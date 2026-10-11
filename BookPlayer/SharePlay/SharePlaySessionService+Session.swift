import BookPlayerKit
import Combine
import Foundation

/// The running session: the sharer's export and upload pipeline, the transport event loop for both
/// roles, receiving pieces, and turning local playback events into messages for everyone else.
extension SharePlaySessionService {
  // MARK: Sharer

  /// Test seam: shares `item` over `transport` without a real GroupSession.
  func beginSharing(with transport: ListenTogetherTransport, item: PlayableItem, ownersOnly: Bool = false) async {
    await beginSharing(with: transport, item: item, shareID: UUID(), ownersOnly: ownersOnly)
  }

  /// Sets up the session and then sends the manifest, exports and uploads every piece starting where
  /// the sharer is listening. Returns when every piece is uploaded or the session has ended.
  func beginSharing(
    with transport: ListenTogetherTransport, item: PlayableItem, shareID: UUID, ownersOnly: Bool = false
  ) async {
    guard startSharingSession(with: transport, item: item, shareID: shareID, ownersOnly: ownersOnly)
    else { return }
    await uploadPieces(of: item, shareID: shareID, over: transport)
  }

  /// The sharer's session bookkeeping, done synchronously in the same main-actor turn as the join
  /// (A-I2): role, transport, event loop, playback target, coordinator and local events. Returns false
  /// (and changes nothing) if a session is already running; the caller then leaves `transport`.
  @discardableResult
  func startSharingSession(
    with transport: ListenTogetherTransport, item: PlayableItem, shareID: UUID, ownersOnly: Bool = false,
    fingerprint: BookFingerprint? = nil
  ) -> Bool {
    guard !isInSession else { return false }
    role = .sharer
    self.shareID = shareID
    self.transport = transport
    isOwnersOnlySession = ownersOnly
    sharingFingerprint = fingerprint
    resetRoster()
    startEventLoop(on: transport)
    startOutbox(on: transport)

    let target = SharerPlaybackTarget(playerManager: playerManager)
    sharerTarget = target
    let bridge = ListenTogetherCoordinatorBridge(target: target, shareID: shareID, role: .sharer)
    self.bridge = bridge
    if let activeSession { bridge.coordinate(with: activeSession) }
    observeLocalEvents(of: target)
    return true
  }

  /// Sends the manifest, then exports and uploads the pieces. Stops as soon as the session ends or the
  /// task is cancelled (`tearDown` cancels `sharingTask`).
  ///
  /// With "Send it for this session", every piece is uploaded even if everyone so far has their own
  /// copy: the journal keeps them for anyone who joins later without one (who would otherwise wait for
  /// a late export), and listeners with their own copy never load them. "Only people who have the book
  /// can join" uploads nothing; the manifest has no pieces.
  func uploadPieces(of item: PlayableItem, shareID: UUID, over transport: ListenTogetherTransport) async {
    guard self.transport === transport else { return }
    let splitter = BookSplitter()
    let files: [SourceFile]
    let folder: URL
    do {
      files = try splitter.sourceFiles(for: item)
      folder = try storage.folder(for: shareID, role: .sharer)
    } catch {
      Self.logger.error("Listen Together: could not prepare the book: \(error.localizedDescription)")
      await failSharing(on: transport)
      return
    }
    let plan = isOwnersOnlySession ? [] : PiecePlanner.plan(files: files, chapterStarts: item.chapters.map(\.start))
    let manifest = SharedBookManifest(
      shareID: shareID,
      title: item.title,
      author: item.author,
      duration: item.duration,
      chapters: item.chapters.sorted { $0.start < $1.start }.map {
        SharedChapter(title: $0.title, start: $0.start, duration: $0.duration)
      },
      // Planner estimates until exported; listeners only use sizes for progress.
      pieces: plan.map {
        SharedPiece(index: $0.index, bookStart: $0.bookStart, duration: $0.duration, byteSize: $0.estimatedBytes)
      },
      fingerprint: sharingFingerprint)
    self.manifest = manifest
    setState(.sharing(participants: participantCount))
    await send(.manifest(manifest), on: transport)

    for piece in plan.uploadOrder(startingAt: item.currentTime) {
      guard self.transport === transport, !Task.isCancelled else { return }
      guard let attachmentID = await exportAndUpload(piece, from: files, to: folder, on: transport) else {
        guard self.transport === transport else { return }
        await failSharing(on: transport)
        return
      }
      guard self.transport === transport else { return }
      let message = ListenTogetherMessage.pieceUploaded(index: piece.index, attachmentID: attachmentID)
      uploadedPieceMessages.append(message)
      await send(message, on: transport)
    }
  }

  /// Up to three attempts. Returns nil when every attempt failed or the session ended meanwhile.
  private func exportAndUpload(
    _ piece: PlannedPiece, from files: [SourceFile], to folder: URL, on transport: ListenTogetherTransport
  ) async -> UUID? {
    for attempt in 1...3 {
      guard self.transport === transport, !Task.isCancelled else { return nil }
      do {
        let exported = try await BookSplitter().export(piece, from: files, to: folder)
        guard self.transport === transport else { return nil }
        return try await transport.upload(fileAt: exported.url)
      } catch {
        Self.logger.error(
          "Listen Together: piece \(piece.index) attempt \(attempt) failed: \(error.localizedDescription)")
        if attempt < 3 { try? await Task.sleep(for: uploadRetryDelay) }
      }
    }
    return nil
  }

  private func failSharing(on transport: ListenTogetherTransport) async {
    await send(.sessionEnding, on: transport)
    tearDown(reason: .sendFailed, announcement: "listen_together_send_failed".localized)
  }

  // MARK: Listener

  /// Test seam: listens to the share `shareID` over `transport`.
  func beginListening(with transport: ListenTogetherTransport, shareID: UUID) async {
    startListening(with: transport, shareID: shareID)
  }

  /// Listens to the share `shareID` over `transport`. Synchronous, so `joinInvitation()` sets it up in
  /// the same main-actor turn as the join (A-I2). Returns false (and changes nothing) if a session is
  /// already running; the caller then leaves `transport`.
  ///
  /// With `ownCopy` (addendum 2) the listener plays its own files: the player is built at once from
  /// them (already-arrived pieces on the shared timeline), so there is no "getting the book" screen,
  /// nothing is downloaded and the state is complete from the start (no percent). One announcement,
  /// "Joined. Playing your copy.", once the screen change has settled. The library is only read: the
  /// copy's progress, bookmarks and last-played date are never written by the session.
  @discardableResult
  func startListening(
    with transport: ListenTogetherTransport, shareID: UUID, ownCopy: ListenTogetherOwnCopy? = nil,
    title: String = "", author: String = "", shared: BookFingerprint? = nil, ownersOnly: Bool = false
  ) -> Bool {
    guard !isInSession else { return false }
    role = .listener
    self.shareID = shareID
    self.transport = transport
    isOwnersOnlySession = ownersOnly
    resetRoster()
    announcer.resetDownloadProgress()
    guard let ownCopy else {
      setState(.listening(participants: participantCount, downloaded: 0))
      startEventLoop(on: transport)
      startOutbox(on: transport)
      return true
    }
    transport.stopReceivingPieces()
    setOwnCopy(true)
    setState(.listening(participants: participantCount, downloaded: 1))
    startEventLoop(on: transport)
    startOutbox(on: transport)
    let manifest = ownCopy.manifest(shareID: shareID, title: title, author: author, shared: shared)
    var urls: [Int: URL] = [:]
    for (index, file) in ownCopy.files.enumerated() { urls[index] = file.url }
    installListener(manifest: manifest, arrivedFiles: urls)
    // Said after the player's title has focus (`listenerTitleFocused`), or after a fallback delay.
    pendingOwnCopyJoinedLine = true
    schedule(Self.ownCopyJoinedFallbackDelay) { [weak self] in self?.announceOwnCopyJoined(on: transport) }
    return true
  }

  private func receivedManifest(_ manifest: SharedBookManifest) {
    // Later copies (re-sent for late joiners) keep the existing player; a listener with their own
    // copy already has one from Join.
    guard role == .listener, listener == nil, manifest.shareID == shareID else { return }
    installListener(manifest: manifest)
  }

  /// Builds the listener's player for `manifest`. `arrivedFiles` (own copy) are pieces that are
  /// already here: own library files, played in place and never moved, copied or deleted.
  private func installListener(manifest: SharedBookManifest, arrivedFiles: [Int: URL] = [:]) {
    self.manifest = manifest
    let player = ListenerPlayer(manifest: manifest)
    for (index, url) in arrivedFiles.sorted(by: { $0.key < $1.key }) { player.pieceArrived(index: index, url: url) }
    let bridge = ListenTogetherCoordinatorBridge(target: player, shareID: manifest.shareID, role: .listener)
    player.onNeedsPiece = { [weak self] _ in self?.listenerNeedsPiece() }
    // Play or pause while the group waits for this device's piece: nothing is sent; say why.
    player.onToggleWhileWaiting = { [weak self] in
      guard let self, self.waitingToggleLimiter.allows(at: Date()) else { return }
      self.announcer.announce("listen_together_waiting_download".localized)
    }
    self.bridge = bridge
    setListener(player)
    if let activeSession { bridge.coordinate(with: activeSession) }
    observeLocalEvents(of: player)
    // Pieces that arrived before the manifest.
    for (attachmentID, index) in pieceIndexByAttachment {
      if let url = heldAttachments.removeValue(forKey: attachmentID) { place(index: index, url: url) }
    }
    updateListeningState()
  }

  private func listenerNeedsPiece() {
    bridge?.waitForPiece()
    guard !announcedWaiting else { return }
    announcedWaiting = true
    announcer.announce("listen_together_waiting_download".localized)
  }

  private func pieceUploaded(index: Int, attachmentID: UUID) {
    guard role == .listener, !isUsingOwnCopy else { return }
    pieceIndexByAttachment[attachmentID] = index
    if listener != nil, let url = heldAttachments.removeValue(forKey: attachmentID) {
      place(index: index, url: url)
    }
  }

  private func attachmentReceived(id: UUID, url: URL) {
    // A listener with their own copy never downloads (the transport stops loading pieces); anything
    // that still arrives stays in the session folder, which teardown deletes.
    guard role == .listener, !isUsingOwnCopy else { return }
    if listener != nil, let index = pieceIndexByAttachment[id] {
      place(index: index, url: url)
    } else {
      heldAttachments[id] = url
    }
  }

  /// Moves a received file into the listener folder and hands it to the player.
  private func place(index: Int, url: URL) {
    guard let listener, let shareID, !placedPieces.contains(index) else { return }
    let destination: URL
    do {
      let folder = try storage.folder(for: shareID, role: .listener)
      let pathExtension = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
      destination = folder.appendingPathComponent(String(format: "piece-%03d.%@", index, pathExtension))
      if destination != url {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: url, to: destination)
      }
    } catch {
      Self.logger.error("Listen Together: could not store piece \(index): \(error.localizedDescription)")
      return
    }
    placedPieces.insert(index)
    listener.pieceArrived(index: index, url: destination)
    if listener.isReady(at: listener.bookTime) { announcedWaiting = false }
    bridge?.pieceBecameAvailable()
    announcer.announceDownload(fraction: listener.timeline.arrivedFraction)
    updateListeningState()
  }

  private func updateListeningState() {
    guard role == .listener else { return }
    let downloaded = isUsingOwnCopy ? 1 : (listener?.timeline.arrivedFraction ?? 0)
    setState(.listening(participants: participantCount, downloaded: downloaded))
  }

  // MARK: Both roles

  private func startEventLoop(on transport: ListenTogetherTransport) {
    eventLoop = Task { [weak self] in
      for await event in transport.events {
        guard let self, self.transport === transport else { return }
        await self.handle(event, from: transport)
      }
      // The stream ended without an explicit end message: the session is over.
      guard let self, self.transport === transport else { return }
      self.tearDown(reason: .normal)
    }
  }

  private func handle(_ event: TransportEvent, from transport: ListenTogetherTransport) async {
    switch event {
    case .message(.manifest(let manifest)):
      receivedManifest(manifest)
    case .message(.pieceUploaded(let index, let attachmentID)):
      pieceUploaded(index: index, attachmentID: attachmentID)
    case .attachmentReceived(let id, let url):
      attachmentReceived(id: id, url: url)
    case .message(.action(let action)):
      announcer.announce(ListenTogetherAnnouncements.text(for: action))
      if let target = playbackTarget, let rate = Self.silentRate(for: action, target: target) {
        target.applyRate(rate)
      }
    case .message(.sessionEnding), .invalidated:
      tearDown(reason: .normal)
    case .participantsChanged(let count, let ids):
      if ids.isEmpty {
        await participantsChanged(to: count, on: transport)
      } else {
        await rosterChanged(to: ids, on: transport)
      }
    case .participantDeclined(let id):
      participantDeclined(id)
    case .message(.declinedNoCopy):
      // The transport reports it as `.participantDeclined`; a bare message has no sender.
      participantDeclined(nil)
    }
  }

  func resetRoster() {
    participantCount = 1
    hasParticipantBaseline = false
    rosterIDs = []
    confirmedParticipantIDs = []
    declinedParticipantIDs = []
  }

  /// Someone couldn't join an owners-only share (no copy). They are never counted, and their brief
  /// join and leave are never announced. The sharer hears one queued line, coalesced to one per
  /// 10 seconds; listeners hear nothing. Nothing says who it was or what they own.
  private func participantDeclined(_ id: UUID?) {
    guard role != nil else { return }
    if let id {
      declinedParticipantIDs.insert(id)
      if confirmedParticipantIDs.remove(id) != nil { applyParticipantCount(confirmedParticipantIDs.count) }
    }
    guard role == .sharer, declineAnnouncementLimiter.allows(at: now()) else { return }
    announcer.announce("listen_together_declined_no_copy".localized)
  }

  /// The roster by id. The first one is the baseline. Someone new is counted and announced only after
  /// `joinConfirmationDelay`, if still here and not declined; someone counted who leaves is announced.
  /// The sharer re-sends the manifest and piece map to anyone new at once.
  private func rosterChanged(to ids: Set<UUID>, on transport: ListenTogetherTransport) async {
    guard role != nil else { return }
    guard hasParticipantBaseline else {
      hasParticipantBaseline = true
      rosterIDs = ids
      confirmedParticipantIDs = ids.subtracting(declinedParticipantIDs)
      applyParticipantCount(confirmedParticipantIDs.count)
      return
    }
    let arrived = ids.subtracting(rosterIDs)
    let gone = rosterIDs.subtracting(ids)
    rosterIDs = ids
    declinedParticipantIDs.subtract(gone)
    let countedLeft = !gone.isDisjoint(with: confirmedParticipantIDs)
    confirmedParticipantIDs.subtract(gone)
    applyParticipantCount(confirmedParticipantIDs.count)
    if countedLeft { announcer.announce(ListenTogetherAnnouncements.left()) }
    guard !arrived.isEmpty else { return }
    if isOwnersOnlySession {
      schedule(Self.joinConfirmationDelay) { [weak self] in self?.confirmArrivals(arrived, on: transport) }
    } else {
      confirmArrivals(arrived, on: transport)
    }
    if role == .sharer { await resendForLateJoiners(on: transport) }
  }

  private func confirmArrivals(_ ids: Set<UUID>, on transport: ListenTogetherTransport) {
    guard self.transport === transport, role != nil else { return }
    let stayed = ids.intersection(rosterIDs).subtracting(declinedParticipantIDs).subtracting(confirmedParticipantIDs)
    guard !stayed.isEmpty else { return }
    confirmedParticipantIDs.formUnion(stayed)
    applyParticipantCount(confirmedParticipantIDs.count)
    announcer.announce(ListenTogetherAnnouncements.joined())
  }

  private func applyParticipantCount(_ count: Int) {
    participantCount = max(count, 1)
    switch role {
    case .sharer: setState(.sharing(participants: participantCount))
    case .listener: updateListeningState()
    case nil: break
    }
  }

  /// Late joiners get journal attachments automatically, but not earlier messages: re-send the
  /// manifest and the piece map. Nothing is uploaded again.
  private func resendForLateJoiners(on transport: ListenTogetherTransport) async {
    guard role == .sharer, let manifest else { return }
    await send(.manifest(manifest), on: transport)
    for message in uploadedPieceMessages {
      guard self.transport === transport else { return }
      await send(message, on: transport)
    }
  }

  /// Roster changes reported as a count only (no ids).
  private func participantsChanged(to count: Int, on transport: ListenTogetherTransport) async {
    // A roster with nobody in it (not even us) is not a real change.
    guard count > 0, role != nil else { return }
    let previous = participantCount
    participantCount = count
    switch role {
    case .sharer: setState(.sharing(participants: count))
    default: updateListeningState()
    }
    // The publisher reports the current roster on subscribe: that only sets the baseline.
    guard hasParticipantBaseline else {
      hasParticipantBaseline = true
      return
    }
    if count > previous {
      announcer.announce(ListenTogetherAnnouncements.joined())
      await resendForLateJoiners(on: transport)
    } else if count < previous {
      announcer.announce(ListenTogetherAnnouncements.left())
    }
  }

  /// This device's playback target in the current session, whichever role it has.
  var playbackTarget: ListenTogetherPlaybackTarget? {
    if let listener { return listener }
    return sharerTarget
  }

  /// A speed change is coordinated only while playing (the play command carries the rate). Made while
  /// paused, it only arrives as an announcement: returns the rate to set silently then, else nil.
  static func silentRate(for action: RemoteAction, target: ListenTogetherPlaybackTarget) -> Float? {
    guard case .speedChanged(let rate) = action, !target.isPlaying, rate > 0,
      abs(rate - target.rate) > 0.001
    else { return nil }
    return rate
  }

  /// The local user's own actions become messages, so the others hear an announcement. They go
  /// through the outbox, so they arrive in the order they happened.
  private func observeLocalEvents(of target: ListenTogetherPlaybackTarget) {
    target.localEvents
      .sink { [weak self] event in
        guard let self, let action = self.remoteAction(for: event) else { return }
        self.outbox?.yield(.action(action))
      }
      .store(in: &localEventsBag)
  }

  /// One stream and one consumer per session (M3): each message is sent after the previous one.
  /// Finished and cancelled by `tearDown`.
  private func startOutbox(on transport: ListenTogetherTransport) {
    let (stream, continuation) = AsyncStream.makeStream(of: ListenTogetherMessage.self)
    outbox = continuation
    outboxTask = Task { [weak self] in
      for await message in stream {
        guard let self, self.transport === transport else { return }
        await self.send(message, on: transport)
      }
    }
  }

  private func remoteAction(for event: LocalPlaybackEvent) -> RemoteAction? {
    switch event {
    case .played: return .resumed
    case .paused: return .paused
    case .rateChanged(let rate): return .speedChanged(rate: rate)
    case .seeked(let to, let from):
      if let chapter = manifest?.chapter(at: to), chapter != manifest?.chapter(at: from) {
        return .movedToChapter(title: chapter.title)
      }
      let seconds = Int((to - from).rounded())
      return seconds == 0 ? nil : .skipped(seconds: seconds)
    }
  }

  private func send(_ message: ListenTogetherMessage, on transport: ListenTogetherTransport) async {
    do {
      try await transport.send(message)
    } catch {
      Self.logger.error("Listen Together: could not send a message: \(error.localizedDescription)")
    }
  }
}
