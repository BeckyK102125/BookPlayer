import BookPlayerKit
import Combine
import Foundation

/// The running session: the sharer's export and upload pipeline, the transport event loop for both
/// roles, receiving pieces, and turning local playback events into messages for everyone else.
extension SharePlaySessionService {
  // MARK: Sharer

  /// Test seam: shares `item` over `transport` without a real GroupSession.
  func beginSharing(with transport: ListenTogetherTransport, item: PlayableItem) async {
    await beginSharing(with: transport, item: item, shareID: UUID())
  }

  /// Sends the manifest, then exports and uploads every piece starting where the sharer is listening.
  /// Returns when every piece is uploaded or the session has ended.
  func beginSharing(with transport: ListenTogetherTransport, item: PlayableItem, shareID: UUID) async {
    guard !isInSession else { return }
    role = .sharer
    self.shareID = shareID
    self.transport = transport
    participantCount = 1
    hasParticipantBaseline = false
    startEventLoop(on: transport)

    let target = SharerPlaybackTarget(playerManager: playerManager)
    sharerTarget = target
    let bridge = ListenTogetherCoordinatorBridge(target: target, shareID: shareID)
    self.bridge = bridge
    if let activeSession { bridge.coordinate(with: activeSession) }
    observeLocalEvents(of: target)

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
    let plan = PiecePlanner.plan(files: files, chapterStarts: item.chapters.map(\.start))
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
      })
    self.manifest = manifest
    setState(.sharing(participants: participantCount))
    await send(.manifest(manifest), on: transport)

    for piece in plan.uploadOrder(startingAt: item.currentTime) {
      guard self.transport === transport else { return }
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
      guard self.transport === transport else { return nil }
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

  /// Test seam (also used by `joinInvitation()`): listens to the share `shareID` over `transport`.
  func beginListening(with transport: ListenTogetherTransport, shareID: UUID) async {
    guard !isInSession else { return }
    role = .listener
    self.shareID = shareID
    self.transport = transport
    participantCount = 1
    hasParticipantBaseline = false
    announcer.resetDownloadProgress()
    setState(.listening(participants: participantCount, downloaded: 0))
    startEventLoop(on: transport)
  }

  private func receivedManifest(_ manifest: SharedBookManifest) {
    // Later copies (re-sent for late joiners) keep the existing player.
    guard role == .listener, listener == nil, manifest.shareID == shareID else { return }
    self.manifest = manifest
    let player = ListenerPlayer(manifest: manifest)
    let bridge = ListenTogetherCoordinatorBridge(target: player, shareID: manifest.shareID)
    player.onNeedsPiece = { [weak self] _ in self?.listenerNeedsPiece() }
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
    guard role == .listener else { return }
    pieceIndexByAttachment[attachmentID] = index
    if listener != nil, let url = heldAttachments.removeValue(forKey: attachmentID) {
      place(index: index, url: url)
    }
  }

  private func attachmentReceived(id: UUID, url: URL) {
    guard role == .listener else { return }
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
    setState(.listening(participants: participantCount, downloaded: listener?.timeline.arrivedFraction ?? 0))
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
    case .message(.sessionEnding), .invalidated:
      tearDown(reason: .normal)
    case .participantsChanged(let count):
      await participantsChanged(to: count, on: transport)
    }
  }

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
      // Late joiners get journal attachments automatically, but not earlier messages:
      // re-send the manifest and the piece map. Nothing is uploaded again.
      if role == .sharer, let manifest {
        await send(.manifest(manifest), on: transport)
        for message in uploadedPieceMessages {
          guard self.transport === transport else { return }
          await send(message, on: transport)
        }
      }
    } else if count < previous {
      announcer.announce(ListenTogetherAnnouncements.left())
    }
  }

  /// The local user's own actions become messages, so the others hear an announcement.
  private func observeLocalEvents(of target: ListenTogetherPlaybackTarget) {
    target.localEvents
      .sink { [weak self] event in
        guard let self, let transport = self.transport, let action = self.remoteAction(for: event) else { return }
        Task { await self.send(.action(action), on: transport) }
      }
      .store(in: &localEventsBag)
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
