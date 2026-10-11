import BookPlayerKit
import Foundation

/// The Listen Together status line: what the banner shows and what VoiceOver reads for each state.
enum ListenTogetherStatus {
  /// The text on screen; nil when no banner is shown.
  static func visibleText(for state: ListenTogetherState) -> String? {
    switch state {
    case .preparing(let title):
      return String.localizedStringWithFormat("listen_together_status_preparing".localized, title)
    case .sharing(let participants):
      return participants <= 1
        ? "listen_together_status_sharing_waiting".localized
        : String.localizedStringWithFormat("listen_together_status_sharing".localized, participants)
    case .listening(let participants, let downloaded):
      if downloaded < 1 {
        return downloadingText(percent: Int((downloaded * 100).rounded(.down)))
      }
      return participants <= 1
        ? "listen_together_status_listening_one".localized
        : String.localizedStringWithFormat("listen_together_status_listening".localized, participants)
    case .ended(.normal):
      return "listen_together_ended".localized
    case .ended(.sendFailed):
      return "listen_together_send_failed".localized
    case .ended(.unavailable):
      return "listen_together_unavailable".localized
    case .idle, .needsFaceTime, .invitation:
      return nil
    }
  }

  /// What VoiceOver reads. The download percent moves in 25 percent steps, in step with the
  /// announcer, so the label does not change on every piece.
  static func spokenText(for state: ListenTogetherState) -> String? {
    if case .listening(_, let downloaded) = state, downloaded < 1 {
      return downloadingText(percent: Int((downloaded * 4).rounded(.down)) * 25)
    }
    return visibleText(for: state)
  }

  /// The End button's hint; nil when there is nothing to end. A listener playing their own copy hears
  /// that it is kept (nothing was downloaded, so nothing is deleted).
  static func endHint(for state: ListenTogetherState, usesOwnCopy: Bool = false) -> String? {
    switch state {
    case .preparing: return "listen_together_end_hint_preparing".localized
    case .sharing: return "listen_together_end_hint_sharer".localized
    case .listening:
      return usesOwnCopy
        ? "listen_together_end_hint_listener_own_copy".localized
        : "listen_together_end_hint_listener".localized
    case .idle, .needsFaceTime, .invitation, .ended: return nil
    }
  }

  static func isProblem(_ state: ListenTogetherState) -> Bool {
    state == .ended(reason: .sendFailed) || state == .ended(reason: .unavailable)
  }

  private static func downloadingText(percent: Int) -> String {
    String.localizedStringWithFormat("listen_together_status_downloading".localized, percent)
  }
}
