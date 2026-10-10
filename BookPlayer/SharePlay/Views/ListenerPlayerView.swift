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
/// Two-finger Z does nothing here: ending is only through the labelled End button.
struct ListenerPlayerView: View {
  let service: SharePlaySessionService
  /// Not observed here: its time ticks twice a second, so only the small subviews observe it.
  let listener: ListenerPlayer
  /// How long to wait before moving focus to the title: long for a fresh cover, short when this view
  /// replaces the "getting the book" screen inside a cover that is already up.
  var initialFocusDelay: Duration = .milliseconds(600)

  @StateObject private var theme = ThemeViewModel()
  @AccessibilityFocusState private var focus: ListenerFocus?
  @State private var showingChapters = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        ListenerHeaderView(listener: listener, focus: $focus)
        ListenTogetherBanner(service: service)
        ListenerPositionView(listener: listener)
        ListenerTransportRow(listener: listener)
          .frame(maxWidth: .infinity)
        ListenerExtrasRow(listener: listener) { showingChapters = true }
      }
      .padding(16)
      .frame(maxWidth: 600, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .background(theme.systemBackgroundColor.ignoresSafeArea())
    .environmentObject(theme)
    .accessibilityAction(.magicTap) { listener.userTogglePlay() }
    // Escape is ignored on purpose: ending deletes the listener's copy, too much for a reflex gesture.
    .accessibilityAction(.escape) {}
    .task {
      // Wait for the cover to finish presenting; an earlier request is often lost.
      try? await Task.sleep(for: initialFocusDelay)
      focus = .title
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

      Text(manifest.author.isEmpty ? "voiceover_unknown_author".localized : manifest.author)
        .bpFont(.body)
        .foregroundStyle(theme.secondaryColor)
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
