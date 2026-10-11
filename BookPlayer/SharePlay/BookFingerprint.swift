import CryptoKit
import Foundation

/// Describes a shared book well enough for a listener to recognise the same recording in their own
/// library (addendum 2, "Both have the book"). It travels in the invitation (the activity), so the
/// match is known before the invitation is shown, and in the manifest.
struct BookFingerprint: Codable, Equatable, Sendable {
  struct File: Codable, Equatable, Sendable {
    /// Where this file starts on the sharer's book timeline, in seconds.
    let bookStart: TimeInterval
    let duration: TimeInterval
    let byteSize: Int64
  }

  /// Normalised (see `normalize`).
  let title: String
  /// Normalised (see `normalize`).
  let author: String
  let duration: TimeInterval
  let files: [File]
  /// SHA-256 (hex) of the first 64 KB of the first file's bytes. Nil when the file couldn't be read.
  let sampleHash: String?

  /// How many bytes of the first file are hashed.
  static let sampleLength = 64 * 1024

  init(title: String, author: String, duration: TimeInterval, files: [File], sampleHash: String?) {
    self.title = Self.normalize(title)
    self.author = Self.normalize(author)
    self.duration = duration
    self.files = files
    self.sampleHash = sampleHash
  }

  init(title: String, author: String, duration: TimeInterval, sourceFiles: [SourceFile], sampleHash: String?) {
    self.init(
      title: title, author: author, duration: duration,
      files: sourceFiles.map { File(bookStart: $0.bookStart, duration: $0.duration, byteSize: $0.byteSize) },
      sampleHash: sampleHash)
  }

  /// Case-folded (and diacritic-folded), with whitespace and punctuation trimmed from both ends and
  /// runs of inner whitespace collapsed to one space.
  static func normalize(_ text: String) -> String {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    let trimmed = folded.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    return trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  /// Reads the first 64 KB of `url` directly (no decoding) and hashes them. Synchronous file I/O:
  /// call it off the main actor (`sampleHashOffMain`).
  nonisolated static func sampleHash(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: sampleLength), !data.isEmpty else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// `sampleHash(of:)` on a background thread, so the main actor never waits on the disk.
  nonisolated static func sampleHashOffMain(of url: URL) async -> String? {
    await Task.detached(priority: .userInitiated) { sampleHash(of: url) }.value
  }
}

/// The matching rules from addendum 2. Pure, so they are unit-tested without a library.
enum BookFingerprintMatcher {
  static let durationTolerance: TimeInterval = 2
  static let byteSizeTolerance = 0.01

  /// Total duration within ±2 s, the same number of files, and every file's duration within ±2 s.
  /// Cheap: checked before a candidate's first file is hashed.
  static func layoutMatches(shared: BookFingerprint, candidate: BookFingerprint) -> Bool {
    guard abs(shared.duration - candidate.duration) <= durationTolerance,
      shared.files.count == candidate.files.count, !shared.files.isEmpty
    else { return false }
    return zip(shared.files, candidate.files).allSatisfy { abs($0.duration - $1.duration) <= durationTolerance }
  }

  /// The layout matches, and either the sample hash matches, or the title and author match and every
  /// file's byte size is within ±1 %.
  static func matches(shared: BookFingerprint, candidate: BookFingerprint) -> Bool {
    guard layoutMatches(shared: shared, candidate: candidate) else { return false }
    if let hash = shared.sampleHash, hash == candidate.sampleHash { return true }
    guard shared.title == candidate.title, shared.author == candidate.author else { return false }
    return zip(shared.files, candidate.files).allSatisfy { sizesMatch($0.byteSize, $1.byteSize) }
  }

  static func sizesMatch(_ shared: Int64, _ candidate: Int64) -> Bool {
    if shared == candidate { return true }
    let reference = Double(max(shared, candidate))
    guard reference > 0 else { return false }
    return abs(Double(shared - candidate)) <= reference * byteSizeTolerance
  }

  /// Among matching candidates, the most recently played one (never-played ones last). Ties in the
  /// play date keep the earlier candidate.
  static func bestMatch<Value>(
    shared: BookFingerprint, candidates: [(fingerprint: BookFingerprint, lastPlayed: Date?, value: Value)]
  ) -> Value? {
    var best: (lastPlayed: Date?, value: Value)?
    for candidate in candidates where matches(shared: shared, candidate: candidate.fingerprint) {
      guard let current = best else {
        best = (candidate.lastPlayed, candidate.value)
        continue
      }
      if isMoreRecent(candidate.lastPlayed, than: current.lastPlayed) {
        best = (candidate.lastPlayed, candidate.value)
      }
    }
    return best?.value
  }

  private static func isMoreRecent(_ date: Date?, than other: Date?) -> Bool {
    switch (date, other) {
    case let (date?, other?): return date > other
    case (.some, nil): return true
    default: return false
    }
  }
}
