import BookPlayerKit
import Combine
import Foundation
import GroupActivities

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
    case sendFailed
    case unavailable
  }
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

  // Collaborators. Internal (not private) so SharePlaySessionService+Session.swift can use them.
  let playerManager: PlayerManagerProtocol
  let storage: ShareStorage
  let announcer: ListenTogetherAnnouncer
  let transportFactory: @MainActor (GroupSession<ListenTogetherActivity>, URL) -> ListenTogetherTransport
  /// Remembers, per device, that the first-share note was seen.
  let defaults: UserDefaults
  static let firstShareNoteSeenKey = "listenTogetherFirstShareNoteSeen"
  /// Pause between upload attempts. Test seam.
  var uploadRetryDelay: Duration = .seconds(1)
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
  /// The sharer's end message gets this long before the session is left anyway.
  static let endMessageTimeout: Duration = .seconds(2)

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
  var localEventsBag = Set<AnyCancellable>()
  var eventLoop: Task<Void, Never>?
  /// Sharer: the export and upload pipeline. Cancelled by `tearDown`, so no export keeps running after End.
  var sharingTask: Task<Void, Never>?
  /// The user's own actions, sent one after another in the order they happened (one consumer).
  var outbox: AsyncStream<ListenTogetherMessage>.Continuation?
  var outboxTask: Task<Void, Never>?

  // SharePlay plumbing.
  private var observeTask: Task<Void, Never>?
  /// The real GroupSession behind the current transport, if any (never set in tests).
  var activeSession: GroupSession<ListenTogetherActivity>?
  private var pendingShareID: UUID?
  private var pendingItem: PlayableItem?
  private var pendingInvitation: GroupSession<ListenTogetherActivity>?
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
    transportFactory: @escaping @MainActor (GroupSession<ListenTogetherActivity>, URL) -> ListenTogetherTransport
      = { GroupSessionTransport(session: $0, downloadFolder: $1) }
  ) {
    self.playerManager = playerManager
    self.storage = storage
    // Built here rather than as a default argument, which would run outside the main actor.
    self.announcer = announcer ?? ListenTogetherAnnouncer()
    self.transportFactory = transportFactory
    self.defaults = defaults
    let groupStateObserver = GroupStateObserver()
    self.isEligibleForGroupSession = { groupStateObserver.isEligibleForGroupSession }
  }

  var isInSession: Bool { role != nil }
  /// True while this device listens to someone else's share (from Join until the session ends).
  var isListenerSession: Bool { role == .listener }

  /// Setters for SharePlaySessionService+Session.swift; the published properties stay read-only elsewhere.
  func setState(_ newState: ListenTogetherState) { state = newState }
  func setListener(_ player: ListenerPlayer?) { listener = player }

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
    let activity = ListenTogetherActivity(shareID: shareID, title: item.title, author: item.author)

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
    let activity = ListenTogetherActivity(shareID: shareID, title: item.title, author: item.author)
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
    announceSheetResult("listen_together_cancelled_announcement".localized, for: shareID)
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
    announceSheetResult("listen_together_didnt_start_announcement".localized, for: shareID)
  }

  /// Announced after the sheet's screen change has settled, and only if nothing has happened since: no
  /// newer share, nothing pending, no session, no invitation on screen. A locked phone may not speak it
  /// (the guide says so).
  private func announceSheetResult(_ text: String, for shareID: UUID) {
    schedule(Self.sheetAnnouncementDelay) { [weak self] in
      guard let self, self.latestSheetShareID == shareID, self.pendingShareID == nil, !self.isInSession,
        self.pendingInvitation == nil, !self.isShowingInvitation
      else { return }
      self.announcer.announce(text)
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

  func joinInvitation() {
    guard let session = pendingInvitation, !isInSession else { return }
    pendingInvitation = nil
    invitationBag.removeAll()
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
    activeSession = session
    session.join()
    // A-I2: set up in the same main-actor turn as the join, so End (or a second invitation) can never
    // fall into a gap where the session is joined but this device is not yet listening.
    if !startListening(with: transport, shareID: shareID) {
      activeSession = nil
      joinedTitle = nil
      transport.leave()
    }
  }

  /// Does nothing unless an invitation is waiting.
  func declineInvitation() {
    guard pendingInvitation != nil else { return }
    pendingInvitation?.leave()
    pendingInvitation = nil
    invitationBag.removeAll()
    state = .idle
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
    if role == .sharer, let transport {
      tearDown(reason: .normal, leaveTransport: false)
      // The end message gets a short time; the session is left whatever happens, so a stalled
      // messenger can't keep this device in a session the UI already says has ended.
      Task {
        await Self.withTimeLimit(Self.endMessageTimeout) {
          do {
            try await transport.send(.sessionEnding)
          } catch {
            Self.logger.error("Listen Together: could not send the end message: \(error.localizedDescription)")
          }
        }
        transport.leave()
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

  /// Stops playback, leaves the session, deletes this share's files and announces the end.
  func tearDown(reason: ListenTogetherState.EndReason, announcement: String? = nil, leaveTransport: Bool = true) {
    guard isInSession else { return }
    let transport = self.transport
    let shareID = self.shareID
    role = nil
    eventLoop?.cancel()
    eventLoop = nil
    sharingTask?.cancel()
    sharingTask = nil
    outbox?.finish()
    outbox = nil
    outboxTask?.cancel()
    outboxTask = nil
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
    self.shareID = nil
    if leaveTransport { transport?.leave() }
    if let shareID { storage.remove(shareID: shareID) }
    announcer.announce(announcement ?? ListenTogetherAnnouncements.ended())
    state = .ended(reason: reason)
    scheduleReturnToIdle()
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
    /// Someone else's share: offer it.
    case invitation
    /// Already in a session, preparing a share or offering one: ignore.
    case busy
  }

  /// What to do with a session that arrives. Removes a matched cancelled id. Test seam.
  func decision(forIncoming shareID: UUID) -> IncomingSessionDecision {
    if cancelledShareIDs.remove(shareID) != nil { return .cancelledShare }
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
    case .cancelledShare:
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
    guard startSharingSession(with: transport, item: item, shareID: shareID) else {
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

  private func offerInvitation(_ session: GroupSession<ListenTogetherActivity>) {
    pendingInvitation = session
    showInvitation(title: session.activity.title, author: session.activity.author)
    // If the session goes away before the user answers, drop the invitation.
    session.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak session] newState in
        MainActor.assumeIsolated {
          guard let self, let session, self.pendingInvitation === session,
            case .invalidated = newState
          else { return }
          self.pendingInvitation = nil
          self.invitationBag.removeAll()
          self.state = .idle
        }
      }
      .store(in: &invitationBag)
  }

  /// Shows the invitation and announces it (queued), so a VoiceOver user hears it whatever is on
  /// screen. Test seam.
  func showInvitation(title: String, author: String) {
    state = .invitation(title: title, author: author)
    announcer.announce(ListenTogetherAnnouncements.invitation(title: title, author: author))
  }

  private func clearPendingShare() {
    pendingShareID = nil
    pendingItem = nil
  }

  /// Listen Together could not start (SharePlay unavailable or no folder for the files). Announced,
  /// because otherwise a VoiceOver user hears nothing. Internal for tests.
  func endUnavailable() {
    announcer.announce("listen_together_unavailable".localized)
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
