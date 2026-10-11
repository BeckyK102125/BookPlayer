import BookPlayerKit
import SwiftUI

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
  /// Focus is reset by SwiftUI when its element goes away, often before the removal's onChange runs,
  /// so the last focused element and when focus was lost are remembered.
  @State private var lastFocus: Field?
  @State private var focusLostAt: Date?
  /// A removal seen before the focus reset arrived; handled when it does.
  @State private var pendingRemoval: (kind: Removal, at: Date)?
  @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 18

  private enum Field {
    case status
    case end
  }

  private enum Removal {
    case end
    case banner
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
    .onChange(of: focus) { old, new in
      if let new {
        lastFocus = new
        focusLostAt = nil
        return
      }
      focusLostAt = .now
      // The element went away first and focus was reset afterwards.
      if let pendingRemoval, Date.now.timeIntervalSince(pendingRemoval.at) < 1, let old {
        self.pendingRemoval = nil
        if pendingRemoval.kind == .banner || old == .end { recover(from: pendingRemoval.kind) }
      }
    }
    .onChange(of: visible == nil) { _, isGone in
      guard isGone else { return }
      removed(.banner, hadFocus: hadFocusJustNow(nil))
    }
    .onChange(of: ListenTogetherStatus.endHint(for: service.state) == nil) { _, endIsGone in
      guard endIsGone else { return }
      // The session ended some other way while the confirmation was up: nothing left to confirm.
      isConfirmingEnd = false
      removed(.end, hadFocus: hadFocusJustNow(.end))
    }
    .confirmationDialog(
      "listen_together_end_confirm_title".localized,
      isPresented: $isConfirmingEnd,
      titleVisibility: .visible
    ) {
      Button("listen_together_end_button".localized, role: .destructive) {
        // Move off End first, so VoiceOver lands on the ended status instead of losing focus.
        focus = .status
        service.end()
      }
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
      // The theme's background: link-coloured text and outlines are designed against it.
      RoundedRectangle(cornerRadius: 12)
        .fill(theme.systemBackgroundColor)
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
      focus = .status
      service.end()
    } else {
      isConfirmingEnd = true
    }
  }

  /// Whether VoiceOver is, or was a moment ago, on `field` (any banner element when nil).
  private func hadFocusJustNow(_ field: Field?) -> Bool {
    if let focus { return field == nil || focus == field }
    guard let focusLostAt, Date.now.timeIntervalSince(focusLostAt) < 1, let lastFocus else { return false }
    return field == nil || lastFocus == field
  }

  private func removed(_ kind: Removal, hadFocus: Bool) {
    if hadFocus {
      recover(from: kind)
    } else {
      pendingRemoval = (kind, .now)
    }
  }

  /// End went away: stay on the status. The banner went away: the host picks a target.
  private func recover(from kind: Removal) {
    focusLostAt = nil
    lastFocus = nil
    switch kind {
    case .end: focus = .status
    case .banner: onRemovedWhileFocused?()
    }
  }
}

/// The "Couldn't open sharing" alert, shown only when Apple's sharing sheet can't be. It waits a
/// moment so it is not dropped while the More menu is still closing, and OK returns the service to idle.
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
      // The player closed before the alert showed: don't show it later, out of context.
      .onDisappear { service.acknowledgeNeedsFaceTime() }
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

/// The one-time "listening only" note for the sharer, the first time they choose Listen Together on this
/// device, before sharing starts (so it never interrupts the session's announcements). It waits a moment
/// so it is not dropped while the More menu is still closing. Share records it as seen and starts
/// sharing; Cancel shares nothing and does not record it.
struct ListenTogetherFirstShareNoteAlert: ViewModifier {
  @ObservedObject var service: SharePlaySessionService
  @State private var isPresented = false

  func body(content: Content) -> some View {
    content
      .onChange(of: service.showsFirstShareNote, initial: true) { _, shows in
        guard shows else {
          isPresented = false
          return
        }
        Task {
          try? await Task.sleep(for: .milliseconds(600))
          if service.showsFirstShareNote { isPresented = true }
        }
      }
      // The player closed first: don't show the note later, out of context, and don't share.
      .onDisappear { service.cancelFirstShareNote() }
      .alert("listen_together_first_share_title".localized, isPresented: $isPresented) {
        // R34: escape never starts an action. Share is the default; Cancel (and two-finger Z, which
        // picks the cancel action) shares nothing and keeps the note for next time.
        Button("listen_together_share_button".localized) {
          Task { await service.acknowledgeFirstShareNote() }
        }
        .keyboardShortcut(.defaultAction)
        Button("cancel_button".localized, role: .cancel) { service.cancelFirstShareNote() }
      } message: {
        Text("listen_together_first_share_message".localized)
      }
  }
}

extension View {
  /// Adds the sharer's one-time "listening only" note when Listen Together is available.
  @ViewBuilder
  func listenTogetherFirstShareNote(_ service: SharePlaySessionService?) -> some View {
    if let service {
      modifier(ListenTogetherFirstShareNoteAlert(service: service))
    } else {
      self
    }
  }
}
