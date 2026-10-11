import BookPlayerKit
import Foundation

/// What the status line needs besides the session state (addendum 3).
struct ListenTogetherStatusConditions: Equatable {
  var notice: ListenTogetherNotice?
  /// The person sharing left the roster: the group is paused for at most a minute.
  var isSharerGraceRunning = false
  /// Listener: the group waits for a piece this device doesn't have yet.
  var isWaitingForPiece = false
  /// Listener: the book is playing here.
  var isListenerPlaying = false
  /// Someone else paused the group (until the next play).
  var isPausedByOther = false
  /// Sharer: someone couldn't join (no copy).
  var someoneDeclined = false
  /// Listener: the group's timing is not known yet; Play and the skips do nothing ("Joining…").
  var isJoiningGroup = false
}

/// One status line in the banner: a first line, an optional second line, what VoiceOver reads and the
/// icon. The text carries the meaning; the icon is decoration (hidden from VoiceOver).
struct ListenTogetherStatusLine: Equatable {
  enum Icon: Equatable {
    case shareplay
    case hourglass
    case warning

    var systemName: String {
      switch self {
      case .shareplay: return "shareplay"
      case .hourglass: return "hourglass"
      case .warning: return "exclamationmark.triangle"
      }
    }
  }

  var text: String
  var detail: String?
  var spoken: String
  var icon: Icon
}

/// The Listen Together status line: what the banner shows and what VoiceOver reads for each state.
enum ListenTogetherStatus {
  /// The base text on screen for `state` alone; nil when no banner is shown. Endings caused by someone
  /// else (and "isn't available") are centred alerts instead (R41), so they have no banner text.
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
      // The person's own End (E15): the short ended banner stays.
      return "listen_together_ended".localized
    case .ended(.prepareFailed), .ended(.unavailable), .ended(.sharerEnded), .ended(.sharerLeft),
      .ended(.sharerCouldNotPrepare), .ended(.connectionEnded), .ended(.left), .ended(.ownCopyFailed):
      return nil
    case .idle, .needsFaceTime, .invitation:
      return nil
    }
  }

  /// What VoiceOver reads for `state` alone. The download percent moves in 25 percent steps, in step
  /// with the announcer, so the label does not change on every piece.
  static func spokenText(for state: ListenTogetherState) -> String? {
    if case .listening(_, let downloaded) = state, downloaded < 1 {
      return downloadingText(percent: Int((downloaded * 4).rounded(.down)) * 25)
    }
    return visibleText(for: state)
  }

  /// The full status line (guidance A.1, C). Priorities: listener, the person sharing out of the session
  /// (the grace), then waiting for a piece, then the person sharing quiet, then paused by another
  /// listener; sharer, retrying a piece, then paused by another listener. "Someone couldn't join" is a
  /// second line under the sharer's status.
  static func line(
    for state: ListenTogetherState, conditions: ListenTogetherStatusConditions = .init()
  ) -> ListenTogetherStatusLine? {
    guard let base = visibleText(for: state) else { return nil }
    let baseSpoken = spokenText(for: state) ?? base
    switch state {
    case .listening(_, let downloaded):
      if conditions.isSharerGraceRunning {
        let text = "listen_together_waiting_for_sharer".localized
        let detail = "listen_together_waiting_for_sharer_detail".localized
        return ListenTogetherStatusLine(text: text, detail: detail, spoken: joined(text, detail), icon: .hourglass)
      }
      if conditions.isWaitingForPiece {
        let text = "listen_together_waiting_download".localized
        // While the book is still arriving, the percent stays visible under it.
        let detail = downloaded < 1 ? base : nil
        let spokenDetail = downloaded < 1 ? baseSpoken : nil
        return ListenTogetherStatusLine(text: text, detail: detail, spoken: joined(text, spokenDetail), icon: .hourglass)
      }
      if conditions.isJoiningGroup {
        // Start-position fix C: why Play does nothing yet. The percent stays visible under it.
        let text = "listen_together_joining".localized
        let detail = downloaded < 1 ? base : nil
        let spokenDetail = downloaded < 1 ? baseSpoken : nil
        return ListenTogetherStatusLine(text: text, detail: detail, spoken: joined(text, spokenDetail), icon: .hourglass)
      }
      if conditions.notice == .waitingForSharer, conditions.isListenerPlaying {
        // Silence only (a11y I4): the book keeps playing, so this is not "waiting"; nothing is announced.
        // Not before the manifest or while paused: "Getting the book" / the normal line stay (M2).
        let text = "listen_together_sharer_quiet".localized
        return ListenTogetherStatusLine(text: text, detail: nil, spoken: text, icon: .hourglass)
      }
      if conditions.isPausedByOther {
        let text = "listen_together_status_paused_by_other".localized
        return ListenTogetherStatusLine(text: text, detail: base, spoken: joined(text, baseSpoken), icon: .shareplay)
      }
    case .sharing:
      let declined = conditions.someoneDeclined ? "listen_together_declined_no_copy".localized : nil
      if conditions.notice == .retryingSend {
        let text = "listen_together_send_failed".localized
        return ListenTogetherStatusLine(text: text, detail: declined, spoken: joined(text, declined), icon: .warning)
      }
      if conditions.isPausedByOther {
        let text = "listen_together_status_paused_by_other".localized
        let detail = declined ?? base
        return ListenTogetherStatusLine(text: text, detail: detail, spoken: joined(text, detail), icon: .shareplay)
      }
      return ListenTogetherStatusLine(text: base, detail: declined, spoken: joined(baseSpoken, declined), icon: .shareplay)
    default:
      break
    }
    return ListenTogetherStatusLine(text: base, detail: nil, spoken: baseSpoken, icon: .shareplay)
  }

  /// The short reason under the listener's play controls, for Zoom (C.1, C.2): hidden from VoiceOver
  /// (the banner and the play button's value carry it). Also the play button's value. Nil when
  /// playback isn't held.
  static func waitingCaption(_ conditions: ListenTogetherStatusConditions) -> String? {
    if conditions.isSharerGraceRunning { return "listen_together_waiting_for_sharer".localized }
    if conditions.isWaitingForPiece { return "listen_together_waiting_download".localized }
    if conditions.isJoiningGroup { return "listen_together_joining".localized }
    return nil
  }

  /// The session button's hint; nil when there is nothing to end, leave or cancel (or no hint is
  /// needed). A listener playing their own copy hears that it is kept.
  static func endHint(for state: ListenTogetherState, usesOwnCopy: Bool = false) -> String? {
    ListenTogetherSessionAction.action(for: state, usesOwnCopy: usesOwnCopy)?.hint
  }

  private static func joined(_ text: String, _ detail: String?) -> String {
    guard let detail, !detail.isEmpty else { return text }
    return text + ". " + detail
  }

  private static func downloadingText(percent: Int) -> String {
    String.localizedStringWithFormat("listen_together_status_downloading".localized, percent)
  }
}

/// The one session button and its meaning per state (leave guidance, "Role-aware banner button"):
/// Cancel Sharing (preparing, acts at once), End Listen Together (sharing, asks once), Leave Listen
/// Together (listening, asks once). The status element's custom action uses the same label.
struct ListenTogetherSessionAction: Equatable {
  enum Kind: Equatable {
    case cancelSharing
    case endForEveryone
    case leave
  }

  let kind: Kind
  let label: String
  let systemImage: String
  let hint: String?
  /// Asks once before acting (End and Leave can't be undone).
  let confirms: Bool

  static func action(for state: ListenTogetherState, usesOwnCopy: Bool = false) -> ListenTogetherSessionAction? {
    switch state {
    case .preparing:
      return ListenTogetherSessionAction(
        kind: .cancelSharing, label: "listen_together_cancel_sharing_button".localized,
        systemImage: "xmark.circle", hint: nil, confirms: false)
    case .sharing:
      return ListenTogetherSessionAction(
        kind: .endForEveryone, label: "listen_together_end_button".localized,
        systemImage: "stop.circle", hint: "listen_together_end_hint_sharer".localized, confirms: true)
    case .listening:
      return ListenTogetherSessionAction(
        kind: .leave, label: "listen_together_leave_session_button".localized,
        systemImage: "rectangle.portrait.and.arrow.right",
        hint: (usesOwnCopy
          ? "listen_together_leave_session_hint_own_copy" : "listen_together_leave_session_hint").localized,
        confirms: true)
    case .idle, .needsFaceTime, .invitation, .ended:
      return nil
    }
  }

  /// Leave is offered only where the host owns the confirmation (fix round 1, I3); the other actions
  /// are always offered.
  static func isOffered(_ kind: Kind, hasHostLeave: Bool) -> Bool {
    kind != .leave || hasHostLeave
  }

  /// The "Leave Listen Together?" message (own copy: the copy stays).
  static func leaveConfirmationMessage(usesOwnCopy: Bool) -> String {
    (usesOwnCopy ? "listen_together_leave_confirm_message_own_copy" : "listen_together_leave_confirm_message").localized
  }
}
