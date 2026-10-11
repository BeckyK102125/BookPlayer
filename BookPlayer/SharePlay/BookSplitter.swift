import AVFoundation
import BookPlayerKit
import Foundation

enum BookSplitterError: Error, Equatable {
  case noLocalFile
  /// `preset` is how the piece was made ("copy", "passthrough" or "AppleM4A"); `underlying` is the
  /// error from the file system or AVFoundation, kept for the log (addendum 3, decision 11).
  case exportFailed(index: Int, preset: String, underlying: NSError?)
  case pieceTooLarge(index: Int, bytes: Int64)

  /// One line for the log: domain, code and description of the underlying error, and the preset.
  var diagnostics: String {
    switch self {
    case .noLocalFile:
      return "no local file"
    case .exportFailed(_, let preset, let underlying):
      guard let underlying else { return "export failed, preset=\(preset), no underlying error" }
      return "export failed, preset=\(preset), \(underlying.domain) \(underlying.code): "
        + underlying.localizedDescription
    case .pieceTooLarge(_, let bytes):
      return "piece too large: \(bytes) bytes"
    }
  }
}

/// A piece ready to upload, and how it was made (for the log).
struct ExportedPiece {
  let url: URL
  let shared: SharedPiece
  /// "copy" (a whole file), "passthrough" (cut without re-encoding) or "AppleM4A" (re-encoded).
  let preset: String
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

  func export(_ piece: PlannedPiece, from files: [SourceFile], to folder: URL) async throws -> ExportedPiece {
    guard files.indices.contains(piece.sourceIndex) else { throw BookSplitterError.noLocalFile }
    let source = files[piece.sourceIndex]
    let pathExtension = source.url.pathExtension.isEmpty ? "m4a" : source.url.pathExtension
    let output = folder.appendingPathComponent(
      String(format: "piece-%03d.%@", piece.index, piece.isWholeFile ? pathExtension : "m4a"))
    try? FileManager.default.removeItem(at: output)

    let preset: String
    if piece.isWholeFile {
      preset = "copy"
      do {
        try FileManager.default.copyItem(at: source.url, to: output)
      } catch {
        throw BookSplitterError.exportFailed(index: piece.index, preset: preset, underlying: error as NSError)
      }
    } else {
      let asset = AVURLAsset(url: source.url)
      let passthroughOK = await AVAssetExportSession.compatibility(
        ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: .m4a)
      preset = passthroughOK ? "passthrough" : "AppleM4A"
      let presetName = passthroughOK ? AVAssetExportPresetPassthrough : AVAssetExportPresetAppleM4A
      guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
        throw BookSplitterError.exportFailed(
          index: piece.index, preset: preset,
          underlying: NSError(
            domain: "ListenTogether.BookSplitter", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No export session for this source and preset"]))
      }
      session.timeRange = CMTimeRange(
        start: CMTime(seconds: piece.sourceStart, preferredTimescale: 600),
        duration: CMTime(seconds: piece.duration, preferredTimescale: 600))
      do {
        try await session.export(to: output, as: .m4a)
      } catch {
        try? FileManager.default.removeItem(at: output)
        throw BookSplitterError.exportFailed(index: piece.index, preset: preset, underlying: error as NSError)
      }
    }

    let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
    guard size <= ListenTogetherLimits.maxExportedPieceBytes else {
      try? FileManager.default.removeItem(at: output)
      throw BookSplitterError.pieceTooLarge(index: piece.index, bytes: size)
    }
    return ExportedPiece(
      url: output,
      shared: SharedPiece(index: piece.index, bookStart: piece.bookStart, duration: piece.duration, byteSize: size),
      preset: preset)
  }
}
