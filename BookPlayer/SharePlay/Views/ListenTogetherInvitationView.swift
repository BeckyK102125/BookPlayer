import BookPlayerKit
import SwiftUI

/// Asks whether to join someone's Listen Together share. Presented by MainCoordinator in a UIKit
/// sheet from the topmost screen (MainCoordinator+ListenTogether.swift).
/// VoiceOver order: heading, message, Join, Not Now. Two-finger Z calls `onDecline`; swiping the
/// sheet away declines through the coordinator's presentation-controller delegate.
struct ListenTogetherInvitationView: View {
  let title: String
  let author: String
  /// The listener has the book (addendum 2, case A): the message and Join hint say BookPlayer plays
  /// their copy. Heading, button labels, order and focus are the same in every case.
  var usesOwnCopy = false
  let onJoin: () -> Void
  let onDecline: () -> Void

  @EnvironmentObject private var theme: ThemeViewModel
  @AccessibilityFocusState private var focus: Field?

  private enum Field {
    case heading
  }

  /// One paragraph: who is sharing what, then what Join does with the book: plays your copy (case A),
  /// or saves a copy for this session only (case B).
  private var message: String {
    if usesOwnCopy {
      return author.isEmpty
        ? String.localizedStringWithFormat("listen_together_invitation_own_copy_no_author".localized, title)
        : String.localizedStringWithFormat("listen_together_invitation_own_copy".localized, title, author)
    }
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

        // R40 (A3): symbol and text, prominent in the theme's primary colour with the background colour
        // as the label (at least 6.40:1 in every theme variant, and the fill at least 3:1).
        Button(action: onJoin) {
          Label {
            Text("listen_together_join_button".localized)
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "shareplay").accessibilityHidden(true)
          }
          .bpFont(.body)
          .foregroundStyle(theme.systemBackgroundColor)
          .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.primaryColor)
        .controlSize(.large)
        .accessibilityLabel("listen_together_join_button".localized)
        .accessibilityHint(
          (usesOwnCopy ? "listen_together_join_hint_own_copy" : "listen_together_join_hint").localized)
        .accessibilityIdentifier("listenTogether.join")

        // R40 (A4): symbol and text, outline capsule in the theme's primary colour.
        Button(action: onDecline) {
          Label {
            Text("listen_together_decline_button".localized)
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "xmark").accessibilityHidden(true)
          }
          .bpFont(.body)
          .foregroundStyle(theme.primaryColor)
          .frame(maxWidth: .infinity, minHeight: 44)
          .padding(.vertical, 6)
          .overlay(Capsule().stroke(theme.primaryColor, lineWidth: 1.5))
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("listen_together_decline_button".localized)
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
