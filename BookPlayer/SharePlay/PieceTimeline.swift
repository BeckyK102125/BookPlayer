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

  func location(for bookTime: TimeInterval) -> (piece: SharedPiece, offset: TimeInterval)? {
    guard bookTime >= 0, let last = pieces.last else { return nil }
    if let piece = pieces.first(where: { bookTime >= $0.bookStart && bookTime < $0.bookEnd }) {
      return (piece, bookTime - piece.bookStart)
    }
    return bookTime >= last.bookEnd ? (last, last.duration) : nil
  }

  func isReady(at bookTime: TimeInterval) -> Bool {
    guard let piece = location(for: bookTime)?.piece else { return false }
    return arrived[piece.index] != nil
  }
}
