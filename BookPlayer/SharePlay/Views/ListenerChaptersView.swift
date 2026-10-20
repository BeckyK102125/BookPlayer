import BookPlayerKit
import SwiftUI

/// The shared book's chapters. VoiceOver starts on the current chapter (marked selected); choosing
/// one jumps there and closes the sheet. Chapters not downloaded yet stay enabled: the service says
/// "Waiting for the book to download" if needed.
struct ListenerChaptersView: View {
  let listener: ListenerPlayer
  let currentIndex: Int?

  @EnvironmentObject private var theme: ThemeViewModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @AccessibilityFocusState private var focusedIndex: Int?

  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        List {
          ForEach(Array(listener.manifest.chapters.enumerated()), id: \.offset) { index, chapter in
            row(chapter, isCurrent: index == currentIndex)
              .id(index)
              .accessibilityFocused($focusedIndex, equals: index)
              // The theme's background, as the player's chapters list: primary text on the default row
              // background drops below 4.5:1 in some themes (Sky dark).
              .listRowBackground(theme.systemBackgroundColor)
          }
        }
        .listStyle(.plain)
        .applyListStyle(with: theme, background: theme.systemBackgroundColor)
        .task {
          guard let currentIndex else { return }
          proxy.scrollTo(currentIndex, anchor: .center)
          try? await Task.sleep(for: .milliseconds(500))
          focusedIndex = currentIndex
        }
      }
      .navigationTitle("chapters_title".localized)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("voiceover_close_button".localized) { dismiss() }
            .bpFont(.body)
            // Primary (A5): on the theme background the system tint and link colour can fall below 3:1.
            .foregroundStyle(theme.primaryColor)
        }
      }
    }
    .accessibilityAction(.escape) { dismiss() }
    .accessibilityAction(.magicTap) { listener.userTogglePlay() }
  }

  private func row(_ chapter: SharedChapter, isCurrent: Bool) -> some View {
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
      : AnyLayout(HStackLayout(spacing: 8))
    return Button {
      listener.userJump(to: chapter.start)
      dismiss()
    } label: {
      HStack(spacing: 8) {
        layout {
          Text(chapter.title)
            .bpFont(.body)
            .foregroundStyle(theme.primaryColor)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
          if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
          Text(TimeParser.formatTime(chapter.duration))
            .bpFont(.footnote)
            .monospacedDigit()
            // Primary (A9): secondary is below 4.5:1 in most light themes.
            .foregroundStyle(theme.primaryColor)
        }
        Image(systemName: "checkmark")
          // Primary (A5): the only visual sign of the current chapter; link is below 3:1 in four variants.
          .foregroundStyle(theme.primaryColor)
          .opacity(isCurrent ? 1 : 0)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(chapter.title)
    .accessibilityValue(VoiceOverService.secondsToMinutes(chapter.duration))
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }
}
