import UIKit

/// SR7-06: Join closes every screen above the main view so the listener screen can be shown. An open
/// sheet (Transfer from Computer receiving files, an item's details being edited) would close without
/// a word and lose what wasn't imported or saved, so Join asks first. Cancel leaves the invitation and
/// the sheet as they are; the invitation can be answered once the work there is done.
extension MainCoordinator {
  /// True when joining would close a screen other than the player (the player cover comes back as the
  /// listener screen, so nothing is lost there). `invitationPresenter`: the screen the invitation is
  /// shown from. Test seam.
  static func joinClosesAnOpenScreen(
    invitationPresenter: UIViewController?, main: UIViewController?, isShowingPlayer: Bool
  ) -> Bool {
    guard let invitationPresenter, let main, invitationPresenter !== main else { return false }
    if isShowingPlayer, invitationPresenter === main.presentedViewController { return false }
    return true
  }

  func confirmJoinListenTogether() {
    guard let invitation = invitationController,
      Self.joinClosesAnOpenScreen(
        invitationPresenter: invitation.presentingViewController, main: mainController,
        isShowingPlayer: playerState.isShowingPlayer)
    else {
      joinListenTogether()
      return
    }
    let alert = UIAlertController(
      title: "listen_together_join_close_title".localized,
      message: "listen_together_join_close_message".localized,
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "listen_together_join_button".localized, style: .default) { [weak self] _ in
      self?.joinListenTogether()
    })
    // The cancel style is what VoiceOver's escape (two-finger scrub) triggers.
    alert.addAction(UIAlertAction(title: "cancel_button".localized, style: .cancel))
    invitation.present(alert, animated: true)
  }
}
