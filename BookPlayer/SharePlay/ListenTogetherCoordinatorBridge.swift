import AVFoundation
import BookPlayerKit
import Combine
import CoreMedia
import GroupActivities

/// The small surface of `AVDelegatingPlaybackCoordinator` the bridge uses, so tests can observe it.
@MainActor
protocol ListenTogetherCoordinatorControlling: AnyObject {
  func coordinateRateChange(to rate: Float)
  func coordinateSeek(to bookTime: TimeInterval)
  /// Begins a stall-recovery suspension and returns a closure that ends it.
  func beginStallSuspension() -> () -> Void
  /// Makes `identifier` the current item. With a `time`, proposes that the item is at `time` moving
  /// at `rate` (0 when paused); with nil, the coordinator assumes paused at zero.
  func transitionToItem(withIdentifier identifier: String?, proposingTime time: TimeInterval?, rate: Float)
}

/// Syncs one abstract "book time" timeline across a SharePlay session by routing
/// `AVDelegatingPlaybackCoordinator` commands to a `ListenTogetherPlaybackTarget`,
/// and reporting the target's local events back to the coordinator.
@MainActor
final class ListenTogetherCoordinatorBridge: NSObject, BPLogger {
  private weak var target: ListenTogetherPlaybackTarget?
  nonisolated let itemIdentifier: String
  private var control: ListenTogetherCoordinatorControlling!
  private var realCoordinator: AVDelegatingPlaybackCoordinator?
  private var endStallSuspension: (() -> Void)?
  /// A second suspension while a listener waits for the person sharing (addendum 3, decision 9).
  private var endSharerHold: (() -> Void)?
  private var disposeBag = Set<AnyCancellable>()
  private var isInvalidated = false

  /// `role` decides the initial timing: the sharer proposes where it really is (time and rate), so the
  /// group starts there; a listener proposes nothing and adopts the group's timing.
  init(
    target: ListenTogetherPlaybackTarget,
    shareID: UUID,
    role: SharePlaySessionService.Role = .listener,
    control: ListenTogetherCoordinatorControlling? = nil
  ) {
    self.target = target
    self.itemIdentifier = shareID.uuidString
    super.init()

    if let control {
      self.control = control
    } else {
      let coordinator = AVDelegatingPlaybackCoordinator(playbackControlDelegate: self)
      coordinator.suspensionReasonsThatTriggerWaiting = [.stallRecovery]
      self.realCoordinator = coordinator
      self.control = DelegatingCoordinatorControl(coordinator: coordinator)
    }
    switch role {
    case .sharer:
      self.control.transitionToItem(
        withIdentifier: itemIdentifier,
        proposingTime: target.bookTime,
        rate: target.isPlaying ? target.rate : 0)
    case .listener:
      self.control.transitionToItem(withIdentifier: itemIdentifier, proposingTime: nil, rate: 0)
    }

    target.localEvents
      .sink { [weak self] event in self?.report(event) }
      .store(in: &disposeBag)
  }

  func coordinate(with session: GroupSession<ListenTogetherActivity>) {
    realCoordinator?.coordinateWithSession(session)
  }

  /// Begins a `.stallRecovery` suspension if not already suspended.
  func waitForPiece() {
    guard !isInvalidated, let target, endStallSuspension == nil else { return }
    Self.logger.info("Listen Together: stall begin at \(target.bookTime, privacy: .public)")
    endStallSuspension = control.beginStallSuspension()
  }

  /// Ends the stall suspension if the target is now ready at its current position. Called after any
  /// piece placement, load, seek or play (path 3), so no stall outlives its reason.
  func pieceBecameAvailable() {
    guard let end = endStallSuspension else { return }
    if let target, !target.isReady(at: target.bookTime) {
      Self.logger.info("Listen Together: still not ready at \(target.bookTime, privacy: .public)")
      return
    }
    Self.logger.info("Listen Together: stall end")
    endStallSuspension = nil
    end()
  }

  /// The person sharing is missing: the group waits (one suspension, kept apart from piece stalls).
  func holdForSharer() {
    guard !isInvalidated, endSharerHold == nil else { return }
    Self.logger.info("Listen Together: waiting for the sharer, group held")
    endSharerHold = control.beginStallSuspension()
  }

  /// The person sharing is back.
  func releaseSharerHold() {
    guard let end = endSharerHold else { return }
    Self.logger.info("Listen Together: the sharer is back, group released")
    endSharerHold = nil
    end()
  }

  func invalidate() {
    isInvalidated = true
    endStallSuspension?()
    endStallSuspension = nil
    endSharerHold?()
    endSharerHold = nil
    disposeBag.removeAll()
    control.transitionToItem(withIdentifier: nil, proposingTime: nil, rate: 0)
  }

  // MARK: Command handling (main actor)

  func handlePlay(itemTime: TimeInterval, rate: Float) {
    guard !isInvalidated else { return }
    target?.applyPlay(at: itemTime, rate: rate)
    pieceBecameAvailable()
  }

  /// A pause with `shouldBuffer` is also a request to buffer in anticipation of playback.
  func handlePause(itemTime: TimeInterval, shouldBuffer: Bool = false) {
    guard !isInvalidated else { return }
    target?.applyPause(at: itemTime)
    if shouldBuffer { waitIfNotReady() } else { pieceBecameAvailable() }
  }

  /// A seek with `shouldBuffer` is also a request to buffer in anticipation of playback.
  func handleSeek(itemTime: TimeInterval, shouldBuffer: Bool = false) {
    guard !isInvalidated else { return }
    target?.applySeek(to: itemTime)
    if shouldBuffer { waitIfNotReady() } else { pieceBecameAvailable() }
  }

  func handleBuffering() -> Bool {
    guard !isInvalidated, let target else { return false }
    return target.isReady(at: target.bookTime)
  }

  private func waitIfNotReady() {
    if handleBuffering() { pieceBecameAvailable() } else { waitForPiece() }
  }

  // MARK: Local changes -> coordinator

  private func report(_ event: LocalPlaybackEvent) {
    switch event {
    case .played(_, let rate):
      control.coordinateRateChange(to: rate)
    case .paused:
      control.coordinateRateChange(to: 0)
    case .seeked(let to, _):
      control.coordinateSeek(to: to)
    case .rateChanged(let rate):
      if target?.isPlaying == true { control.coordinateRateChange(to: rate) }
    }
  }
}

/// Real coordinator adapter.
@MainActor
private final class DelegatingCoordinatorControl: ListenTogetherCoordinatorControlling {
  private let coordinator: AVDelegatingPlaybackCoordinator

  init(coordinator: AVDelegatingPlaybackCoordinator) {
    self.coordinator = coordinator
  }

  func coordinateRateChange(to rate: Float) {
    coordinator.coordinateRateChange(to: rate, options: [])
  }

  func coordinateSeek(to bookTime: TimeInterval) {
    coordinator.coordinateSeek(to: CMTime(seconds: bookTime, preferredTimescale: 600), options: [])
  }

  func beginStallSuspension() -> () -> Void {
    let suspension = coordinator.beginSuspension(for: .stallRecovery)
    return { suspension.end() }
  }

  func transitionToItem(withIdentifier identifier: String?, proposingTime time: TimeInterval?, rate: Float) {
    var timebase: CMTimebase?
    if let time, time.isFinite {
      // A snapshot on the host clock: the coordinator reads its time and rate once.
      if CMTimebaseCreateWithSourceClock(
        allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr,
        let timebase
      {
        CMTimebaseSetTime(timebase, time: CMTime(seconds: max(0, time), preferredTimescale: 600))
        CMTimebaseSetRate(timebase, rate: Float64(rate))
      } else {
        timebase = nil
      }
    }
    coordinator.transitionToItem(withIdentifier: identifier, proposingInitialTimingBasedOn: timebase)
  }
}

extension ListenTogetherCoordinatorBridge: AVPlaybackCoordinatorPlaybackControlDelegate {
  /// Runs `work` on the main actor, in the order the commands were issued (M9): the main queue is FIFO,
  /// while separate `Task { @MainActor in }` hops have no ordering guarantee between them.
  nonisolated private static func onMainInOrder(_ work: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
  }

  nonisolated func playbackCoordinator(
    _ coordinator: AVDelegatingPlaybackCoordinator,
    didIssue playCommand: AVDelegatingPlaybackCoordinatorPlayCommand,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    let cmTime = playCommand.itemTime
    let time: TimeInterval? = cmTime.isNumeric ? cmTime.seconds : nil
    let rate = playCommand.rate
    let matches = playCommand.expectedCurrentItemIdentifier == itemIdentifier
    Self.onMainInOrder {
      Self.logger.info(
        "Listen Together: play command time=\(time ?? -1, privacy: .public) rate=\(rate, privacy: .public) matches=\(matches, privacy: .public)")
      if matches, let time { self.handlePlay(itemTime: time, rate: rate) }
      completionHandler()
    }
  }

  nonisolated func playbackCoordinator(
    _ coordinator: AVDelegatingPlaybackCoordinator,
    didIssue pauseCommand: AVDelegatingPlaybackCoordinatorPauseCommand,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    let matches = pauseCommand.expectedCurrentItemIdentifier == itemIdentifier
    let shouldBuffer = pauseCommand.shouldBufferInAnticipationOfPlayback
    Self.onMainInOrder {
      Self.logger.info(
        "Listen Together: pause command buffer=\(shouldBuffer, privacy: .public) matches=\(matches, privacy: .public)")
      if matches {
        // The pause command carries no time; hold at the target's own position.
        self.handlePause(itemTime: self.target?.bookTime ?? 0, shouldBuffer: shouldBuffer)
      }
      completionHandler()
    }
  }

  nonisolated func playbackCoordinator(
    _ coordinator: AVDelegatingPlaybackCoordinator,
    didIssue seekCommand: AVDelegatingPlaybackCoordinatorSeekCommand,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    let cmTime = seekCommand.itemTime
    let time: TimeInterval? = cmTime.isNumeric ? cmTime.seconds : nil
    let shouldBuffer = seekCommand.shouldBufferInAnticipationOfPlayback
    let matches = seekCommand.expectedCurrentItemIdentifier == itemIdentifier
    Self.onMainInOrder {
      Self.logger.info(
        "Listen Together: seek command time=\(time ?? -1, privacy: .public) buffer=\(shouldBuffer, privacy: .public) matches=\(matches, privacy: .public)")
      if matches, let time { self.handleSeek(itemTime: time, shouldBuffer: shouldBuffer) }
      completionHandler()
    }
  }

  nonisolated func playbackCoordinator(
    _ coordinator: AVDelegatingPlaybackCoordinator,
    didIssue bufferingCommand: AVDelegatingPlaybackCoordinatorBufferingCommand,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    let matches = bufferingCommand.expectedCurrentItemIdentifier == itemIdentifier
    Self.onMainInOrder {
      if matches, !self.handleBuffering() { self.waitForPiece() }
      completionHandler()
    }
  }
}
