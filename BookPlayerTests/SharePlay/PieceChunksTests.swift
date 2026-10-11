@testable import BookPlayer
import XCTest

/// Transfer fix B: the pure parts of the chunked-messenger fallback (frame format, control messages,
/// checksum, gaps, send window, mode switch) and the public error lines (item 3).
final class PieceChunksTests: XCTestCase {
  // MARK: CRC32

  func testCRC32MatchesTheStandardCheckValue() {
    XCTAssertEqual(ListenTogetherCRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    XCTAssertEqual(ListenTogetherCRC32.checksum(Data()), 0)
  }

  func testCRC32IsTheSameInPieces() {
    let data = Data((0..<10_000).map { UInt8($0 % 251) })
    var crc = ListenTogetherCRC32()
    crc.update(data.prefix(3333))
    crc.update(data.dropFirst(3333))
    XCTAssertEqual(crc.checksum, ListenTogetherCRC32.checksum(data))
  }

  func testCRC32OfAFileReadsItInBlocks() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("crc-\(UUID()).bin")
    defer { try? FileManager.default.removeItem(at: url) }
    let data = Data((0..<500_000).map { UInt8(($0 * 7) % 256) })
    try data.write(to: url)
    XCTAssertEqual(
      try ListenTogetherCRC32.checksum(ofFileAt: url, blockSize: 1000), ListenTogetherCRC32.checksum(data))
  }

  // MARK: Chunk frame

  func testChunkCountAndRanges() {
    let size = Int64(ChunkFrame.payloadSize)
    XCTAssertEqual(ChunkFrame.payloadSize, 196_608)
    XCTAssertEqual(ChunkFrame.chunkCount(forBytes: 0), 1)
    XCTAssertEqual(ChunkFrame.chunkCount(forBytes: 1), 1)
    XCTAssertEqual(ChunkFrame.chunkCount(forBytes: size), 1)
    XCTAssertEqual(ChunkFrame.chunkCount(forBytes: size + 1), 2)
    XCTAssertEqual(ChunkFrame.chunkCount(forBytes: 5_800_000), 30)
    XCTAssertEqual(ChunkFrame.byteRange(ofChunk: 1, totalBytes: size + 10), size..<(size + 10))
    XCTAssertEqual(ChunkFrame.byteRange(ofChunk: 0, totalBytes: size + 10), 0..<size)
  }

  func testFrameRoundTripsWithA48ByteHeader() throws {
    let id = UUID()
    let payload = Data((0..<1000).map { UInt8($0 % 256) })
    let frame = ChunkFrame(
      pieceID: id, index: 1, count: 2, totalBytes: Int64(ChunkFrame.payloadSize + 1000),
      checksum: 0xDEAD_BEEF, pathExtension: "mp3", payload: payload)
    let data = frame.encoded()
    XCTAssertEqual(data.count, 48 + 1000)
    XCTAssertEqual(Array(data.prefix(4)), Array("LTCK".utf8))
    XCTAssertEqual(data[4], 1, "version")
    XCTAssertEqual(data[5], 1, "flags: last chunk")
    let decoded = try XCTUnwrap(ChunkFrame.decode(data))
    XCTAssertEqual(decoded, frame)
    XCTAssertTrue(decoded.isLast)
    // A slice that doesn't start at 0 decodes the same.
    let padded = Data([9, 9, 9]) + data
    XCTAssertEqual(ChunkFrame.decode(padded.dropFirst(3)), frame)
  }

  func testFrameRejectsAnythingElse() {
    let good = ChunkFrame(
      pieceID: UUID(), index: 0, count: 1, totalBytes: 3, checksum: 1, pathExtension: "m4a",
      payload: Data([1, 2, 3])).encoded()
    XCTAssertNotNil(ChunkFrame.decode(good))
    // Wrong magic, wrong version, short header, wrong payload length, index past count.
    var magic = good; magic[0] = 0x41
    XCTAssertNil(ChunkFrame.decode(magic))
    var version = good; version[4] = 2
    XCTAssertNil(ChunkFrame.decode(version))
    XCTAssertNil(ChunkFrame.decode(good.prefix(40)))
    XCTAssertNil(ChunkFrame.decode(good.dropLast()))
    var index = good; index[24] = 5
    XCTAssertNil(ChunkFrame.decode(index))
    // A control message or a JSON message is never read as a chunk.
    XCTAssertNil(ChunkFrame.decode(ChunkControl.transportMode(.chunks).encoded()))
    XCTAssertNil(ChunkFrame.decode(Data(#"{"heartbeat":{}}"#.utf8)))
  }

  // MARK: Hostile frames (fix round 1, C1)

  /// A frame header with any values, for hostile-frame tests.
  private func rawFrame(
    index: UInt32 = 0, count: UInt32 = 1, total: UInt64, ext: [UInt8] = Array("m4a".utf8) + [0], payload: Int = 0
  ) -> Data {
    var data = Data("LTCK".utf8)
    data.append(contentsOf: [1, 0, 0, 0])
    data.append(contentsOf: [UInt8](repeating: 7, count: 16))
    withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: count.littleEndian) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: total.littleEndian) { data.append(contentsOf: $0) }
    data.append(contentsOf: [0, 0, 0, 0])
    data.append(contentsOf: ext)
    data.append(Data(count: payload))
    return data
  }

  func testChunkCountNeverOverflows() {
    XCTAssertEqual(ChunkFrame.chunkCount(forBytes: Int64.max), Int(Int64.max / Int64(ChunkFrame.payloadSize)) + 1)
  }

  func testHostileFramesAreRejectedWithoutCrashing() {
    // Total of Int64.max (used to trap in chunkCount), and UInt64.max.
    XCTAssertNil(ChunkFrame.decode(rawFrame(total: UInt64(Int64.max))))
    XCTAssertNil(ChunkFrame.decode(rawFrame(total: UInt64.max)))
    // Above the 100 MB limit, even with a consistent count.
    let over = UInt64(ListenTogetherLimits.maxChunkedPieceBytes) + 1
    XCTAssertNil(ChunkFrame.decode(rawFrame(
      count: UInt32(ChunkFrame.chunkCount(forBytes: Int64(over))), total: over)))
    // count = UInt32.max with the total that matches it (would allocate a 4-billion-entry bitset).
    let huge = UInt64(UInt32.max) * UInt64(ChunkFrame.payloadSize)
    XCTAssertNil(ChunkFrame.decode(rawFrame(index: 0, count: UInt32.max, total: huge, payload: ChunkFrame.payloadSize)))
    // count that doesn't match the total; index (offset) past the end; payload of the wrong length.
    XCTAssertNil(ChunkFrame.decode(rawFrame(count: 3, total: 10, payload: 10)))
    XCTAssertNil(ChunkFrame.decode(rawFrame(index: 2, count: 2, total: UInt64(ChunkFrame.payloadSize) + 1, payload: 1)))
    XCTAssertNil(ChunkFrame.decode(rawFrame(total: 10, payload: 9)))
    // Non-ASCII extension; truncated header.
    XCTAssertNil(ChunkFrame.decode(rawFrame(total: 1, ext: [0xC3, 0xA9, 0, 0], payload: 1)))
    XCTAssertNil(ChunkFrame.decode(rawFrame(total: 1, payload: 1).prefix(47)))
    // The largest allowed piece still decodes.
    let max = UInt64(ListenTogetherLimits.maxChunkedPieceBytes)
    let count = UInt32(ChunkFrame.chunkCount(forBytes: Int64(max)))
    XCTAssertNotNil(ChunkFrame.decode(rawFrame(
      index: count - 1, count: count, total: max,
      payload: Int(ChunkFrame.byteRange(ofChunk: Int(count) - 1, totalBytes: Int64(max)).count))))
  }

  func testWireExtensionKeepsShortAudioExtensionsOnly() {
    XCTAssertEqual(ChunkFrame.wireExtension("m4b"), "m4b")
    XCTAssertEqual(ChunkFrame.wireExtension("MP3"), "mp3")
    XCTAssertEqual(ChunkFrame.wireExtension("flac"), "flac")
    XCTAssertEqual(ChunkFrame.wireExtension("toolong"), "")
    XCTAssertEqual(ChunkFrame.wireExtension("m/4"), "")
    XCTAssertEqual(ChunkFrame.wireExtension(""), "")
  }

  // MARK: Control messages

  func testControlMessagesRoundTrip() {
    let id = UUID()
    for control in [
      ChunkControl.transportMode(.chunks), .chunksMissing(pieceID: id, ranges: [0...2, 7...7]),
      .chunksMissing(pieceID: id, ranges: []), .pieceGone(pieceID: id), .journalUnusable,
    ] {
      let data = control.encoded()
      XCTAssertEqual(Array(data.prefix(4)), Array("LTCC".utf8))
      XCTAssertEqual(ChunkControl.decode(data), control)
    }
    XCTAssertNil(ChunkControl.decode(Data("LTCX".utf8) + Data([1])))
    XCTAssertNil(ChunkControl.decode(ChunkFrame(
      pieceID: id, index: 0, count: 1, totalBytes: 0, checksum: 0, pathExtension: "", payload: Data()).encoded()))
  }

  // MARK: Gaps

  func testMissingRanges() {
    XCTAssertEqual(ChunkGaps.missingRanges([true, true]), [])
    XCTAssertEqual(ChunkGaps.missingRanges([false, false, false]), [0...2])
    XCTAssertEqual(ChunkGaps.missingRanges([true, false, false, true, false]), [1...2, 4...4])
    XCTAssertEqual(ChunkGaps.missingRanges([false, true]), [0...0])
  }

  func testIndicesForRangesClampAndEmptyMeansAll() {
    XCTAssertEqual(ChunkGaps.indices(in: [], count: 3), [0, 1, 2])
    XCTAssertEqual(ChunkGaps.indices(in: [1...2, 5...9], count: 7), [1, 2, 5, 6])
    XCTAssertEqual(ChunkGaps.indices(in: [2...3, 1...2], count: 5), [1, 2, 3])
    XCTAssertEqual(ChunkGaps.indices(in: [8...9], count: 5), [])
  }

  // MARK: Send window

  func testWindowStartsAtTwoGrowsToThreeAfterTenCleanSends() {
    var window = ChunkSendWindow()
    XCTAssertEqual(window.size, 2)
    for _ in 0..<9 { window.sent() }
    XCTAssertEqual(window.size, 2)
    window.sent()
    XCTAssertEqual(window.size, 3)
    for _ in 0..<20 { window.sent() }
    XCTAssertEqual(window.size, 3, "never more than three in flight")
  }

  func testWindowHalvesAndBacksOffOnFailures() {
    var window = ChunkSendWindow()
    for _ in 0..<10 { window.sent() }
    XCTAssertEqual(window.size, 3)
    XCTAssertEqual(window.failed(), .milliseconds(100))
    XCTAssertEqual(window.size, 1)
    XCTAssertEqual(window.failed(), .milliseconds(250))
    XCTAssertEqual(window.failed(), .milliseconds(500))
    XCTAssertEqual(window.failed(), .seconds(1))
    XCTAssertEqual(window.failed(), .seconds(1))
    XCTAssertEqual(window.consecutiveFailures, 5)
    window.sent()
    XCTAssertEqual(window.consecutiveFailures, 0)
    XCTAssertEqual(window.size, 1, "opens again only after ten clean sends")
    for _ in 0..<9 { window.sent() }
    XCTAssertEqual(window.size, 2)
  }

  // MARK: Mode switch

  func testTwoRealJournalFailuresSwitchToChunks() {
    var modes = TransportModeSwitch()
    XCTAssertEqual(modes.mode, .journal)
    XCTAssertFalse(modes.journalAddFailed(isNotSupported: false, isInterruption: false))
    XCTAssertEqual(modes.mode, .journal)
    XCTAssertTrue(modes.journalAddFailed(isNotSupported: false, isInterruption: false))
    XCTAssertEqual(modes.mode, .chunks)
    XCTAssertFalse(modes.journalAddFailed(isNotSupported: true, isInterruption: false), "already switched")
  }

  func testInterruptionsAndSuccessesDontCountTowardsTheSwitch() {
    var modes = TransportModeSwitch()
    XCTAssertFalse(modes.journalAddFailed(isNotSupported: false, isInterruption: false))
    XCTAssertFalse(modes.journalAddFailed(isNotSupported: false, isInterruption: true))
    modes.journalAddSucceeded()
    XCTAssertFalse(modes.journalAddFailed(isNotSupported: false, isInterruption: false))
    XCTAssertEqual(modes.mode, .journal)
  }

  func testNotSupportedSwitchesAtOnceEvenDuringAnInterruption() {
    var modes = TransportModeSwitch()
    XCTAssertTrue(modes.journalAddFailed(isNotSupported: true, isInterruption: true))
    XCTAssertEqual(modes.mode, .chunks)
  }

  func testAnnouncedModeIsAdopted() {
    var modes = TransportModeSwitch()
    XCTAssertTrue(modes.adopt(.chunks))
    XCTAssertFalse(modes.adopt(.chunks))
    XCTAssertFalse(modes.adopt(.journal), "a session never goes back to the journal")
    XCTAssertEqual(modes.mode, .chunks)
  }

  private enum FakeGroupSessionErrors: Error {
    case notSupported
    case uploadFailure
  }

  func testJournalRejectionsAreRecognisedByCaseOrDomain() {
    XCTAssertTrue(TransportModeSwitch.isJournalRejection(FakeGroupSessionErrors.notSupported))
    XCTAssertTrue(TransportModeSwitch.isJournalRejection(
      NSError(domain: "GroupActivities.GroupSessionJournal.Errors", code: 3)))
    XCTAssertTrue(TransportModeSwitch.isJournalRejection(NSError(domain: "com.apple.GroupSession", code: 1)))
    XCTAssertFalse(TransportModeSwitch.isJournalRejection(URLError(.timedOut)))
  }

  /// I2: the journal's own errors count while the app isn't active; other errors don't; cancellations never.
  func testInterruptionRule() {
    let journal = NSError(domain: "GroupActivities.GroupSessionJournal.Errors", code: 3)
    XCTAssertFalse(TransportModeSwitch.isInterruption(journal, appWasActive: false))
    XCTAssertFalse(TransportModeSwitch.isInterruption(URLError(.timedOut), appWasActive: true))
    XCTAssertTrue(TransportModeSwitch.isInterruption(URLError(.timedOut), appWasActive: false))
    XCTAssertTrue(TransportModeSwitch.isInterruption(CancellationError(), appWasActive: true))
  }

  func testAListenerReportSwitchesTheSharerOnce() {
    var modes = TransportModeSwitch()
    XCTAssertTrue(modes.listenerReportedJournalUnusable())
    XCTAssertFalse(modes.listenerReportedJournalUnusable())
    XCTAssertEqual(modes.mode, .chunks)
  }

  func testNotSupportedIsRecognisedByItsCaseName() {
    XCTAssertTrue(TransportModeSwitch.isNotSupported(FakeGroupSessionErrors.notSupported))
    XCTAssertFalse(TransportModeSwitch.isNotSupported(FakeGroupSessionErrors.uploadFailure))
    XCTAssertFalse(TransportModeSwitch.isNotSupported(URLError(.timedOut)))
  }

  // MARK: Public error lines (item 3)

  func testSwiftEnumErrorsNameTheirCase() {
    let line = ListenTogetherErrorDescription.describe(FakeGroupSessionErrors.notSupported)
    XCTAssertTrue(line.contains("notSupported"), line)
    XCTAssertTrue(line.contains("domain="), line)
    XCTAssertTrue(line.contains("code=0"), line)
  }

  private enum TitledError: Error {
    case couldNotOpen(name: String)
  }

  /// Minor 8: an enum's associated values (a file name is a book title) never reach the log.
  func testEnumErrorsLogTheirCaseButNotTheirValues() {
    let line = ListenTogetherErrorDescription.describe(TitledError.couldNotOpen(name: "Moby Dick.m4b"))
    XCTAssertTrue(line.contains("couldNotOpen"), line)
    XCTAssertFalse(line.contains("Moby"), line)
  }

  func testNSErrorsGiveDomainCodeAndUnderlyingButNoPathsOrNames() {
    let underlying = NSError(domain: NSOSStatusErrorDomain, code: -12_780, userInfo: [
      NSFilePathErrorKey: "/var/mobile/Moby Dick.m4b",
    ])
    let error = NSError(domain: "AVFoundationErrorDomain", code: -11_800, userInfo: [
      NSLocalizedDescriptionKey: "“Moby Dick.m4b” could not be opened",
      NSURLErrorKey: URL(fileURLWithPath: "/var/mobile/Moby Dick.m4b"),
      NSUnderlyingErrorKey: underlying,
    ])
    let line = ListenTogetherErrorDescription.describe(error)
    XCTAssertTrue(line.contains("AVFoundationErrorDomain"), line)
    XCTAssertTrue(line.contains("-11800"), line)
    XCTAssertTrue(line.contains("NSOSStatusErrorDomain -12780"), line)
    XCTAssertFalse(line.contains("Moby"), line)
    XCTAssertFalse(line.contains("/var"), line)
  }

  func testSplitterErrorsKeepTheirCaseAndPresetWithoutTheUnderlyingDescription() {
    let underlying = NSError(domain: "AVFoundationErrorDomain", code: -11_838, userInfo: [
      NSLocalizedDescriptionKey: "Operation Stopped for /private/var/Moby Dick.m4b",
    ])
    let line = ListenTogetherErrorDescription.describe(
      BookSplitterError.exportFailed(index: 3, preset: "passthrough", underlying: underlying))
    XCTAssertTrue(line.contains("exportFailed"), line)
    XCTAssertTrue(line.contains("passthrough"), line)
    XCTAssertTrue(line.contains("AVFoundationErrorDomain -11838"), line)
    XCTAssertFalse(line.contains("Moby"), line)
  }

  func testCocoaErrorsAreDomainAndCodeOnly() {
    let error = CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "/tmp/ListenTogether/Moby Dick.m4a"])
    let line = ListenTogetherErrorDescription.describe(error)
    XCTAssertTrue(line.contains("NSCocoaErrorDomain"), line)
    XCTAssertTrue(line.contains("code=4"), line)
    XCTAssertFalse(line.contains("Moby"), line)
  }

  func testPathsAreRedacted() {
    XCTAssertEqual(
      ListenTogetherErrorDescription.redactingPaths("failed at /var/mobile/a.m4a and file:///tmp/x.mp3 ok"),
      "failed at <path> and <path> ok")
  }
}
