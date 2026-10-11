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
    .sharerEnded, .sharerLeft, .sharerCouldNotPrepare, .prepareFailed, .unavailable, .didntStart,
    .waitingForSharer, .sharerBack, .retryingSend, .waitingForBook,
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

  private func makeDelivery(active: Bool = true) -> ListenTogetherMessageDelivery {
    system.appState = active ? .active : .background
    let system = self.system!
    let delivery = ListenTogetherMessageDelivery(
      announcer: ListenTogetherAnnouncer(post: { [weak self] in self?.posted.append($0) }),
      speaker: speaker, coverTracker: tracker, focusRequests: ListenTogetherFocusRequests(),
      isAppActive: { system.appState == .active })
    delivery.schedule = timers.schedule
    return delivery
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
      appSystem: system, speaker: speaker, coverTracker: tracker, focusRequests: ListenTogetherFocusRequests())
    service.retrySleep = { _ in await Task.yield() }
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
      for active in [true, false] {
        let plan = ListenTogetherMessageDelivery.plan(for: message, isActive: active)
        let alertLike = plan.showsAlert || plan.notifiesOrWaits
        XCTAssertFalse(alertLike && plan.announces, "\(message) active=\(active)")
        XCTAssertFalse(plan.speaksNow && plan.speaksWithAlert, "\(message) spoken once")
      }
    }
  }

  func testAlertMessagesWhenActive() {
    for message in [Message.sharerEnded, .sharerLeft, .sharerCouldNotPrepare, .prepareFailed, .unavailable, .didntStart] {
      XCTAssertEqual(
        ListenTogetherMessageDelivery.plan(for: message, isActive: true),
        ListenTogetherDeliveryPlan(showsAlert: true, speaksWithAlert: true), "\(message)")
      XCTAssertEqual(
        ListenTogetherMessageDelivery.plan(for: message, isActive: false),
        ListenTogetherDeliveryPlan(speaksNow: true, notifiesOrWaits: true), "\(message)")
    }
  }

  func testStatusMessagesAnnounceOnceAndOnlyErrorsAreSpoken() {
    XCTAssertEqual(
      ListenTogetherMessageDelivery.plan(for: .waitingForSharer, isActive: true),
      ListenTogetherDeliveryPlan(announces: true, speaksNow: true))
    XCTAssertEqual(
      ListenTogetherMessageDelivery.plan(for: .retryingSend, isActive: false),
      ListenTogetherDeliveryPlan(announces: true, speaksNow: true))
    XCTAssertEqual(
      ListenTogetherMessageDelivery.plan(for: .waitingForBook, isActive: true),
      ListenTogetherDeliveryPlan(announces: true), "normal buffering is never spoken")
    XCTAssertEqual(
      ListenTogetherMessageDelivery.plan(for: .sharerBack, isActive: true),
      ListenTogetherDeliveryPlan(announces: true), "VoiceOver only")
    XCTAssertEqual(
      ListenTogetherMessageDelivery.plan(for: .alertShownElsewhere(text: "x", key: "k"), isActive: true),
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
    let delivery = ListenTogetherMessageDelivery(
      announcer: ListenTogetherAnnouncer(post: { [weak self] in self?.posted.append($0) }),
      speaker: speaker, coverTracker: tracker, focusRequests: focus, isAppActive: { true })
    delivery.schedule = timers.schedule
    tracker.coverAppeared()
    delivery.afterListenerCoverGone(announce: "You left Listen Together.")
    timers.advance(by: .seconds(5))
    XCTAssertEqual(focused, 0)
    XCTAssertEqual(posted, [], "nothing while the cover is still up")
    tracker.coverDismissed()
    timers.advance(by: .milliseconds(499))
    XCTAssertEqual(focused, 0)
    timers.advance(by: .milliseconds(1))
    XCTAssertEqual(focused, 1, "focus moves first")
    XCTAssertEqual(posted, [])
    timers.advance(by: .milliseconds(300))
    XCTAssertEqual(posted, ["You left Listen Together."], "then the sentence, once")
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
    try XCTUnwrap(service.listener).userTogglePlay()
    XCTAssertFalse(service.isPausedByOther, "the person's own play clears it")
  }

  // MARK: Status lines (A.1, C)

  func testEndingsByOthersHaveNoBannerText() {
    for reason in [ListenTogetherState.EndReason.sharerEnded, .sharerLeft, .sharerCouldNotPrepare, .prepareFailed, .unavailable] {
      XCTAssertNil(ListenTogetherStatus.visibleText(for: .ended(reason: reason)), "\(reason)")
    }
  }

  func testSharerWaitWinsAndTheMinuteLineOnlyDuringTheGrace() {
    let state = ListenTogetherState.listening(participants: 2, downloaded: 1)
    var conditions = ListenTogetherStatusConditions(notice: .waitingForSharer, isWaitingForPiece: true)
    var line = try! XCTUnwrap(ListenTogetherStatus.line(for: state, conditions: conditions))
    XCTAssertEqual(line.text, "Waiting for the person sharing")
    XCTAssertNil(line.detail, "silence never ends the session, so no minute")
    XCTAssertEqual(line.icon, .hourglass)
    conditions.isSharerGraceRunning = true
    line = try! XCTUnwrap(ListenTogetherStatus.line(for: state, conditions: conditions))
    XCTAssertEqual(line.detail, "If they are not back within a minute, Listen Together ends.")
    XCTAssertEqual(line.spoken, "Waiting for the person sharing. If they are not back within a minute, Listen Together ends.")
    XCTAssertEqual(ListenTogetherStatus.waitingCaption(conditions), "Waiting for the person sharing")
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
      waitingForSharer: true)
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

    let listening = try XCTUnwrap(ListenTogetherSessionAction.action(for: .listening(participants: 2, downloaded: 0)))
    XCTAssertEqual(listening.label, "Leave Listen Together")
    XCTAssertEqual(listening.systemImage, "rectangle.portrait.and.arrow.right")
    XCTAssertEqual(listening.hint, "The others keep listening. The book is deleted from this iPhone.")
    XCTAssertTrue(listening.confirms, "asks once")
    XCTAssertEqual(
      ListenTogetherSessionAction.leaveConfirmationMessage(usesOwnCopy: false),
      "You will leave Listen Together on this iPhone. The others keep listening. The book is deleted from this iPhone.")

    XCTAssertNil(ListenTogetherSessionAction.action(for: .ended(reason: .normal)))
    XCTAssertNil(ListenTogetherSessionAction.action(for: .idle))
  }
}
