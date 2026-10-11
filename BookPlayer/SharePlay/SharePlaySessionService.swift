import BookPlayerKit
import Combine
import Foundation
import GroupActivities
import UIKit

enum ListenTogetherState: Equatable {
  case idle
  case needsFaceTime
  case preparing(title: String)
  case invitation(title: String, author: String)
  case sharing(participants: Int)
  case listening(participants: Int, downloaded: Double)
  case ended(reason: EndReason)

  enum EndReason: Equatable {
    case normal
    /// Sharer: the book couldn't be prepared at all (its files couldn't be read), so nothing could be
    /// sent and the session ended (E14). A piece failure never ends a session (decision 5).
    case prepareFailed
    case unavailable
    /// Listener: the person sharing pressed End (addendum 3, decision 9).
    case sharerEnded
    /// Listener: the person sharing was gone for `sharerReturnLimit` (addendum 3, decision 9).
    case sharerLeft
    /// Listener: the person sharing couldn't read the book's files, so the share ended at the start.
    case sharerCouldNotPrepare
    /// The group session was invalidated, or its messages stopped, without an end message and not by
    /// this device's own End or Leave (fix round 1, I1): the FaceTime call ended, the connection dropped.
    case connectionEnded
    /// Listener: this device left (Leave Listen Together, or Leave to play its own book). No "ended"
    /// banner, which would suggest it ended for everyone (a11y M6).
    case left
    /// Listener with their own copy: a file couldn't be played (gone, or failed three times), so this
    /// phone left (final review I1). One alert says why.
    case ownCopyFailed
  }
}

/// Ongoing conditions of a running session that are not a state of their own (addendum 3). Shown as
/// status text by the banner (`ListenTogetherStatus.line`) and announced once per episode.
enum ListenTogetherNotice: Equatable {
  /// Listener: nothing heard from the person sharing for a while (or they left the roster). The
  /// group is paused until they are back, for at most `sharerReturnLimit`.
  case waitingForSharer
  /// Sharer: a piece failed and is being tried again. The session goes on.
  case retryingSend
}

/// Starts, joins and ends Listen Together sessions. The sharer splits and uploads the book;
/// listeners receive the pieces and play them with their own player. Playback itself is kept in
/// sync by `ListenTogetherCoordinatorBridge`; this service only relays other people's actions as
/// VoiceOver announcements.
@MainActor
final class SharePlaySessionService: ObservableObject, BPLogger {
  enum Role {
    case sharer
    case listener
  }

  @Published private(set) var state: ListenTogetherState = .idle
  @Published private(set) var listener: ListenerPlayer?
  /// The title of the share this device joined, from the invitation; shown until the manifest arrives.
  @Published private(set) var joinedTitle: String?
  /// True when the sharer should see the one-time "listening only" note (first share on this device).
  /// It is shown before sharing starts, so it never cuts off the session's announcements.
  @Published private(set) var showsFirstShareNote = false
  /// The book to share once the first-share note has been read.
  private var firstShareNoteItem: PlayableItem?
  /// The listener's own copy of the book in the invitation on screen (addendum 2), or nil when the
  /// book would be sent. Set before the invitation state, so the sheet is built with the right words.
  @Published private(set) var invitationOwnCopy: ListenTogetherOwnCopy?
  /// "You need your own copy" (owners-only share, no copy): shown as a single-button alert by
  /// MainCoordinator. The invitation has already been declined when this is set.
  @Published private(set) var needsCopyNotice: ListenTogetherNeedsCopyNotice?
  /// True while this device listens with its own copy: nothing is downloaded and the End hint says
  /// the copy is kept.
  @Published private(set) var isUsingOwnCopy = false
  /// An ongoing condition of the running session (waiting for the sharer, retrying a piece). Nil
  /// when there is none, and always nil outside a session.
  @Published private(set) var notice: ListenTogetherNotice?
  /// Listener: why the last session ended, when the person sharing ended it or left (decision 9,
  /// Becky's ruling: one message, then nothing of that session remains). Kept until the message has
  /// been shown (`acknowledgeEndNotice()`) or a new session starts. The session itself, its player,
  /// row and temporary copy are already gone when this is set.
  @Published private(set) var endNotice: ListenTogetherState.EndReason?
  /// Listener: the person sharing left the roster and the 60 s grace runs (the group is paused).
  @Published private(set) var isSharerGraceRunning = false
  /// Listener: the group waits for a piece this device doesn't have yet (mirrors the player).
  @Published private(set) var isListenerWaitingForPiece = false
  /// Listener: the shared book is playing on this phone (mirrors the player). The "Can't reach the
  /// person sharing. The book keeps playing." line needs it to be true (final review M2).
  @Published private(set) var isListenerPlaying = false
  /// Someone else paused the group; cleared by the next play (E9).
  @Published private(set) var isPausedByOther = false
  /// Sharer, owners-only: someone couldn't join (no copy). Shown until the count changes or the end (E11).
  @Published private(set) var someoneDeclined = false

  /// What the status line needs besides the state.
  var statusConditions: ListenTogetherStatusConditions {
    ListenTogetherStatusConditions(
      notice: notice, isSharerGraceRunning: isSharerGraceRunning,
      isWaitingForPiece: isListenerWaitingForPiece, isListenerPlaying: isListenerPlaying,
      isPausedByOther: isPausedByOther,
      someoneDeclined: someoneDeclined)
  }

  /// Every alert, announcement and spoken message goes through here (guidance A.2).
  let messages: ListenTogetherMessageDelivery

  var invitationUsesOwnCopy: Bool { invitationOwnCopy != nil }

  // Collaborators. Internal (not private) so SharePlaySessionService+Session.swift can use them.
  let playerManager: PlayerManagerProtocol
  let storage: ShareStorage
  let announcer: ListenTogetherAnnouncer
  let transportFactory: @MainActor (GroupSession<ListenTogetherActivity>, URL) -> ListenTogetherTransport
  /// Remembers, per device, that the first-share note was seen.
  let defaults: UserDefaults
  static let firstShareNoteSeenKey = "listenTogetherFirstShareNoteSeen"
  /// The idle timer, background tasks and app state (addendum 3, decision 6).
  let appSystem: ListenTogetherAppSystem
  /// Waits out a back-off before a piece is tried again. Test seam (back-off lengths without waiting).
  var retrySleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  /// Makes the file for one piece. Test seam (no AVFoundation).
  var pieceExporter: @MainActor (PlannedPiece, [SourceFile], URL) async throws -> ExportedPiece = {
    try await BookSplitter().export($0, from: $1, to: $2)
  }
  /// Where the group is on the book timeline, for choosing the next piece. Test seam; nil reads the
  /// sharer's own player.
  var groupPositionProvider: (@MainActor () -> TimeInterval)?
  /// Runs `action` after `delay`, for the session's repeating checks (heartbeat, sharer presence,
  /// state requests). Separate from `schedule`, so tests of one-off waits see only those. Test seam.
  var scheduleSessionTimer: @MainActor (Duration, @escaping @MainActor () -> Void) -> Void = { delay, action in
    Task { @MainActor in
      try? await Task.sleep(for: delay)
      action()
    }
  }
  /// Builds the coordinator control for a session's bridge. Test seam; nil uses the real
  /// AVDelegatingPlaybackCoordinator.
  var coordinatorControlFactory: (@MainActor () -> ListenTogetherCoordinatorControlling)?
  /// The sharer says "still here" this often.
  static let heartbeatInterval: Duration = .seconds(5)
  /// A listener asks for the manifest and piece map this often until it has them.
  static let stateRequestInterval: Duration = .seconds(5)
  /// A listener that hears nothing from the person sharing for longer than this waits for them.
  static let sharerSilenceLimit: TimeInterval = 15
  /// ...and ends the session if they are not back after this long.
  static let sharerReturnLimit: TimeInterval = 60
  /// Shows Apple's sharing sheet when there is no FaceTime call. Set by MainCoordinator; nil means the
  /// "Couldn't open sharing" alert is shown instead.
  weak var sharingSheetPresenter: ListenTogetherSharingSheetPresenting?
  /// Whether this device is on a FaceTime call that can carry SharePlay. Test seam.
  var isEligibleForGroupSession: @MainActor () -> Bool
  /// Runs `action` after `delay`. Test seam, so the sharing sheet's waits need no real clock.
  var schedule: @MainActor (Duration, @escaping @MainActor () -> Void) -> Void = { delay, action in
    Task { @MainActor in
      try? await Task.sleep(for: delay)
      action()
    }
  }
  /// After the sharing sheet closes: lets its screen change finish before anything is announced.
  static let sheetAnnouncementDelay: Duration = .milliseconds(700)
  /// After the sharing sheet closes with a send: how long to wait for our session before saying it
  /// didn't start (R37). The sheet cannot tell a slow session from a lost one, so a session that still
  /// arrives later is accepted while nothing else is going on (`lateShare`).
  static let sheetSessionTimeout: Duration = .seconds(20)
  /// The sheet never reported a result (app backgrounded, screen locked, sheet taken down from under
  /// it): after this long the pending share is released so Listen Together is offered again. While the
  /// sheet is still on screen nothing is released or announced: the check simply runs again later.
  static let sheetWatchdog: Duration = .seconds(120)
  /// The sharer's end message gets this long before the session is ended anyway.
  static let endMessageTimeout: Duration = .seconds(2)
  /// After the end message is out, the session is ended this much later (within the time limit), so
  /// listeners handle "ended by the person sharing" before their session is invalidated.
  static let endAfterMessageDelay: Duration = .milliseconds(500)
  /// Owners-only shares: someone new in the roster is counted and announced only after this long, and
  /// only if they are still there and did not decline (no copy), so a decliner is never heard as
  /// "Someone joined" and "Someone left". Covers the decliner's 3 s wait for the join plus the send.
  /// Send-mode shares (nobody can decline) announce at once.
  static let joinConfirmationDelay: Duration = .seconds(4)
  /// The sharer hears "Someone couldn't join" at most once per this many seconds.
  static let declineAnnouncementInterval: TimeInterval = 10

  /// Finds the listener's own copy of a shared book. Nil: never matches (tests, previews).
  let ownCopyFinder: ListenTogetherOwnCopyFinding?
  /// How long the invitation waits for the own-copy check. Past it, the invitation is shown as if
  /// there were no copy (the wording never changes once the sheet is up).
  var ownCopyCheckLimit: Duration = .seconds(3)
  /// Test seam: the clock for the decline announcement's limit.
  var now: () -> Date = Date.init

  // Active session. Reset by `tearDown(reason:)`.
  var role: Role?
  var shareID: UUID?
  var transport: ListenTogetherTransport?
  var bridge: ListenTogetherCoordinatorBridge?
  var sharerTarget: SharerPlaybackTarget?
  var manifest: SharedBookManifest?
  var participantCount = 1
  /// The first participants event of a session is the current roster, not a join or leave.
  var hasParticipantBaseline = false
  /// Sharer: messages already sent for uploaded pieces, re-sent to late joiners.
  var uploadedPieceMessages: [ListenTogetherMessage] = []
  /// Listener: attachment id -> piece index, from `.pieceUploaded`.
  var pieceIndexByAttachment: [UUID: Int] = [:]
  /// Listener: files that arrived before we could place them.
  var heldAttachments: [UUID: URL] = [:]
  var placedPieces = Set<Int>()
  /// True while the "waiting for the book" announcement has been made for the current wait.
  var announcedWaiting = false
  /// Play/pause pressed again and again while held for a piece: "waiting" at most once per 3 s.
  var waitingToggleLimiter = ListenTogetherRepeatLimiter(interval: 3)
  /// Play pressed while the person sharing is missing: "Waiting for the person sharing" at most every 2 s.
  var sharerWaitToggleLimiter = ListenTogetherRepeatLimiter(interval: 2)
  /// Roster by participant id (when the transport reports ids): everyone present, everyone counted
  /// (present for `joinConfirmationDelay` and not declined), and everyone who declined.
  var rosterIDs = Set<UUID>()
  var confirmedParticipantIDs = Set<UUID>()
  var declinedParticipantIDs = Set<UUID>()
  var declineAnnouncementLimiter = ListenTogetherRepeatLimiter(interval: declineAnnouncementInterval)
  /// The running share is "Only people who have the book can join": the sharer uploads nothing, and
  /// both roles delay join announcements so decliners are never heard.
  var isOwnersOnlySession = false
  /// Own copy: "Joined. Playing your copy." is still to be said.
  var pendingOwnCopyJoinedLine = false
  /// Sharer: the running share's fingerprint, sent in the manifest.
  var sharingFingerprint: BookFingerprint?
  var localEventsBag = Set<AnyCancellable>()
  var eventLoop: Task<Void, Never>?
  /// Sharer: the export and upload pipeline. Cancelled by `tearDown`, so no export keeps running after End.
  var sharingTask: Task<Void, Never>?
  /// The user's own actions, sent one after another in the order they happened (one consumer).
  var outbox: AsyncStream<ListenTogetherMessage>.Continuation?
  var outboxTask: Task<Void, Never>?
  /// Sharer: which piece goes next (follows the group, and listeners' requests).
  var pieceScheduler: PieceUploadScheduler?
  /// Sharer: the current back-off wait; woken when the app becomes active or the session ends.
  let retryWaiter = ListenTogetherRetryWaiter()
  /// Sharer: the idle timer is held off while pieces are left to send. `didDisableIdleTimer` is true
  /// only when this code switched it off (it was on before), so only then is it switched back.
  var keepsScreenAwake = false
  var didDisableIdleTimer = false
  /// Sharer: what the send loop needs, kept so a piece can be sent again after the loop finished.
  var sendContext: (item: PlayableItem, files: [SourceFile], folder: URL)?
  var isSendLoopRunning = false
  /// Sharer: real failures per piece (for its back-off); interruptions are not counted.
  var pieceFailures: [Int: Int] = [:]
  /// Sharer: state requests are answered at most once per `stateAnswerInterval`; requests in between
  /// are coalesced into one later answer.
  var lastStateAnswer: Date?
  var isStateAnswerPending = false
  static let stateAnswerInterval: TimeInterval = 2
  /// Sharer: a heartbeat waits in the outbox (at most one at a time).
  var isHeartbeatQueued = false
  /// Listener: when the person sharing was last heard from; whether they are silent (notice only);
  /// and since when they are missing from the roster (the 60 s grace).
  var lastSharerContact: Date?
  var isSharerSilent = false
  var sharerMissingSince: Date?
  /// Listener: the sharer's participant id, from their messages.
  var sharerParticipantID: UUID?
  /// Listener: the roster has had someone besides this device (so a roster of one means the sharer left).
  var hasSeenOtherParticipants = false
  /// Listener: failed piece loads are retried after 5, 10, 20, then every 30 s.
  static let loadRetryDelays: [Duration] = [.seconds(5), .seconds(10), .seconds(20), .seconds(30)]
  /// Shares that ended for this device (the sharer ended or left, it couldn't be prepared, or this
  /// device ended it): never offered or joined again in this app session (decision 9 ruling). A new
  /// invitation has a new id.
  private(set) var endedShareIDs = Set<UUID>()
  func rememberEndedShare(_ id: UUID) { endedShareIDs.insert(id) }
  /// Listener: how often each received piece failed to play (its reload backs off).
  var pieceDecodeFailures: [Int: Int] = [:]
  /// Listener with their own copy: the own files by piece index, armed again after a failure (I1).
  var ownCopyFiles: [Int: SourceFile] = [:]
  /// Sharer: `.needPiece` requests that arrived before the send order existed (final review M5).
  var pendingPieceRequests = Set<Int>()
  /// An own file that fails this many times makes this phone leave.
  static let ownCopyFailureLimit = 3
  private var appStateObservation: AnyCancellable?
  /// The app terminating (transfer fix, item 4).
  private var appExitObservations = Set<AnyCancellable>()

  // SharePlay plumbing.
  private var observeTask: Task<Void, Never>?
  /// The real GroupSession behind the current transport, if any (never set in tests).
  var activeSession: GroupSession<ListenTogetherActivity>?
  private var pendingShareID: UUID?
  private var pendingItem: PlayableItem?
  private var pendingInvitation: GroupSession<ListenTogetherActivity>?
  /// What the waiting invitation offers; set while its own-copy check runs.
  private var pendingInvitationDetails: ListenTogetherInvitationDetails?
  /// How the waiting invitation is declined (from its session; test seam).
  private var pendingInvitationDecline: ListenTogetherPendingDecline?
  /// The decline that waits for the "You need your own copy" alert to be on screen.
  private var noticeDecline: ListenTogetherPendingDecline?
  /// Watches the notice's session: if it ends while the notice waits, the notice is dropped.
  private var noticeObservation: AnyCancellable?
  /// The notice's age stands still while it is held back by another Listen Together alert.
  private var needsCopyAgingPausedAt: Date?
  private var needsCopyPausedTotal: TimeInterval = 0
  private var invitationCheckTask: Task<Void, Never>?
  /// Shares cancelled while preparing (End, or Cancel in the sharing sheet). If `activate()` was already
  /// in flight, their session can still arrive; it is left, never offered as an invitation. Each id is
  /// removed once seen. A cancelled share whose session never arrives stays here until relaunch; that
  /// is one UUID per cancelled share, so the set stays tiny in practice.
  private var cancelledShareIDs = Set<UUID>()
  /// A sharing-sheet share that was sent but whose session did not arrive in time (or whose sheet never
  /// reported back). If its session still arrives while this device is idle, it is started as our own
  /// share. Only the most recent one is kept.
  private var lateShare: (id: UUID, item: PlayableItem)?
  /// The latest sharing-sheet share. A delayed "not started" announcement is only made for it.
  private var latestSheetShareID: UUID?
  private var invitationBag = Set<AnyCancellable>()
  private var endedGeneration = 0

  init(
    playerManager: PlayerManagerProtocol,
    storage: ShareStorage = ShareStorage(),
    announcer: ListenTogetherAnnouncer? = nil,
    defaults: UserDefaults = .standard,
    ownCopyFinder: ListenTogetherOwnCopyFinding? = nil,
    appSystem: ListenTogetherAppSystem? = nil,
    speaker: ListenTogetherSpeaking? = nil,
    coverTracker: ListenTogetherCoverTracker? = nil,
    focusRequests: ListenTogetherFocusRequests? = nil,
    notificationCenter: NotificationCenter = .default,
    transportFactory: @escaping @MainActor (GroupSession<ListenTogetherActivity>, URL) -> ListenTogetherTransport
      = { GroupSessionTransport(session: $0, downloadFolder: $1) }
  ) {
    self.playerManager = playerManager
    self.storage = storage
    // Built here rather than as a default argument, which would run outside the main actor.
    self.announcer = announcer ?? ListenTogetherAnnouncer()
    self.transportFactory = transportFactory
    self.defaults = defaults
    self.ownCopyFinder = ownCopyFinder
    // Built here rather than as a default argument, which would run outside the main actor.
    let system = appSystem ?? UIKitListenTogetherAppSystem()
    self.appSystem = system
    self.messages = ListenTogetherMessageDelivery(
      announcer: self.announcer, speaker: speaker ?? ListenTogetherSpeaker.shared,
      coverTracker: coverTracker ?? .shared, focusRequests: focusRequests ?? .shared,
      context: {
        ListenTogetherDeliveryContext(
          appState: system.appState, isLocked: !UIApplication.shared.isProtectedDataAvailable,
          isVoiceOverRunning: UIAccessibility.isVoiceOverRunning)
      })
    let groupStateObserver = GroupStateObserver()
    self.isEligibleForGroupSession = { groupStateObserver.isEligibleForGroupSession }
    observeAppState()
    observeAppExit(in: notificationCenter)
  }

  var isInSession: Bool { role != nil }
  /// True while this device listens to someone else's share (from Join until the session ends).
  var isListenerSession: Bool { role == .listener }

  /// Setters for SharePlaySessionService+Session.swift; the published properties stay read-only elsewhere.
  func setState(_ newState: ListenTogetherState) { state = newState }
  func setListener(_ player: ListenerPlayer?) { listener = player }
  func setOwnCopy(_ value: Bool) { isUsingOwnCopy = value }
  func setSharerGraceRunning(_ value: Bool) { if isSharerGraceRunning != value { isSharerGraceRunning = value } }
  func setListenerWaitingForPiece(_ value: Bool) {
    if isListenerWaitingForPiece != value { isListenerWaitingForPiece = value }
  }
  func setListenerPlaying(_ value: Bool) { if isListenerPlaying != value { isListenerPlaying = value } }
  func setPausedByOther(_ value: Bool) { if isPausedByOther != value { isPausedByOther = value } }
  func setSomeoneDeclined(_ value: Bool) { if someoneDeclined != value { someoneDeclined = value } }

  /// "Couldn't send part of the book. Trying again." is said once per episode (guidance A.2, C5), until
  /// every piece is sent again.
  func setNotice(_ value: ListenTogetherNotice?) {
    guard notice != value else { return }
    let old = notice
    notice = value
    // "Waiting for the person sharing" and "is back" belong to the roster grace only (a11y I4); they
    // are delivered where the grace starts and ends. Silence alone is a quiet status line.
    if old != .retryingSend, value == .retryingSend { messages.deliver(.retryingSend) }
  }

  /// App state changes reach `appStateChanged(to:)` for the service's lifetime.
  private func observeAppState() {
    appStateObservation = appSystem.appStateChanges
      .sink { [weak self] appState in
        MainActor.assumeIsolated { self?.appStateChanged(to: appState) }
      }
  }

  /// Best-effort (transfer fix, item 4): when the app terminates, a sharer ends SharePlay for
  /// everyone and a listener leaves, so nobody is left in a session with nobody sharing. A scene going
  /// away is not the app closing (iOS can disconnect a background scene that keeps playing), so only
  /// termination counts (fix round 1, C3).
  private func observeAppExit(in center: NotificationCenter) {
    center.publisher(for: UIApplication.willTerminateNotification)
      .sink { [weak self] _ in
        MainActor.assumeIsolated { self?.endForAppExit(reason: "terminate") }
      }
      .store(in: &appExitObservations)
  }

  /// No time is left for the end message: the session is ended (sharer) or left (listener) at once,
  /// and nothing is announced.
  func endForAppExit(reason: String) {
    guard isInSession, let transport else { return }
    Self.logger.info(
      "Listen Together: the app is closing (\(reason, privacy: .public)); \(self.role == .sharer ? "ending the group session" : "leaving", privacy: .public)")
    if let shareID { rememberEndedShare(shareID) }
    if role == .sharer {
      transport.stopPieceTransfers()
      tearDown(reason: .normal, announces: false, leaveTransport: false)
      transport.end()
    } else {
      tearDown(reason: .left, announces: false)
    }
  }

  /// The listener's message after "The person sharing ended/left" has been shown.
  func acknowledgeEndNotice() { endNotice = nil }

  /// A new session starts: an older ending message is no longer relevant, and alerts still waiting
  /// about an earlier session are dropped (guidance A.0, A.4).
  func clearEndNotice() {
    endNotice = nil
    messages.dropPendingAlerts()
    // A cover flag left over from an earlier session never outlives it (fix round 1, I2).
    if listener == nil { messages.coverTracker.coverDismissed() }
  }

  // MARK: Starting and joining

  /// Watches for Listen Together sessions: our own (after `startSharing`) and invitations from others.
  func startObservingSessions() {
    guard observeTask == nil else { return }
    observeTask = Task { [weak self] in
      for await session in ListenTogetherActivity.sessions() {
        guard let self else { return }
        self.received(session)
      }
    }
  }

  func canShare(_ item: PlayableItem?) -> Bool {
    guard let item else { return false }
    return BookSplitter.isShareable(item)
  }

  /// Whether to offer "Listen Together" for `item` now. Hidden (not disabled) while a share is being
  /// prepared, a session is running or an invitation is waiting, because `startSharing` would do nothing.
  func canOfferSharing(_ item: PlayableItem?) -> Bool {
    guard canShare(item), !isInSession, !isPreparing, pendingInvitation == nil, !showsFirstShareNote
    else { return false }
    switch state {
    case .idle, .needsFaceTime, .ended: return true
    case .preparing, .invitation, .sharing, .listening: return false
    }
  }

  /// True while someone else's share is waiting for Join or Not Now.
  var hasPendingInvitation: Bool { pendingInvitation != nil }

  private var isShowingInvitation: Bool {
    if case .invitation = state { return true }
    return false
  }

  /// The needs-FaceTime alert was dismissed.
  func acknowledgeNeedsFaceTime() {
    guard state == .needsFaceTime else { return }
    state = .idle
  }

  /// Eligible (on a FaceTime call): activate. Otherwise Apple's sharing sheet, or the fallback alert
  /// when the sheet can't be shown.
  nonisolated static func startRoute(
    isEligibleForGroupSession: Bool, canPresentSharingSheet: Bool
  ) -> ListenTogetherStartRoute {
    if isEligibleForGroupSession { return .activate }
    return canPresentSharingSheet ? .sharingSheet : .needsFaceTime
  }

  /// A second call while one share is still being prepared is ignored.
  func startSharing(_ item: PlayableItem) async {
    guard !isInSession, !isPreparing else { return }
    let presenter = sharingSheetPresenter
    switch Self.startRoute(
      isEligibleForGroupSession: isEligibleForGroupSession(),
      canPresentSharingSheet: presenter?.canPresentSharingSheet ?? false
    ) {
    case .activate:
      await activateOnCall(item)
    case .sharingSheet:
      guard let presenter else { return }
      await shareWithSheet(item, presenter: presenter)
    case .needsFaceTime:
      state = .needsFaceTime
    }
  }

  /// On a FaceTime call: the system confirms, then the session arrives through `sessions()`.
  private func activateOnCall(_ item: PlayableItem) async {
    guard let shareID = beginPreparing(item) else { return }
    let activity = await makeActivity(shareID: shareID, item: item)
    guard pendingShareID == shareID else { return }

    let result = await activity.prepareForActivation()
    // `end()` while the system sheet was up cancels the share.
    guard pendingShareID == shareID else { return }
    switch result {
    case .activationPreferred:
      do {
        _ = try await activity.activate()
        // The session arrives through `startObservingSessions()`.
      } catch {
        Self.logger.error("Listen Together: could not start SharePlay: \(error.localizedDescription)")
        guard pendingShareID == shareID else { return }
        clearPendingShare()
        endUnavailable()
      }
    case .activationDisabled:
      clearPendingShare()
      endUnavailable()
    case .cancelled:
      clearPendingShare()
      state = .idle
    @unknown default:
      clearPendingShare()
      state = .idle
    }
  }

  /// The share's activity: the book, its fingerprint (so listeners can find their own copy before the
  /// invitation is shown) and the sharer's setting at this moment (a later change applies to the next
  /// share). The 64 KB sample hash is read off the main actor.
  func makeActivity(shareID: UUID, item: PlayableItem) async -> ListenTogetherActivity {
    let ownersOnly = ListenTogetherSharingMode.current(in: defaults) == .ownersOnly
    return ListenTogetherActivity(
      shareID: shareID, title: item.title, author: item.author,
      fingerprint: await Self.fingerprint(for: item), ownersOnly: ownersOnly)
  }

  static func fingerprint(for item: PlayableItem) async -> BookFingerprint? {
    guard let files = try? BookSplitter().sourceFiles(for: item), let first = files.first else { return nil }
    let hash = await BookFingerprint.sampleHashOffMain(of: first.url)
    return BookFingerprint(
      title: item.title, author: item.author, duration: item.duration, sourceFiles: files, sampleHash: hash)
  }

  // MARK: Sharing sheet (no FaceTime call)

  /// Records the share as pending without showing `.preparing`: the sheet has the screen, and a
  /// banner or announcement now would be cut off or come before anyone is chosen. Nothing is announced
  /// before the sheet; it announces itself.
  private func shareWithSheet(_ item: PlayableItem, presenter: ListenTogetherSharingSheetPresenting) async {
    guard let shareID = recordPendingShare(item) else { return }
    latestSheetShareID = shareID
    if state == .needsFaceTime { state = .idle }
    // If the sheet never reports back, don't leave Listen Together hidden (and invitations ignored).
    scheduleSheetWatchdog(shareID)
    let activity = await makeActivity(shareID: shareID, item: item)
    guard pendingShareID == shareID else { return }
    let outcome = await presenter.presentSharingSheet(for: activity)
    sharingSheetFinished(outcome, shareID: shareID)
  }

  /// The sheet closed. Internal for tests.
  func sharingSheetFinished(_ outcome: ListenTogetherSharingSheetOutcome, shareID: UUID) {
    switch outcome {
    case .unavailable:
      // Nothing was shared, so there is no session to leave later.
      guard pendingShareID == shareID else { return }
      clearPendingShare()
      // The state keeps its old name; the alert it shows is "Couldn't open sharing".
      state = .needsFaceTime
    case .cancelled:
      cancelSheetShare(shareID)
    case .abandoned:
      releaseSheetShare(shareID)
    case .sent:
      schedule(Self.sheetAnnouncementDelay) { [weak self] in self?.sheetPreparingMoment(shareID) }
      schedule(Self.sheetSessionTimeout) { [weak self] in self?.releaseSheetShare(shareID) }
    }
  }

  /// W-I2: the watchdog never speaks over an open sheet. While the sheet is still presented it checks
  /// again later; once the sheet is gone (and still no result) the share is released.
  private func scheduleSheetWatchdog(_ shareID: UUID) {
    schedule(Self.sheetWatchdog) { [weak self] in
      guard let self, self.pendingShareID == shareID else { return }
      switch Self.sheetWatchdogAction(isSheetStillPresented: self.sharingSheetPresenter?.isSharingSheetPresented ?? false) {
      case .checkAgainLater: self.scheduleSheetWatchdog(shareID)
      case .release: self.releaseSheetShare(shareID)
      }
    }
  }

  enum SheetWatchdogAction: Equatable {
    case checkAgainLater
    case release
  }

  /// What the watchdog does when it fires. Test seam.
  nonisolated static func sheetWatchdogAction(isSheetStillPresented: Bool) -> SheetWatchdogAction {
    isSheetStillPresented ? .checkAgainLater : .release
  }

  /// Shortly after a send: if our session hasn't arrived yet, show and announce "Preparing".
  private func sheetPreparingMoment(_ shareID: UUID) {
    guard pendingShareID == shareID, let item = pendingItem, !isInSession else { return }
    state = .preparing(title: item.title)
    announcer.announce(String.localizedStringWithFormat("listen_together_status_preparing".localized, item.title))
  }

  /// Cancel in the sheet: the share is cancelled (a late session is left), and one short announcement
  /// says so once the sheet's dismissal has settled. Does nothing if the session arrived or the share
  /// was already ended.
  private func cancelSheetShare(_ shareID: UUID) {
    if lateShare?.id == shareID {
      // The sheet reported Cancel after the share had been released: its session must not start now.
      lateShare = nil
      cancelledShareIDs.insert(shareID)
      return
    }
    guard pendingShareID == shareID, !isInSession else { return }
    cancelledShareIDs.insert(shareID)
    clearPendingShare()
    state = .idle
    afterSheetSettled(shareID) { [weak self] in
      self?.announcer.announce("listen_together_cancelled_announcement".localized)
    }
  }

  /// Sent but no session in time, or the sheet never reported back: Listen Together is offered again
  /// and says it didn't start. Not cancelled: if the session still arrives while nothing else is going
  /// on, it starts as our share.
  private func releaseSheetShare(_ shareID: UUID) {
    guard pendingShareID == shareID, let item = pendingItem, !isInSession else { return }
    clearPendingShare()
    // Only the latest late share is kept. An older one is cancelled, so its session (if it still
    // arrives) is left rather than started or offered to ourselves as an invitation.
    if let replaced = lateShare, replaced.id != shareID { cancelledShareIDs.insert(replaced.id) }
    lateShare = (shareID, item)
    state = .idle
    // A failure reason: a centred alert (E13), not only an announcement.
    afterSheetSettled(shareID) { [weak self] in self?.messages.deliver(.didntStart) }
  }

  /// Runs `action` (the sheet's result message) after the sheet's screen change has settled, and only if
  /// nothing has happened since: no newer share, nothing pending, no session, no invitation on screen.
  private func afterSheetSettled(_ shareID: UUID, _ action: @escaping @MainActor () -> Void) {
    schedule(Self.sheetAnnouncementDelay) { [weak self] in
      guard let self, self.latestSheetShareID == shareID, self.pendingShareID == nil, !self.isInSession,
        self.pendingInvitation == nil, !self.isShowingInvitation
      else { return }
      action()
    }
  }

  // MARK: First-share note

  /// Listen Together was chosen in the More menu. The first time on this device the sharer first reads
  /// that people who join can only listen; sharing starts when they dismiss it.
  func chooseListenTogether(_ item: PlayableItem) async {
    guard !defaults.bool(forKey: Self.firstShareNoteSeenKey) else {
      await startSharing(item)
      return
    }
    guard !showsFirstShareNote else { return }
    firstShareNoteItem = item
    showsFirstShareNote = true
  }

  /// Share was chosen on the note: remembered on this device, then sharing starts.
  func acknowledgeFirstShareNote() async {
    guard showsFirstShareNote else { return }
    showsFirstShareNote = false
    defaults.set(true, forKey: Self.firstShareNoteSeenKey)
    guard let item = firstShareNoteItem else { return }
    firstShareNoteItem = nil
    await startSharing(item)
  }

  /// Cancel (or two-finger Z) on the note, or the player closed before it was answered: nothing is
  /// shared and nothing is remembered, so the note is shown again next time.
  func cancelFirstShareNote() {
    showsFirstShareNote = false
    firstShareNoteItem = nil
  }

  /// True from `startSharing` until our session arrives or the share is cancelled.
  var isPreparing: Bool { pendingShareID != nil }

  /// Records the share being prepared and shows `.preparing`. Returns nil if one is already
  /// being prepared or a session is active. Test seam (no GroupSession needed).
  func beginPreparing(_ item: PlayableItem) -> UUID? {
    guard let shareID = recordPendingShare(item) else { return nil }
    state = .preparing(title: item.title)
    return shareID
  }

  private func recordPendingShare(_ item: PlayableItem) -> UUID? {
    guard !isInSession, !isPreparing else { return nil }
    let shareID = UUID()
    pendingShareID = shareID
    pendingItem = item
    return shareID
  }

  /// Our own session arrived: takes the pending share (cleared) for sharing.
  private func claimOwnShare(_ shareID: UUID) -> PlayableItem? {
    guard pendingShareID == shareID, let item = pendingItem else { return nil }
    clearPendingShare()
    return item
  }

  /// What Join does with the invitation's own-copy match (addendum 2).
  enum JoinPlan: Equatable {
    /// Play the listener's own copy: nothing is downloaded.
    case ownCopy
    /// Get the book from the sharer (today's path).
    case download
    /// Owners-only, and the copy found for the invitation can no longer be used: decline.
    case declineCopyUnusable
  }

  /// The match is re-checked at Join: a copy moved or deleted since the invitation is never started.
  nonisolated static func joinPlan(hadOwnCopy: Bool, isStillAvailable: Bool, ownersOnly: Bool) -> JoinPlan {
    if hadOwnCopy, isStillAvailable { return .ownCopy }
    if hadOwnCopy, ownersOnly { return .declineCopyUnusable }
    return .download
  }

  func joinInvitation() {
    guard let session = pendingInvitation, !isInSession else { return }
    let candidate = invitationOwnCopy
    let plan = Self.joinPlan(
      hadOwnCopy: candidate != nil, isStillAvailable: candidate?.isStillAvailable() ?? false,
      ownersOnly: session.activity.isOwnersOnly)
    if plan == .declineCopyUnusable {
      declineWithoutCopy(bookTitle: session.activity.title, cause: .copyUnusable)
      return
    }
    let ownCopy = plan == .ownCopy ? candidate : nil
    clearInvitation()
    let shareID = session.activity.shareID
    let folder: URL
    do {
      folder = try storage.folder(for: shareID, role: .listener)
    } catch {
      Self.logger.error("Listen Together: could not create the download folder: \(error.localizedDescription)")
      session.leave()
      endUnavailable()
      return
    }
    playerManager.pause()
    joinedTitle = session.activity.title
    let transport = transportFactory(session, folder)
    // Before the join: a listener with their own copy never loads a piece from the journal.
    if ownCopy != nil { transport.stopReceivingPieces() }
    activeSession = session
    session.join()
    // A-I2: set up in the same main-actor turn as the join, so End (or a second invitation) can never
    // fall into a gap where the session is joined but this device is not yet listening.
    if !startListening(
      with: transport, shareID: shareID, ownCopy: ownCopy, title: session.activity.title,
      author: session.activity.author, shared: session.activity.fingerprint,
      ownersOnly: session.activity.isOwnersOnly)
    {
      activeSession = nil
      joinedTitle = nil
      transport.leave()
    }
  }

  /// Does nothing unless an invitation is waiting.
  func declineInvitation() {
    guard pendingInvitation != nil else { return }
    pendingInvitation?.leave()
    clearInvitation()
    state = .idle
  }

  /// Forgets the waiting invitation (answered, declined or gone).
  private func clearInvitation() {
    pendingInvitation = nil
    pendingInvitationDetails = nil
    pendingInvitationDecline = nil
    invitationOwnCopy = nil
    invitationCheckTask?.cancel()
    invitationCheckTask = nil
    invitationBag.removeAll()
  }

  /// Owners-only share and this device can't use a copy: the invitation is declined with a small
  /// "declined, no copy" message (so the sharer can hear that someone couldn't join), and the
  /// single-button "You need your own copy" alert explains it. No second action is needed: the
  /// decline is already done when the alert appears, and OK or escape only closes it.
  func declineWithoutCopy(bookTitle: String, cause: ListenTogetherNeedsCopyNotice.Cause) {
    let decline = pendingInvitationDecline ?? pendingInvitation.map(Self.decline(for:))
    clearInvitation()
    if isShowingInvitation { state = .idle }
    // A newer notice replaces an older one that was never shown: that one is left without a message.
    noticeDecline?.abandon()
    noticeDecline = decline
    let notice = ListenTogetherNeedsCopyNotice(bookTitle: bookTitle, cause: cause, createdAt: now())
    resetNeedsCopyAging()
    // Kept apart from invitationBag (cleared above): the session is watched until the notice is gone.
    noticeObservation = decline?.watchInvalidation { [weak self] in
      self?.needsCopySessionEnded(noticeID: notice.id)
    }
    needsCopyNotice = notice
  }

  static func decline(for session: GroupSession<ListenTogetherActivity>) -> ListenTogetherPendingDecline {
    ListenTogetherPendingDecline(
      send: { ListenTogetherDecline.sendAndLeave(session) },
      abandon: { session.leave() },
      watchInvalidation: { [weak session] handler in
        session?.$state
          .receive(on: DispatchQueue.main)
          .sink { state in
            guard case .invalidated = state else { return }
            MainActor.assumeIsolated { handler() }
          }
      })
  }

  /// "Joined. Playing your copy." is said this long after the player's title has VoiceOver focus, so
  /// the focus change can't cut it off (a11y I2)...
  static let ownCopyJoinedAfterFocusDelay: Duration = .milliseconds(300)
  /// ...or after this long from Join if the player is not shown (the user closed it, or it was slow).
  static let ownCopyJoinedFallbackDelay: Duration = .milliseconds(1500)

  /// The listener player put VoiceOver focus on the title. Called by ListenerPlayerView every time it
  /// appears; only the first call of an own-copy session schedules the line.
  func listenerTitleFocused() {
    guard pendingOwnCopyJoinedLine, let transport else { return }
    schedule(Self.ownCopyJoinedAfterFocusDelay) { [weak self] in self?.announceOwnCopyJoined(on: transport) }
  }

  /// Says "Joined. Playing your copy." once per session, whichever of the two moments comes first.
  func announceOwnCopyJoined(on transport: ListenTogetherTransport) {
    guard self.transport === transport, isUsingOwnCopy, pendingOwnCopyJoinedLine else { return }
    pendingOwnCopyJoinedLine = false
    announcer.announce("listen_together_joined_own_copy".localized)
  }

  /// The "You need your own copy" alert is on screen: only now is the decline sent (a11y I3), so the
  /// user hears the alert before anything happens in SharePlay. OK and escape only close the alert.
  func needsCopyNoticePresented() {
    let decline = noticeDecline
    noticeDecline = nil
    decline?.send()
  }

  /// A waiting "You need your own copy" notice is only shown this long after it was made. Older, the
  /// invitation it explains is long gone: it is discarded unshown (no alert, no decline message).
  static let needsCopyNoticeLifetime: TimeInterval = 60

  /// True when a notice is waiting and still young enough to show. A too-old notice is discarded here
  /// (its session is left without a message). Checked before every presentation attempt.
  func needsCopyNoticeIsCurrent() -> Bool {
    guard let notice = needsCopyNotice else { return false }
    guard needsCopyNoticeAge(notice) > Self.needsCopyNoticeLifetime else { return true }
    noticeDecline?.abandon()
    clearNeedsCopyNotice()
    return false
  }

  /// How long the notice has waited, not counting time spent behind another Listen Together alert.
  private func needsCopyNoticeAge(_ notice: ListenTogetherNeedsCopyNotice) -> TimeInterval {
    var paused = needsCopyPausedTotal
    if let since = needsCopyAgingPausedAt { paused += now().timeIntervalSince(since) }
    return now().timeIntervalSince(notice.createdAt) - paused
  }

  /// Another Listen Together alert is on screen: the waiting notice doesn't age meanwhile (a11y M7).
  func pauseNeedsCopyNoticeAging() {
    guard needsCopyNotice != nil, needsCopyAgingPausedAt == nil else { return }
    needsCopyAgingPausedAt = now()
  }

  func resumeNeedsCopyNoticeAging() {
    guard let since = needsCopyAgingPausedAt else { return }
    needsCopyPausedTotal += now().timeIntervalSince(since)
    needsCopyAgingPausedAt = nil
  }

  private func resetNeedsCopyAging() {
    needsCopyAgingPausedAt = nil
    needsCopyPausedTotal = 0
  }

  /// The invitation's session ended while its notice waited: nothing to tell anyone any more.
  private func needsCopySessionEnded(noticeID: UUID) {
    guard needsCopyNotice?.id == noticeID else { return }
    clearNeedsCopyNotice()
  }

  private func clearNeedsCopyNotice() {
    resetNeedsCopyAging()
    noticeDecline = nil
    noticeObservation = nil
    needsCopyNotice = nil
  }

  /// The "You need your own copy" alert was closed (OK or escape).
  func acknowledgeNeedsCopyNotice() {
    resetNeedsCopyAging()
    needsCopyNotice = nil
    // Never shown (should not happen: only the alert acknowledges): leave without a message.
    noticeDecline?.abandon()
    noticeDecline = nil
    noticeObservation = nil
  }

  /// Leave was chosen on "Leave Listen Together to play this book?": the listener session ends with
  /// `announcement` (one sentence in context) instead of the generic "ended". Listener only.
  func leaveForOwnBook(announcement: String) {
    guard role == .listener else { return }
    if let shareID { endedShareIDs.insert(shareID) }
    tearDown(reason: .left, announcement: announcement)
  }

  /// "Leave Listen Together" (listener, leave guidance): this device leaves and deletes its temporary
  /// copy; the others keep listening. "You left Listen Together." is said once, after the listener
  /// cover has gone and VoiceOver focus has moved to the mini player (when it is shown).
  func leave() {
    guard role == .listener else { return }
    if let shareID { endedShareIDs.insert(shareID) }
    tearDown(reason: .left, announces: false)
    messages.forgetStuckCover()
    messages.afterListenerCoverGone(announce: "listen_together_left_for_own_book".localized)
  }

  /// Ends Listen Together for this device. The sharer also tells everyone else it is over.
  func end() {
    if isPreparing, !isInSession {
      // Cancel: a session that arrives later is left, not started or offered.
      if let pendingShareID { cancelledShareIDs.insert(pendingShareID) }
      clearPendingShare()
      state = .idle
      return
    }
    if pendingInvitation != nil, !isInSession {
      declineInvitation()
      return
    }
    guard isInSession else { return }
    if let shareID { endedShareIDs.insert(shareID) }
    if role == .sharer, let transport {
      // Chunk sends stop before teardown deletes the share's files (fix round 1, Minor 1).
      transport.stopPieceTransfers()
      tearDown(reason: .normal, leaveTransport: false)
      // The end message gets a short time; then SharePlay is ended for everyone (transfer fix, item
      // 4) whatever happens, so a stalled messenger can't keep a session the UI already says has ended.
      // A short pause after the message lets it be handled before listeners see the session end.
      Task {
        await Self.withTimeLimit(Self.endMessageTimeout) {
          do {
            try await transport.send(.sessionEnding)
            try? await Task.sleep(for: Self.endAfterMessageDelay)
          } catch {
            Self.logger.error(
              "Listen Together: could not send the end message: \(ListenTogetherErrorDescription.describe(error), privacy: .public)")
          }
        }
        Self.logger.info("Listen Together: ending the group session for everyone")
        transport.end()
      }
    } else {
      tearDown(reason: .normal)
    }
  }

  /// Runs `work`, but returns after `limit` at the latest. The work is not awaited past the limit (a
  /// task group would wait for it), so a send that ignores cancellation can't hold the caller.
  static func withTimeLimit(_ limit: Duration, _ work: @escaping @MainActor () async -> Void) async {
    @MainActor final class Once {
      var continuation: CheckedContinuation<Void, Never>?
      var timer: Task<Void, Never>?
    }
    let once = Once()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      once.continuation = continuation
      let finish: @MainActor () -> Void = {
        once.timer?.cancel()
        once.continuation?.resume()
        once.continuation = nil
      }
      once.timer = Task { @MainActor in
        try? await Task.sleep(for: limit)
        finish()
      }
      Task { @MainActor in
        await work()
        finish()
      }
    }
  }

  // MARK: Teardown

  /// Stops playback, leaves the session, deletes this share's files and tells the person once.
  ///
  /// The person's own End: "Listen Together ended" (or `announcement`) is announced. Someone else
  /// ending it, or a book that couldn't be prepared: no announcement and no ended banner; after
  /// everything is cleared, the one message goes through `messages` (an alert shown after the listener
  /// cover has gone, guidance A.0). `announces: false` leaves the announcement to the caller.
  func tearDown(
    reason: ListenTogetherState.EndReason, announcement: String? = nil, announces: Bool = true,
    leaveTransport: Bool = true
  ) {
    guard isInSession else { return }
    // N1: a cover recorded for an earlier ending is never closed by this one.
    messages.forgetStuckCover()
    let transport = self.transport
    let shareID = self.shareID
    let wasListener = role == .listener
    role = nil
    eventLoop?.cancel()
    eventLoop = nil
    sharingTask?.cancel()
    sharingTask = nil
    outbox?.finish()
    outbox = nil
    outboxTask?.cancel()
    outboxTask = nil
    pieceScheduler = nil
    retryWaiter.wake()
    setKeepingScreenAwake(false)
    sendContext = nil
    isSendLoopRunning = false
    pieceFailures = [:]
    pieceDecodeFailures = [:]
    ownCopyFiles = [:]
    pendingPieceRequests = []
    lastStateAnswer = nil
    isStateAnswerPending = false
    isHeartbeatQueued = false
    lastSharerContact = nil
    isSharerSilent = false
    sharerMissingSince = nil
    sharerParticipantID = nil
    hasSeenOtherParticipants = false
    notice = nil
    isSharerGraceRunning = false
    isListenerWaitingForPiece = false
    isListenerPlaying = false
    isPausedByOther = false
    someoneDeclined = false
    localEventsBag.removeAll()
    bridge?.invalidate()
    bridge = nil
    listener?.stop()
    listener = nil
    joinedTitle = nil
    sharerTarget?.stop()
    sharerTarget = nil
    self.transport = nil
    activeSession = nil
    manifest = nil
    participantCount = 1
    hasParticipantBaseline = false
    uploadedPieceMessages = []
    pieceIndexByAttachment = [:]
    heldAttachments = [:]
    placedPieces = []
    announcedWaiting = false
    isUsingOwnCopy = false
    rosterIDs = []
    confirmedParticipantIDs = []
    declinedParticipantIDs = []
    isOwnersOnlySession = false
    pendingOwnCopyJoinedLine = false
    sharingFingerprint = nil
    self.shareID = nil
    if leaveTransport { transport?.leave() }
    if let shareID { storage.remove(shareID: shareID) }
    storage.removeIncoming()
    let message = ListenTogetherUserMessage.ending(for: reason, wasListener: wasListener)
    if announces, message == nil { announcer.announce(announcement ?? ListenTogetherAnnouncements.ended()) }
    Self.logger.info("Listen Together: session ended, reason=\(String(describing: reason), privacy: .public)")
    if wasListener, [.sharerEnded, .sharerLeft, .sharerCouldNotPrepare, .connectionEnded, .ownCopyFailed].contains(reason) {
      endNotice = reason
    }
    // Never offered or joined again in this app session. `.unavailable` has no share (it ends before
    // one starts), and an own End or Leave records it before tearing down.
    if [.sharerEnded, .sharerLeft, .sharerCouldNotPrepare, .prepareFailed, .connectionEnded, .ownCopyFailed]
      .contains(reason),
      let shareID
    {
      endedShareIDs.insert(shareID)
    }
    state = .ended(reason: reason)
    scheduleReturnToIdle()
    // Last, once the player, row and temporary copy are gone (A.0 order).
    if let message {
      messages.deliver(message) { [weak self] in
        guard let self, self.endNotice == reason else { return }
        self.acknowledgeEndNotice()
      }
    }
  }

  // MARK: Private

  enum IncomingSessionDecision: Equatable {
    /// The share this device is preparing.
    case ownShare
    /// A share this device cancelled while preparing: leave it.
    case cancelledShare
    /// Our sharing-sheet share that arrived after the wait, while this device is idle: start it.
    case lateOwnShare
    /// Our late sharing-sheet share, but something else is now pending or running: leave it, so its
    /// people are not left in a session nobody is sharing into.
    case staleOwnShare
    /// A share that already ended for this device: left silently, never offered again.
    case endedShare
    /// Someone else's share: offer it.
    case invitation
    /// Already in a session, preparing a share or offering one: ignore.
    case busy
  }

  /// What to do with a session that arrives. Removes a matched cancelled id. Test seam.
  func decision(forIncoming shareID: UUID) -> IncomingSessionDecision {
    if cancelledShareIDs.remove(shareID) != nil { return .cancelledShare }
    if endedShareIDs.contains(shareID) { return .endedShare }
    if shareID == pendingShareID, pendingItem != nil { return .ownShare }
    if lateShare?.id == shareID {
      return isInSession || isPreparing || pendingInvitation != nil ? .staleOwnShare : .lateOwnShare
    }
    // While this device prepares its own share, someone else's is not offered on top of it.
    return isInSession || isPreparing || pendingInvitation != nil ? .busy : .invitation
  }

  enum IncomingSessionAction {
    case leave
    case ignore
    case offer
    /// Our own share: start sharing `item`. `late` when it arrived after the sharing sheet's wait.
    case share(PlayableItem, late: Bool)
  }

  /// What `received` does with a session, claiming our own share. Test seam (no GroupSession needed).
  func action(forIncoming shareID: UUID) -> IncomingSessionAction {
    switch decision(forIncoming: shareID) {
    case .cancelledShare, .endedShare:
      return .leave
    case .staleOwnShare:
      lateShare = nil
      return .leave
    case .busy:
      return .ignore
    case .invitation:
      return .offer
    case .ownShare:
      guard let item = claimOwnShare(shareID) else { return .ignore }
      return .share(item, late: false)
    case .lateOwnShare:
      guard let item = lateShare?.item else { return .ignore }
      lateShare = nil
      return .share(item, late: true)
    }
  }

  private func received(_ session: GroupSession<ListenTogetherActivity>) {
    let shareID = session.activity.shareID
    let item: PlayableItem
    let late: Bool
    switch action(forIncoming: shareID) {
    case .leave:
      session.leave()
      return
    case .ignore:
      return
    case .offer:
      offerInvitation(session)
      return
    case let .share(sharedItem, isLate):
      item = sharedItem
      late = isLate
    }
    // Our own session: start sharing.
    let folder: URL
    do {
      folder = try storage.folder(for: shareID, role: .sharer)
    } catch {
      Self.logger.error("Listen Together: could not create the share folder: \(error.localizedDescription)")
      session.leave()
      endUnavailable()
      return
    }
    let transport = transportFactory(session, folder)
    activeSession = session
    session.join()
    // A-I2: the session's bookkeeping happens in this turn; only the export and upload are async.
    guard startSharingSession(
      with: transport, item: item, shareID: shareID, ownersOnly: session.activity.isOwnersOnly,
      fingerprint: session.activity.fingerprint)
    else {
      activeSession = nil
      transport.leave()
      return
    }
    if let text = startedAnnouncement(forShare: shareID, late: late) { announcer.announce(text) }
    sharingTask = Task { await self.uploadPieces(of: item, shareID: shareID, over: transport) }
  }

  /// What is said when our own session arrives: "Listen Together started" after the sharing sheet
  /// (the sheet itself gives no confirmation, and a late session follows "didn't start"); nothing on a
  /// FaceTime call, where the system shows SharePlay starting. Said once either way. Test seam.
  func startedAnnouncement(forShare shareID: UUID, late: Bool) -> String? {
    guard late || shareID == latestSheetShareID else { return nil }
    return "listen_together_started_late_announcement".localized
  }

  /// Someone else's share arrived. Their copy check runs first (at most `ownCopyCheckLimit`), so the
  /// invitation is shown once, with the right words, or not at all (owners-only and no copy).
  private func offerInvitation(_ session: GroupSession<ListenTogetherActivity>) {
    pendingInvitation = session
    let details = ListenTogetherInvitationDetails(activity: session.activity)
    let decline = Self.decline(for: session)
    invitationCheckTask = Task { [weak self, weak session] in
      await self?.prepareInvitation(
        details,
        isCurrent: { [weak self, weak session] in
          guard let self, let session else { return false }
          return self.pendingInvitation === session
        },
        decline: decline)
    }
    // If the session goes away before the user answers, drop the invitation.
    session.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak session] newState in
        MainActor.assumeIsolated {
          guard let self, let session, self.pendingInvitation === session,
            case .invalidated = newState
          else { return }
          self.clearInvitation()
          self.state = .idle
        }
      }
      .store(in: &invitationBag)
  }

  /// Looks for the listener's own copy, then shows the invitation (cases A and B) or declines it with
  /// the "You need your own copy" alert (case C). `isCurrent` is false once the invitation was
  /// answered or went away during the check. Test seam (no GroupSession needed).
  func prepareInvitation(
    _ details: ListenTogetherInvitationDetails, isCurrent: @MainActor () -> Bool = { true },
    decline: ListenTogetherPendingDecline? = nil
  ) async {
    pendingInvitationDetails = details
    pendingInvitationDecline = decline
    let check = await checkOwnCopy(for: details.fingerprint)
    guard isCurrent(), pendingInvitationDetails?.shareID == details.shareID else { return }
    // Code M3: this device started its own share (or joined one) during the check. The invitation is
    // left, so it neither covers "Preparing" nor blocks every later invitation.
    guard !isInSession, !isPreparing else {
      pendingInvitationDecline?.abandon()
      clearInvitation()
      return
    }
    let ownCopy = check.copy
    switch ListenTogetherInvitationKind.decide(hasOwnCopy: ownCopy != nil, ownersOnly: details.ownersOnly) {
    case .ownCopy, .sendCopy:
      invitationOwnCopy = ownCopy
      showInvitation(title: details.title, author: details.author)
    case .needsOwnCopy:
      // No invitation sheet and no invitation announcement: the alert is the only speech. A check that
      // ran out of time doesn't claim the book is missing (code M2).
      declineWithoutCopy(bookTitle: details.title, cause: check == .timedOut ? .checkTimedOut : .notFound)
    }
  }

  enum OwnCopyCheck: Equatable {
    case found(ListenTogetherOwnCopy)
    case notFound
    case timedOut

    var copy: ListenTogetherOwnCopy? {
      if case .found(let copy) = self { return copy }
      return nil
    }
  }

  /// The own-copy check, limited to `ownCopyCheckLimit`.
  private func checkOwnCopy(for fingerprint: BookFingerprint?) async -> OwnCopyCheck {
    guard let fingerprint, let finder = ownCopyFinder else { return .notFound }
    let result = await ListenTogetherFirstResult.value(within: ownCopyCheckLimit) { () -> OwnCopyCheck in
      guard let copy = await finder.findOwnCopy(matching: fingerprint) else { return .notFound }
      return .found(copy)
    }
    return result ?? .timedOut
  }

  /// Shows the invitation and announces it (queued), so a VoiceOver user hears it whatever is on
  /// screen. Test seam.
  func showInvitation(title: String, author: String) {
    // A queued alert about an earlier session is no longer relevant (A.4).
    messages.dropPendingAlerts()
    state = .invitation(title: title, author: author)
    announcer.announce(ListenTogetherAnnouncements.invitation(title: title, author: author))
  }

  private func clearPendingShare() {
    pendingShareID = nil
    pendingItem = nil
  }

  /// Listen Together could not start (SharePlay unavailable or no folder for the files). A centred
  /// alert (E12, R41): seen as well as heard, never a timed banner. Internal for tests.
  func endUnavailable() {
    messages.deliver(.unavailable)
    state = .ended(reason: .unavailable)
    scheduleReturnToIdle()
  }

  /// After 3 seconds the ended banner goes away, unless something else happened meanwhile.
  private func scheduleReturnToIdle() {
    endedGeneration += 1
    let generation = endedGeneration
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard let self, self.endedGeneration == generation, case .ended = self.state else { return }
      self.state = .idle
    }
  }
}

/// What a listener knows about an incoming share before joining: everything comes from the activity.
struct ListenTogetherInvitationDetails: Equatable {
  let shareID: UUID
  let title: String
  let author: String
  let fingerprint: BookFingerprint?
  let ownersOnly: Bool

  init(shareID: UUID, title: String, author: String, fingerprint: BookFingerprint?, ownersOnly: Bool) {
    self.shareID = shareID
    self.title = title
    self.author = author
    self.fingerprint = fingerprint
    self.ownersOnly = ownersOnly
  }

  init(activity: ListenTogetherActivity) {
    self.init(
      shareID: activity.shareID, title: activity.title, author: activity.author,
      fingerprint: activity.fingerprint, ownersOnly: activity.isOwnersOnly)
  }
}

/// Runs `work` and returns its result, or nil once `limit` has passed (the work is then cancelled).
@MainActor
final class ListenTogetherFirstResult<Value> {
  private var continuation: CheckedContinuation<Value?, Never>?
  private var tasks: [Task<Void, Never>] = []

  static func value(within limit: Duration, _ work: @escaping @MainActor () async -> Value) async -> Value? {
    let race = ListenTogetherFirstResult<Value>()
    return await withCheckedContinuation { continuation in
      race.continuation = continuation
      race.tasks.append(Task { @MainActor in
        let value = await work()
        race.finish(value)
      })
      race.tasks.append(Task { @MainActor in
        try? await Task.sleep(for: limit)
        race.finish(nil)
      })
    }
  }

  private func finish(_ value: Value?) {
    guard let continuation else { return }
    self.continuation = nil
    tasks.forEach { $0.cancel() }
    tasks = []
    continuation.resume(returning: value)
  }
}
