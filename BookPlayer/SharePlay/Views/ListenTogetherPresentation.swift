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

  /// Whether the listener screen is shown: while the user wants it (`isRequested`: on from the session
  /// start or the Listen Together row, off after escape), from the moment this device is listening
  /// (before the book details arrive, so a VoiceOver user always has the status and End), and while a
  /// listener player exists; never while a cover it can't be presented over is still on screen.
  static func showsListenerScreen(
    state: ListenTogetherState, hasListener: Bool, isCovered: Bool, isRequested: Bool
  ) -> Bool {
    guard isRequested, !isCovered else { return false }
    if case .listening = state { return true }
    return hasListener
  }

  /// What changes whether the user wants the listener screen up.
  enum ListenerScreenEvent: Equatable {
    /// This device started listening (Join): the screen presents itself.
    case sessionStarted
    /// The Listen Together row, or any other explicit open.
    case opened
    /// Escape, or the system dismissed the cover. Never ends anything (R35).
    case closedByUser
    case stateChanged(ListenTogetherState)
  }

  /// Only a real change from not listening to listening is a session start. `onChange(initial:)` also
  /// fires when the view is rebuilt (old == new); that must not undo an escape.
  static func isSessionStart(wasListening: Bool, isListening: Bool) -> Bool {
    !wasListening && isListening
  }

  /// R35: escape closes the listener screen and service state alone never brings it back. The session
  /// ending, or a new invitation, clears the request so nothing stale pops a screen up later; the next
  /// session start sets it again.
  static func isListenerScreenRequested(after event: ListenerScreenEvent, current: Bool) -> Bool {
    switch event {
    case .sessionStarted, .opened:
      return true
    case .closedByUser:
      return false
    case .stateChanged(let state):
      if case .listening = state { return current }
      return false
    }
  }

  /// The escape action on the listener screen and on "Getting the book": close the screen, nothing
  /// else. It takes no service on purpose: it can't end, pause or start anything.
  static func closeListenerScreen(listState: ListStateManager) {
    listState.isListenerScreenRequested = isListenerScreenRequested(
      after: .closedByUser, current: listState.isListenerScreenRequested)
  }

  /// After the listener screen has gone, VoiceOver focus moves to the Listen Together row only when the
  /// user closed it and the session is still on. When the session ended, the "ended" announcement owns
  /// the moment and the row is gone.
  static func focusesRowAfterListenerScreenCloses(
    state: ListenTogetherState, hasListener: Bool, isRequested: Bool
  ) -> Bool {
    guard !isRequested else { return false }
    return ListenTogetherRow.role(state: state, hasListener: hasListener) == .listener
  }

  /// Who a Magic Tap (two-finger double tap) reaches from MainView. While this device is in a listener
  /// session the library book must never play: before the book details arrive there is nothing to play.
  enum MagicTapTarget: Equatable {
    case listener
    case nothing
    case libraryPlayer
  }

  static func magicTapTarget(state: ListenTogetherState, hasListener: Bool) -> MagicTapTarget {
    if hasListener { return .listener }
    if case .listening = state { return .nothing }
    return .libraryPlayer
  }

  /// What Magic Tap says when it reaches nothing (joined, book not here yet): "Waiting for the book.
  /// Play is not available yet.", the same as the lock-screen path in AppDelegate. nil when it acted.
  static func magicTapAnnouncement(for target: MagicTapTarget) -> String? {
    target == .nothing ? "listen_together_not_available_now".localized : nil
  }

  /// Repeated Magic Taps say it once per 2 seconds, so the speech doesn't stack.
  @MainActor private static var notAvailableLimiter = ListenTogetherRepeatLimiter(interval: 2)

  /// Says "Waiting for the book. Play is not available yet." Queued, so it doesn't cut off speech.
  @MainActor
  static func announceNotAvailableYet() {
    guard let text = magicTapAnnouncement(for: .nothing), notAvailableLimiter.allows(at: Date()) else { return }
    ListenTogetherAnnouncer.postQueued(text)
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
      state: service.state, hasListener: service.listener != nil, isCovered: isCovered,
      isRequested: listState.isListenerScreenRequested
    ) ? ListenerScreen() : nil

    content
      .fullScreenCover(
        item: Binding(
          get: { screen },
          // Escape closes the screen (R35); a dismissal the system makes is respected the same way.
          set: { newValue in
            if newValue == nil { Self.closeListenerScreen(listState: listState) }
          }
        ),
        onDismiss: {
          listState.coversOnScreen.remove(.listenTogether)
          // A listener's ending alert waits for this (guidance A.0).
          ListenTogetherCoverTracker.shared.coverDismissed()
          guard Self.focusesRowAfterListenerScreenCloses(
            state: service.state, hasListener: service.listener != nil,
            isRequested: listState.isListenerScreenRequested)
          else { return }
          Task { @MainActor in
            // Let the cover finish leaving; an earlier focus request is often lost.
            try? await Task.sleep(for: .milliseconds(500))
            listState.listenTogetherRowFocusRequest += 1
          }
        }
      ) { _ in
        ListenTogetherListenerScreen(service: service, onClose: { Self.closeListenerScreen(listState: listState) })
          .onAppear {
            listState.coversOnScreen.insert(.listenTogether)
            ListenTogetherCoverTracker.shared.coverAppeared()
          }
      }
      .onChange(of: isListening, initial: true) { wasListening, isListening in
        guard isListening else { return }
        if Self.isSessionStart(wasListening: wasListening, isListening: isListening) {
          listState.isListenerScreenRequested = Self.isListenerScreenRequested(
            after: .sessionStarted, current: listState.isListenerScreenRequested)
        }
        // Close what is in the way; the listener screen follows once it has left.
        if playerState.isShowingPlayer { playerState.isShowingPlayer = false }
        if listState.activeIntegrationSheet != nil { listState.activeIntegrationSheet = nil }
      }
      .onChange(of: service.state) { _, state in
        listState.isListenerScreenRequested = Self.isListenerScreenRequested(
          after: .stateChanged(state), current: listState.isListenerScreenRequested)
      }
  }
}

/// The listener cover's content: "getting the book" until the book details arrive, then the player.
///
/// "Leave Listen Together?" lives here (leave guidance, trap 1): this view stays the same when the book
/// details arrive and "getting the book" is replaced by the player, so the question is not dropped from
/// under the user, and the player doesn't move focus to the title while it is up.
struct ListenTogetherListenerScreen: View {
  @ObservedObject var service: SharePlaySessionService
  /// Escape: closes the screen only; the session keeps going (R35).
  let onClose: () -> Void
  /// Set once the getting-book view has appeared, so the player that replaces it moves focus sooner
  /// (the cover has been up for a while; the long wait is only for a fresh presentation).
  @State private var cameFromGettingBook = false
  @State private var isConfirmingLeave = false
  /// The player replaced "getting the book" while the question was up: Cancel then returns focus to the
  /// player's title, because the Leave button it came from no longer exists (a11y M5).
  @State private var swappedWhileConfirming = false
  @State private var titleFocusRequest = 0

  var body: some View {
    Group {
      if let listener = service.listener {
        ListenerPlayerView(
          service: service, listener: listener,
          initialFocusDelay: cameFromGettingBook ? .milliseconds(150) : .milliseconds(600),
          isConfirmingLeave: $isConfirmingLeave,
          titleFocusRequest: titleFocusRequest,
          onRequestLeave: { isConfirmingLeave = true },
          onClose: onClose)
      } else {
        ListenerGettingBookView(service: service, onRequestLeave: { isConfirmingLeave = true }, onClose: onClose)
          .onAppear { cameFromGettingBook = true }
      }
    }
    .onChange(of: service.listener != nil) { _, hasListener in
      if hasListener, isConfirmingLeave { swappedWhileConfirming = true }
    }
    .onChange(of: isConfirmingLeave) { _, confirming in
      if confirming { swappedWhileConfirming = false }
    }
    .listenTogetherLeaveConfirmation(isPresented: $isConfirmingLeave, service: service) {
      guard swappedWhileConfirming else { return }
      swappedWhileConfirming = false
      titleFocusRequest += 1
    }
    // Second signal that the cover has gone, in case its onDismiss never arrives (fix round 1, I2).
    .onDisappear { ListenTogetherCoverTracker.shared.coverDismissed() }
  }
}

/// Shown between Join and the arrival of the book details. VoiceOver order: Done, title (heading, first
/// focus), what happens next, status, then Leave Listen Together (full width under the status card, the
/// screen's action). Done and two-finger Z close the screen only, as on the player screen: the session
/// and the download keep going and the Listen Together row brings it back.
struct ListenerGettingBookView: View {
  @ObservedObject var service: SharePlaySessionService
  /// Leave Listen Together: asks through the listener screen.
  let onRequestLeave: () -> Void
  /// Escape: closes the screen only (R35).
  let onClose: () -> Void
  @StateObject private var theme = ThemeViewModel()
  @AccessibilityFocusState private var isTitleFocused: Bool
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // Closes the screen only, like the two-finger scrub; the download keeps going.
        ListenTogetherDoneButton(action: onClose)
        Text(service.joinedTitle ?? "listen_together_title".localized)
          .bpFont(.titleLarge)
          .foregroundStyle(theme.primaryColor)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityAddTraits(.isHeader)
          .accessibilityHeading(.h1)
          .accessibilityFocused($isTitleFocused)
        // The explanation comes right after the title so it is heard before the status and End.
        (dynamicTypeSize.isAccessibilitySize
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
          : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))) {
          ProgressView()
            .tint(theme.primaryColor)
            .accessibilityHidden(true)
          // Primary, not secondary: secondary is below 4.5:1 in most light themes (A9).
          Text("listen_together_getting_book_message".localized)
            .bpFont(.body)
            .foregroundStyle(theme.primaryColor)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        // The status element's Leave action asks through the screen's one confirmation too (I3).
        ListenTogetherBanner(
          service: service, onRemovedWhileFocused: { isTitleFocused = true }, showsActionButton: false,
          onRequestLeave: onRequestLeave)
        // The screen's action: one control, full width, outside the status card.
        if let action = ListenTogetherSessionAction.action(
      for: service.state, usesOwnCopy: service.isUsingOwnCopy, audience: service.leaveAudience) {
          ListenTogetherSessionButton(action: action, isFullWidth: true) { onRequestLeave() }
        }
      }
      .padding(16)
      .frame(maxWidth: 600, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .background(theme.systemBackgroundColor.ignoresSafeArea())
    .environmentObject(theme)
    // Escape closes the screen only (R35): never ends, pauses or starts anything. Ending is only
    // through the labelled End button. A full-screen cover doesn't close on escape by itself.
    .accessibilityAction(.escape) { onClose() }
    // Nothing to play yet: say so, and don't let Magic Tap reach the library player in MainView.
    .accessibilityAction(.magicTap) { ListenTogetherPresentation.announceNotAvailableYet() }
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
