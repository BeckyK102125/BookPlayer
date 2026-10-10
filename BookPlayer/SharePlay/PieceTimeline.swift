import Foundation

struct PieceTimeline {
  private(set) var pieces: [SharedPiece]
  private var arrived: [Int: URL] = [:]

  init(pieces: [SharedPiece]) {
    self.pieces = pieces.sorted { $0.bookStart < $1.bookStart }
  }

  var totalDuration: TimeInterval { pieces.last?.bookEnd ?? 0 }

  var arrivedFraction: Double {
    let total = pieces.reduce(Int64(0)) { $0 + $1.byteSize }
    guard total > 0 else { return 0 }
    let done = pieces.filter { arrived[$0.index] != nil }.reduce(Int64(0)) { $0 + $1.byteSize }
    return Double(done) / Double(total)
  }

  mutating func markArrived(index: Int, url: URL) { arrived[index] = url }

  func url(forPiece index: Int) -> URL? { arrived[index] }

  /// Piece boundaries come from float arithmetic, so a piece can end a hair before the next one
  /// starts. Times are matched to the last piece starting at or before them (within a tolerance), so
  /// such a seam belongs to the next piece instead of to no piece at all. Times past the end clamp to
  /// the end of the last piece. Nil only for negative or NaN times, or an empty timeline.
  func location(for bookTime: TimeInterval) -> (piece: SharedPiece, offset: TimeInterval)? {
    guard !bookTime.isNaN, bookTime >= 0, let first = pieces.first else { return nil }
    let piece = pieces.last(where: { $0.bookStart <= bookTime + Self.seamTolerance }) ?? first
    let offset = min(max(0, bookTime - piece.bookStart), piece.duration)
    return (piece, offset)
  }

  /// The piece after `index` in book order, if any.
  func piece(after index: Int) -> SharedPiece? {
    guard let position = pieces.firstIndex(where: { $0.index == index }), position + 1 < pieces.count else {
      return nil
    }
    return pieces[position + 1]
  }

  static let seamTolerance: TimeInterval = 1e-6

  func isReady(at bookTime: TimeInterval) -> Bool {
    guard let piece = location(for: bookTime)?.piece else { return false }
    return arrived[piece.index] != nil
  }
}
