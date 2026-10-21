@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import MediaPlayer
import XCTest

@MainActor
final class FakeCommandSettings: ListenTogetherCommandSettings {
  var skipForwardIntervals: [NSNumber] = [15]
  var skipBackwardIntervals: [NSNumber] = [45]
  var isSkipForwardEnabled = false
  var isSkipBackwardEnabled = true
  var isChangePositionEnabled = false
}

@MainActor
final class FakeNowPlayingSink: ListenTogetherNowPlayingSink {
  var published: [(info: [String: Any]?, state: MPNowPlayingPlaybackState)] = []
  func publish(_ info: [String: Any]?, playbackState: MPNowPlayingPlaybackState) {
    published.append((info, playbackState))
  }
}

@MainActor
final class ListenTogetherRemoteCommandsTests: XCTestCase {
  private var playerManager: PlayerManagerProtocolMock!
  private var service: SharePlaySessionService!
  private var settings: FakeCommandSettings!
  private var sink: FakeNowPlayingSink!
  private var scheduled: [@MainActor () -> Void] = []
  private var userSettings = UserRemoteCommandSettings(
    forwardInterval: 15, rewindInterval: 45, isForwardChapterSkip: true, isRewindChapterSkip: false,
    isSeekBarEnabled: false)
  private var router: ListenTogetherRemoteCommands!
  private var events: [LocalPlaybackEvent] = []
  private var bag = Set<AnyCancellable>()

  private let allCommands: [ListenTogetherRemoteCommands.Command] = [
    .togglePlayPause, .play, .pause, .skipForward, .skipBackward, .nextTrack, .previousTrack, .changePosition(50),
  ]

  override func setUp() async throws {
    playerManager = PlayerManagerProtocolMock()
    playerManager.underlyingIsPlaying = false
    service = SharePlaySessionService(
      playerManager: playerManager,
      storage: ShareStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("RouterTests-\(UUID())")),
      announcer: ListenTogetherAnnouncer(post: { _ in }))
    settings = FakeCommandSettings()
    sink = FakeNowPlayingSink()
    scheduled = []
    events = []
    router = ListenTogetherRemoteCommands(
      settings: settings, nowPlayingSink: sink, now: { Date(timeIntervalSince1970: 0) },
      userSettings: { [unowned self] in self.userSettings },
      schedulePositionApply: { [unowned self] action in self.scheduled.append(action) })
    router.attach(to: service)
  }

  override func tearDown() async throws {
    bag.removeAll()
    router = nil
    service = nil
  }

  private func manifest(chapters: [SharedChapter]) -> SharedBookManifest {
    SharedBookManifest(
      shareID: UUID(), title: "Book", author: "Author", duration: 1000, chapters: chapters,
      pieces: [SharedPiece(index: 0, bookStart: 0, duration: 1000, byteSize: 1)])
  }

  private let threeChapters = [
    SharedChapter(title: "One", start: 0, duration: 100),
    SharedChapter(title: "Two", start: 100, duration: 200),
    SharedChapter(title: "Three", start: 300, duration: 700),
  ]

  /// A listener session with a player at `bookTime` (no pieces, so nothing actually plays).
  @discardableResult
  private func startListening(chapters: [SharedChapter]? = nil, at bookTime: TimeInterval = 0) -> ListenerPlayer {
    service.setState(.listening(participants: 2, downloaded: 0))
    let listener = ListenerPlayer(manifest: manifest(chapters: chapters ?? threeChapters))
    if bookTime > 0 { listener.applyPause(at: bookTime) }
    service.setListener(listener)
    listener.localEvents.sink { [unowned self] in self.events.append($0) }.store(in: &bag)
    return listener
  }

  private func assertPlayerManagerUntouched(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(playerManager.playCallsCount, 0, file: file, line: line)
    XCTAssertEqual(playerManager.playPauseCallsCount, 0, file: file, line: line)
    XCTAssertEqual(playerManager.pauseCallsCount, 0, file: file, line: line)
    XCTAssertEqual(playerManager.forwardCallsCount, 0, file: file, line: line)
    XCTAssertEqual(playerManager.rewindCallsCount, 0, file: file, line: line)
    XCTAssertEqual(playerManager.skipCallsCount, 0, file: file, line: line)
    XCTAssertEqual(playerManager.jumpToRecordBookmarkCallsCount, 0, file: file, line: line)
    XCTAssertEqual(playerManager.skipToNextChapterCallsCount, 0, file: file, line: line)
    XCTAssertEqual(playerManager.skipToPreviousChapterCallsCount, 0, file: file, line: line)
  }

  // MARK: Routing

  /// Audit 2 M1: one rule for every control. While the group waits for this phone's piece, the lock
  /// screen's Pause does what the in-app button and the AirPods toggle do: nothing for the group, and
  /// the reason is said.
  func testLockScreenPauseWhileTheGroupWaitsForThisPhonesPieceIsRefusedLikeTheOtherControls() {
    let listener = startListening(at: 40)
    defer { listener.stop() }
    var refused = 0
    listener.onToggleWhileWaiting = { refused += 1 }
    listener.applyPlay(at: 40, rate: 1)
    XCTAssertFalse(listener.isPlaying)
    XCTAssertTrue(listener.isWaitingForPiece)
    _ = router.handle(.pause)
    XCTAssertEqual(events, [], "the group is not paused for this phone's missing piece")
    XCTAssertEqual(refused, 1, "the reason is said, as for the in-app button")
    XCTAssertTrue(listener.isPlayingForGroup)
    assertPlayerManagerUntouched()
  }

  func testNotHandledOutsideAListenerSession() {
    for state: ListenTogetherState in [.idle, .sharing(participants: 2), .preparing(title: "T"),
                                       .invitation(title: "T", author: "A"), .ended(reason: .normal)] {
      service.setState(state)
      for command in allCommands {
        XCTAssertNil(router.handle(command), "\(command) in \(state)")
      }
    }
    XCTAssertFalse(router.isRouting)
  }

  func testSharerWithAListenerObjectIsStillNotRouted() {
    service.setState(.sharing(participants: 2))
    service.setListener(ListenerPlayer(manifest: manifest(chapters: threeChapters)))
    XCTAssertNil(router.handle(.togglePlayPause))
  }

  func testBeforeTheBookArrivesCommandsReportNoActionableItem() {
    service.setState(.listening(participants: 2, downloaded: 0))
    for command in allCommands {
      XCTAssertEqual(router.handle(command), .noActionableNowPlayingItem, "\(command)")
    }
    XCTAssertTrue(scheduled.isEmpty)
    assertPlayerManagerUntouched()
  }

  func testEveryCommandGoesToTheListenerAndNeverToPlayerManager() {
    startListening(at: 150)
    for command in allCommands {
      XCTAssertEqual(router.handle(command), .success, "\(command)")
    }
    scheduled.forEach { $0() }
    assertPlayerManagerUntouched()
    XCTAssertFalse(events.isEmpty)
  }

  /// Fix round 1: while the place in the book is not known yet, lock screen, AirPods and Control
  /// Center do nothing and say nothing (like waiting for the person sharing).
  func testEveryCommandIsSilentAndDoesNothingWhileFindingThePlace() {
    let listener = startListening(at: 150)
    listener.isJoiningGroup = true
    var refusals = 0
    listener.onActionWhileJoining = { refusals += 1 }
    for command in allCommands {
      XCTAssertEqual(router.handle(command), .success, "\(command)")
    }
    scheduled.forEach { $0() }
    XCTAssertEqual(events, [])
    XCTAssertEqual(refusals, 0, "nothing is said from the background")
    assertPlayerManagerUntouched()
  }

  func testPlayAndToggleReportAPlay() {
    startListening(at: 40)
    XCTAssertEqual(router.handle(.play), .success)
    XCTAssertEqual(events, [.played(at: 40, rate: 1)])
    // The piece is missing, so the group is now held for it: another press sends nothing to the group
    // (fix wave 2: no second play, never a pause); the service says "waiting" instead.
    events = []
    XCTAssertEqual(router.handle(.togglePlayPause), .success)
    XCTAssertEqual(router.handle(.play), .success)
    XCTAssertEqual(events, [])
  }

  func testToggleReportsAPlay() {
    startListening(at: 40)
    XCTAssertEqual(router.handle(.togglePlayPause), .success)
    XCTAssertEqual(events, [.played(at: 40, rate: 1)])
  }

  func testPauseWhilePausedDoesNothing() {
    startListening(at: 40)
    XCTAssertEqual(router.handle(.pause), .success)
    XCTAssertEqual(events, [], "pause is idempotent")
  }

  func testSkipsAreThirtySeconds() {
    startListening(at: 150)
    XCTAssertEqual(router.handle(.skipForward), .success)
    XCTAssertEqual(events.last, .seeked(to: 180, from: 150))
    XCTAssertEqual(router.handle(.skipBackward), .success)
    XCTAssertEqual(events.last, .seeked(to: 150, from: 180))
  }

  func testNextAndPreviousTrackSkipThirtySecondsEvenWithChapters() {
    // R33: never a chapter jump (150 -> 300 would be the next chapter here).
    startListening(at: 150)
    XCTAssertEqual(router.handle(.nextTrack), .success)
    XCTAssertEqual(events.last, .seeked(to: 180, from: 150))
    XCTAssertEqual(router.handle(.previousTrack), .success)
    XCTAssertEqual(events.last, .seeked(to: 150, from: 180))
  }

  func testPositionBurstIsAppliedOnceWithTheLatestBookTime() {
    startListening(at: 10)
    XCTAssertEqual(router.handle(.changePosition(200)), .success)
    XCTAssertEqual(router.handle(.changePosition(250)), .success)
    XCTAssertEqual(events, [], "nothing until the events settle")
    scheduled.forEach { $0() }
    XCTAssertEqual(events, [.seeked(to: 250, from: 10)])
  }

  func testPositionPendingWhenTheSessionEndsIsDropped() {
    startListening(at: 10)
    _ = router.handle(.changePosition(200))
    service.setListener(nil)
    service.setState(.ended(reason: .normal))
    scheduled.forEach { $0() }
    XCTAssertEqual(events, [])
    assertPlayerManagerUntouched()
  }

  // MARK: Skip settings and Now Playing hand-back

  func testSkipIntervalsAreThirtyDuringTheSessionAndUserSettingsAfter() {
    service.setState(.listening(participants: 1, downloaded: 0))
    XCTAssertEqual(settings.skipForwardIntervals, [30])
    XCTAssertEqual(settings.skipBackwardIntervals, [30])
    XCTAssertTrue(settings.isSkipForwardEnabled)
    XCTAssertTrue(settings.isSkipBackwardEnabled)
    XCTAssertTrue(settings.isChangePositionEnabled)

    service.setState(.listening(participants: 2, downloaded: 0.5))
    service.setState(.ended(reason: .normal))
    // The user's settings: forward is chapter skip (disabled), back 45 s, no seek bar.
    XCTAssertFalse(settings.isSkipForwardEnabled)
    XCTAssertTrue(settings.isSkipBackwardEnabled)
    XCTAssertEqual(settings.skipBackwardIntervals, [45])
    XCTAssertFalse(settings.isChangePositionEnabled)
  }

  func testUserSettingChangedMidSessionKeepsThirtyThenIsRestoredLive() {
    service.setState(.listening(participants: 1, downloaded: 0))
    // The user changes the forward skip to 10 s during the session: PlayerManager's setter writes
    // the command centre directly.
    userSettings.forwardInterval = 10
    userSettings.isForwardChapterSkip = false
    userSettings.isSeekBarEnabled = true
    settings.skipForwardIntervals = [10]
    NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
    XCTAssertEqual(settings.skipForwardIntervals, [30], "the lock screen still advertises 30 s")
    XCTAssertTrue(settings.isSkipForwardEnabled)

    service.setState(.ended(reason: .normal))
    XCTAssertEqual(settings.skipForwardIntervals, [10], "the new setting, not the one from the start")
    XCTAssertTrue(settings.isSkipForwardEnabled)
    XCTAssertTrue(settings.isChangePositionEnabled)
    NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
    XCTAssertEqual(settings.skipForwardIntervals, [10], "nothing re-applied after the session")
  }

  func testSharingDoesNotChangeSkipIntervals() {
    service.setState(.sharing(participants: 2))
    XCTAssertEqual(settings.skipForwardIntervals, [15])
    XCTAssertFalse(settings.isChangePositionEnabled)
  }

  func testEndingWithNoOwnBookClearsNowPlaying() {
    startListening(at: 10)
    service.setListener(nil)
    service.setState(.ended(reason: .normal))
    XCTAssertNil(sink.published.last?.info)
    XCTAssertEqual(sink.published.last?.state, .stopped)
    assertPlayerManagerUntouched()
  }

  func testEndingWithAPausedOwnBookRepublishesItThroughPause() {
    playerManager.currentItem = PlayableItem.stub(currentTime: 0, duration: 10, fileURL: URL(fileURLWithPath: "/x.m4a"))
    startListening(at: 10)
    let publishedDuringSession = sink.published.count
    XCTAssertGreaterThan(publishedDuringSession, 0, "the shared book was on the lock screen")
    service.setListener(nil)
    service.setState(.ended(reason: .normal))
    XCTAssertEqual(playerManager.pauseCallsCount, 1, "pause() re-publishes the paused book's own info")
    XCTAssertEqual(sink.published.count, publishedDuringSession, "the shared book is not published again")
  }

  func testNowPlayingShowsTheSharedBookDuringTheSession() throws {
    startListening(at: 150)
    let info = try XCTUnwrap(sink.published.last?.info)
    XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Two")
    XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Book")
    XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 150)
    XCTAssertEqual(sink.published.last?.state, .paused)
  }
}

/// Fork audit A17: Siri and Shortcuts during a Listen Together session never touch the user's own
/// paused book; they act on the shared book or say why not. Each intent asks this router first.
@MainActor
final class ListenTogetherIntentRoutingTests: XCTestCase {
  private var playerManager: PlayerManagerProtocolMock!
  private var service: SharePlaySessionService!
  private var posted: [String] = []
  private var events: [LocalPlaybackEvent] = []
  private var bag = Set<AnyCancellable>()

  override func setUp() async throws {
    playerManager = PlayerManagerProtocolMock()
    playerManager.underlyingIsPlaying = false
    playerManager.underlyingCurrentSpeed = 1
    playerManager.isPlayingPublisherReturnValue = Just(false).eraseToAnyPublisher()
    playerManager.currentSpeedPublisherReturnValue = Just(Float(1)).eraseToAnyPublisher()
    service = SharePlaySessionService(
      playerManager: playerManager,
      storage: ShareStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("IntentTests-\(UUID())")),
      announcer: ListenTogetherAnnouncer(post: { [weak self] in self?.posted.append($0) }))
    service.coordinatorControlFactory = { RecordingCoordinatorControl() }
    posted = []
    events = []
  }

  override func tearDown() async throws {
    service.end()
    bag.removeAll()
  }

  private func listening() -> ListenerPlayer {
    service.startListening(with: FakeTransport(), shareID: UUID())
    let manifest = SharedBookManifest(
      shareID: UUID(), title: "Shared", author: "A", duration: 1000,
      chapters: [SharedChapter(title: "One", start: 0, duration: 1000)],
      pieces: [SharedPiece(index: 0, bookStart: 0, duration: 1000, byteSize: 1)])
    let listener = ListenerPlayer(manifest: manifest)
    listener.applyPause(at: 100)
    service.setListener(listener)
    listener.localEvents.sink { [unowned self] in self.events.append($0) }.store(in: &bag)
    return listener
  }

  private func untouched(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(playerManager.pauseCallsCount, 0, file: file, line: line)
    XCTAssertEqual(playerManager.skipCallsCount, 0, file: file, line: line)
    XCTAssertEqual(playerManager.directSkipCallsCount, 0, file: file, line: line)
    XCTAssertEqual(playerManager.playCallsCount, 0, file: file, line: line)
  }

  func testOutsideASessionEveryIntentProceeds() {
    for command: ListenTogetherIntentRouting.Command in [
      .pause, .skip(seconds: 30), .createBookmark, .startBook(relativePath: "a", title: "A"),
    ] {
      XCTAssertEqual(ListenTogetherIntentRouting.route(command, service: service), .proceed)
    }
  }

  func testAListenersPauseIntentGoesToTheSharedBookNotTheirOwn() {
    listening()
    XCTAssertEqual(ListenTogetherIntentRouting.route(.pause, service: service), .handled)
    untouched()
  }

  func testAListenersSkipIntentsMoveTheSharedBook() {
    listening()
    XCTAssertEqual(ListenTogetherIntentRouting.route(.skip(seconds: 30), service: service), .handled)
    XCTAssertEqual(ListenTogetherIntentRouting.route(.skip(seconds: -15), service: service), .handled)
    XCTAssertEqual(events.count, 2)
    untouched()
  }

  func testAListenersBookmarkIntentIsRefused() {
    listening()
    XCTAssertEqual(
      ListenTogetherIntentRouting.route(.createBookmark, service: service),
      .refused("You're listening to someone else's book, so a bookmark can't be added now."))
  }

  func testAListenerStartingTheirOwnBookFromSiriLeavesFirst() {
    listening()
    XCTAssertEqual(
      ListenTogetherIntentRouting.route(.startBook(relativePath: "own.m4b", title: "Moby Dick"), service: service),
      .proceed)
    XCTAssertFalse(service.isInSession, "left Listen Together, so the book may start")
    XCTAssertEqual(posted, ["You left Listen Together. Playing Moby Dick."])
  }

  func testASharerStartingAnotherBookFromSiriIsRefused() {
    let item = PlayableItem.stub(currentTime: 10, duration: 100)
    playerManager.currentItem = item
    service.startSharingSession(with: FakeTransport(), item: item, shareID: UUID())
    XCTAssertEqual(
      ListenTogetherIntentRouting.route(.startBook(relativePath: "other.m4b", title: "Other"), service: service),
      .refused("You're sharing a book. End Listen Together first to play another book."))
    XCTAssertEqual(
      ListenTogetherIntentRouting.route(.startBook(relativePath: item.relativePath, title: nil), service: service),
      .proceed, "resuming the shared book is fine")
    XCTAssertEqual(ListenTogetherIntentRouting.route(.pause, service: service), .proceed, "the sharer's book is the shared one")
    XCTAssertTrue(service.isInSession)
  }
}
