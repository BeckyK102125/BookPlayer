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
}

extension ListenTogetherTransport {
  func end() { leave() }
  func stopReceivingPieces() {}
  var hasFailedPieceLoads: Bool { false }
  func retryFailedPieceLoads() {}
  func reloadPiece(attachmentID: UUID) {}
  func hasAttachment(_ id: UUID) -> Bool? { nil }
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
/// or, once the journal has refused pieces, as chunks on a second messenger (`MessengerPieceChannel`,
/// transfer fix B). The switch is per session and announced, so both sides agree; the protocol and
/// everything above it are the same in both modes.
@MainActor
final class GroupSessionTransport: ListenTogetherTransport, BPLogger {
  private let session: GroupSession<ListenTogetherActivity>
  private let messenger: GroupSessionMessenger
  private let journal: GroupSessionJournal
  /// Transfer fix B: raw chunk and chunk-control `Data` only.
  private let chunkMessenger: GroupSessionMessenger
  private let channel: MessengerPieceChannel
  private let participants: ListenTogetherParticipantDirectory
  private let downloadFolder: URL
  private let isAppActive: @MainActor () -> Bool
  private var tasks: [Task<Void, Never>] = []
  private var seenAttachments = Set<UUID>()
  /// Every attachment in the journal's latest list, by id (to load one again).
  private var knownAttachments: [UUID: GroupSessionJournal.Attachment] = [:]
  /// Listener: attachments whose load failed, waiting for `retryFailedPieceLoads()`.
  private var failedAttachments = Set<UUID>()
  /// Sharer: the ids in the journal's latest list, once one has arrived.
  private var latestAttachmentIDs: Set<UUID>?
  /// The sharer never downloads: set before its first upload, so its own attachments are not loaded back.
  private var isUploader = false
  /// A listener with their own copy never downloads either (addendum 2).
  private var receivesPieces = true
  /// Journal or chunks, for this session.
  private var modeSwitch = TransportModeSwitch()
  /// Listener: pieces announced (`pieceUploaded`) before the sharer's switch to chunks was heard.
  private var announcedBeforeChunks: [UUID] = []
  let events: AsyncStream<TransportEvent>
  private let continuation: AsyncStream<TransportEvent>.Continuation

  init(
    session: GroupSession<ListenTogetherActivity>, downloadFolder: URL,
    isAppActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
  ) {
    self.session = session
    self.messenger = GroupSessionMessenger(session: session, deliveryMode: .reliable)
    self.journal = GroupSessionJournal(session: session)
    let chunkMessenger = GroupSessionMessenger(session: session, deliveryMode: .reliable)
    self.chunkMessenger = chunkMessenger
    let participants = ListenTogetherParticipantDirectory()
    self.participants = participants
    self.channel = MessengerPieceChannel(folder: downloadFolder) { data, recipient in
      guard let recipient else {
        try await chunkMessenger.send(data)
        return
      }
      // Someone who has left meanwhile gets nothing.
      guard let participant = participants.byID[recipient] else { return }
      try await chunkMessenger.send(data, to: .only([participant]))
    }
    self.downloadFolder = downloadFolder
    self.isAppActive = isAppActive
    let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    self.events = stream
    self.continuation = continuation

    channel.onPieceReceived = { [continuation] id, url in
      continuation.yield(.attachmentReceived(id: id, url: url))
    }
    channel.onModeAnnounced = { [weak self] mode in self?.modeAnnounced(mode) }

    tasks.append(Task { [weak self, messenger, continuation] in
      for await (message, context) in messenger.messages(of: ListenTogetherMessage.self) {
        switch message {
        case .declinedNoCopy:
          continuation.yield(.participantDeclined(id: context.source.id))
        case .manifest, .pieceUploaded, .heartbeat:
          self?.heardSharer(context.source.id)
          if case .pieceUploaded(_, let attachmentID) = message { self?.pieceAnnounced(attachmentID) }
          continuation.yield(.sharerParticipant(id: context.source.id))
          continuation.yield(.message(message))
        default:
          continuation.yield(.message(message))
        }
      }
    })
    tasks.append(Task { [weak self, chunkMessenger] in
      for await (data, context) in chunkMessenger.messages(of: Data.self) {
        self?.channel.receive(data, from: context.source.id)
      }
    })
    tasks.append(Task { [weak self] in
      guard let publisher = self?.session.$activeParticipants.values else { return }
      for await active in publisher {
        self?.rosterChanged(active)
        self?.continuation.yield(.participantsChanged(count: active.count, ids: Set(active.map(\.id))))
      }
    })
    tasks.append(Task { [weak self] in
      guard let publisher = self?.session.$state.values else { return }
      for await state in publisher {
        Self.logger.info("Listen Together: group session state \(String(describing: state), privacy: .public)")
        if case .invalidated = state {
          self?.continuation.yield(.invalidated)
          self?.continuation.finish()
        }
      }
    })
    tasks.append(Task { [weak self] in
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

  /// Journal first. A journal failure that switches the session to chunks (`TransportModeSwitch`) is
  /// not thrown: the same piece goes out as chunks at once, after the listeners have been told.
  func upload(fileAt url: URL) async throws -> UUID {
    isUploader = true
    if modeSwitch.mode == .journal {
      let activeAtStart = isAppActive()
      do {
        let attachment = try await journal.add(
          PieceTransfer(url: url), metadata: PieceMetadata(pathExtension: url.pathExtension))
        modeSwitch.journalAddSucceeded()
        seenAttachments.insert(attachment.id)
        return attachment.id
      } catch {
        let activeNow = isAppActive()
        let interrupted = PieceRetryPolicy.isInterruption(error) || !activeAtStart || !activeNow
        let notSupported = TransportModeSwitch.isNotSupported(error)
        let switched = modeSwitch.journalAddFailed(isNotSupported: notSupported, isInterruption: interrupted)
        Self.logger.error(
          "Listen Together: journal upload failed: \(ListenTogetherErrorDescription.describe(error), privacy: .public) notSupported=\(notSupported, privacy: .public) interruption=\(interrupted, privacy: .public) switching=\(switched, privacy: .public)")
        guard switched else { throw error }
        Self.logger.info(
          "Listen Together: transport mode chunks (sharer, after \(notSupported ? "notSupported" : "\(TransportModeSwitch.failureLimit) journal failures", privacy: .public))")
        await channel.announceMode(to: nil)
      }
    }
    return try await channel.upload(fileAt: url)
  }

  func stopReceivingPieces() {
    receivesPieces = false
    channel.stopReceiving()
  }

  var hasFailedPieceLoads: Bool { !failedAttachments.isEmpty || channel.hasStalePieces }

  func retryFailedPieceLoads() {
    channel.retryStale()
    let retrying = failedAttachments.compactMap { knownAttachments[$0] }
    failedAttachments = []
    guard !retrying.isEmpty else { return }
    // Seen again, so a journal list change meanwhile doesn't load the same piece twice.
    retrying.forEach { seenAttachments.insert($0.id) }
    // Tracked, so `leave()` cancels it with the rest.
    tasks.append(Task { [weak self] in
      for attachment in retrying { await self?.load(attachment) }
    })
  }

  func reloadPiece(attachmentID: UUID) {
    guard let attachment = knownAttachments[attachmentID] else {
      // Not in the journal: a piece sent as chunks.
      if channel.knows(attachmentID) || modeSwitch.mode == .chunks { channel.reload(attachmentID) }
      return
    }
    failedAttachments.remove(attachmentID)
    seenAttachments.insert(attachmentID)
    tasks.append(Task { [weak self] in await self?.load(attachment) })
  }

  func hasAttachment(_ id: UUID) -> Bool? {
    if let kept = channel.hasPiece(id) { return kept }
    return latestAttachmentIDs.map { $0.contains(id) }
  }

  func leave() {
    stopEverything()
    session.leave()
  }

  /// Sharer: SharePlay ends for everyone (transfer fix, item 4).
  func end() {
    stopEverything()
    session.end()
  }

  private func stopEverything() {
    tasks.forEach { $0.cancel() }
    tasks = []
    channel.stop()
    continuation.finish()
  }

  // MARK: Chunks (transfer fix B)

  private func heardSharer(_ id: UUID) {
    guard !isUploader else { return }
    channel.sharerID = id
  }

  /// Listener: the sharer announced a piece. In chunk mode it is asked for unless it is arriving.
  private func pieceAnnounced(_ id: UUID) {
    guard !isUploader, receivesPieces, knownAttachments[id] == nil else { return }
    guard modeSwitch.mode == .chunks else {
      // Kept in case the switch is heard later (messages on two messengers have no common order).
      if !announcedBeforeChunks.contains(id) { announcedBeforeChunks.append(id) }
      if announcedBeforeChunks.count > 500 { announcedBeforeChunks.removeFirst() }
      return
    }
    channel.pieceAnnounced(id)
  }

  private func modeAnnounced(_ mode: ListenTogetherTransportMode) {
    guard !isUploader, modeSwitch.adopt(mode) else { return }
    Self.logger.info("Listen Together: transport mode chunks (listener, announced by the sharer)")
    let waiting = announcedBeforeChunks
    announcedBeforeChunks = []
    for id in waiting where knownAttachments[id] == nil { channel.pieceAnnounced(id) }
  }

  /// Keeps the participants for chunk replies; in chunk mode, the sharer tells anyone new.
  private func rosterChanged(_ active: Set<Participant>) {
    let previous = Set(participants.byID.keys)
    participants.byID = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard isUploader, modeSwitch.mode == .chunks else { return }
    let me = session.localParticipant.id
    for id in Set(participants.byID.keys).subtracting(previous) where id != me {
      tasks.append(Task { [weak self] in await self?.channel.announceMode(to: id) })
    }
  }

  // MARK: Journal

  private func receive(_ attachments: [GroupSessionJournal.Attachment]) async {
    latestAttachmentIDs = Set(attachments.map(\.id))
    knownAttachments = Dictionary(attachments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard !isUploader, receivesPieces else { return }
    for attachment in attachments where !seenAttachments.contains(attachment.id) {
      seenAttachments.insert(attachment.id)
      await load(attachment)
    }
  }

  /// Loads one piece into the download folder, named with the sender's extension. A failure is kept
  /// for `retryFailedPieceLoads()`.
  private func load(_ attachment: GroupSessionJournal.Attachment) async {
    guard receivesPieces else { return }
    var loaded: URL?
    let start = Date()
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
      continuation.yield(.attachmentReceived(id: attachment.id, url: destination))
    } catch {
      // Nothing may be left outside the folders the session cleans up.
      if let loaded { try? FileManager.default.removeItem(at: loaded) }
      // Tried again on the service's timer, and when the journal's attachment list changes.
      seenAttachments.remove(attachment.id)
      failedAttachments.insert(attachment.id)
      Self.logger.error(
        "Listen Together: could not load a piece: \(ListenTogetherErrorDescription.describe(error), privacy: .public)")
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
