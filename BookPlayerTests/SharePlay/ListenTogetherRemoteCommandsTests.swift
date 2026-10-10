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

  func testPlayAndToggleReportAPlay() {
    startListening(at: 40)
    XCTAssertEqual(router.handle(.play), .success)
    XCTAssertEqual(events, [.played(at: 40, rate: 1)])
    events = []
    XCTAssertEqual(router.handle(.togglePlayPause), .success)
    XCTAssertEqual(events.count, 1)
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

  func testNextAndPreviousTrackMoveByChapter() {
    startListening(at: 150)
    XCTAssertEqual(router.handle(.nextTrack), .success)
    XCTAssertEqual(events.last, .seeked(to: 300, from: 150))
    XCTAssertEqual(router.handle(.previousTrack), .success)
    XCTAssertEqual(events.last, .seeked(to: 100, from: 300), "at a chapter's start: the chapter before")
  }

  func testNextAndPreviousTrackWithoutChaptersSkipThirtySeconds() {
    startListening(chapters: [], at: 150)
    XCTAssertEqual(router.handle(.nextTrack), .success)
    XCTAssertEqual(events.last, .seeked(to: 180, from: 150))
    XCTAssertEqual(router.handle(.previousTrack), .success)
    XCTAssertEqual(events.last, .seeked(to: 150, from: 180))
  }

  func testChapterTargets() {
    let book = manifest(chapters: threeChapters)
    XCTAssertEqual(ListenTogetherRemoteCommands.nextChapterStart(in: book, at: 0), 100)
    XCTAssertEqual(ListenTogetherRemoteCommands.nextChapterStart(in: book, at: 100), 300)
    XCTAssertNil(ListenTogetherRemoteCommands.nextChapterStart(in: book, at: 500), "last chapter")
    XCTAssertEqual(ListenTogetherRemoteCommands.previousChapterTarget(in: book, at: 150), 100, "into it: its start")
    XCTAssertEqual(ListenTogetherRemoteCommands.previousChapterTarget(in: book, at: 101), 0, "near its start")
    XCTAssertEqual(ListenTogetherRemoteCommands.previousChapterTarget(in: book, at: 1), 0, "first chapter")
    XCTAssertNil(ListenTogetherRemoteCommands.previousChapterTarget(in: manifest(chapters: []), at: 50))
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

  func testSkipIntervalsAreThirtyDuringTheSessionAndRestoredAfter() {
    service.setState(.listening(participants: 1, downloaded: 0))
    XCTAssertEqual(settings.skipForwardIntervals, [30])
    XCTAssertEqual(settings.skipBackwardIntervals, [30])
    XCTAssertTrue(settings.isSkipForwardEnabled)
    XCTAssertTrue(settings.isSkipBackwardEnabled)
    XCTAssertTrue(settings.isChangePositionEnabled)

    service.setState(.listening(participants: 2, downloaded: 0.5))
    service.setState(.ended(reason: .normal))
    XCTAssertEqual(settings.skipForwardIntervals, [15])
    XCTAssertEqual(settings.skipBackwardIntervals, [45])
    XCTAssertFalse(settings.isSkipForwardEnabled)
    XCTAssertTrue(settings.isSkipBackwardEnabled)
    XCTAssertFalse(settings.isChangePositionEnabled)
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
