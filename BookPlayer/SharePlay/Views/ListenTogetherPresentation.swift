import BookPlayerKit
import SwiftUI

/// Presents the Listen Together invitation sheet and the listener screen from MainView.
///
/// SwiftUI can't present them over the player cover or the media servers sheet (it silently drops
/// the presentation, and a blind user would never know). So those are closed first, and the
/// invitation or listener screen is presented once they have finished leaving
/// (`ListStateManager.coversOnScreen`). Both register in `coversOnScreen` like the player does.
struct ListenTogetherPresentation: ViewModifier {
  @ObservedObject var service: SharePlaySessionService
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let listState: ListStateManager
  let playerState: PlayerState

  struct Invitation: Identifiable {
    let title: String
    let author: String
    var id: String { title + "\u{1F}" + author }
  }

  struct Listener: Identifiable {
    let player: ListenerPlayer
    var id: ObjectIdentifier { ObjectIdentifier(player) }
  }

  private var pendingInvitation: Invitation? {
    guard case .invitation(let title, let author) = service.state else { return nil }
    return Invitation(title: title, author: author)
  }

  /// True while something MainView presents (other than Listen Together) is on screen or leaving.
  private var isCovered: Bool {
    listState.coversOnScreen.contains(.player) || listState.coversOnScreen.contains(.mediaServers)
  }

  private var invitationBinding: Binding<Invitation?> {
    Binding(
      get: { isCovered ? nil : pendingInvitation },
      set: { newValue in
        // Swipe-down or two-finger Z on the sheet counts as Not Now. After Join there is no
        // pending invitation any more, so nothing is declined.
        if newValue == nil, service.hasPendingInvitation { service.declineInvitation() }
      }
    )
  }

  private var listenerBinding: Binding<Listener?> {
    Binding(
      get: {
        guard !isCovered, !listState.coversOnScreen.contains(.listenTogetherInvitation),
          let player = service.listener
        else { return nil }
        return Listener(player: player)
      },
      // The cover only closes when the session ends (escape is ignored, there is no swipe).
      set: { _ in }
    )
  }

  func body(content: Content) -> some View {
    content
      .sheet(item: invitationBinding, onDismiss: {
        listState.coversOnScreen.remove(.listenTogetherInvitation)
      }) { invitation in
        ListenTogetherInvitationView(
          title: invitation.title,
          author: invitation.author,
          onJoin: { service.joinInvitation() },
          onDecline: { service.declineInvitation() }
        )
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .onAppear { listState.coversOnScreen.insert(.listenTogetherInvitation) }
      }
      .fullScreenCover(item: listenerBinding, onDismiss: {
        listState.coversOnScreen.remove(.listenTogether)
      }) { listener in
        ListenerPlayerView(service: service, listener: listener.player)
          .onAppear { listState.coversOnScreen.insert(.listenTogether) }
      }
      .onChange(of: pendingInvitation != nil || service.listener != nil, initial: true) { _, wantsScreen in
        guard wantsScreen else { return }
        // Close what is in the way; the presentation follows once it has left.
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
