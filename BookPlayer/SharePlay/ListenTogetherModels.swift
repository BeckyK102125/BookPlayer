import Foundation

enum ListenTogetherLimits {
  /// SharePlay journal attachments are capped at 100 MB; keep a margin.
  static let maxPieceBytes: Int64 = 90_000_000
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
}
