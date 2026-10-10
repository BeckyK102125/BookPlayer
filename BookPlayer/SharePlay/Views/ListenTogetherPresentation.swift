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

  struct Listener: Identifiable {
    let player: ListenerPlayer
    var id: ObjectIdentifier { ObjectIdentifier(player) }
  }

  private var isListening: Bool {
    if case .listening = service.state { return true }
    return service.listener != nil
  }

  func body(content: Content) -> some View {
    // Read here (not only inside the binding) so the presentation re-evaluates when covers change.
    let covers = listState.coversOnScreen
    let isCovered = covers.contains(.player) || covers.contains(.mediaServers)
    let listener = isCovered ? nil : service.listener.map(Listener.init(player:))

    content
      .fullScreenCover(
        item: Binding(
          get: { listener },
          // The cover only closes when the session ends (escape is ignored, there is no swipe).
          set: { _ in }
        ),
        onDismiss: { listState.coversOnScreen.remove(.listenTogether) }
      ) { listener in
        ListenerPlayerView(service: service, listener: listener.player)
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

extension View {
  func listenTogetherPresentation(
    service: SharePlaySessionService, listState: ListStateManager, playerState: PlayerState
  ) -> some View {
    modifier(ListenTogetherPresentation(service: service, listState: listState, playerState: playerState))
  }
}
