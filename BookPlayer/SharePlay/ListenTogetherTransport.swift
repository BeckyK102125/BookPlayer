import BookPlayerKit
import CoreTransferable
import Foundation
import GroupActivities
import UniformTypeIdentifiers

enum TransportEvent: Equatable {
  case message(ListenTogetherMessage)
  case participantsChanged(count: Int)
  case attachmentReceived(id: UUID, url: URL)
  case invalidated
}

/// Everything the session service needs from SharePlay, so tests can use a fake.
@MainActor
protocol ListenTogetherTransport: AnyObject {
  var events: AsyncStream<TransportEvent> { get }
  func send(_ message: ListenTogetherMessage) async throws
  /// Uploads a file as a journal attachment and returns the attachment id.
  func upload(fileAt url: URL) async throws -> UUID
  func leave()
}

/// A received or sent audio piece. File-backed so a 90 MB piece never sits in memory.
struct PieceTransfer: Transferable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(contentType: .audio) { piece in
      SentTransferredFile(piece.url)
    } importing: { received in
      // The system deletes `received.file` after this returns, so move it somewhere we own.
      let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("ListenTogether-incoming-\(UUID().uuidString).\(received.file.pathExtension)")
      try FileManager.default.moveItem(at: received.file, to: destination)
      return PieceTransfer(url: destination)
    }
  }
}

/// The real transport: messages over `GroupSessionMessenger`, audio pieces over `GroupSessionJournal`.
@MainActor
final class GroupSessionTransport: ListenTogetherTransport, BPLogger {
  private let session: GroupSession<ListenTogetherActivity>
  private let messenger: GroupSessionMessenger
  private let journal: GroupSessionJournal
  private let downloadFolder: URL
  private var tasks: [Task<Void, Never>] = []
  private var seenAttachments = Set<UUID>()
  /// The sharer never downloads: set before its first upload, so its own attachments are not loaded back.
  private var isUploader = false
  let events: AsyncStream<TransportEvent>
  private let continuation: AsyncStream<TransportEvent>.Continuation

  init(session: GroupSession<ListenTogetherActivity>, downloadFolder: URL) {
    self.session = session
    self.messenger = GroupSessionMessenger(session: session, deliveryMode: .reliable)
    self.journal = GroupSessionJournal(session: session)
    self.downloadFolder = downloadFolder
    let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    self.events = stream
    self.continuation = continuation

    tasks.append(Task { [messenger, continuation] in
      for await (message, _) in messenger.messages(of: ListenTogetherMessage.self) {
        continuation.yield(.message(message))
      }
    })
    tasks.append(Task { [weak self] in
      guard let publisher = self?.session.$activeParticipants.values else { return }
      for await participants in publisher {
        self?.continuation.yield(.participantsChanged(count: participants.count))
      }
    })
    tasks.append(Task { [weak self] in
      guard let publisher = self?.session.$state.values else { return }
      for await state in publisher {
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

  func upload(fileAt url: URL) async throws -> UUID {
    isUploader = true
    let attachment = try await journal.add(PieceTransfer(url: url))
    seenAttachments.insert(attachment.id)
    return attachment.id
  }

  func leave() {
    tasks.forEach { $0.cancel() }
    tasks = []
    session.leave()
    continuation.finish()
  }

  private func receive(_ attachments: [GroupSessionJournal.Attachment]) async {
    guard !isUploader else { return }
    for attachment in attachments where !seenAttachments.contains(attachment.id) {
      seenAttachments.insert(attachment.id)
      do {
        let piece = try await attachment.load(PieceTransfer.self)
        let destination = downloadFolder.appendingPathComponent(piece.url.lastPathComponent)
        try FileManager.default.moveItem(at: piece.url, to: destination)
        continuation.yield(.attachmentReceived(id: attachment.id, url: destination))
      } catch {
        // Try again the next time the journal's attachment list changes.
        seenAttachments.remove(attachment.id)
        Self.logger.error("Listen Together: could not load a piece: \(error.localizedDescription)")
      }
    }
  }
}
