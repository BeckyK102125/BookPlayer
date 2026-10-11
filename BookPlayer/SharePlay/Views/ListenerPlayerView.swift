import BookPlayerKit
import SwiftUI

/// Where VoiceOver focus is moved on the listener screen.
enum ListenerFocus: Hashable {
  case title
  case chapter
}

/// The listener's player during Listen Together, shown as a full-screen cover from MainView while
/// `SharePlaySessionService.listener` exists. VoiceOver order: title (heading, first focus), author,
/// chapter, status, End, position, skip back, play/pause, skip forward, chapters, speed.
/// Two-finger Z closes the screen only (R35): the session keeps playing and the Listen Together row
/// brings it back. Ending is only through the labelled End button.
struct ListenerPlayerView: View {
  let service: SharePlaySessionService
  /// Not observed here: its time ticks twice a second, so only the small subviews observe it.
  let listener: ListenerPlayer
  /// How long to wait before moving focus to the title: long for a fresh cover, short when this view
  /// replaces the "getting the book" screen inside a cover that is already up.
  var initialFocusDelay: Duration = .milliseconds(600)
  /// "Leave Listen Together?" is up: the title focus move is skipped so it doesn't pull focus from it.
  var isConfirmingLeave = false
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
      guard !isConfirmingLeave else { return }
      focus = .title
      // Own copy: "Joined. Playing your copy." comes after the title, never over it (a11y I2).
      service.listenerTitleFocused()
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

/// Title, author and the current chapter.
struct ListenerHeaderView: View {
  @ObservedObject var listener: ListenerPlayer
  var focus: AccessibilityFocusState<ListenerFocus?>.Binding
  @EnvironmentObject private var theme: ThemeViewModel

  static func chapter(for listener: ListenerPlayer) -> SharedChapter? {
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
/// in the status and as the play button's value.
struct ListenerWaitingCaption: View {
  @ObservedObject var service: SharePlaySessionService
  @EnvironmentObject private var theme: ThemeViewModel

  var body: some View {
    if let caption = ListenTogetherStatus.waitingCaption(service.statusConditions) {
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
