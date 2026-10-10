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
  @Published private(set) var showsFirstShareNote = false

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

  // SharePlay plumbing.
  private let groupStateObserver = GroupStateObserver()
  private var observeTask: Task<Void, Never>?
  /// The real GroupSession behind the current transport, if any (never set in tests).
  var activeSession: GroupSession<ListenTogetherActivity>?
  private var pendingShareID: UUID?
  private var pendingItem: PlayableItem?
  private var pendingInvitation: GroupSession<ListenTogetherActivity>?
  /// Shares cancelled while preparing. If `activate()` was already in flight, their session can
  /// still arrive; it is left, never offered as an invitation. Each id is removed once seen.
  private var cancelledShareIDs = Set<UUID>()
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
  }

  var isInSession: Bool { role != nil }

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
    guard canShare(item), !isInSession, !isPreparing, pendingInvitation == nil else { return false }
    switch state {
    case .idle, .needsFaceTime, .ended: return true
    case .preparing, .invitation, .sharing, .listening: return false
    }
  }

  /// True while someone else's share is waiting for Join or Not Now.
  var hasPendingInvitation: Bool { pendingInvitation != nil }

  /// The needs-FaceTime alert was dismissed.
  func acknowledgeNeedsFaceTime() {
    guard state == .needsFaceTime else { return }
    state = .idle
  }

  /// A second call while one share is still being prepared is ignored.
  func startSharing(_ item: PlayableItem) async {
    guard !isInSession, !isPreparing else { return }
    guard groupStateObserver.isEligibleForGroupSession else {
      state = .needsFaceTime
      return
    }
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

  // MARK: First-share note

  /// Sharing has started: the first time on this device, the sharer is told that people who join can
  /// only listen. Internal for tests and SharePlaySessionService+Session.swift.
  func sharingStarted() {
    guard !defaults.bool(forKey: Self.firstShareNoteSeenKey) else { return }
    showsFirstShareNote = true
  }

  /// The note was read and dismissed: never shown again on this device.
  func acknowledgeFirstShareNote() {
    guard showsFirstShareNote else { return }
    showsFirstShareNote = false
    defaults.set(true, forKey: Self.firstShareNoteSeenKey)
  }

  /// True from `startSharing` until our session arrives or the share is cancelled.
  var isPreparing: Bool { pendingShareID != nil }

  /// Records the share being prepared and shows `.preparing`. Returns nil if one is already
  /// being prepared or a session is active. Test seam (no GroupSession needed).
  func beginPreparing(_ item: PlayableItem) -> UUID? {
    guard !isInSession, !isPreparing else { return nil }
    let shareID = UUID()
    pendingShareID = shareID
    pendingItem = item
    state = .preparing(title: item.title)
    return shareID
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
    Task { await self.beginListening(with: transport, shareID: shareID) }
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
      Task {
        do {
          try await transport.send(.sessionEnding)
        } catch {
          Self.logger.error("Listen Together: could not send the end message: \(error.localizedDescription)")
        }
        transport.leave()
      }
    } else {
      tearDown(reason: .normal)
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
    localEventsBag.removeAll()
    bridge?.invalidate()
    bridge = nil
    listener?.stop()
    listener = nil
    joinedTitle = nil
    // Not seen before the session ended: shown at the next share instead.
    showsFirstShareNote = false
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
    /// Someone else's share: offer it.
    case invitation
    /// Already in a session, preparing a share or offering one: ignore.
    case busy
  }

  /// What to do with a session that arrives. Removes a matched cancelled id. Test seam.
  func decision(forIncoming shareID: UUID) -> IncomingSessionDecision {
    if cancelledShareIDs.remove(shareID) != nil { return .cancelledShare }
    if shareID == pendingShareID, pendingItem != nil { return .ownShare }
    // While this device prepares its own share, someone else's is not offered on top of it.
    return isInSession || isPreparing || pendingInvitation != nil ? .busy : .invitation
  }

  private func received(_ session: GroupSession<ListenTogetherActivity>) {
    switch decision(forIncoming: session.activity.shareID) {
    case .cancelledShare:
      session.leave()
      return
    case .busy:
      return
    case .invitation:
      offerInvitation(session)
      return
    case .ownShare:
      break
    }
    // Our own session: start sharing.
    guard let pendingShareID, let item = pendingItem else { return }
    clearPendingShare()
    let folder: URL
    do {
      folder = try storage.folder(for: pendingShareID, role: .sharer)
    } catch {
      Self.logger.error("Listen Together: could not create the share folder: \(error.localizedDescription)")
      session.leave()
      endUnavailable()
      return
    }
    let transport = transportFactory(session, folder)
    activeSession = session
    session.join()
    Task { await self.beginSharing(with: transport, item: item, shareID: pendingShareID) }
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
