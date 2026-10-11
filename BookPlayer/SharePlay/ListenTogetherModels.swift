import Foundation

enum ListenTogetherLimits {
  /// SharePlay journal attachments are capped at 100 MB, but a journal piece now travels as `Data` and
  /// the listener's import holds it in memory whole (transfer fix A): pieces stay at most 25 MB. The
  /// planner's target (about 12 minutes, around 6 MB at 64 kbps) is unchanged; only high-bitrate
  /// sources are cut shorter.
  static let maxPieceBytes: Int64 = 25_000_000
}

struct SharedChapter: Codable, Equatable {
  let title: String
  let start: TimeInterval
  let duration: TimeInterval
  var end: TimeInterval { start + duration }
}

struct SharedPiece: Codable, Equatable {
  let index: Int
  /// Where this piece starts on the book timeline, in seconds.
  let bookStart: TimeInterval
  let duration: TimeInterval
  let byteSize: Int64
  var bookEnd: TimeInterval { bookStart + duration }
}

struct SharedBookManifest: Codable, Equatable {
  let shareID: UUID
  let title: String
  let author: String
  let duration: TimeInterval
  let chapters: [SharedChapter]
  var pieces: [SharedPiece]
  /// Lets listeners recognise their own copy (addendum 2). Optional, so an older manifest still decodes.
  var fingerprint: BookFingerprint? = nil

  func chapter(at bookTime: TimeInterval) -> SharedChapter? {
    chapters.first { bookTime >= $0.start && bookTime < $0.end }
  }
}

enum RemoteAction: Codable, Equatable {
  case paused
  case resumed
  case skipped(seconds: Int)
  case movedToChapter(title: String)
  case speedChanged(rate: Float)
}

enum ListenTogetherMessage: Codable, Equatable {
  case manifest(SharedBookManifest)
  case pieceUploaded(index: Int, attachmentID: UUID)
  case action(RemoteAction)
  case sessionEnding
  /// Sent by a listener who can't join an owners-only share (no copy of the book), just before it
  /// leaves. The transport turns it into `TransportEvent.participantDeclined`. Carries nothing about
  /// what that person owns.
  case declinedNoCopy
  /// Listener: "send me the manifest and the piece map". Sent on join and every few seconds until the
  /// manifest is here (and while a received piece has no index); the sharer answers by sending both again.
  case requestState
  /// Sharer: "still here", every few seconds. Listeners that stop hearing the sharer wait for them.
  case heartbeat
  /// Listener: the group waits for this piece on this device; the sharer sends it next.
  case needPiece(index: Int)
  /// Sharer: the book's files could not be read at the start, so the share ends (instead of
  /// `.sessionEnding`, so listeners can say why).
  case sharerCouldNotPrepare

  /// The kind of message, for logs (never its contents).
  var kind: String {
    switch self {
    case .manifest: return "manifest"
    case .pieceUploaded: return "pieceUploaded"
    case .action: return "action"
    case .sessionEnding: return "sessionEnding"
    case .declinedNoCopy: return "declinedNoCopy"
    case .requestState: return "requestState"
    case .heartbeat: return "heartbeat"
    case .needPiece: return "needPiece"
    case .sharerCouldNotPrepare: return "sharerCouldNotPrepare"
    }
  }
}
