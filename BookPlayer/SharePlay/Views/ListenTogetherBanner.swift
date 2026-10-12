import BookPlayerKit
import SwiftUI

/// Shown at the top of the player and on the listener screen while Listen Together is preparing,
/// running or has just ended. VoiceOver reads the status as one element and the session button
/// (Cancel Sharing, End Listen Together or Leave Listen Together) as a second one. The status is
/// persistent text that stays until it changes (R41); changing it posts nothing by itself. The service
/// makes every announcement; this view never posts one.
struct ListenTogetherBanner: View {
  @ObservedObject var service: SharePlaySessionService
  /// Called when the banner goes away while VoiceOver is on it, so the host can move focus somewhere
  /// sensible instead of letting it drop.
  var onRemovedWhileFocused: (() -> Void)?
  /// False on "Getting the book", which draws the session button itself, full width under the card.
  var showsActionButton = true
  /// Listener: Leave asks through the listener screen's one confirmation (kept there, so it survives
  /// the book details arriving). Without it the banner offers no Leave at all (fix round 1, I3): a
  /// banner-owned question would vanish when the banner is rebuilt.
  var onRequestLeave: (() -> Void)?
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

  private var sessionAction: ListenTogetherSessionAction? {
    guard let action = ListenTogetherSessionAction.action(for: service.state, usesOwnCopy: service.isUsingOwnCopy),
      ListenTogetherSessionAction.isOffered(action.kind, hasHostLeave: onRequestLeave != nil)
    else { return nil }
    return action
  }

  var body: some View {
    let line = ListenTogetherStatus.line(for: service.state, conditions: service.statusConditions)
    VStack(spacing: 0) {
      if let line {
        content(line: line)
          .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: line != nil)
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
    .onChange(of: line == nil) { _, isGone in
      guard isGone else { return }
      removed(.banner, hadFocus: hadFocusJustNow(nil))
    }
    .onChange(of: sessionAction == nil) { _, actionIsGone in
      guard actionIsGone else { return }
      // The session ended some other way while a confirmation was up: nothing left to confirm.
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
      Text("listen_together_end_confirm_message".localized)
    }
  }

  private func content(line: ListenTogetherStatusLine) -> some View {
    let action = showsActionButton ? sessionAction : nil
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
    return layout {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: line.icon.systemName)
          .resizable()
          .scaledToFit()
          .frame(width: iconSize, height: iconSize)
          // Primary, not link: link fails 3:1 in four theme variants (leave guidance section 4).
          .foregroundStyle(theme.primaryColor)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(line.text)
            .bpFont(.subheadline)
            .foregroundStyle(theme.primaryColor)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
          if let detail = line.detail {
            Text(detail)
              .bpFont(.footnote)
              .foregroundStyle(theme.primaryColor)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .layoutPriority(1)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(line.spoken)
      .accessibilityFocused($focus, equals: .status)
      .accessibilityActions {
        if let action = sessionAction {
          Button(action.label) { perform(action) }
        }
      }

      if let action {
        ListenTogetherSessionButton(action: action, isFullWidth: dynamicTypeSize.isAccessibilitySize) {
          perform(action)
        }
        .accessibilityFocused($focus, equals: .end)
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(theme.systemBackgroundColor)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(theme.secondaryColor, lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
  }

  /// Cancelling a share that is still being prepared is cheap and acts at once; ending a running
  /// session (everyone stops) and leaving (this device's copy is deleted) ask once.
  private func perform(_ action: ListenTogetherSessionAction) {
    switch action.kind {
    case .cancelSharing:
      focus = .status
      service.end()
    case .endForEveryone:
      isConfirmingEnd = true
    case .leave:
      onRequestLeave?()
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

  /// The button went away: stay on the status. The banner went away: the host picks a target.
  private func recover(from kind: Removal) {
    focusLostAt = nil
    lastFocus = nil
    switch kind {
    case .end: focus = .status
    case .banner: onRemovedWhileFocused?()
    }
  }
}

/// The session button (R40): SF Symbol plus visible text, the player's outline capsule style in the
/// theme's primary colour on its background (at least 6.40:1 in all 22 theme variants), at least
/// 44 pt high, Dynamic Type without truncation, one element with the Button trait and the same label.
struct ListenTogetherSessionButton: View {
  let action: ListenTogetherSessionAction
  var isFullWidth = false
  let perform: () -> Void
  @EnvironmentObject private var theme: ThemeViewModel

  var body: some View {
    Button(action: perform) {
      Label {
        Text(action.label)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: action.systemImage)
          .accessibilityHidden(true)
      }
      .bpFont(.body)
      .foregroundStyle(theme.primaryColor)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .frame(minWidth: 44, minHeight: 44)
      .frame(maxWidth: isFullWidth ? .infinity : nil)
      .overlay(Capsule().stroke(theme.primaryColor, lineWidth: 1.5))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(action.label)
    .accessibilityHint(action.hint ?? "")
    .accessibilityIdentifier("listenTogether.end")
  }
}

/// "Leave Listen Together?" (leave guidance): Leave is destructive, Cancel is the cancel action, so the
/// two-finger scrub only ever cancels. Leave asks the service to leave; nothing else.
struct ListenTogetherLeaveConfirmation: ViewModifier {
  @Binding var isPresented: Bool
  @ObservedObject var service: SharePlaySessionService
  var onCancel: () -> Void = {}

  func body(content: Content) -> some View {
    content
      .onChange(of: service.isListenerSession) { _, isListening in
        // The session ended some other way while the question was up: nothing left to confirm.
        if !isListening { isPresented = false }
      }
      .alert("listen_together_leave_confirm_title".localized, isPresented: $isPresented) {
        Button("listen_together_leave_button".localized, role: .destructive) { service.leave() }
        Button("cancel_button".localized, role: .cancel) { onCancel() }
      } message: {
        Text(ListenTogetherSessionAction.leaveConfirmationMessage(usesOwnCopy: service.isUsingOwnCopy))
      }
  }
}

extension View {
  func listenTogetherLeaveConfirmation(
    isPresented: Binding<Bool>, service: SharePlaySessionService, onCancel: @escaping () -> Void = {}
  ) -> some View {
    modifier(ListenTogetherLeaveConfirmation(isPresented: isPresented, service: service, onCancel: onCancel))
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
          guard service.state == .needsFaceTime else { return }
          isPresented = true
          // E18: a failure reason, so "Speak error messages" reads the title too.
          service.messages.deliver(
            .alertShownElsewhere(text: "listen_together_needs_facetime_title".localized, key: "needsFaceTime"))
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
        // Depends on the sharer's setting: "Send it for this session" or owners only.
        Text(ListenTogetherSharingMode.current(in: service.defaults).firstShareMessage)
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
