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
  private var target: SharerPlaybackTarget?
  private var clock = Date(timeIntervalSince1970: 1_000_000)

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
    clock = Date(timeIntervalSince1970: 1_000_000)
  }

  override func tearDown() async throws {
    target = nil
    bag.removeAll()
  }

  private func makeTarget() -> SharerPlaybackTarget {
    let target = SharerPlaybackTarget(
      playerManager: mock, seekCheckInterval: 1000, now: { [unowned self] in self.clock }) // timer effectively off
    self.target = target // keep alive through assertions: subscriptions die with it
    target.localEvents.sink { [weak self] in self?.events.append($0) }.store(in: &bag)
    return target
  }

  func testLocalPlayIsReported() {
    let target = makeTarget() // must stay alive: its subscriptions die with it
    playing.send(true)
    XCTAssertEqual(events, [.played(at: 100, rate: 1)])
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

  func testItemChangeResetsBaselineWithoutSeek() {
    let target = makeTarget()
    let start = Date()
    target.checkForSeek(now: start)
    mock.currentItem = PlayableItem.stub(currentTime: 2000, duration: 3600)
    target.checkForSeek(now: start.addingTimeInterval(0.5))
    mock.currentItem = nil
    target.checkForSeek(now: start.addingTimeInterval(1))
    XCTAssertTrue(events.isEmpty)
  }

  func testNoOpRemotePlayDoesNotSwallowLaterUserPause() {
    let target = makeTarget()
    mock.underlyingIsPlaying = true
    target.applyPlay(at: 100, rate: 1)   // already playing: no echo expected
    playing.send(false)                  // genuine user pause
    XCTAssertEqual(events, [.paused(at: 100)])
  }

  func testStaleExpectationDoesNotSwallowLaterUserPlay() {
    let target = makeTarget()
    target.applyPlay(at: 100, rate: 1)   // player never reports back
    clock = clock.addingTimeInterval(2)
    playing.send(true)
    XCTAssertEqual(events, [.played(at: 100, rate: 1)])
  }

  func testStallIsNotSeekButForwardAndBackwardJumpsAre() {
    let target = makeTarget()
    mock.underlyingIsPlaying = true
    let start = Date()
    target.checkForSeek(now: start)                       // baseline 100
    target.checkForSeek(now: start.addingTimeInterval(5)) // clock stalled at 100
    XCTAssertTrue(events.isEmpty)
    mock.currentItem?.currentTime = 400
    target.checkForSeek(now: start.addingTimeInterval(10))
    XCTAssertEqual(events, [.seeked(to: 400, from: 100)])
    mock.currentItem?.currentTime = 40
    target.checkForSeek(now: start.addingTimeInterval(11))
    XCTAssertEqual(events.last, .seeked(to: 40, from: 400))
  }

  func testForwardJumpAfterStallIsSeek() {
    let target = makeTarget()
    mock.underlyingIsPlaying = true
    let start = Date()
    target.checkForSeek(now: start)
    mock.currentItem?.currentTime = 300
    target.checkForSeek(now: start.addingTimeInterval(5))
    XCTAssertEqual(events, [.seeked(to: 300, from: 100)])
  }

  func testHighRateCoarseUpdateIsNotSeek() {
    mock.underlyingCurrentSpeed = 3
    let target = makeTarget()
    mock.underlyingIsPlaying = true
    let start = Date()
    target.checkForSeek(now: start)
    mock.currentItem?.currentTime = 103
    target.checkForSeek(now: start.addingTimeInterval(0.5))
    XCTAssertTrue(events.isEmpty)
  }
}
