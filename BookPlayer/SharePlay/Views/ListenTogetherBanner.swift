import BookPlayerKit
import SwiftUI

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

  /// The End button's hint; nil when there is nothing to end.
  static func endHint(for state: ListenTogetherState) -> String? {
    switch state {
    case .preparing: return "listen_together_end_hint_preparing".localized
    case .sharing: return "listen_together_end_hint_sharer".localized
    case .listening: return "listen_together_end_hint_listener".localized
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

/// Shown at the top of the player and on the listener screen while Listen Together is preparing,
/// running or has just ended. VoiceOver reads the status as one element and End as a second one.
/// The service makes every announcement; this view never posts one.
struct ListenTogetherBanner: View {
  @ObservedObject var service: SharePlaySessionService
  /// Called when the banner goes away while VoiceOver is on it, so the host can move focus somewhere
  /// sensible instead of letting it drop.
  var onRemovedWhileFocused: (() -> Void)?
  @EnvironmentObject private var theme: ThemeViewModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AccessibilityFocusState private var focus: Field?
  @State private var isConfirmingEnd = false
  @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 18

  private enum Field {
    case status
    case end
  }

  var body: some View {
    let visible = ListenTogetherStatus.visibleText(for: service.state)
    VStack(spacing: 0) {
      if let visible {
        content(visible: visible)
          .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: visible != nil)
    .onChange(of: visible == nil) { _, isGone in
      if isGone, focus != nil { onRemovedWhileFocused?() }
    }
    .onChange(of: ListenTogetherStatus.endHint(for: service.state) == nil) { _, endIsGone in
      // The End button is about to go away: keep VoiceOver on the banner instead of losing focus.
      if endIsGone, focus == .end { focus = .status }
      // The session ended some other way while the confirmation was up: nothing left to confirm.
      if endIsGone { isConfirmingEnd = false }
    }
    .confirmationDialog(
      "listen_together_end_confirm_title".localized,
      isPresented: $isConfirmingEnd,
      titleVisibility: .visible
    ) {
      Button("listen_together_end_button".localized, role: .destructive) { service.end() }
      Button("cancel_button".localized, role: .cancel) {}
    } message: {
      if let hint = ListenTogetherStatus.endHint(for: service.state) {
        Text(hint)
      }
    }
  }

  private func content(visible: String) -> some View {
    let state = service.state
    let endHint = ListenTogetherStatus.endHint(for: state)
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
    return layout {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: ListenTogetherStatus.isProblem(state) ? "exclamationmark.triangle" : "shareplay")
          .resizable()
          .scaledToFit()
          .frame(width: iconSize, height: iconSize)
          .foregroundStyle(theme.linkColor)
          .accessibilityHidden(true)
        Text(visible)
          .bpFont(.subheadline)
          .foregroundStyle(theme.primaryColor)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .layoutPriority(1)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(ListenTogetherStatus.spokenText(for: state) ?? visible)
      .accessibilityFocused($focus, equals: .status)
      .accessibilityActions {
        if endHint != nil {
          Button("listen_together_end_button".localized) { requestEnd() }
        }
      }

      if let endHint {
        Button(action: requestEnd) {
          Text("listen_together_end_button".localized)
            .bpFont(.body)
            .foregroundStyle(theme.linkColor)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: 44, minHeight: 44)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
            .overlay(Capsule().stroke(theme.linkColor, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(endHint)
        .accessibilityIdentifier("listenTogether.end")
        .accessibilityFocused($focus, equals: .end)
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(theme.secondarySystemBackgroundColor)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(theme.secondaryColor, lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
  }

  /// Cancelling a share that is still being prepared is cheap; ending a running session is not
  /// (everyone stops, or the listener's copy is deleted), so that asks first.
  private func requestEnd() {
    if case .preparing = service.state {
      service.end()
    } else {
      isConfirmingEnd = true
    }
  }
}

/// The "Start a FaceTime call first" alert. It waits a moment so it is not dropped while the More
/// menu is still closing, and OK returns the service to idle.
struct ListenTogetherNeedsFaceTimeAlert: ViewModifier {
  @ObservedObject var service: SharePlaySessionService
  @State private var isPresented = false

  func body(content: Content) -> some View {
    content
      .onChange(of: service.state == .needsFaceTime, initial: true) { _, needsFaceTime in
        guard needsFaceTime else {
          isPresented = false
          return
        }
        Task {
          try? await Task.sleep(for: .milliseconds(600))
          if service.state == .needsFaceTime { isPresented = true }
        }
      }
      .onChange(of: isPresented) { _, shown in
        if !shown { service.acknowledgeNeedsFaceTime() }
      }
      .alert("listen_together_needs_facetime_title".localized, isPresented: $isPresented) {
        Button("ok_button".localized, role: .cancel) {}
      } message: {
        Text("listen_together_needs_facetime_message".localized)
      }
  }
}

extension View {
  /// Adds the needs-FaceTime alert when Listen Together is available.
  @ViewBuilder
  func listenTogetherNeedsFaceTimeAlert(_ service: SharePlaySessionService?) -> some View {
    if let service {
      modifier(ListenTogetherNeedsFaceTimeAlert(service: service))
    } else {
      self
    }
  }
}
