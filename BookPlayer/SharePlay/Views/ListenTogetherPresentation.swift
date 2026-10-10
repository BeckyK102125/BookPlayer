import BookPlayerKit
import SwiftUI

/// Presents the listener screen from MainView. (The invitation is presented by MainCoordinator from
/// the topmost view controller, so no open screen can hide it.)
///
/// SwiftUI can't present a cover over the player cover or the media servers sheet (it silently drops
/// the presentation). So when a listener session starts those are closed first, and the listener
/// screen is presented once they have finished leaving (`ListStateManager.coversOnScreen`). The
/// listener screen registers in `coversOnScreen` like the player does.
struct ListenTogetherPresentation: ViewModifier {
  @ObservedObject var service: SharePlaySessionService
  let listState: ListStateManager
  let playerState: PlayerState

  /// One listener screen per session. Its identity stays the same when the book details arrive, so
  /// the cover is not dismissed and presented again when the "getting the book" state is replaced.
  struct ListenerScreen: Identifiable {
    var id: Int { 0 }
  }

  /// Whether the listener screen is shown: from the moment this device is listening (before the book
  /// details arrive, so a VoiceOver user always has the status and End), and while a listener player
  /// exists; never while a cover it can't be presented over is still on screen.
  static func showsListenerScreen(state: ListenTogetherState, hasListener: Bool, isCovered: Bool) -> Bool {
    guard !isCovered else { return false }
    if case .listening = state { return true }
    return hasListener
  }

  private var isListening: Bool {
    if case .listening = service.state { return true }
    return service.listener != nil
  }

  func body(content: Content) -> some View {
    // Read here (not only inside the binding) so the presentation re-evaluates when covers change.
    let covers = listState.coversOnScreen
    let isCovered = covers.contains(.player) || covers.contains(.mediaServers)
    let screen = Self.showsListenerScreen(
      state: service.state, hasListener: service.listener != nil, isCovered: isCovered
    ) ? ListenerScreen() : nil

    content
      .fullScreenCover(
        item: Binding(
          get: { screen },
          // The cover only closes when the session ends (escape is ignored, there is no swipe).
          set: { _ in }
        ),
        onDismiss: { listState.coversOnScreen.remove(.listenTogether) }
      ) { _ in
        ListenTogetherListenerScreen(service: service)
          .onAppear { listState.coversOnScreen.insert(.listenTogether) }
      }
      .onChange(of: isListening, initial: true) { _, isListening in
        guard isListening else { return }
        // Close what is in the way; the listener screen follows once it has left.
        if playerState.isShowingPlayer { playerState.isShowingPlayer = false }
        if listState.activeIntegrationSheet != nil { listState.activeIntegrationSheet = nil }
      }
  }
}

/// The listener cover's content: "getting the book" until the book details arrive, then the player.
struct ListenTogetherListenerScreen: View {
  @ObservedObject var service: SharePlaySessionService

  var body: some View {
    if let listener = service.listener {
      ListenerPlayerView(service: service, listener: listener)
    } else {
      ListenerGettingBookView(service: service)
    }
  }
}

/// Shown between Join and the arrival of the book details. VoiceOver order: title (heading, first
/// focus), status, End, then what happens next. Two-finger Z does nothing, as on the player screen.
struct ListenerGettingBookView: View {
  @ObservedObject var service: SharePlaySessionService
  @StateObject private var theme = ThemeViewModel()
  @AccessibilityFocusState private var isTitleFocused: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text(service.joinedTitle ?? "listen_together_title".localized)
          .bpFont(.titleLarge)
          .foregroundStyle(theme.primaryColor)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityAddTraits(.isHeader)
          .accessibilityHeading(.h1)
          .accessibilityFocused($isTitleFocused)
        ListenTogetherBanner(service: service, onRemovedWhileFocused: { isTitleFocused = true })
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          ProgressView()
            .tint(theme.linkColor)
            .accessibilityHidden(true)
          Text("listen_together_getting_book_message".localized)
            .bpFont(.body)
            .foregroundStyle(theme.secondaryColor)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(16)
      .frame(maxWidth: 600, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .background(theme.systemBackgroundColor.ignoresSafeArea())
    .environmentObject(theme)
    // Escape is ignored on purpose: ending is only through the labelled End button.
    .accessibilityAction(.escape) {}
    .task {
      // Wait for the cover to finish presenting; an earlier request is often lost.
      try? await Task.sleep(for: .milliseconds(600))
      isTitleFocused = true
    }
  }
}

extension View {
  func listenTogetherPresentation(
    service: SharePlaySessionService, listState: ListStateManager, playerState: PlayerState
  ) -> some View {
    modifier(ListenTogetherPresentation(service: service, listState: listState, playerState: playerState))
  }
}
