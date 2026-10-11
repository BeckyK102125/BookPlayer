import BookPlayerKit
import Combine
import SwiftUI

/// The Listen Together row above the tab bar (R35/R36): what shows at the bottom of the main view
/// and what the row says. Pure decisions, unit tested.
enum ListenTogetherRow {
  enum Role: Equatable {
    case listener
    case sharer
  }

  /// Whose row it is; nil when there is no session on this device (or it is still being prepared).
  static func role(state: ListenTogetherState, hasListener: Bool) -> Role? {
    if hasListener { return .listener }
    switch state {
    case .listening: return .listener
    case .sharing: return .sharer
    case .idle, .needsFaceTime, .preparing, .invitation, .ended: return nil
    }
  }

  /// What sits above the tab bar. The row is above the mini player when both show.
  struct BottomBar: Equatable {
    var showsRow: Bool
    var showsMiniPlayer: Bool
  }

  /// R36: a listener's own mini player is hidden and the row takes its slot (its play button would
  /// start the library book over the shared one). The sharer keeps their mini player, with the row
  /// above it. The row stays in search and edit mode (it is the only way back to the listener screen)
  /// and hides only for the keyboard; the mini player hides for all three, as before.
  static func bottomBar(
    state: ListenTogetherState, hasListener: Bool, hasLoadedBook: Bool,
    isSearchingOrEditing: Bool, isKeyboardVisible: Bool
  ) -> BottomBar {
    let role = role(state: state, hasListener: hasListener)
    return BottomBar(
      showsRow: role != nil && !isKeyboardVisible,
      showsMiniPlayer: hasLoadedBook && role != .listener && !isSearchingOrEditing && !isKeyboardVisible)
  }

  /// What the listener's player is doing, read from `ListenerPlayer`.
  struct ListenerSnapshot: Equatable {
    var title: String
    var isPlaying: Bool
    var isWaiting: Bool
  }

  /// The row's value: the state word and the book title. The label is always "Listen Together", so
  /// a change is read as a new value while the row is focused, and Voice Control matches the label.
  static func value(
    state: ListenTogetherState, joinedTitle: String?, listener: ListenerSnapshot?, sharerTitle: String?
  ) -> String? {
    switch role(state: state, hasListener: listener != nil) {
    case .listener:
      guard let listener else {
        // The book is not here yet. Same 25 percent steps as the status line and the announcer.
        var downloaded = 0.0
        if case .listening(_, let fraction) = state { downloaded = fraction }
        let percent = min(Int((downloaded * 4).rounded(.down)) * 25, 100)
        let text = String.localizedStringWithFormat("listen_together_row_value_downloading".localized, percent)
        guard let joinedTitle, !joinedTitle.isEmpty else { return text }
        return text + ", " + joinedTitle
      }
      let title = listener.title.isEmpty ? "voiceover_no_title".localized : listener.title
      let key: String
      if listener.isWaiting {
        key = "listen_together_row_value_waiting"
      } else if listener.isPlaying {
        key = "listen_together_row_value_playing"
      } else {
        key = "listen_together_row_value_paused"
      }
      return String.localizedStringWithFormat(key.localized, title)
    case .sharer:
      guard let sharerTitle, !sharerTitle.isEmpty else {
        return "listen_together_row_value_sharing_untitled".localized
      }
      return String.localizedStringWithFormat("listen_together_row_value_sharing".localized, sharerTitle)
    case nil:
      return nil
    }
  }

  /// iOS 26.0 accessory mini player value for a sharer: "Listen Together, sharing". The mini player's
  /// label already has the title, so it is not repeated.
  static var sharerAccessoryValue: String {
    "listen_together_title".localized + ", " + "listen_together_row_value_sharing_untitled".localized
  }

  static func hint(for role: Role) -> String {
    switch role {
    case .listener: return "listen_together_row_hint_listener".localized
    case .sharer: return "listen_together_row_hint_sharer".localized
    }
  }
}

/// One button: "Listen Together, playing, Moby Dick". It only opens the Listen Together player (the
/// listener screen, or the sharer's player); it has no End action of any kind. It never announces:
/// the service makes every announcement.
struct ListenTogetherStatusRow: View {
  @ObservedObject var service: SharePlaySessionService
  /// Opens the sharer's player.
  let showPlayer: () -> Void
  /// iOS 26.0 only: drawn inside the tab view's bottom accessory, which supplies its own background.
  var isAccessory = false

  @Environment(\.listState) private var listState
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @EnvironmentObject private var theme: ThemeViewModel
  @EnvironmentObject private var playerManager: PlayerManager
  @AccessibilityFocusState private var isFocused: Bool
  @State private var snapshot: ListenTogetherRow.ListenerSnapshot?
  /// Built once, so the subscription is not replaced on every update.
  @State private var snapshots: AnyPublisher<ListenTogetherRow.ListenerSnapshot?, Never>
  @ScaledMetric(relativeTo: .headline) private var iconSize: CGFloat = 22

  init(service: SharePlaySessionService, isAccessory: Bool = false, showPlayer: @escaping () -> Void) {
    self.service = service
    self.isAccessory = isAccessory
    self.showPlayer = showPlayer
    _snapshots = State(initialValue: Self.snapshots(of: service))
    // Seeded now so the first frame already says playing or paused, not "getting the book".
    _snapshot = State(initialValue: service.listener.map(Self.snapshot(of:)))
  }

  var body: some View {
    let role = ListenTogetherRow.role(state: service.state, hasListener: service.listener != nil)
    let value = ListenTogetherRow.value(
      state: service.state, joinedTitle: service.joinedTitle, listener: snapshot,
      sharerTitle: playerManager.currentItem?.title)
    Group {
      if let role, let value {
        Button { activate(role) } label: { content(value: value) }
          .buttonStyle(.plain)
          .accessibilityLabel("listen_together_title".localized)
          .accessibilityValue(value)
          .accessibilityHint(ListenTogetherRow.hint(for: role))
          .accessibilityIdentifier("listenTogether.row")
          .accessibilityFocused($isFocused)
      }
    }
    .onReceive(snapshots) { snapshot = $0 }
    .onChange(of: listState.listenTogetherRowFocusRequest) { isFocused = true }
  }

  private func content(value: String) -> some View {
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
    return layout {
      if !dynamicTypeSize.isAccessibilitySize {
        Image(systemName: "shareplay")
          .resizable()
          .scaledToFit()
          .frame(width: iconSize, height: iconSize)
          .foregroundStyle(theme.linkColor)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text("listen_together_title".localized)
          .bpFont(.headline)
          .foregroundStyle(textStyle)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        Text(value)
          .bpFont(.subheadline)
          .foregroundStyle(textStyle)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, isAccessory ? 4 : 10)
    .frame(maxWidth: .infinity, minHeight: isAccessory ? 44 : 56, alignment: .leading)
    .background {
      if !isAccessory {
        // The theme's background, as the banner: not glass, so Reduce Transparency and Increase
        // Contrast can't break contrast.
        RoundedRectangle(cornerRadius: 12)
          .fill(theme.systemBackgroundColor)
          .overlay(
            RoundedRectangle(cornerRadius: 12)
              .stroke(theme.secondaryColor, lineWidth: 1)
          )
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: 12))
    .frame(maxWidth: 600)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, isAccessory ? 0 : 12)
  }

  /// In the accessory the text sits on system glass, so it uses the system label colour, which adapts
  /// to the glass, Reduce Transparency and Increase Contrast. Elsewhere it is on the theme background.
  private var textStyle: AnyShapeStyle {
    isAccessory ? AnyShapeStyle(.primary) : AnyShapeStyle(theme.primaryColor)
  }

  private func activate(_ role: ListenTogetherRow.Role) {
    switch role {
    case .listener:
      listState.isListenerScreenRequested = ListenTogetherPresentation.isListenerScreenRequested(
        after: .opened, current: listState.isListenerScreenRequested)
    case .sharer:
      showPlayer()
    }
  }

  private static func snapshot(of listener: ListenerPlayer) -> ListenTogetherRow.ListenerSnapshot {
    ListenTogetherRow.ListenerSnapshot(
      title: listener.manifest.title, isPlaying: listener.isPlaying, isWaiting: listener.isWaitingForPiece)
  }

  /// The listener's playing and waiting state, without observing its twice-a-second time.
  private static func snapshots(
    of service: SharePlaySessionService
  ) -> AnyPublisher<ListenTogetherRow.ListenerSnapshot?, Never> {
    service.$listener
      .map { listener -> AnyPublisher<ListenTogetherRow.ListenerSnapshot?, Never> in
        guard let listener else { return Just(nil).eraseToAnyPublisher() }
        let title = listener.manifest.title
        return listener.$isPlaying
          .combineLatest(listener.$isWaitingForPiece)
          .map { ListenTogetherRow.ListenerSnapshot(title: title, isPlaying: $0, isWaiting: $1) }
          .eraseToAnyPublisher()
      }
      .switchToLatest()
      .removeDuplicates()
      // No receive(on:): both objects are main-actor and publish on main; hopping would delay the value.
      .eraseToAnyPublisher()
  }
}
