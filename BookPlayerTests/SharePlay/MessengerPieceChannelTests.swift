@testable import BookPlayer
import XCTest

/// Transfer fix B: pieces as chunks on a second messenger. Several channels are wired together by a
/// fake network (no SharePlay): what one sends reaches the others, or only the recipient.
/// Delivers what a channel sends to the other channels, a turn later, through optional filters.
@MainActor
final class ChunkTestNetwork {
  var channels: [UUID: MessengerPieceChannel] = [:]
  /// Every frame sent: (from, to, data). `to` nil means everyone.
  private(set) var log: [(from: UUID, to: UUID?, data: Data)] = []
  /// Return nil to drop the frame, or other data to change it in transit.
  var filter: (@MainActor (UUID, UUID?, Data) -> Data?)?
  /// Each send takes this long (a real network is slower than reading a chunk from disk).
  var sendDelay: Duration?
  /// Thrown by the next sends, one each.
  var sendErrors: [Error] = []
  /// Sends in flight right now, and the most there ever were.
  private(set) var inFlight = 0
  private(set) var peakInFlight = 0

  func sender(for id: UUID) -> MessengerPieceChannel.Send {
    { [weak self] data, recipient in
      guard let self else { return }
      self.inFlight += 1
      self.peakInFlight = max(self.peakInFlight, self.inFlight)
      defer { self.inFlight -= 1 }
      await Task.yield()
      if let delay = self.sendDelay { try? await Task.sleep(for: delay) }
      if !self.sendErrors.isEmpty { throw self.sendErrors.removeFirst() }
      self.log.append((id, recipient, data))
      guard let delivered = self.filter.map({ $0(id, recipient, data) }) ?? data else { return }
      for (other, channel) in self.channels where other != id && (recipient == nil || recipient == other) {
        Task { @MainActor in channel.receive(delivered, from: id) }
      }
    }
  }

  func chunks(to id: UUID) -> [ChunkFrame] {
    log.filter { $0.to == nil || $0.to == id }.compactMap { ChunkFrame.decode($0.data) }
  }

  func controls(from id: UUID) -> [ChunkControl] {
    log.filter { $0.from == id }.compactMap { ChunkControl.decode($0.data) }
  }
}

@MainActor
final class MessengerPieceChannelTests: XCTestCase {
  typealias Network = ChunkTestNetwork

  private var root: URL!
  private var network: Network!
  private var sleeps: [Duration] = []
  private var clock = Date(timeIntervalSince1970: 1_000_000)
  private var received: [UUID: [(UUID, URL)]] = [:]
  private let sharerID = UUID()
  private let listenerID = UUID()

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ChunkTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    network = Network()
    sleeps = []
    received = [:]
  }

  override func tearDown() async throws {
    network.channels.values.forEach { $0.stop() }
    network = nil
    try? FileManager.default.removeItem(at: root)
  }

  @discardableResult
  private func makeChannel(_ id: UUID) -> MessengerPieceChannel {
    let channel = MessengerPieceChannel(
      folder: root.appendingPathComponent(id.uuidString, isDirectory: true),
      send: network.sender(for: id),
      sleep: { [weak self] delay in
        self?.sleeps.append(delay)
        // The gap check waits a little real time, as on a device, so chunks the fake network delivers
        // out of order are in before it looks (back-offs don't wait).
        if delay == MessengerPieceChannel.gapCheckDelay { try? await Task.sleep(for: .milliseconds(100)) }
      },
      now: { [weak self] in self?.clock ?? Date() })
    channel.sharerID = sharerID
    channel.onPieceReceived = { [weak self] pieceID, url in self?.received[id, default: []].append((pieceID, url)) }
    network.channels[id] = channel
    return channel
  }

  /// A piece file in the sharer's folder.
  private func makePiece(bytes: Int, ext: String = "mp3", name: String = "piece") throws -> URL {
    let folder = root.appendingPathComponent(sharerID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("\(name).\(ext)")
    try Data((0..<bytes).map { UInt8(($0 * 31 + bytes) % 256) }).write(to: url)
    return url
  }

  private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
  }

  private var chunk: Int { ChunkFrame.payloadSize }

  // MARK: Push and reassembly

  func testUploadPushesEveryChunkAndTheListenerGetsTheSameFileWithItsExtension() async throws {
    let sharer = makeChannel(sharerID)
    makeChannel(listenerID)
    let source = try makePiece(bytes: chunk * 2 + 1234, ext: "mp3")

    let id = try await sharer.upload(fileAt: source)

    await waitUntil { received[listenerID]?.count == 1 }
    let (pieceID, url) = try XCTUnwrap(received[listenerID]?.first)
    XCTAssertEqual(pieceID, id)
    XCTAssertEqual(url.lastPathComponent, "\(id.uuidString).mp3")
    XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: source))
    XCTAssertEqual(network.chunks(to: listenerID).count, 3)
    XCTAssertEqual(sharer.hasPiece(id), true)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    XCTAssertFalse(leftovers.contains { $0.hasSuffix(".part") }, "\(leftovers)")
  }

  func testAPieceWithoutAShortExtensionArrivesAsM4A() async throws {
    let sharer = makeChannel(sharerID)
    makeChannel(listenerID)
    let id = try await sharer.upload(fileAt: try makePiece(bytes: 500, ext: "audiobook"))
    await waitUntil { received[listenerID]?.count == 1 }
    XCTAssertEqual(received[listenerID]?.first?.1.lastPathComponent, "\(id.uuidString).m4a")
  }

  func testChunksArrivingOutOfOrderAndTwiceStillMakeTheFile() async throws {
    let listener = makeChannel(listenerID)
    let source = try makePiece(bytes: chunk * 3 + 10)
    let data = try Data(contentsOf: source)
    let id = UUID()
    let crc = ListenTogetherCRC32.checksum(data)
    let frames = (0..<4).map { index -> ChunkFrame in
      let range = ChunkFrame.byteRange(ofChunk: index, totalBytes: Int64(data.count))
      return ChunkFrame(
        pieceID: id, index: index, count: 4, totalBytes: Int64(data.count), checksum: crc,
        pathExtension: "mp3", payload: data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
    }
    for index in [2, 0, 2, 3] { listener.receive(frames[index].encoded(), from: sharerID) }
    XCTAssertNil(received[listenerID])
    // The .part file is pre-sized to the whole piece.
    let part = root.appendingPathComponent(listenerID.uuidString).appendingPathComponent("\(id.uuidString).part")
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int, data.count)

    listener.receive(frames[1].encoded(), from: sharerID)
    await waitUntil { received[listenerID]?.count == 1 }
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(received[listenerID]?.first?.1)), data)
    // A late duplicate of a finished piece is ignored.
    listener.receive(frames[0].encoded(), from: sharerID)
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(received[listenerID]?.count, 1)
  }

  // MARK: Gaps

  func testAGapAfterTheLastChunkIsRequestedAndOnlyThatChunkIsSentAgainToThatListener() async throws {
    let sharer = makeChannel(sharerID)
    makeChannel(listenerID)
    var dropped = false
    network.filter = { _, _, data in
      if !dropped, let frame = ChunkFrame.decode(data), frame.index == 1 {
        dropped = true
        return nil
      }
      return data
    }
    let id = try await sharer.upload(fileAt: try makePiece(bytes: chunk * 3 + 1))

    await waitUntil { received[listenerID]?.count == 1 }
    XCTAssertEqual(network.controls(from: listenerID), [.chunksMissing(pieceID: id, ranges: [1...1])])
    let resent = network.log.filter { $0.from == sharerID && $0.to == listenerID }.compactMap { ChunkFrame.decode($0.data) }
    XCTAssertEqual(resent.map(\.index), [1])
  }

  /// Found by the full run: a chunk arriving after the last one must not hide a gap.
  func testAGapIsAskedForOnceEvenWhenTheLastChunkCameFirst() async throws {
    let listener = makeChannel(listenerID)
    let id = UUID()
    let total = Int64(chunk * 3 + 10)
    func frame(_ index: Int) -> ChunkFrame {
      ChunkFrame(
        pieceID: id, index: index, count: 4, totalBytes: total, checksum: 0, pathExtension: "m4a",
        payload: Data(count: Int(ChunkFrame.byteRange(ofChunk: index, totalBytes: total).count)))
    }
    for index in [3, 0, 2] { listener.receive(frame(index).encoded(), from: sharerID) }

    await waitUntil { !network.controls(from: listenerID).isEmpty }
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(network.controls(from: listenerID), [.chunksMissing(pieceID: id, ranges: [1...1])])
  }

  func testAChecksumFailureDiscardsThePieceAndAsksForAllOfIt() async throws {
    let sharer = makeChannel(sharerID)
    makeChannel(listenerID)
    var corrupted = false
    network.filter = { _, _, data in
      guard !corrupted, ChunkFrame.decode(data)?.index == 0 else { return data }
      corrupted = true
      var changed = data
      changed[ChunkFrame.headerSize + 5] ^= 0xFF
      return changed
    }
    let source = try makePiece(bytes: chunk + 100)
    let id = try await sharer.upload(fileAt: source)

    await waitUntil { received[listenerID]?.count == 1 }
    XCTAssertEqual(network.controls(from: listenerID), [.chunksMissing(pieceID: id, ranges: [])])
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(received[listenerID]?.first?.1)), try Data(contentsOf: source))
  }

  func testALateJoinerAsksForAnnouncedPiecesAndOnlyItGetsThem() async throws {
    let sharer = makeChannel(sharerID)
    makeChannel(listenerID)
    let id = try await sharer.upload(fileAt: try makePiece(bytes: chunk + 5))
    await waitUntil { received[listenerID]?.count == 1 }
    let sentBefore = network.log.count

    let lateID = UUID()
    let late = makeChannel(lateID)
    late.pieceAnnounced(id)

    await waitUntil { received[lateID]?.count == 1 }
    XCTAssertEqual(received[lateID]?.first?.0, id)
    let after = network.log.dropFirst(sentBefore)
    XCTAssertTrue(after.filter { ChunkFrame.decode($0.data) != nil }.allSatisfy { $0.to == lateID })
    XCTAssertEqual(received[listenerID]?.count, 1)
  }

  func testAnAnnouncedPieceThatIsStillArrivingIsNotRequestedTwice() {
    let listener = makeChannel(listenerID)
    let id = UUID()
    listener.receive(ChunkFrame(
      pieceID: id, index: 0, count: 2, totalBytes: Int64(chunk + 1), checksum: 0, pathExtension: "m4a",
      payload: Data(count: chunk)).encoded(), from: sharerID)
    listener.pieceAnnounced(id)
    XCTAssertTrue(network.controls(from: listenerID).isEmpty)
  }

  func testStalePiecesAreReportedAndAskedForAgain() async throws {
    let listener = makeChannel(listenerID)
    let id = UUID()
    listener.pieceAnnounced(id)
    await waitUntil { network.controls(from: listenerID).count == 1 }
    XCTAssertFalse(listener.hasStalePieces)

    clock += 6
    XCTAssertTrue(listener.hasStalePieces)
    listener.retryStale()
    await waitUntil { network.controls(from: listenerID).count == 2 }
    XCTAssertEqual(network.controls(from: listenerID).last, .chunksMissing(pieceID: id, ranges: []))
    XCTAssertFalse(listener.hasStalePieces)
  }

  func testReloadAsksForAFinishedPieceAgain() async throws {
    let sharer = makeChannel(sharerID)
    let listener = makeChannel(listenerID)
    let id = try await sharer.upload(fileAt: try makePiece(bytes: 300))
    await waitUntil { received[listenerID]?.count == 1 }
    XCTAssertTrue(listener.knows(id))

    listener.reload(id)

    await waitUntil { received[listenerID]?.count == 2 }
    XCTAssertEqual(received[listenerID]?.last?.0, id)
  }

  // MARK: Sharer cache

  func testOnlyTheThreeLatestPiecesAreKeptAndAnOlderOneIsReportedGone() async throws {
    let sharer = makeChannel(sharerID)
    let listener = makeChannel(listenerID)
    var ids: [UUID] = []
    var urls: [URL] = []
    for number in 0..<4 {
      let url = try makePiece(bytes: 100 + number, name: "piece-\(number)")
      urls.append(url)
      ids.append(try await sharer.upload(fileAt: url))
    }
    XCTAssertEqual(sharer.hasPiece(ids[0]), false, "evicted: the sharer prepares it again when asked")
    XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].path), "an evicted piece's file is deleted")
    XCTAssertEqual(ids.dropFirst().map { sharer.hasPiece($0) }, [true, true, true])
    XCTAssertNil(sharer.hasPiece(UUID()))

    listener.reload(ids[0])
    await waitUntil { network.controls(from: sharerID).contains(.pieceGone(pieceID: ids[0])) }
    clock += 10
    XCTAssertFalse(listener.hasStalePieces, "a gone piece is not asked for again")
  }

  func testAPieceOutsideTheFolderIsNeverDeleted() async throws {
    let sharer = makeChannel(sharerID)
    makeChannel(listenerID)
    let outside = root.appendingPathComponent("library-book.mp3")
    try Data([1, 2, 3]).write(to: outside)
    _ = try await sharer.upload(fileAt: outside)
    for number in 0..<3 { _ = try await sharer.upload(fileAt: try makePiece(bytes: 50, name: "p\(number)")) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
  }

  // MARK: Flow control

  func testNeverMoreThanThreeChunksAreInFlight() async throws {
    let sharer = makeChannel(sharerID)
    makeChannel(listenerID)
    network.sendDelay = .milliseconds(5)
    _ = try await sharer.upload(fileAt: try makePiece(bytes: chunk * 30 + 7))
    await waitUntil { received[listenerID]?.count == 1 }
    XCTAssertLessThanOrEqual(network.peakInFlight, 3)
    XCTAssertGreaterThanOrEqual(network.peakInFlight, 2)
  }

  func testSendErrorsBackOffAndThePieceStillArrives() async throws {
    let sharer = makeChannel(sharerID)
    makeChannel(listenerID)
    network.sendErrors = [URLError(.timedOut), URLError(.timedOut), URLError(.timedOut)]
    let source = try makePiece(bytes: chunk * 2 + 3)
    _ = try await sharer.upload(fileAt: source)
    XCTAssertEqual(Array(sleeps.prefix(3)), [.milliseconds(100), .milliseconds(250), .milliseconds(500)])
    await waitUntil { received[listenerID]?.count == 1 }
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(received[listenerID]?.first?.1)), try Data(contentsOf: source))
  }

  func testAPieceThatCantBeSentFailsTheUploadAndIsForgotten() async throws {
    let sharer = makeChannel(sharerID)
    network.sendErrors = Array(repeating: URLError(.timedOut), count: 40)
    do {
      _ = try await sharer.upload(fileAt: try makePiece(bytes: 10))
      XCTFail("the upload should fail")
    } catch {
      XCTAssertEqual(error as? ChunkChannelError, .tooManySendFailures)
    }
    XCTAssertEqual(sleeps.count, MessengerPieceChannel.maxConsecutiveSendFailures)
  }

  // MARK: Stopping

  func testStopEndsAWaitingUploadAndDeletesPartialFiles() async throws {
    let sharer = makeChannel(sharerID)
    let listener = makeChannel(listenerID)
    let id = UUID()
    listener.receive(ChunkFrame(
      pieceID: id, index: 0, count: 2, totalBytes: Int64(chunk + 1), checksum: 0, pathExtension: "m4a",
      payload: Data(count: chunk)).encoded(), from: sharerID)
    let part = root.appendingPathComponent(listenerID.uuidString).appendingPathComponent("\(id.uuidString).part")
    XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))

    listener.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))

    network.filter = { _, _, _ in nil }
    let bytes = chunk * 50
    let upload = Task { try await sharer.upload(fileAt: try self.makePiece(bytes: bytes)) }
    await Task.yield()
    sharer.stop()
    do {
      _ = try await upload.value
      XCTFail("a stopped channel sends nothing more")
    } catch {}
  }

  func testAListenerWithItsOwnCopyDropsChunks() async throws {
    let listener = makeChannel(listenerID)
    listener.stopReceiving()
    listener.receive(ChunkFrame(
      pieceID: UUID(), index: 0, count: 1, totalBytes: 3, checksum: ListenTogetherCRC32.checksum(Data([1, 2, 3])),
      pathExtension: "m4a", payload: Data([1, 2, 3])).encoded(), from: sharerID)
    listener.pieceAnnounced(UUID())
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertNil(received[listenerID])
    XCTAssertTrue(network.log.isEmpty)
  }

  // MARK: Fix round 1

  /// I1: once the sharer is known, chunks from anyone else are dropped (they can't poison a piece).
  func testChunksFromSomeoneOtherThanTheSharerAreDropped() async throws {
    let listener = makeChannel(listenerID)
    let stranger = UUID()
    let data = Data([1, 2, 3])
    let frame = ChunkFrame(
      pieceID: UUID(), index: 0, count: 1, totalBytes: 3, checksum: ListenTogetherCRC32.checksum(data),
      pathExtension: "m4a", payload: data)
    listener.receive(frame.encoded(), from: stranger)
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertNil(received[listenerID])

    listener.receive(frame.encoded(), from: sharerID)
    await waitUntil { received[listenerID]?.count == 1 }
    XCTAssertEqual(received[listenerID]?.count, 1)
  }

  /// I1: at most four pieces are assembled at once; a fifth is dropped (and asked for again later).
  func testAtMostFourPiecesAreAssembledAtOnce() async throws {
    let listener = makeChannel(listenerID)
    let ids = (0..<5).map { _ in UUID() }
    for id in ids {
      listener.receive(ChunkFrame(
        pieceID: id, index: 0, count: 2, totalBytes: Int64(chunk + 1), checksum: 0, pathExtension: "m4a",
        payload: Data(count: chunk)).encoded(), from: sharerID)
    }
    let folder = root.appendingPathComponent(listenerID.uuidString)
    let parts = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".part") }
    XCTAssertEqual(parts.count, 4)
    XCTAssertFalse(parts.contains("\(ids[4].uuidString).part"))
    clock += 6
    listener.retryStale()
    await waitUntil { network.controls(from: listenerID).count == 5 }
    XCTAssertTrue(network.controls(from: listenerID).contains(.chunksMissing(pieceID: ids[4], ranges: [])))
  }

  /// I1: a stale assembly makes room for a new piece.
  func testAStaleAssemblyMakesRoomForANewPiece() throws {
    let listener = makeChannel(listenerID)
    let ids = (0..<5).map { _ in UUID() }
    for (number, id) in ids.enumerated() {
      if number == 4 { clock += 6 }
      listener.receive(ChunkFrame(
        pieceID: id, index: 0, count: 2, totalBytes: Int64(chunk + 1), checksum: 0, pathExtension: "m4a",
        payload: Data(count: chunk)).encoded(), from: sharerID)
    }
    let folder = root.appendingPathComponent(listenerID.uuidString)
    let parts = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".part") }
    XCTAssertEqual(parts.count, 4)
    XCTAssertTrue(parts.contains("\(ids[4].uuidString).part"))
  }

  /// C2: a listener's "journal unusable" reaches the sharer's channel.
  func testJournalUnusableReachesTheSharer() async throws {
    let sharer = makeChannel(sharerID)
    let listener = makeChannel(listenerID)
    var reports: [UUID?] = []
    sharer.onJournalUnusable = { reports.append($0) }
    await listener.reportJournalUnusable()
    await waitUntil { !reports.isEmpty }
    XCTAssertEqual(reports, [listenerID])
    XCTAssertEqual(network.log.last?.to, sharerID, "sent to the sharer only")
  }

  func testModeAnnouncementsReachTheListener() async throws {
    let sharer = makeChannel(sharerID)
    let listener = makeChannel(listenerID)
    var modes: [ListenTogetherTransportMode] = []
    listener.onModeAnnounced = { mode, explicit in
      XCTAssertTrue(explicit)
      modes.append(mode)
    }
    await sharer.announceMode(to: nil)
    await waitUntil { !modes.isEmpty }
    XCTAssertEqual(modes, [.chunks])
  }
}
