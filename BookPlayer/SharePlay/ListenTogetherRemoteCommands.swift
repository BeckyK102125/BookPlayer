import BookPlayerKit
import Combine
import Foundation
import MediaPlayer
import UIKit

/// The remote-command settings Listen Together changes while this device is a listener. Seam for
/// tests; the app uses `SystemRemoteCommandSettings`. Changing these is not adding targets: the
/// targets stay the ones wired once in `AppDelegate.setupMPRemoteCommands()`.
@MainActor
protocol ListenTogetherCommandSettings: AnyObject {
  var skipForwardIntervals: [NSNumber] { get set }
  var skipBackwardIntervals: [NSNumber] { get set }
  var isSkipForwardEnabled: Bool { get set }
  var isSkipBackwardEnabled: Bool { get set }
  var isChangePositionEnabled: Bool { get set }
}

@MainActor
final class SystemRemoteCommandSettings: ListenTogetherCommandSettings {
  private var center: MPRemoteCommandCenter { MPRemoteCommandCenter.shared() }

  var skipForwardIntervals: [NSNumber] {
    get { center.skipForwardCommand.preferredIntervals }
    set { center.skipForwardCommand.preferredIntervals = newValue }
  }
  var skipBackwardIntervals: [NSNumber] {
    get { center.skipBackwardCommand.preferredIntervals }
    set { center.skipBackwardCommand.preferredIntervals = newValue }
  }
  var isSkipForwardEnabled: Bool {
    get { center.skipForwardCommand.isEnabled }
    set { center.skipForwardCommand.isEnabled = newValue }
  }
  var isSkipBackwardEnabled: Bool {
    get { center.skipBackwardCommand.isEnabled }
    set { center.skipBackwardCommand.isEnabled = newValue }
  }
  var isChangePositionEnabled: Bool {
    get { center.changePlaybackPositionCommand.isEnabled }
    set { center.changePlaybackPositionCommand.isEnabled = newValue }
  }
}

/// The user's own skip and position settings, read live when a listener session ends.
struct UserRemoteCommandSettings: Equatable {
  var forwardInterval: TimeInterval
  var rewindInterval: TimeInterval
  var isForwardChapterSkip: Bool
  var isRewindChapterSkip: Bool
  var isSeekBarEnabled: Bool

  /// What `AppDelegate.setupMPSkipRemoteCommands()` and `setupChangePlaybackPositionCommand()` apply.
  @MainActor
  static func current() -> UserRemoteCommandSettings {
    UserRemoteCommandSettings(
      forwardInterval: PlayerManager.forwardInterval,
      rewindInterval: PlayerManager.rewindInterval,
      isForwardChapterSkip: PlayerManager.isForwardChapterSkip,
      isRewindChapterSkip: PlayerManager.isRewindChapterSkip,
      isSeekBarEnabled: UserDefaults.standard.bool(forKey: Constants.UserDefaults.seekProgressBarEnabled))
  }
}

/// Routes the lock screen, Control Center, AirPods and headset commands to the shared book while this
/// device is a Listen Together listener. Each `AppDelegate` remote-command handler asks `handle(_:)`
/// first; nil means "not handled" and the existing PlayerManager path runs unchanged.
///
/// The sharer needs no routing: the sharer's session player is PlayerManager itself.
@MainActor
final class ListenTogetherRemoteCommands {
  enum Command: Equatable {
    case togglePlayPause
    case play
    case pause
    case skipForward
    case skipBackward
    case nextTrack
    case previousTrack
    /// A book-level position (the lock screen shows book time during a listener session).
    case changePosition(TimeInterval)
  }

  /// Set by MainCoordinator once the session service exists.
  static let shared = ListenTogetherRemoteCommands()

  /// The listener's fixed skip.
  static let skipInterval: TimeInterval = 30
  /// Burst of position events (scrubbing, repeated VoiceOver adjusts) is applied once, after this.
  static let positionSettleDelay: Duration = .milliseconds(300)

  private(set) weak var service: SharePlaySessionService?
  private let settings: ListenTogetherCommandSettings
  let nowPlaying: ListenTogetherNowPlayingPublisher
  private let nowPlayingSink: ListenTogetherNowPlayingSink
  /// Runs `action` once position events have settled. Test seam (tests run it by hand).
  private let schedulePositionApply: (@escaping @MainActor () -> Void) -> Void
  private var pendingPosition: TimeInterval?
  private var positionGeneration = 0
  private let userSettings: @MainActor () -> UserRemoteCommandSettings
  private var isActive = false
  private var bag = Set<AnyCancellable>()

  init(
    settings: ListenTogetherCommandSettings? = nil,
    nowPlayingSink: ListenTogetherNowPlayingSink? = nil,
    now: @escaping () -> Date = Date.init,
    userSettings: (@MainActor () -> UserRemoteCommandSettings)? = nil,
    schedulePositionApply: ((@escaping @MainActor () -> Void) -> Void)? = nil
  ) {
    // Built here rather than as default arguments, which would run outside the main actor.
    self.settings = settings ?? SystemRemoteCommandSettings()
    self.userSettings = userSettings ?? { UserRemoteCommandSettings.current() }
    let sink = nowPlayingSink ?? SystemNowPlayingSink()
    self.nowPlayingSink = sink
    self.nowPlaying = ListenTogetherNowPlayingPublisher(sink: sink, now: now)
    self.schedulePositionApply = schedulePositionApply ?? { action in
      Task { @MainActor in
        try? await Task.sleep(for: Self.positionSettleDelay)
        action()
      }
    }
  }

  /// Follows `service`: listener sessions switch the skip settings and Now Playing over to the shared
  /// book, and give them back when they end.
  func attach(to service: SharePlaySessionService) {
    bag.removeAll()
    self.service = service
    // The emitted values, not the properties: @Published emits before the property is stored.
    service.$state
      .sink { [weak self] state in
        MainActor.assumeIsolated { self?.stateChanged(to: state) }
      }
      .store(in: &bag)
    service.$listener
      .sink { [weak self] listener in
        MainActor.assumeIsolated { self?.nowPlaying.observe(listener) }
      }
      .store(in: &bag)
    // A skip setting changed during the session (PlayerManager's setters write the command centre
    // directly) would make the lock screen advertise the user's interval while the router skips 30 s.
    // The lock screen and Control Center are only visible once the app has resigned active, and the
    // settings can only change while it is active, so re-applying here keeps label and action equal.
    NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
      .sink { [weak self] _ in
        MainActor.assumeIsolated { self?.reapplySessionSettings() }
      }
      .store(in: &bag)
  }

  /// Entry point for AppDelegate's MediaPlayer handlers and Magic Tap. They are closures and an
  /// override formed in the MainActor AppDelegate, but MediaPlayer does not declare which thread it
  /// calls them on, so the main-actor assumption is made explicit here: on the main thread the command
  /// is handled directly; anywhere else it is handled on the main queue first (never a data race).
  nonisolated static func route(_ command: Command) -> MPRemoteCommandHandlerStatus? {
    onMain { shared.handle(command) }
  }

  /// `isRouting`, read on the main actor (see `route(_:)`).
  nonisolated static var isRoutingNow: Bool {
    onMain { shared.isRouting }
  }

  private nonisolated static func onMain<T: Sendable>(_ work: @MainActor @Sendable () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated(work) }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
  }

  /// True while remote commands go to the shared book.
  var isRouting: Bool {
    guard let service, case .listening = service.state else { return false }
    return true
  }

  /// Handles `command` for the shared book during a listener session. Returns nil (not handled)
  /// otherwise, so the caller runs its PlayerManager path. Never touches PlayerManager.
  func handle(_ command: Command) -> MPRemoteCommandHandlerStatus? {
    guard isRouting, let service else { return nil }
    // Joined, but the book details have not arrived: nothing to play yet. Saying so (rather than
    // `.success`) avoids a silent failure; the user's own paused book must not start either.
    guard let listener = service.listener else { return .noActionableNowPlayingItem }
    switch command {
    case .togglePlayPause:
      listener.userTogglePlay()
    case .play:
      // Idempotent: a repeated Play must not pause.
      if !listener.isPlaying { listener.userTogglePlay() }
    case .pause:
      if listener.isPlaying { listener.userTogglePlay() }
    case .skipForward:
      listener.userSkip(by: Self.skipInterval)
    case .skipBackward:
      listener.userSkip(by: -Self.skipInterval)
    case .nextTrack:
      // R33: the app's own mapping (next = forward); a chapter jump is too far for an accidental press.
      listener.userSkip(by: Self.skipInterval)
    case .previousTrack:
      listener.userSkip(by: -Self.skipInterval)
    case .changePosition(let position):
      schedulePosition(position)
    }
    return .success
  }

  // MARK: Position

  private func schedulePosition(_ position: TimeInterval) {
    pendingPosition = position
    positionGeneration += 1
    let generation = positionGeneration
    schedulePositionApply { [weak self] in
      guard let self, self.positionGeneration == generation, let position = self.pendingPosition else { return }
      self.pendingPosition = nil
      // The session may have ended meanwhile.
      guard self.isRouting, let listener = self.service?.listener else { return }
      listener.userJump(to: position)
    }
  }

  // MARK: Session start and end

  private func stateChanged(to state: ListenTogetherState) {
    if case .listening = state {
      if !isActive { activate() }
    } else if isActive {
      deactivate()
    }
  }

  /// Advertise the listener's 30 second skips (the label VoiceOver speaks for the lock-screen
  /// buttons) and an adjustable position control, and take over Now Playing.
  private func activate() {
    isActive = true
    reapplySessionSettings()
    nowPlaying.start(gettingBookTitle: service?.joinedTitle)
    nowPlaying.observe(service?.listener)
  }

  /// Sets the session's skip and position settings again. Internal for tests.
  func reapplySessionSettings() {
    guard isActive else { return }
    let interval = [NSNumber(value: Self.skipInterval)]
    settings.skipForwardIntervals = interval
    settings.skipBackwardIntervals = interval
    settings.isSkipForwardEnabled = true
    settings.isSkipBackwardEnabled = true
    settings.isChangePositionEnabled = true
  }

  /// Runs as the session's state leaves `.listening`, after the listener has been stopped.
  private func deactivate() {
    isActive = false
    pendingPosition = nil
    positionGeneration += 1
    nowPlaying.stop()
    handNowPlayingBack()
    restoreUserSettings()
  }

  /// The user's settings as they are now (not as they were at the start), applied the way AppDelegate
  /// applies them at launch.
  private func restoreUserSettings() {
    let user = userSettings()
    settings.isSkipForwardEnabled = !user.isForwardChapterSkip
    if !user.isForwardChapterSkip { settings.skipForwardIntervals = [NSNumber(value: user.forwardInterval)] }
    settings.isSkipBackwardEnabled = !user.isRewindChapterSkip
    if !user.isRewindChapterSkip { settings.skipBackwardIntervals = [NSNumber(value: user.rewindInterval)] }
    settings.isChangePositionEnabled = user.isSeekBarEnabled
  }

  /// The shared book must not stay on the lock screen. PlayerManagerProtocol has no "publish your Now
  /// Playing info" call, but `pause()` re-publishes the paused book's info (rate 0, `.paused`) without
  /// any other effect on an already paused book. With no book loaded, the info is cleared.
  private func handNowPlayingBack() {
    guard let playerManager = service?.playerManager else {
      nowPlayingSink.publish(nil, playbackState: .stopped)
      return
    }
    if playerManager.currentItem == nil {
      nowPlayingSink.publish(nil, playbackState: .stopped)
    } else if !playerManager.isPlaying {
      playerManager.pause()
    }
    // Playing (not expected: it was paused on Join): PlayerManager publishes on its next tick.
  }
}
