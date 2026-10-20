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
  /// Listener: the group's place is not known yet; Play and the skips do nothing.
  var isJoiningGroup = false
  /// Listener: still finding the place after a while: the line also says what to do.
  var isJoiningSlow = false
  /// Build 5: the group paused because listeners left, until someone plays (both roles).
  var pauseCause: ListenTogetherPauseCause?
  /// Listener (Option 1): stopped on this phone while the group plays on.
  var localStop: ListenTogetherLocalStop?
  /// Sharer (decision B): the last listener vanished; Listen Together ends if nobody is back in a minute.
  var isWaitingForListeners = false
}

/// One status line in the banner: a first line, an optional second line, what VoiceOver reads and the
/// icon. The text carries the meaning; the icon is decoration (hidden from VoiceOver).
struct ListenTogetherStatusLine: Equatable {
  enum Icon: Equatable {
    case shareplay
    case hourglass
    case warning
    case paused

    var systemName: String {
      switch self {
      case .shareplay: return "shareplay"
      case .hourglass: return "hourglass"
      case .warning: return "exclamationmark.triangle"
      case .paused: return "pause.circle"
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
      .ended(.sharerCouldNotPrepare), .ended(.connectionEnded), .ended(.left), .ended(.ownCopyFailed),
      .ended(.everyoneLeft):
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

  /// The full status line (guidance A.1, C; build 5 1.4). Priorities: listener, the person sharing out
  /// of the session (the grace), then paused because someone left, then waiting for a piece, then the
  /// person sharing quiet, then paused by another listener; sharer, paused because someone left, then
  /// retrying a piece, then paused by another listener. "Someone couldn't join" is a second line under
  /// the sharer's status.
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
      if let stop = conditions.localStop {
        // Option 1: why this phone is silent while the others listen on.
        let text = stop.text
        return ListenTogetherStatusLine(text: text, detail: base, spoken: joined(text, baseSpoken), icon: .paused)
      }
      if let cause = conditions.pauseCause {
        let text = cause.text
        return ListenTogetherStatusLine(text: text, detail: base, spoken: joined(text, baseSpoken), icon: .paused)
      }
      if conditions.isWaitingForPiece {
        let text = "listen_together_waiting_download".localized
        // While the book is still arriving, the percent stays visible under it.
        let detail = downloaded < 1 ? base : nil
        let spokenDetail = downloaded < 1 ? baseSpoken : nil
        return ListenTogetherStatusLine(text: text, detail: detail, spoken: joined(text, spokenDetail), icon: .hourglass)
      }
      if conditions.isJoiningGroup {
        // Start-position fix C: why Play does nothing yet. The percent stays visible under it, until
        // the wait is long: then the second line says what to do (round 1, a11y I1).
        let text = "listen_together_finding_place".localized
        if conditions.isJoiningSlow {
          let slow = "listen_together_finding_place_slow".localized
          return ListenTogetherStatusLine(text: text, detail: slow, spoken: joined(text, slow), icon: .hourglass)
        }
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
      let declined = conditions.isWaitingForListeners
        ? "listen_together_waiting_for_listeners_detail".localized
        : (conditions.someoneDeclined ? "listen_together_declined_no_copy".localized : nil)
      if let cause = conditions.pauseCause {
        let text = cause.text
        let detail = declined ?? base
        return ListenTogetherStatusLine(text: text, detail: detail, spoken: joined(text, detail), icon: .paused)
      }
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
    if conditions.isJoiningGroup { return "listen_together_finding_place".localized }
    return nil
  }

  /// The listener's Play button value: why playback is held, or why this phone is stopped while the
  /// group plays on (Option 1; Play then rejoins).
  static func listenerPlayValue(_ conditions: ListenTogetherStatusConditions) -> String? {
    waitingCaption(conditions) ?? conditions.localStop?.text
  }

  /// The caption under a listener's play controls (Zoom): why playback is held, else (fix round 1,
  /// a11y M4) why the group paused because someone left. Hidden from VoiceOver; unlike `waitingCaption`
  /// it is never the Play value (Play works; the banner and row carry the pause for VoiceOver).
  static func listenerCaption(_ conditions: ListenTogetherStatusConditions) -> String? {
    waitingCaption(conditions) ?? conditions.localStop?.text ?? conditions.pauseCause?.text
  }

  /// Build 5 (1.4): the sharer's reason under the play controls (Zoom) and the play button's value:
  /// the P-sentence while the group is paused because someone left. Nil otherwise, and for listeners
  /// (their Play works; the banner and row carry it).
  static func sharerPauseCaption(
    for state: ListenTogetherState, conditions: ListenTogetherStatusConditions
  ) -> String? {
    guard case .sharing = state else { return nil }
    return conditions.pauseCause?.text
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
      let last = isLastListener(state)
      let key = usesOwnCopy
        ? (last ? "listen_together_leave_session_hint_own_copy_last" : "listen_together_leave_session_hint_own_copy")
        : (last ? "listen_together_leave_session_hint_last" : "listen_together_leave_session_hint")
      return ListenTogetherSessionAction(
        kind: .leave, label: "listen_together_leave_session_button".localized,
        systemImage: "rectangle.portrait.and.arrow.right",
        hint: key.localized,
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

  /// A listener's roster is the person sharing and this phone: leaving ends Listen Together for
  /// everyone (build 6), so "The others keep listening" would be false (audit 1, a11y I3).
  static func isLastListener(_ state: ListenTogetherState) -> Bool {
    guard case .listening(let participants, _) = state else { return false }
    return participants <= 2
  }

  /// The "Leave Listen Together?" message (own copy: the copy stays). While others remain it says that
  /// SharePlay stays on until closed in Control Center (decision C); for the last listener, that Listen
  /// Together ends for everyone.
  static func leaveConfirmationMessage(usesOwnCopy: Bool, isLastListener: Bool = false) -> String {
    let key = usesOwnCopy
      ? (isLastListener ? "listen_together_leave_confirm_message_own_copy_last" : "listen_together_leave_confirm_message_own_copy")
      : (isLastListener ? "listen_together_leave_confirm_message_last" : "listen_together_leave_confirm_message")
    return key.localized
  }

  /// "Leave Listen Together to play this book?": the same two cases.
  static func leaveToPlayMessage(isLastListener: Bool) -> String {
    (isLastListener ? "listen_together_leave_to_play_message_last" : "listen_together_leave_to_play_message").localized
  }
}
