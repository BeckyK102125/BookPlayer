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
    clearEndNotice()
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
    let bridge = ListenTogetherCoordinatorBridge(
      target: target, shareID: shareID, role: .sharer, control: coordinatorControlFactory?())
    self.bridge = bridge
    if let activeSession { bridge.coordinate(with: activeSession) }
    observeLocalEvents(of: target)
    scheduleHeartbeat(on: transport)
    Self.logger.info("Listen Together: sharing started, ownersOnly=\(ownersOnly, privacy: .public)")
    return true
  }

  /// Sends the manifest, then exports and uploads the pieces. Stops as soon as the session ends or the
  /// task is cancelled (`tearDown` cancels `sharingTask`).
  ///
  /// Addendum 3: pieces are small (about 12 minutes) and sent in the order the group needs them
  /// (`PieceUploadScheduler`, asked again before every piece). A failed piece never ends the session:
  /// it is tried again after a back-off (2, 5, 15, then every 30 seconds), and at once when the app
  /// becomes active; interruptions never count as failures. While pieces are left, the idle timer is
  /// held off and each piece runs inside a background task.
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
      // Not a piece failure: without the files there is no book to describe or send.
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
    guard self.transport === transport, !plan.isEmpty else { return }

    pieceScheduler = PieceUploadScheduler(pieces: plan)
    Self.logger.info(
      "Listen Together: \(plan.count, privacy: .public) pieces to send, \(files.count, privacy: .public) files")
    var failures = 0
    while self.transport === transport, !Task.isCancelled,
      let piece = pieceScheduler?.next(at: groupPosition(for: item))
    {
      // Re-asserted for every piece: another screen may have turned the idle timer back on.
      setKeepingScreenAwake(true)
      switch await exportAndUpload(piece, from: files, to: folder, on: transport) {
      case .uploaded(let attachmentID):
        failures = 0
        if notice == .retryingSend { setNotice(nil) }
        pieceScheduler?.markSent(piece.index)
        let message = ListenTogetherMessage.pieceUploaded(index: piece.index, attachmentID: attachmentID)
        uploadedPieceMessages.append(message)
        await send(message, on: transport)
      case .interrupted:
        let delay = appSystem.appState == .active
          ? PieceRetryPolicy.interruptionDelay : PieceRetryPolicy.backgroundInterruptionDelay
        Self.logger.info(
          "Listen Together: piece \(piece.index, privacy: .public) interrupted, retry in \(String(describing: delay), privacy: .public) (not counted)")
        await retryWaiter.wait(delay, sleep: retrySleep)
      case .failed:
        failures += 1
        setNotice(.retryingSend)
        let delay = PieceRetryPolicy.delay(afterFailures: failures)
        Self.logger.info(
          "Listen Together: piece \(piece.index, privacy: .public) failure \(failures, privacy: .public), retry in \(String(describing: delay), privacy: .public)")
        await retryWaiter.wait(delay, sleep: retrySleep)
      case .stopped:
        return
      }
    }
    guard self.transport === transport, pieceScheduler?.isComplete == true else { return }
    Self.logger.info("Listen Together: every piece is sent")
    setKeepingScreenAwake(false)
  }

  enum PieceSendResult: Equatable {
    case uploaded(UUID)
    /// A real failure: counts towards the back-off.
    case failed
    /// The app was suspended or in the background, or the work was interrupted or cancelled: retried
    /// without counting.
    case interrupted
    /// The session ended meanwhile.
    case stopped
  }

  /// One attempt at one piece, inside a background task that is ended on every path (the defer) or
  /// by its expiration handler, whichever comes first.
  private func exportAndUpload(
    _ piece: PlannedPiece, from files: [SourceFile], to folder: URL, on transport: ListenTogetherTransport
  ) async -> PieceSendResult {
    guard self.transport === transport, !Task.isCancelled else { return .stopped }
    let backgroundTask = ListenTogetherBackgroundTask(system: appSystem, name: "Listen Together piece")
    defer { backgroundTask.end() }
    let appStateAtStart = appSystem.appState
    let exportStart = Date()
    Self.logger.info(
      "Listen Together: export piece \(piece.index, privacy: .public) start whole=\(piece.isWholeFile, privacy: .public) source=\(piece.sourceIndex, privacy: .public) start=\(piece.sourceStart, privacy: .public) duration=\(piece.duration, privacy: .public) estimated=\(piece.estimatedBytes, privacy: .public) app=\(appStateAtStart.rawValue, privacy: .public)")
    let exported: ExportedPiece
    do {
      exported = try await pieceExporter(piece, files, folder)
    } catch {
      return failure(error, stage: "export", piece: piece, appStateAtStart: appStateAtStart, on: transport)
    }
    guard self.transport === transport else { return .stopped }
    Self.logger.info(
      "Listen Together: exported piece \(piece.index, privacy: .public) preset=\(exported.preset, privacy: .public) bytes=\(exported.shared.byteSize, privacy: .public) in \(Date().timeIntervalSince(exportStart), privacy: .public)s")
    let uploadStart = Date()
    Self.logger.info("Listen Together: upload piece \(piece.index, privacy: .public) start")
    do {
      let attachmentID = try await transport.upload(fileAt: exported.url)
      guard self.transport === transport else { return .stopped }
      Self.logger.info(
        "Listen Together: uploaded piece \(piece.index, privacy: .public) attachment=\(attachmentID.uuidString, privacy: .public) in \(Date().timeIntervalSince(uploadStart), privacy: .public)s")
      return .uploaded(attachmentID)
    } catch {
      return failure(error, stage: "upload", piece: piece, appStateAtStart: appStateAtStart, on: transport)
    }
  }

  /// Logs the failure with its underlying error (domain, code, description) and says whether it counts.
  private func failure(
    _ error: Error, stage: String, piece: PlannedPiece, appStateAtStart: ListenTogetherAppState,
    on transport: ListenTogetherTransport
  ) -> PieceSendResult {
    guard self.transport === transport else { return .stopped }
    let appStateNow = appSystem.appState
    let interrupted = PieceRetryPolicy.isInterruption(error) || appStateAtStart != .active || appStateNow != .active
    let nsError = error as NSError
    let detail = (error as? BookSplitterError)?.diagnostics ?? nsError.localizedDescription
    Self.logger.error(
      "Listen Together: \(stage, privacy: .public) piece \(piece.index, privacy: .public) failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) \(detail) app=\(appStateAtStart.rawValue, privacy: .public)->\(appStateNow.rawValue, privacy: .public) interruption=\(interrupted, privacy: .public)")
    return interrupted ? .interrupted : .failed
  }

  /// Where the group is, for choosing the next piece: the sharer's own player while it holds the
  /// shared book (the coordinator keeps it at the group's time), else where the share started.
  func groupPosition(for item: PlayableItem) -> TimeInterval {
    if let groupPositionProvider { return groupPositionProvider() }
    if let current = playerManager.currentItem, current.uuid == item.uuid { return current.currentTime }
    return item.currentTime
  }

  /// Sharer, while pieces are left to send: the idle timer is held off so the phone doesn't lock and
  /// suspend the export. Restored to its earlier value when every piece is sent or the session ends.
  func setKeepingScreenAwake(_ keep: Bool) {
    if keep {
      if !keepsScreenAwake {
        idleTimerBeforeSharing = appSystem.isIdleTimerDisabled
        keepsScreenAwake = true
      }
      if !appSystem.isIdleTimerDisabled { appSystem.isIdleTimerDisabled = true }
    } else {
      guard keepsScreenAwake else { return }
      keepsScreenAwake = false
      appSystem.isIdleTimerDisabled = idleTimerBeforeSharing
    }
  }

  /// The app's state changed: logged during a session (it explains interruptions). Becoming active
  /// retries a waiting piece at once and holds the idle timer off again while pieces are left.
  func appStateChanged(to appState: ListenTogetherAppState) {
    guard isInSession else { return }
    Self.logger.info(
      "Listen Together: app state \(appState.rawValue, privacy: .public) role=\(self.role == .sharer ? "sharer" : "listener", privacy: .public)")
    guard appState == .active else { return }
    if keepsScreenAwake { appSystem.isIdleTimerDisabled = true }
    retryWaiter.wake()
  }

  /// "Still here", every `heartbeatInterval`, for as long as this share runs.
  private func scheduleHeartbeat(on transport: ListenTogetherTransport) {
    scheduleSessionTimer(Self.heartbeatInterval) { [weak self] in
      guard let self, self.transport === transport, self.role == .sharer else { return }
      self.outbox?.yield(.heartbeat)
      self.scheduleHeartbeat(on: transport)
    }
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
    clearEndNotice()
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
      startPresenceWatch(on: transport)
      requestStateIfNeeded(on: transport)
      Self.logger.info("Listen Together: joined, getting the book")
      return true
    }
    transport.stopReceivingPieces()
    setOwnCopy(true)
    setState(.listening(participants: participantCount, downloaded: 1))
    startEventLoop(on: transport)
    startOutbox(on: transport)
    startPresenceWatch(on: transport)
    Self.logger.info("Listen Together: joined with an own copy")
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
    Self.logger.info("Listen Together: manifest received, pieces=\(manifest.pieces.count, privacy: .public)")
    installListener(manifest: manifest)
  }

  /// Builds the listener's player for `manifest`. `arrivedFiles` (own copy) are pieces that are
  /// already here: own library files, played in place and never moved, copied or deleted.
  private func installListener(manifest: SharedBookManifest, arrivedFiles: [Int: URL] = [:]) {
    self.manifest = manifest
    let player = ListenerPlayer(manifest: manifest)
    for (index, url) in arrivedFiles.sorted(by: { $0.key < $1.key }) { player.pieceArrived(index: index, url: url) }
    let bridge = ListenTogetherCoordinatorBridge(
      target: player, shareID: manifest.shareID, role: .listener, control: coordinatorControlFactory?())
    player.onNeedsPiece = { [weak self] index in self?.listenerNeedsPiece(index) }
    // Path 3: whenever the player is at an arrived piece again (a placement, load, seek or play), a
    // stall that is no longer needed ends, so the group never waits for a piece nobody needs.
    player.onPositionReady = { [weak self] in self?.listenerPositionReady() }
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

  private func listenerNeedsPiece(_ index: Int) {
    bridge?.waitForPiece()
    // The sharer sends this piece next, whatever its own position.
    if !isUsingOwnCopy { outbox?.yield(.needPiece(index: index)) }
    guard !announcedWaiting else { return }
    announcedWaiting = true
    announcer.announce("listen_together_waiting_download".localized)
  }

  private func listenerPositionReady() {
    guard let listener, listener.isReady(at: listener.bookTime) else { return }
    announcedWaiting = false
    bridge?.pieceBecameAvailable()
  }

  private func pieceUploaded(index: Int, attachmentID: UUID) {
    guard role == .listener, !isUsingOwnCopy else { return }
    Self.logger.info(
      "Listen Together: piece \(index, privacy: .public) is attachment \(attachmentID.uuidString, privacy: .public), held=\(self.heldAttachments[attachmentID] != nil, privacy: .public)")
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
    Self.logger.info(
      "Listen Together: placed piece \(index, privacy: .public) ext=\(destination.pathExtension, privacy: .public) ready=\(listener.isReady(at: listener.bookTime), privacy: .public)")
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
      Self.logger.info("Listen Together: the event stream ended")
      self.tearDown(reason: .normal)
    }
  }

  private func handle(_ event: TransportEvent, from transport: ListenTogetherTransport) async {
    switch event {
    case .message(.manifest(let manifest)):
      sharerHeard()
      receivedManifest(manifest)
    case .message(.pieceUploaded(let index, let attachmentID)):
      sharerHeard()
      pieceUploaded(index: index, attachmentID: attachmentID)
    case .message(.heartbeat):
      sharerHeard()
    case .message(.requestState):
      // A listener without the manifest or piece map: send both again (to everyone; harmless).
      guard role == .sharer else { return }
      Self.logger.info("Listen Together: state requested; resending the manifest and piece map")
      await resendForLateJoiners(on: transport)
    case .message(.needPiece(let index)):
      guard role == .sharer else { return }
      Self.logger.info("Listen Together: a listener waits for piece \(index, privacy: .public)")
      pieceScheduler?.request(index)
    case .attachmentReceived(let id, let url):
      attachmentReceived(id: id, url: url)
    case .message(.action(let action)):
      announcer.announce(ListenTogetherAnnouncements.text(for: action))
      if let target = playbackTarget, let rate = Self.silentRate(for: action, target: target) {
        target.applyRate(rate)
      }
    case .message(.sessionEnding):
      // Only the sharer sends it: their End (or a book that could not be read at the start).
      Self.logger.info("Listen Together: the sharer ended the session")
      tearDown(reason: role == .listener ? .sharerEnded : .normal)
    case .invalidated:
      Self.logger.info("Listen Together: the group session was invalidated")
      tearDown(reason: .normal)
    case .participantsChanged(let count, let ids):
      Self.logger.info("Listen Together: participants \(ids.isEmpty ? count : ids.count, privacy: .public)")
      noteRosterSize(ids.isEmpty ? count : ids.count)
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
      let nsError = error as NSError
      Self.logger.error(
        "Listen Together: could not send \(message.kind, privacy: .public): \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) \(error.localizedDescription)")
    }
  }

  // MARK: Listener: state requests and the sharer's presence (addendum 3)

  /// Path 5: the manifest (and the piece map) can be missed. The listener asks on join and every
  /// `stateRequestInterval` while it has no manifest or holds a piece whose index it doesn't know.
  private func requestStateIfNeeded(on transport: ListenTogetherTransport) {
    guard self.transport === transport, role == .listener, !isUsingOwnCopy else { return }
    if listener == nil || heldAttachments.keys.contains(where: { pieceIndexByAttachment[$0] == nil }) {
      outbox?.yield(.requestState)
    }
    scheduleSessionTimer(Self.stateRequestInterval) { [weak self] in self?.requestStateIfNeeded(on: transport) }
  }

  private func startPresenceWatch(on transport: ListenTogetherTransport) {
    lastSharerContact = now()
    schedulePresenceCheck(on: transport)
  }

  private func schedulePresenceCheck(on transport: ListenTogetherTransport) {
    scheduleSessionTimer(Self.heartbeatInterval) { [weak self] in
      guard let self, self.transport === transport, self.role == .listener else { return }
      self.checkSharerPresence()
      if self.transport === transport { self.schedulePresenceCheck(on: transport) }
    }
  }

  /// Decision 9: silent for longer than `sharerSilenceLimit` while the group needs the sharer
  /// (playing, waiting for a piece, or still without the manifest) -> wait for the sharer; missing
  /// for `sharerReturnLimit` -> the session ends with `.sharerLeft`.
  func checkSharerPresence() {
    guard role == .listener else { return }
    let now = now()
    if let since = sharerMissingSince {
      guard now.timeIntervalSince(since) >= Self.sharerReturnLimit else { return }
      Self.logger.info("Listen Together: the sharer did not come back; ending")
      tearDown(reason: .sharerLeft)
      return
    }
    // While the group is paused and this device awaits nothing, silence is harmless: a sharer who
    // paused and locked the phone is suspended and can't send (device check "paused + locked 5+
    // minutes"). The silence clock starts again; leaving the roster still counts at once.
    if let listener, !listener.isPlaying, !listener.isWaitingForPiece {
      lastSharerContact = now
      return
    }
    if let last = lastSharerContact, now.timeIntervalSince(last) > Self.sharerSilenceLimit {
      sharerWentMissing(because: "silent")
    }
  }

  /// A roster of only this device, after someone else was in it: the sharer is gone.
  private func noteRosterSize(_ size: Int) {
    guard role == .listener, size > 0 else { return }
    if size >= 2 {
      hasSeenOtherParticipants = true
    } else if hasSeenOtherParticipants {
      sharerWentMissing(because: "alone in the roster")
    }
  }

  private func sharerWentMissing(because why: String) {
    guard role == .listener, sharerMissingSince == nil else { return }
    sharerMissingSince = now()
    Self.logger.info("Listen Together: waiting for the sharer (\(why, privacy: .public))")
    setNotice(.waitingForSharer)
    // Everyone pauses together: this device stops, and its stall suspension makes the group wait.
    listener?.holdForSharer()
    bridge?.holdForSharer()
  }

  /// A message only the sharer sends arrived. If they were missing, the group continues.
  private func sharerHeard() {
    guard role == .listener else { return }
    lastSharerContact = now()
    guard sharerMissingSince != nil else { return }
    sharerMissingSince = nil
    Self.logger.info("Listen Together: the sharer is back")
    if notice == .waitingForSharer { setNotice(nil) }
    bridge?.releaseSharerHold()
  }
}
