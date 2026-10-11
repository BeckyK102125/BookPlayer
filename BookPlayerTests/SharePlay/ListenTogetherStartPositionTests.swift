@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import MediaPlayer
import XCTest

/// Records everything the bridge asks of the coordinator, in order.
@MainActor
private final class StartPositionControl: ListenTogetherCoordinatorControlling {
  struct Transition: Equatable {
    let identifier: String?
    let time: TimeInterval?
    let rate: Float
  }

  var log: [String] = []
  var transitions: [Transition] = []
  var seeks: [TimeInterval] = []
  var rateChanges: [Float] = []
  var reapplies = 0

  func coordinateRateChange(to rate: Float) {
    rateChanges.append(rate)
    log.append("rate \(rate)")
  }
  func coordinateSeek(to bookTime: TimeInterval) {
    seeks.append(bookTime)
    log.append("seek \(Int(bookTime))")
  }
  func beginStallSuspension() -> () -> Void {
    log.append("suspend")
    return {}
  }
  func transitionToItem(withIdentifier identifier: String?, proposingTime time: TimeInterval?, rate: Float) {
    transitions.append(Transition(identifier: identifier, time: time, rate: rate))
    log.append("transition \(identifier == nil ? "nil" : "item")")
  }
  func reapplyCurrentItemState() {
    reapplies += 1
    log.append("reapply")
  }
}

@MainActor
private final class StartPositionTarget: ListenTogetherPlaybackTarget {
  var bookTime: TimeInterval = 0
  var isPlaying = false
  var rate: Float = 1
  let subject = PassthroughSubject<LocalPlaybackEvent, Never>()
  var localEvents: AnyPublisher<LocalPlaybackEvent, Never> { subject.eraseToAnyPublisher() }
  func isReady(at bookTime: TimeInterval) -> Bool { true }
  func applyPlay(at bookTime: TimeInterval, rate: Float) {}
  func applyPause(at bookTime: TimeInterval) {}
  func applySeek(to bookTime: TimeInterval) {}
  func applyRate(_ rate: Float) {}
}

/// Build 4: the session starts where the person sharing is, and their saved place is never reset by
/// the group (Becky's report 2026-10-11: the session started at 0:00 and Michael's place became 0:00).
@MainActor
final class ListenTogetherStartPositionTests: XCTestCase {
  private var root: URL!
  private var posted: [String] = []
  private var services: [SharePlaySessionService] = []
  private var control: StartPositionControl!
  private var playerManager: PlayerManagerProtocolMock!
  private var timers: ManualScheduler!
  private let base = Date(timeIntervalSince1970: 1_000_000)

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("StartPosition-\(UUID())")
    posted = []
    control = StartPositionControl()
    timers = ManualScheduler()
    playerManager = PlayerManagerProtocolMock()
    playerManager.isPlayingPublisherReturnValue = Just(false).eraseToAnyPublisher()
    playerManager.currentSpeedPublisherReturnValue = Just(Float(1)).eraseToAnyPublisher()
    playerManager.underlyingIsPlaying = false
    playerManager.underlyingCurrentSpeed = 1
  }

  override func tearDown() async throws {
    services.forEach { $0.end() }
    services = []
    try? FileManager.default.removeItem(at: root)
  }

  private func makeService() -> SharePlaySessionService {
    let service = SharePlaySessionService(
      playerManager: playerManager,
      storage: ShareStorage(root: root),
      announcer: ListenTogetherAnnouncer(post: { [weak self] in self?.posted.append($0) }),
      appSystem: FakeAppSystem())
    service.scheduleSessionTimer = timers.schedule
    service.schedule = timers.schedule
    service.messages.schedule = timers.schedule
    service.messages.postNotification = { _, _ in false }
    service.now = { [unowned self] in
      let elapsed = self.timers.now.components
      return self.base.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
    let control = self.control!
    service.coordinatorControlFactory = { control }
    services.append(service)
    return service
  }

  private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Lets everything already queued on the main queue run (FIFO).
  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
  }

  /// Michael's book, paused at 1234 s and loaded in his player.
  private func startSharingLoadedBook(at time: TimeInterval = 1234) -> (SharePlaySessionService, FakeTransport, PlayableItem) {
    let item = PlayableItem.stub(currentTime: time, duration: 3600)
    playerManager.currentItem = item
    let service = makeService(), transport = FakeTransport()
    XCTAssertTrue(service.startSharingSession(with: transport, item: item, shareID: UUID()))
    return (service, transport, item)
  }

  private func manifest(_ id: UUID) -> SharedBookManifest {
    SharedBookManifest(
      shareID: id, title: "T", author: "A", duration: 20,
      chapters: [SharedChapter(title: "One", start: 0, duration: 20)],
      pieces: (0..<2).map { SharedPiece(index: $0, bookStart: Double($0) * 10, duration: 10, byteSize: 1) })
  }

  private func startListeningWithManifest() async -> (SharePlaySessionService, FakeTransport) {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    service.startListening(with: transport, shareID: id)
    transport.emit(.message(.manifest(manifest(id))))
    await waitUntil { service.listener != nil }
    return (service, transport)
  }

  // MARK: A. Connect first, then transition

  func testTheBridgeProposesNothingUntilItIsStarted() {
    let target = StartPositionTarget()
    target.bookTime = 1234
    let control = StartPositionControl()
    let shareID = UUID()
    let bridge = ListenTogetherCoordinatorBridge(target: target, shareID: shareID, role: .sharer, control: control)
    XCTAssertEqual(control.transitions, [], "nothing is proposed before the coordinator is connected")
    bridge.start(session: nil)
    XCTAssertEqual(control.transitions, [.init(identifier: shareID.uuidString, time: 1234, rate: 0)])
    bridge.start(session: nil)
    XCTAssertEqual(control.transitions.count, 1, "started once")
  }

  func testAListenerProposesPausedAtZeroOnlyOnceStarted() {
    let target = StartPositionTarget()
    let control = StartPositionControl()
    let shareID = UUID()
    let bridge = ListenTogetherCoordinatorBridge(target: target, shareID: shareID, role: .listener, control: control)
    XCTAssertEqual(control.transitions, [])
    bridge.start(session: nil)
    XCTAssertEqual(control.transitions, [.init(identifier: shareID.uuidString, time: nil, rate: 0)])
    XCTAssertEqual(control.seeks, [], "a listener never asserts a position")
  }

  // MARK: B. The sharer asserts its position

  func testSharerAssertsItsPositionWithACoordinatedSeekAfterTransitioning() {
    let (service, _, item) = startSharingLoadedBook()
    XCTAssertEqual(control.log, ["transition item", "seek 1234"])
    XCTAssertEqual(control.transitions, [.init(identifier: service.shareID?.uuidString, time: 1234, rate: 0)])
    XCTAssertEqual(control.rateChanges, [], "paused: no rate change")
    withExtendedLifetime(item) {}
  }

  func testAPlayingSharerAssertsItsPositionAndRate() {
    let item = PlayableItem.stub(currentTime: 500, duration: 3600)
    playerManager.currentItem = item
    playerManager.underlyingIsPlaying = true
    playerManager.underlyingCurrentSpeed = 1.5
    let service = makeService()
    service.startSharingSession(with: FakeTransport(), item: item, shareID: UUID())
    XCTAssertEqual(control.log, ["transition item", "seek 500", "rate 1.5"])
  }

  func testSharerStartsFromTheSharedBooksPlaceWhenThePlayerIsNotOnIt() {
    let item = PlayableItem.stub(currentTime: 900, duration: 3600)
    playerManager.currentItem = nil
    let service = makeService()
    service.startSharingSession(with: FakeTransport(), item: item, shareID: UUID())
    XCTAssertEqual(control.transitions.first?.time, 900)
    XCTAssertEqual(control.seeks, [900], "never 0 just because no book is loaded")
  }

  func testSharerProposesTheSharedBooksPlaceButNeverAssertsWhileAnotherBookIsLoaded() {
    let item = PlayableItem.stub(currentTime: 900, duration: 3600)
    playerManager.currentItem = PlayableItem.stub(currentTime: 50, duration: 3600)
    playerManager.underlyingIsPlaying = true   // the other book plays: the group must not start
    let service = makeService()
    service.startSharingSession(with: FakeTransport(), item: item, shareID: UUID())
    XCTAssertEqual(control.transitions.first?.time, 900, "not the other book's position")
    XCTAssertEqual(control.transitions.first?.rate, 0, "the other book playing is not the shared book playing")
    XCTAssertEqual(control.seeks, [], "no assert while another book is loaded")
    XCTAssertEqual(control.rateChanges, [])
  }

  private func makeOwnCopy() throws -> ListenTogetherOwnCopy {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("own-\(UUID().uuidString).m4a")
    try AudioFixture.makeM4A(seconds: 1, at: file)
    let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64)
    return ListenTogetherOwnCopy(
      relativePath: file.lastPathComponent,
      files: [SourceFile(url: file, bookStart: 0, duration: 20, byteSize: size)],
      chapters: [SharedChapter(title: "One", start: 0, duration: 20)], duration: 20)
  }

  func testAStateRequestBeforeConfirmationReassertsThePosition() async {
    let (_, transport, _) = startSharingLoadedBook()
    transport.emit(.message(.requestState))
    await waitUntil { self.control.seeks.count == 2 }
    XCTAssertEqual(control.seeks, [1234, 1234])
  }

  // MARK: D. The sharer's saved place is protected

  func testSharerIgnoresAGroupPlayAtZeroBeforeTheGroupIsAtItsPlace() async {
    let (service, transport, _) = startSharingLoadedBook()
    service.bridge?.handlePlay(itemTime: 0, rate: 1)
    XCTAssertFalse(playerManager.jumpToRecordBookmarkCalled, "a jump persists the time: it must never happen")
    XCTAssertEqual(playerManager.playCallsCount, 1, "plays where it is")
    await drainMainQueue()
    XCTAssertEqual(control.seeks, [1234, 1234], "and puts the group back at its place")
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(transport.sent, [], "a re-assert is never a message to the others")
  }

  func testSharerIgnoresAGroupSeekToZeroBeforeTheGroupIsAtItsPlace() async {
    let (service, _, _) = startSharingLoadedBook()
    service.bridge?.handleSeek(itemTime: 0)
    service.bridge?.handlePause(itemTime: 0)
    XCTAssertFalse(playerManager.jumpToRecordBookmarkCalled)
    await drainMainQueue()
    XCTAssertEqual(control.seeks, [1234, 1234])
  }

  // MARK: Fix round 1, C1: only a listener confirms

  private let me = UUID(), becky = UUID(), third = UUID()

  /// Michael alone, then Becky joins.
  private func shareAndLetBeckyJoin() async -> (SharePlaySessionService, FakeTransport) {
    let (service, transport, _) = startSharingLoadedBook()
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    await waitUntil { service.hasParticipantBaseline }
    transport.emit(.participantsChanged(count: 2, ids: [me, becky]))
    await waitUntil { service.participantCount == 2 }
    return (service, transport)
  }

  func testTheSharersOwnEchoNeverConfirms() async {
    let (service, _, _) = startSharingLoadedBook()
    service.bridge?.handleSeek(itemTime: 1234)   // the echo of its own assert-seek
    XCTAssertEqual(service.sharerTarget?.isGroupEstablished, false)
    service.bridge?.handleSeek(itemTime: 0)
    service.bridge?.handlePlay(itemTime: 0, rate: 1)
    XCTAssertFalse(playerManager.jumpToRecordBookmarkCalled, "still protected after the echo")
  }

  func testAJoinersPausedAtZeroNeverMovesTheSharer() async {
    let (service, transport) = await shareAndLetBeckyJoin()
    XCTAssertEqual(control.seeks, [1234, 1234], "asserted again for the joiner")
    service.bridge?.handleSeek(itemTime: 0)
    service.bridge?.handlePlay(itemTime: 0, rate: 1)
    XCTAssertFalse(playerManager.jumpToRecordBookmarkCalled)
    await drainMainQueue()
    XCTAssertFalse(transport.sent.contains { if case .action = $0 { return true } else { return false } },
                   "a re-assert is never a message to the others")
  }

  func testTheJoinersInStepConfirmsAndThenDeliberateJumpsApply() async {
    let (service, transport) = await shareAndLetBeckyJoin()
    transport.emit(.inStep(at: 1234.3, from: becky))
    await waitUntil { service.sharerTarget?.isGroupEstablished == true }
    XCTAssertEqual(service.sharerTarget?.isGroupEstablished, true)
    service.bridge?.handleSeek(itemTime: 600)
    XCTAssertEqual(playerManager.jumpToRecordBookmarkReceivedInvocations.map(\.time), [600])
    XCTAssertEqual(playerManager.jumpToRecordBookmarkReceivedArguments?.recordBookmark, false)
  }

  func testWhilePlayingAnInStepReportAllowsForTheMessageDelay() async {
    let item = PlayableItem.stub(currentTime: 1234, duration: 3600)
    playerManager.currentItem = item
    playerManager.underlyingIsPlaying = true
    let service = makeService(), transport = FakeTransport()
    service.startSharingSession(with: transport, item: item, shareID: UUID())
    // 1x playing: 3 s for the tick + 2 s for the message.
    transport.emit(.inStep(at: 1229.5, from: nil))
    await waitUntil { service.sharerTarget?.isGroupEstablished == true }
    XCTAssertEqual(service.sharerTarget?.isGroupEstablished, true)
  }

  func testAnInStepAwayFromTheSharersPlaceReassertsIt() async {
    let (service, transport) = await shareAndLetBeckyJoin()
    timers.advance(by: .seconds(4))   // past the re-assert limit
    transport.emit(.inStep(at: 0, from: becky))
    await waitUntil { self.control.seeks.count == 3 }
    XCTAssertEqual(control.seeks, [1234, 1234, 1234])
    XCTAssertEqual(service.sharerTarget?.isGroupEstablished, false)
  }

  func testALateJoinerRearmsTheProtectionUntilItIsInStep() async {
    let (service, transport) = await shareAndLetBeckyJoin()
    transport.emit(.inStep(at: 1234, from: becky))
    await waitUntil { service.sharerTarget?.isGroupEstablished == true }

    transport.emit(.participantsChanged(count: 3, ids: [me, becky, third]))
    await waitUntil { service.participantCount == 3 }
    XCTAssertEqual(service.sharerTarget?.isGroupEstablished, false, "re-armed for the new joiner")
    XCTAssertEqual(control.seeks.last, 1234, "and the place is asserted for it")
    service.bridge?.handleSeek(itemTime: 0)
    XCTAssertFalse(playerManager.jumpToRecordBookmarkCalled)

    transport.emit(.inStep(at: 1234.5, from: third))
    await waitUntil { service.sharerTarget?.isGroupEstablished == true }
    XCTAssertEqual(service.sharerTarget?.isGroupEstablished, true)
  }

  func testTwoJoinersBothHaveToBeInStep() async {
    let (service, transport) = await shareAndLetBeckyJoin()
    transport.emit(.participantsChanged(count: 3, ids: [me, becky, third]))
    await waitUntil { service.participantCount == 3 }
    transport.emit(.inStep(at: 1234, from: becky))
    await waitUntil { self.timers.now >= .zero && service.participantCount == 3 }
    await drainMainQueue()
    XCTAssertEqual(service.sharerTarget?.isGroupEstablished, false, "the third joiner isn't in step yet")
    transport.emit(.inStep(at: 1234, from: third))
    await waitUntil { service.sharerTarget?.isGroupEstablished == true }
    XCTAssertEqual(service.sharerTarget?.isGroupEstablished, true)
  }

  func testAJoinerWhoLeavesBeforeItIsInStepNoLongerHoldsTheProtection() async {
    let (service, transport) = await shareAndLetBeckyJoin()
    transport.emit(.participantsChanged(count: 3, ids: [me, becky, third]))
    await waitUntil { service.participantCount == 3 }
    transport.emit(.inStep(at: 1234, from: becky))
    transport.emit(.participantsChanged(count: 2, ids: [me, becky]))
    await waitUntil { service.sharerTarget?.isGroupEstablished == true }
    XCTAssertEqual(service.sharerTarget?.isGroupEstablished, true)
  }

  func testRestoreFollowsTheListenerConfirmation() async {
    // Only the echo: still unconfirmed, so a moved-back place is restored.
    let (service, _, _) = startSharingLoadedBook()
    service.bridge?.handleSeek(itemTime: 1234)
    playerManager.currentItem?.currentTime = 0
    service.end()
    XCTAssertEqual(playerManager.jumpToRecordBookmarkReceivedInvocations.map(\.time), [1234])
  }

  func testAConfirmedSessionNeverRestores() async {
    let (service, transport) = await shareAndLetBeckyJoin()
    transport.emit(.inStep(at: 1234, from: becky))
    await waitUntil { service.sharerTarget?.isGroupEstablished == true }
    service.bridge?.handleSeek(itemTime: 100)   // a deliberate group jump
    service.end()
    XCTAssertEqual(playerManager.jumpToRecordBookmarkReceivedInvocations.map(\.time), [100])
  }

  func testADifferentBookIsNeverMovedOrPlayed() async {
    let item = PlayableItem.stub(currentTime: 900, duration: 3600)
    playerManager.currentItem = PlayableItem.stub(currentTime: 50, duration: 3600)
    let service = makeService(), transport = FakeTransport()
    service.startSharingSession(with: transport, item: item, shareID: UUID())
    transport.emit(.inStep(at: 900, from: nil))
    await waitUntil { service.sharerTarget?.isGroupEstablished == true }
    service.bridge?.handleSeek(itemTime: 10)
    service.bridge?.handlePlay(itemTime: 20, rate: 1)
    service.bridge?.handlePause(itemTime: 30)
    XCTAssertFalse(playerManager.jumpToRecordBookmarkCalled)
    XCTAssertEqual(playerManager.playCallsCount, 0, "the other book must not play (its progress would move)")
  }

  func testAnUnconfirmedSessionThatMovedTheSharerBackRestoresTheirPlace() {
    let (service, _, item) = startSharingLoadedBook()
    playerManager.currentItem?.currentTime = 0   // moved by something outside Listen Together's guard
    service.end()
    XCTAssertEqual(playerManager.jumpToRecordBookmarkReceivedInvocations.map(\.time), [1234])
    XCTAssertEqual(playerManager.jumpToRecordBookmarkReceivedArguments?.recordBookmark, false)
    withExtendedLifetime(item) {}
  }

  func testListeningOnBeforeConfirmationIsNotUndone() {
    let (service, _, _) = startSharingLoadedBook()
    playerManager.currentItem?.currentTime = 1500   // Michael kept listening
    service.end()
    XCTAssertFalse(playerManager.jumpToRecordBookmarkCalled)
  }

  // MARK: Fix round 1, I1: speed-aware tolerance and at most one re-assert per 3 s

  private func target(rate: Float, playing: Bool) -> (SharerPlaybackTarget, PlayableItem) {
    let item = PlayableItem.stub(currentTime: 1234, duration: 3600)
    playerManager.currentItem = item
    playerManager.underlyingIsPlaying = playing
    playerManager.underlyingCurrentSpeed = rate
    let target = SharerPlaybackTarget(
      playerManager: playerManager, sharedItemUUID: item.uuid, startPosition: 1234, seekCheckInterval: 1000,
      now: { [unowned self] in self.clock() }, schedule: timers.schedule, deliversOnMainQueue: false)
    return (target, item)
  }

  private func clock() -> Date {
    let elapsed = timers.now.components
    return base.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
  }

  private func reasserts(_ target: SharerPlaybackTarget, _ body: () -> Void) -> [LocalPlaybackEvent] {
    var events: [LocalPlaybackEvent] = []
    let cancellable = target.localEvents.sink { events.append($0) }
    body()
    withExtendedLifetime(cancellable) {}
    return events.filter { if case .reasserted = $0 { return true } else { return false } }
  }

  func testTheToleranceGrowsWithSpeedWhilePlaying() {
    // max(2, 1.5 x rate) + rate x 1 s while playing.
    for (rate, inside, outside) in [(Float(1), 1236.9, 1237.2), (2, 1238.9, 1239.2), (3, 1241.4, 1241.7)] {
      timers.advance(by: .seconds(10))
      let (target, _) = self.target(rate: rate, playing: true)
      XCTAssertEqual(reasserts(target) { target.applySeek(to: inside) }.count, 0, "rate \(rate) inside")
      XCTAssertEqual(reasserts(target) { target.applySeek(to: outside) }.count, 1, "rate \(rate) outside")
      target.stop()
    }
  }

  func testPausedToleranceIsTwoSecondsAtNormalSpeed() {
    let (target, _) = self.target(rate: 1, playing: false)
    XCTAssertEqual(reasserts(target) { target.applySeek(to: 1235.9) }.count, 0)
    XCTAssertEqual(reasserts(target) { target.applySeek(to: 1236.2) }.count, 1)
    target.stop()
  }

  /// Round 2 (N1): a re-assert inside the 3 s limit is delayed to the end of the limit, never dropped.
  func testAReassertInsideTheLimitIsSentWhenTheLimitEnds() {
    let (target, _) = self.target(rate: 1, playing: false)
    var events: [LocalPlaybackEvent] = []
    let cancellable = target.localEvents.sink { events.append($0) }
    target.applySeek(to: 0)
    target.applyPlay(at: 10, rate: 1)
    target.applySeek(to: 20)
    XCTAssertEqual(events.count, 1, "one now")
    timers.advance(by: .seconds(2.9))
    XCTAssertEqual(events.count, 1)
    timers.advance(by: .seconds(0.2))
    XCTAssertEqual(events.count, 2, "and one more when the limit ends (at most one pending)")
    timers.advance(by: .seconds(10))
    XCTAssertEqual(events.count, 2)
    XCTAssertFalse(playerManager.jumpToRecordBookmarkCalled)
    target.stop()
    withExtendedLifetime(cancellable) {}
  }

  func testNoPendingReassertFiresAfterStopOrConfirmation() {
    for ending in ["stop", "confirm"] {
      timers.advance(by: .seconds(10))
      let (target, _) = self.target(rate: 1, playing: false)
      var events: [LocalPlaybackEvent] = []
      let cancellable = target.localEvents.sink { events.append($0) }
      target.applySeek(to: 0)
      target.applySeek(to: 20)   // pending
      if ending == "stop" { target.stop() } else { target.confirmGroup() }
      timers.advance(by: .seconds(5))
      XCTAssertEqual(events.count, 1, ending)
      if ending == "confirm" { target.stop() }
      withExtendedLifetime(cancellable) {}
    }
  }

  func testAnInStepMismatchInsideTheLimitIsReassertedLater() async {
    let (service, transport) = await shareAndLetBeckyJoin()
    service.bridge?.handleSeek(itemTime: 0)       // a stray group time: re-asserted now
    await drainMainQueue()
    XCTAssertEqual(control.seeks.count, 3)
    transport.emit(.inStep(at: 0, from: becky))   // inside the limit: delayed, not dropped
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(control.seeks.count, 3)
    timers.advance(by: .seconds(3))
    await waitUntil { self.control.seeks.count == 4 }
    XCTAssertEqual(control.seeks, [1234, 1234, 1234, 1234])
  }

  // MARK: Round 2 (N2): listeners report after every group time; the sharer listens until confirmed

  func testAMissedInStepIsFollowedByTheNextReportAndConfirms() async {
    let (service, transport) = await shareAndLetBeckyJoin()
    timers.advance(by: .seconds(4))
    transport.emit(.inStep(at: 0, from: becky))            // Becky's first group time was the stray 0
    await waitUntil { self.control.seeks.count == 3 }      // the sharer re-asserts
    transport.emit(.inStep(at: 1234, from: becky))         // her bridge applied that seek: she reports again
    await waitUntil { service.sharerTarget?.isGroupEstablished == true }
    XCTAssertEqual(service.sharerTarget?.isGroupEstablished, true)
  }

  func testOnceConfirmedAnOffPlaceInStepNeverPullsAnyoneBack() async {
    let (service, transport) = await shareAndLetBeckyJoin()
    transport.emit(.inStep(at: 1234, from: becky))
    await waitUntil { service.sharerTarget?.isGroupEstablished == true }
    let seeks = control.seeks.count
    timers.advance(by: .seconds(4))
    transport.emit(.inStep(at: 600, from: becky))          // after a deliberate skip
    try? await Task.sleep(for: .milliseconds(100))
    await drainMainQueue()
    XCTAssertEqual(control.seeks.count, seeks)
    XCTAssertEqual(service.sharerTarget?.isGroupEstablished, true)
  }

  func testTheListenerReportsAfterEveryGroupTimeAtMostOnceEveryTwoSeconds() async throws {
    let (service, transport) = await startListeningWithManifest()
    let inSteps = { transport.sent.compactMap { if case .inStep(let t) = $0 { return t } else { return nil } } }
    service.bridge?.handleSeek(itemTime: 12)
    await waitUntil { inSteps() == [12] }
    XCTAssertEqual(inSteps(), [12], "at once")
    timers.advance(by: .seconds(0.5))
    service.bridge?.handleSeek(itemTime: 13)
    timers.advance(by: .seconds(0.5))
    service.bridge?.handlePlay(itemTime: 14, rate: 1)
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(inSteps(), [12], "coalesced")
    timers.advance(by: .seconds(1))
    await waitUntil { inSteps().count == 2 }
    XCTAssertEqual(inSteps(), [12, 14], "the latest time when the 2 s are up")
    service.bridge?.handlePause(itemTime: 14)
    timers.advance(by: .seconds(5))
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(inSteps(), [12, 14], "a pause carries no time: no report")
    service.listener?.stop()
  }

  func testAReassertUsesTheSharersPlaceWhenItIsSent() async {
    let (service, _, item) = startSharingLoadedBook()
    service.bridge?.handleSeek(itemTime: 0)
    item.currentTime = 1250   // Michael's player moved on before the re-assert goes out
    await drainMainQueue()
    XCTAssertEqual(control.seeks, [1234, 1250])
  }

  // MARK: Fix round 1, I2 + C1: only time-carrying commands open the listener's gate

  func testAPauseDoesNotOpenTheListenersGate() async throws {
    let (service, transport) = await startListeningWithManifest()
    service.bridge?.handlePause(itemTime: 0)
    XCTAssertTrue(service.isListenerJoining)
    service.listener?.userSkip(by: 30)
    XCTAssertEqual(control.seeks, [])
    service.bridge?.handleSeek(itemTime: 12)
    XCTAssertFalse(service.isListenerJoining)
    await waitUntil { transport.sent.contains(.inStep(at: 12)) }
    XCTAssertEqual(transport.sent.filter { $0 == .inStep(at: 12) }.count, 1)
  }

  // MARK: C. The listener waits for the group's timing

  private var findingPlace: String { "listen_together_finding_place".localized }

  func testListenerSendsNothingToTheGroupUntilItsFirstCommand() async throws {
    let (service, transport) = await startListeningWithManifest()
    let listener = try XCTUnwrap(service.listener)
    XCTAssertTrue(service.statusConditions.isJoiningGroup)

    listener.userTogglePlay()
    listener.userSkip(by: 30)
    listener.userSetRate(1.5)
    await drainMainQueue()

    XCTAssertEqual(control.rateChanges, [])
    XCTAssertEqual(control.seeks, [])
    XCTAssertFalse(listener.isPlaying)
    XCTAssertEqual(listener.bookTime, 0)
    XCTAssertFalse(transport.sent.contains { if case .action = $0 { return true } else { return false } })
    XCTAssertEqual(posted.filter { $0 == findingPlace }.count, 1, "one announcement (throttled)")

    service.bridge?.handleSeek(itemTime: 12)
    XCTAssertFalse(service.statusConditions.isJoiningGroup)
    XCTAssertEqual(listener.bookTime, 12)
    listener.userTogglePlay()
    XCTAssertEqual(control.rateChanges, [1])
    listener.stop()
  }

  func testTheWaitingStateIsVisibleNextToTheControlsAndInTheStatus() async {
    let (service, _) = await startListeningWithManifest()
    XCTAssertEqual(findingPlace, "Finding the group's place")
    XCTAssertEqual(ListenTogetherStatus.waitingCaption(service.statusConditions), findingPlace)
    let line = ListenTogetherStatus.line(for: service.state, conditions: service.statusConditions)
    XCTAssertEqual(line?.text, findingPlace)
    XCTAssertEqual(line?.icon, .hourglass)

    service.bridge?.handleSeek(itemTime: 5)
    XCTAssertNotEqual(ListenTogetherStatus.waitingCaption(service.statusConditions), findingPlace)
    XCTAssertNotEqual(
      ListenTogetherStatus.line(for: service.state, conditions: service.statusConditions)?.text, findingPlace)
  }

  func testTheWaitingAnnouncementIsThrottled() async throws {
    let (service, _) = await startListeningWithManifest()
    let listener = try XCTUnwrap(service.listener)
    listener.userTogglePlay()
    listener.userTogglePlay()
    XCTAssertEqual(posted.filter { $0 == findingPlace }.count, 1)
    timers.advance(by: .seconds(2.5))
    listener.userTogglePlay()
    XCTAssertEqual(posted.filter { $0 == findingPlace }.count, 1)
    timers.advance(by: .seconds(1))
    listener.userTogglePlay()
    XCTAssertEqual(posted.filter { $0 == findingPlace }.count, 2)
  }

  func testEveryLocalActionIsHeldWhileFindingThePlace() async throws {
    let (service, _) = await startListeningWithManifest()
    let listener = try XCTUnwrap(service.listener)
    var events: [LocalPlaybackEvent] = []
    let cancellable = listener.localEvents.sink { events.append($0) }
    listener.userJump(to: 15)
    listener.userTogglePlay()
    listener.userSetRate(2)
    XCTAssertEqual(events, [])
    XCTAssertTrue(listener.refusesUserActions)
    withExtendedLifetime(cancellable) {}
  }

  func testTheWaitingStateEndsWithTheSession() async {
    let (service, _) = await startListeningWithManifest()
    XCTAssertTrue(service.isListenerJoining)
    service.end()
    XCTAssertFalse(service.isListenerJoining)
  }

  // MARK: Fix round 1: staged fallback

  func testAfterThreeSecondsTheListenerAsksItsCoordinatorAgain() async {
    let (service, _) = await startListeningWithManifest()
    timers.advance(by: .seconds(2.9))
    XCTAssertEqual(control.reapplies, 0)
    timers.advance(by: .seconds(0.2))
    XCTAssertEqual(control.reapplies, 1)
    withExtendedLifetime(service) {}
  }

  func testFromFiveSecondsTheListenerAsksTheSharerEveryFiveSeconds() async {
    let (service, transport) = await startListeningWithManifest()
    let requests = { transport.sent.filter { $0 == .requestState }.count }
    let before = requests()
    timers.advance(by: .seconds(5))
    await waitUntil { requests() == before + 1 }
    XCTAssertEqual(requests(), before + 1)
    timers.advance(by: .seconds(5))
    await waitUntil { requests() == before + 2 }
    XCTAssertEqual(requests(), before + 2)
    service.bridge?.handleSeek(itemTime: 3)
    timers.advance(by: .seconds(10))
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(requests(), before + 2, "not once the place is found")
  }

  func testAnOwnCopyListenerAlsoAsksTheSharer() async throws {
    let service = makeService(), transport = FakeTransport()
    let ownCopy = try makeOwnCopy()
    XCTAssertTrue(service.startListening(with: transport, shareID: UUID(), ownCopy: ownCopy, title: "T"))
    XCTAssertTrue(service.isListenerJoining)
    timers.advance(by: .seconds(5))
    await waitUntil { transport.sent.contains(.requestState) }
    XCTAssertTrue(transport.sent.contains(.requestState))
    service.listener?.stop()
  }

  func testAfterTwelveSecondsTheStatusSaysWhatToDoAndItIsSaidOnce() async {
    let (service, _) = await startListeningWithManifest()
    let slow = "listen_together_finding_place_slow".localized
    XCTAssertEqual(slow, "If this doesn't change, choose Leave Listen Together and join again.")
    timers.advance(by: .seconds(11.9))
    XCTAssertNotEqual(ListenTogetherStatus.line(for: service.state, conditions: service.statusConditions)?.detail, slow)
    timers.advance(by: .seconds(0.2))
    let line = ListenTogetherStatus.line(for: service.state, conditions: service.statusConditions)
    XCTAssertEqual(line?.text, findingPlace)
    XCTAssertEqual(line?.detail, slow)
    XCTAssertEqual(line?.spoken, findingPlace + ". " + slow)
    XCTAssertEqual(posted.filter { $0.contains(slow) }.count, 1)
    timers.advance(by: .seconds(30))
    XCTAssertEqual(posted.filter { $0.contains(slow) }.count, 1, "once")
    service.bridge?.handleSeek(itemTime: 3)
    XCTAssertNotEqual(ListenTogetherStatus.line(for: service.state, conditions: service.statusConditions)?.detail, slow)
  }

  func testLeaveWorksWhileFindingThePlaceAndNoStageRunsAfterwards() async {
    let (service, transport) = await startListeningWithManifest()
    service.leave()
    XCTAssertFalse(service.isInSession)
    let sentBefore = transport.sent.count
    timers.advance(by: .seconds(30))
    XCTAssertEqual(control.reapplies, 0)
    XCTAssertEqual(transport.sent.count, sentBefore)
    XCTAssertFalse(posted.contains { $0.contains("listen_together_finding_place_slow".localized) })
  }

  func testAStateRequestMakesTheSharerAssertOnlyWhileAJoinerIsNotInStepAndItHoldsTheBook() async {
    let (service, transport) = await shareAndLetBeckyJoin()
    timers.advance(by: .seconds(4))
    transport.emit(.message(.requestState))
    await waitUntil { self.control.seeks.count == 3 }
    XCTAssertEqual(control.seeks.count, 3, "Becky isn't in step: asserted")

    transport.emit(.inStep(at: 1234, from: becky))
    await waitUntil { service.sharerTarget?.isGroupEstablished == true }
    timers.advance(by: .seconds(4))
    transport.emit(.message(.requestState))
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(control.seeks.count, 3, "everyone in step: the group's own state stands")
  }

  func testAStateRequestNeverAssertsWhileTheSharerHoldsAnotherBook() async {
    let item = PlayableItem.stub(currentTime: 900, duration: 3600)
    playerManager.currentItem = PlayableItem.stub(currentTime: 50, duration: 3600)
    let service = makeService(), transport = FakeTransport()
    service.startSharingSession(with: transport, item: item, shareID: UUID())
    transport.emit(.message(.requestState))
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(control.seeks, [])
  }

  // MARK: Fix round 1: a11y

  func testWhileFindingThePlaceThePositionShowsNoTimeAndNoChapter() async throws {
    let (service, _) = await startListeningWithManifest()
    let listener = try XCTUnwrap(service.listener)
    XCTAssertTrue(listener.isJoiningGroup)
    XCTAssertEqual(ListenerPositionText.value(for: listener), findingPlace)
    XCTAssertEqual(ListenerPositionText.elapsedText(for: listener), "--:--")
    XCTAssertEqual(ListenerPositionText.remainingText(for: listener), "--:--")
    XCTAssertNil(ListenerHeaderView.chapter(for: listener))

    service.bridge?.handleSeek(itemTime: 5)
    XCTAssertNotEqual(ListenerPositionText.value(for: listener), findingPlace)
    XCTAssertEqual(ListenerPositionText.elapsedText(for: listener), TimeParser.formatTime(5))
    XCTAssertNotNil(ListenerHeaderView.chapter(for: listener))
  }

  func testTheLockScreenHasNoElapsedTimeWhileFindingThePlace() {
    let manifest = manifest(UUID())
    var state = ListenTogetherNowPlayingState(
      manifest: manifest, bookTime: 0, rate: 1, isPlaying: false, isWaitingForPiece: false)
    state.isPlaceUnknown = true
    let info = ListenTogetherNowPlaying.info(for: state)
    XCTAssertNil(info[MPNowPlayingInfoPropertyElapsedPlaybackTime])
    XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration], "no length: no scrubber at 0:00 (round 2, I-B)")
    XCTAssertNil(info[MPNowPlayingInfoPropertyChapterNumber])
    state.isPlaceUnknown = false
    XCTAssertNotNil(ListenTogetherNowPlaying.info(for: state)[MPNowPlayingInfoPropertyElapsedPlaybackTime])
    XCTAssertNotNil(ListenTogetherNowPlaying.info(for: state)[MPMediaItemPropertyPlaybackDuration])
  }

  func testTheRowSaysFindingThePlace() {
    let value = ListenTogetherRow.value(
      state: .listening(participants: 2, downloaded: 1), joinedTitle: nil,
      listener: .init(title: "Moby Dick", isPlaying: false, isWaiting: false, isFindingPlace: true),
      sharerTitle: nil)
    XCTAssertEqual(value, "finding the group's place, Moby Dick")
  }

  func testOwnCopyJoinedLineWaitsUntilThePlaceIsFound() async throws {
    let service = makeService(), transport = FakeTransport()
    let ownCopy = try makeOwnCopy()
    service.startListening(with: transport, shareID: UUID(), ownCopy: ownCopy, title: "T")
    let joined = "listen_together_joined_own_copy".localized
    service.listenerTitleFocused()
    timers.advance(by: .seconds(2))
    XCTAssertFalse(posted.contains(joined), "not while the place is unknown")
    service.bridge?.handleSeek(itemTime: 0)
    XCTAssertEqual(posted.filter { $0 == joined }.count, 1)
    timers.advance(by: .seconds(5))
    XCTAssertEqual(posted.filter { $0 == joined }.count, 1)
    service.listener?.stop()
  }

  func testReadyIsSaidOnceWhenThePlaceIsFoundPausedAfterARefusedPress() async throws {
    let (service, _) = await startListeningWithManifest()
    let ready = "listen_together_ready".localized
    service.listener?.userTogglePlay()   // refused
    service.bridge?.handleSeek(itemTime: 5)   // found, paused
    XCTAssertEqual(posted.filter { $0 == ready }.count, 1)
  }

  func testReadyIsNotSaidWithoutARefusedPress() async throws {
    let (service, _) = await startListeningWithManifest()
    service.bridge?.handleSeek(itemTime: 5)
    XCTAssertFalse(posted.contains("listen_together_ready".localized))
  }

  func testNewTextIsInEveryLanguageFile() throws {
    let folder = Bundle(for: SharePlaySessionService.self).bundleURL
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "lproj" }
    XCTAssertFalse(files.isEmpty)
    let keys = ["listen_together_finding_place", "listen_together_finding_place_slow",
                "listen_together_row_value_finding_place", "listen_together_ready", "listen_together_time_unknown"]
    for lproj in files {
      let strings = lproj.appendingPathComponent("Localizable.strings")
      guard let table = NSDictionary(contentsOf: strings) else {
        XCTFail("\(lproj.lastPathComponent) can't be read")
        continue
      }
      for key in keys { XCTAssertNotNil(table[key], "\(lproj.lastPathComponent) \(key)") }
      XCTAssertNil(table["listen_together_joining"], "the old wording is gone")
    }
  }

  // MARK: Round 2: requestState (R1, R3), the 12 s line (a11y I-A, M-b), position swipe (M-a), own copy (M-c)

  func testAStateRequestAssertsTheStartPlaceWithNoBookLoadedBeforeConfirmation() async {
    let item = PlayableItem.stub(currentTime: 900, duration: 3600)
    playerManager.currentItem = nil
    let service = makeService(), transport = FakeTransport()
    service.startSharingSession(with: transport, item: item, shareID: UUID())
    transport.emit(.message(.requestState))
    await waitUntil { self.control.seeks.count == 2 }
    XCTAssertEqual(control.seeks, [900, 900])
  }

  func testAfterTheTwelveSecondLineTheListenerAsksLessOften() async {
    let (service, transport) = await startListeningWithManifest()
    let requests = { transport.sent.filter { $0 == .requestState }.count }
    timers.advance(by: .seconds(12.5))
    await waitUntil { requests() >= 2 }
    let atTwelve = requests()
    timers.advance(by: .seconds(2.5))          // 15 s: one more (scheduled at 10 s, before the line)
    await waitUntil { requests() == atTwelve + 1 }
    timers.advance(by: .seconds(10))           // 25 s: the next is at 30 s now, not 20 or 25
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(requests(), atTwelve + 1)
    timers.advance(by: .seconds(5))            // 30 s
    await waitUntil { requests() == atTwelve + 2 }
    XCTAssertEqual(requests(), atTwelve + 2)
    withExtendedLifetime(service) {}
  }

  func testTheTwelveSecondLineIsSaidOnlyWhenItIsTheVisibleStatus() async {
    let (service, transport) = await startListeningWithManifest()
    let slow = "listen_together_finding_place_slow".localized
    let me = UUID(), sharer = UUID()
    transport.emit(.sharerParticipant(id: sharer))
    transport.emit(.participantsChanged(count: 2, ids: [me, sharer]))
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    await waitUntil { service.isSharerGraceRunning }
    timers.advance(by: .seconds(13))
    XCTAssertTrue(service.isListenerJoiningSlow)
    XCTAssertNotEqual(
      ListenTogetherStatus.line(for: service.state, conditions: service.statusConditions)?.detail, slow,
      "the person sharing being away is shown")
    XCTAssertFalse(posted.contains { $0.contains(slow) }, "not said while not shown")
    transport.emit(.participantsChanged(count: 2, ids: [me, sharer]))   // back
    await waitUntil { !service.isSharerGraceRunning }
    XCTAssertEqual(
      ListenTogetherStatus.line(for: service.state, conditions: service.statusConditions)?.detail, slow)
    XCTAssertEqual(posted.filter { $0.contains(slow) }.count, 1, "said once it is shown")
  }

  func testTheTwelveSecondLineDoesNotRepeatAJustSaidPhrase() async throws {
    let (service, _) = await startListeningWithManifest()
    let slow = "listen_together_finding_place_slow".localized
    timers.advance(by: .seconds(11))
    try XCTUnwrap(service.listener).userTogglePlay()   // "Finding the group's place"
    timers.advance(by: .seconds(1.5))
    XCTAssertEqual(posted.last, slow, "only the advice, not the same phrase again")
  }

  func testAPositionSwipeWhileFindingThePlaceSaysNothing() async throws {
    let (service, _) = await startListeningWithManifest()
    let listener = try XCTUnwrap(service.listener)
    ListenerPositionView.adjust(listener, by: 30)
    XCTAssertFalse(posted.contains(findingPlace), "VoiceOver re-reads the value instead")
    XCTAssertEqual(listener.bookTime, 0)
  }

  func testOwnCopyAfterARefusedPressAlsoSaysPlayWorks() async throws {
    let service = makeService(), transport = FakeTransport()
    let ownCopy = try makeOwnCopy()
    service.startListening(with: transport, shareID: UUID(), ownCopy: ownCopy, title: "T")
    service.listenerTitleFocused()
    timers.advance(by: .seconds(2))
    service.listener?.userTogglePlay()    // refused
    service.bridge?.handleSeek(itemTime: 0)
    let joined = "listen_together_joined_own_copy".localized, ready = "listen_together_ready".localized
    XCTAssertEqual(posted.suffix(2), [joined, ready])
    service.listener?.stop()
  }
}
