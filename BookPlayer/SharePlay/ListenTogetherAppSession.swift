import Foundation

/// SR7-02: one Listen Together session per app process, however many windows are open.
///
/// Every window (scene) gets its own MainCoordinator. Before this, each one made its own
/// SharePlaySessionService, and a second window's start removed the running session's files and took
/// over the lock screen controls and Siri routing with an idle service. Now the first window makes the
/// service and starts it once; later windows share it. One window at a time shows the Listen Together
/// screens (invitation, alerts, the "play your own book?" question): the first one, and when it closes,
/// the next window that becomes active.
@MainActor
final class ListenTogetherAppSession {
  static let shared = ListenTogetherAppSession()

  private(set) var service: SharePlaySessionService?
  private var isStarted = false
  private weak var uiOwner: AnyObject?
  private let cleanStorage: @MainActor () -> Void
  private let start: @MainActor (SharePlaySessionService) -> Void

  init(
    cleanStorage: @escaping @MainActor () -> Void = { ShareStorage().cleanAll() },
    start: @escaping @MainActor (SharePlaySessionService) -> Void = { @MainActor service in
      service.startObservingSessions()
      // Lock screen, Control Center and AirPods control the shared book during a listener session.
      ListenTogetherRemoteCommands.shared.attach(to: service)
      // Fork audit A17: Siri and Shortcuts address the shared book during a session.
      ListenTogetherIntentRouting.service = service
    }
  ) {
    self.cleanStorage = cleanStorage
    self.start = start
  }

  /// The app's one service; `make` runs only the first time.
  func service(make: () -> SharePlaySessionService) -> SharePlaySessionService {
    if let service { return service }
    let service = make()
    self.service = service
    return service
  }

  /// Once per process: removes files left by an earlier launch (no session survives a relaunch), then
  /// starts watching for sessions. Later calls do nothing, so a new window never touches a running
  /// session's files.
  func startOnce() {
    guard !isStarted, let service else { return }
    isStarted = true
    cleanStorage()
    start(service)
  }

  /// Whether `owner` shows the Listen Together screens. It becomes the owner when no open window is.
  func claimUI(for owner: AnyObject) -> Bool {
    if uiOwner == nil { uiOwner = owner }
    return uiOwner === owner
  }

  /// `owner`'s window closed: the next window that becomes active takes over.
  func releaseUI(for owner: AnyObject) {
    if uiOwner === owner { uiOwner = nil }
  }
}

extension MainCoordinator {
  /// SR7-02: one window shows the Listen Together screens. This one takes over if none does (it is the
  /// first window, or the one that showed them has closed). Called at start and when the window
  /// becomes active.
  func claimListenTogetherUIIfFree() {
    guard listenTogetherSubscription == nil, ListenTogetherAppSession.shared.claimUI(for: self) else { return }
    bindListenTogether()
  }

  /// This window is closing: another window takes over the Listen Together screens when it becomes active.
  func releaseListenTogetherUI() {
    ListenTogetherAppSession.shared.releaseUI(for: self)
    listenTogetherSubscription = nil
    needsCopySubscription = nil
    needsCopyActiveSubscription = nil
    listenTogetherAlertSubscriptions.removeAll()
  }
}
