import Foundation

/// How audio pieces travel in a session (transfer fix B). Decided by the sharer; listeners follow.
enum ListenTogetherTransportMode: String, Codable, Equatable {
  /// `GroupSessionJournal` attachments: uploaded once, kept in Apple's cloud for late joiners.
  case journal
  /// Raw chunks on a second `GroupSessionMessenger` (`MessengerPieceChannel`): the fallback when the
  /// journal refuses pieces.
  case chunks
}

/// Decides when a session gives up on the journal: after `failureLimit` journal `add` failures in a
/// row that are not interruptions, or at once on `notSupported`. Never goes back.
struct TransportModeSwitch: Equatable {
  static let failureLimit = 2

  private(set) var mode: ListenTogetherTransportMode = .journal
  private var consecutiveFailures = 0

  /// Records a failed journal `add`. True when this failure switches the session to chunks.
  /// `isInterruption` comes from `isInterruption(_:appWasActive:)`.
  mutating func journalAddFailed(isNotSupported: Bool, isInterruption: Bool) -> Bool {
    guard mode == .journal else { return false }
    if !isInterruption { consecutiveFailures += 1 }
    guard isNotSupported || consecutiveFailures >= Self.failureLimit else { return false }
    mode = .chunks
    return true
  }

  mutating func journalAddSucceeded() {
    consecutiveFailures = 0
  }

  /// A listener couldn't load journal pieces (`ChunkControl.journalUnusable`): the sharer switches.
  /// True when it changed.
  mutating func listenerReportedJournalUnusable() -> Bool {
    guard mode != .chunks else { return false }
    mode = .chunks
    return true
  }

  /// A listener adopts the mode the sharer announced. True when it changed.
  mutating func adopt(_ announced: ListenTogetherTransportMode) -> Bool {
    guard announced == .chunks, mode != .chunks else { return false }
    mode = .chunks
    return true
  }

  /// GroupActivities' journal errors are not public API: the case is recognised by its name.
  static func isNotSupported(_ error: Error) -> Bool {
    String(reflecting: error).contains("notSupported")
  }

  /// The journal itself refused (its own error domain, or `notSupported`): a local or validation
  /// failure, never a suspension, so it counts whatever the app's state (fix round 1, I2).
  static func isJournalRejection(_ error: Error) -> Bool {
    if isNotSupported(error) { return true }
    let domain = (error as NSError).domain
    return domain.contains("GroupActivities") || domain.contains("GroupSession")
  }

  /// A real interruption doesn't count towards the switch: a cancellation, or (for errors that are not
  /// the journal's own) the app not being active during the attempt.
  static func isInterruption(_ error: Error, appWasActive: Bool) -> Bool {
    if PieceRetryPolicy.isInterruption(error) { return true }
    return !isJournalRejection(error) && !appWasActive
  }
}

/// CRC-32 (IEEE 802.3, the zip/PNG one), the whole-file checksum carried by every chunk.
struct ListenTogetherCRC32 {
  private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
    var value = UInt32(index)
    for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    return value
  }

  private var state: UInt32 = 0xFFFF_FFFF

  var checksum: UInt32 { state ^ 0xFFFF_FFFF }

  mutating func update(_ data: Data) {
    var crc = state
    data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      for byte in buffer { crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
    state = crc
  }

  static func checksum(_ data: Data) -> UInt32 {
    var crc = ListenTogetherCRC32()
    crc.update(data)
    return crc.checksum
  }

  /// Reads the file `blockSize` bytes at a time, so a piece is never held in memory whole.
  static func checksum(ofFileAt url: URL, blockSize: Int = ChunkFrame.payloadSize) throws -> UInt32 {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var crc = ListenTogetherCRC32()
    while let block = try handle.read(upToCount: blockSize), !block.isEmpty { crc.update(block) }
    return crc.checksum
  }
}

/// One chunk of one piece, as sent on the chunk messenger: a 48-byte little-endian header, then at
/// most `payloadSize` bytes of the file.
///
/// | magic `LTCK` 4 | version 1 | flags 1 (bit 0: last) | reserved 2 | piece id 16 | index 4 | count 4 |
/// | total bytes 8 | whole-file CRC-32 4 | extension 4 (ASCII, zero-padded) | payload |
struct ChunkFrame: Equatable {
  static let magic = Data("LTCK".utf8)
  static let version: UInt8 = 1
  static let headerSize = 48
  /// 192 KB: well below the messenger's 256 KB limit, leaving room for its own framing.
  static let payloadSize = 196_608
  static let maxExtensionLength = 4

  let pieceID: UUID
  let index: Int
  let count: Int
  let totalBytes: Int64
  let checksum: UInt32
  let pathExtension: String
  let payload: Data

  var isLast: Bool { index == count - 1 }

  /// Overflow-safe for any size (fix round 1, C1).
  static func chunkCount(forBytes totalBytes: Int64) -> Int {
    guard totalBytes > 0 else { return 1 }
    let size = Int64(payloadSize)
    let (whole, rest) = totalBytes.quotientAndRemainder(dividingBy: size)
    return Int(whole) + (rest == 0 ? 0 : 1)
  }

  static func byteRange(ofChunk index: Int, totalBytes: Int64) -> Range<Int64> {
    let start = min(Int64(index) * Int64(payloadSize), totalBytes)
    return start..<min(start + Int64(payloadSize), totalBytes)
  }

  /// The extension as sent: lowercase ASCII letters and digits, at most four; otherwise empty (the
  /// listener then names the file `.m4a`).
  static func wireExtension(_ pathExtension: String) -> String {
    let lowered = pathExtension.lowercased()
    guard !lowered.isEmpty, lowered.count <= maxExtensionLength,
      lowered.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
    else { return "" }
    return lowered
  }

  func encoded() -> Data {
    var data = Data(capacity: Self.headerSize + payload.count)
    data.append(Self.magic)
    data.append(Self.version)
    data.append(isLast ? 1 : 0)
    data.append(contentsOf: [0, 0])
    withUnsafeBytes(of: pieceID.uuid) { data.append(contentsOf: $0) }
    Self.append(UInt32(index), to: &data)
    Self.append(UInt32(count), to: &data)
    Self.append(UInt64(totalBytes), to: &data)
    Self.append(checksum, to: &data)
    var ext = Array(Self.wireExtension(pathExtension).utf8)
    ext += Array(repeating: 0, count: Self.maxExtensionLength - ext.count)
    data.append(contentsOf: ext)
    data.append(payload)
    return data
  }

  /// Nil for anything that isn't a well-formed chunk (other traffic on the messenger is dropped).
  static func decode(_ data: Data) -> ChunkFrame? {
    guard data.count >= headerSize else { return nil }
    let header = [UInt8](data.prefix(headerSize))
    guard Data(header[0..<4]) == magic, header[4] == version else { return nil }
    let id = UUID(uuid: (
      header[8], header[9], header[10], header[11], header[12], header[13], header[14], header[15],
      header[16], header[17], header[18], header[19], header[20], header[21], header[22], header[23]))
    let index = Int(read(UInt32.self, header, at: 24))
    let count = Int(read(UInt32.self, header, at: 28))
    let total = read(UInt64.self, header, at: 32)
    // A hostile or broken frame can't make anyone allocate or compute past the SharePlay limit (C1).
    guard total <= UInt64(ListenTogetherLimits.maxChunkedPieceBytes) else { return nil }
    let totalBytes = Int64(total)
    let checksum = read(UInt32.self, header, at: 40)
    let extBytes = header[44..<48].prefix { $0 != 0 }
    guard let ext = String(bytes: extBytes, encoding: .ascii), wireExtension(ext) == ext else { return nil }
    guard count >= 1, index < count, count == chunkCount(forBytes: totalBytes) else { return nil }
    let payload = Data(data.dropFirst(headerSize))
    guard Int64(payload.count) == byteRange(ofChunk: index, totalBytes: totalBytes).count else { return nil }
    return ChunkFrame(
      pieceID: id, index: index, count: count, totalBytes: totalBytes, checksum: checksum,
      pathExtension: ext, payload: payload)
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }

  private static func read<T: FixedWidthInteger>(_ type: T.Type, _ bytes: [UInt8], at offset: Int) -> T {
    var value: T = 0
    for byteIndex in 0..<MemoryLayout<T>.size {
      value |= T(bytes[offset + byteIndex]) << (8 * byteIndex)
    }
    return value
  }
}

/// Small control messages on the chunk messenger: `LTCC`, a version byte, then JSON. Kept off the
/// main messenger so the `ListenTogetherTransport` protocol and the session service don't change.
enum ChunkControl: Codable, Equatable {
  /// Sharer: pieces now come as chunks (sent when switching, and to anyone who joins later).
  case transportMode(ListenTogetherTransportMode)
  /// Listener to sharer: send these chunks of the piece (none listed: all of it).
  case chunksMissing(pieceID: UUID, ranges: [ClosedRange<Int>])
  /// Listener to sharer: journal pieces can't be loaded on this phone (fix round 1, C2). The sharer
  /// switches to chunks, announces it, and reports its journal pieces gone, so `needPiece` re-sends them.
  case journalUnusable
  /// Sharer: this piece is no longer kept. The listener stops asking; its player's `needPiece`
  /// makes the sharer prepare the piece again.
  case pieceGone(pieceID: UUID)

  static let magic = Data("LTCC".utf8)
  static let version: UInt8 = 1

  func encoded() -> Data {
    var data = Self.magic
    data.append(Self.version)
    data.append((try? JSONEncoder().encode(self)) ?? Data())
    return data
  }

  static func decode(_ data: Data) -> ChunkControl? {
    guard data.count > magic.count + 1, data.prefix(magic.count) == magic,
      data[data.startIndex + magic.count] == version
    else { return nil }
    return try? JSONDecoder().decode(ChunkControl.self, from: Data(data.dropFirst(magic.count + 1)))
  }
}

/// Which chunks are missing, as ranges, and back.
enum ChunkGaps {
  static func missingRanges(_ received: [Bool]) -> [ClosedRange<Int>] {
    var ranges: [ClosedRange<Int>] = []
    var start: Int?
    for (index, has) in received.enumerated() {
      if !has, start == nil { start = index }
      if has, let first = start {
        ranges.append(first...(index - 1))
        start = nil
      }
    }
    if let first = start { ranges.append(first...(received.count - 1)) }
    return ranges
  }

  /// The chunk indices in `ranges`, sorted, without duplicates, within `0..<count`. No ranges: all.
  static func indices(in ranges: [ClosedRange<Int>], count: Int) -> [Int] {
    guard !ranges.isEmpty else { return Array(0..<count) }
    var wanted = Set<Int>()
    for range in ranges {
      let low = max(range.lowerBound, 0), high = min(range.upperBound, count - 1)
      guard low <= high else { continue }
      wanted.formUnion(low...high)
    }
    return wanted.sorted()
  }
}

/// The sharer's send window: 2 chunks in flight, 3 after ten clean sends. A failed send (rate limit,
/// flow control) halves it and backs off 100 ms, 250 ms, 500 ms, then 1 s.
struct ChunkSendWindow: Equatable {
  static let initialSize = 2
  static let maxSize = 3
  static let cleanSendsToGrow = 10
  static let backoffs: [Duration] = [.milliseconds(100), .milliseconds(250), .milliseconds(500), .seconds(1)]

  private(set) var size = ChunkSendWindow.initialSize
  private(set) var consecutiveFailures = 0
  private var cleanSends = 0

  mutating func sent() {
    consecutiveFailures = 0
    cleanSends += 1
    guard cleanSends >= Self.cleanSendsToGrow else { return }
    cleanSends = 0
    size = min(size + 1, Self.maxSize)
  }

  /// Returns how long to wait before sending again.
  mutating func failed() -> Duration {
    consecutiveFailures += 1
    cleanSends = 0
    size = max(1, size / 2)
    return Self.backoffs[min(consecutiveFailures, Self.backoffs.count) - 1]
  }
}

/// One public log line for an error (transfer fix, item 3): the type and case (Swift enums, such as
/// GroupActivities' journal errors), domain and code, and the underlying error's domain and code.
/// Descriptions and user info are left out: they can hold file paths, and file names are book titles.
enum ListenTogetherErrorDescription {
  static func describe(_ error: Error) -> String {
    let nsError = error as NSError
    var parts: [String] = []
    if let splitter = error as? BookSplitterError {
      parts.append(splitter.publicCase)
    } else if Mirror(reflecting: error).displayStyle == .enum {
      // The type and the case name only: associated values could hold a file name (a book title).
      parts.append("\(String(reflecting: type(of: error))).\(caseName(of: error))")
    } else {
      parts.append(String(reflecting: type(of: error)))
    }
    parts.append("domain=\(nsError.domain) code=\(nsError.code)")
    if let underlying = underlyingError(of: error) {
      parts.append("underlying=\(underlying.domain) \(underlying.code)")
    }
    return parts.joined(separator: " ")
  }

  /// An enum's case name, without its associated values.
  static func caseName(of value: Any) -> String {
    if let label = Mirror(reflecting: value).children.first?.label { return label }
    let text = String(describing: value)
    return String(text.prefix { $0 != "(" })
  }

  private static func underlyingError(of error: Error) -> NSError? {
    if case .exportFailed(_, _, let underlying?)? = error as? BookSplitterError { return underlying }
    return (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
  }

  /// Replaces anything that looks like a file path or file URL with `<path>`.
  static func redactingPaths(_ text: String) -> String {
    text.replacingOccurrences(
      of: #"(file://)?/[^\s"',;)\]}]+"#, with: "<path>", options: .regularExpression)
  }
}

extension BookSplitterError {
  /// The case and its non-personal values, for the public log line.
  var publicCase: String {
    switch self {
    case .noLocalFile: return "BookSplitterError.noLocalFile"
    case .exportFailed(let index, let preset, _):
      return "BookSplitterError.exportFailed(index: \(index), preset: \(preset))"
    case .pieceTooLarge(let index, let bytes):
      return "BookSplitterError.pieceTooLarge(index: \(index), bytes: \(bytes))"
    }
  }
}
