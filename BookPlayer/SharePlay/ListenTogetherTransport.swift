import BookPlayerKit
import CoreTransferable
import Foundation
import GroupActivities
import UIKit
import UniformTypeIdentifiers

enum TransportEvent: Equatable {
  case message(ListenTogetherMessage)
  /// The roster. `ids` identifies each participant (empty when unknown, as in older tests): with ids,
  /// people who join and decline (owners-only, no copy) are never counted or announced.
  case participantsChanged(count: Int, ids: Set<UUID> = [])
  /// A participant sent `.declinedNoCopy`: they couldn't join an owners-only share.
  case participantDeclined(id: UUID?)
  case attachmentReceived(id: UUID, url: URL)
  case invalidated
  /// The participant who sent a message only the sharer sends (manifest, piece map, heartbeat): lets
  /// listeners tell when the sharer leaves the roster, however many people are in it.
  case sharerParticipant(id: UUID)
  /// A listener reported `.inStep(at:)`; `from` is its participant id (nil when unknown).
  case inStep(at: TimeInterval, from: UUID?)
  /// A listener said it is leaving (`.listenerLeaving`, build 5); `id` is its participant id (nil when
  /// unknown).
  case listenerLeaving(id: UUID?)
}

/// Everything the session service needs from SharePlay, so tests can use a fake.
@MainActor
protocol ListenTogetherTransport: AnyObject {
  var events: AsyncStream<TransportEvent> { get }
  func send(_ message: ListenTogetherMessage) async throws
  /// Uploads a file as a journal attachment and returns the attachment id.
  func upload(fileAt url: URL) async throws -> UUID
  func leave()
  /// Sharer: ends the group session for everyone (`GroupSession.end()`), not only for this device.
  func end()
  /// Stops sending and receiving pieces at once, before the share's files are deleted (End).
  func stopPieceTransfers()
  /// A listener playing their own copy never downloads: pieces in the journal are not loaded.
  func stopReceivingPieces()
  /// Listener: some piece loads failed and wait to be tried again.
  var hasFailedPieceLoads: Bool { get }
  /// Listener: tries every failed piece load again (on the service's timer, not only when the
  /// journal's list changes).
  func retryFailedPieceLoads()
  /// Listener: loads this attachment again (the received file could not be played).
  func reloadPiece(attachmentID: UUID)
  /// Sharer: whether the journal still holds this attachment; nil when not known.
  func hasAttachment(_ id: UUID) -> Bool?
  /// Sharer (build 5, B3): returns once this device has joined and someone else is in the session, so
  /// no piece is exported or uploaded while the sharer is alone. False when the transport stopped (or
  /// the waiting task was cancelled) first.
  func waitUntilReadyToSend() async -> Bool
}

extension ListenTogetherTransport {
  func end() { leave() }
  func stopPieceTransfers() {}
  func stopReceivingPieces() {}
  var hasFailedPieceLoads: Bool { false }
  func retryFailedPieceLoads() {}
  func reloadPiece(attachmentID: UUID) {}
  func hasAttachment(_ id: UUID) -> Bool? { nil }
  func waitUntilReadyToSend() async -> Bool { true }
}

/// A sent or received audio piece. Sent as `Data` (transfer fix A): the journal's `add` only packages
/// Data-producing representations, so a `FileRepresentation` was refused. The sharer's file is
/// memory-mapped, so a piece (at most `ListenTogetherLimits.maxPieceBytes`) isn't copied into RAM.
/// `.data` because whole-file pieces can be any audio format; the extension travels separately as
/// `PieceMetadata`, and the listener names the file with it.
struct PieceTransfer: Transferable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(contentType: .data) { piece in
      try Data(contentsOf: piece.url, options: .mappedIfSafe)
    } importing: { data in
      // Inside the Listen Together root, so launch cleanup (`ShareStorage.cleanAll()`) covers it.
      // Named with the sender's extension once the metadata is read (`receivedFileName`).
      let folder = ShareStorage.defaultRoot.appendingPathComponent("incoming", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let destination = folder.appendingPathComponent(UUID().uuidString)
      try data.write(to: destination, options: .atomic)
      return PieceTransfer(url: destination)
    }
  }

  /// The name a received piece gets: the sender's extension (sanitised), `m4a` when there is none.
  static func receivedFileName(for importedURL: URL, pathExtension: String?) -> String {
    let wire = ChunkFrame.wireExtension(pathExtension ?? "")
    return "\(importedURL.lastPathComponent).\(wire.isEmpty ? "m4a" : wire)"
  }
}

/// Travels with each journal attachment: the listener names the file with the sender's extension, so
/// whole-file `.mp3` / `.m4b` pieces keep theirs.
struct PieceMetadata: Codable, Equatable {
  let pathExtension: String
}

/// The real transport: messages over `GroupSessionMessenger`, audio pieces over `GroupSessionJournal`,
/// or, once the journal has refused pieces (on the sharer's add or a listener's load), as chunks on a
/// second messenger (`MessengerPieceChannel`, transfer fix B). Every mode decision is
/// `ListenTogetherTransferCoordinator`'s; this class only wires SharePlay to it. The protocol and
/// everything above it are the same in both modes.
@MainActor
final class GroupSessionTransport: ListenTogetherTransport, BPLogger {
  private let session: GroupSession<ListenTogetherActivity>
  private let messenger: GroupSessionMessenger
  private let journal: GroupSessionJournal
  /// Transfer fix B: raw chunk and chunk-control `Data` only.
  private let chunkMessenger: GroupSessionMessenger
  private let transfers: ListenTogetherTransferCoordinator
  private let participants: ListenTogetherParticipantDirectory
  private let downloadFolder: URL
  private let isAppActive: @MainActor () -> Bool
  /// The long-lived loops (messages, chunks, roster, state, journal list).
  private var loops: [Task<Void, Never>] = []
  /// One-off loads; each forgets itself when done (Minor 9).
  private var loads: [UUID: Task<Void, Never>] = [:]
  private var seenAttachments = Set<UUID>()
  /// Every attachment in the journal's latest list, by id (to load one again).
  private var knownAttachments: [UUID: GroupSessionJournal.Attachment] = [:]
  /// Listener: attachments whose load failed, waiting for `retryFailedPieceLoads()`.
  private var failedAttachments = Set<UUID>()
  /// A listener with their own copy never downloads either (addendum 2).
  private var receivesPieces = true
  /// Build 5 (B3): pieces wait until this device has joined and someone else is here.
  private let sendGate = ListenTogetherSendGate()
  let events: AsyncStream<TransportEvent>
  private let continuation: AsyncStream<TransportEvent>.Continuation

  init(
    session: GroupSession<ListenTogetherActivity>, downloadFolder: URL,
    isAppActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
  ) {
    self.session = session
    let messenger = GroupSessionMessenger(session: session, deliveryMode: .reliable)
    self.messenger = messenger
    let journal = GroupSessionJournal(session: session)
    self.journal = journal
    let chunkMessenger = GroupSessionMessenger(session: session, deliveryMode: .reliable)
    self.chunkMessenger = chunkMessenger
    let participants = ListenTogetherParticipantDirectory()
    self.participants = participants
    let channel = MessengerPieceChannel(folder: downloadFolder) { data, recipient in
      guard let recipient else {
        try await chunkMessenger.send(data)
        return
      }
      // Someone who has left meanwhile gets nothing.
      guard let participant = participants.byID[recipient] else { return }
      try await chunkMessenger.send(data, to: .only([participant]))
    }
    self.transfers = ListenTogetherTransferCoordinator(
      channel: channel,
      journalAdd: { url in
        try await journal.add(PieceTransfer(url: url), metadata: PieceMetadata(pathExtension: url.pathExtension)).id
      },
      sendMessage: { message in try await messenger.send(message) },
      isAppActive: isAppActive)
    self.downloadFolder = downloadFolder
    self.isAppActive = isAppActive
    let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    self.events = stream
    self.continuation = continuation

    channel.onPieceReceived = { [weak self, continuation] id, url in
      self?.transfers.chunkPieceReceived(id)
      continuation.yield(.attachmentReceived(id: id, url: url))
    }

    loops.append(Task { [weak self, messenger, continuation] in
      for await (message, context) in messenger.messages(of: ListenTogetherMessage.self) {
        self?.transfers.messageReceived(message, from: context.source.id)
        switch message {
        case .declinedNoCopy:
          continuation.yield(.participantDeclined(id: context.source.id))
        case .manifest, .pieceUploaded, .heartbeat:
          continuation.yield(.sharerParticipant(id: context.source.id))
          continuation.yield(.message(message))
        case .inStep(let time):
          continuation.yield(.inStep(at: time, from: context.source.id))
        case .listenerLeaving:
          continuation.yield(.listenerLeaving(id: context.source.id))
        default:
          continuation.yield(.message(message))
        }
      }
    })
    loops.append(Task { [weak self, chunkMessenger] in
      for await (data, context) in chunkMessenger.messages(of: Data.self) {
        self?.transfers.channel.receive(data, from: context.source.id)
      }
    })
    loops.append(Task { [weak self] in
      guard let publisher = self?.session.$activeParticipants.values else { return }
      for await active in publisher {
        guard let self else { return }
        self.participants.byID = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localID = self.session.localParticipant.id
        self.sendGate.update(hasOthers: active.contains { $0.id != localID })
        self.transfers.rosterChanged(Set(active.map(\.id)), localID: self.session.localParticipant.id)
        self.continuation.yield(.participantsChanged(count: active.count, ids: Set(active.map(\.id))))
      }
    })
    loops.append(Task { [weak self] in
      guard let publisher = self?.session.$state.values else { return }
      for await state in publisher {
        Self.logger.info("Listen Together: group session state \(Self.describe(state), privacy: .public)")
        if case .joined = state { self?.sendGate.update(isJoined: true) }
        if case .invalidated = state {
          self?.continuation.yield(.invalidated)
          self?.continuation.finish()
        }
      }
    })
    loops.append(Task { [weak self] in
      guard let attachments = self?.journal.attachments else { return }
      for await list in attachments {
        guard let self else { return }
        await self.receive(list)
      }
    })
  }

  func send(_ message: ListenTogetherMessage) async throws {
    try await messenger.send(message)
  }

  func upload(fileAt url: URL) async throws -> UUID {
    let id = try await transfers.upload(fileAt: url)
    seenAttachments.insert(id)
    return id
  }

  func stopReceivingPieces() {
    receivesPieces = false
    transfers.stopReceiving()
  }

  var hasFailedPieceLoads: Bool {
    (!failedAttachments.isEmpty && !transfers.hasAbandonedJournal) || transfers.channel.hasStalePieces
  }

  func retryFailedPieceLoads() {
    transfers.channel.retryStale()
    let retrying = failedAttachments.compactMap { knownAttachments[$0] }
    failedAttachments = []
    // C2: once the pieces come again as chunks, failed journal loads are not retried.
    guard !retrying.isEmpty, !transfers.hasAbandonedJournal else { return }
    // Seen again, so a journal list change meanwhile doesn't load the same piece twice.
    retrying.forEach { seenAttachments.insert($0.id) }
    startLoads(retrying)
  }

  func reloadPiece(attachmentID: UUID) {
    let attachment = knownAttachments[attachmentID]
    if transfers.reloadChunkPiece(attachmentID, isJournalAttachment: attachment != nil) { return }
    guard let attachment else { return }
    failedAttachments.remove(attachmentID)
    seenAttachments.insert(attachmentID)
    startLoads([attachment])
  }

  func hasAttachment(_ id: UUID) -> Bool? {
    transfers.hasAttachment(id)
  }

  func waitUntilReadyToSend() async -> Bool {
    if !sendGate.isOpen {
      Self.logger.info(
        "Listen Together: pieces wait until the session is joined and someone else is here (joined=\(self.sendGate.isJoined, privacy: .public) others=\(self.sendGate.hasOthers, privacy: .public))")
    }
    return await sendGate.wait()
  }

  /// Chunk sends and receives stop at once (End, before the share folder is deleted: Minor 1).
  func stopPieceTransfers() {
    transfers.stop()
  }

  func leave() {
    stopEverything()
    Self.logger.info("Listen Together: leaving the group session, state before: \(Self.describe(self.session.state), privacy: .public)")
    session.leave()
    logStateAfterwards(of: session, call: "leave")
  }

  /// Sharer: SharePlay ends for everyone (transfer fix, item 4).
  func end() {
    stopEverything()
    Self.logger.info("Listen Together: ending the group session, state before: \(Self.describe(self.session.state), privacy: .public)")
    session.end()
    logStateAfterwards(of: session, call: "end")
  }

  /// A6 (build 5): after `end()` or `leave()` the state loop is gone, so a small observer logs every
  /// state the session moves through for a few seconds, then its state at 1 s, so a device log shows
  /// whether the call really invalidated the session. Public and without personal data.
  private func logStateAfterwards(of session: GroupSession<ListenTogetherActivity>, call: String) {
    let observer = Task { @MainActor in
      for await state in session.$state.values {
        Self.logger.info("Listen Together: after \(call, privacy: .public), group session state \(Self.describe(state), privacy: .public)")
        if case .invalidated = state { return }
      }
    }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1))
      Self.logger.info("Listen Together: 1 s after \(call, privacy: .public), group session state \(Self.describe(session.state), privacy: .public)")
      try? await Task.sleep(for: .seconds(4))
      observer.cancel()
    }
  }

  /// The session state for logs: the case, and for an invalidation only the error's domain and code.
  nonisolated static func describe(_ state: GroupSession<ListenTogetherActivity>.State) -> String {
    switch state {
    case .waiting: return "waiting"
    case .joined: return "joined"
    case .invalidated(let reason):
      let error = reason as NSError
      return "invalidated(\(error.domain) \(error.code))"
    @unknown default: return "unknown"
    }
  }

  private func stopEverything() {
    loops.forEach { $0.cancel() }
    loops = []
    loads.values.forEach { $0.cancel() }
    loads = [:]
    transfers.stop()
    sendGate.close()
    continuation.finish()
  }

  // MARK: Journal

  private func receive(_ attachments: [GroupSessionJournal.Attachment]) async {
    transfers.journalListChanged(Set(attachments.map(\.id)))
    knownAttachments = Dictionary(attachments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard !transfers.isUploader, receivesPieces, !transfers.hasAbandonedJournal else { return }
    for attachment in attachments where !seenAttachments.contains(attachment.id) {
      seenAttachments.insert(attachment.id)
      await load(attachment)
    }
  }

  private func startLoads(_ attachments: [GroupSessionJournal.Attachment]) {
    let key = UUID()
    loads[key] = Task { [weak self] in
      for attachment in attachments { await self?.load(attachment) }
      self?.loads[key] = nil
    }
  }

  /// Loads one piece into the download folder, named with the sender's extension. A failure is kept
  /// for `retryFailedPieceLoads()` and reported to the coordinator (C2).
  private func load(_ attachment: GroupSessionJournal.Attachment) async {
    guard receivesPieces else { return }
    var loaded: URL?
    let start = Date()
    let activeAtStart = isAppActive()
    Self.logger.info("Listen Together: attachment \(attachment.id.uuidString, privacy: .public) load start")
    do {
      let piece = try await attachment.load(PieceTransfer.self)
      loaded = piece.url
      let metadata = try? await attachment.loadMetadata(of: PieceMetadata.self)
      let destination = downloadFolder.appendingPathComponent(
        PieceTransfer.receivedFileName(for: piece.url, pathExtension: metadata?.pathExtension))
      try FileManager.default.moveItem(at: piece.url, to: destination)
      let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
      Self.logger.info(
        "Listen Together: attachment \(attachment.id.uuidString, privacy: .public) loaded in \(Date().timeIntervalSince(start), privacy: .public)s bytes=\(bytes, privacy: .public) ext=\(destination.pathExtension, privacy: .public) metadata=\(metadata != nil, privacy: .public)")
      transfers.journalPieceLoaded(attachment.id)
      continuation.yield(.attachmentReceived(id: attachment.id, url: destination))
    } catch {
      // Nothing may be left outside the folders the session cleans up.
      if let loaded { try? FileManager.default.removeItem(at: loaded) }
      // Tried again on the service's timer, and when the journal's attachment list changes.
      seenAttachments.remove(attachment.id)
      failedAttachments.insert(attachment.id)
      Self.logger.error(
        "Listen Together: could not load a piece: \(ListenTogetherErrorDescription.describe(error), privacy: .public)")
      transfers.journalLoadFailed(attachment.id, error: error, appWasActive: activeAtStart && isAppActive())
    }
  }
}

/// The session's participants by id, read by the chunk channel's send (outside the transport's init).
@MainActor
final class ListenTogetherParticipantDirectory {
  var byID: [UUID: Participant] = [:]
}

/// Owners-only share and no copy (addendum 2): the listener joins just long enough to tell the
/// others "declined, no copy", then leaves. Messages can only be sent from a joined session. Never
/// waits more than `limit`; the session is left whatever happens.
@MainActor
enum ListenTogetherDecline {
  static let limit: Duration = .seconds(3)

  static func sendAndLeave(_ session: GroupSession<ListenTogetherActivity>) {
    let messenger = GroupSessionMessenger(session: session, deliveryMode: .reliable)
    session.join()
    Task { @MainActor in
      await SharePlaySessionService.withTimeLimit(limit) {
        for await state in session.$state.values {
          if case .joined = state { break }
          if case .invalidated = state { return }
        }
        do {
          try await messenger.send(ListenTogetherMessage.declinedNoCopy)
        } catch {
          SharePlaySessionService.logger.error(
            "Listen Together: could not send the decline: \(error.localizedDescription)")
        }
      }
      session.leave()
    }
  }
}

/// Build 5 (B3): the sharer sends no piece until this device has joined the session and someone else is
/// in it. Waiters resume with true once both hold, or with false when the transport stops or the waiting
/// task is cancelled. It closes again while everyone else is gone.
@MainActor
final class ListenTogetherSendGate {
  private(set) var isJoined = false
  private(set) var hasOthers = false
  private(set) var isStopped = false
  private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

  var isOpen: Bool { isJoined && hasOthers && !isStopped }

  func update(isJoined: Bool? = nil, hasOthers: Bool? = nil) {
    if let isJoined { self.isJoined = isJoined }
    if let hasOthers { self.hasOthers = hasOthers }
    if isOpen { resumeAll(true) }
  }

  func close() {
    isStopped = true
    resumeAll(false)
  }

  func wait() async -> Bool {
    if isOpen { return true }
    if isStopped || Task.isCancelled { return false }
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        if isOpen {
          continuation.resume(returning: true)
        } else if isStopped || Task.isCancelled {
          continuation.resume(returning: false)
        } else {
          waiters[id] = continuation
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancel(id) }
    }
  }

  private func cancel(_ id: UUID) {
    waiters.removeValue(forKey: id)?.resume(returning: false)
  }

  private func resumeAll(_ value: Bool) {
    let waiting = waiters.values
    waiters = [:]
    waiting.forEach { $0.resume(returning: value) }
  }
}
