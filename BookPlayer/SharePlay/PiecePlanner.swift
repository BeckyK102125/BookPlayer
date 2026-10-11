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

/// Cuts a book into the pieces that are sent (addendum 3, decision 1): about 12 minutes each, so the
/// first one is exported and sent in seconds and progress moves. Pieces are invisible to listeners;
/// chapters still come from the manifest.
enum PiecePlanner {
  /// About this much audio per piece.
  static let targetDuration: TimeInterval = 12 * 60
  /// Short chapters are grouped while the piece stays this long or less; a longer chapter (or a book
  /// without chapters) is split into equal parts of about `targetDuration`.
  static let maxDuration: TimeInterval = 15 * 60

  /// Every file is cut on its own (file boundaries are always cuts). A file of at most `maxDuration`
  /// and `maxBytes` is sent whole (copied, never re-encoded). Otherwise pieces are cut at chapter
  /// starts where possible: consecutive chapters are grouped until the piece reaches `targetDuration`
  /// (never past `maxDuration`); a chapter longer than `maxDuration` is split evenly. The byte limit
  /// is a hard cap that can make pieces shorter (high-bitrate sources).
  static func plan(
    files: [SourceFile],
    chapterStarts: [TimeInterval],
    maxBytes: Int64 = ListenTogetherLimits.maxPieceBytes,
    targetDuration: TimeInterval = PiecePlanner.targetDuration,
    maxDuration: TimeInterval = PiecePlanner.maxDuration
  ) -> [PlannedPiece] {
    var result: [PlannedPiece] = []
    for (sourceIndex, file) in files.enumerated() {
      guard file.duration > 0 else { continue }
      let bytesPerSecond = Double(file.byteSize) / file.duration
      func bytes(_ start: TimeInterval, _ end: TimeInterval) -> Double { (end - start) * bytesPerSecond }

      if file.duration <= maxDuration, file.byteSize <= maxBytes {
        result.append(PlannedPiece(
          index: result.count, sourceIndex: sourceIndex, sourceStart: 0, duration: file.duration,
          bookStart: file.bookStart, isWholeFile: true, estimatedBytes: file.byteSize))
        continue
      }

      // The byte cap, as a duration: no piece of this file may be longer.
      let byteLimit = bytesPerSecond > 0 ? Double(maxBytes) / bytesPerSecond : .infinity
      let upper = min(maxDuration, byteLimit)
      let target = min(targetDuration, upper)

      // Chapter spans inside this file, in file-relative seconds.
      let fileEnd = file.bookStart + file.duration
      let interior = Set(chapterStarts.filter { $0 > file.bookStart && $0 < fileEnd }.map { $0 - file.bookStart })
      let boundaries = [0] + interior.sorted() + [file.duration]

      var segments: [(TimeInterval, TimeInterval)] = []
      var group: (start: TimeInterval, end: TimeInterval)?
      func flush() {
        if let current = group { segments.append((current.start, current.end)) }
        group = nil
      }

      for (start, end) in zip(boundaries, boundaries.dropFirst()) {
        if end - start > upper {
          // One chapter too long for a piece: equal parts of about the target (and under the cap).
          flush()
          let parts = max(1, Int(ceil((end - start) / target)), Int(ceil(bytes(start, end) / Double(maxBytes))))
          let step = (end - start) / Double(parts)
          for part in 0..<parts {
            let partStart = start + Double(part) * step
            segments.append((partStart, part == parts - 1 ? end : partStart + step))
          }
          continue
        }
        if let current = group, current.end - current.start < target, end - current.start <= upper {
          group = (current.start, end)
          continue
        }
        flush()
        group = (start, end)
      }
      flush()

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
