import BookPlayerKit
import SwiftUI

/// Asks whether to join someone's Listen Together share. Presented by MainCoordinator in a UIKit
/// sheet from the topmost screen (MainCoordinator+ListenTogether.swift).
/// VoiceOver order: heading, message, Join, Not Now. Two-finger Z calls `onDecline`; swiping the
/// sheet away declines through the coordinator's presentation-controller delegate.
struct ListenTogetherInvitationView: View {
  let title: String
  let author: String
  let onJoin: () -> Void
  let onDecline: () -> Void

  @EnvironmentObject private var theme: ThemeViewModel
  @Environment(\.colorScheme) private var colorScheme
  @AccessibilityFocusState private var focus: Field?

  private enum Field {
    case heading
  }

  /// One paragraph: who is sharing what, then that joining gives no copy of the book.
  private var message: String {
    let invitation = author.isEmpty
      ? String.localizedStringWithFormat("listen_together_invitation_message_no_author".localized, title)
      : String.localizedStringWithFormat("listen_together_invitation_message".localized, title, author)
    return invitation + " " + "listen_together_invitation_listen_only".localized
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("listen_together_title".localized)
          .bpFont(.title2)
          .foregroundStyle(theme.primaryColor)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
          .accessibilityHeading(.h1)
          .accessibilityFocused($focus, equals: .heading)

        Text(message)
          .bpFont(.body)
          .foregroundStyle(theme.primaryColor)
          .fixedSize(horizontal: false, vertical: true)

        Button(action: onJoin) {
          Text("listen_together_join_button".localized)
            .bpFont(.body)
            .foregroundStyle(theme.labelColorOnLink(for: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 6)
            .background(Capsule().fill(theme.linkColor))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("listen_together_join_hint".localized)
        .accessibilityIdentifier("listenTogether.join")

        Button(action: onDecline) {
          Text("listen_together_decline_button".localized)
            .bpFont(.body)
            .foregroundStyle(theme.linkColor)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 6)
            .overlay(Capsule().stroke(theme.linkColor, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("listenTogether.decline")
      }
      .padding(24)
      .frame(maxWidth: 600, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .background(theme.systemBackgroundColor.ignoresSafeArea())
    .accessibilityAction(.escape) { onDecline() }
    .task {
      // Set after the sheet has finished presenting; earlier the request is often lost.
      try? await Task.sleep(for: .milliseconds(400))
      focus = .heading
    }
  }
}
