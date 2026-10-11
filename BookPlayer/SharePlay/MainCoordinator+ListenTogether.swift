import BookPlayerKit
import Combine
import GroupActivities
import SwiftUI
import UIKit

/// The Listen Together invitation. It is presented with UIKit from the topmost presented screen, so an
/// open sheet (Settings, an item's details, the import screen…) can't hide or drop it. The service
/// also announces the invitation, so a VoiceOver user hears it wherever focus is.
extension MainCoordinator: UIAdaptivePresentationControllerDelegate {
  func bindListenTogether() {
    sharePlayService.sharingSheetPresenter = self
    listenTogetherSubscription = sharePlayService.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        MainActor.assumeIsolated { self?.listenTogetherStateChanged(state) }
      }
  }

  private func listenTogetherStateChanged(_ state: ListenTogetherState) {
    if case .invitation(let title, let author) = state {
      guard invitationController == nil else { return }
      presentInvitation(title: title, author: author)
    } else if let controller = invitationController {
      // Declined, joined or the share went away.
      invitationController = nil
      controller.presentingViewController?.dismiss(animated: true)
    }
  }

  /// Whether an invitation that disappeared without an answer should be shown again. Test seam.
  nonisolated static func shouldRepresentInvitation(answered: Bool, state: ListenTogetherState) -> Bool {
    guard !answered, case .invitation = state else { return false }
    return true
  }

  /// The invitation left the screen. If that was not the user answering (something beneath it was
  /// closed and UIKit took it down too), show it again once the dismissal has finished.
  private func invitationDisappeared(_ host: UIViewController) {
    // Answering (Join, Not Now, swipe, state change) clears `invitationController` first.
    let answered = host !== invitationController
    if !answered { invitationController = nil }
    DispatchQueue.main.async { [weak self] in
      guard let self,
        Self.shouldRepresentInvitation(answered: answered, state: self.sharePlayService.state),
        self.invitationController == nil,
        case .invitation(let title, let author) = self.sharePlayService.state
      else { return }
      // Nowhere to show it: decline rather than leave the service waiting forever.
      if !self.presentInvitation(title: title, author: author) {
        self.sharePlayService.declineInvitation()
      }
    }
  }

  /// The topmost screen that is not on its way out: the invitation and the sharing sheet are shown
  /// from it, so an open sheet (Settings, an item's details, the player…) can't hide or drop them.
  private func topmostPresenter() -> UIViewController? {
    guard var top = mainController, top.viewIfLoaded?.window != nil else { return nil }
    while let presented = top.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }

  @discardableResult
  private func presentInvitation(title: String, author: String) -> Bool {
    guard let top = topmostPresenter() else { return false }
    let view = ListenTogetherInvitationView(
      title: title,
      author: author,
      onJoin: { [weak self] in self?.joinListenTogether() },
      onDecline: { [weak self] in self?.sharePlayService.declineInvitation() }
    )
    .environmentObject(ThemeViewModel())
    let host = ListenTogetherInvitationHostingController(rootView: AnyView(view))
    host.onDisappear = { [weak self, weak host] in
      guard let self, let host else { return }
      self.invitationDisappeared(host)
    }
    host.modalPresentationStyle = .pageSheet
    if let sheet = host.sheetPresentationController {
      let isAccessibilitySize = UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory
      sheet.detents = isAccessibilitySize ? [.large()] : [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    host.presentationController?.delegate = self
    invitationController = host
    top.present(host, animated: true)
    return true
  }

  /// Joins, then clears every screen above the main view so the listener screen can be presented.
  private func joinListenTogether() {
    let invitation = invitationController
    invitationController = nil
    sharePlayService.joinInvitation()
    guard let mainController else { return }
    if playerState.isShowingPlayer {
      // The player cover is SwiftUI's: close it through its state once the invitation has gone.
      invitation?.presentingViewController?.dismiss(animated: true) { [weak self] in
        self?.playerState.isShowingPlayer = false
      }
    } else if mainController.presentedViewController != nil {
      mainController.dismiss(animated: true)
    }
  }

  /// Swiping the invitation away counts as Not Now.
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    // `viewDidDisappear` already ran (and cleared `invitationController`); its re-present check runs on
    // the next main-loop turn, after this decline, so it sees the state has left `.invitation`.
    guard presentationController.presentedViewController is ListenTogetherInvitationHostingController
    else { return }
    invitationController = nil
    if sharePlayService.hasPendingInvitation { sharePlayService.declineInvitation() }
  }
}

// MARK: Sharing sheet (Change B: start from Messages)

extension MainCoordinator: ListenTogetherSharingSheetPresenting {
  var canPresentSharingSheet: Bool { mainController?.viewIfLoaded?.window != nil }

  /// Apple's `GroupActivitySharingController`, shown when there is no FaceTime call. It is presented
  /// silently (it announces itself); the service announces what happens after it closes.
  func presentSharingSheet(for activity: ListenTogetherActivity) async -> ListenTogetherSharingSheetOutcome {
    // Let the More menu (or the first-share note) finish closing first; presenting over a closing
    // alert can fail without any sign, and a VoiceOver user would get no cue at all.
    try? await Task.sleep(for: .milliseconds(600))
    guard let top = topmostPresenter() else { return .unavailable }
    let controller: GroupActivitySharingController
    do {
      controller = try GroupActivitySharingController(activity)
    } catch {
      SharePlaySessionService.logger.error(
        "Listen Together: could not create the sharing sheet: \(error.localizedDescription)")
      return .unavailable
    }
    top.present(controller, animated: true)
    // UIKit refused the presentation (something else is being presented): use the fallback alert.
    // VERIFY on device that a refused presentation leaves `presentingViewController` nil.
    guard controller.presentingViewController != nil else { return .unavailable }
    let outcome = await ListenTogetherSharingSheetWatch.outcome(of: controller)
    // The sheet normally closes itself; make sure it is gone before anything is announced.
    if controller.presentingViewController != nil, !controller.isBeingDismissed {
      controller.dismiss(animated: true)
    }
    return outcome
  }
}

/// Waits for the sharing sheet's `result`, but does not wait forever: if the sheet has left the screen
/// (checked every second, and again when the app comes back to the foreground) without reporting a
/// result, the outcome is `.abandoned`, so the pending share is released (B2.7, R37).
@MainActor
final class ListenTogetherSharingSheetWatch {
  private var continuation: CheckedContinuation<ListenTogetherSharingSheetOutcome, Never>?
  private var foregroundObserver: NSObjectProtocol?
  private var tasks: [Task<Void, Never>] = []

  private init() {}

  static func outcome(of controller: GroupActivitySharingController) async -> ListenTogetherSharingSheetOutcome {
    let watch = ListenTogetherSharingSheetWatch()
    let outcome = await withCheckedContinuation { continuation in
      watch.start(controller, continuation: continuation)
    }
    // The tasks hold the watch weakly; keep it alive until it has finished.
    withExtendedLifetime(watch) {}
    return outcome
  }

  private func start(
    _ controller: GroupActivitySharingController,
    continuation: CheckedContinuation<ListenTogetherSharingSheetOutcome, Never>
  ) {
    self.continuation = continuation
    tasks.append(Task { [weak self] in
      let result = await controller.result
      self?.finish(result == .success ? .sent : .cancelled)
    })
    tasks.append(Task { [weak self, weak controller] in
      var goneChecks = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, self.continuation != nil else { return }
        // Two checks in a row, so a result that arrives just after the sheet closes still wins.
        goneChecks = Self.isGone(controller) ? goneChecks + 1 : 0
        if goneChecks >= 2 { self.finish(.abandoned) }
      }
    })
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self, weak controller] _ in
      MainActor.assumeIsolated {
        // Give UIKit a moment to restore the screen, then check once.
        self?.tasks.append(Task { [weak self, weak controller] in
          try? await Task.sleep(for: .seconds(1))
          if Self.isGone(controller) { self?.finish(.abandoned) }
        })
      }
    }
  }

  private static func isGone(_ controller: UIViewController?) -> Bool {
    guard let controller else { return true }
    return controller.presentingViewController == nil && !controller.isBeingPresented
  }

  private func finish(_ outcome: ListenTogetherSharingSheetOutcome) {
    guard let continuation else { return }
    self.continuation = nil
    if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    foregroundObserver = nil
    tasks.forEach { $0.cancel() }
    tasks = []
    continuation.resume(returning: outcome)
  }
}

/// Reports when the invitation has left the screen for any reason (including a screen beneath it
/// being closed, which takes it down without `presentationControllerDidDismiss`).
final class ListenTogetherInvitationHostingController: UIHostingController<AnyView> {
  var onDisappear: (() -> Void)?

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Still presented means something was put over it, not that it went away.
    if presentingViewController == nil || isBeingDismissed { onDisappear?() }
  }
}
