@testable import BookPlayer
@testable import BookPlayerKit
import AVFoundation
import Combine
import XCTest

/// SR7-03: a piece that can never be sent, or never played, ends the share with one message instead of
/// being retried for the rest of the session.
@MainActor
final class ListenTogetherGiveUpTests: XCTestCase {
  private var root: URL!
  private var processedFiles: [URL] = []
  private var services: [SharePlaySessionService] = []
  private var system: FakeAppSystem!
  private var exporter: FakePieceExporter!
  private var sleeps: [Duration] = []
  private var timers: ManualScheduler!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("GiveUp-\(UUID())")
    sleeps = []
    system = FakeAppSystem()
    exporter = FakePieceExporter()
    timers = ManualScheduler()
  }

  override func tearDown() async throws {
    services.forEach { $0.end() }
    services = []
    try? FileManager.default.removeItem(at: root)
    processedFiles.forEach { try? FileManager.default.removeItem(at: $0) }
    processedFiles = []
  }

  private func makeService() -> SharePlaySessionService {
    let playerManager = PlayerManagerProtocolMock()
    playerManager.isPlayingPublisherReturnValue = Just(false).eraseToAnyPublisher()
    playerManager.currentSpeedPublisherReturnValue = Just(Float(1)).eraseToAnyPublisher()
    playerManager.underlyingIsPlaying = false
    playerManager.underlyingCurrentSpeed = 1
    let service = SharePlaySessionService(
      playerManager: playerManager,
      storage: ShareStorage(root: root),
      announcer: ListenTogetherAnnouncer(post: { _ in }),
      appSystem: system)
    let exporter = self.exporter!
    service.pieceExporter = { try await exporter.export($0, $1, $2) }
    service.retrySleep = { [weak self] in self?.sleeps.append($0) }
    service.scheduleSessionTimer = timers.schedule
    let control = RecordingCoordinatorControl()
    service.coordinatorControlFactory = { control }
    services.append(service)
    return service
  }

  private func makeHourLongItem() throws -> PlayableItem {
    let url = DataManager.getProcessedFolderURL().appendingPathComponent("GiveUp-\(UUID().uuidString).m4a")
    try AudioFixture.makeM4A(seconds: 1, at: url)
    processedFiles.append(url)
    return PlayableItem.stub(currentTime: 0, duration: 3600, fileURL: url)
  }

  private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func advance(seconds: Double) {
    timers.advance(by: .milliseconds(Int(seconds * 1000)))
  }

  private func pieceFile(_ name: String) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("\(name).m4a")
    try AudioFixture.makeM4A(seconds: 10, at: url)
    return url
  }

  private func manifest(_ id: UUID) -> SharedBookManifest {
    SharedBookManifest(
      shareID: id, title: "T", author: "A", duration: 20,
      chapters: [SharedChapter(title: "One", start: 0, duration: 20)],
      pieces: (0..<2).map { SharedPiece(index: $0, bookStart: Double($0) * 10, duration: 10, byteSize: 1) })
  }

  // MARK: Policy

  func testPermanentFailuresAreRecognised() {
    let full = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
    let gone = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
    XCTAssertTrue(PieceRetryPolicy.isPermanent(BookSplitterError.noLocalFile))
    XCTAssertTrue(PieceRetryPolicy.isPermanent(BookSplitterError.pieceTooLarge(index: 0, bytes: 1)))
    XCTAssertTrue(PieceRetryPolicy.isPermanent(BookSplitterError.exportFailed(index: 0, preset: "copy", underlying: full)))
    XCTAssertTrue(PieceRetryPolicy.isPermanent(gone))
    XCTAssertTrue(PieceRetryPolicy.isPermanent(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
    XCTAssertFalse(PieceRetryPolicy.isPermanent(URLError(.networkConnectionLost)))
    XCTAssertFalse(PieceRetryPolicy.isPermanent(
      BookSplitterError.exportFailed(index: 0, preset: "AppleM4A", underlying: NSError(domain: "x", code: 1))))
    XCTAssertFalse(PieceRetryPolicy.isPermanent(BookSplitterError.exportFailed(index: 0, preset: "copy", underlying: nil)))
  }

  // MARK: Sharer

  func testAPieceThatKeepsFailingEndsTheShareAtTheLimit() async throws {
    let service = makeService(), transport = FakeTransport()
    let lost = BookSplitterError.exportFailed(index: 0, preset: "AppleM4A", underlying: NSError(domain: "x", code: 1))
    exporter.errorsByIndex = [0: Array(repeating: lost, count: 50)]
    await service.beginSharing(with: transport, item: try makeHourLongItem())

    XCTAssertEqual(exporter.attempts.filter { $0 == 0 }.count, PieceRetryPolicy.failureLimit)
    XCTAssertEqual(sleeps.count, PieceRetryPolicy.failureLimit - 1, "no wait after the last try")
    XCTAssertTrue(transport.sent.contains(.sharerCouldNotPrepare), "the listeners are told why")
    XCTAssertEqual(service.state, .ended(reason: .prepareFailed))
    XCTAssertEqual(service.messages.alerts.next?.message, .prepareFailed)
    XCTAssertFalse(system.isIdleTimerDisabled, "the screen may lock again")
  }

  func testAPermanentFailureEndsTheShareAtOnce() async throws {
    let service = makeService(), transport = FakeTransport()
    let full = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
    exporter.errorsByIndex = [0: [BookSplitterError.exportFailed(index: 0, preset: "copy", underlying: full)]]
    await service.beginSharing(with: transport, item: try makeHourLongItem())

    XCTAssertEqual(exporter.attempts, [0])
    XCTAssertEqual(sleeps, [])
    XCTAssertEqual(service.state, .ended(reason: .prepareFailed))
    XCTAssertTrue(transport.sent.contains(.sharerCouldNotPrepare))
  }

  func testTheScreenMayLockWhileWaitingToTryAgain() async throws {
    let service = makeService(), transport = FakeTransport()
    let lost = BookSplitterError.exportFailed(index: 0, preset: "AppleM4A", underlying: NSError(domain: "x", code: 1))
    exporter.errorsByIndex = [0: [lost]]
    var idleTimerDuringWait: [Bool] = []
    service.retrySleep = { [weak self] in
      self?.sleeps.append($0)
      idleTimerDuringWait.append(self?.system.isIdleTimerDisabled ?? true)
    }
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    XCTAssertEqual(idleTimerDuringWait, [false])
    XCTAssertEqual(service.state, .sharing(participants: 1), "one failure doesn't end the share")
  }

  // MARK: Listener

  func testAListenerLeavesWhenAReceivedPieceNeverPlays() async throws {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    service.startListening(with: transport, shareID: id)
    transport.emit(.message(.manifest(manifest(id))))
    await waitUntil { service.listener != nil }
    let attachment = UUID()
    transport.emit(.message(.pieceUploaded(index: 0, attachmentID: attachment)))
    transport.emit(.attachmentReceived(id: attachment, url: try pieceFile("p0")))
    await waitUntil { service.listener?.timeline.isReady(at: 1) == true }
    let listener = try XCTUnwrap(service.listener)

    for attempt in 1..<SharePlaySessionService.receivedPieceFailureLimit {
      listener.pieceFailed(index: 0)
      advance(seconds: 30)
      XCTAssertEqual(transport.reloadedAttachments.count, attempt)
      transport.emit(.attachmentReceived(id: attachment, url: try pieceFile("p0-\(attempt)")))
      await waitUntil { service.listener?.timeline.isReady(at: 1) == true }
    }
    listener.pieceFailed(index: 0)

    XCTAssertEqual(service.state, .ended(reason: .receivedPieceFailed))
    XCTAssertEqual(service.messages.alerts.next?.message, .pieceUnplayable)
    advance(seconds: 60)
    XCTAssertEqual(transport.reloadedAttachments.count, SharePlaySessionService.receivedPieceFailureLimit - 1,
      "nothing is reloaded after leaving")
  }
}
