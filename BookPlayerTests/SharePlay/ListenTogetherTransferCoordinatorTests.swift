@testable import BookPlayer
import XCTest

/// Fix round 1 (I3, I2, C2): the journal/chunks decisions of `GroupSessionTransport`, tested without a
/// GroupSession. A sharer and a listener coordinator share the fake chunk network; main-messenger
/// messages are handed over by the tests.
@MainActor
final class ListenTogetherTransferCoordinatorTests: XCTestCase {
  private enum FakeJournalErrors: Error {
    case notSupported
  }

  private var root: URL!
  private var network: ChunkTestNetwork!
  private let sharerID = UUID()
  private let listenerID = UUID()
  private var journalResults: [Result<UUID, Error>] = []
  private var journalAdds: [URL] = []
  private var sharerMessages: [ListenTogetherMessage] = []
  private var listenerMessages: [ListenTogetherMessage] = []
  private var received: [UUID: [UUID]] = [:]
  private var appActive = true
  private var sharer: ListenTogetherTransferCoordinator!
  private var listener: ListenTogetherTransferCoordinator!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("TransferTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    network = ChunkTestNetwork()
    journalResults = []
    journalAdds = []
    sharerMessages = []
    listenerMessages = []
    received = [:]
    appActive = true
    sharer = makeCoordinator(sharerID) { [weak self] in self?.sharerMessages.append($0) }
    listener = makeCoordinator(listenerID) { [weak self] in self?.listenerMessages.append($0) }
  }

  override func tearDown() async throws {
    sharer.stop()
    listener.stop()
    try? FileManager.default.removeItem(at: root)
  }

  private func makeCoordinator(
    _ id: UUID, record: @escaping @MainActor (ListenTogetherMessage) -> Void
  ) -> ListenTogetherTransferCoordinator {
    let channel = MessengerPieceChannel(
      folder: root.appendingPathComponent(id.uuidString, isDirectory: true),
      send: network.sender(for: id), sleep: { _ in })
    channel.onPieceReceived = { [weak self] pieceID, _ in self?.received[id, default: []].append(pieceID) }
    network.channels[id] = channel
    return ListenTogetherTransferCoordinator(
      channel: channel,
      journalAdd: { [weak self] url in
        guard let self else { throw CancellationError() }
        self.journalAdds.append(url)
        return try (self.journalResults.isEmpty ? .success(UUID()) : self.journalResults.removeFirst()).get()
      },
      sendMessage: { record($0) },
      isAppActive: { [weak self] in self?.appActive ?? true })
  }

  private func makePiece(_ name: String = "piece", bytes: Int = 5000) throws -> URL {
    let folder = root.appendingPathComponent(sharerID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("\(name).m4a")
    try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
    return url
  }

  private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
  }

  private func heardFromSharer() {
    listener.messageReceived(.heartbeat, from: sharerID)
  }

  // MARK: Sharer switch (I3, I2)

  func testTheFirstRealFailureIsThrownAndTheSecondSendsTheSamePieceAsChunks() async throws {
    heardFromSharer()
    journalResults = [.failure(URLError(.badServerResponse)), .failure(URLError(.badServerResponse))]
    let piece = try makePiece()

    do {
      _ = try await sharer.upload(fileAt: piece)
      XCTFail("the first failure is the service's to retry")
    } catch {}
    XCTAssertEqual(sharer.mode, .journal)

    let id = try await sharer.upload(fileAt: piece)

    XCTAssertEqual(sharer.mode, .chunks)
    XCTAssertEqual(journalAdds.count, 2)
    XCTAssertEqual(sharer.hasAttachment(id), true)
    await waitUntil { received[listenerID] == [id] }
    XCTAssertEqual(received[listenerID], [id])
    XCTAssertEqual(listener.mode, .chunks)
    // The mode went out before the first chunk.
    let fromSharer = network.log.filter { $0.from == sharerID }
    XCTAssertEqual(ChunkControl.decode(fromSharer.first?.data ?? Data()), .transportMode(.chunks))
  }

  func testNotSupportedSwitchesAtOnce() async throws {
    journalResults = [.failure(FakeJournalErrors.notSupported)]
    _ = try await sharer.upload(fileAt: try makePiece())
    XCTAssertEqual(sharer.mode, .chunks)
  }

  /// I2: the journal's own errors count while the sharer is in another app or locked.
  func testJournalDomainErrorsCountWhileTheAppIsNotActive() async throws {
    appActive = false
    let journalError = NSError(domain: "GroupActivities.GroupSessionJournal.Errors", code: 2)
    journalResults = [.failure(journalError), .failure(journalError)]
    _ = try? await sharer.upload(fileAt: try makePiece())
    _ = try await sharer.upload(fileAt: try makePiece())
    XCTAssertEqual(sharer.mode, .chunks)
  }

  func testOtherErrorsWhileTheAppIsNotActiveAndCancellationsDontCount() async throws {
    appActive = false
    journalResults = [.failure(URLError(.timedOut)), .failure(URLError(.timedOut))]
    _ = try? await sharer.upload(fileAt: try makePiece())
    _ = try? await sharer.upload(fileAt: try makePiece())
    XCTAssertEqual(sharer.mode, .journal)
    appActive = true
    journalResults = [.failure(CancellationError()), .failure(CancellationError())]
    _ = try? await sharer.upload(fileAt: try makePiece())
    _ = try? await sharer.upload(fileAt: try makePiece())
    XCTAssertEqual(sharer.mode, .journal)
  }

  func testAJournalSuccessResetsTheCount() async throws {
    journalResults = [.failure(URLError(.badServerResponse)), .success(UUID()), .failure(URLError(.badServerResponse))]
    for _ in 0..<3 { _ = try? await sharer.upload(fileAt: try makePiece()) }
    XCTAssertEqual(sharer.mode, .journal)
  }

  func testALateJoinerInAChunkSessionIsToldTheModeOnlyThem() async throws {
    journalResults = [.failure(FakeJournalErrors.notSupported)]
    sharer.rosterChanged([sharerID, listenerID], localID: sharerID)
    _ = try await sharer.upload(fileAt: try makePiece())
    let before = network.log.count

    let late = UUID()
    sharer.rosterChanged([sharerID, listenerID, late], localID: sharerID)

    await waitUntil { network.log.count > before }
    let announcements = network.log.dropFirst(before).filter { ChunkControl.decode($0.data) == .transportMode(.chunks) }
    XCTAssertEqual(announcements.map(\.to), [late])
  }

  func testHasAttachmentChunkPiecesFirstThenTheJournalList() async throws {
    let journalID = UUID()
    journalResults = [.success(journalID)]
    let uploaded = try await sharer.upload(fileAt: try makePiece())
    XCTAssertEqual(uploaded, journalID)
    XCTAssertNil(sharer.hasAttachment(journalID), "no journal list yet")
    sharer.journalListChanged([journalID])
    XCTAssertEqual(sharer.hasAttachment(journalID), true)
    XCTAssertEqual(sharer.hasAttachment(UUID()), false)
  }

  // MARK: Listener (I3)

  func testAListenerAsksForPiecesAnnouncedBeforeTheSwitchButNotJournalPieces() async throws {
    heardFromSharer()
    let journalID = UUID(), early = UUID()
    listener.journalListChanged([journalID])
    listener.messageReceived(.pieceUploaded(index: 0, attachmentID: journalID), from: sharerID)
    listener.messageReceived(.pieceUploaded(index: 1, attachmentID: early), from: sharerID)
    XCTAssertTrue(network.controls(from: listenerID).isEmpty, "journal mode: nothing asked for")

    await sharer.channel.announceMode(to: nil)

    await waitUntil { !network.controls(from: listenerID).isEmpty }
    XCTAssertEqual(network.controls(from: listenerID), [.chunksMissing(pieceID: early, ranges: [])])
    XCTAssertTrue(listenerMessages.isEmpty, "this listener's journal works: no needPiece")
  }

  func testReloadRoutesChunkPiecesToTheChannelAndJournalPiecesBack() async throws {
    heardFromSharer()
    journalResults = [.failure(FakeJournalErrors.notSupported)]
    let id = try await sharer.upload(fileAt: try makePiece())
    await waitUntil { received[listenerID] == [id] }

    XCTAssertFalse(listener.reloadChunkPiece(UUID(), isJournalAttachment: true))
    XCTAssertTrue(listener.reloadChunkPiece(id, isJournalAttachment: false))
    await waitUntil { received[listenerID]?.count == 2 }
    XCTAssertEqual(received[listenerID], [id, id])
  }

  // MARK: Listener-side fallback (C2)

  /// The journal accepts the sharer's add but the listener can't load: after two real load failures
  /// the listener reports it, the sharer switches and announces, journal pieces count as gone, and the
  /// listener asks for its missing pieces again in the order they were announced.
  func testListenerLoadFailuresSwitchTheSharerAndThePiecesAreAskedForAgain() async throws {
    heardFromSharer()
    let first = UUID(), second = UUID()
    journalResults = [.success(first), .success(second)]
    let uploadedFirst = try await sharer.upload(fileAt: try makePiece("a"))
    let uploadedSecond = try await sharer.upload(fileAt: try makePiece("b"))
    XCTAssertEqual([uploadedFirst, uploadedSecond], [first, second])
    sharer.journalListChanged([first, second])
    listener.journalListChanged([first, second])
    listener.messageReceived(.pieceUploaded(index: 4, attachmentID: first), from: sharerID)
    listener.messageReceived(.pieceUploaded(index: 5, attachmentID: second), from: sharerID)

    listener.journalLoadFailed(first, error: URLError(.badServerResponse), appWasActive: true)
    XCTAssertFalse(listener.reportedJournalUnusable)
    listener.journalLoadFailed(second, error: URLError(.badServerResponse), appWasActive: true)
    XCTAssertTrue(listener.reportedJournalUnusable)

    await waitUntil { listenerMessages.count == 2 }
    XCTAssertEqual(sharer.mode, .chunks)
    XCTAssertEqual(sharer.hasAttachment(first), false, "journal pieces count as gone: needPiece re-exports")
    XCTAssertEqual(listener.mode, .chunks)
    XCTAssertEqual(listenerMessages, [.needPiece(index: 4), .needPiece(index: 5)])
    XCTAssertTrue(listener.hasAbandonedJournal)
  }

  func testANotSupportedLoadIsReportedAtOnce() async throws {
    heardFromSharer()
    _ = try await sharer.upload(fileAt: try makePiece())
    listener.journalLoadFailed(UUID(), error: FakeJournalErrors.notSupported, appWasActive: true)
    XCTAssertTrue(listener.reportedJournalUnusable)
    await waitUntil { sharer.mode == .chunks }
    XCTAssertEqual(sharer.mode, .chunks)
  }

  func testLoadInterruptionsAndSuccessesDontReport() {
    heardFromSharer()
    listener.journalLoadFailed(UUID(), error: CancellationError(), appWasActive: true)
    listener.journalLoadFailed(UUID(), error: URLError(.timedOut), appWasActive: false)
    listener.journalLoadFailed(UUID(), error: URLError(.badServerResponse), appWasActive: true)
    listener.journalPieceLoaded(UUID())
    listener.journalLoadFailed(UUID(), error: URLError(.badServerResponse), appWasActive: true)
    XCTAssertFalse(listener.reportedJournalUnusable)
  }

  func testAReceivedJournalPieceIsNotAskedForAgain() async throws {
    heardFromSharer()
    let first = UUID(), second = UUID()
    journalResults = [.success(first), .success(second)]
    _ = try await sharer.upload(fileAt: try makePiece("a"))
    _ = try await sharer.upload(fileAt: try makePiece("b"))
    listener.journalListChanged([first, second])
    listener.messageReceived(.pieceUploaded(index: 0, attachmentID: first), from: sharerID)
    listener.messageReceived(.pieceUploaded(index: 1, attachmentID: second), from: sharerID)
    listener.journalPieceLoaded(first)
    listener.journalLoadFailed(second, error: FakeJournalErrors.notSupported, appWasActive: true)

    await waitUntil { !listenerMessages.isEmpty }
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(listenerMessages, [.needPiece(index: 1)])
  }
  // MARK: Fix round 2

  /// N1: the sharer's own switch announces before it has read this listener's report. The needPiece
  /// sent then only gets map entries back; the announcement that answers the report asks again.
  func testTheAnswerToTheReportAsksAgainEvenWhenAnEarlierAnnouncementCrossedIt() async throws {
    heardFromSharer()
    let first = UUID(), second = UUID()
    journalResults = [.success(first), .success(second), .failure(FakeJournalErrors.notSupported)]
    _ = try await sharer.upload(fileAt: try makePiece("a"))
    _ = try await sharer.upload(fileAt: try makePiece("b"))
    sharer.journalListChanged([first, second])
    listener.journalListChanged([first, second])
    listener.messageReceived(.pieceUploaded(index: 4, attachmentID: first), from: sharerID)
    listener.messageReceived(.pieceUploaded(index: 5, attachmentID: second), from: sharerID)
    // The report is held in transit.
    var held: [Data] = []
    network.filter = { from, _, data in
      guard from == self.listenerID, ChunkControl.decode(data) == .journalUnusable else { return data }
      held.append(data)
      return nil
    }

    listener.journalLoadFailed(first, error: FakeJournalErrors.notSupported, appWasActive: true)
    await waitUntil { !held.isEmpty }
    // Meanwhile the sharer's own add fails: it switches and announces, not knowing about the report.
    _ = try await sharer.upload(fileAt: try makePiece("c"))
    await waitUntil { listenerMessages.count == 2 }
    XCTAssertEqual(listenerMessages, [.needPiece(index: 4), .needPiece(index: 5)])
    XCTAssertEqual(sharer.hasAttachment(first), true, "the sharer hasn't read the report yet")

    // The report arrives: journal pieces count as gone, the mode is announced again, and the listener
    // asks again for what is still missing.
    network.filter = nil
    sharer.channel.receive(held[0], from: listenerID)
    await waitUntil { listenerMessages.count == 4 }
    XCTAssertEqual(sharer.hasAttachment(first), false)
    XCTAssertEqual(
      listenerMessages, [.needPiece(index: 4), .needPiece(index: 5), .needPiece(index: 4), .needPiece(index: 5)])
  }

  /// N1: a piece sent again under a new id that has arrived is no longer asked for.
  func testAPieceThatArrivedUnderANewIdIsNotAskedForAgain() async throws {
    heardFromSharer()
    let first = UUID()
    journalResults = [.success(first)]
    _ = try await sharer.upload(fileAt: try makePiece("a"))
    sharer.journalListChanged([first])
    listener.journalListChanged([first])
    listener.messageReceived(.pieceUploaded(index: 4, attachmentID: first), from: sharerID)
    listener.journalLoadFailed(first, error: FakeJournalErrors.notSupported, appWasActive: true)
    await waitUntil { listenerMessages.count == 1 }

    // The re-export arrives as chunks under a new id.
    let resent = try await sharer.upload(fileAt: try makePiece("a2"))
    listener.messageReceived(.pieceUploaded(index: 4, attachmentID: resent), from: sharerID)
    await waitUntil { received[listenerID]?.contains(resent) == true }
    let before = listenerMessages.count
    await sharer.channel.announceMode(to: nil)
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(listenerMessages.count, before, "index 4 is here: nothing asked for")
  }

  /// N3: two listeners, only one can't load from the journal. The other keeps its journal pieces and
  /// asks for nothing.
  func testOnlyTheListenerWhoseJournalFailsAsksAgain() async throws {
    let otherID = UUID()
    var otherMessages: [ListenTogetherMessage] = []
    let other = makeCoordinator(otherID) { otherMessages.append($0) }
    defer { other.stop() }
    heardFromSharer()
    other.messageReceived(.heartbeat, from: sharerID)
    let first = UUID()
    journalResults = [.success(first)]
    _ = try await sharer.upload(fileAt: try makePiece("a"))
    for coordinator in [sharer!, listener!, other] { coordinator.journalListChanged([first]) }
    for coordinator in [listener!, other] {
      coordinator.messageReceived(.pieceUploaded(index: 0, attachmentID: first), from: sharerID)
    }
    other.journalPieceLoaded(first)

    listener.journalLoadFailed(first, error: FakeJournalErrors.notSupported, appWasActive: true)
    await waitUntil { listenerMessages.count == 1 && other.mode == .chunks }

    XCTAssertEqual(listenerMessages, [.needPiece(index: 0)])
    XCTAssertEqual(other.mode, .chunks, "the other listener follows the mode")
    XCTAssertEqual(otherMessages, [], "and asks for nothing")
    XCTAssertFalse(other.hasAbandonedJournal)
    XCTAssertTrue(listener.hasAbandonedJournal)
  }

  /// N2: nothing starts after stop() (a load cancelled by leaving reports nothing).
  func testNothingIsSentAfterStop() async throws {
    heardFromSharer()
    listener.stop()
    listener.journalLoadFailed(UUID(), error: FakeJournalErrors.notSupported, appWasActive: true)
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(network.controls(from: listenerID).isEmpty)
    XCTAssertFalse(listener.reportedJournalUnusable)
  }
}
