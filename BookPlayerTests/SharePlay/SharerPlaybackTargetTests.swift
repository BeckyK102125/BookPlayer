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
      playerManager: mock, seekCheckInterval: 1000, now: { [unowned self] in self.clock },
      deliversOnMainQueue: false) // timer effectively off; fake publishers already run on main
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
    // Already playing: the publisher's current value says so too (I4 compares against it).
    playing.value = true
    mock.underlyingIsPlaying = true
    let target = makeTarget()
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

  func testFirstRedundantValuesAfterTheInitialOnesAreNotEvents() {
    _ = makeTarget()
    playing.send(false)   // same as the initial value
    speed.send(1)         // same as the initial value
    XCTAssertTrue(events.isEmpty)
    playing.send(true)
    XCTAssertEqual(events, [.played(at: 100, rate: 1)])
  }

  func testApplyRateSetsSpeedWithoutEcho() {
    let target = makeTarget()
    target.applyRate(1.75)
    XCTAssertEqual(mock.setSpeedReceivedNewValue, 1.75)
    XCTAssertEqual(mock.playCallsCount, 0)
    speed.send(1.75)      // PlayerManager reports our own change
    XCTAssertTrue(events.isEmpty)
  }

  func testApplyRateAtCurrentSpeedDoesNothing() {
    let target = makeTarget()
    target.applyRate(1)
    XCTAssertEqual(mock.setSpeedCallsCount, 0)
  }

  // MARK: Fix wave 2

  /// Lets everything already queued on the main queue run (FIFO), with no clock involved.
  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
  }

  /// A-I1: PlayerManager's playing value can come from AVPlayer KVO on another thread. The real target
  /// hops to the main queue before touching its state, and echo suppression still works across the hop.
  func testPublisherValuesFromAnotherThreadAreHandledOnMainAndEchoesStaySuppressed() async {
    let target = SharerPlaybackTarget(
      playerManager: mock, seekCheckInterval: 1000, now: { [unowned self] in self.clock })
    self.target = target
    target.localEvents.sink { [weak self] in self?.events.append($0) }.store(in: &bag)

    DispatchQueue.global().sync { self.playing.send(true) }
    XCTAssertTrue(events.isEmpty, "not handled on the background thread")
    await drainMainQueue()
    XCTAssertEqual(events, [.played(at: 100, rate: 1)])

    // Our own pause, echoed back from another thread, is still recognised as our echo.
    mock.underlyingIsPlaying = true
    target.applyPause(at: 100)
    DispatchQueue.global().sync { self.playing.send(false) }
    await drainMainQueue()
    XCTAssertEqual(events, [.played(at: 100, rate: 1)])

    // A speed change from another thread arrives too.
    DispatchQueue.global().sync { self.speed.send(1.5) }
    await drainMainQueue()
    XCTAssertEqual(events, [.played(at: 100, rate: 1), .rateChanged(1.5)])
  }

  /// M4: after `stop()` (the session's teardown) nothing is reported, even if the target is still held.
  func testStopEndsEveryReport() {
    let target = makeTarget()
    target.stop()
    playing.send(true)
    speed.send(2)
    XCTAssertTrue(events.isEmpty)
  }

  // MARK: Option A (Becky, 2026-10-20): the sharer's interruption keeps the group paused

  func testAGroupPlayDuringTheSharersInterruptionNeverStartsItsAudio() {
    let target = makeTarget()
    mock.underlyingIsPlaying = true
    target.handleInterruption(.began, shouldResume: false)
    XCTAssertEqual(target.interruption, .interrupted)
    target.applyPlay(at: 100, rate: 1)
    target.applyPlay(at: 120, rate: 1)
    XCTAssertEqual(mock.playCallsCount, 0, "PlayerManager.play() would fatalError if the session can't activate")
    XCTAssertEqual(events, [.heldPaused(at: 100), .heldPaused(at: 100)], "the group is asked to stay paused")
  }

  func testTheInterruptionEndingWithPermissionResumesAGroupThatWasPlaying() {
    let target = makeTarget()
    mock.underlyingIsPlaying = true
    target.handleInterruption(.began, shouldResume: false)
    mock.underlyingIsPlaying = false   // the system paused it
    target.handleInterruption(.ended, shouldResume: true)
    XCTAssertNil(target.interruption)
    XCTAssertEqual(mock.playCallsCount, 1, "the sharer resumes the group by itself")
  }

  func testTheInterruptionEndingWithoutPermissionWaitsForTheSharersPlay() {
    let target = makeTarget()
    mock.underlyingIsPlaying = true
    target.handleInterruption(.began, shouldResume: false)
    mock.underlyingIsPlaying = false
    target.handleInterruption(.ended, shouldResume: false)
    XCTAssertEqual(target.interruption, .needsPlay)
    XCTAssertEqual(mock.playCallsCount, 0)
    target.applyPlay(at: 100, rate: 1)
    XCTAssertEqual(mock.playCallsCount, 0, "still never from the group")
    playing.send(true)                 // the sharer pressed Play
    XCTAssertNil(target.interruption)
  }

  func testAnInterruptionWhilePausedNeverResumesByItself() {
    let target = makeTarget()
    target.handleInterruption(.began, shouldResume: false)
    target.handleInterruption(.ended, shouldResume: true)
    XCTAssertEqual(target.interruption, .needsPlay, "the group was paused: the sharer decides")
    XCTAssertEqual(mock.playCallsCount, 0)
  }

  func testAStaleInterruptionFromASuspendedAppIsIgnored() {
    let target = makeTarget()
    target.handleInterruption(.began, shouldResume: false, wasSuspended: true)
    XCTAssertNil(target.interruption)
    target.applyPlay(at: 100, rate: 1)
    XCTAssertEqual(mock.playCallsCount, 1)
  }
}
