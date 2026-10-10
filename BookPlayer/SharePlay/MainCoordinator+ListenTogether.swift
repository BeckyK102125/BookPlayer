import BookPlayerKit
import Combine
import SwiftUI
import UIKit

/// The Listen Together invitation. It is presented with UIKit from the topmost presented screen, so an
/// open sheet (Settings, an item's details, the import screen…) can't hide or drop it. The service
/// also announces the invitation, so a VoiceOver user hears it wherever focus is.
extension MainCoordinator: UIAdaptivePresentationControllerDelegate {
  func bindListenTogether() {
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

  @discardableResult
  private func presentInvitation(title: String, author: String) -> Bool {
    guard var top = mainController, top.viewIfLoaded?.window != nil else { return false }
    while let presented = top.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
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
