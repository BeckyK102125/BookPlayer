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
  /// at `rate` (0 when paused). With nil, the coordinator assumes the item is paused at zero: that is a
  /// proposal too, not "no proposal" (Apple's documentation).
  func transitionToItem(withIdentifier identifier: String?, proposingTime time: TimeInterval?, rate: Float)
  /// Asks the coordinator to issue the group's current state for the item again, as commands.
  func reapplyCurrentItemState()
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
  private var realControl: DelegatingCoordinatorControl?
  private var endStallSuspension: (() -> Void)?
  /// A second suspension while a listener waits for the person sharing (addendum 3, decision 9).
  private var endSharerHold: (() -> Void)?
  private var endInterruptionHold: (() -> Void)?
  private var disposeBag = Set<AnyCancellable>()
  private var isInvalidated = false
  private let role: SharePlaySessionService.Role
  private var isStarted = false
  /// Listener: true once the first time-carrying coordinator command (play or seek) for this item has
  /// arrived, so the group's place is known here (round 1, I2: a pause carries no time, and the bridge
  /// would make one up from this listener's own 0). Until then nothing local is sent to the group (start-position fix C): a
  /// listener's own timeline is "paused at 0", and a play or skip from it could become the group's.
  /// Always true for the sharer, whose place is where the group starts.
  private(set) var hasGroupTiming: Bool
  /// Called once, when `hasGroupTiming` becomes true, with the group time that command carried (after
  /// it was applied).
  var onGroupTimingKnown: ((TimeInterval) -> Void)?
  /// Listener: called after every play or seek command was applied, with its group time (round 2, N2:
  /// the listener tells the sharer where it is after each, not only the first).
  var onGroupTime: ((TimeInterval) -> Void)?

  /// `role` decides the initial timing (`start(session:)`): the sharer proposes where it really is
  /// (time and rate) and then asserts that place with a coordinated seek, so the group starts there; a
  /// listener's transition proposes "paused at zero" and it adopts the group's timing from the first
  /// command.
  init(
    target: ListenTogetherPlaybackTarget,
    shareID: UUID,
    role: SharePlaySessionService.Role = .listener,
    control: ListenTogetherCoordinatorControlling? = nil
  ) {
    self.target = target
    self.itemIdentifier = shareID.uuidString
    self.role = role
    self.hasGroupTiming = role == .sharer
    super.init()

    if let control {
      self.control = control
    } else {
      let coordinator = AVDelegatingPlaybackCoordinator(playbackControlDelegate: self)
      coordinator.suspensionReasonsThatTriggerWaiting = [.stallRecovery]
      self.realCoordinator = coordinator
      let control = DelegatingCoordinatorControl(coordinator: coordinator)
      self.realControl = control
      self.control = control
    }
    target.localEvents
      .sink { [weak self] event in self?.report(event) }
      .store(in: &disposeBag)
  }

  /// Connects the coordinator to `session` first and only then makes the shared book its item, the
  /// order of Apple's "Supporting coordinated media playback" sample (start-position fix A): a
  /// proposal made before connecting was never seen by the group (the 0:00 start, build 3). The sharer
  /// then asserts its place explicitly (fix B). `session` is nil in tests. Runs once.
  func start(session: GroupSession<ListenTogetherActivity>?) {
    guard !isStarted, !isInvalidated, let target else { return }
    isStarted = true
    if let session {
      realCoordinator?.coordinateWithSession(session)
      realControl?.isConnectedToSession = true
    }
    switch role {
    case .sharer:
      control.transitionToItem(
        withIdentifier: itemIdentifier,
        proposingTime: target.bookTime,
        rate: target.isPlayingForGroup ? target.rate : 0)
      assertPosition()
    case .listener:
      control.transitionToItem(withIdentifier: itemIdentifier, proposingTime: nil, rate: 0)
    }
  }

  /// Sharer: puts the group at this device's place with a coordinated seek (and its speed when
  /// playing), an explicit group command that does not depend on how Apple treats initial proposals.
  /// Called after starting, and when someone joins before the group has been seen at that place.
  func assertPosition() {
    guard role == .sharer, isStarted, !isInvalidated, let target else { return }
    // Never while another book is loaded (its time and playing state are not the shared book's).
    guard target.canAssertPlace else {
      Self.logger.info("Listen Together: not asserting the sharer's place (the shared book isn't loaded)")
      return
    }
    Self.logger.info("Listen Together: asserting the sharer's place \(target.bookTime, privacy: .public)")
    control.coordinateSeek(to: target.bookTime)
    if target.isPlayingForGroup { control.coordinateRateChange(to: target.rate) }
  }

  /// Listener fallback (round 1): asks the coordinator to issue the group's current state again.
  func reapplyCurrentItemState() {
    guard isStarted, !isInvalidated else { return }
    Self.logger.info("Listen Together: asking the coordinator for the group's state again")
    control.reapplyCurrentItemState()
  }

  /// A coordinator command for this item arrived: the group's timing is known from now on.
  private func noteGroupTiming(at time: TimeInterval) {
    guard !hasGroupTiming else { return }
    hasGroupTiming = true
    Self.logger.info("Listen Together: the group's timing is known (\(time, privacy: .public))")
    onGroupTimingKnown?(time)
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

  /// Audio interruption holds are independent of missing pieces and sharer absence.
  func holdForInterruption() {
    guard !isInvalidated, endInterruptionHold == nil else { return }
    endInterruptionHold = control.beginStallSuspension()
  }

  func releaseInterruptionHold() {
    guard !isInvalidated, let end = endInterruptionHold else { return }
    endInterruptionHold = nil
    end()
    reapplyCurrentItemState()
  }

  func invalidate() {
    isInvalidated = true
    endInterruptionHold?()
    endInterruptionHold = nil
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
    noteGroupTiming(at: itemTime)
    if role == .listener { onGroupTime?(itemTime) }
    pieceBecameAvailable()
  }

  /// A pause with `shouldBuffer` is also a request to buffer in anticipation of playback.
  func handlePause(itemTime: TimeInterval, shouldBuffer: Bool = false) {
    guard !isInvalidated else { return }
    target?.applyPause(at: itemTime, shouldBuffer: shouldBuffer)
    if shouldBuffer { waitIfNotReady() } else { pieceBecameAvailable() }
  }

  /// A seek with `shouldBuffer` is also a request to buffer in anticipation of playback.
  func handleSeek(itemTime: TimeInterval, shouldBuffer: Bool = false) {
    guard !isInvalidated else { return }
    target?.applySeek(to: itemTime)
    noteGroupTiming(at: itemTime)
    if role == .listener { onGroupTime?(itemTime) }
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
    // Belt and braces for fix C (the listener's player already holds its actions while joining).
    if role == .listener, !hasGroupTiming {
      Self.logger.info("Listen Together: not sent, the group's timing is not known yet")
      return
    }
    switch event {
    case .played(_, let rate):
      control.coordinateRateChange(to: rate)
    case .paused:
      // A deliberate Pause must reach the group, even when local preparation is suspended.
      // Clear the hold first; commands proposed during a suspension affect only this device.
      let end = endStallSuspension
      endStallSuspension = nil
      end?()
      control.coordinateRateChange(to: 0)
    case .seeked(let to, _):
      control.coordinateSeek(to: to)
    case .rateChanged(let rate):
      if target?.isPlayingForGroup == true { control.coordinateRateChange(to: rate) }
    case .reasserted:
      // Sent from inside a coordinator command: coordinated after that command has completed (the
      // main queue is FIFO, and the command's completion handler runs in the same turn as the command).
      // The place is read then, so it is the sharer's current one (round 1 minor).
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self, !self.isInvalidated, let target = self.target, target.canAssertPlace else { return }
          Self.logger.info("Listen Together: the group was elsewhere; reasserting \(target.bookTime, privacy: .public)")
          self.control.coordinateSeek(to: target.bookTime)
        }
      }
    }
  }
}

/// Owns every suspension begun on one coordinator (build 6 fix round 1, the TSan crash).
///
/// `AVCoordinatedPlaybackSuspension.end()` only queues the end: CoreMedia finishes it later on its
/// own queue (`figTimelineCoordinator_endSuspensionOnQueue`). Releasing the coordinator right after
/// `end()` (teardown, or a test's service going away) let that queued block release a freed object
/// (SEGV in `CFRelease`). So here:
/// - each suspension ends exactly once, whichever closure or path asks first;
/// - after an end, the coordinator and the suspension are handed to `keepAliveAfterEnd`, which keeps
///   them alive until the coordinator has processed it;
/// - anything still active when the ledger goes away (its owner was released without `invalidate`)
///   is ended then, the same way, so no suspension outlives its owner unended.
/// Used on the main thread only.
final class ListenTogetherSuspensionLedger: @unchecked Sendable {
  private var active: [Int: AnyObject] = [:]
  private var nextID = 0
  private let owner: AnyObject?
  private let end: (AnyObject) -> Void
  private let keepAliveAfterEnd: ([AnyObject]) -> Void

  init(owner: AnyObject?, end: @escaping (AnyObject) -> Void, keepAliveAfterEnd: @escaping ([AnyObject]) -> Void) {
    self.owner = owner
    self.end = end
    self.keepAliveAfterEnd = keepAliveAfterEnd
  }

  deinit { endAll() }

  var activeCount: Int { active.count }

  /// Tracks `suspension`; the returned closure ends it (once; later calls do nothing).
  func track(_ suspension: AnyObject) -> () -> Void {
    let id = nextID
    nextID += 1
    active[id] = suspension
    return { [weak self] in self?.endSuspension(id) }
  }

  func endAll() {
    for id in active.keys.sorted() { endSuspension(id) }
  }

  private func endSuspension(_ id: Int) {
    guard let suspension = active.removeValue(forKey: id) else { return }
    end(suspension)
    keepAliveAfterEnd([owner, suspension].compactMap { $0 })
  }
}

/// Keeps objects alive for a while on the main queue: at least `minimum`, then until `isSettled()` or
/// `maximum`, checked every `interval`. `schedule` is a test seam.
enum ListenTogetherKeepAlive {
  static func hold(
    _ objects: [AnyObject], minimum: TimeInterval = 1, maximum: TimeInterval = 10, interval: TimeInterval = 0.25,
    isSettled: @escaping () -> Bool,
    schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
  ) {
    var waited: TimeInterval = 0
    func check() {
      if waited >= maximum || (waited >= minimum && isSettled()) {
        withExtendedLifetime(objects) {}
        return
      }
      waited += interval
      schedule(interval) { check() }
    }
    schedule(0) { check() }
  }
}

/// Real coordinator adapter.
@MainActor
private final class DelegatingCoordinatorControl: ListenTogetherCoordinatorControlling {
  private let coordinator: AVDelegatingPlaybackCoordinator
  private let suspensions: ListenTogetherSuspensionLedger
  /// Suspensions only mean something to a coordinator connected to a group session. Ending one on a
  /// coordinator that never was (tests; a session-less bridge) crashed inside CoreMedia
  /// (`figTimelineCoordinator_endSuspensionOnQueue`, SEGV in `CFRelease`, build 6 fix round 1), so
  /// none is begun then.
  var isConnectedToSession = false

  init(coordinator: AVDelegatingPlaybackCoordinator) {
    self.coordinator = coordinator
    self.suspensions = ListenTogetherSuspensionLedger(
      owner: coordinator,
      end: { ($0 as? AVCoordinatedPlaybackSuspension)?.end() },
      keepAliveAfterEnd: { [weak coordinator] objects in
        ListenTogetherKeepAlive.hold(objects, isSettled: { coordinator?.suspensionReasons.isEmpty ?? true })
      })
  }

  func coordinateRateChange(to rate: Float) {
    coordinator.coordinateRateChange(to: rate, options: [])
  }

  func coordinateSeek(to bookTime: TimeInterval) {
    coordinator.coordinateSeek(to: CMTime(seconds: bookTime, preferredTimescale: 600), options: [])
  }

  func beginStallSuspension() -> () -> Void {
    guard isConnectedToSession else { return {} }
    return suspensions.track(coordinator.beginSuspension(for: .stallRecovery))
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

  func reapplyCurrentItemState() {
    coordinator.reapplyCurrentItemStateToPlaybackControlDelegate()
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
