import BookPlayerKit
import Combine
import UIKit

enum ListenTogetherAppState: String {
  case active
  case inactive
  case background
}

/// The parts of the app that keep the sharer sending (addendum 3, decision 6): the idle timer,
/// background tasks and the app's state. A protocol so tests can check that every background task is
/// ended and the idle timer is restored.
@MainActor
protocol ListenTogetherAppSystem: AnyObject {
  var appState: ListenTogetherAppState { get }
  var appStateChanges: AnyPublisher<ListenTogetherAppState, Never> { get }
  var isIdleTimerDisabled: Bool { get set }
  func beginBackgroundTask(
    named name: String, expirationHandler: @escaping @MainActor () -> Void
  ) -> UIBackgroundTaskIdentifier
  func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

/// The real app.
@MainActor
final class UIKitListenTogetherAppSystem: ListenTogetherAppSystem {
  var appState: ListenTogetherAppState {
    switch UIApplication.shared.applicationState {
    case .active: return .active
    case .inactive: return .inactive
    case .background: return .background
    @unknown default: return .inactive
    }
  }

  var appStateChanges: AnyPublisher<ListenTogetherAppState, Never> {
    let center = NotificationCenter.default
    return Publishers.MergeMany(
      center.publisher(for: UIApplication.didBecomeActiveNotification).map { _ in ListenTogetherAppState.active },
      center.publisher(for: UIApplication.willResignActiveNotification).map { _ in .inactive },
      center.publisher(for: UIApplication.didEnterBackgroundNotification).map { _ in .background })
    .receive(on: DispatchQueue.main)
    .eraseToAnyPublisher()
  }

  var isIdleTimerDisabled: Bool {
    get { UIApplication.shared.isIdleTimerDisabled }
    set { UIApplication.shared.isIdleTimerDisabled = newValue }
  }

  func beginBackgroundTask(
    named name: String, expirationHandler: @escaping @MainActor () -> Void
  ) -> UIBackgroundTaskIdentifier {
    UIApplication.shared.beginBackgroundTask(withName: name) {
      // Called on the main thread.
      MainActor.assumeIsolated { expirationHandler() }
    }
  }

  func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
    UIApplication.shared.endBackgroundTask(identifier)
  }
}

/// One background task around one piece's export and upload. `end()` is safe to call more than once
/// (the `.invalid` sentinel): it is called when the work ends on every path (success, error,
/// cancellation) and by the expiration handler, whichever comes first.
@MainActor
final class ListenTogetherBackgroundTask {
  private let system: ListenTogetherAppSystem
  private var identifier: UIBackgroundTaskIdentifier = .invalid

  /// `onExpire` runs when the system's background time runs out, after the task has ended.
  init(system: ListenTogetherAppSystem, name: String, onExpire: (@MainActor () -> Void)? = nil) {
    self.system = system
    identifier = system.beginBackgroundTask(named: name) { [weak self] in
      SharePlaySessionService.logger.info("Listen Together: background time ran out (\(name, privacy: .public))")
      self?.end()
      onExpire?()
    }
  }

  func end() {
    guard identifier != .invalid else { return }
    let ending = identifier
    identifier = .invalid
    system.endBackgroundTask(ending)
  }
}
