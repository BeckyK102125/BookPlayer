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
          }
        }
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
            .foregroundStyle(theme.secondaryColor)
        }
        Image(systemName: "checkmark")
          .foregroundStyle(theme.linkColor)
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
