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

  /// SHA-256 of the first 64 KB of the first file's AUDIO DATA, read directly (no decoding), so tags
  /// and cover art don't change it. Synchronous file I/O: call it off the main actor
  /// (`sampleHashOffMain`).
  nonisolated static func sampleHash(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let offset = audioDataOffset(in: handle) ?? 0
    guard (try? handle.seek(toOffset: offset)) != nil,
      let data = try? handle.read(upToCount: sampleLength), !data.isEmpty
    else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Where the audio data starts:
  /// - MP4 family (m4a, m4b, mp4; recognised by an `ftyp` atom first): the top-level atoms are walked
  ///   (32-bit sizes, the 64-bit `size == 1` form, `size == 0` = to the end) to the `mdat` payload.
  /// - MP3 with an ID3v2 tag ("ID3" first): the 10-byte header plus the synchsafe tag size, plus 10
  ///   more when the footer flag is set.
  /// - Anything else, or anything that doesn't parse (an atom running past the end, no `mdat`): nil,
  ///   and the caller hashes from the start of the file. Both phones do the same, so equal files still
  ///   match; only the tag-independence is lost for such files.
  nonisolated static func audioDataOffset(in handle: FileHandle) -> UInt64? {
    guard let fileSize = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil,
      let head = try? handle.read(upToCount: 10), head.count == 10
    else { return nil }
    let bytes = [UInt8](head)
    if bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {  // "ID3"
      guard bytes[6...9].allSatisfy({ $0 < 0x80 }) else { return nil }
      let size = bytes[6...9].reduce(UInt64(0)) { ($0 << 7) | UInt64($1) }
      let footer: UInt64 = (bytes[5] & 0x10) != 0 ? 10 : 0
      let offset = 10 + size + footer
      return offset < fileSize ? offset : nil
    }
    guard String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" else { return nil }
    var position: UInt64 = 0
    while position + 8 <= fileSize {
      guard (try? handle.seek(toOffset: position)) != nil,
        let header = try? handle.read(upToCount: 8), header.count == 8
      else { return nil }
      let h = [UInt8](header)
      var size = h[0..<4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
      let type = String(bytes: h[4..<8], encoding: .ascii)
      var headerLength: UInt64 = 8
      if size == 1 {
        guard let large = try? handle.read(upToCount: 8), large.count == 8 else { return nil }
        size = [UInt8](large).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        headerLength = 16
      } else if size == 0 {
        size = fileSize - position
      }
      guard size >= headerLength, position + size <= fileSize else { return nil }
      if type == "mdat" { return size > headerLength ? position + headerLength : nil }
      position += size
    }
    return nil
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
