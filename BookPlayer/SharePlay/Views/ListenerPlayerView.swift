import BookPlayerKit
import SwiftUI

/// Where VoiceOver focus is moved on the listener screen.
enum ListenerFocus: Hashable {
  case title
  case chapter
}

/// The listener's player during Listen Together, shown as a full-screen cover from MainView while
/// `SharePlaySessionService.listener` exists. VoiceOver order: Done, title (heading, first focus),
/// author, chapter, status, End, position, skip back, play/pause, skip forward, chapters, speed.
/// Done and two-finger Z close the screen only (R35): the session keeps playing and the Listen Together
/// row brings it back. Ending is only through the labelled End button.
struct ListenerPlayerView: View {
  let service: SharePlaySessionService
  /// Not observed here: its time ticks twice a second, so only the small subviews observe it.
  let listener: ListenerPlayer
  /// How long to wait before moving focus to the title: long for a fresh cover, short when this view
  /// replaces the "getting the book" screen inside a cover that is already up.
  var initialFocusDelay: Duration = .milliseconds(600)
  /// "Leave Listen Together?" is up: the title focus move is skipped so it doesn't pull focus from it.
  /// A binding, so the delayed check reads the current value (code M2).
  var isConfirmingLeave: Binding<Bool> = .constant(false)
  /// Bumped to move VoiceOver focus to the title (Cancel after the screen swap, a11y M5).
  var titleFocusRequest = 0
  /// Leave Listen Together: asks through the listener screen.
  var onRequestLeave: (() -> Void)?
  /// Escape: closes the screen only; never ends, pauses or starts anything.
  var onClose: () -> Void = {}

  @StateObject private var theme = ThemeViewModel()
  @AccessibilityFocusState private var focus: ListenerFocus?
  @State private var showingChapters = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        ListenTogetherDoneButton(action: onClose)
        ListenerHeaderView(listener: listener, focus: $focus)
        ListenTogetherBanner(service: service, onRequestLeave: onRequestLeave)
        ListenerPositionView(listener: listener)
        ListenerTransportRow(listener: listener, service: service)
          .frame(maxWidth: .infinity)
        // Zoom (C.1, C.2): why Play does nothing, right under the controls. Hidden from VoiceOver.
        ListenerWaitingCaption(service: service)
        ListenerExtrasRow(listener: listener) { showingChapters = true }
      }
      .padding(16)
      .frame(maxWidth: 600, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .background(theme.systemBackgroundColor.ignoresSafeArea())
    .environmentObject(theme)
    .accessibilityAction(.magicTap) { listener.userTogglePlay() }
    // Escape closes the screen only (R35). Ending deletes a downloaded copy (never the listener's own
    // book), so it stays on the labelled End button and its confirmation; escape never reaches it.
    .accessibilityAction(.escape) { onClose() }
    .task {
      // Wait for the cover to finish presenting; an earlier request is often lost.
      try? await Task.sleep(for: initialFocusDelay)
      guard !isConfirmingLeave.wrappedValue else { return }
      focus = .title
      // Own copy: "Joined. Playing your copy." comes after the title, never over it (a11y I2).
      service.listenerTitleFocused()
    }
    .onChange(of: titleFocusRequest) {
      Task {
        try? await Task.sleep(for: .milliseconds(300))
        focus = .title
      }
    }
    .sheet(isPresented: $showingChapters, onDismiss: focusChapterAfterJump) {
      ListenerChaptersView(listener: listener, currentIndex: currentChapterIndex)
        .environmentObject(theme)
    }
  }

  private var currentChapterIndex: Int? {
    listener.manifest.chapters.firstIndex { $0 == ListenerHeaderView.chapter(for: listener) }
  }

  /// A jump the user makes is never announced, so land on the chapter text to confirm where they are.
  private func focusChapterAfterJump() {
    Task {
      try? await Task.sleep(for: .milliseconds(400))
      focus = .chapter
    }
  }
}

/// Done, at the top trailing edge of the listener screens: closes the screen only, exactly like the
/// two-finger scrub (R35), for everyone who can't use that gesture (Zoom, Voice Control, Switch Control,
/// keyboard, no assistive technology). It never ends, leaves, pauses or starts anything. Same outline
/// capsule as the session button (R40): primary colour (at least 6.40:1), 44 pt, Dynamic Type.
struct ListenTogetherDoneButton: View {
  let action: () -> Void
  @EnvironmentObject private var theme: ThemeViewModel

  var body: some View {
    HStack {
      Spacer(minLength: 0)
      Button(action: action) {
        Label {
          Text("done_title".localized)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "chevron.down").accessibilityHidden(true)
        }
        .bpFont(.body)
        .foregroundStyle(theme.primaryColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minWidth: 44, minHeight: 44)
        .overlay(Capsule().stroke(theme.primaryColor, lineWidth: 1.5))
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("done_title".localized)
      .accessibilityHint("listen_together_done_hint".localized)
      .accessibilityIdentifier("listenTogether.done")
    }
  }
}

/// Title, author and the current chapter.
struct ListenerHeaderView: View {
  @ObservedObject var listener: ListenerPlayer
  var focus: AccessibilityFocusState<ListenerFocus?>.Binding
  @EnvironmentObject private var theme: ThemeViewModel

  static func chapter(for listener: ListenerPlayer) -> SharedChapter? {
    // No chapter while the place is unknown: it would be the first one (a11y I2).
    guard !listener.isJoiningGroup else { return nil }
    let manifest = listener.manifest
    if let chapter = manifest.chapter(at: listener.bookTime) { return chapter }
    // At the very end the time equals the last chapter's end.
    return listener.bookTime >= manifest.duration ? manifest.chapters.last : nil
  }

  var body: some View {
    let manifest = listener.manifest
    VStack(alignment: .leading, spacing: 6) {
      Text(manifest.title)
        .bpFont(.titleLarge)
        .foregroundStyle(theme.primaryColor)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHeading(.h1)
        .accessibilityFocused(focus, equals: .title)

      // Primary (A9): secondary is below 4.5:1 in most light themes.
      Text(manifest.author.isEmpty ? "voiceover_unknown_author".localized : manifest.author)
        .bpFont(.body)
        .foregroundStyle(theme.primaryColor)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)

      if let chapter = Self.chapter(for: listener) {
        Text(chapter.title)
          .bpFont(.subheadline)
          .foregroundStyle(theme.primaryColor)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityFocused(focus, equals: .chapter)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The reason playback is held, under the play controls (C.1, C.2): where a Zoom user looks when Play
/// "does nothing". The only intentionally duplicated visual text; hidden from VoiceOver, which hears it
/// in the status and as the play button's value. Fix round 1 (a11y M4): when nothing holds playback, the
/// "Paused. Someone left..." sentence shows here too (VoiceOver hears it in the status and row only).
struct ListenerWaitingCaption: View {
  @ObservedObject var service: SharePlaySessionService
  @EnvironmentObject private var theme: ThemeViewModel

  var body: some View {
    if let caption = ListenTogetherStatus.listenerCaption(service.statusConditions) {
      Text(caption)
        .bpFont(.subheadline)
        .foregroundStyle(theme.primaryColor)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
  }
}

/// The player's controls while sharing (build 5, a11y guidance 1.4): when the group paused because
/// someone left, the reason sits directly under the play controls for Zoom (hidden from VoiceOver) and is
/// the play button's value, so landing on Play says why. Nothing changes otherwise.
struct ListenTogetherPlayControls: View {
  @ObservedObject var service: SharePlaySessionService
  let isPlaying: Bool
  @EnvironmentObject private var theme: ThemeViewModel

  var body: some View {
    let caption = ListenTogetherStatus.sharerPauseCaption(for: service.state, conditions: service.statusConditions)
    VStack(spacing: 8) {
      PlayControlsRowView(isPlaying: isPlaying, playValue: caption)
      if let caption {
        Text(caption)
          .bpFont(.subheadline)
          .foregroundStyle(theme.primaryColor)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity)
          .accessibilityHidden(true)
      }
    }
  }
}
