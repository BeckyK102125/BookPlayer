@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import XCTest

/// SR7-07: while this phone is a listener, the sleep timer pauses the group (as the listener's Pause
/// button does) and leaves PlayerManager's own paused book, and its audio session, alone.
@MainActor
final class ListenTogetherSleepTimerTests: XCTestCase {
  private var playerManager: PlayerManagerProtocolMock!
  private var service: SharePlaySessionService!
  private var timerEnded: PassthroughSubject<SleepTimerState, Never>!
  private var events: [LocalPlaybackEvent] = []
  private var bag = Set<AnyCancellable>()

  override func setUp() async throws {
    playerManager = PlayerManagerProtocolMock()
    playerManager.underlyingIsPlaying = false
    service = SharePlaySessionService(
      playerManager: playerManager,
      storage: ShareStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("SleepTimerTests-\(UUID())")),
      announcer: ListenTogetherAnnouncer(post: { _ in }))
    timerEnded = PassthroughSubject()
    service.sleepTimerEnded = timerEnded.eraseToAnyPublisher()
    events = []
  }

  override func tearDown() async throws {
    bag.removeAll()
    service = nil
  }

  private func startListening() -> ListenerPlayer {
    let manifest = SharedBookManifest(
      shareID: UUID(), title: "Book", author: "Author", duration: 1000,
      chapters: [SharedChapter(title: "One", start: 0, duration: 1000)],
      pieces: [SharedPiece(index: 0, bookStart: 0, duration: 1000, byteSize: 1)])
    service.setState(.listening(participants: 2, downloaded: 0))
    let listener = ListenerPlayer(manifest: manifest)
    service.setListener(listener)
    listener.localEvents.sink { [unowned self] in self.events.append($0) }.store(in: &bag)
    return listener
  }

  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  func testTheTimerBelongsToTheSessionOnlyWhileListening() {
    _ = startListening()
    XCTAssertEqual(playerManager.sleepTimerBelongsToListenTogether, true)
    service.setListener(nil)
    XCTAssertEqual(playerManager.sleepTimerBelongsToListenTogether, false, "back to the person's own book")
  }

  func testTheTimerRunningOutPausesTheGroupAndNotTheOwnBook() async {
    let listener = startListening()
    listener.applyPlay(at: 10, rate: 1)
    events = []
    timerEnded.send(.countdown(0))
    await drainMainQueue()
    XCTAssertTrue(events.contains { if case .paused = $0 { return true } else { return false } },
                  "the group is paused, as the listener's Pause button does")
    XCTAssertEqual(playerManager.pauseCallsCount, 0, "PlayerManager's own book is left alone")
  }

  func testTheTimerDoesNothingHereAfterTheSessionEnds() async {
    _ = startListening()
    service.setListener(nil)
    events = []
    timerEnded.send(.countdown(0))
    await drainMainQueue()
    XCTAssertTrue(events.isEmpty)
  }
}
