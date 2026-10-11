@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import XCTest

@MainActor
final class FakeTransport: ListenTogetherTransport {
  private var continuation: AsyncStream<TransportEvent>.Continuation!
  lazy var events: AsyncStream<TransportEvent> = AsyncStream { self.continuation = $0 }
  var sent: [ListenTogetherMessage] = []
  var uploads: [URL] = []
  var left = false
  var failUploads = false
  /// Thrown by the next uploads, one each, before uploads succeed again.
  var uploadErrors: [Error] = []
  /// Listener: a piece load failed and waits for `retryFailedPieceLoads()`.
  var hasFailedPieceLoads = false
  private(set) var loadRetries = 0
  private(set) var reloadedAttachments: [UUID] = []
  /// Sharer: attachments the journal no longer holds.
  var goneAttachments = Set<UUID>()
  /// While true, sends wait until `releaseSends()`.
  var holdSends = false
  private var heldSends: [CheckedContinuation<Void, Never>] = []
  func emit(_ event: TransportEvent) { _ = events; continuation.yield(event) }
  func send(_ message: ListenTogetherMessage) async throws {
    if holdSends { await withCheckedContinuation { heldSends.append($0) } }
    sent.append(message)
  }
  func releaseSends() {
    holdSends = false
    let waiting = heldSends
    heldSends = []
    waiting.forEach { $0.resume() }
  }
  func retryFailedPieceLoads() { loadRetries += 1 }
  func reloadPiece(attachmentID: UUID) { reloadedAttachments.append(attachmentID) }
  func hasAttachment(_ id: UUID) -> Bool? { !goneAttachments.contains(id) }
  func upload(fileAt url: URL) async throws -> UUID {
    if failUploads { throw URLError(.networkConnectionLost) }
    if !uploadErrors.isEmpty { throw uploadErrors.removeFirst() }
    uploads.append(url); return UUID()
  }
  func leave() { left = true; _ = events; continuation.finish() }
}

@MainActor
final class SharePlaySessionServiceTests: XCTestCase {
  private var root: URL!
  private var posted: [String] = []
  private var processedFiles: [URL] = []
  private var services: [SharePlaySessionService] = []

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionTests-\(UUID())")
    posted = []
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
      announcer: ListenTogetherAnnouncer(post: { [weak self] in self?.posted.append($0) }))
    service.retrySleep = { _ in await Task.yield() }
    services.append(service)
    return service
  }

  private func manifest(_ id: UUID) -> SharedBookManifest {
    SharedBookManifest(shareID: id, title: "T", author: "A", duration: 10,
                       chapters: [SharedChapter(title: "One", start: 0, duration: 10)],
                       pieces: [SharedPiece(index: 0, bookStart: 0, duration: 10, byteSize: 1)])
  }

  /// A 10 s audio file the stub item's chapter resolves to.
  private func makeSharedItem() throws -> PlayableItem {
    let url = DataManager.getProcessedFolderURL()
      .appendingPathComponent("SessionTests-\(UUID().uuidString).m4a")
    try AudioFixture.makeM4A(seconds: 10, at: url)
    processedFiles.append(url)
    return PlayableItem.stub(currentTime: 0, duration: 10, fileURL: url)
  }

  private func manifestCount(_ transport: FakeTransport) -> Int {
    transport.sent.filter { if case .manifest = $0 { return true } else { return false } }.count
  }

  /// Gives the service's event loop a chance to run: polls until `condition` holds (bounded).
  private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  func testListenerReceivesManifestAndPieces() async throws {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    Task { await service.beginListening(with: transport, shareID: id) }
    await waitUntil { service.state != .idle }
    transport.emit(.message(.manifest(manifest(id))))
    await waitUntil { service.listener != nil }
    XCTAssertNotNil(service.listener)

    let attachment = UUID()
    let file = root.appendingPathComponent("incoming.m4a")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try AudioFixture.makeM4A(seconds: 10, at: file)
    transport.emit(.message(.pieceUploaded(index: 0, attachmentID: attachment)))
    transport.emit(.attachmentReceived(id: attachment, url: file))
    await waitUntil { service.listener?.isReady(at: 1) == true }
    XCTAssertTrue(service.listener?.isReady(at: 1) == true)
    XCTAssertEqual(service.state, .listening(participants: 1, downloaded: 1))
  }

  func testRemoteActionIsAnnounced() async {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    Task { await service.beginListening(with: transport, shareID: id) }
    await waitUntil { service.state != .idle }
    transport.emit(.message(.action(.paused)))
    await waitUntil { !self.posted.isEmpty }
    XCTAssertEqual(posted.last, "listen_together_remote_paused".localized)
  }

  func testInvalidationDeletesListenerFiles() async throws {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    let folder = try ShareStorage(root: root).folder(for: id, role: .listener)
    try Data([1]).write(to: folder.appendingPathComponent("piece-000.m4a"))
    Task { await service.beginListening(with: transport, shareID: id) }
    await waitUntil { service.state != .idle }
    transport.emit(.invalidated)
    await waitUntil { !service.isInSession }
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    // Task B fix round 1 (I1): not the person's own End, so one alert says why; no announcement.
    XCTAssertEqual(service.endNotice, .connectionEnded)
    XCTAssertFalse(posted.contains(ListenTogetherAnnouncements.ended()))
    XCTAssertEqual(service.messages.alerts.next?.message, .connectionEnded)
  }

  func testManifestResentWhenParticipantsIncrease() async throws {
    let service = makeService(), transport = FakeTransport()
    let item = try makeSharedItem()
    Task { await service.beginSharing(with: transport, item: item) }
    await waitUntil { self.manifestCount(transport) >= 1 && !transport.uploads.isEmpty }
    // The first participants event is the roster at subscribe time: only a baseline.
    transport.emit(.participantsChanged(count: 2))
    await waitUntil { service.state == .sharing(participants: 2) }
    let before = manifestCount(transport)
    transport.emit(.participantsChanged(count: 3))
    await waitUntil { self.manifestCount(transport) > before }
    let after = manifestCount(transport)
    XCTAssertEqual(after, before + 1)
    XCTAssertEqual(posted.last, ListenTogetherAnnouncements.joined())
  }

  /// Addendum 3, decision 5: a piece that keeps failing never ends the session; it is retried.
  func testUploadFailureKeepsTheSessionAndRetries() async throws {
    let service = makeService(), transport = FakeTransport()
    transport.failUploads = true
    let item = try makeSharedItem()
    let sending = Task { await service.beginSharing(with: transport, item: item) }
    await waitUntil { transport.sent.contains { if case .manifest = $0 { return true } else { return false } } }
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(service.state, .sharing(participants: 1))
    XCTAssertFalse(transport.left)
    XCTAssertFalse(transport.sent.contains(.sessionEnding))
    transport.failUploads = false
    await sending.value
    XCTAssertEqual(transport.uploads.count, 1)
  }

  func testFirstParticipantsEventIsOnlyABaseline() async {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    Task { await service.beginListening(with: transport, shareID: id) }
    await waitUntil { service.state != .idle }
    transport.emit(.participantsChanged(count: 3))
    await waitUntil { service.state == .listening(participants: 3, downloaded: 0) }
    XCTAssertEqual(service.state, .listening(participants: 3, downloaded: 0))
    XCTAssertEqual(posted, [])
  }

  func testParticipantCountOfZeroIsIgnored() async {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    Task { await service.beginListening(with: transport, shareID: id) }
    await waitUntil { service.state != .idle }
    transport.emit(.participantsChanged(count: 2))
    transport.emit(.participantsChanged(count: 0))
    // A later real change proves the zero was processed (events are handled in order).
    transport.emit(.participantsChanged(count: 3))
    await waitUntil { service.state == .listening(participants: 3, downloaded: 0) }
    XCTAssertEqual(service.state, .listening(participants: 3, downloaded: 0))
    XCTAssertEqual(posted, [ListenTogetherAnnouncements.joined()])
  }

  func testEndWhilePreparingCancelsTheShare() throws {
    let service = makeService()
    let item = try makeSharedItem()
    XCTAssertNotNil(service.beginPreparing(item))
    XCTAssertEqual(service.state, .preparing(title: item.title))
    XCTAssertNil(service.beginPreparing(item), "a second share while preparing is ignored")

    service.end()

    XCTAssertEqual(service.state, .idle)
    XCTAssertFalse(service.isPreparing)
    XCTAssertEqual(posted, [])
    XCTAssertNotNil(service.beginPreparing(item), "a new share can start after cancelling")
  }

  func testSessionOfCancelledShareIsLeftNotOffered() throws {
    let service = makeService()
    let item = try makeSharedItem()
    let cancelled = try XCTUnwrap(service.beginPreparing(item))
    service.end()

    XCTAssertEqual(service.decision(forIncoming: cancelled), .cancelledShare)
    XCTAssertEqual(service.state, .idle)
    XCTAssertEqual(service.decision(forIncoming: UUID()), .invitation, "other people's shares are still offered")
  }

  func testIncomingSessionDecisions() throws {
    let service = makeService()
    let item = try makeSharedItem()
    let pending = try XCTUnwrap(service.beginPreparing(item))
    XCTAssertEqual(service.decision(forIncoming: pending), .ownShare)
    XCTAssertEqual(service.decision(forIncoming: UUID()), .busy, "no invitation on top of our own share")
    service.end()
    XCTAssertEqual(service.decision(forIncoming: UUID()), .invitation)
  }

  func testSpeedChangedWhilePausedIsAppliedSilently() {
    let target = SpeedTarget()
    XCTAssertEqual(SharePlaySessionService.silentRate(for: .speedChanged(rate: 1.5), target: target), 1.5)
    target.isPlaying = true
    XCTAssertNil(SharePlaySessionService.silentRate(for: .speedChanged(rate: 1.5), target: target),
                 "while playing the coordinator's play command carries the rate")
    target.isPlaying = false
    target.rate = 1.5
    XCTAssertNil(SharePlaySessionService.silentRate(for: .speedChanged(rate: 1.5), target: target))
    XCTAssertNil(SharePlaySessionService.silentRate(for: .paused, target: target))
  }

  // MARK: Fix wave 2: no gap after the join (A-I2)

  /// Join and End in the same main-actor turn: the session is set up synchronously, so End finds it
  /// and leaves it (it used to be lost in the gap before an async setup ran).
  func testListenerSetupIsSynchronousSoAnImmediateEndLeaves() {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    XCTAssertTrue(service.startListening(with: transport, shareID: id))
    XCTAssertTrue(service.isListenerSession)
    XCTAssertEqual(service.state, .listening(participants: 1, downloaded: 0))

    service.end()

    XCTAssertTrue(transport.left)
    XCTAssertFalse(service.isInSession)
    XCTAssertEqual(service.state, .ended(reason: .normal))
  }

  /// A second share arriving right after the join is not offered on top of the session.
  func testSecondShareRightAfterJoinIsBusy() {
    let service = makeService(), transport = FakeTransport()
    service.startListening(with: transport, shareID: UUID())
    XCTAssertEqual(service.decision(forIncoming: UUID()), .busy)
  }

  /// Setting up a second session while one runs changes nothing (the caller then leaves its transport).
  func testSecondSetupWhileInASessionIsRefused() throws {
    let service = makeService(), first = FakeTransport(), second = FakeTransport()
    let id = UUID()
    XCTAssertTrue(service.startListening(with: first, shareID: id))
    XCTAssertFalse(service.startListening(with: second, shareID: UUID()))
    XCTAssertFalse(service.startSharingSession(with: second, item: try makeSharedItem(), shareID: UUID()))
    XCTAssertEqual(service.state, .listening(participants: 1, downloaded: 0))
    service.end()
    XCTAssertTrue(first.left)
  }

  /// The sharer's bookkeeping is synchronous too: End straight after it ends the session, and the
  /// session is left once the end message has been sent.
  func testSharerSetupIsSynchronousSoAnImmediateEndEnds() async throws {
    let service = makeService(), transport = FakeTransport()
    XCTAssertTrue(service.startSharingSession(with: transport, item: try makeSharedItem(), shareID: UUID()))
    XCTAssertTrue(service.isInSession)
    XCTAssertFalse(service.isListenerSession)

    service.end()

    XCTAssertFalse(service.isInSession)
    XCTAssertEqual(service.state, .ended(reason: .normal))
    await waitUntil { transport.left }
    XCTAssertTrue(transport.left)
    XCTAssertEqual(transport.sent, [.sessionEnding])
  }

  /// M2: the sharer's end message gets a short time; a send that never finishes can't hold the leave.
  func testTimeLimitReturnsWhileTheWorkIsStillRunning() async {
    var release: CheckedContinuation<Void, Never>?
    var finished = false
    await SharePlaySessionService.withTimeLimit(.milliseconds(1)) {
      await withCheckedContinuation { release = $0 }
      finished = true
    }
    XCTAssertFalse(finished, "returned at the limit, not when the work finished")
    release?.resume()
  }

  /// M3: the user's own actions are sent one after another, in the order they happened.
  func testLocalActionsAreSentInOrder() async {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    service.startListening(with: transport, shareID: id)
    transport.emit(.message(.manifest(manifest(id))))
    await waitUntil { service.listener != nil }
    let listener = try? XCTUnwrap(service.listener)

    listener?.userSetRate(1.5)
    listener?.userSetRate(2)
    listener?.userSetRate(1.25)
    let actions = { transport.sent.filter { if case .action = $0 { return true } else { return false } } }
    await waitUntil { actions().count >= 3 }

    XCTAssertEqual(actions(), [
      .action(.speedChanged(rate: 1.5)), .action(.speedChanged(rate: 2)), .action(.speedChanged(rate: 1.25)),
    ])
  }

  /// Minor: play/pause while the group is held for this listener's piece says "waiting", sends nothing.
  func testToggleWhileWaitingAnnouncesWaitingAndSendsNothing() async {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    service.startListening(with: transport, shareID: id)
    transport.emit(.message(.manifest(manifest(id))))
    await waitUntil { service.listener != nil }
    guard let listener = service.listener else { return XCTFail("no listener") }
    // No stall suspension on the real (session-less) coordinator here: under Thread Sanitizer, ending
    // one aborts inside CoreMedia (see fix-wave-2-report.md). The wait itself is what this test needs.
    listener.onNeedsPiece = nil
    listener.applyPlay(at: 0, rate: 1)   // the group plays, the piece is missing
    XCTAssertTrue(listener.isWaitingForPiece)
    posted = []

    listener.userTogglePlay()
    listener.userTogglePlay()   // pressed again straight away: not said twice (3 s limit)

    XCTAssertEqual(posted, ["listen_together_waiting_download".localized])
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(transport.sent.contains { if case .action = $0 { return true } else { return false } })
  }
}

@MainActor
private final class SpeedTarget: ListenTogetherPlaybackTarget {
  var bookTime: TimeInterval = 0
  var isPlaying = false
  var rate: Float = 1
  var localEvents: AnyPublisher<LocalPlaybackEvent, Never> { Empty().eraseToAnyPublisher() }
  func isReady(at bookTime: TimeInterval) -> Bool { true }
  func applyPlay(at bookTime: TimeInterval, rate: Float) {}
  func applyPause(at bookTime: TimeInterval) {}
  func applySeek(to bookTime: TimeInterval) {}
  func applyRate(_ rate: Float) { self.rate = rate }
}
