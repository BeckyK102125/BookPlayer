@testable import BookPlayer
@testable import BookPlayerKit
import Combine
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

  func testSharerStartsFromTheSharedBooksPlaceWhenAnotherBookIsLoaded() {
    let item = PlayableItem.stub(currentTime: 900, duration: 3600)
    playerManager.currentItem = PlayableItem.stub(currentTime: 50, duration: 3600)
    let service = makeService()
    service.startSharingSession(with: FakeTransport(), item: item, shareID: UUID())
    XCTAssertEqual(control.seeks, [900], "not the other book's position")
  }

  func testAJoinBeforeTheGroupIsAtTheSharersPlaceReassertsIt() async {
    let (service, transport, _) = startSharingLoadedBook()
    let me = UUID(), becky = UUID(), third = UUID()
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    await waitUntil { service.hasParticipantBaseline }
    XCTAssertEqual(control.seeks, [1234])

    transport.emit(.participantsChanged(count: 2, ids: [me, becky]))
    await waitUntil { self.control.seeks.count == 2 }
    XCTAssertEqual(control.seeks, [1234, 1234], "the late joiner is given the sharer's place")

    // The group is seen at the sharer's place: later joiners get the group's own state.
    service.bridge?.handleSeek(itemTime: 1234.4)
    transport.emit(.participantsChanged(count: 3, ids: [me, becky, third]))
    await waitUntil { service.participantCount == 3 }
    await drainMainQueue()
    XCTAssertEqual(control.seeks, [1234, 1234])
  }

  func testAStateRequestBeforeConfirmationReassertsThePosition() async {
    let (_, transport, _) = startSharingLoadedBook()
    transport.emit(.message(.requestState))
    await waitUntil { self.control.seeks.count == 2 }
    XCTAssertEqual(control.seeks, [1234, 1234])
  }

  // MARK: D. The sharer's saved place is protected

  func testSharerIgnoresAGroupPlayAtZeroBeforeTheGroupIsAtItsPlace() async {
    let (service, _, _) = startSharingLoadedBook()
    service.bridge?.handlePlay(itemTime: 0, rate: 1)
    XCTAssertFalse(playerManager.jumpToRecordBookmarkCalled, "a jump persists the time: it must never happen")
    XCTAssertEqual(playerManager.playCallsCount, 1, "plays where it is")
    await drainMainQueue()
    XCTAssertEqual(control.seeks, [1234, 1234], "and puts the group back at its place")
  }

  func testSharerIgnoresAGroupSeekToZeroBeforeTheGroupIsAtItsPlace() async {
    let (service, _, _) = startSharingLoadedBook()
    service.bridge?.handleSeek(itemTime: 0)
    service.bridge?.handlePause(itemTime: 0)
    XCTAssertFalse(playerManager.jumpToRecordBookmarkCalled)
    await drainMainQueue()
    XCTAssertEqual(control.seeks, [1234, 1234])
  }

  func testAfterTheGroupIsAtTheSharersPlaceDeliberateJumpsApply() {
    let (service, _, _) = startSharingLoadedBook()
    service.bridge?.handlePlay(itemTime: 1234.5, rate: 1)
    XCTAssertFalse(playerManager.jumpToRecordBookmarkCalled, "within 0.5 s: no jump")
    XCTAssertTrue(service.sharerTarget?.isGroupEstablished == true)
    service.bridge?.handleSeek(itemTime: 600)
    XCTAssertEqual(playerManager.jumpToRecordBookmarkReceivedInvocations.map(\.time), [600])
    XCTAssertEqual(playerManager.jumpToRecordBookmarkReceivedArguments?.recordBookmark, false)
  }

  func testADifferentBookIsNeverMovedOrPlayed() async {
    let item = PlayableItem.stub(currentTime: 900, duration: 3600)
    playerManager.currentItem = PlayableItem.stub(currentTime: 50, duration: 3600)
    let service = makeService()
    service.startSharingSession(with: FakeTransport(), item: item, shareID: UUID())
    service.bridge?.handleSeek(itemTime: 900.5)   // the group is at the shared book's place
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

  func testAConfirmedSessionNeverRestores() {
    let (service, _, _) = startSharingLoadedBook()
    service.bridge?.handleSeek(itemTime: 1234)
    service.bridge?.handleSeek(itemTime: 100)   // a deliberate group jump
    service.end()
    XCTAssertEqual(playerManager.jumpToRecordBookmarkReceivedInvocations.map(\.time), [100])
  }

  func testListeningOnBeforeConfirmationIsNotUndone() {
    let (service, _, _) = startSharingLoadedBook()
    playerManager.currentItem?.currentTime = 1500   // Michael kept listening
    service.end()
    XCTAssertFalse(playerManager.jumpToRecordBookmarkCalled)
  }

  // MARK: C. The listener waits for the group's timing

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
    XCTAssertEqual(posted.filter { $0 == "listen_together_joining".localized }.count, 1, "one announcement (throttled)")

    service.bridge?.handlePause(itemTime: 12)
    XCTAssertFalse(service.statusConditions.isJoiningGroup)
    XCTAssertEqual(listener.bookTime, 12)
    listener.userTogglePlay()
    XCTAssertEqual(control.rateChanges, [1])
    listener.stop()
  }

  func testTheJoiningStateIsVisibleNextToTheControlsAndInTheStatus() async {
    let (service, _) = await startListeningWithManifest()
    let joining = "listen_together_joining".localized
    XCTAssertEqual(ListenTogetherStatus.waitingCaption(service.statusConditions), joining)
    let line = ListenTogetherStatus.line(for: service.state, conditions: service.statusConditions)
    XCTAssertEqual(line?.text, joining)
    XCTAssertEqual(line?.icon, .hourglass)

    service.bridge?.handlePause(itemTime: 5)
    XCTAssertNil(ListenTogetherStatus.waitingCaption(service.statusConditions))
    XCTAssertNotEqual(
      ListenTogetherStatus.line(for: service.state, conditions: service.statusConditions)?.text, joining)
  }

  func testTheJoiningAnnouncementIsThrottled() async throws {
    let (service, _) = await startListeningWithManifest()
    let listener = try XCTUnwrap(service.listener)
    let joining = "listen_together_joining".localized
    listener.userTogglePlay()
    listener.userTogglePlay()
    XCTAssertEqual(posted.filter { $0 == joining }.count, 1)
    timers.advance(by: .seconds(4))
    listener.userTogglePlay()
    XCTAssertEqual(posted.filter { $0 == joining }.count, 2)
  }

  func testEveryLocalActionIsHeldWhileJoining() async throws {
    let (service, _) = await startListeningWithManifest()
    let listener = try XCTUnwrap(service.listener)
    var events: [LocalPlaybackEvent] = []
    let cancellable = listener.localEvents.sink { events.append($0) }
    listener.userJump(to: 15)
    listener.userTogglePlay()
    XCTAssertEqual(events, [])
    withExtendedLifetime(cancellable) {}
  }

  func testTheJoiningStateEndsWithTheSession() async {
    let (service, _) = await startListeningWithManifest()
    XCTAssertTrue(service.isListenerJoining)
    service.end()
    XCTAssertFalse(service.isListenerJoining)
  }

  func testJoiningTextIsInEveryLanguageFile() throws {
    let folder = Bundle(for: SharePlaySessionService.self).bundleURL
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "lproj" }
    XCTAssertFalse(files.isEmpty)
    for lproj in files {
      let strings = lproj.appendingPathComponent("Localizable.strings")
      guard let table = NSDictionary(contentsOf: strings) else { continue }
      XCTAssertNotNil(table["listen_together_joining"], lproj.lastPathComponent)
    }
  }
}
