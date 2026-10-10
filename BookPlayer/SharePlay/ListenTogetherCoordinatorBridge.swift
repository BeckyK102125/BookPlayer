import AVFoundation
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
}

/// Syncs one abstract "book time" timeline across a SharePlay session by routing
/// `AVDelegatingPlaybackCoordinator` commands to a `ListenTogetherPlaybackTarget`,
/// and reporting the target's local events back to the coordinator.
@MainActor
final class ListenTogetherCoordinatorBridge: NSObject {
  private weak var target: ListenTogetherPlaybackTarget?
  nonisolated let itemIdentifier: String
  private var control: ListenTogetherCoordinatorControlling!
  private var realCoordinator: AVDelegatingPlaybackCoordinator?
  private var endStallSuspension: (() -> Void)?
  private var disposeBag = Set<AnyCancellable>()

  init(
    target: ListenTogetherPlaybackTarget,
    shareID: UUID,
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
      coordinator.transitionToItem(
        withIdentifier: itemIdentifier,
        proposingInitialTimingBasedOn: nil
      )
      self.realCoordinator = coordinator
      self.control = DelegatingCoordinatorControl(coordinator: coordinator)
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
    guard endStallSuspension == nil else { return }
    endStallSuspension = control.beginStallSuspension()
  }

  /// Ends the stall suspension if the target is now ready at its current position.
  func pieceBecameAvailable() {
    guard let target, target.isReady(at: target.bookTime) else { return }
    endStallSuspension?()
    endStallSuspension = nil
  }

  func invalidate() {
    endStallSuspension?()
    endStallSuspension = nil
    disposeBag.removeAll()
    realCoordinator?.transitionToItem(
      withIdentifier: nil,
      proposingInitialTimingBasedOn: nil
    )
  }

  // MARK: Command handling (main actor)

  func handlePlay(itemTime: TimeInterval, rate: Float) {
    target?.applyPlay(at: itemTime, rate: rate)
  }

  func handlePause(itemTime: TimeInterval) {
    target?.applyPause(at: itemTime)
  }

  func handleSeek(itemTime: TimeInterval) {
    target?.applySeek(to: itemTime)
  }

  func handleBuffering() -> Bool {
    guard let target else { return false }
    return target.isReady(at: target.bookTime)
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
}

extension ListenTogetherCoordinatorBridge: AVPlaybackCoordinatorPlaybackControlDelegate {
  nonisolated func playbackCoordinator(
    _ coordinator: AVDelegatingPlaybackCoordinator,
    didIssue playCommand: AVDelegatingPlaybackCoordinatorPlayCommand,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    let time = playCommand.itemTime.seconds
    let rate = playCommand.rate
    let matches = playCommand.expectedCurrentItemIdentifier == itemIdentifier
    Task { @MainActor in
      if matches { self.handlePlay(itemTime: time, rate: rate) }
      completionHandler()
    }
  }

  nonisolated func playbackCoordinator(
    _ coordinator: AVDelegatingPlaybackCoordinator,
    didIssue pauseCommand: AVDelegatingPlaybackCoordinatorPauseCommand,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    let matches = pauseCommand.expectedCurrentItemIdentifier == itemIdentifier
    Task { @MainActor in
      if matches {
        // The pause command carries no time; hold at the target's own position.
        self.handlePause(itemTime: self.target?.bookTime ?? 0)
      }
      completionHandler()
    }
  }

  nonisolated func playbackCoordinator(
    _ coordinator: AVDelegatingPlaybackCoordinator,
    didIssue seekCommand: AVDelegatingPlaybackCoordinatorSeekCommand,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    let time = seekCommand.itemTime.seconds
    let matches = seekCommand.expectedCurrentItemIdentifier == itemIdentifier
    Task { @MainActor in
      if matches { self.handleSeek(itemTime: time) }
      completionHandler()
    }
  }

  nonisolated func playbackCoordinator(
    _ coordinator: AVDelegatingPlaybackCoordinator,
    didIssue bufferingCommand: AVDelegatingPlaybackCoordinatorBufferingCommand,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    let matches = bufferingCommand.expectedCurrentItemIdentifier == itemIdentifier
    Task { @MainActor in
      if matches, !self.handleBuffering() { self.waitForPiece() }
      completionHandler()
    }
  }
}
