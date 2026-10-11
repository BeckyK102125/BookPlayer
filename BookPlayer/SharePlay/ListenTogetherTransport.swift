import BookPlayerKit
import CoreTransferable
import Foundation
import GroupActivities
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
}

/// Everything the session service needs from SharePlay, so tests can use a fake.
@MainActor
protocol ListenTogetherTransport: AnyObject {
  var events: AsyncStream<TransportEvent> { get }
  func send(_ message: ListenTogetherMessage) async throws
  /// Uploads a file as a journal attachment and returns the attachment id.
  func upload(fileAt url: URL) async throws -> UUID
  func leave()
  /// A listener playing their own copy never downloads: pieces in the journal are not loaded.
  func stopReceivingPieces()
}

extension ListenTogetherTransport {
  func stopReceivingPieces() {}
}

/// A received or sent audio piece. File-backed so a 90 MB piece never sits in memory.
struct PieceTransfer: Transferable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(contentType: .audio) { piece in
      SentTransferredFile(piece.url)
    } importing: { received in
      // The system deletes `received.file` after this returns, so move it somewhere we own,
      // inside the Listen Together root so launch cleanup (`ShareStorage.cleanAll()`) covers it.
      let folder = ShareStorage.defaultRoot.appendingPathComponent("incoming", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let destination = folder
        .appendingPathComponent("\(UUID().uuidString).\(received.file.pathExtension)")
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
  /// A listener with their own copy never downloads either (addendum 2).
  private var receivesPieces = true
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
      for await (message, context) in messenger.messages(of: ListenTogetherMessage.self) {
        if case .declinedNoCopy = message {
          continuation.yield(.participantDeclined(id: context.source.id))
        } else {
          continuation.yield(.message(message))
        }
      }
    })
    tasks.append(Task { [weak self] in
      guard let publisher = self?.session.$activeParticipants.values else { return }
      for await participants in publisher {
        self?.continuation.yield(
          .participantsChanged(count: participants.count, ids: Set(participants.map(\.id))))
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

  func stopReceivingPieces() {
    receivesPieces = false
  }

  func leave() {
    tasks.forEach { $0.cancel() }
    tasks = []
    session.leave()
    continuation.finish()
  }

  private func receive(_ attachments: [GroupSessionJournal.Attachment]) async {
    guard !isUploader, receivesPieces else { return }
    for attachment in attachments where !seenAttachments.contains(attachment.id) {
      seenAttachments.insert(attachment.id)
      var loaded: URL?
      do {
        let piece = try await attachment.load(PieceTransfer.self)
        loaded = piece.url
        let destination = downloadFolder.appendingPathComponent(piece.url.lastPathComponent)
        try FileManager.default.moveItem(at: piece.url, to: destination)
        continuation.yield(.attachmentReceived(id: attachment.id, url: destination))
      } catch {
        // Nothing may be left outside the folders the session cleans up.
        if let loaded { try? FileManager.default.removeItem(at: loaded) }
        // Try again the next time the journal's attachment list changes.
        seenAttachments.remove(attachment.id)
        Self.logger.error("Listen Together: could not load a piece: \(error.localizedDescription)")
      }
    }
  }
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
