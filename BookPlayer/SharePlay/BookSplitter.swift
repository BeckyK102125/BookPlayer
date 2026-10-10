import AVFoundation
import BookPlayerKit
import Foundation

enum BookSplitterError: Error, Equatable {
  case noLocalFile
  case exportFailed(index: Int)
  case pieceTooLarge(index: Int)
}

struct BookSplitter {
  /// Every chapter's local file exists and none is video.
  static func isShareable(_ item: PlayableItem) -> Bool {
    !item.chapters.isEmpty && item.chapters.allSatisfy { chapter in
      !chapter.isVideo && FileManager.default.fileExists(atPath: chapter.fileURL.path)
    }
  }

  /// One entry per distinct audio file, in book order.
  func sourceFiles(for item: PlayableItem) throws -> [SourceFile] {
    var files: [SourceFile] = []
    for chapter in item.chapters.sorted(by: { $0.start < $1.start }) {
      let url = chapter.fileURL
      guard FileManager.default.fileExists(atPath: url.path) else { throw BookSplitterError.noLocalFile }
      // Single-file books: many chapters, one file.
      if files.last?.url == url { continue }
      let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
      // chapterOffset is where this chapter begins inside its file.
      let fileBookStart = chapter.start - chapter.chapterOffset
      let lastEnd = item.chapters.filter { $0.fileURL == url }.map(\.end).max() ?? chapter.end
      files.append(SourceFile(
        url: url, bookStart: fileBookStart, duration: max(lastEnd - fileBookStart, 0), byteSize: size))
    }
    return files
  }

  func export(_ piece: PlannedPiece, from files: [SourceFile], to folder: URL)
    async throws -> (url: URL, shared: SharedPiece)
  {
    guard files.indices.contains(piece.sourceIndex) else { throw BookSplitterError.noLocalFile }
    let source = files[piece.sourceIndex]
    let pathExtension = source.url.pathExtension.isEmpty ? "m4a" : source.url.pathExtension
    let output = folder.appendingPathComponent(
      String(format: "piece-%03d.%@", piece.index, piece.isWholeFile ? pathExtension : "m4a"))
    try? FileManager.default.removeItem(at: output)

    if piece.isWholeFile {
      do {
        try FileManager.default.copyItem(at: source.url, to: output)
      } catch {
        throw BookSplitterError.exportFailed(index: piece.index)
      }
    } else {
      let asset = AVURLAsset(url: source.url)
      let passthroughOK = await AVAssetExportSession.compatibility(
        ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: .m4a)
      let preset = passthroughOK ? AVAssetExportPresetPassthrough : AVAssetExportPresetAppleM4A
      guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
        throw BookSplitterError.exportFailed(index: piece.index)
      }
      session.timeRange = CMTimeRange(
        start: CMTime(seconds: piece.sourceStart, preferredTimescale: 600),
        duration: CMTime(seconds: piece.duration, preferredTimescale: 600))
      do {
        try await session.export(to: output, as: .m4a)
      } catch {
        throw BookSplitterError.exportFailed(index: piece.index)
      }
    }

    let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
    guard size <= 100_000_000 else {
      try? FileManager.default.removeItem(at: output)
      throw BookSplitterError.pieceTooLarge(index: piece.index)
    }
    return (output, SharedPiece(
      index: piece.index, bookStart: piece.bookStart, duration: piece.duration, byteSize: size))
  }
}
