@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import XCTest

@MainActor
final class SharerPlaybackTargetTests: XCTestCase {
  private var mock: PlayerManagerProtocolMock!
  private var playing: CurrentValueSubject<Bool, Never>!
  private var speed: CurrentValueSubject<Float, Never>!
  private var events: [LocalPlaybackEvent] = []
  private var bag = Set<AnyCancellable>()

  override func setUp() async throws {
    mock = PlayerManagerProtocolMock()
    playing = CurrentValueSubject(false)
    speed = CurrentValueSubject(1)
    mock.isPlayingPublisherReturnValue = playing.eraseToAnyPublisher()
    mock.currentSpeedPublisherReturnValue = speed.eraseToAnyPublisher()
    mock.underlyingIsPlaying = false
    mock.underlyingCurrentSpeed = 1
    mock.currentItem = PlayableItem.stub(currentTime: 100, duration: 3600)
    events = []
  }

  private func makeTarget() -> SharerPlaybackTarget {
    let target = SharerPlaybackTarget(playerManager: mock, seekCheckInterval: 1000) // timer effectively off
    target.localEvents.sink { [weak self] in self?.events.append($0) }.store(in: &bag)
    return target
  }

  func testLocalPlayIsReported() {
    let target = makeTarget() // must stay alive: its subscriptions die with it
    playing.send(true)
    XCTAssertEqual(events, [.played(at: 100, rate: 1)])
    withExtendedLifetime(target) {}
  }

  func testRemotePauseIsNotEchoed() {
    let target = makeTarget()
    mock.underlyingIsPlaying = true
    target.applyPause(at: 100)
    playing.send(false)            // PlayerManager reacts to our own pause
    XCTAssertEqual(mock.pauseCallsCount, 1)
    XCTAssertTrue(events.isEmpty)
  }

  func testRemoteSeekJumpsWithoutBookmark() {
    let target = makeTarget()
    target.applySeek(to: 500)
    XCTAssertEqual(mock.jumpToRecordBookmarkReceivedArguments?.time, 500)
    XCTAssertEqual(mock.jumpToRecordBookmarkReceivedArguments?.recordBookmark, false)
  }

  func testRemotePlaySetsSpeedThenPlays() {
    let target = makeTarget()
    target.applyPlay(at: 100.2, rate: 1.5)
    XCTAssertEqual(mock.setSpeedReceivedNewValue, 1.5)
    XCTAssertEqual(mock.playCallsCount, 1)
    XCTAssertEqual(mock.jumpToRecordBookmarkCallsCount, 0) // within 0.5 s: no jump
  }

  func testLocalJumpIsDetectedAsSeek() {
    let target = makeTarget()
    let start = Date()
    target.checkForSeek(now: start)                 // baseline at 100, paused
    mock.currentItem?.currentTime = 900
    target.checkForSeek(now: start.addingTimeInterval(0.5))
    XCTAssertEqual(events, [.seeked(to: 900, from: 100)])
  }
}
