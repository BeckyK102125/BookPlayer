@testable import BookPlayer
@testable import BookPlayerKit
import AVFoundation
import Combine
import UIKit
import XCTest

/// The app around the session (idle timer, background tasks, app state), recorded for tests.
@MainActor
final class FakeAppSystem: ListenTogetherAppSystem {
  var appState: ListenTogetherAppState = .active
  let stateSubject = PassthroughSubject<ListenTogetherAppState, Never>()
  var appStateChanges: AnyPublisher<ListenTogetherAppState, Never> { stateSubject.eraseToAnyPublisher() }
  var isIdleTimerDisabled = false {
    didSet { idleTimerHistory.append(isIdleTimerDisabled) }
  }
  var idleTimerHistory: [Bool] = []
  var begun: [UIBackgroundTaskIdentifier] = []
  var ended: [UIBackgroundTaskIdentifier] = []
  private var expirations: [UIBackgroundTaskIdentifier: @MainActor () -> Void] = [:]
  private var nextID = 1

  func beginBackgroundTask(
    named name: String, expirationHandler: @escaping @MainActor () -> Void
  ) -> UIBackgroundTaskIdentifier {
    let id = UIBackgroundTaskIdentifier(rawValue: nextID)
    nextID += 1
    begun.append(id)
    expirations[id] = expirationHandler
    return id
  }

  func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
    ended.append(identifier)
    expirations[identifier] = nil
  }

  /// The system's background time ran out for every open task.
  func expireAll() {
    for handler in Array(expirations.values) { handler() }
  }

  func become(_ state: ListenTogetherAppState) {
    appState = state
    stateSubject.send(state)
  }
}

/// Exports without AVFoundation: writes a one-byte file, or throws the next queued error.
@MainActor
final class FakePieceExporter {
  var errors: [Error] = []
  /// Errors for one piece only, thrown on its next attempts.
  var errorsByIndex: [Int: [Error]] = [:]
  private(set) var attempts: [Int] = []
  private(set) var exported: [Int] = []
  /// Runs before each attempt (to hold an export, look at the app or end the session meanwhile).
  var beforeExport: ((PlannedPiece) async -> Void)?

  func export(_ piece: PlannedPiece, _ files: [SourceFile], _ folder: URL) async throws -> ExportedPiece {
    attempts.append(piece.index)
    await beforeExport?(piece)
    if !errors.isEmpty { throw errors.removeFirst() }
    if var pending = errorsByIndex[piece.index], !pending.isEmpty {
      let error = pending.removeFirst()
      errorsByIndex[piece.index] = pending
      throw error
    }
    exported.append(piece.index)
    let url = folder.appendingPathComponent("piece-\(piece.index).m4a")
    try Data([1]).write(to: url)
    return ExportedPiece(
      url: url,
      shared: SharedPiece(index: piece.index, bookStart: piece.bookStart, duration: piece.duration, byteSize: 1),
      preset: "test")
  }
}

/// Records what the bridge asks of the coordinator (no real AVDelegatingPlaybackCoordinator).
@MainActor
final class RecordingCoordinatorControl: ListenTogetherCoordinatorControlling {
  var suspensionsBegun = 0
  var suspensionsEnded = 0
  var openSuspensions: Int { suspensionsBegun - suspensionsEnded }
  func coordinateRateChange(to rate: Float) {}
  func coordinateSeek(to bookTime: TimeInterval) {}
  func beginStallSuspension() -> () -> Void {
    suspensionsBegun += 1
    return { [weak self] in self?.suspensionsEnded += 1 }
  }
  func transitionToItem(withIdentifier identifier: String?, proposingTime time: TimeInterval?, rate: Float) {}
}

@MainActor
final class ListenTogetherReliableSendingTests: XCTestCase {
  private var root: URL!
  private var posted: [String] = []
  private var processedFiles: [URL] = []
  private var services: [SharePlaySessionService] = []
  private var system: FakeAppSystem!
  private var exporter: FakePieceExporter!
  private var sleeps: [Duration] = []
  private var timers: ManualScheduler!
  private let base = Date(timeIntervalSince1970: 1_000_000)
  private var control: RecordingCoordinatorControl!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ReliableSending-\(UUID())")
    posted = []
    sleeps = []
    system = FakeAppSystem()
    exporter = FakePieceExporter()
    timers = ManualScheduler()
    control = RecordingCoordinatorControl()
  }

  override func tearDown() async throws {
    services.forEach { $0.end() }
    services = []
    try? FileManager.default.removeItem(at: root)
    processedFiles.forEach { try? FileManager.default.removeItem(at: $0) }
    processedFiles = []
  }

  /// `instantRetries`: back-off waits return at once (their lengths are recorded in `sleeps`).
  private func makeService(instantRetries: Bool = true) -> SharePlaySessionService {
    let playerManager = PlayerManagerProtocolMock()
    playerManager.isPlayingPublisherReturnValue = Just(false).eraseToAnyPublisher()
    playerManager.currentSpeedPublisherReturnValue = Just(Float(1)).eraseToAnyPublisher()
    playerManager.underlyingIsPlaying = false
    playerManager.underlyingCurrentSpeed = 1
    let service = SharePlaySessionService(
      playerManager: playerManager,
      storage: ShareStorage(root: root),
      announcer: ListenTogetherAnnouncer(post: { [weak self] in self?.posted.append($0) }),
      appSystem: system)
    let exporter = self.exporter!
    service.pieceExporter = { try await exporter.export($0, $1, $2) }
    if instantRetries {
      service.retrySleep = { [weak self] in self?.sleeps.append($0) }
    } else {
      service.retrySleep = { [weak self] delay in
        self?.sleeps.append(delay)
        try? await Task.sleep(for: .seconds(3600))
      }
    }
    service.scheduleSessionTimer = timers.schedule
    // The session's clock follows the fake timers, so each check sees the time it was due at.
    service.now = { [unowned self] in
      let elapsed = self.timers.now.components
      return self.base.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
    let control = self.control!
    service.coordinatorControlFactory = { control }
    services.append(service)
    return service
  }

  /// A one-hour book (one chapter) backed by a short real file: five pieces of 12 minutes.
  private func makeHourLongItem(currentTime: TimeInterval = 0) throws -> PlayableItem {
    let url = DataManager.getProcessedFolderURL()
      .appendingPathComponent("ReliableSending-\(UUID().uuidString).m4a")
    try AudioFixture.makeM4A(seconds: 1, at: url)
    processedFiles.append(url)
    return PlayableItem.stub(currentTime: currentTime, duration: 3600, fileURL: url)
  }

  private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func uploadedIndexes(_ transport: FakeTransport) -> [Int] {
    transport.sent.compactMap { if case .pieceUploaded(let index, _) = $0 { return index } else { return nil } }
  }

  private func count(_ transport: FakeTransport, _ match: (ListenTogetherMessage) -> Bool) -> Int {
    transport.sent.filter(match).count
  }

  private func advance(seconds: Double) {
    timers.advance(by: .milliseconds(Int(seconds * 1000)))
  }

  private func manifest(_ id: UUID, pieces: Int = 2) -> SharedBookManifest {
    SharedBookManifest(
      shareID: id, title: "T", author: "A", duration: Double(pieces) * 10,
      chapters: [SharedChapter(title: "One", start: 0, duration: Double(pieces) * 10)],
      pieces: (0..<pieces).map { SharedPiece(index: $0, bookStart: Double($0) * 10, duration: 10, byteSize: 1) })
  }

  private func pieceFile(_ name: String) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("\(name).m4a")
    try AudioFixture.makeM4A(seconds: 10, at: url)
    return url
  }

  // MARK: Scheduling (decision 2)

  func testSchedulerSendsTheGroupPositionFirstThenAheadThenTheRest() {
    let pieces = (0..<10).map {
      PlannedPiece(index: $0, sourceIndex: 0, sourceStart: Double($0) * 720, duration: 720,
                   bookStart: Double($0) * 720, isWholeFile: false, estimatedBytes: 1)
    }
    var scheduler = PieceUploadScheduler(pieces: pieces)
    var order: [Int] = []
    while let next = scheduler.next(at: 2000) {
      order.append(next.index)
      scheduler.markSent(next.index)
    }
    XCTAssertEqual(order, [2, 3, 4, 5, 6, 7, 8, 9, 0, 1])
    XCTAssertTrue(scheduler.isComplete)
  }

  func testSchedulerFollowsAFarSeekAndPutsRequestedPiecesFirst() {
    let pieces = (0..<10).map {
      PlannedPiece(index: $0, sourceIndex: 0, sourceStart: Double($0) * 720, duration: 720,
                   bookStart: Double($0) * 720, isWholeFile: false, estimatedBytes: 1)
    }
    var scheduler = PieceUploadScheduler(pieces: pieces)
    XCTAssertEqual(scheduler.next(at: 0)?.index, 0)
    scheduler.markSent(0)
    XCTAssertEqual(scheduler.next(at: 5000)?.index, 6, "the group seeked far ahead")
    scheduler.request(3)
    XCTAssertEqual(scheduler.next(at: 5000)?.index, 3, "a listener waits for piece 3")
    scheduler.markSent(3)
    XCTAssertEqual(scheduler.next(at: 5000)?.index, 6)
    scheduler.request(0)
    XCTAssertEqual(scheduler.next(at: 5000)?.index, 6, "a request for a piece already sent changes nothing")
  }

  // MARK: Retry policy (decision 5)

  func testBackoffDelaysGrowAndAreCapped() {
    XCTAssertEqual((1...6).map { PieceRetryPolicy.delay(afterFailures: $0) },
                   [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(30), .seconds(30)])
  }

  func testInterruptionsAreRecognised() {
    let interrupted = NSError(domain: AVFoundationErrorDomain, code: AVError.operationInterrupted.rawValue)
    XCTAssertTrue(PieceRetryPolicy.isInterruption(CancellationError()))
    XCTAssertTrue(PieceRetryPolicy.isInterruption(interrupted))
    XCTAssertTrue(PieceRetryPolicy.isInterruption(
      BookSplitterError.exportFailed(index: 1, preset: "passthrough", underlying: interrupted)))
    XCTAssertTrue(PieceRetryPolicy.isInterruption(URLError(.cancelled)))
    XCTAssertFalse(PieceRetryPolicy.isInterruption(URLError(.networkConnectionLost)))
    XCTAssertFalse(PieceRetryPolicy.isInterruption(BookSplitterError.pieceTooLarge(index: 1, bytes: 1)))
    XCTAssertFalse(PieceRetryPolicy.isInterruption(
      BookSplitterError.exportFailed(index: 1, preset: "AppleM4A", underlying: NSError(domain: "x", code: 1))))
  }

  // MARK: The sharer's pipeline

  func testSharerSendsTheGroupPositionFirst() async throws {
    let service = makeService(), transport = FakeTransport()
    service.groupPositionProvider = { 2000 }
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    XCTAssertEqual(uploadedIndexes(transport), [2, 3, 4, 0, 1])
  }

  func testSharerFollowsTheGroupWhenItSeeksFar() async throws {
    let service = makeService(), transport = FakeTransport()
    var position: TimeInterval = 2000
    service.groupPositionProvider = { position }
    exporter.beforeExport = { _ in position = 100 }   // the group moves back during the first export
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    XCTAssertEqual(uploadedIndexes(transport), [2, 0, 1, 3, 4])
  }

  func testPieceFailureNeverEndsTheSessionAndRetriesWithBackoff() async throws {
    let service = makeService(), transport = FakeTransport()
    let lost = BookSplitterError.exportFailed(index: 0, preset: "AppleM4A", underlying: NSError(domain: "x", code: 1))
    exporter.errorsByIndex = [0: Array(repeating: lost, count: 4)]
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    XCTAssertEqual(sleeps, [.seconds(2), .seconds(5), .seconds(15), .seconds(30)], "per piece")
    XCTAssertFalse(transport.sent.contains(.sessionEnding))
    XCTAssertFalse(transport.left)
    XCTAssertEqual(service.state, .sharing(participants: 1))
    XCTAssertEqual(uploadedIndexes(transport), [1, 2, 3, 4, 0], "the failing piece went behind the others")
    XCTAssertNil(service.notice)
  }

  func testAFailedPieceIsReportedAsATypedNoticeUntilItIsSent() async throws {
    let service = makeService(instantRetries: false), transport = FakeTransport()
    transport.uploadErrors = [URLError(.networkConnectionLost)]
    let item = try makeHourLongItem()
    let sending = Task { await service.beginSharing(with: transport, item: item) }
    await waitUntil { !self.sleeps.isEmpty }
    XCTAssertEqual(service.notice, .retryingSend)
    system.become(.active)   // retries at once
    await sending.value
    XCTAssertNil(service.notice)
    XCTAssertEqual(uploadedIndexes(transport).count, 5)
  }

  func testInterruptionsDoNotCountTowardsTheBackoff() async throws {
    let service = makeService(), transport = FakeTransport()
    let interrupted = NSError(domain: AVFoundationErrorDomain, code: AVError.operationInterrupted.rawValue)
    exporter.errorsByIndex = [0: [
      BookSplitterError.exportFailed(index: 0, preset: "passthrough", underlying: interrupted),
      CancellationError(),
      BookSplitterError.exportFailed(index: 0, preset: "AppleM4A", underlying: NSError(domain: "x", code: 1)),
      BookSplitterError.exportFailed(index: 0, preset: "AppleM4A", underlying: NSError(domain: "x", code: 1)),
    ]]
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    XCTAssertEqual(sleeps, [.seconds(2), .seconds(2), .seconds(2), .seconds(5)])
    XCTAssertEqual(uploadedIndexes(transport).count, 5)
  }

  func testAFailureInTheBackgroundIsAnInterruption() async throws {
    let service = makeService(), transport = FakeTransport()
    system.appState = .background
    exporter.errors = [BookSplitterError.exportFailed(index: 0, preset: "AppleM4A", underlying: NSError(domain: "x", code: 1))]
    service.retrySleep = { [weak self, system] delay in
      self?.sleeps.append(delay)
      system?.appState = .active
    }
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    XCTAssertEqual(sleeps, [PieceRetryPolicy.backgroundInterruptionDelay], "waits for the app, does not count")
    XCTAssertEqual(uploadedIndexes(transport).count, 5)
  }

  func testBecomingActiveRetriesAtOnce() async throws {
    let service = makeService(instantRetries: false), transport = FakeTransport()
    transport.uploadErrors = [URLError(.networkConnectionLost)]
    let item = try makeHourLongItem()
    let sending = Task { await service.beginSharing(with: transport, item: item) }
    await waitUntil { !self.sleeps.isEmpty }
    XCTAssertEqual(uploadedIndexes(transport), [])
    system.become(.active)
    await sending.value
    XCTAssertEqual(uploadedIndexes(transport), [1, 2, 3, 4, 0])
  }

  func testEndDuringABackoffStopsThePipeline() async throws {
    let service = makeService(instantRetries: false), transport = FakeTransport()
    transport.uploadErrors = [URLError(.networkConnectionLost)]
    let item = try makeHourLongItem()
    let sending = Task { await service.beginSharing(with: transport, item: item) }
    await waitUntil { !self.sleeps.isEmpty }
    service.end()
    await sending.value
    XCTAssertEqual(uploadedIndexes(transport), [])
    XCTAssertEqual(exporter.attempts, [0])
  }

  // MARK: Staying awake (decision 6)

  func testIdleTimerIsDisabledWhileSendingAndRestoredWhenAllAreSent() async throws {
    let service = makeService(), transport = FakeTransport()
    var disabledDuringExport: [Bool] = []
    exporter.beforeExport = { [system] _ in disabledDuringExport.append(system?.isIdleTimerDisabled ?? false) }
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    XCTAssertEqual(disabledDuringExport, [true, true, true, true, true])
    XCTAssertFalse(system.isIdleTimerDisabled, "restored once every piece is sent")
    XCTAssertTrue(service.isInSession, "the session goes on")
  }

  func testIdleTimerIsRestoredWhenTheSessionEndsMidway() async throws {
    let service = makeService(), transport = FakeTransport()
    exporter.beforeExport = { [weak service] piece in if piece.index == 1 { service?.end() } }
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    XCTAssertFalse(system.isIdleTimerDisabled)
    XCTAssertEqual(system.idleTimerHistory.first, true)
  }

  func testBackgroundTaskIsEndedOnEveryPath() async throws {
    let service = makeService(), transport = FakeTransport()
    // Piece 0: an upload error (it then waits behind the others). Piece 1: background time expires
    // during the export, then success. Piece 2: the session ends during the export.
    transport.uploadErrors = [URLError(.networkConnectionLost)]
    exporter.beforeExport = { [system, weak service] piece in
      if piece.index == 1 { system?.expireAll() }
      if piece.index == 2 { service?.end() }
    }
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    XCTAssertEqual(system.begun.count, 3)
    XCTAssertEqual(Set(system.ended), Set(system.begun), "every task ended")
    XCTAssertEqual(system.ended.count, system.begun.count, "none ended twice")
  }

  // MARK: Manifest and piece map on request (path 5)

  func testListenerRequestsStateUntilItHasTheManifest() async throws {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    service.startListening(with: transport, shareID: id)
    let isRequest: (ListenTogetherMessage) -> Bool = { $0 == .requestState }
    await waitUntil { self.count(transport, isRequest) == 1 }
    XCTAssertEqual(count(transport, isRequest), 1, "asked on join")
    advance(seconds: 5)
    await waitUntil { self.count(transport, isRequest) == 2 }
    XCTAssertEqual(count(transport, isRequest), 2, "asked again 5 s later")
    transport.emit(.message(.manifest(manifest(id))))
    await waitUntil { service.listener != nil }
    advance(seconds: 5)
    advance(seconds: 5)
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(count(transport, isRequest), 2, "not asked once the manifest is here")
  }

  func testSharerAnswersAStateRequestWithTheManifestAndPieceMap() async throws {
    let service = makeService(), transport = FakeTransport()
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    let manifests = count(transport) { if case .manifest = $0 { return true } else { return false } }
    transport.emit(.message(.requestState))
    await waitUntil { self.uploadedIndexes(transport).count == 10 }
    XCTAssertEqual(count(transport) { if case .manifest = $0 { return true } else { return false } }, manifests + 1)
    XCTAssertEqual(uploadedIndexes(transport), [0, 1, 2, 3, 4, 0, 1, 2, 3, 4])
  }

  func testListenerAsksForTheMissingPieceAndTheSharerSendsItFirst() async throws {
    // Listener side: a missing piece is requested from the sharer.
    let listenerService = makeService(), listenerTransport = FakeTransport(), id = UUID()
    listenerService.startListening(with: listenerTransport, shareID: id)
    listenerTransport.emit(.message(.manifest(manifest(id, pieces: 5))))
    await waitUntil { listenerService.listener != nil }
    listenerService.listener?.userJump(to: 35)
    await waitUntil { listenerTransport.sent.contains(.needPiece(index: 3)) }
    XCTAssertTrue(listenerTransport.sent.contains(.needPiece(index: 3)))

    // Sharer side: the request goes before the group's position.
    let service = makeService(), transport = FakeTransport()
    var held: CheckedContinuation<Void, Never>?
    exporter.beforeExport = { piece in
      if piece.index == 0 { await withCheckedContinuation { held = $0 } }
    }
    let item = try makeHourLongItem()
    let sending = Task { await service.beginSharing(with: transport, item: item) }
    await waitUntil { held != nil }
    transport.emit(.message(.needPiece(index: 4)))
    try? await Task.sleep(for: .milliseconds(50))
    held?.resume()
    await sending.value
    XCTAssertEqual(uploadedIndexes(transport), [0, 4, 1, 2, 3])
  }

  // MARK: Progress per piece (decision 3)

  func testProgressMovesWithEachSmallPiece() async throws {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    service.startListening(with: transport, shareID: id)
    transport.emit(.message(.manifest(manifest(id, pieces: 8))))
    await waitUntil { service.listener != nil }
    let attachment = UUID()
    transport.emit(.message(.pieceUploaded(index: 3, attachmentID: attachment)))
    transport.emit(.attachmentReceived(id: attachment, url: try pieceFile("incoming")))
    await waitUntil { service.state == .listening(participants: 1, downloaded: 0.125) }
    XCTAssertEqual(service.state, .listening(participants: 1, downloaded: 0.125))
    XCTAssertFalse(posted.contains(ListenTogetherAnnouncements.download(percent: 25)), "25 percent steps kept")
  }

  // MARK: Stall release (path 3)

  func testAMoveToAnArrivedPieceEndsTheStall() async throws {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    service.startListening(with: transport, shareID: id)
    transport.emit(.message(.manifest(manifest(id))))
    await waitUntil { service.listener != nil }
    let attachment = UUID()
    transport.emit(.message(.pieceUploaded(index: 0, attachmentID: attachment)))
    transport.emit(.attachmentReceived(id: attachment, url: try pieceFile("p0")))
    await waitUntil { service.listener?.isReady(at: 1) == true }
    let listener = try XCTUnwrap(service.listener)

    listener.userJump(to: 15)   // piece 1 is missing: the group waits
    XCTAssertEqual(control.openSuspensions, 1)
    listener.userJump(to: 5)    // back into piece 0, which is here
    XCTAssertEqual(control.openSuspensions, 0, "no piece is awaited any more")
  }

  func testAListenerAtTheStartIsReleasedWhenItsLatePieceArrives() async throws {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    service.startListening(with: transport, shareID: id)
    transport.emit(.message(.manifest(manifest(id))))
    await waitUntil { service.listener != nil }
    let listener = try XCTUnwrap(service.listener)
    listener.userTogglePlay()   // at 0; piece 0 missing
    XCTAssertEqual(control.openSuspensions, 1)

    let late = UUID(), first = UUID()
    transport.emit(.message(.pieceUploaded(index: 1, attachmentID: late)))
    transport.emit(.attachmentReceived(id: late, url: try pieceFile("p1")))
    await waitUntil { listener.isReady(at: 15) }
    XCTAssertEqual(control.openSuspensions, 1, "still waiting for piece 0")
    transport.emit(.message(.pieceUploaded(index: 0, attachmentID: first)))
    transport.emit(.attachmentReceived(id: first, url: try pieceFile("p0")))
    await waitUntil { self.control.openSuspensions == 0 }
    XCTAssertEqual(control.openSuspensions, 0)
  }

  // MARK: The sharer leaving (decision 9)

  func testSharerSendsAHeartbeatEveryFiveSeconds() async throws {
    let service = makeService(), transport = FakeTransport()
    service.startSharingSession(with: transport, item: try makeHourLongItem(), shareID: UUID())
    advance(seconds: 5)
    await waitUntil { transport.sent.contains(.heartbeat) }
    advance(seconds: 5)
    await waitUntil { self.count(transport) { $0 == .heartbeat } == 2 }
    XCTAssertEqual(count(transport) { $0 == .heartbeat }, 2)
  }

  private func startListeningWithManifest() async throws -> (SharePlaySessionService, FakeTransport, UUID) {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    service.startListening(with: transport, shareID: id)
    transport.emit(.message(.manifest(manifest(id))))
    await waitUntil { service.listener != nil }
    return (service, transport, id)
  }

  /// Joined, piece 0 here and the group playing.
  private func startListeningAndPlaying() async throws -> (SharePlaySessionService, FakeTransport, UUID) {
    let (service, transport, id) = try await startListeningWithManifest()
    let attachment = UUID()
    transport.emit(.message(.pieceUploaded(index: 0, attachmentID: attachment)))
    transport.emit(.attachmentReceived(id: attachment, url: try pieceFile("p0")))
    await waitUntil { service.listener?.isReady(at: 1) == true }
    service.listener?.applyPlay(at: 1, rate: 1)
    return (service, transport, id)
  }

  func testASilentSharerIsHarmlessWhileTheGroupIsPaused() async throws {
    let (service, _, _) = try await startListeningWithManifest()
    advance(seconds: 300)
    XCTAssertNil(service.notice, "paused and nothing awaited: a sharer who locked the phone is fine")
    XCTAssertTrue(service.isListenerSession)
  }

  func testASilentSharerBeforeTheManifestIsMissing() async throws {
    let service = makeService(), transport = FakeTransport()
    service.startListening(with: transport, shareID: UUID())
    advance(seconds: 20)
    XCTAssertEqual(service.notice, .waitingForSharer)
  }

  /// Fix round 1 (I2): silence never ends the session; it only shows the waiting notice.
  func testSilenceForTenMinutesWhilePlayingOnlyShowsTheNotice() async throws {
    let (service, transport, _) = try await startListeningAndPlaying()
    advance(seconds: 20)
    XCTAssertEqual(service.notice, .waitingForSharer)
    XCTAssertEqual(control.openSuspensions, 0, "silence alone does not hold the group")
    advance(seconds: 600)
    XCTAssertTrue(service.isListenerSession, "silence never ends the session")
    XCTAssertEqual(service.notice, .waitingForSharer)
    transport.emit(.message(.heartbeat))
    await waitUntil { service.notice == nil }
    XCTAssertNil(service.notice)
  }

  func testRosterWithOnlyThisListenerMeansTheSharerIsMissing() async throws {
    let (service, transport, _) = try await startListeningWithManifest()
    let me = UUID(), sharer = UUID()
    transport.emit(.participantsChanged(count: 2, ids: [me, sharer]))
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    await waitUntil { service.notice == .waitingForSharer }
    XCTAssertEqual(service.notice, .waitingForSharer)
    XCTAssertEqual(control.openSuspensions, 1, "the group waits")
  }

  /// With three people, the sharer is recognised by id (from their messages) when they leave.
  private func joinRosterWithSharer(
    _ transport: FakeTransport, others: Set<UUID> = []
  ) async -> (me: UUID, sharer: UUID) {
    let me = UUID(), sharer = UUID()
    transport.emit(.sharerParticipant(id: sharer))
    transport.emit(.participantsChanged(count: 2 + others.count, ids: others.union([me, sharer])))
    return (me, sharer)
  }

  func testTheSharerLeavingTheRosterPausesTheGroup() async throws {
    let (service, transport, _) = try await startListeningAndPlaying()
    let listener = try XCTUnwrap(service.listener)
    let other = UUID()
    let (me, _) = await joinRosterWithSharer(transport, others: [other])
    transport.emit(.participantsChanged(count: 2, ids: [me, other]))
    await waitUntil { service.notice == .waitingForSharer }
    XCTAssertEqual(service.notice, .waitingForSharer)
    XCTAssertEqual(control.openSuspensions, 1)
    XCTAssertFalse(listener.isPlaying)
  }

  func testRosterLossForSixtyOneSecondsEndsWithSharerLeft() async throws {
    let (service, transport, id) = try await startListeningAndPlaying()
    let folder = root.appendingPathComponent("listener").appendingPathComponent(id.uuidString)
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    let (me, _) = await joinRosterWithSharer(transport)
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    await waitUntil { service.notice == .waitingForSharer }
    advance(seconds: 55)
    XCTAssertTrue(service.isListenerSession, "not yet 60 s missing")
    advance(seconds: 6)
    XCTAssertEqual(service.state, .ended(reason: .sharerLeft))
    XCTAssertNil(service.listener)
    XCTAssertNil(service.joinedTitle)
    XCTAssertNil(service.notice)
    XCTAssertEqual(service.endNotice, .sharerLeft)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the temporary copy is deleted")
    XCTAssertTrue(transport.left)
    XCTAssertEqual(control.openSuspensions, 0)
  }

  func testRosterLossForThirtySecondsThenBackResumes() async throws {
    let (service, transport, _) = try await startListeningAndPlaying()
    let (me, sharer) = await joinRosterWithSharer(transport)
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    await waitUntil { service.notice == .waitingForSharer }
    advance(seconds: 30)
    transport.emit(.participantsChanged(count: 2, ids: [me, sharer]))
    await waitUntil { service.notice == nil }
    XCTAssertNil(service.notice)
    XCTAssertEqual(control.openSuspensions, 0)
    advance(seconds: 60)
    XCTAssertTrue(service.isListenerSession)
  }

  func testSharerEndTearsDownWithSharerEndedAndClearsEverything() async throws {
    let (service, transport, id) = try await startListeningWithManifest()
    let attachment = UUID()
    transport.emit(.message(.pieceUploaded(index: 0, attachmentID: attachment)))
    transport.emit(.attachmentReceived(id: attachment, url: try pieceFile("p0")))
    await waitUntil { service.listener?.isReady(at: 1) == true }
    let folder = root.appendingPathComponent("listener").appendingPathComponent(id.uuidString)
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

    transport.emit(.message(.sessionEnding))
    await waitUntil { !service.isInSession }

    XCTAssertEqual(service.state, .ended(reason: .sharerEnded))
    XCTAssertEqual(service.endNotice, .sharerEnded)
    XCTAssertNil(service.listener)
    XCTAssertNil(service.joinedTitle)
    XCTAssertFalse(service.isUsingOwnCopy)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    XCTAssertTrue(transport.left)
    XCTAssertEqual(posted.last, ListenTogetherAnnouncements.ended(), "generic text until Task B")
    service.acknowledgeEndNotice()
    XCTAssertNil(service.endNotice)
  }

  func testOwnEndIsNotASharerEnding() async throws {
    let (service, _, _) = try await startListeningWithManifest()
    service.end()
    XCTAssertEqual(service.state, .ended(reason: .normal))
    XCTAssertNil(service.endNotice)
  }

  // MARK: Fix round 1

  /// I1: a failed piece load is tried again on a timer, backing off to 30 s, until teardown.
  func testFailedPieceLoadsAreRetriedOnATimer() async throws {
    let (service, transport, _) = try await startListeningWithManifest()
    transport.hasFailedPieceLoads = true
    advance(seconds: 5)
    XCTAssertEqual(transport.loadRetries, 1)
    advance(seconds: 10)
    XCTAssertEqual(transport.loadRetries, 2)
    advance(seconds: 20)
    XCTAssertEqual(transport.loadRetries, 3)
    advance(seconds: 30)
    XCTAssertEqual(transport.loadRetries, 4)
    advance(seconds: 30)
    XCTAssertEqual(transport.loadRetries, 5, "capped at 30 s")
    transport.hasFailedPieceLoads = false
    advance(seconds: 60)
    XCTAssertEqual(transport.loadRetries, 5, "nothing to retry")
    service.end()
    transport.hasFailedPieceLoads = true
    advance(seconds: 120)
    XCTAssertEqual(transport.loadRetries, 5, "stopped at teardown")
  }

  /// I1: a request for a piece already sent re-sends its map entry (the attachment is still there).
  func testRequestForASentPieceResendsItsMessage() async throws {
    let service = makeService(), transport = FakeTransport()
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    XCTAssertEqual(uploadedIndexes(transport).count, 5)
    transport.emit(.message(.needPiece(index: 2)))
    await waitUntil { self.uploadedIndexes(transport).count == 6 }
    XCTAssertEqual(uploadedIndexes(transport).last, 2)
    XCTAssertEqual(transport.uploads.count, 5, "nothing uploaded again")
  }

  /// I1: ...and uploads it again when the journal no longer holds the attachment.
  func testRequestForASentPieceWhoseAttachmentIsGoneUploadsItAgain() async throws {
    let service = makeService(), transport = FakeTransport()
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    guard case .pieceUploaded(_, let attachment)? = transport.sent.first(where: {
      if case .pieceUploaded(2, _) = $0 { return true } else { return false }
    }) else { return XCTFail("no message for piece 2") }
    transport.goneAttachments = [attachment]
    transport.emit(.message(.needPiece(index: 2)))
    await waitUntil { transport.uploads.count == 6 }
    XCTAssertEqual(transport.uploads.count, 6)
    XCTAssertEqual(uploadedIndexes(transport).last, 2)
    XCTAssertEqual(exporter.exported.last, 2)
  }

  /// I3: an ended share is never offered or joined again in this app session.
  func testAnEndedShareIsNotOfferedAgain() async throws {
    let (service, transport, id) = try await startListeningWithManifest()
    transport.emit(.message(.sessionEnding))
    await waitUntil { !service.isInSession }
    XCTAssertEqual(service.decision(forIncoming: id), .endedShare)
    XCTAssertEqual(service.decision(forIncoming: id), .endedShare, "remembered, not used up")
    XCTAssertEqual(service.decision(forIncoming: UUID()), .invitation, "a new invitation still works")
  }

  func testAShareLeftByTheSharerOrByOwnEndIsNotOfferedAgain() async throws {
    let (service, _, id) = try await startListeningWithManifest()
    service.end()
    XCTAssertEqual(service.decision(forIncoming: id), .endedShare)

    let (leftService, transport, leftID) = try await startListeningAndPlaying()
    let (me, _) = await joinRosterWithSharer(transport)
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    await waitUntil { leftService.notice == .waitingForSharer }
    advance(seconds: 61)
    XCTAssertEqual(leftService.state, .ended(reason: .sharerLeft))
    XCTAssertEqual(leftService.decision(forIncoming: leftID), .endedShare)
  }

  /// Minor 4: a piece that can't be played is dropped, loaded again and asked for.
  func testAPieceThatCannotBePlayedIsRequestedAgain() async throws {
    let (service, transport, _) = try await startListeningWithManifest()
    let attachment = UUID()
    transport.emit(.message(.pieceUploaded(index: 0, attachmentID: attachment)))
    transport.emit(.attachmentReceived(id: attachment, url: try pieceFile("p0")))
    await waitUntil { service.listener?.isReady(at: 1) == true }
    let listener = try XCTUnwrap(service.listener)
    listener.applySeek(to: 1)
    listener.pieceFailed(index: 0)
    XCTAssertFalse(listener.isReady(at: 1))
    XCTAssertEqual(transport.reloadedAttachments, [attachment])
    await waitUntil { transport.sent.contains(.needPiece(index: 0)) }
    XCTAssertTrue(transport.sent.contains(.needPiece(index: 0)))
    XCTAssertEqual(control.openSuspensions, 1, "the group waits for the piece")
    // The reloaded file is placed again.
    transport.emit(.attachmentReceived(id: attachment, url: try pieceFile("p0-again")))
    await waitUntil { listener.isReady(at: 1) }
    XCTAssertTrue(listener.isReady(at: 1))
    XCTAssertEqual(control.openSuspensions, 0)
  }

  /// Minor 5: a failed piece goes behind the others; a piece the group waits for goes first.
  func testAFailedPieceGoesBehindTheNextPieces() async throws {
    let service = makeService(), transport = FakeTransport()
    exporter.errorsByIndex = [0: [BookSplitterError.exportFailed(index: 0, preset: "AppleM4A", underlying: nil)]]
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    XCTAssertEqual(uploadedIndexes(transport), [1, 2, 3, 4, 0])
    XCTAssertEqual(sleeps, [.seconds(2)])
  }

  func testAFailedPieceTheGroupWaitsForStillGoesFirst() async throws {
    let service = makeService(), transport = FakeTransport()
    exporter.errorsByIndex = [0: [BookSplitterError.exportFailed(index: 0, preset: "AppleM4A", underlying: nil)]]
    exporter.beforeExport = { piece in
      if piece.index == 0, transport.sent.contains(where: { if case .manifest = $0 { return true } else { return false } }) {
        transport.emit(.message(.needPiece(index: 0)))
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    XCTAssertEqual(uploadedIndexes(transport), [0, 1, 2, 3, 4])
  }

  /// Minor 6: the idle timer is only switched back if this code switched it off.
  func testIdleTimerSetByAnotherFeatureIsLeftAlone() async throws {
    let service = makeService(), transport = FakeTransport()
    system.isIdleTimerDisabled = true
    system.idleTimerHistory = []
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    service.end()
    XCTAssertTrue(system.isIdleTimerDisabled)
    XCTAssertFalse(system.idleTimerHistory.contains(false))
  }

  func testIdleTimerTurnedOnByUsIsTurnedOffEvenIfItWasChangedMeanwhile() async throws {
    let service = makeService(), transport = FakeTransport()
    exporter.beforeExport = { [system] piece in
      if piece.index == 1 { system?.isIdleTimerDisabled = false }   // another screen switched it back
    }
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    XCTAssertFalse(system.isIdleTimerDisabled, "never left on for good")
  }

  /// Minor 7: answers to state requests are rate-limited and coalesced.
  func testStateRequestsAreAnsweredAtMostOncePerTwoSeconds() async throws {
    let service = makeService(), transport = FakeTransport()
    await service.beginSharing(with: transport, item: try makeHourLongItem())
    let isManifest: (ListenTogetherMessage) -> Bool = { if case .manifest = $0 { return true } else { return false } }
    let before = count(transport, isManifest)
    transport.emit(.message(.requestState))
    transport.emit(.message(.requestState))
    transport.emit(.message(.requestState))
    await waitUntil { self.count(transport, isManifest) == before + 1 }
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(count(transport, isManifest), before + 1, "one answer now")
    advance(seconds: 2)
    await waitUntil { self.count(transport, isManifest) == before + 2 }
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(count(transport, isManifest), before + 2, "the others coalesced into one later answer")
    _ = service
  }

  /// Minor 9: a book that can't be prepared reaches listeners as its own reason.
  func testAPrepareFailureReachesListenersAsItsOwnReason() async throws {
    let service = makeService(), transport = FakeTransport()
    let missing = PlayableItem.stub(currentTime: 0, duration: 3600)   // no file on disk
    await service.beginSharing(with: transport, item: missing)
    XCTAssertTrue(transport.sent.contains(.sharerCouldNotPrepare))
    XCTAssertFalse(transport.sent.contains(.sessionEnding))
    XCTAssertEqual(service.state, .ended(reason: .sendFailed))

    let (listenerService, listenerTransport, _) = try await startListeningWithManifest()
    listenerTransport.emit(.message(.sharerCouldNotPrepare))
    await waitUntil { !listenerService.isInSession }
    XCTAssertEqual(listenerService.state, .ended(reason: .sharerCouldNotPrepare))
    XCTAssertEqual(listenerService.endNotice, .sharerCouldNotPrepare)
  }

  /// Minor 10: at most one heartbeat waits in the outbox.
  func testHeartbeatsDoNotPileUp() async throws {
    let service = makeService(), transport = FakeTransport()
    transport.holdSends = true
    service.startSharingSession(with: transport, item: try makeHourLongItem(), shareID: UUID())
    for _ in 0..<4 {
      advance(seconds: 5)
      try? await Task.sleep(for: .milliseconds(20))
    }
    transport.releaseSends()
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(count(transport) { $0 == .heartbeat }, 1)
  }
}
