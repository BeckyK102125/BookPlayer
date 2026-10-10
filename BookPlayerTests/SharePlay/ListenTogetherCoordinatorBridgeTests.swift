@testable import BookPlayer
import Combine
import XCTest

@MainActor
private final class FakePlaybackTarget: ListenTogetherPlaybackTarget {
  var bookTime: TimeInterval = 0
  var isPlaying = false
  var rate: Float = 1
  var ready = true
  var log: [String] = []
  let subject = PassthroughSubject<LocalPlaybackEvent, Never>()
  var localEvents: AnyPublisher<LocalPlaybackEvent, Never> { subject.eraseToAnyPublisher() }
  func isReady(at bookTime: TimeInterval) -> Bool { ready }
  func applyPlay(at bookTime: TimeInterval, rate: Float) { log.append("play \(Int(bookTime)) \(rate)") }
  func applyPause(at bookTime: TimeInterval) { log.append("pause \(Int(bookTime))") }
  func applySeek(to bookTime: TimeInterval) { log.append("seek \(Int(bookTime))") }
}

@MainActor
private final class FakeCoordinatorControl: ListenTogetherCoordinatorControlling {
  var log: [String] = []
  var suspensionsBegun = 0
  var suspensionsEnded = 0

  func coordinateRateChange(to rate: Float) { log.append("rate \(rate)") }
  func coordinateSeek(to bookTime: TimeInterval) { log.append("seek \(Int(bookTime))") }
  func beginStallSuspension() -> () -> Void {
    suspensionsBegun += 1
    return { [weak self] in self?.suspensionsEnded += 1 }
  }
}

@MainActor
final class ListenTogetherCoordinatorBridgeTests: XCTestCase {
  func testCommandsReachTarget() {
    let target = FakePlaybackTarget()
    let bridge = ListenTogetherCoordinatorBridge(target: target, shareID: UUID())
    bridge.handlePlay(itemTime: 42, rate: 1.25)
    bridge.handlePause(itemTime: 50)
    bridge.handleSeek(itemTime: 600)
    XCTAssertEqual(target.log, ["play 42 1.25", "pause 50", "seek 600"])
  }

  func testBufferingReportsReadiness() {
    let target = FakePlaybackTarget()
    let bridge = ListenTogetherCoordinatorBridge(target: target, shareID: UUID())
    target.ready = false
    XCTAssertFalse(bridge.handleBuffering())
    target.ready = true
    XCTAssertTrue(bridge.handleBuffering())
  }

  func testLocalEventsBecomeCoordinatorCommands() {
    let target = FakePlaybackTarget()
    let control = FakeCoordinatorControl()
    let bridge = ListenTogetherCoordinatorBridge(target: target, shareID: UUID(), control: control)
    target.subject.send(.played(at: 10, rate: 1.5))
    target.subject.send(.paused(at: 12))
    target.subject.send(.seeked(to: 300, from: 12))
    target.isPlaying = false
    target.subject.send(.rateChanged(2))
    target.isPlaying = true
    target.subject.send(.rateChanged(2))
    XCTAssertEqual(control.log, ["rate 1.5", "rate 0.0", "seek 300", "rate 2.0"])
    withExtendedLifetime(bridge) {}
  }

  func testWaitForPieceBeginsOneSuspensionEndedOnlyWhenReady() {
    let target = FakePlaybackTarget()
    let control = FakeCoordinatorControl()
    let bridge = ListenTogetherCoordinatorBridge(target: target, shareID: UUID(), control: control)
    target.ready = false
    bridge.waitForPiece()
    bridge.waitForPiece()
    XCTAssertEqual(control.suspensionsBegun, 1)

    bridge.pieceBecameAvailable()
    XCTAssertEqual(control.suspensionsEnded, 0)

    target.ready = true
    bridge.pieceBecameAvailable()
    XCTAssertEqual(control.suspensionsEnded, 1)

    bridge.pieceBecameAvailable()
    XCTAssertEqual(control.suspensionsEnded, 1)
    bridge.waitForPiece()
    XCTAssertEqual(control.suspensionsBegun, 2)
  }

  private var retained: [AnyObject] = []

  private func makeBridge(ready: Bool) -> (ListenTogetherCoordinatorBridge, FakePlaybackTarget, FakeCoordinatorControl) {
    let target = FakePlaybackTarget()
    target.ready = ready
    retained.append(target)
    let control = FakeCoordinatorControl()
    return (ListenTogetherCoordinatorBridge(target: target, shareID: UUID(), control: control), target, control)
  }

  func testSeekWithBufferingBeginsOneSuspensionWhenNotReady() {
    let (bridge, target, control) = makeBridge(ready: false)
    bridge.handleSeek(itemTime: 100, shouldBuffer: true)
    bridge.handleSeek(itemTime: 101, shouldBuffer: true)
    XCTAssertEqual(target.log, ["seek 100", "seek 101"])
    XCTAssertEqual(control.suspensionsBegun, 1)
  }

  func testSeekWithoutBufferingBeginsNoSuspension() {
    let (bridge, _, control) = makeBridge(ready: false)
    bridge.handleSeek(itemTime: 100, shouldBuffer: false)
    XCTAssertEqual(control.suspensionsBegun, 0)
  }

  func testPauseWithBufferingWhenReadyBeginsNoSuspension() {
    let (bridge, _, control) = makeBridge(ready: true)
    bridge.handlePause(itemTime: 5, shouldBuffer: true)
    XCTAssertEqual(control.suspensionsBegun, 0)
  }

  func testPauseWithBufferingWhenNotReadyBeginsSuspension() {
    let (bridge, _, control) = makeBridge(ready: false)
    bridge.handlePause(itemTime: 5, shouldBuffer: true)
    XCTAssertEqual(control.suspensionsBegun, 1)
  }

  func testNilTargetNeverBeginsSuspensionAndEndsExisting() {
    let control = FakeCoordinatorControl()
    var target: FakePlaybackTarget? = FakePlaybackTarget()
    target?.ready = false
    let bridge = ListenTogetherCoordinatorBridge(target: target!, shareID: UUID(), control: control)
    bridge.waitForPiece()
    XCTAssertEqual(control.suspensionsBegun, 1)
    target = nil
    bridge.pieceBecameAvailable()
    XCTAssertEqual(control.suspensionsEnded, 1)
    bridge.waitForPiece()
    XCTAssertEqual(control.suspensionsBegun, 1)
  }

  func testInvalidatedBridgeIgnoresCommandsAndWaits() {
    let (bridge, target, control) = makeBridge(ready: false)
    bridge.waitForPiece()
    bridge.invalidate()
    XCTAssertEqual(control.suspensionsEnded, 1)
    bridge.handlePlay(itemTime: 1, rate: 1)
    bridge.handlePause(itemTime: 1, shouldBuffer: true)
    bridge.handleSeek(itemTime: 1, shouldBuffer: true)
    bridge.waitForPiece()
    XCTAssertEqual(target.log, [])
    XCTAssertEqual(control.suspensionsBegun, 1)
  }
}
