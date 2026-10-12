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

    // The group starts at the shared book's saved place, also when the player holds no book or another
    // one (start-position fix B), and the target never lets the group move that place before the group
    // has been seen there (fix D).
    let target = SharerPlaybackTarget(
      playerManager: playerManager, sharedItemUUID: item.uuid, startPosition: groupPosition(for: item),
      now: { [weak self] in self?.now() ?? Date() },
      schedule: { [weak self] delay, work in self?.scheduleSessionTimer(delay, work) })
    sharerTarget = target
    let bridge = ListenTogetherCoordinatorBridge(
      target: target, shareID: shareID, role: .sharer, control: coordinatorControlFactory?())
    self.bridge = bridge
    // Connect first, then transition and assert the place (fix A).
    bridge.start(session: activeSession)
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
    // Final review M5: pieces a listener asked for before the send order existed go first now.
    for index in pendingPieceRequests.sorted() { pieceScheduler?.request(index) }
    pendingPieceRequests = []
    sendContext = (item, files, folder)
    Self.logger.info(
      "Listen Together: \(plan.count, privacy: .public) pieces to send, \(files.count, privacy: .public) files")
    await runSendLoop(on: transport)
  }

  /// Sends pieces until every one is sent or the session ends. Started by `uploadPieces`, and again
  /// when a piece must be sent a second time after the loop had finished.
  func runSendLoop(on transport: ListenTogetherTransport) async {
    guard !isSendLoopRunning, let context = sendContext else { return }
    isSendLoopRunning = true
    defer { if self.transport === transport { isSendLoopRunning = false } }
    while self.transport === transport, !Task.isCancelled, pieceScheduler?.isComplete == false {
      // Fix round 1 (M1): while nobody else is here nothing is sent, so the screen may lock.
      if !hasOtherParticipants { setKeepingScreenAwake(false) }
      // B3 (build 5): nothing is exported or uploaded until the session is joined and someone else is
      // here; the piece is chosen after the wait, so it follows the group's place then.
      guard await transport.waitUntilReadyToSend(), self.transport === transport, !Task.isCancelled,
        let piece = pieceScheduler?.next(at: groupPosition(for: context.item))
      else { break }
      // Re-asserted for every piece: another screen may have turned the idle timer back on.
      setKeepingScreenAwake(true)
      switch await exportAndUpload(piece, from: context.files, to: context.folder, on: transport) {
      case .uploaded(let attachmentID):
        pieceFailures[piece.index] = nil
        if notice == .retryingSend, pieceFailures.isEmpty { setNotice(nil) }
        pieceScheduler?.markSent(piece.index)
        let message = ListenTogetherMessage.pieceUploaded(index: piece.index, attachmentID: attachmentID)
        uploadedPieceMessages.removeAll { if case .pieceUploaded(piece.index, _) = $0 { return true } else { return false } }
        uploadedPieceMessages.append(message)
        await send(message, on: transport)
      case .interrupted:
        let delay = appSystem.appState == .active
          ? PieceRetryPolicy.interruptionDelay : PieceRetryPolicy.backgroundInterruptionDelay
        Self.logger.info(
          "Listen Together: piece \(piece.index, privacy: .public) interrupted, retry in \(String(describing: delay), privacy: .public) (not counted)")
        await retryWaiter.wait(delay, sleep: retrySleep)
      case .failed:
        let failures = (pieceFailures[piece.index] ?? 0) + 1
        pieceFailures[piece.index] = failures
        // Behind the other pieces still to send, unless a listener waits for it (minor 5).
        pieceScheduler?.markFailed(piece.index)
        // B3 (3.3): while nobody else has joined, failures are retried silently.
        if hasOtherParticipants { setNotice(.retryingSend) }
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

  /// A listener waits for `index` (I1). Not sent yet: it goes next. Already sent: its map entry is sent
  /// again (the listener may have missed it or failed to load it), and if the journal no longer holds
  /// the attachment, the piece is exported and uploaded again.
  private func listenerNeeds(_ index: Int, on transport: ListenTogetherTransport) async {
    guard let message = uploadedPieceMessages.first(where: {
      if case .pieceUploaded(index, _) = $0 { return true } else { return false }
    }), case .pieceUploaded(_, let attachmentID) = message else {
      if pieceScheduler != nil {
        pieceScheduler?.request(index)
      } else {
        // The manifest is still being sent: remember it for when the send order exists (M5).
        pendingPieceRequests.insert(index)
      }
      return
    }
    guard transport.hasAttachment(attachmentID) == false else {
      Self.logger.info("Listen Together: piece \(index, privacy: .public) was sent; sending its map entry again")
      await send(message, on: transport)
      return
    }
    Self.logger.info("Listen Together: piece \(index, privacy: .public) is gone from the journal; sending it again")
    uploadedPieceMessages.removeAll { $0 == message }
    pieceScheduler?.markUnsent(index)
    pieceScheduler?.request(index)
    guard !isSendLoopRunning else { return }
    sharingTask = Task { [weak self] in await self?.runSendLoop(on: transport) }
  }

  /// Minor 7: at most one full answer per `stateAnswerInterval`; requests in between get one later answer.
  private func answerStateRequest(on transport: ListenTogetherTransport) async {
    let now = now()
    if let last = lastStateAnswer, now.timeIntervalSince(last) < Self.stateAnswerInterval {
      guard !isStateAnswerPending else { return }
      isStateAnswerPending = true
      let wait = Self.stateAnswerInterval - now.timeIntervalSince(last)
      // M10: timers hold the transport weakly, so a left session's transport is released at teardown.
      scheduleSessionTimer(.milliseconds(Int((wait * 1000).rounded(.up)))) { [weak self, weak transport] in
        guard let self, let transport, self.transport === transport, self.isStateAnswerPending else { return }
        self.isStateAnswerPending = false
        Task { await self.answerStateRequest(on: transport) }
      }
      return
    }
    lastStateAnswer = now
    Self.logger.info("Listen Together: state requested; resending the manifest and piece map")
    await resendForLateJoiners(on: transport)
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

  /// Logs the failure with its underlying error and says whether it counts. The public part (transfer
  /// fix, item 3) names the error's type or case, domain and code, and the underlying error's domain
  /// and code, so a device log without a debugger shows it; the description stays private.
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
      "Listen Together: \(stage, privacy: .public) piece \(piece.index, privacy: .public) failed: \(ListenTogetherErrorDescription.describe(error), privacy: .public) app=\(appStateAtStart.rawValue, privacy: .public)->\(appStateNow.rawValue, privacy: .public) interruption=\(interrupted, privacy: .public) detail=\(detail)")
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
  ///
  /// Minor 6: it is only switched back on if this code switched it off. When another BookPlayer feature
  /// had already disabled it, it is left alone; when this code disabled it, it is always enabled again
  /// at the end (even if another screen toggled it meanwhile), so the screen never stays unlocked.
  func setKeepingScreenAwake(_ keep: Bool) {
    if keep {
      if !keepsScreenAwake {
        keepsScreenAwake = true
        didDisableIdleTimer = !appSystem.isIdleTimerDisabled
      }
      if didDisableIdleTimer, !appSystem.isIdleTimerDisabled { appSystem.isIdleTimerDisabled = true }
    } else {
      guard keepsScreenAwake else { return }
      keepsScreenAwake = false
      if didDisableIdleTimer { appSystem.isIdleTimerDisabled = false }
      didDisableIdleTimer = false
    }
  }

  /// Someone besides this device is counted in the session.
  var hasOtherParticipants: Bool { participantCount > 1 }

  /// B3 (3.3): the sharer's retry status needs someone to have joined. Fix round 1 (M2, a11y M3): a
  /// join never starts an episode by itself (a failure from before, while alone, is stale and would be
  /// heard before "Someone joined"); the next failure after the join does. The last listener leaving
  /// ends an episode silently and resets it, and the idle timer is released (M1).
  func participantCountChanged(from previous: Int, to count: Int) {
    guard role == .sharer, previous != count, count <= 1 else { return }
    if notice == .retryingSend { setNotice(nil) }
    setKeepingScreenAwake(false)
  }

  /// The app's state changed: logged during a session (it explains interruptions). Becoming active
  /// retries a waiting piece at once and holds the idle timer off again while pieces are left.
  func appStateChanged(to appState: ListenTogetherAppState) {
    guard isInSession else { return }
    Self.logger.info(
      "Listen Together: app state \(appState.rawValue, privacy: .public) role=\(self.role == .sharer ? "sharer" : "listener", privacy: .public)")
    guard appState == .active else { return }
    if keepsScreenAwake { setKeepingScreenAwake(true) }
    retryWaiter.wake()
    // 1.5: no notification could be posted for the pause while away: said once now, if still paused.
    if announcesPauseWhenActive {
      announcesPauseWhenActive = false
      if let pauseCause { announcer.announce(pauseCause.text) }
    }
  }

  /// "Still here", every `heartbeatInterval`, for as long as this share runs.
  private func scheduleHeartbeat(on transport: ListenTogetherTransport) {
    scheduleSessionTimer(Self.heartbeatInterval) { [weak self, weak transport] in
      guard let self, let transport, self.transport === transport, self.role == .sharer else { return }
      // Minor 10: never more than one heartbeat waiting in the outbox.
      if !self.isHeartbeatQueued {
        self.isHeartbeatQueued = true
        self.outbox?.yield(.heartbeat)
      }
      self.scheduleHeartbeat(on: transport)
    }
  }

  private func failSharing(on transport: ListenTogetherTransport) async {
    // Its own message, so listeners can say why it ended (minor 9).
    await send(.sharerCouldNotPrepare, on: transport)
    // E14: "Couldn't prepare the book for sharing. Listen Together ended." as a centred alert.
    tearDown(reason: .prepareFailed)
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
      scheduleLoadRetry(on: transport, attempt: 0)
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
    ownCopyFiles = Dictionary(uniqueKeysWithValues: ownCopy.files.enumerated().map { ($0, $1) })
    installListener(manifest: manifest, arrivedFiles: urls)
    // Said after the player's title has focus (`listenerTitleFocused`), or after a fallback delay.
    pendingOwnCopyJoinedLine = true
    schedule(Self.ownCopyJoinedFallbackDelay) { [weak self, weak transport] in
      guard let transport else { return }
      self?.announceOwnCopyJoined(on: transport)
    }
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
    player.onPieceFailed = { [weak self] index in self?.listenerPieceFailed(index) }
    // Play or pause while the group waits for this device's piece: nothing is sent; say why.
    player.onToggleWhileWaiting = { [weak self] in
      guard let self, !self.isUsingOwnCopy, self.waitingToggleLimiter.allows(at: Date()) else { return }
      self.announcer.announce("listen_together_waiting_download".localized)
    }
    // Play or pause while the person sharing is missing (C.2): nothing happens; say why, at most every
    // 2 s (VoiceOver only).
    player.isHeldForSharer = isSharerGraceRunning
    player.onToggleWhileHeldForSharer = { [weak self] in
      guard let self, self.sharerWaitToggleLimiter.allows(at: Date()) else { return }
      self.announcer.announce("listen_together_waiting_for_sharer".localized)
    }
    // Start-position fix C: until the first play or seek command, the group's place is unknown here.
    // Play, pause, skips and speed do nothing to the group; "Finding the group's place" shows in the
    // status and under the controls, and a press says it (VoiceOver), at most every 3 s like "Waiting
    // for the book". Round 1: a staged fallback runs meanwhile (`scheduleFindingPlaceFallback`).
    player.isJoiningGroup = !bridge.hasGroupTiming
    setListenerJoining(!bridge.hasGroupTiming)
    player.onActionWhileJoining = { [weak self] in
      guard let self else { return }
      self.refusedPressWhileJoining = true
      guard self.joiningToggleLimiter.allows(at: self.now()) else { return }
      self.lastFindingPlaceAnnouncedAt = self.now()
      self.announcer.announce("listen_together_finding_place".localized)
    }
    bridge.onGroupTimingKnown = { [weak self, weak player] time in
      player?.isJoiningGroup = false
      self?.listenerFoundPlace(at: time, playing: player?.isPlaying == true)
    }
    bridge.onGroupTime = { [weak self] time in self?.reportInStep(at: time) }
    // The status line and the Zoom caption follow the player's wait for a piece.
    player.$isWaitingForPiece
      .removeDuplicates()
      .sink { [weak self] waiting in
        // Own copy: no "Waiting for the book" status or caption (final review I1).
        guard let self else { return }
        self.setListenerWaitingForPiece(waiting && !self.isUsingOwnCopy)
      }
      .store(in: &localEventsBag)
    player.$isPlaying
      .removeDuplicates()
      .sink { [weak self] playing in self?.setListenerPlaying(playing) }
      .store(in: &localEventsBag)
    self.bridge = bridge
    setListener(player)
    // Connect first, then transition (fix A).
    bridge.start(session: activeSession)
    observeLocalEvents(of: player)
    if let transport, isListenerJoining { scheduleFindingPlaceFallback(on: transport, bridge: bridge) }
    // Pieces that arrived before the manifest.
    for (attachmentID, index) in pieceIndexByAttachment {
      if let url = heldAttachments.removeValue(forKey: attachmentID) { place(index: index, url: url) }
    }
    updateListeningState()
  }

  /// The listener received its first group time (round 1): the fallback's status ends, and what waited
  /// for the place is said now. (The sharer hears `.inStep` through `reportInStep`, after every command.)
  private func listenerFoundPlace(at time: TimeInterval, playing: Bool) {
    setListenerJoining(false)
    setListenerJoiningSlow(false)
    slowLineWaitsToBeShown = false
    let saysReady = refusedPressWhileJoining && !playing
    refusedPressWhileJoining = false
    if ownCopyLineWaitsForPlace, let transport {
      ownCopyLineWaitsForPlace = false
      announceOwnCopyJoined(on: transport)
    }
    // a11y M3: a press was refused and the group is paused: say once that Play works now (also after
    // the own-copy line, round 2 M-c, so she learns Play works).
    if saysReady { announcer.announce("listen_together_ready".localized) }
  }

  /// Round 2 (N2): the listener tells the sharer where it is after every play or seek command it
  /// applied: at once, then at most one per `inStepInterval`, the latest time when that time is up.
  /// A report that misses the sharer's place is followed by the sharer's re-assert, whose seek brings
  /// the next report, so protection never stays on because of one missed report.
  private func reportInStep(at time: TimeInterval) {
    guard role == .listener, let transport else { return }
    let date = now()
    if let last = lastInStepSentAt, date.timeIntervalSince(last) < Self.inStepInterval {
      let isScheduled = pendingInStepTime != nil
      pendingInStepTime = time
      guard !isScheduled else { return }
      let wait = Self.inStepInterval - date.timeIntervalSince(last)
      scheduleSessionTimer(.milliseconds(Int((wait * 1000).rounded(.up)))) { [weak self, weak transport] in
        guard let self, let transport, self.transport === transport, self.role == .listener,
          let latest = self.pendingInStepTime
        else { return }
        self.pendingInStepTime = nil
        self.sendInStep(at: latest)
      }
      return
    }
    sendInStep(at: time)
  }

  private func sendInStep(at time: TimeInterval) {
    lastInStepSentAt = now()
    outbox?.yield(.inStep(at: time))
  }

  /// The 12 s line is visible only while "Finding the group's place" is the status shown: the person
  /// sharing being away and waiting for the book come first (status order). Round 2 (a11y I-A).
  private var isFindingPlaceLineShown: Bool {
    isListenerJoining && !isSharerGraceRunning && !isListenerWaitingForPiece
  }

  /// Says the 12 s line once, when it is (or becomes) the visible status. Called at 12 s and whenever
  /// the sharer's grace or the wait for a piece ends.
  func announceSlowLineIfShown() {
    guard slowLineWaitsToBeShown, isListenerJoiningSlow, isFindingPlaceLineShown else { return }
    slowLineWaitsToBeShown = false
    let slow = "listen_together_finding_place_slow".localized
    // a11y M-b: no "Finding the group's place" twice in a row after a press just before.
    if let last = lastFindingPlaceAnnouncedAt, now().timeIntervalSince(last) < 3 {
      announcer.announce(slow)
    } else {
      announcer.announce("listen_together_finding_place".localized + ". " + slow)
    }
  }

  /// Round 1 fallback while the group's place is unknown, all on the session clock and stopped by
  /// teardown: at 3 s the coordinator is asked to re-send the group's state; from 5 s the sharer is
  /// asked every `stateRequestInterval` (`.requestState`, own copy too); at 12 s a second status line
  /// says what to do, announced once.
  private func scheduleFindingPlaceFallback(on transport: ListenTogetherTransport, bridge: ListenTogetherCoordinatorBridge) {
    let stillFinding: @MainActor (SharePlaySessionService) -> Bool = { [weak transport, weak bridge] service in
      guard let transport, let bridge else { return false }
      return service.transport === transport && service.bridge === bridge && service.role == .listener
        && service.isListenerJoining
    }
    scheduleSessionTimer(Self.joiningReapplyDelay) { [weak self, weak bridge] in
      guard let self, stillFinding(self) else { return }
      bridge?.reapplyCurrentItemState()
    }
    scheduleFindingPlaceRequest(after: Self.joiningRequestDelay, stillFinding: stillFinding)
    scheduleSessionTimer(Self.joiningSlowDelay) { [weak self] in
      guard let self, stillFinding(self) else { return }
      Self.logger.info("Listen Together: the group's place is still not known; showing what to do")
      self.setListenerJoiningSlow(true)
      self.slowLineWaitsToBeShown = true
      self.announceSlowLineIfShown()
    }
  }

  private func scheduleFindingPlaceRequest(
    after delay: Duration, stillFinding: @escaping @MainActor (SharePlaySessionService) -> Bool
  ) {
    scheduleSessionTimer(delay) { [weak self] in
      guard let self, stillFinding(self) else { return }
      Self.logger.info("Listen Together: asking the person sharing for the group's place")
      self.outbox?.yield(.requestState)
      // Round 2 (R3): after the 12 s line, less often (each answer re-sends the manifest and piece map).
      let next = self.isListenerJoiningSlow ? Self.slowFindingPlaceRequestInterval : Self.stateRequestInterval
      self.scheduleFindingPlaceRequest(after: next, stillFinding: stillFinding)
    }
  }

  private func listenerNeedsPiece(_ index: Int) {
    bridge?.waitForPiece()
    // The sharer sends this piece next, whatever its own position.
    if !isUsingOwnCopy { outbox?.yield(.needPiece(index: index)) }
    // An own file is never "Waiting for the book": nothing will be sent (final review I1).
    guard !isUsingOwnCopy, !announcedWaiting else { return }
    announcedWaiting = true
    // Status + one announcement per wait; never spoken by the setting (normal buffering).
    messages.deliver(.waitingForBook)
  }

  /// Minor 4: a received piece couldn't be played. It may be placed again, and its attachment is
  /// loaded again (the player then waits for it, which asks the sharer too).
  private func listenerPieceFailed(_ index: Int) {
    placedPieces.remove(index)
    updateListeningState()
    // Fix round 2 (I-A): loaded again on the 5/10/20/30 s schedule, counted per piece, so a file that
    // never plays is not re-read in a tight loop. Teardown stops a pending reload.
    let failures = (pieceDecodeFailures[index] ?? 0) + 1
    pieceDecodeFailures[index] = failures
    let delay = Self.loadRetryDelays[min(failures - 1, Self.loadRetryDelays.count - 1)]
    if isUsingOwnCopy {
      ownCopyFileFailed(index, failures: failures, delay: delay)
      return
    }
    Self.logger.error(
      "Listen Together: piece \(index, privacy: .public) dropped (failure \(failures, privacy: .public)), loading it again in \(String(describing: delay), privacy: .public)")
    guard let transport, let attachmentID = pieceIndexByAttachment.first(where: { $0.value == index })?.key
    else { return }
    scheduleSessionTimer(delay) { [weak self, weak transport] in
      guard let self, let transport, self.transport === transport, self.role == .listener,
        !self.placedPieces.contains(index)
      else { return }
      transport.reloadPiece(attachmentID: attachmentID)
    }
  }

  /// Final review I1: one of the listener's own files can't be played. Nothing will ever be sent for it,
  /// so it is armed again after the same back-off if the file is still there with its matched size. If
  /// it is gone, or fails `ownCopyFailureLimit` times, this phone leaves (the others' stall ends with it)
  /// and one alert says why.
  private func ownCopyFileFailed(_ index: Int, failures: Int, delay: Duration) {
    Self.logger.error(
      "Listen Together: own file \(index, privacy: .public) can't be played (failure \(failures, privacy: .public))")
    guard failures < Self.ownCopyFailureLimit else {
      leaveBecauseOwnCopyFailed()
      return
    }
    guard let transport else { return }
    scheduleSessionTimer(delay) { [weak self, weak transport] in
      guard let self, let transport, self.transport === transport, self.role == .listener,
        self.isUsingOwnCopy
      else { return }
      guard let file = self.ownCopyFiles[index], Self.ownFileIsUsable(file) else {
        self.leaveBecauseOwnCopyFailed()
        return
      }
      Self.logger.info("Listen Together: own file \(index, privacy: .public) armed again")
      self.listener?.pieceArrived(index: index, url: file.url)
    }
  }

  /// The own file is still there with the size it had when matched.
  nonisolated static func ownFileIsUsable(_ file: SourceFile, fileManager: FileManager = .default) -> Bool {
    guard let size = (try? fileManager.attributesOfItem(atPath: file.url.path))?[.size] as? Int64 else {
      return false
    }
    return size == file.byteSize
  }

  func leaveBecauseOwnCopyFailed() {
    guard role == .listener, isUsingOwnCopy else { return }
    Self.logger.error("Listen Together: the own copy can't be played; leaving on this phone")
    // This phone leaves on purpose: the sharer hears "left", not "lost their connection" (build 5).
    let transport = self.transport
    stopReceivingBeforeLeaving(transport)
    tearDown(reason: .ownCopyFailed, leaveTransport: false)
    if let transport { leaveTellingTheSharer(transport) }
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
      Self.logger.error(
        "Listen Together: could not store piece \(index, privacy: .public): \(ListenTogetherErrorDescription.describe(error), privacy: .public)")
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
      // Not this device's own End or Leave (those tear down first): say why (fix round 1, I1).
      self.tearDown(reason: .connectionEnded)
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
      // Round 1 fallback: a joiner still finding the place asks too. The place is re-asserted only
      // while a joiner is not in step and it may be asserted (`canAssertPlace`, as for every assert);
      // inside the 3 s limit it is delayed, never dropped (round 2).
      sharerTarget?.requestReassert()
      await answerStateRequest(on: transport)
    case .message(.needPiece(let index)):
      guard role == .sharer else { return }
      Self.logger.info("Listen Together: a listener waits for piece \(index, privacy: .public)")
      await listenerNeeds(index, on: transport)
    case .inStep(let time, let id):
      listenerInStep(at: time, from: id)
    case .message(.inStep(let time)):
      listenerInStep(at: time, from: nil)
    case .message(.sharerCouldNotPrepare):
      Self.logger.info("Listen Together: the sharer could not prepare the book")
      tearDown(reason: role == .listener ? .sharerCouldNotPrepare : .normal)
    case .sharerParticipant(let id):
      guard role == .listener else { return }
      sharerParticipantID = id
    case .attachmentReceived(let id, let url):
      attachmentReceived(id: id, url: url)
    case .message(.action(let action)):
      announcer.announce(ListenTogetherAnnouncements.text(for: action))
      // E9: why the audio stopped, visible until the next play.
      if action == .paused { setPausedByOther(true) }
      if action == .resumed {
        setPausedByOther(false)
        // Build 5 (1.6): any play resumes for everyone and clears the pause status silently.
        clearPauseCause()
      }
      if let target = playbackTarget, let rate = Self.silentRate(for: action, target: target) {
        target.applyRate(rate)
      }
    case .message(.sessionEnding):
      // Only the sharer sends it: their End (or a book that could not be read at the start).
      Self.logger.info("Listen Together: the sharer ended the session")
      tearDown(reason: role == .listener ? .sharerEnded : .normal)
    case .invalidated:
      Self.logger.info("Listen Together: the group session was invalidated")
      // An invalidated session can't be joined again (fix round 2).
      if let shareID { rememberEndedShare(shareID) }
      // One ending per session: after a more specific reason tearDown has already run and returns.
      tearDown(reason: .connectionEnded)
    case .participantsChanged(let count, let ids):
      Self.logger.info("Listen Together: participants \(ids.isEmpty ? count : ids.count, privacy: .public)")
      let wasSharerMissing = sharerMissingSince != nil
      noteRoster(count: count, ids: ids)
      // Listener: the person sharing leaving the roster is the grace, never "Someone left" (1.8).
      let sharerJustLeft = !wasSharerMissing && sharerMissingSince != nil
      if ids.isEmpty {
        await participantsChanged(to: count, sharerJustLeft: sharerJustLeft, on: transport)
      } else {
        await rosterChanged(to: ids, sharerJustLeft: sharerJustLeft, on: transport)
      }
    case .participantDeclined(let id):
      participantDeclined(id)
    case .message(.declinedNoCopy):
      // The transport reports it as `.participantDeclined`; a bare message has no sender.
      participantDeclined(nil)
    case .listenerLeaving(let id):
      noteListenerLeaving(id)
    case .message(.listenerLeaving):
      // The transport reports it as `.listenerLeaving(id:)`; a bare message has no sender.
      noteListenerLeaving(nil)
    case .message(.groupPaused(let cause)):
      groupPausedBySharer(cause)
    }
  }

  func resetRoster() {
    participantCount = 1
    hasParticipantBaseline = false
    rosterIDs = []
    confirmedParticipantIDs = []
    declinedParticipantIDs = []
    awaitingInStep = []
    awaitingAnonymousInStep = 0
    hasInStepSinceArm = false
  }

  /// Someone couldn't join an owners-only share (no copy). They are never counted, and their brief
  /// join and leave are never announced. The sharer hears one queued line, coalesced to one per
  /// 10 seconds; listeners hear nothing. Nothing says who it was or what they own.
  private func participantDeclined(_ id: UUID?) {
    guard role != nil else { return }
    if let id {
      declinedParticipantIDs.insert(id)
      if confirmedParticipantIDs.remove(id) != nil { applyParticipantCount(confirmedParticipantIDs.count) }
      if awaitingInStep.remove(id) != nil { confirmIfEveryJoinerIsInStep() }
    }
    guard role == .sharer else { return }
    // E11: also a second status line, so a sharer without VoiceOver learns why no one joined.
    setSomeoneDeclined(true)
    guard declineAnnouncementLimiter.allows(at: now()) else { return }
    announcer.announce("listen_together_declined_no_copy".localized)
  }

  /// The roster by id. The first one is the baseline. Someone new is counted and announced only after
  /// `joinConfirmationDelay`, if still here and not declined; someone counted who leaves is announced.
  /// The sharer re-sends the manifest and piece map to anyone new at once.
  private func rosterChanged(
    to ids: Set<UUID>, sharerJustLeft: Bool = false, on transport: ListenTogetherTransport
  ) async {
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
    if role == .sharer {
      if !arrived.isEmpty { sharerJoinersArrived(ids: arrived) }
      if !gone.isEmpty, !awaitingInStep.isDisjoint(with: gone) {
        awaitingInStep.subtract(gone)
        confirmIfEveryJoinerIsInStep()
      }
    }
    declinedParticipantIDs.subtract(gone)
    var countedGone = gone.intersection(confirmedParticipantIDs)
    if role == .listener, sharerJustLeft {
      // 1.8: the person sharing is not "someone".
      if let sharer = sharerParticipantID, countedGone.contains(sharer) {
        countedGone.remove(sharer)
      } else if let any = countedGone.first {
        countedGone.remove(any)
      }
    }
    confirmedParticipantIDs.subtract(gone)
    applyParticipantCount(confirmedParticipantIDs.count)
    if !countedGone.isEmpty {
      someoneLeft(ids: countedGone, count: countedGone.count, othersLeft: participantCount - 1)
    }
    guard !arrived.isEmpty else { return }
    if isOwnersOnlySession {
      schedule(Self.joinConfirmationDelay) { [weak self, weak transport] in
        guard let transport else { return }
        self?.confirmArrivals(arrived, on: transport)
      }
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
    let previous = participantCount
    participantCount = max(count, 1)
    // The "couldn't join" line stays until the visible count changes.
    if participantCount != previous { setSomeoneDeclined(false) }
    participantCountChanged(from: previous, to: participantCount)
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
  private func participantsChanged(
    to count: Int, sharerJustLeft: Bool = false, on transport: ListenTogetherTransport
  ) async {
    // A roster with nobody in it (not even us) is not a real change.
    guard count > 0, role != nil else { return }
    let previous = participantCount
    participantCount = count
    if count != previous { setSomeoneDeclined(false) }
    participantCountChanged(from: previous, to: count)
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
      if role == .sharer { sharerJoinersArrived(count: count - previous) }
      announcer.announce(ListenTogetherAnnouncements.joined())
      await resendForLateJoiners(on: transport)
    } else if count < previous {
      if role == .sharer, awaitingAnonymousInStep > count - 1 {
        awaitingAnonymousInStep = max(0, count - 1)
        confirmIfEveryJoinerIsInStep()
      }
      let departed = previous - count - (role == .listener && sharerJustLeft ? 1 : 0)
      if departed > 0 { someoneLeft(ids: [], count: departed, othersLeft: count - 1) }
    }
  }

  // MARK: Someone left: the group pauses (build 5, a11y guidance section 1)

  /// Counted listeners left. The sharer pauses the group when it was playing (P1-P4 replace "Someone
  /// left"); otherwise, and on listeners, "Someone left Listen Together" as before (a listener holds it
  /// for the sharer's `.groupPaused`). `othersLeft`: counted listeners still here after this update.
  private func someoneLeft(ids: Set<UUID>, count: Int, othersLeft: Int = 1) {
    switch role {
    case .sharer:
      let cause = pauseCause(forDeparted: ids, count: count, everyoneLeft: othersLeft == 0)
      if pauseCause == nil, sharerTarget?.isPlayingForGroup == true {
        pauseGroup(cause)
      } else {
        announcer.announce(ListenTogetherAnnouncements.left())
      }
    case .listener:
      holdLeftAnnouncement(ids: ids)
    case nil:
      break
    }
  }

  /// P1-P4: "lost their connection" only when ids are known and none of the departed said they were
  /// leaving. Leaving notes are used up by the departure they explain. Fix round 1 (M8): when several
  /// listeners vanish at once and nobody is left, the likelier cause is the sharer's own connection, so the
  /// neutral "left" wording is used rather than blaming the others' connections.
  private func pauseCause(
    forDeparted ids: Set<UUID>, count: Int, everyoneLeft: Bool = false
  ) -> ListenTogetherPauseCause {
    pruneLeavingNotes()
    var explained = 0
    for id in ids where leavingNotes.removeValue(forKey: id) != nil { explained += 1 }
    let fromAnonymous = min(count - explained, anonymousLeavingNotes.count)
    anonymousLeavingNotes.removeFirst(max(fromAnonymous, 0))
    explained += max(fromAnonymous, 0)
    // A count-only roster has no ids to prove a lost connection: the neutral "left" wording.
    var lostConnection = !ids.isEmpty && explained == 0
    if lostConnection, count > 1, everyoneLeft { lostConnection = false }
    return ListenTogetherPauseCause(count: count, lostConnection: lostConnection, departedIDs: ids)
  }

  private func pruneLeavingNotes() {
    let now = now()
    leavingNotes = leavingNotes.filter { now.timeIntervalSince($0.value) <= Self.leavingNoteLifetime }
    anonymousLeavingNotes.removeAll { now.timeIntervalSince($0) > Self.leavingNoteLifetime }
  }

  /// Sharer: a listener said it is leaving; the roster drop that follows reads as "left".
  private func noteListenerLeaving(_ id: UUID?) {
    guard role == .sharer else { return }
    Self.logger.info("Listen Together: a listener is leaving")
    if let id {
      leavingNotes[id] = now()
    } else {
      anonymousLeavingNotes.append(now())
    }
  }

  /// The longest the pause's background task is held (fix round 1, I2).
  static let pauseBackgroundLimit: Duration = .seconds(5)

  /// Sharer: the group was playing and listeners left. The book pauses for everyone; one message (status,
  /// caption, row, one announcement, Speak, a notification when away) says why, and the listeners get
  /// `.groupPaused` instead of "Another listener paused".
  ///
  /// Fix round 1 (I2): the app may be in the background (phone locked on a call), and once the audio
  /// stops iOS can suspend it. A background task, begun before the pause, is held until the `.groupPaused`
  /// send and the notification attempt are both done, at most `pauseBackgroundLimit`; expiry ends it.
  private func pauseGroup(_ cause: ListenTogetherPauseCause) {
    Self.logger.info(
      "Listen Together: \(cause.count, privacy: .public) listener(s) left (lostConnection=\(cause.lostConnection, privacy: .public)); pausing the group")
    let background = ListenTogetherBackgroundTask(system: appSystem, name: "Listen Together pause")
    var pending = 2
    let finishOne: @MainActor () -> Void = {
      pending -= 1
      if pending == 0 { background.end() }
    }
    schedule(Self.pauseBackgroundLimit) { background.end() }
    setPauseCause(cause)
    suppressPausedActionUntil = now().addingTimeInterval(2)
    announcesPauseWhenActive = false
    if let transport {
      Task { [weak self] in
        await self?.send(.groupPaused(cause), on: transport)
        finishOne()
      }
    } else {
      finishOne()
    }
    playerManager.pause()
    deliverPauseMessage(.pausedBecauseSomeoneLeft(cause, isSharer: true), onClose: finishOne)
  }

  /// The pause message, both roles. Away without a notification: said on the return, if still paused,
  /// or at once if the app became active while the notification was being checked (fix round 1, M6).
  private func deliverPauseMessage(
    _ message: ListenTogetherUserMessage, onClose: (@MainActor () -> Void)? = nil
  ) {
    messages.deliver(
      message,
      onNotNotified: { [weak self] in
        guard let self, let pauseCause = self.pauseCause else { return }
        if self.appSystem.appState == .active {
          self.announcer.announce(pauseCause.text)
        } else {
          self.announcesPauseWhenActive = true
        }
      },
      onClose: { [weak self] in
        // Played again while the notification was being posted: it is no longer true.
        if let self, self.pauseCause == nil { self.messages.removePauseNotificationIfShown() }
        onClose?()
      })
  }

  /// Listener: the person sharing paused the group because someone left. The P-sentence replaces
  /// "Someone left" (held) and "Another listener paused"; one announcement per pause episode.
  private func groupPausedBySharer(_ cause: ListenTogetherPauseCause) {
    guard role == .listener else { return }
    // Fix round 1 (M8): while the person sharing is missing (or just back), a pause they queued while
    // their own connection was dropping is not about the others.
    if isSharerGraceRunning { return }
    if let back = sharerReturnedAt, now().timeIntervalSince(back) <= Self.sharerReturnPauseGrace { return }
    lastGroupPausedAt = now()
    lastGroupPausedNamedIDs = !cause.departedIDs.isEmpty
    explainedDepartures.formUnion(cause.departedIDs)
    heldLeftIDs.subtract(cause.departedIDs)
    if cause.departedIDs.isEmpty || heldLeftIDs.isEmpty {
      // The held "Someone left Listen Together" for this departure is dropped.
      leftHoldGeneration += 1
      heldLeftIDs = []
    }
    setPausedByOther(false)
    guard pauseCause == nil else { return }
    // Fix round 2 (m1): `.groupPaused` and the coordinator's pause travel separately, and a play (here or
    // another `.action(.resumed)`) can overtake the message. While this phone still plays, the pause
    // waits up to `groupPauseSettle` for the player to stop; if it is still playing then, the group is
    // playing again and the stale pause is dropped (no status, no announcement).
    guard isListenerPlaying else {
      applyGroupPause(cause)
      return
    }
    pendingGroupPause = cause
    groupPauseGeneration += 1
    let generation = groupPauseGeneration
    schedule(Self.groupPauseSettle) { [weak self] in
      guard let self, self.role == .listener, self.groupPauseGeneration == generation,
        self.pendingGroupPause != nil
      else { return }
      self.pendingGroupPause = nil
      if self.isListenerPlaying {
        Self.logger.info("Listen Together: a pause message arrived after the group played again; ignored")
      } else {
        self.applyGroupPause(cause)
      }
    }
  }

  /// The listener's player stopped while a `.groupPaused` waited (fix round 2): applied now.
  func listenerStoppedPlaying() {
    guard let cause = pendingGroupPause, role == .listener else { return }
    pendingGroupPause = nil
    groupPauseGeneration += 1
    applyGroupPause(cause)
  }

  private func applyGroupPause(_ cause: ListenTogetherPauseCause) {
    guard pauseCause == nil else { return }
    setPauseCause(cause)
    deliverPauseMessage(.pausedBecauseSomeoneLeft(cause, isSharer: false))
  }

  /// How long a `.groupPaused` waits for a still-playing listener to stop (fix round 2, m1).
  static let groupPauseSettle: Duration = .seconds(2)

  /// A `.groupPaused` this soon after the person sharing came back is ignored (fix round 1, M8).
  static let sharerReturnPauseGrace: TimeInterval = 5

  /// Listener: "Someone left Listen Together" waits `listenerLeftHold` for the sharer's `.groupPaused`.
  /// With ids (fix round 1, a11y M1), departures a `.groupPaused` named are never said, whatever the
  /// timing; others are. Count-only: a drop just after a `.groupPaused` is the departure it explained.
  private func holdLeftAnnouncement(ids: Set<UUID>) {
    // A `.groupPaused` without ids (a count-only sharer) explains a drop just after it.
    if ids.isEmpty || !lastGroupPausedNamedIDs {
      if let at = lastGroupPausedAt, now().timeIntervalSince(at) <= 2 { return }
    }
    if !ids.isEmpty {
      let unexplained = ids.subtracting(explainedDepartures)
      guard !unexplained.isEmpty else { return }
      heldLeftIDs.formUnion(unexplained)
    }
    leftHoldGeneration += 1
    let generation = leftHoldGeneration
    let usesIDs = !ids.isEmpty
    schedule(Self.listenerLeftHold) { [weak self] in
      guard let self, self.role == .listener, self.leftHoldGeneration == generation else { return }
      if usesIDs {
        guard !self.heldLeftIDs.isEmpty else { return }
        self.heldLeftIDs = []
      }
      self.announcer.announce(ListenTogetherAnnouncements.left())
    }
  }

  /// Any play (here or by someone else) ends the pause episode, silently (1.6).
  func clearPauseCause() {
    announcesPauseWhenActive = false
    // A pause still waiting for this phone to stop is overtaken by the play (fix round 2, m1).
    pendingGroupPause = nil
    groupPauseGeneration += 1
    let hadPause = pauseCause != nil
    setPauseCause(nil)
    if hadPause { messages.removePauseNotificationIfShown() }
  }

  // MARK: Sharer: joiners in step (start-position fix round 1, C1)

  /// Someone joined: the sharer's place is protected again until each joiner reports `.inStep`, and is
  /// asserted for them (start-position fix B), unless another book is loaded.
  private func sharerJoinersArrived(ids: Set<UUID> = [], count: Int = 0) {
    awaitingInStep.formUnion(ids)
    awaitingAnonymousInStep += count
    hasInStepSinceArm = false
    sharerTarget?.rearm()
    bridge?.assertPosition()
  }

  /// A listener said it is in step at `time`. At the sharer's place: that joiner is confirmed, and
  /// when every joiner is, the group is. Elsewhere: the place is asserted again (at most every 3 s).
  private func listenerInStep(at time: TimeInterval, from id: UUID?) {
    guard role == .sharer, let target = sharerTarget else { return }
    // Round 2 (N2): listeners report after every group time; once everyone is in step, a report (late,
    // or after someone's deliberate skip) must never pull anyone back.
    guard !target.isGroupEstablished else { return }
    guard target.isInStepReportAtOwnPlace(time) else {
      Self.logger.info(
        "Listen Together: a listener is in step at \(time, privacy: .public), not at the sharer's place \(target.bookTime, privacy: .public)")
      target.requestReassert()
      return
    }
    Self.logger.info("Listen Together: a listener is in step at the sharer's place \(time, privacy: .public)")
    if let id, awaitingInStep.contains(id) {
      awaitingInStep.remove(id)
    } else if awaitingAnonymousInStep > 0 {
      awaitingAnonymousInStep -= 1
    }
    hasInStepSinceArm = true
    confirmIfEveryJoinerIsInStep()
  }

  private func confirmIfEveryJoinerIsInStep() {
    guard role == .sharer, hasInStepSinceArm, awaitingInStep.isEmpty, awaitingAnonymousInStep == 0 else { return }
    sharerTarget?.confirmGroup()
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
        guard let self else { return }
        // The person's own play or pause: "Paused by another listener" no longer applies.
        if case .played = event {
          self.setPausedByOther(false)
          self.suppressPausedActionUntil = nil
          self.clearPauseCause()
        }
        if case .paused = event {
          self.setPausedByOther(false)
          // The automatic pause travels as `.groupPaused`, never also as "Another listener paused".
          if let until = self.suppressPausedActionUntil {
            self.suppressPausedActionUntil = nil
            if self.now() <= until { return }
          }
        }
        guard let action = self.remoteAction(for: event) else { return }
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
        if message == .heartbeat { self.isHeartbeatQueued = false }
      }
    }
  }

  private func remoteAction(for event: LocalPlaybackEvent) -> RemoteAction? {
    switch event {
    case .played: return .resumed
    case .paused: return .paused
    case .rateChanged(let rate): return .speedChanged(rate: rate)
    case .reasserted: return nil   // the sharer's own place, asserted to the coordinator only
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
    scheduleSessionTimer(Self.stateRequestInterval) { [weak self, weak transport] in
      guard let transport else { return }
      self?.requestStateIfNeeded(on: transport)
    }
  }

  /// I1: failed piece loads are tried again on a timer (5, 10, 20, then every 30 s), whatever the
  /// journal does, until the session ends.
  private func scheduleLoadRetry(on transport: ListenTogetherTransport, attempt: Int) {
    let delay = Self.loadRetryDelays[min(attempt, Self.loadRetryDelays.count - 1)]
    scheduleSessionTimer(delay) { [weak self, weak transport] in
      guard let self, let transport, self.transport === transport, self.role == .listener else { return }
      var next = 0
      if transport.hasFailedPieceLoads {
        Self.logger.info("Listen Together: retrying failed piece loads")
        transport.retryFailedPieceLoads()
        next = attempt + 1
      }
      self.scheduleLoadRetry(on: transport, attempt: next)
    }
  }

  private func startPresenceWatch(on transport: ListenTogetherTransport) {
    lastSharerContact = now()
    schedulePresenceCheck(on: transport)
  }

  private func schedulePresenceCheck(on transport: ListenTogetherTransport) {
    scheduleSessionTimer(Self.heartbeatInterval) { [weak self, weak transport] in
      guard let self, let transport, self.transport === transport, self.role == .listener else { return }
      self.checkSharerPresence()
      if self.transport === transport { self.schedulePresenceCheck(on: transport) }
    }
  }

  /// Decision 9 as ruled in fix round 1 (I2):
  /// - Silence (nothing from the sharer for `sharerSilenceLimit`) while the group needs them (playing,
  ///   waiting for a piece, or no manifest yet) only shows `.waitingForSharer`. It never pauses the
  ///   group and never ends the session: a sharer whose app is suspended is still in the session.
  /// - Only the sharer leaving the roster starts the grace: the group pauses, and if they are not
  ///   back within `sharerReturnLimit` the session ends with `.sharerLeft`.
  func checkSharerPresence() {
    guard role == .listener else { return }
    let now = now()
    if let since = sharerMissingSince, now.timeIntervalSince(since) >= Self.sharerReturnLimit {
      Self.logger.info("Listen Together: the sharer did not come back; ending")
      tearDown(reason: .sharerLeft)
      return
    }
    let needsSharer = listener.map { $0.isPlaying || $0.isWaitingForPiece } ?? true
    if !needsSharer {
      // Paused with nothing awaited: a sharer who paused and locked the phone is fine.
      lastSharerContact = now
      setSharerSilent(false)
    } else if let last = lastSharerContact, now.timeIntervalSince(last) > Self.sharerSilenceLimit {
      setSharerSilent(true)
    }
  }

  private func setSharerSilent(_ silent: Bool) {
    guard isSharerSilent != silent else { return }
    isSharerSilent = silent
    Self.logger.info("Listen Together: sharer silent=\(silent, privacy: .public)")
    updateSharerNotice()
  }

  private func updateSharerNotice() {
    let waiting = isSharerSilent || sharerMissingSince != nil
    if waiting {
      setNotice(.waitingForSharer)
    } else if notice == .waitingForSharer {
      setNotice(nil)
    }
  }

  /// The roster: the sharer (known by id from their messages) missing starts the grace, back ends it.
  /// Without ids or before the sharer's id is known: a roster of one, after having had more, counts.
  private func noteRoster(count: Int, ids: Set<UUID>) {
    let size = ids.isEmpty ? count : ids.count
    guard role == .listener, size > 0 else { return }
    let sharerPresent: Bool
    if let sharer = sharerParticipantID, !ids.isEmpty {
      sharerPresent = ids.contains(sharer)
    } else {
      if size >= 2 { hasSeenOtherParticipants = true }
      sharerPresent = size >= 2 || !hasSeenOtherParticipants
    }
    if sharerPresent {
      sharerReturned()
    } else {
      sharerLeftRoster()
    }
  }

  private func sharerLeftRoster() {
    guard role == .listener, sharerMissingSince == nil else { return }
    sharerMissingSince = now()
    Self.logger.info("Listen Together: the sharer left the roster; waiting up to 60 s")
    setSharerGraceRunning(true)
    listener?.isHeldForSharer = true
    updateSharerNotice()
    // E3: status + one announcement + Speak, for the grace only (a11y I4).
    messages.deliver(.waitingForSharer)
    // Everyone pauses together: this device stops, and its stall suspension makes the group wait.
    listener?.holdForSharer()
    bridge?.holdForSharer()
  }

  private func sharerReturned() {
    guard sharerMissingSince != nil else { return }
    sharerMissingSince = nil
    sharerReturnedAt = now()
    Self.logger.info("Listen Together: the sharer is back")
    setSharerGraceRunning(false)
    listener?.isHeldForSharer = false
    messages.deliver(.sharerBack)
    bridge?.releaseSharerHold()
    updateSharerNotice()
  }

  /// A message only the sharer sends arrived: they are neither silent nor gone.
  private func sharerHeard() {
    guard role == .listener else { return }
    lastSharerContact = now()
    // Final review M6: during the roster grace a message alone doesn't prove the sharer is back (a
    // heartbeat queued before they left can arrive late). Only the sharer's own id, back in the roster,
    // ends the grace here; otherwise the roster does.
    if sharerMissingSince == nil || isSharerInRoster { sharerReturned() }
    setSharerSilent(false)
  }

  /// The sharer's participant id is known and in the latest roster.
  private var isSharerInRoster: Bool {
    guard let sharer = sharerParticipantID else { return false }
    return rosterIDs.contains(sharer)
  }
}
