@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import XCTest

/// Records what would be spoken (no AVSpeechSynthesizer).
@MainActor
final class RecordingSpeaker: ListenTogetherSpeaking {
  var spoken: [String] = []
  func speak(_ text: String, key: String) { spoken.append(text) }
}

/// Addendum 3, Task B: one delivery path for every message (guidance A.0 to A.4, C).
@MainActor
final class ListenTogetherMessagesTests: XCTestCase {
  private typealias Message = ListenTogetherUserMessage
  private var root: URL!
  private var posted: [String] = []
  private var speaker: RecordingSpeaker!
  private var tracker: ListenTogetherCoverTracker!
  private var system: FakeAppSystem!
  private var timers: ManualScheduler!
  private var services: [SharePlaySessionService] = []
  private var control: RecordingCoordinatorControl!
  private let base = Date(timeIntervalSince1970: 1_000_000)

  private static let allMessages: [Message] = [
    .sharerEnded, .sharerLeft, .sharerCouldNotPrepare, .prepareFailed, .everyoneLeft, .unavailable, .didntStart,
    .waitingForSharer, .sharerBack, .retryingSend, .waitingForBook, .stoppedHere(.interrupted), .stoppedHere(.needsPlay),
    .sharerInterruption(.interrupted), .sharerInterruption(.needsPlay), .ownInterruption(.interrupted),
    .ownInterruption(.needsPlay),
    .alertShownElsewhere(text: "Couldn't open sharing", key: "needsFaceTime"),
  ]

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("Messages-\(UUID())")
    posted = []
    speaker = RecordingSpeaker()
    tracker = ListenTogetherCoverTracker()
    system = FakeAppSystem()
    timers = ManualScheduler()
    control = RecordingCoordinatorControl()
  }

  override func tearDown() async throws {
    services.forEach { $0.end() }
    services = []
    try? FileManager.default.removeItem(at: root)
  }

  private var locked = true
  private var voiceOver = false

  private func makeDelivery(active: Bool = true, focus: ListenTogetherFocusRequests? = nil) -> ListenTogetherMessageDelivery {
    let focus = focus ?? ListenTogetherFocusRequests()
    system.appState = active ? .active : .background
    let system = self.system!
    let delivery = ListenTogetherMessageDelivery(
      announcer: ListenTogetherAnnouncer(post: { [weak self] in self?.posted.append($0) }),
      speaker: speaker, coverTracker: tracker, focusRequests: focus,
      context: { [unowned self] in
        ListenTogetherDeliveryContext(
          appState: system.appState, isLocked: self.locked, isVoiceOverRunning: self.voiceOver)
      })
    delivery.schedule = timers.schedule
    delivery.now = clock
    return delivery
  }

  private func clock() -> Date {
    let elapsed = timers.now.components
    return base.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
  }

  private static let active = ListenTogetherDeliveryContext()
  private static let lockedAway = ListenTogetherDeliveryContext(appState: .background, isLocked: true)

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
      appSystem: system, speaker: speaker, coverTracker: tracker, focusRequests: ListenTogetherFocusRequests())
    service.retrySleep = { _ in await Task.yield() }
    service.scheduleSessionTimer = timers.schedule
    service.schedule = timers.schedule
    service.messages.schedule = timers.schedule
    service.messages.postNotification = { _, _ in false }
    service.now = { [unowned self] in self.clock() }
    service.messages.now = { [unowned self] in self.clock() }
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

  private func manifest(_ id: UUID) -> SharedBookManifest {
    SharedBookManifest(
      shareID: id, title: "T", author: "A", duration: 20,
      chapters: [SharedChapter(title: "One", start: 0, duration: 20)],
      pieces: (0..<2).map { SharedPiece(index: $0, bookStart: Double($0) * 10, duration: 10, byteSize: 1) })
  }

  private func startListeningWithManifest() async -> (SharePlaySessionService, FakeTransport, UUID) {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    service.startListening(with: transport, shareID: id)
    transport.emit(.message(.manifest(manifest(id))))
    await waitUntil { service.listener != nil }
    return (service, transport, id)
  }

  // MARK: The plan (A.2)

  func testNoMessageEverGetsBothAnAlertAndAnAnnouncement() {
    for message in Self.allMessages {
      for active in [Self.active, Self.lockedAway, .init(appState: .background), .init(appState: .inactive)] {
        let plan = ListenTogetherMessageDelivery.plan(for: message, context: active)
        let alertLike = plan.showsAlert || plan.notifiesOrWaits
        XCTAssertFalse(alertLike && plan.announces, "\(message) active=\(active)")
        XCTAssertFalse(plan.speaksNow && plan.speaksWithAlert, "\(message) spoken once")
      }
    }
  }

  func testAlertMessagesWhenActive() {
    for message in [
      Message.sharerEnded, .sharerLeft, .sharerCouldNotPrepare, .connectionEnded, .connectionEndedSharer,
      .prepareFailed, .everyoneLeft, .unavailable, .didntStart,
    ] {
      XCTAssertEqual(
        ListenTogetherMessageDelivery.plan(for: message, context: Self.active),
        ListenTogetherDeliveryPlan(showsAlert: true, speaksWithAlert: true), "\(message)")
      XCTAssertEqual(
        ListenTogetherMessageDelivery.plan(for: message, context: Self.lockedAway),
        ListenTogetherDeliveryPlan(speaksNow: true, notifiesOrWaits: true), "\(message)")
    }
  }

  func testStatusMessagesAnnounceOnceAndOnlyErrorsAreSpoken() {
    XCTAssertEqual(
      ListenTogetherMessageDelivery.plan(for: .waitingForSharer, context: Self.active),
      ListenTogetherDeliveryPlan(announces: true, speaksNow: true))
    XCTAssertEqual(
      ListenTogetherMessageDelivery.plan(for: .retryingSend, context: Self.lockedAway),
      ListenTogetherDeliveryPlan(announces: true, speaksNow: true))
    XCTAssertEqual(
      ListenTogetherMessageDelivery.plan(for: .waitingForBook, context: Self.active),
      ListenTogetherDeliveryPlan(announces: true), "normal buffering is never spoken")
    XCTAssertEqual(
      ListenTogetherMessageDelivery.plan(for: .sharerBack, context: Self.active),
      ListenTogetherDeliveryPlan(announces: true), "VoiceOver only")
    XCTAssertEqual(
      ListenTogetherMessageDelivery.plan(for: .alertShownElsewhere(text: "x", key: "k"), context: Self.active),
      ListenTogetherDeliveryPlan(speaksNow: true))
  }

  func testExactEnglishText() {
    XCTAssertEqual(Message.sharerEnded.text, "The person sharing ended Listen Together.")
    XCTAssertEqual(Message.sharerLeft.text, "The person sharing left. Listen Together ended.")
    XCTAssertEqual(Message.prepareFailed.text, "Couldn't prepare the book for sharing. Listen Together ended.")
    XCTAssertEqual(Message.waitingForSharer.text, "Waiting for the person sharing")
    XCTAssertEqual(Message.sharerBack.text, "The person sharing is back.")
    XCTAssertEqual(Message.retryingSend.text, "Couldn't send part of the book. Trying again.")
    XCTAssertEqual(Message.waitingForBook.text, "Waiting for the book")
    XCTAssertEqual(Message.unavailable.text, "listen_together_unavailable".localized)
  }

  // MARK: Delivery

  func testActiveAlertIsQueuedWithoutAnnouncementAndSpokenWhenShown() {
    let delivery = makeDelivery()
    var closed = 0
    delivery.deliver(.sharerEnded) { closed += 1 }
    XCTAssertEqual(posted, [], "an alert never also posts an announcement")
    XCTAssertEqual(speaker.spoken, [], "spoken when it is on screen")
    let item = try! XCTUnwrap(delivery.alerts.next)
    XCTAssertEqual(item.message, .sharerEnded)
    delivery.alertPresented(item.id)
    XCTAssertEqual(speaker.spoken, ["The person sharing ended Listen Together."])
    XCTAssertNil(delivery.alerts.next)
    delivery.alertClosed(item.id)
    XCTAssertEqual(closed, 1)
    XCTAssertNil(delivery.alerts.onScreen)
  }

  func testStatusMessageIsAnnouncedAndSpokenWithoutAlert() {
    let delivery = makeDelivery()
    delivery.deliver(.retryingSend)
    XCTAssertEqual(posted, ["Couldn't send part of the book. Trying again."])
    XCTAssertEqual(speaker.spoken, ["Couldn't send part of the book. Trying again."])
    XCTAssertNil(delivery.alerts.next)
  }

  func testNotActiveWithNotificationPermissionPostsOneNotificationAndNoAlert() async {
    let delivery = makeDelivery(active: false)
    var notifications: [String] = []
    delivery.postNotification = { title, body in
      notifications.append(title + "|" + body)
      return true
    }
    var closed = 0
    delivery.deliver(.sharerLeft) { closed += 1 }
    await waitUntil { closed == 1 }
    XCTAssertEqual(notifications, ["listen_together_title".localized + "|The person sharing left. Listen Together ended."])
    XCTAssertNil(delivery.alerts.next, "the notification is the one message")
    XCTAssertEqual(posted, [], "no announcement from the background")
    XCTAssertEqual(speaker.spoken, ["The person sharing left. Listen Together ended."], "spoken at once")
  }

  func testNotActiveWithoutPermissionKeepsAPendingAlertThatIsNotSpokenAgain() async {
    let delivery = makeDelivery(active: false)
    delivery.postNotification = { _, _ in false }
    delivery.deliver(.sharerEnded)
    await waitUntil { delivery.alerts.next != nil }
    let item = try! XCTUnwrap(delivery.alerts.next)
    XCTAssertTrue(item.isSpoken)
    XCTAssertEqual(speaker.spoken.count, 1)
    delivery.alertPresented(item.id)
    XCTAssertEqual(speaker.spoken.count, 1, "already spoken when it arrived")
  }

  func testAPendingAlertIsDroppedByANewSession() {
    let delivery = makeDelivery()
    var closed = 0
    delivery.deliver(.didntStart) { closed += 1 }
    delivery.dropPendingAlerts()
    XCTAssertNil(delivery.alerts.next)
    XCTAssertEqual(closed, 1)
  }

  // MARK: The queue (A.4)

  func testTwoEndingsBackToBackShowOneAlertTheLatest() {
    let delivery = makeDelivery()
    var closed: [String] = []
    delivery.deliver(.sharerEnded) { closed.append("ended") }
    delivery.deliver(.sharerLeft) { closed.append("left") }
    XCTAssertEqual(delivery.alerts.pending.map(\.message), [.sharerLeft])
    XCTAssertEqual(closed, ["ended"], "the replaced ending is closed unshown")
  }

  func testAnEndingReplacesAPendingNonEnding() {
    var queue = ListenTogetherAlertQueue()
    queue.enqueue(.init(id: UUID(), message: .didntStart, isSpoken: false))
    queue.enqueue(.init(id: UUID(), message: .sharerEnded, isSpoken: false))
    XCTAssertEqual(queue.pending.map(\.message), [.sharerEnded])
  }

  func testTheAlertOnScreenIsNeverReplacedAndTheNextWaits() {
    var queue = ListenTogetherAlertQueue()
    let first = ListenTogetherAlertQueue.Item(id: UUID(), message: .unavailable, isSpoken: false)
    queue.enqueue(first)
    XCTAssertTrue(queue.markPresented(first.id))
    let ending = ListenTogetherAlertQueue.Item(id: UUID(), message: .sharerEnded, isSpoken: false)
    queue.enqueue(ending)
    XCTAssertEqual(queue.onScreen, first)
    XCTAssertNil(queue.next, "one at a time")
    XCTAssertEqual(queue.markClosed(first.id), first)
    XCTAssertEqual(queue.next, ending)
  }

  func testTheSameMessageIsNotQueuedTwice() {
    var queue = ListenTogetherAlertQueue()
    queue.enqueue(.init(id: UUID(), message: .unavailable, isSpoken: false))
    queue.enqueue(.init(id: UUID(), message: .unavailable, isSpoken: false))
    XCTAssertEqual(queue.pending.count, 1)
  }

  func testAlertStep() {
    typealias C = MainCoordinator
    XCTAssertEqual(
      C.listenTogetherAlertStep(isActive: false, waitsForCover: false, isCoverOnScreen: false, isOtherAlertOnScreen: false),
      .waitForActive)
    XCTAssertEqual(
      C.listenTogetherAlertStep(isActive: true, waitsForCover: true, isCoverOnScreen: true, isOtherAlertOnScreen: false),
      .waitForCover, "a listener's ending waits for the cover to leave")
    XCTAssertEqual(
      C.listenTogetherAlertStep(isActive: true, waitsForCover: false, isCoverOnScreen: true, isOtherAlertOnScreen: false),
      .present)
    XCTAssertEqual(
      C.listenTogetherAlertStep(isActive: true, waitsForCover: true, isCoverOnScreen: false, isOtherAlertOnScreen: true),
      .retry, "never stacked on another Listen Together alert")
    XCTAssertEqual(
      C.listenTogetherAlertStep(isActive: true, waitsForCover: true, isCoverOnScreen: false, isOtherAlertOnScreen: false),
      .present)
    XCTAssertTrue(Message.sharerEnded.waitsForListenerCover)
    XCTAssertFalse(Message.prepareFailed.waitsForListenerCover, "the sharer has no listener cover")
  }

  func testAfterListenerCoverGoneWaitsForTheCoverThenFocusesThenAnnounces() {
    let focus = ListenTogetherFocusRequests()
    var focused = 0
    let bag = focus.miniPlayer.sink { focused += 1 }
    let delivery = makeDelivery(focus: focus)
    tracker.coverAppeared()
    delivery.afterListenerCoverGone(announce: "You left Listen Together.")
    timers.advance(by: .seconds(1))
    XCTAssertEqual(focused, 0)
    XCTAssertEqual(posted, [], "nothing while the cover is still up")
    tracker.coverDismissed()
    timers.advance(by: .milliseconds(499))
    XCTAssertEqual(focused, 0)
    timers.advance(by: .milliseconds(1))
    XCTAssertEqual(focused, 1, "focus moves first")
    XCTAssertEqual(posted, [])
    timers.advance(by: .milliseconds(499))
    XCTAssertEqual(posted, [], "500 ms after the focus move (a11y M4)")
    timers.advance(by: .milliseconds(1))
    XCTAssertEqual(posted, ["You left Listen Together."], "then the sentence, once")
    timers.advance(by: .seconds(5))
    XCTAssertEqual(focused, 1, "the cover watchdog doesn't run it again")
    XCTAssertEqual(posted.count, 1)
    withExtendedLifetime(bag) {}
  }

  // MARK: The session (A.0 order, C)

  func testSharerEndTearsDownFirstThenQueuesOneAlert() async throws {
    let (service, transport, id) = await startListeningWithManifest()
    let folder = root.appendingPathComponent("listener").appendingPathComponent(id.uuidString)
    var seenAtDelivery: (inSession: Bool, listener: Bool, title: String?, folder: Bool)?
    let bag = service.messages.$alerts.dropFirst().sink { _ in
      seenAtDelivery = (
        service.isInSession, service.listener != nil, service.joinedTitle,
        FileManager.default.fileExists(atPath: folder.path))
    }
    posted = []
    transport.emit(.message(.sessionEnding))
    await waitUntil { service.messages.alerts.next != nil }

    let seen = try XCTUnwrap(seenAtDelivery)
    XCTAssertFalse(seen.inSession, "the row is gone before the alert")
    XCTAssertFalse(seen.listener, "the player is gone before the alert")
    XCTAssertNil(seen.title)
    XCTAssertFalse(seen.folder, "the temporary copy is deleted before the alert")
    XCTAssertEqual(service.messages.alerts.next?.message, .sharerEnded)
    XCTAssertEqual(posted, [], "no 'Listen Together ended' announcement")
    XCTAssertNil(ListenTogetherStatus.visibleText(for: service.state), "no ended banner")
    XCTAssertEqual(service.endNotice, .sharerEnded)

    let item = try XCTUnwrap(service.messages.alerts.next)
    service.messages.alertPresented(item.id)
    service.messages.alertClosed(item.id)
    XCTAssertNil(service.endNotice, "acknowledged by OK")
    withExtendedLifetime(bag) {}
  }

  func testSharerGoneForAMinuteEndsWithTheLeftMessage() async throws {
    let (service, transport, _) = await startListeningWithManifest()
    service.bridge?.handleSeek(itemTime: 0)   // the group's place is known (start-position fix)
    let me = UUID(), sharer = UUID()
    transport.emit(.sharerParticipant(id: sharer))
    transport.emit(.participantsChanged(count: 2, ids: [me, sharer]))
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    await waitUntil { service.isSharerGraceRunning }
    posted = []
    timers.advance(by: .seconds(65))
    XCTAssertEqual(service.messages.alerts.next?.message, .sharerLeft)
    XCTAssertEqual(posted, [])
    XCTAssertFalse(service.isSharerGraceRunning)
  }

  func testOwnEndKeepsTheShortAnnouncementAndNoAlert() async {
    let (service, _, _) = await startListeningWithManifest()
    posted = []
    service.end()
    XCTAssertEqual(posted, [ListenTogetherAnnouncements.ended()])
    XCTAssertNil(service.messages.alerts.next)
    XCTAssertEqual(ListenTogetherStatus.visibleText(for: service.state), "listen_together_ended".localized)
  }

  func testLeaveSaysYouLeftOnceAfterTheCover() async {
    let (service, transport, id) = await startListeningWithManifest()
    tracker.coverAppeared()
    posted = []
    service.leave()
    XCTAssertFalse(service.isInSession)
    // Build 5: the leaving message goes out first, then the session is left.
    await waitUntil { transport.left }
    XCTAssertTrue(transport.left)
    XCTAssertEqual(posted, [], "nothing while the cover is still up")
    XCTAssertNil(service.messages.alerts.next, "the person's own action: no alert")
    XCTAssertEqual(service.decision(forIncoming: id), .endedShare, "never rejoined")
    tracker.coverDismissed()
    timers.advance(by: .seconds(1))
    XCTAssertEqual(posted, ["listen_together_left_for_own_book".localized])
  }

  func testWaitingForTheSharerIsSaidOnceAndBackOnce() async {
    let (service, transport, _) = await startListeningWithManifest()
    let me = UUID(), sharer = UUID()
    transport.emit(.sharerParticipant(id: sharer))
    transport.emit(.participantsChanged(count: 2, ids: [me, sharer]))
    posted = []
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    await waitUntil { service.notice == .waitingForSharer }
    timers.advance(by: .seconds(20))
    // "Someone left" / "Someone joined" (E8) are unchanged and not part of this.
    let sharerLines = { self.posted.filter { $0.contains("person sharing") } }
    XCTAssertEqual(sharerLines(), ["Waiting for the person sharing"])
    XCTAssertEqual(speaker.spoken, ["Waiting for the person sharing"])
    XCTAssertTrue(service.isSharerGraceRunning)
    transport.emit(.participantsChanged(count: 2, ids: [me, sharer]))
    await waitUntil { service.notice == nil }
    XCTAssertEqual(sharerLines(), ["Waiting for the person sharing", "The person sharing is back."])
    XCTAssertEqual(speaker.spoken, ["Waiting for the person sharing"], "the return is never spoken")
  }

  func testPlayWhileTheSharerIsMissingDoesNothingAndSaysWhy() async throws {
    let (service, transport, _) = await startListeningWithManifest()
    let listener = try XCTUnwrap(service.listener)
    let me = UUID(), sharer = UUID()
    transport.emit(.sharerParticipant(id: sharer))
    transport.emit(.participantsChanged(count: 2, ids: [me, sharer]))
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    await waitUntil { listener.isHeldForSharer }
    var events: [LocalPlaybackEvent] = []
    let bag = listener.localEvents.sink { events.append($0) }
    posted = []
    listener.userTogglePlay()
    listener.userTogglePlay()
    XCTAssertEqual(events, [], "nothing is sent")
    XCTAssertFalse(listener.isPlaying)
    XCTAssertEqual(posted, ["Waiting for the person sharing"], "said at most every 2 s")
    XCTAssertEqual(ListenTogetherRemoteCommands.isPlayCommand(.play), true)
    XCTAssertEqual(ListenTogetherRemoteCommands.isPlayCommand(.skipForward), false)
    withExtendedLifetime(bag) {}
  }

  func testRetryingIsSaidOncePerEpisode() async throws {
    let service = makeService(), transport = FakeTransport()
    service.startSharingSession(with: transport, item: PlayableItem.stub(currentTime: 0, duration: 10), shareID: UUID())
    posted = []
    service.setNotice(.retryingSend)
    service.setNotice(.retryingSend)
    XCTAssertEqual(posted, ["Couldn't send part of the book. Trying again."])
    XCTAssertEqual(speaker.spoken, ["Couldn't send part of the book. Trying again."])
    service.setNotice(nil)
    XCTAssertEqual(posted.count, 1, "nothing on recovery")
  }

  func testUnavailableIsAnAlertNotAnAnnouncement() {
    let service = makeService()
    service.endUnavailable()
    XCTAssertEqual(posted, [])
    XCTAssertEqual(service.messages.alerts.next?.message, .unavailable)
    XCTAssertNil(ListenTogetherStatus.visibleText(for: service.state), "no timed banner")
  }

  func testANewInvitationDropsAPendingEndingAlert() async {
    let (service, transport, _) = await startListeningWithManifest()
    transport.emit(.message(.sessionEnding))
    await waitUntil { service.messages.alerts.next != nil }
    service.showInvitation(title: "Other", author: "")
    XCTAssertNil(service.messages.alerts.next)
  }

  func testPausedByAnotherListenerUntilTheNextPlay() async throws {
    let (service, transport, _) = await startListeningWithManifest()
    transport.emit(.message(.action(.paused)))
    await waitUntil { service.isPausedByOther }
    XCTAssertTrue(service.isPausedByOther)
    transport.emit(.message(.action(.resumed)))
    await waitUntil { !service.isPausedByOther }
    XCTAssertFalse(service.isPausedByOther)
    transport.emit(.message(.action(.paused)))
    await waitUntil { service.isPausedByOther }
    service.bridge?.handleSeek(itemTime: 0)   // the group's place is known (start-position fix C, round 1 I2)
    try XCTUnwrap(service.listener).userTogglePlay()
    XCTAssertFalse(service.isPausedByOther, "the person's own play clears it")
  }

  // MARK: Status lines (A.1, C)

  func testEndingsByOthersHaveNoBannerText() {
    for reason in [ListenTogetherState.EndReason.sharerEnded, .sharerLeft, .sharerCouldNotPrepare, .prepareFailed, .unavailable] {
      XCTAssertNil(ListenTogetherStatus.visibleText(for: .ended(reason: reason)), "\(reason)")
    }
  }

  func testSharerWaitOnlyDuringTheGraceAndQuietOtherwise() {
    let state = ListenTogetherState.listening(participants: 2, downloaded: 1)
    var conditions = ListenTogetherStatusConditions(notice: .waitingForSharer, isListenerPlaying: true)
    var line = try! XCTUnwrap(ListenTogetherStatus.line(for: state, conditions: conditions))
    XCTAssertEqual(line.text, "Can't reach the person sharing. The book keeps playing.", "silence only (a11y I4)")
    XCTAssertNil(line.detail)
    XCTAssertNil(ListenTogetherStatus.waitingCaption(conditions), "Play still works: no caption")
    conditions.isWaitingForPiece = true
    line = try! XCTUnwrap(ListenTogetherStatus.line(for: state, conditions: conditions))
    XCTAssertEqual(line.text, "Waiting for the book", "a piece wait wins over the quiet line")
    conditions.isSharerGraceRunning = true
    line = try! XCTUnwrap(ListenTogetherStatus.line(for: state, conditions: conditions))
    XCTAssertEqual(line.text, "Waiting for the person sharing")
    XCTAssertEqual(line.icon, .hourglass)
    XCTAssertEqual(line.detail, "If they are not back within a minute, Listen Together ends.")
    XCTAssertEqual(line.spoken, "Waiting for the person sharing. If they are not back within a minute, Listen Together ends.")
    XCTAssertEqual(ListenTogetherStatus.waitingCaption(conditions), "Waiting for the person sharing")
  }

  /// Option 1 (I4, R41): a listener stopped on this phone sees why, near the controls, until it
  /// changes; VoiceOver hears it once; nothing is spoken by the setting (it isn't an error).
  func testStoppedHereIsAPersistentStatusAnnouncedOnce() {
    let interrupted = Message.stoppedHere(.interrupted), needsPlay = Message.stoppedHere(.needsPlay)
    XCTAssertEqual(interrupted.text, "Listen Together will continue when the interruption ends.")
    XCTAssertEqual(needsPlay.text, "Stopped on this iPhone. Press Play to rejoin the others.")
    for message in [interrupted, needsPlay] {
      XCTAssertEqual(message.kind, .status)
      XCTAssertFalse(message.speaks)
      XCTAssertFalse(message.isEnding)
      XCTAssertTrue(ListenTogetherMessageDelivery.plan(for: message, context: Self.active).announces)
    }
    XCTAssertNotEqual(interrupted.key, needsPlay.key)
    let state = ListenTogetherState.listening(participants: 3, downloaded: 1)
    let conditions = ListenTogetherStatusConditions(pauseCause: nil, localStop: .interrupted)
    let line = try! XCTUnwrap(ListenTogetherStatus.line(for: state, conditions: conditions))
    XCTAssertEqual(line.text, interrupted.text)
    XCTAssertEqual(line.detail, ListenTogetherStatus.visibleText(for: state))
    XCTAssertEqual(ListenTogetherStatus.listenerCaption(conditions), interrupted.text, "under the controls (Zoom)")
    XCTAssertEqual(ListenTogetherStatus.listenerPlayValue(conditions), interrupted.text, "the Play button's value")
    XCTAssertNil(ListenTogetherStatus.waitingCaption(conditions), "Play is not held: it rejoins")
  }

  /// Fix round 3 (a11y I1): away, "Press Play" is one notification (else said on the return) and
  /// "will continue" is never said from the background.
  func testStoppedHereAwayFollowsTheAwayRules() {
    let away = ListenTogetherDeliveryContext(appState: .background, isLocked: true, isVoiceOverRunning: true)
    let interrupted = ListenTogetherMessageDelivery.plan(for: .stoppedHere(.interrupted), context: away)
    XCTAssertFalse(interrupted.announces)
    XCTAssertFalse(interrupted.notifiesWhenAway)
    XCTAssertFalse(interrupted.speaksNow)
    let needsPlay = ListenTogetherMessageDelivery.plan(for: .stoppedHere(.needsPlay), context: away)
    XCTAssertFalse(needsPlay.announces, "no announcement from the background")
    XCTAssertTrue(needsPlay.notifiesWhenAway)
    XCTAssertTrue(ListenTogetherMessageDelivery.plan(for: .stoppedHere(.needsPlay), context: Self.active).announces)
  }

  /// Fix round 3 (a11y I2, M4): the row says why with the player closed.
  func testTheRowSaysStoppedHereAndTheListenersWait() {
    let snapshot = ListenTogetherRow.ListenerSnapshot(title: "Moby", isPlaying: false, isWaiting: false)
    let listening = ListenTogetherState.listening(participants: 3, downloaded: 1)
    func row(_ stop: ListenTogetherLocalStop?) -> String? {
      ListenTogetherRow.value(
        state: listening, joinedTitle: nil, listener: snapshot, sharerTitle: nil,
        pauseCause: ListenTogetherPauseCause(count: 1, lostConnection: false, departedIDs: []), localStop: stop)
    }
    XCTAssertEqual(row(.needsPlay), "stopped on this iPhone, press Play to rejoin, Moby")
    XCTAssertEqual(row(.interrupted), "stopped by an interruption, Moby")
    XCTAssertEqual(row(.rejoining), "rejoining the others, Moby")
    XCTAssertEqual(
      ListenTogetherRow.value(
        state: .sharing(participants: 1), joinedTitle: nil, listener: nil, sharerTitle: "Moby",
        pauseCause: ListenTogetherPauseCause(count: 1, lostConnection: true, departedIDs: []), isWaitingForListeners: true),
      "paused, waiting a minute for listeners to come back, Moby")
    XCTAssertEqual(
      ListenTogetherUserMessage.pausedWaitingForListeners(
        ListenTogetherPauseCause(count: 1, lostConnection: true, departedIDs: [])).text,
      "Paused. Someone lost their connection to Listen Together. If nobody is back within a minute, Listen Together ends.")
    XCTAssertTrue(ListenTogetherUserMessage.pausedWaitingForListeners(
      ListenTogetherPauseCause(count: 1, lostConnection: true, departedIDs: [])).notifiesWhenAway)
  }

  /// Fix round 3 (a11y M5): before a roster has arrived the Leave texts claim neither case.
  func testLeaveTextsWhileTheRosterIsUnknownAreNeutral() {
    XCTAssertEqual(
      ListenTogetherSessionAction.leaveConfirmationMessage(usesOwnCopy: false, audience: .unknown),
      "You will leave Listen Together on this iPhone. The book is deleted from this iPhone.")
    XCTAssertEqual(
      ListenTogetherSessionAction.leaveConfirmationMessage(usesOwnCopy: true, audience: .unknown),
      "You will leave Listen Together on this iPhone. Your copy stays in your library.")
    XCTAssertEqual(ListenTogetherSessionAction.leaveToPlayMessage(audience: .unknown),
                   "You will leave Listen Together on this iPhone.")
    XCTAssertEqual(
      ListenTogetherSessionAction.action(for: .listening(participants: 1, downloaded: 1), audience: .unknown)?.hint,
      "The book is deleted from this iPhone.")
    XCTAssertEqual(
      ListenTogetherSessionAction.action(
        for: .listening(participants: 1, downloaded: 1), usesOwnCopy: true, audience: .unknown)?.hint,
      "Your copy stays in your library.")
  }

  // MARK: Option A (Becky, 2026-10-20): the person sharing has an interruption

  func testTheSharersInterruptionIsShownAndSaidOnceAndPlayDoesNothing() async throws {
    let (service, transport, _) = await startListeningWithManifest()
    let listener = try XCTUnwrap(service.listener)
    posted = []
    transport.emit(.message(.action(.pausedBySharer)))
    transport.emit(.message(.sharerInterrupted))
    await waitUntil { service.listenerSharerInterruption != nil }
    timers.advance(by: .seconds(2))
    let text = "The person sharing has an interruption. Listen Together will continue when it ends."
    XCTAssertEqual(posted, [text], "one message: the held pause line is replaced")
    XCTAssertEqual(ListenTogetherStatus.line(for: service.state, conditions: service.statusConditions)?.text, text)
    XCTAssertEqual(ListenTogetherStatus.listenerPlayValue(service.statusConditions), text, "Play's value")
    XCTAssertTrue(listener.refusesUserActions)
    let sentBefore = transport.sent.count
    listener.userTogglePlay()
    listener.userSkip(by: 30)
    XCTAssertEqual(posted, [text, text], "the reason again, at most once per 3 s")
    XCTAssertEqual(transport.sent.count, sentBefore, "nothing reaches the group")
    transport.emit(.message(.sharerInterruptionEnded(resumed: false)))
    await waitUntil { service.listenerSharerInterruption == .needsPlay }
    XCTAssertEqual(posted.last, "Paused. Waiting for the person sharing to press Play.")
    XCTAssertEqual(
      ListenTogetherStatus.line(for: service.state, conditions: service.statusConditions)?.text,
      "Paused. Waiting for the person sharing to press Play.")
    transport.emit(.message(.action(.resumed)))
    await waitUntil { service.listenerSharerInterruption == nil }
    XCTAssertFalse(listener.isSharerInterrupted)
  }

  /// Fix round 4: a listener who joined after the interruption began gets the waiting-for-Play state.
  func testALateJoinerGetsTheWaitingForPlayState() async throws {
    let (service, transport, _) = await startListeningWithManifest()
    posted = []
    transport.emit(.message(.sharerInterruptionEnded(resumed: false)))
    await waitUntil { service.listenerSharerInterruption == .needsPlay }
    XCTAssertEqual(posted, ["Paused. Waiting for the person sharing to press Play."])
    transport.emit(.message(.sharerInterruptionEnded(resumed: false)))
    await waitUntil(timeout: 0.3) { false }
    XCTAssertEqual(posted.count, 1, "the repeat for later joiners is not said again")
  }

  func testTheSharersInterruptionEndingWithAResumeIsSilent() async throws {
    let (service, transport, _) = await startListeningWithManifest()
    transport.emit(.message(.sharerInterrupted))
    await waitUntil { service.listenerSharerInterruption != nil }
    posted = []
    transport.emit(.message(.sharerInterruptionEnded(resumed: true)))
    await waitUntil { service.listenerSharerInterruption == nil }
    XCTAssertEqual(posted, [], "the sound coming back is the cue")
  }

  /// a11y M8: the sharer's own pause is named as theirs.
  func testThePersonSharingsPauseIsNamed() async throws {
    let (service, transport, _) = await startListeningWithManifest()
    posted = []
    transport.emit(.message(.action(.pausedBySharer)))
    await waitUntil { service.isPausedByOther }
    timers.advance(by: .seconds(2))
    XCTAssertEqual(posted, ["The person sharing paused"])
    XCTAssertTrue(service.statusConditions.isPausedBySharer)
    XCTAssertEqual(
      ListenTogetherStatus.line(
        for: .listening(participants: 2, downloaded: 1),
        conditions: ListenTogetherStatusConditions(isPausedByOther: true, isPausedBySharer: true))?.text,
      "Paused by the person sharing")
  }

  func testTheSharerInterruptionRowValues() {
    let snapshot = ListenTogetherRow.ListenerSnapshot(title: "Moby", isPlaying: false, isWaiting: false)
    XCTAssertEqual(
      ListenTogetherRow.value(
        state: .listening(participants: 3, downloaded: 1), joinedTitle: nil, listener: snapshot, sharerTitle: nil,
        sharerInterruption: .interrupted),
      "paused, the person sharing has an interruption, Moby")
    XCTAssertEqual(
      ListenTogetherRow.value(
        state: .sharing(participants: 2), joinedTitle: nil, listener: nil, sharerTitle: "Moby", ownInterruption: .needsPlay),
      "paused, press Play to continue Listen Together, Moby")
    let away = ListenTogetherDeliveryContext(appState: .background, isLocked: true, isVoiceOverRunning: true)
    XCTAssertTrue(ListenTogetherMessageDelivery.plan(for: .sharerInterruption(.interrupted), context: away).notifiesWhenAway)
    XCTAssertFalse(ListenTogetherMessageDelivery.plan(for: .ownInterruption(.interrupted), context: away).announces,
                   "never over the sharer's call")
    XCTAssertTrue(ListenTogetherMessageDelivery.plan(for: .ownInterruption(.needsPlay), context: away).notifiesWhenAway)
  }

  func testPressPlayWhileAwayIsSaidOnceOnTheReturnWithoutNotificationPermission() async {
    let (service, _, _) = await startListeningWithManifest()
    system.become(.background)
    posted = []
    service.setListenerLocalStop(.interrupted)
    await waitUntil(timeout: 0.3) { false }
    XCTAssertEqual(posted, [], "'will continue' is never said from the background")
    service.setListenerLocalStop(.needsPlay)
    await waitUntil { service.announcesStopWhenActive }
    XCTAssertEqual(posted, [], "no announcement from the background")
    system.become(.active)
    await waitUntil { !self.posted.isEmpty }
    XCTAssertEqual(posted, ["Stopped on this iPhone. Press Play to rejoin the others."], "once, on the return")
    system.become(.background)
    system.become(.active)
    await waitUntil(timeout: 0.3) { false }
    XCTAssertEqual(posted.count, 1)
  }

  func testRejoiningBeforeTheReturnSaysNothingThen() async {
    let (service, _, _) = await startListeningWithManifest()
    system.become(.background)
    posted = []
    service.setListenerLocalStop(.needsPlay)
    await waitUntil { service.announcesStopWhenActive }
    service.setListenerLocalStop(nil)
    system.become(.active)
    await waitUntil(timeout: 0.3) { false }
    XCTAssertEqual(posted, [], "it is over: nothing said")
  }

  func testPressPlayWhileAwayIsANotificationWhenAllowed() async {
    let (service, _, _) = await startListeningWithManifest()
    var notified: [String] = []
    var removed = 0
    service.messages.postNotification = { _, body in notified.append(body); return true }
    service.messages.removeNotification = { removed += 1 }
    system.become(.background)
    posted = []
    service.setListenerLocalStop(.needsPlay)
    await waitUntil { !notified.isEmpty }
    XCTAssertEqual(notified, ["Stopped on this iPhone. Press Play to rejoin the others."])
    XCTAssertEqual(posted, [])
    service.setListenerLocalStop(.rejoining)
    XCTAssertEqual(removed, 1, "removed once it is no longer true")
  }

  func testWaitingForAPieceKeepsThePercentVisible() {
    let state = ListenTogetherState.listening(participants: 2, downloaded: 0.3)
    let conditions = ListenTogetherStatusConditions(isWaitingForPiece: true)
    let line = try! XCTUnwrap(ListenTogetherStatus.line(for: state, conditions: conditions))
    XCTAssertEqual(line.text, "Waiting for the book")
    XCTAssertEqual(line.detail, ListenTogetherStatus.visibleText(for: state))
    XCTAssertEqual(line.spoken, "Waiting for the book. " + ListenTogetherStatus.spokenText(for: state)!)
    XCTAssertEqual(ListenTogetherStatus.waitingCaption(conditions), "Waiting for the book")
    XCTAssertNil(ListenTogetherStatus.waitingCaption(.init()))
  }

  func testSharerRetryAndDeclineLines() {
    let state = ListenTogetherState.sharing(participants: 2)
    var line = try! XCTUnwrap(ListenTogetherStatus.line(for: state, conditions: .init(notice: .retryingSend)))
    XCTAssertEqual(line.text, "Couldn't send part of the book. Trying again.")
    XCTAssertEqual(line.icon, .warning)
    line = try! XCTUnwrap(ListenTogetherStatus.line(for: state, conditions: .init(someoneDeclined: true)))
    XCTAssertEqual(line.text, ListenTogetherStatus.visibleText(for: state))
    XCTAssertEqual(line.detail, "listen_together_declined_no_copy".localized)
    line = try! XCTUnwrap(ListenTogetherStatus.line(for: state, conditions: .init(isPausedByOther: true)))
    XCTAssertEqual(line.text, "Paused by another listener")
  }

  func testRowValueWhileWaitingForTheSharer() {
    let value = ListenTogetherRow.value(
      state: .listening(participants: 2, downloaded: 1), joinedTitle: nil,
      listener: .init(title: "Moby Dick", isPlaying: false, isWaiting: true), sharerTitle: nil,
      sharerPresence: .away)
    XCTAssertEqual(value, "waiting for the person sharing, Moby Dick")
  }

  // MARK: The session button (leave guidance)

  func testSessionButtonPerState() throws {
    let preparing = try XCTUnwrap(ListenTogetherSessionAction.action(for: .preparing(title: "T")))
    XCTAssertEqual(preparing.label, "Cancel Sharing")
    XCTAssertEqual(preparing.systemImage, "xmark.circle")
    XCTAssertNil(preparing.hint)
    XCTAssertFalse(preparing.confirms, "nothing is lost: acts at once")

    let sharing = try XCTUnwrap(ListenTogetherSessionAction.action(for: .sharing(participants: 2)))
    XCTAssertEqual(sharing.label, "listen_together_end_button".localized)
    XCTAssertEqual(sharing.systemImage, "stop.circle")
    XCTAssertTrue(sharing.confirms)

    let listening = try XCTUnwrap(ListenTogetherSessionAction.action(for: .listening(participants: 3, downloaded: 0)))
    XCTAssertEqual(listening.label, "Leave Listen Together")
    XCTAssertEqual(listening.systemImage, "rectangle.portrait.and.arrow.right")
    XCTAssertEqual(listening.hint, "The others keep listening. The book is deleted from this iPhone.")
    XCTAssertTrue(listening.confirms, "asks once")
    XCTAssertEqual(
      ListenTogetherSessionAction.leaveConfirmationMessage(usesOwnCopy: false),
      "You will leave Listen Together on this iPhone. The others keep listening. The book is deleted from this iPhone. SharePlay stays on until you close it in Control Center.")

    XCTAssertNil(ListenTogetherSessionAction.action(for: .ended(reason: .normal)))
    XCTAssertNil(ListenTogetherSessionAction.action(for: .idle))
  }

  // MARK: Fix round 1

  func testAnInactiveAppStillGetsTheAlert() {
    let plan = ListenTogetherMessageDelivery.plan(for: .sharerEnded, context: .init(appState: .inactive))
    XCTAssertTrue(plan.showsAlert, "Control Center or Siri over BookPlayer is not away (a11y I1)")
    XCTAssertFalse(plan.notifiesOrWaits)
  }

  func testAwayUnlockedWithoutVoiceOverNotifiesAndKeepsTheAlert() {
    var context = ListenTogetherDeliveryContext(appState: .background, isLocked: false, isVoiceOverRunning: false)
    XCTAssertTrue(ListenTogetherMessageDelivery.plan(for: .sharerEnded, context: context).keepsAlertAfterNotification)
    context.isLocked = true
    XCTAssertFalse(ListenTogetherMessageDelivery.plan(for: .sharerEnded, context: context).keepsAlertAfterNotification)
    context = .init(appState: .background, isLocked: false, isVoiceOverRunning: true)
    XCTAssertFalse(
      ListenTogetherMessageDelivery.plan(for: .sharerEnded, context: context).keepsAlertAfterNotification,
      "VoiceOver reads the notification; no duplicate")
  }

  func testUnlockedAwayPostsTheNotificationAndTheAlertWaitsForTheReturn() async {
    locked = false
    let delivery = makeDelivery(active: false)
    var notifications = 0
    delivery.postNotification = { _, _ in
      notifications += 1
      return true
    }
    var closed = 0
    delivery.deliver(.sharerEnded) { closed += 1 }
    await waitUntil { delivery.alerts.next != nil }
    XCTAssertEqual(notifications, 1)
    XCTAssertEqual(delivery.alerts.next?.message, .sharerEnded)
    XCTAssertEqual(delivery.alerts.next?.isSpoken, true, "already spoken; not spoken again")
    XCTAssertEqual(closed, 0, "closed by OK on return")
  }

  func testAStuckCoverIsTakenAsGoneAfterTwoSeconds() {
    let delivery = makeDelivery()
    let cover = NSObject()
    delivery.currentCoverSnapshot = { cover }
    tracker.coverAppeared()
    delivery.deliver(.sharerEnded)
    delivery.deliver(.unavailable)
    timers.advance(by: .milliseconds(1999))
    XCTAssertTrue(tracker.isListenerCoverOnScreen)
    XCTAssertFalse(delivery.coverWaitTimedOut)
    timers.advance(by: .milliseconds(1))
    XCTAssertFalse(tracker.isListenerCoverOnScreen, "never waits for ever (code I2)")
    XCTAssertTrue(delivery.coverWaitTimedOut, "MainCoordinator closes a cover still up after OK")
    XCTAssertTrue(delivery.stuckCover === cover, "exactly the controller on screen when the watchdog fired")
    let step = MainCoordinator.listenTogetherAlertStep(
      isActive: true, waitsForCover: true, isCoverOnScreen: tracker.isListenerCoverOnScreen, isOtherAlertOnScreen: false)
    XCTAssertEqual(step, .present)
    let first = try! XCTUnwrap(delivery.alerts.next)
    delivery.alertPresented(first.id)
    delivery.alertClosed(first.id)
    XCTAssertEqual(delivery.alerts.next?.message, .unavailable, "the queue behind it is not blocked")
  }

  func testTheCoverCheckOnBecomingActive() {
    let delivery = makeDelivery()
    delivery.schedule = { _, _ in }   // timers don't run in the background
    tracker.coverAppeared()
    delivery.deliver(.sharerLeft)
    XCTAssertFalse(delivery.forceCoverGoneIfOverdue(), "not overdue yet")
    timers.advance(by: .seconds(3))
    XCTAssertTrue(delivery.forceCoverGoneIfOverdue())
    XCTAssertFalse(tracker.isListenerCoverOnScreen)
  }

  func testLeaveWithAStuckCoverStillFocusesAndAnnounces() {
    let focus = ListenTogetherFocusRequests()
    var focused = 0
    let bag = focus.miniPlayer.sink { focused += 1 }
    let delivery = makeDelivery(focus: focus)
    tracker.coverAppeared()
    delivery.afterListenerCoverGone(announce: "You left Listen Together.")
    timers.advance(by: .seconds(4))
    XCTAssertEqual(focused, 1)
    XCTAssertEqual(posted, ["You left Listen Together."])
    withExtendedLifetime(bag) {}
  }

  func testInvalidationWhileListeningIsOneAlertWithoutAnnouncement() async {
    let (service, transport, _) = await startListeningWithManifest()
    posted = []
    transport.emit(.invalidated)
    await waitUntil { service.messages.alerts.next != nil }
    XCTAssertEqual(service.messages.alerts.next?.message, .connectionEnded)
    XCTAssertEqual(
      service.messages.alerts.next?.message.text,
      "Listen Together ended because the connection to the person sharing was lost.")
    XCTAssertEqual(posted, [])
    XCTAssertNil(ListenTogetherStatus.visibleText(for: service.state), "no banner")
    XCTAssertEqual(service.endNotice, .connectionEnded)
  }

  func testTheStreamEndingIsTheSameEnding() async {
    let (service, transport, _) = await startListeningWithManifest()
    posted = []
    transport.leave()   // the event stream ends without an end message
    await waitUntil { service.messages.alerts.next != nil }
    XCTAssertEqual(service.messages.alerts.next?.message, .connectionEnded)
    XCTAssertEqual(posted, [])
  }

  func testOneEndingPerSession() async {
    let (service, transport, _) = await startListeningWithManifest()
    transport.emit(.message(.sessionEnding))
    transport.emit(.invalidated)
    await waitUntil { service.messages.alerts.next != nil }
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(service.messages.alerts.pending.map(\.message), [.sharerEnded], "never replaced by a vaguer one")

    let (other, otherTransport, _) = await startListeningWithManifest()
    other.end()
    otherTransport.emit(.invalidated)
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(other.messages.alerts.pending.map(\.message), [], "an own End followed by invalidation: nothing")
  }

  func testSharerInvalidationHasItsOwnSentence() {
    let service = makeService(), transport = FakeTransport()
    service.startSharingSession(with: transport, item: PlayableItem.stub(currentTime: 0, duration: 10), shareID: UUID())
    service.tearDown(reason: .connectionEnded)
    XCTAssertEqual(service.messages.alerts.next?.message, .connectionEndedSharer)
    XCTAssertEqual(
      service.messages.alerts.next?.message.text, "Listen Together ended because the call or connection ended.")
    XCTAssertNil(service.endNotice)
  }

  func testListenerPrepareFailureSentence() {
    XCTAssertEqual(
      Message.sharerCouldNotPrepare.text, "The person sharing couldn't prepare the book. Listen Together ended.")
  }

  func testSilenceIsQuietAndNeverSaysBack() async {
    let service = makeService(), transport = FakeTransport()
    service.startListening(with: transport, shareID: UUID())
    posted = []
    timers.advance(by: .seconds(20))
    XCTAssertEqual(service.notice, .waitingForSharer)
    XCTAssertFalse(service.isSharerGraceRunning)
    XCTAssertFalse(posted.contains { $0.contains("person sharing") }, "nothing announced (a11y I4)")
    XCTAssertEqual(speaker.spoken, [], "nothing spoken")
    transport.emit(.message(.heartbeat))
    await waitUntil { service.notice == nil }
    XCTAssertFalse(posted.contains("The person sharing is back."))
  }

  func testRowValuesForTheSharerQuietAndRetrying() {
    let quiet = ListenTogetherRow.value(
      state: .listening(participants: 2, downloaded: 1), joinedTitle: nil,
      listener: .init(title: "Moby Dick", isPlaying: true, isWaiting: false), sharerTitle: nil,
      sharerPresence: .quiet)
    XCTAssertEqual(quiet, "can't reach the person sharing, Moby Dick")
    let retrying = ListenTogetherRow.value(
      state: .sharing(participants: 2), joinedTitle: nil, listener: nil, sharerTitle: "Moby Dick",
      isRetryingSend: true)
    XCTAssertEqual(retrying, "couldn't send part of the book, trying again, Moby Dick")
  }

  func testLeaveIsOfferedOnlyWhereTheHostOwnsTheQuestion() {
    XCTAssertFalse(ListenTogetherSessionAction.isOffered(.leave, hasHostLeave: false), "no banner-owned question (I3)")
    XCTAssertTrue(ListenTogetherSessionAction.isOffered(.leave, hasHostLeave: true))
    XCTAssertTrue(ListenTogetherSessionAction.isOffered(.endForEveryone, hasHostLeave: false))
    XCTAssertTrue(ListenTogetherSessionAction.isOffered(.cancelSharing, hasHostLeave: false))
  }

  func testLeaveHasNoEndedBanner() async {
    let (service, _, _) = await startListeningWithManifest()
    service.leave()
    XCTAssertEqual(service.state, .ended(reason: .left))
    XCTAssertNil(ListenTogetherStatus.visibleText(for: service.state), "it didn't end for everyone (a11y M6)")
  }

  func testAlertRetryBacksOff() {
    XCTAssertEqual(MainCoordinator.listenTogetherAlertRetryDelay(retry: 0), 0.5)
    XCTAssertEqual(MainCoordinator.listenTogetherAlertRetryDelay(retry: 1), 1)
    XCTAssertEqual(MainCoordinator.listenTogetherAlertRetryDelay(retry: 3), 4)
    XCTAssertEqual(MainCoordinator.listenTogetherAlertRetryDelay(retry: 10), 5)
  }

  func testTheNeedsCopyNoticeDoesNotAgeBehindAnotherAlert() {
    let service = makeService()
    service.declineWithoutCopy(bookTitle: "Moby Dick", cause: .notFound)
    service.pauseNeedsCopyNoticeAging()
    timers.advance(by: .seconds(120))
    XCTAssertTrue(service.needsCopyNoticeIsCurrent(), "held back by another alert (a11y M7)")
    service.resumeNeedsCopyNoticeAging()
    timers.advance(by: .seconds(61))
    XCTAssertFalse(service.needsCopyNoticeIsCurrent())
  }

  // MARK: Fix round 2

  /// N1: the Leave path's watchdog records nothing, and a later normal ending (book player presented, the
  /// listener cover reported gone) never closes anything.
  func testALaterNormalEndingNeverClosesTheBookPlayer() {
    let delivery = makeDelivery()
    let player = NSObject()
    delivery.currentCoverSnapshot = { player }
    tracker.coverAppeared()
    delivery.afterListenerCoverGone(announce: "You left Listen Together.")
    timers.advance(by: .seconds(3))
    XCTAssertNil(delivery.stuckCover, "the Leave path never records a cover")
    XCTAssertFalse(tracker.isListenerCoverOnScreen, "but the stuck flag is reset")
    XCTAssertEqual(posted, ["You left Listen Together."], "said once")
    // Later: a listener ending whose cover leaves normally.
    tracker.coverAppeared()
    delivery.deliver(.sharerEnded)
    tracker.coverDismissed()
    timers.advance(by: .seconds(3))
    XCTAssertNil(delivery.takeStuckCover())
    XCTAssertFalse(
      MainCoordinator.closesStuckCover(recorded: delivery.stuckCover, presented: player, isBeingDismissed: false),
      "the book player is never dismissed")
  }

  func testAStuckCoverIsForgottenByANewSessionOrTeardown() {
    let delivery = makeDelivery()
    let cover = NSObject()
    delivery.currentCoverSnapshot = { cover }
    tracker.coverAppeared()
    delivery.deliver(.sharerEnded)
    timers.advance(by: .seconds(2))
    XCTAssertNotNil(delivery.stuckCover)
    delivery.dropPendingAlerts()
    XCTAssertNil(delivery.stuckCover, "a new invitation or session forgets it")
  }

  func testANewSessionAndATeardownForgetAStuckCover() async {
    let service = makeService()
    let cover = NSObject()
    service.messages.currentCoverSnapshot = { cover }
    tracker.coverAppeared()
    service.messages.deliver(.sharerEnded)
    timers.advance(by: .seconds(2))
    XCTAssertNotNil(service.messages.stuckCover)
    service.startListening(with: FakeTransport(), shareID: UUID())
    XCTAssertNil(service.messages.stuckCover, "a new session forgets it")

    tracker.coverAppeared()
    service.messages.deliver(.sharerEnded)
    timers.advance(by: .seconds(4))
    XCTAssertNotNil(service.messages.stuckCover)
    service.end()
    XCTAssertNil(service.messages.stuckCover, "a teardown forgets it")
  }

  /// N4: the coordinator closes only the recorded controller, and only while it is still presented.
  func testClosesStuckCoverDecision() {
    let cover = NSObject(), player = NSObject()
    XCTAssertTrue(MainCoordinator.closesStuckCover(recorded: cover, presented: cover, isBeingDismissed: false))
    XCTAssertFalse(MainCoordinator.closesStuckCover(recorded: cover, presented: player, isBeingDismissed: false))
    XCTAssertFalse(MainCoordinator.closesStuckCover(recorded: cover, presented: cover, isBeingDismissed: true))
    XCTAssertFalse(MainCoordinator.closesStuckCover(recorded: nil, presented: player, isBeingDismissed: false))
    XCTAssertFalse(MainCoordinator.closesStuckCover(recorded: cover, presented: nil, isBeingDismissed: false))
  }

  /// N2: a cover that leaves normally ends the wait; a second ending soon after starts its own 2 s.
  func testANormalDismissalResetsTheCoverWait() {
    let delivery = makeDelivery()
    tracker.coverAppeared()
    delivery.deliver(.sharerEnded)
    timers.advance(by: .milliseconds(1500))
    tracker.coverDismissed()
    let first = try! XCTUnwrap(delivery.alerts.next)
    delivery.alertPresented(first.id)
    delivery.alertClosed(first.id)
    tracker.coverAppeared()
    delivery.deliver(.sharerLeft)
    timers.advance(by: .milliseconds(600))   // the first watchdog fires at 2.0 s
    XCTAssertTrue(tracker.isListenerCoverOnScreen, "not forced early by the first wait's start time")
    timers.advance(by: .milliseconds(1400))  // 2 s after the second ending was queued
    XCTAssertFalse(tracker.isListenerCoverOnScreen)
  }

  // MARK: Final review fixes

  /// M2: before the book arrives, or while nothing plays, silence never claims the book keeps playing.
  func testNoQuietLineBeforeTheBookOrWhilePaused() async {
    let downloading = ListenTogetherState.listening(participants: 2, downloaded: 0.25)
    let line = ListenTogetherStatus.line(for: downloading, conditions: .init(notice: .waitingForSharer))
    XCTAssertEqual(line?.text, ListenTogetherStatus.visibleText(for: downloading), "getting the book N percent")
    let paused = ListenTogetherState.listening(participants: 2, downloaded: 1)
    XCTAssertEqual(
      ListenTogetherStatus.line(for: paused, conditions: .init(notice: .waitingForSharer))?.text,
      ListenTogetherStatus.visibleText(for: paused))
    XCTAssertEqual(
      ListenTogetherStatus.line(for: paused, conditions: .init(notice: .waitingForSharer, isListenerPlaying: true))?.text,
      "Can't reach the person sharing. The book keeps playing.")

    let service = makeService(), transport = FakeTransport()
    service.startListening(with: transport, shareID: UUID())
    timers.advance(by: .seconds(20))
    XCTAssertEqual(service.notice, .waitingForSharer)
    XCTAssertEqual(
      ListenTogetherStatus.line(for: service.state, conditions: service.statusConditions)?.text,
      ListenTogetherStatus.visibleText(for: service.state), "no manifest yet: still getting the book")
  }

  /// M6: a late heartbeat during the grace doesn't end it; the sharer back in the roster does.
  func testALateHeartbeatDoesNotEndTheGrace() async {
    let (service, transport, _) = await startListeningWithManifest()
    let me = UUID(), sharer = UUID()
    transport.emit(.sharerParticipant(id: sharer))
    transport.emit(.participantsChanged(count: 2, ids: [me, sharer]))
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    await waitUntil { service.isSharerGraceRunning }
    transport.emit(.message(.heartbeat))
    transport.emit(.message(.action(.resumed)))   // a marker: everything before it has been handled
    await waitUntil { posted.contains("listen_together_remote_resumed".localized) }
    XCTAssertTrue(service.isSharerGraceRunning, "a heartbeat alone doesn't prove the sharer is back")
    transport.emit(.participantsChanged(count: 2, ids: [me, sharer]))
    await waitUntil { !service.isSharerGraceRunning }
    XCTAssertFalse(service.isSharerGraceRunning)
  }

  /// M9: a background ending still waiting for the notification check is dropped by a new session.
  func testABackgroundEndingFromAnEarlierSessionIsDropped() async {
    let delivery = makeDelivery(active: false)
    var release: CheckedContinuation<Bool, Never>?
    delivery.postNotification = { _, _ in await withCheckedContinuation { release = $0 } }
    var closed = 0
    delivery.deliver(.sharerEnded) { closed += 1 }
    await waitUntil { release != nil }
    delivery.dropPendingAlerts()   // a new invitation or session
    release?.resume(returning: false)
    await waitUntil { closed == 1 }
    XCTAssertEqual(closed, 1)
    XCTAssertNil(delivery.alerts.next, "never shown in the next session")
  }
}
