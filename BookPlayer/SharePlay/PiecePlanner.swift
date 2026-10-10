import Foundation

struct SourceFile: Equatable {
  let url: URL
  let bookStart: TimeInterval
  let duration: TimeInterval
  let byteSize: Int64
}

struct PlannedPiece: Equatable {
  let index: Int
  let sourceIndex: Int
  /// Offset inside the source file, in seconds.
  let sourceStart: TimeInterval
  let duration: TimeInterval
  let bookStart: TimeInterval
  let isWholeFile: Bool
  let estimatedBytes: Int64
}

enum PiecePlanner {
  static func plan(
    files: [SourceFile],
    chapterStarts: [TimeInterval],
    maxBytes: Int64 = ListenTogetherLimits.maxPieceBytes
  ) -> [PlannedPiece] {
    var result: [PlannedPiece] = []
    for (sourceIndex, file) in files.enumerated() {
      guard file.duration > 0 else { continue }
      let bytesPerSecond = Double(file.byteSize) / file.duration

      if file.byteSize <= maxBytes {
        result.append(PlannedPiece(
          index: result.count, sourceIndex: sourceIndex, sourceStart: 0, duration: file.duration,
          bookStart: file.bookStart, isWholeFile: true, estimatedBytes: file.byteSize))
        continue
      }

      // Candidate cut points: chapter starts inside this file, in file-relative seconds.
      let fileEnd = file.bookStart + file.duration
      let cuts = chapterStarts
        .filter { $0 > file.bookStart && $0 < fileEnd }
        .map { $0 - file.bookStart }
        .sorted() + [file.duration]

      var pieceStart: TimeInterval = 0
      var lastGoodCut: TimeInterval?
      var segments: [(TimeInterval, TimeInterval)] = []

      func bytes(_ start: TimeInterval, _ end: TimeInterval) -> Double { (end - start) * bytesPerSecond }

      for cut in cuts {
        if bytes(pieceStart, cut) <= Double(maxBytes) {
          lastGoodCut = cut
          continue
        }
        if let good = lastGoodCut {
          segments.append((pieceStart, good))
          pieceStart = good
          lastGoodCut = nil
          if bytes(pieceStart, cut) <= Double(maxBytes) {
            lastGoodCut = cut
            continue
          }
        }
        // A single chapter span is too big: split it evenly.
        let parts = Int(ceil(bytes(pieceStart, cut) / Double(maxBytes)))
        let step = (cut - pieceStart) / Double(parts)
        for part in 0..<parts {
          let start = pieceStart + Double(part) * step
          segments.append((start, part == parts - 1 ? cut : start + step))
        }
        pieceStart = cut
        lastGoodCut = nil
      }
      if let good = lastGoodCut, good > pieceStart {
        segments.append((pieceStart, good))
      }

      for (start, end) in segments {
        result.append(PlannedPiece(
          index: result.count, sourceIndex: sourceIndex, sourceStart: start, duration: end - start,
          bookStart: file.bookStart + start, isWholeFile: false,
          estimatedBytes: Int64(bytes(start, end).rounded(.up))))
      }
    }
    return result
  }
}

extension Array where Element == PlannedPiece {
  func uploadOrder(startingAt bookTime: TimeInterval) -> [PlannedPiece] {
    guard let first = firstIndex(where: { bookTime >= $0.bookStart && bookTime < $0.bookStart + $0.duration })
    else { return self }
    return Array(self[first...] + self[..<first])
  }
}
