@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import UIKit
import XCTest

/// Transfer fix, item 4: the sharer's End really ends SharePlay (`GroupSession.end()`, through the
/// transport's `end()`), listeners only leave, and the app terminating ends or leaves best-effort.
@MainActor
final class ListenTogetherSessionEndTests: XCTestCase {
  private var root: URL!
  private var posted: [String] = []
  private var processedFiles: [URL] = []
  private var center: NotificationCenter!
  private var services: [SharePlaySessionService] = []

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionEndTests-\(UUID())")
    posted = []
    center = NotificationCenter()
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
      announcer: ListenTogetherAnnouncer(post: { [weak self] in self?.posted.append($0) }),
      notificationCenter: center)
    service.retrySleep = { _ in await Task.yield() }
    services.append(service)
    return service
  }

  private func makeSharedItem() throws -> PlayableItem {
    let url = DataManager.getProcessedFolderURL()
      .appendingPathComponent("SessionEndTests-\(UUID().uuidString).m4a")
    try AudioFixture.makeM4A(seconds: 10, at: url)
    processedFiles.append(url)
    return PlayableItem.stub(currentTime: 0, duration: 10, fileURL: url)
  }

  private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
  }

  // MARK: End

  func testSharerEndSendsTheEndMessageThenEndsTheGroupSessionForEveryone() async throws {
    let service = makeService(), transport = FakeTransport()
    XCTAssertTrue(service.startSharingSession(with: transport, item: try makeSharedItem(), shareID: UUID()))

    service.end()

    await waitUntil { transport.ended }
    XCTAssertTrue(transport.ended)
    XCTAssertFalse(transport.left, "the sharer ends SharePlay, it doesn't just leave it")
    XCTAssertEqual(transport.sent, [.sessionEnding])
    // Fix round 1: piece transfers stop first (before the share folder is deleted), the end message
    // goes out, and only then is the group session ended.
    XCTAssertEqual(transport.calls, ["stopPieceTransfers", "send:sessionEnding", "end"])
    XCTAssertEqual(service.state, .ended(reason: .normal))
  }

  func testSharerEndStillEndsWhenTheEndMessageNeverGoesOut() async throws {
    let service = makeService(), transport = FakeTransport()
    service.startSharingSession(with: transport, item: try makeSharedItem(), shareID: UUID())
    transport.holdSends = true

    service.end()

    await waitUntil(timeout: 6) { transport.ended }
    XCTAssertTrue(transport.ended, "ended after the time limit")
    transport.releaseSends()
  }

  func testListenerEndOnlyLeaves() async {
    let service = makeService(), transport = FakeTransport()
    service.startListening(with: transport, shareID: UUID())

    service.end()

    await waitUntil { transport.left }
    XCTAssertTrue(transport.left)
    XCTAssertFalse(transport.ended, "a listener never ends the session for the others")
  }

  // MARK: The app closing

  func testTerminatingWhileSharingEndsTheGroupSessionAtOnce() throws {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    service.startSharingSession(with: transport, item: try makeSharedItem(), shareID: id)
    posted = []

    center.post(name: UIApplication.willTerminateNotification, object: nil)

    XCTAssertTrue(transport.ended)
    XCTAssertFalse(transport.left)
    XCTAssertEqual(transport.calls, ["stopPieceTransfers", "end"])
    XCTAssertFalse(service.isInSession)
    XCTAssertEqual(posted, [], "nothing is announced while the app closes")
    XCTAssertEqual(service.decision(forIncoming: id), .endedShare)
  }

  func testTerminatingWhileListeningLeaves() {
    let service = makeService(), transport = FakeTransport()
    service.startListening(with: transport, shareID: UUID())

    center.post(name: UIApplication.willTerminateNotification, object: nil)

    XCTAssertTrue(transport.left)
    XCTAssertFalse(transport.ended)
    XCTAssertFalse(service.isInSession)
    XCTAssertNil(service.endNotice)
  }

  /// Fix round 1, C3: a scene going away (iOS can disconnect a background scene that keeps playing) never
  /// ends the session; only termination does.
  func testASceneDisconnectingDoesNotEndTheSession() throws {
    let service = makeService(), transport = FakeTransport()
    service.startSharingSession(with: transport, item: try makeSharedItem(), shareID: UUID())

    center.post(name: UIScene.didDisconnectNotification, object: nil)

    XCTAssertTrue(service.isInSession)
    XCTAssertFalse(transport.ended)
    XCTAssertFalse(transport.left)
  }

  /// Fix round 2 (Minor 6): a teardown also empties incoming/ (journal imports whose load failed).
  func testTeardownEmptiesTheIncomingFolder() throws {
    let service = makeService(), transport = FakeTransport()
    service.startListening(with: transport, shareID: UUID())
    let incoming = root.appendingPathComponent("incoming", isDirectory: true)
    try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
    try Data([1]).write(to: incoming.appendingPathComponent("ABC"))

    service.leave()

    XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
  }

  func testTerminatingOutsideASessionDoesNothing() {
    let service = makeService()
    center.post(name: UIApplication.willTerminateNotification, object: nil)
    XCTAssertEqual(service.state, .idle)
  }
}

/// Build 5: the sharer's End holds a background task until SharePlay is ended (A3), a listener's Leave
/// tells the others first, and our own cancelled or stale shares are ended, not left (A4).
@MainActor
final class ListenTogetherBuild5EndTests: XCTestCase {
  private var root: URL!
  private var system: FakeAppSystem!
  private var services: [SharePlaySessionService] = []

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("Build5EndTests-\(UUID())")
    system = FakeAppSystem()
  }

  override func tearDown() async throws {
    services.forEach { $0.end() }
    services = []
    try? FileManager.default.removeItem(at: root)
  }

  private func makeService() -> SharePlaySessionService {
    let playerManager = PlayerManagerProtocolMock()
    playerManager.isPlayingPublisherReturnValue = Just(false).eraseToAnyPublisher()
    playerManager.currentSpeedPublisherReturnValue = Just(Float(1)).eraseToAnyPublisher()
    playerManager.underlyingIsPlaying = false
    playerManager.underlyingCurrentSpeed = 1
    let service = SharePlaySessionService(
      playerManager: playerManager, storage: ShareStorage(root: root),
      announcer: ListenTogetherAnnouncer(post: { _ in }), appSystem: system, speaker: RecordingSpeaker(),
      notificationCenter: NotificationCenter())
    let control = RecordingCoordinatorControl()
    service.coordinatorControlFactory = { control }
    services.append(service)
    return service
  }

  private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
  }

  // MARK: A3

  func testSharerEndHoldsABackgroundTaskUntilTheGroupSessionIsEnded() async {
    let service = makeService(), transport = FakeTransport()
    service.startSharingSession(with: transport, item: PlayableItem.stub(currentTime: 0, duration: 10), shareID: UUID())
    XCTAssertEqual(system.begun.count, 0)

    service.end()

    XCTAssertEqual(system.begun.count, 1, "begun before the end message goes out")
    XCTAssertTrue(system.ended.isEmpty)
    await waitUntil { !self.system.ended.isEmpty }
    XCTAssertTrue(transport.ended)
    XCTAssertEqual(system.ended, system.begun, "ended once the group session is ended")
    XCTAssertEqual(transport.calls, ["stopPieceTransfers", "send:sessionEnding", "end"])
  }

  func testSharerEndExpiryEndsTheGroupSessionAtOnce() async {
    let service = makeService(), transport = FakeTransport()
    service.startSharingSession(with: transport, item: PlayableItem.stub(currentTime: 0, duration: 10), shareID: UUID())
    transport.holdSends = true

    service.end()
    system.expireAll()

    XCTAssertTrue(transport.ended, "the expiry handler ends SharePlay at once")
    XCTAssertEqual(system.ended, system.begun)
    transport.releaseSends()
    await waitUntil(timeout: 3) { transport.calls.contains("send:sessionEnding") }
    try? await Task.sleep(for: .milliseconds(700))
    XCTAssertEqual(transport.calls.filter { $0 == "end" }.count, 1, "never ended twice")
    XCTAssertEqual(system.ended.count, 1)
  }

  // MARK: Listener Leave

  func testListenerLeaveSendsTheLeavingMessageThenLeaves() async {
    let service = makeService(), transport = FakeTransport()
    service.startListening(with: transport, shareID: UUID())

    service.leave()

    XCTAssertFalse(service.isInSession, "the screen and state change at once")
    await waitUntil { transport.left }
    XCTAssertEqual(transport.calls, ["send:listenerLeaving", "leave"])
    XCTAssertFalse(transport.ended)
    XCTAssertEqual(system.begun.count, 1)
    XCTAssertEqual(system.ended, system.begun)
  }

  func testListenerLeaveStillLeavesWhenTheMessageNeverGoesOut() async {
    let service = makeService(), transport = FakeTransport()
    service.startListening(with: transport, shareID: UUID())
    transport.holdSends = true

    service.leave()

    await waitUntil(timeout: 3) { transport.left }
    XCTAssertTrue(transport.left, "left after the 1 s limit")
    transport.releaseSends()
  }

  func testListenerLeaveForOwnBookAlsoTellsTheOthers() async {
    let service = makeService(), transport = FakeTransport()
    service.startListening(with: transport, shareID: UUID())

    service.leaveForOwnBook(announcement: "You left")

    await waitUntil { transport.left }
    XCTAssertEqual(transport.calls, ["send:listenerLeaving", "leave"])
  }

  // MARK: A4

  func testCancelledOwnShareSessionIsEndedNotLeft() {
    let service = makeService()
    let shareID = try! XCTUnwrap(service.beginPreparing(PlayableItem.stub(currentTime: 0, duration: 10)))
    service.end()   // Cancel while preparing
    guard case .end = service.action(forIncoming: shareID) else {
      return XCTFail("our own cancelled share is ended for everyone")
    }
  }

  func testEndedShareIsOnlyLeft() {
    let service = makeService(), transport = FakeTransport(), shareID = UUID()
    service.startListening(with: transport, shareID: shareID)
    service.end()
    guard case .leave = service.action(forIncoming: shareID) else {
      return XCTFail("someone else's ended share is only left")
    }
  }
}

/// Build 5 (a11y guidance section 1): when a listener leaves while the book plays, the whole group
/// pauses through the sharer, with one sentence on every device.
@MainActor
final class ListenTogetherGroupPauseTests: XCTestCase {
  private var root: URL!
  private var posted: [String] = []
  private var speaker: RecordingSpeaker!
  private var system: FakeAppSystem!
  private var timers: ManualScheduler!
  private var playerManager: PlayerManagerProtocolMock!
  private var isPlaying: CurrentValueSubject<Bool, Never>!
  private var services: [SharePlaySessionService] = []
  private let me = UUID(), sharer = UUID(), a = UUID(), b = UUID()
  private let base = Date(timeIntervalSince1970: 2_000_000)

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("GroupPauseTests-\(UUID())")
    posted = []
    speaker = RecordingSpeaker()
    system = FakeAppSystem()
    timers = ManualScheduler()
  }

  override func tearDown() async throws {
    services.forEach { $0.end() }
    services = []
    try? FileManager.default.removeItem(at: root)
  }

  private func makeService(playing: Bool = true) -> SharePlaySessionService {
    playerManager = PlayerManagerProtocolMock()
    isPlaying = CurrentValueSubject(playing)
    playerManager.isPlayingPublisherReturnValue = isPlaying.eraseToAnyPublisher()
    playerManager.currentSpeedPublisherReturnValue = Just(Float(1)).eraseToAnyPublisher()
    playerManager.underlyingIsPlaying = playing
    playerManager.underlyingCurrentSpeed = 1
    let service = SharePlaySessionService(
      playerManager: playerManager, storage: ShareStorage(root: root),
      announcer: ListenTogetherAnnouncer(post: { [weak self] in self?.posted.append($0) }),
      appSystem: system, speaker: speaker, coverTracker: ListenTogetherCoverTracker(),
      focusRequests: ListenTogetherFocusRequests(), notificationCenter: NotificationCenter())
    service.schedule = timers.schedule
    service.scheduleSessionTimer = timers.schedule
    service.messages.schedule = timers.schedule
    service.messages.postNotification = { _, _ in false }
    service.now = { [unowned self] in
      let elapsed = self.timers.now.components
      return self.base.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
    let control = RecordingCoordinatorControl()
    service.coordinatorControlFactory = { control }
    services.append(service)
    return service
  }

  /// A sharer whose shared book is playing, with `listeners` in the roster (baseline set).
  private func makeSharer(
    playing: Bool = true, listeners: Set<UUID>? = nil
  ) async -> (SharePlaySessionService, FakeTransport) {
    let service = makeService(playing: playing), transport = FakeTransport()
    let item = PlayableItem.stub(currentTime: 100, duration: 1000)
    playerManager.currentItem = item
    service.startSharingSession(with: transport, item: item, shareID: UUID())
    transport.emit(.participantsChanged(count: 0, ids: Set([me]).union(listeners ?? [a, b])))
    await waitUntil { service.participantCount == 1 + (listeners ?? [a, b]).count }
    return (service, transport)
  }

  private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
  }

  /// Lets the event loop handle everything emitted so far.
  private func settle() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(50))
  }

  private let p1 = "Paused. Someone left Listen Together."
  private let p2 = "Paused. Someone lost their connection to Listen Together."
  private var left: String { ListenTogetherAnnouncements.left() }

  private func groupPausedMessages(_ transport: FakeTransport) -> [ListenTogetherPauseCause] {
    transport.sent.compactMap { if case .groupPaused(let cause) = $0 { return cause } else { return nil } }
  }

  // MARK: Wording

  func testExactSentences() {
    XCTAssertEqual(ListenTogetherPauseCause(count: 1, lostConnection: false).text, p1)
    XCTAssertEqual(ListenTogetherPauseCause(count: 1, lostConnection: true).text, p2)
    XCTAssertEqual(ListenTogetherPauseCause(count: 3, lostConnection: false).text, "Paused. 3 people left Listen Together.")
    XCTAssertEqual(
      ListenTogetherPauseCause(count: 2, lostConnection: true).text,
      "Paused. 2 people lost their connection to Listen Together.")
    XCTAssertEqual(ListenTogetherPauseCause(count: 2, lostConnection: false).rowValue(title: "Moby"), "paused, someone left, Moby")
    XCTAssertEqual(
      ListenTogetherPauseCause(count: 1, lostConnection: true).rowValue(title: "Moby"),
      "paused, someone lost their connection, Moby")
  }

  // MARK: Sharer

  func testALeaveMessageThenTheDropPausesWithSomeoneLeft() async {
    let (service, transport) = await makeSharer()
    posted = []
    transport.emit(.listenerLeaving(id: a))
    transport.emit(.participantsChanged(count: 0, ids: [me, b]))
    await waitUntil { service.pauseCause != nil }

    XCTAssertEqual(service.pauseCause, ListenTogetherPauseCause(count: 1, lostConnection: false))
    XCTAssertEqual(playerManager.pauseCallsCount, 1)
    XCTAssertEqual(posted, [p1], "the P-sentence replaces Someone left")
    XCTAssertEqual(speaker.spoken, [p1], "Speak says it once for the sharer")
    await waitUntil { !self.groupPausedMessages(transport).isEmpty }
    XCTAssertEqual(groupPausedMessages(transport), [ListenTogetherPauseCause(count: 1, lostConnection: false)])

    // The player's own pause event follows: never also sent as "Another listener paused".
    playerManager.underlyingIsPlaying = false
    isPlaying.send(false)
    await settle()
    XCTAssertFalse(transport.sent.contains(.action(.paused)))

    let line = ListenTogetherStatus.line(for: service.state, conditions: service.statusConditions)
    XCTAssertEqual(line?.text, p1)
    XCTAssertEqual(line?.detail, ListenTogetherStatus.visibleText(for: service.state))
    XCTAssertEqual(line?.icon, .paused)
    XCTAssertEqual(ListenTogetherStatus.sharerPauseCaption(for: service.state, conditions: service.statusConditions), p1)
  }

  func testADropWithoutALeaveMessageSaysLostConnection() async {
    let (service, transport) = await makeSharer()
    posted = []
    transport.emit(.participantsChanged(count: 0, ids: [me, b]))
    await waitUntil { service.pauseCause != nil }
    XCTAssertEqual(service.pauseCause, ListenTogetherPauseCause(count: 1, lostConnection: true))
    XCTAssertEqual(posted, [p2])
  }

  func testTwoDroppedAtOnceWithoutMessagesLostConnection() async {
    let (service, transport) = await makeSharer()
    posted = []
    transport.emit(.participantsChanged(count: 0, ids: [me]))
    await waitUntil { service.pauseCause != nil }
    XCTAssertEqual(service.pauseCause, ListenTogetherPauseCause(count: 2, lostConnection: true))
    XCTAssertEqual(posted, ["Paused. 2 people lost their connection to Listen Together."])
  }

  func testTwoDroppedAtOnceMixedSaysLeft() async {
    let (service, transport) = await makeSharer()
    transport.emit(.listenerLeaving(id: a))
    transport.emit(.participantsChanged(count: 0, ids: [me]))
    await waitUntil { service.pauseCause != nil }
    XCTAssertEqual(service.pauseCause, ListenTogetherPauseCause(count: 2, lostConnection: false))
  }

  func testAnOldLeaveMessageNoLongerCounts() async {
    let (service, transport) = await makeSharer()
    transport.emit(.listenerLeaving(id: a))
    await settle()
    timers.advance(by: .seconds(11))
    transport.emit(.participantsChanged(count: 0, ids: [me, b]))
    await waitUntil { service.pauseCause != nil }
    XCTAssertEqual(service.pauseCause?.lostConnection, true)
  }

  func testACountOnlyRosterUsesTheLeftWording() async {
    let service = makeService(), transport = FakeTransport()
    let item = PlayableItem.stub(currentTime: 100, duration: 1000)
    playerManager.currentItem = item
    service.startSharingSession(with: transport, item: item, shareID: UUID())
    transport.emit(.participantsChanged(count: 3))
    await waitUntil { service.participantCount == 3 }
    posted = []
    transport.emit(.participantsChanged(count: 2))
    await waitUntil { service.pauseCause != nil }
    XCTAssertEqual(service.pauseCause, ListenTogetherPauseCause(count: 1, lostConnection: false))
    XCTAssertEqual(posted, [p1])
  }

  func testAlreadyPausedGivesOnlySomeoneLeft() async {
    let (service, transport) = await makeSharer(playing: false)
    posted = []
    transport.emit(.participantsChanged(count: 0, ids: [me, b]))
    await waitUntil { !self.posted.isEmpty }
    XCTAssertEqual(posted, [left])
    XCTAssertNil(service.pauseCause)
    XCTAssertEqual(playerManager.pauseCallsCount, 0)
    XCTAssertTrue(groupPausedMessages(transport).isEmpty)
  }

  func testSomeoneWhoDeclinedNeverPausesTheGroup() async {
    let (service, transport) = await makeSharer()
    transport.emit(.participantDeclined(id: a))
    await waitUntil { service.participantCount == 2 }
    posted = []
    transport.emit(.participantsChanged(count: 0, ids: [me, b]))
    await settle()
    XCTAssertNil(service.pauseCause)
    XCTAssertEqual(playerManager.pauseCallsCount, 0)
    XCTAssertEqual(posted, [], "a decliner is never heard as Someone left")
  }

  func testAnotherDepartureInTheSamePauseGivesOnlySomeoneLeft() async {
    let (service, transport) = await makeSharer()
    transport.emit(.participantsChanged(count: 0, ids: [me, b]))
    await waitUntil { service.pauseCause != nil }
    posted = []
    transport.emit(.participantsChanged(count: 0, ids: [me]))
    await waitUntil { !self.posted.isEmpty }
    XCTAssertEqual(posted, [left])
    XCTAssertEqual(service.pauseCause, ListenTogetherPauseCause(count: 1, lostConnection: true), "the first sentence stays")
    XCTAssertEqual(playerManager.pauseCallsCount, 1)
  }

  func testPlayingClearsThePauseSilently() async {
    let (service, transport) = await makeSharer()
    transport.emit(.participantsChanged(count: 0, ids: [me, b]))
    await waitUntil { service.pauseCause != nil }
    playerManager.underlyingIsPlaying = false
    isPlaying.send(false)
    await settle()
    posted = []
    speaker.spoken = []

    playerManager.underlyingIsPlaying = true
    isPlaying.send(true)
    await waitUntil { service.pauseCause == nil }

    XCTAssertNil(service.pauseCause)
    XCTAssertEqual(posted, [])
    XCTAssertEqual(speaker.spoken, [])
    await waitUntil { transport.sent.contains(.action(.resumed)) }
    XCTAssertTrue(transport.sent.contains(.action(.resumed)), "resuming plays for everyone")
  }

  func testARemainingListenerResumingClearsThePause() async {
    let (service, transport) = await makeSharer()
    transport.emit(.participantsChanged(count: 0, ids: [me, b]))
    await waitUntil { service.pauseCause != nil }
    posted = []
    transport.emit(.message(.action(.resumed)))
    await waitUntil { service.pauseCause == nil }
    XCTAssertNil(service.pauseCause)
    XCTAssertEqual(posted, [ListenTogetherAnnouncements.text(for: .resumed)])
  }

  func testAJoinDoesNotClearThePause() async {
    let (service, transport) = await makeSharer()
    transport.emit(.participantsChanged(count: 0, ids: [me, b]))
    await waitUntil { service.pauseCause != nil }
    transport.emit(.participantsChanged(count: 0, ids: [me, b, a]))
    await waitUntil { service.participantCount == 3 }
    XCTAssertNotNil(service.pauseCause)
  }

  func testTheSessionEndingClearsThePause() async {
    let (service, transport) = await makeSharer()
    transport.emit(.participantsChanged(count: 0, ids: [me, b]))
    await waitUntil { service.pauseCause != nil }
    service.end()
    XCTAssertNil(service.pauseCause)
  }

  // MARK: Sharer away (1.5)

  func testAwayWithANotificationNothingIsAnnounced() async {
    let (service, transport) = await makeSharer()
    var notified: [String] = []
    service.messages.postNotification = { _, body in notified.append(body); return true }
    system.appState = .background
    posted = []
    transport.emit(.participantsChanged(count: 0, ids: [me, b]))
    await waitUntil { !notified.isEmpty }
    XCTAssertEqual(notified, [p2])
    XCTAssertEqual(posted, [], "no announcement from the background")
    XCTAssertEqual(speaker.spoken, [p2], "Speak still says it")
    system.become(.active)
    await settle()
    XCTAssertEqual(posted, [], "the notification was the one message")
  }

  func testAwayWithoutANotificationItIsAnnouncedOnTheReturn() async {
    let (service, transport) = await makeSharer()
    system.appState = .background
    posted = []
    transport.emit(.participantsChanged(count: 0, ids: [me, b]))
    await waitUntil { service.announcesPauseWhenActive }
    XCTAssertEqual(posted, [])
    system.become(.active)
    XCTAssertEqual(posted, [p2])
    system.become(.background)
    system.become(.active)
    XCTAssertEqual(posted, [p2], "said once")
  }

  func testAwayWithoutANotificationPlayFirstMeansNothingIsSaid() async {
    let (service, transport) = await makeSharer()
    system.appState = .background
    transport.emit(.participantsChanged(count: 0, ids: [me, b]))
    await waitUntil { service.announcesPauseWhenActive }
    playerManager.underlyingIsPlaying = false
    isPlaying.send(false)
    await settle()
    playerManager.underlyingIsPlaying = true
    isPlaying.send(true)
    await waitUntil { service.pauseCause == nil }
    posted = []
    system.become(.active)
    XCTAssertEqual(posted, [])
  }

  /// Review P2: `onClose` runs only after the notification attempt, after `onNotNotified` on a failure.
  func testAwayOnCloseRunsOnlyAfterTheNotificationAttempt() async {
    let service = makeService()
    system.appState = .background
    var release: CheckedContinuation<Bool, Never>?
    service.messages.postNotification = { _, _ in await withCheckedContinuation { release = $0 } }
    var events: [String] = []
    service.messages.deliver(
      .pausedBecauseSomeoneLeft(ListenTogetherPauseCause(count: 1, lostConnection: false), isSharer: true),
      onNotNotified: { events.append("notNotified") }, onClose: { events.append("close") })
    await waitUntil { release != nil }
    XCTAssertEqual(events, [], "nothing before the attempt finishes")
    release?.resume(returning: false)
    await waitUntil { events.count == 2 }
    XCTAssertEqual(events, ["notNotified", "close"])

    events = []
    release = nil
    service.messages.deliver(
      .pausedBecauseSomeoneLeft(ListenTogetherPauseCause(count: 1, lostConnection: false), isSharer: true),
      onNotNotified: { events.append("notNotified") }, onClose: { events.append("close") })
    await waitUntil { release != nil }
    XCTAssertEqual(events, [])
    release?.resume(returning: true)
    await waitUntil { !events.isEmpty }
    XCTAssertEqual(events, ["close"], "posted: no announcement later")
  }

  // MARK: Remaining listeners (1.7)

  private func makeListener() async -> (SharePlaySessionService, FakeTransport) {
    let service = makeService(playing: false), transport = FakeTransport()
    service.startListening(with: transport, shareID: UUID())
    transport.emit(.participantsChanged(count: 0, ids: [sharer, me, b]))
    transport.emit(.sharerParticipant(id: sharer))
    await waitUntil { service.participantCount == 3 }
    await settle()
    posted = []
    return (service, transport)
  }

  func testAListenerHearsOnlyThePauseSentence() async {
    let (service, transport) = await makeListener()
    transport.emit(.participantsChanged(count: 0, ids: [sharer, me]))
    await waitUntil { service.participantCount == 2 }
    transport.emit(.message(.groupPaused(ListenTogetherPauseCause(count: 1, lostConnection: false))))
    await waitUntil { service.pauseCause != nil }
    timers.advance(by: .seconds(3))

    XCTAssertEqual(posted, [p1], "no Someone left, no Another listener paused")
    XCTAssertEqual(speaker.spoken, [], "remaining listeners: Speak stays quiet")
    XCTAssertFalse(service.isPausedByOther)
    let line = ListenTogetherStatus.line(for: service.state, conditions: service.statusConditions)
    XCTAssertEqual(line?.text, p1)
    XCTAssertNil(ListenTogetherStatus.sharerPauseCaption(for: service.state, conditions: service.statusConditions))
  }

  func testAListenerGetsThePauseMessageBeforeTheRosterDrop() async {
    let (service, transport) = await makeListener()
    transport.emit(.message(.groupPaused(ListenTogetherPauseCause(count: 1, lostConnection: true))))
    await waitUntil { service.pauseCause != nil }
    transport.emit(.participantsChanged(count: 0, ids: [sharer, me]))
    await waitUntil { service.participantCount == 2 }
    timers.advance(by: .seconds(3))
    XCTAssertEqual(posted, [p2])
  }

  func testAListenerSaysSomeoneLeftWhenNoPauseFollows() async {
    let (service, transport) = await makeListener()
    transport.emit(.participantsChanged(count: 0, ids: [sharer, me]))
    await waitUntil { service.participantCount == 2 }
    timers.advance(by: .milliseconds(1900))
    XCTAssertEqual(posted, [], "held for the sharer's pause")
    timers.advance(by: .milliseconds(200))
    XCTAssertEqual(posted, [left])
  }

  func testTheSharerLeavingIsNeverSomeoneLeftOnAListener() async {
    let (_, transport) = await makeListener()
    transport.emit(.participantsChanged(count: 0, ids: [me, b]))
    await waitUntil { !self.posted.isEmpty }
    timers.advance(by: .seconds(3))
    XCTAssertFalse(posted.contains(left))
    XCTAssertFalse(posted.contains(p1))
    XCTAssertTrue(posted.contains("listen_together_waiting_for_sharer".localized))
  }

  func testAListenerPlayingClearsThePause() async {
    let (service, transport) = await makeListener()
    transport.emit(.message(.groupPaused(ListenTogetherPauseCause(count: 1, lostConnection: false))))
    await waitUntil { service.pauseCause != nil }
    transport.emit(.message(.action(.resumed)))
    await waitUntil { service.pauseCause == nil }
    XCTAssertNil(service.pauseCause)
  }

  // MARK: Delivery plan

  func testDeliveryPlan() {
    let cause = ListenTogetherPauseCause(count: 1, lostConnection: false)
    let active = ListenTogetherDeliveryContext()
    let away = ListenTogetherDeliveryContext(appState: .background, isLocked: true)
    var sharer = ListenTogetherDeliveryPlan()
    sharer.announces = true
    sharer.speaksNow = true
    XCTAssertEqual(ListenTogetherMessageDelivery.plan(for: .pausedBecauseSomeoneLeft(cause, isSharer: true), context: active), sharer)
    var sharerAway = ListenTogetherDeliveryPlan()
    sharerAway.speaksNow = true
    sharerAway.notifiesWhenAway = true
    XCTAssertEqual(ListenTogetherMessageDelivery.plan(for: .pausedBecauseSomeoneLeft(cause, isSharer: true), context: away), sharerAway)
    var listener = ListenTogetherDeliveryPlan()
    listener.announces = true
    XCTAssertEqual(ListenTogetherMessageDelivery.plan(for: .pausedBecauseSomeoneLeft(cause, isSharer: false), context: active), listener)
    XCTAssertEqual(ListenTogetherMessageDelivery.plan(for: .pausedBecauseSomeoneLeft(cause, isSharer: false), context: away), listener)
    XCTAssertEqual(ListenTogetherUserMessage.pausedBecauseSomeoneLeft(cause, isSharer: true).kind, .status)
  }

  // MARK: Status priorities and the row

  func testStatusPriorities() {
    let cause = ListenTogetherPauseCause(count: 1, lostConnection: true)
    let sharing = ListenTogetherState.sharing(participants: 2)
    var conditions = ListenTogetherStatusConditions(notice: .retryingSend, pauseCause: cause)
    XCTAssertEqual(ListenTogetherStatus.line(for: sharing, conditions: conditions)?.text, p2, "over retrying")
    conditions.someoneDeclined = true
    XCTAssertEqual(ListenTogetherStatus.line(for: sharing, conditions: conditions)?.detail, "listen_together_declined_no_copy".localized)

    let listening = ListenTogetherState.listening(participants: 2, downloaded: 1)
    var listener = ListenTogetherStatusConditions(isSharerGraceRunning: true, isWaitingForPiece: true, pauseCause: cause)
    XCTAssertEqual(ListenTogetherStatus.line(for: listening, conditions: listener)?.text, "listen_together_waiting_for_sharer".localized)
    listener.isSharerGraceRunning = false
    XCTAssertEqual(ListenTogetherStatus.line(for: listening, conditions: listener)?.text, p2, "over waiting for the book")
    XCTAssertNil(ListenTogetherStatus.waitingCaption(ListenTogetherStatusConditions(pauseCause: cause)), "a listener's Play works")
  }

  func testRowValues() {
    let cause = ListenTogetherPauseCause(count: 1, lostConnection: false)
    XCTAssertEqual(
      ListenTogetherRow.value(
        state: .sharing(participants: 2), joinedTitle: nil, listener: nil, sharerTitle: "Moby",
        isRetryingSend: true, pauseCause: cause),
      "paused, someone left, Moby")
    XCTAssertEqual(
      ListenTogetherRow.value(state: .sharing(participants: 1), joinedTitle: nil, listener: nil, sharerTitle: "Moby"),
      "sharing, waiting for people to join, Moby")
    let snapshot = ListenTogetherRow.ListenerSnapshot(title: "Moby", isPlaying: false, isWaiting: false)
    XCTAssertEqual(
      ListenTogetherRow.value(
        state: .listening(participants: 2, downloaded: 1), joinedTitle: nil, listener: snapshot, sharerTitle: nil,
        pauseCause: ListenTogetherPauseCause(count: 2, lostConnection: true)),
      "paused, someone lost their connection, Moby")
    XCTAssertEqual(
      ListenTogetherRow.value(
        state: .listening(participants: 2, downloaded: 1), joinedTitle: nil, listener: snapshot, sharerTitle: nil,
        sharerPresence: .away, pauseCause: cause),
      String.localizedStringWithFormat("listen_together_row_value_waiting_sharer".localized, "Moby"))
  }

  func testConfirmationAndAloneStrings() {
    XCTAssertEqual(
      "listen_together_end_confirm_message".localized,
      "It ends for everyone. SharePlay stays on until you close it in Control Center.")
    XCTAssertTrue(ListenTogetherSessionAction.leaveConfirmationMessage(usesOwnCopy: false)
      .hasSuffix("The book is deleted from this iPhone. SharePlay stays on until you close it in Control Center."))
    XCTAssertTrue(ListenTogetherSessionAction.leaveConfirmationMessage(usesOwnCopy: true)
      .hasSuffix("Your copy stays in your library. SharePlay stays on until you close it in Control Center."))
    XCTAssertEqual(
      ListenTogetherStatus.visibleText(for: .sharing(participants: 1)),
      "Listen Together, sharing, waiting for people to join")
  }
}
