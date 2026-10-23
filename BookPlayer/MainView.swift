//
//  MainView.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 12/8/25.
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

struct MainView: View {
  let showSecondOnboarding: () -> Void
  let showImport: () -> Void

  @State private var listState = ListStateManager()
  @StateObject private var theme = ThemeViewModel()
  @StateObject private var keyboardObserver = KeyboardObserver()
  /// A wire between SwiftUI views that MainCoordinator never touches, so it's owned here.
  /// Injected below, where the library sheets and the library tab both inherit it.
  @StateObject private var externalImportEvents = ExternalImportEvents()
  @Environment(\.libraryService) private var libraryService
  @Environment(\.playerState) private var playerState
  @Environment(\.syncService) private var syncService
  @Environment(\.jellyfinService) private var jellyfinService
  @Environment(\.audiobookshelfService) private var audiobookshelfService
  @Environment(\.playbackService) private var playbackService
  @Environment(\.colorScheme) private var scheme
  @Environment(\.horizontalSizeClass) private var hSize

  @EnvironmentObject private var listSyncRefreshService: ListSyncRefreshService
  @EnvironmentObject private var playerManager: PlayerManager
  @EnvironmentObject private var sharePlayService: SharePlaySessionService
  @EnvironmentObject private var importManager: ImportManager

  var body: some View {
    TabView {
      Tab("library_title", systemImage: "books.vertical") {
        LibraryRootView(
          showSecondOnboarding: showSecondOnboarding,
          showImport: showImport
        )
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(theme.systemBackgroundColor, for: .tabBar)
        .toolbar(listState.isEditing ? .hidden : .visible, for: .tabBar)
      }
      Tab("profile_title", systemImage: "person.crop.circle") {
        ProfileView()
      }
      Tab("settings_title", systemImage: "gearshape") {
        SettingsView()
      }
      Tab("search_title", systemImage: "magnifyingglass", role: .search) {
        SearchView {
          SearchViewModel(libraryService: libraryService)
        }
      }

    }
    /// Selecting the Search tab focuses its field right away; dismissing search returns to the previous tab
    .tabViewSearchActivation(.searchTabSelection)
    .miniPlayer(isEnabled: bottomBar.showsRow || bottomBar.showsMiniPlayer) {
      // R36 in the tab view's one accessory slot: a listener gets the Listen Together row there (their
      // own mini player is hidden); a sharer keeps the mini player, which shows and reads the sharing
      // status in place of the author.
      let bar = bottomBar
      if bar.showsRow && !bar.showsMiniPlayer {
        ListenTogetherStatusRow(service: sharePlayService, isAccessory: true, showPlayer: showPlayer)
          // The accessory's height is fixed: text stops growing at the largest non-accessibility size
          // (one row, no clipping) instead of wrapping; VoiceOver still reads the full label and value.
          .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
      } else if bar.showsMiniPlayer, let relativePath = playerState.loadedBookRelativePath {
        MiniPlayerAccessoryView(
          relativePath: relativePath, showPlayer: showPlayer,
          listenTogetherValue: bar.showsRow ? sharerStatus : nil)
      }
    }
    .sheet(item: $listState.activeLibrarySheet, onDismiss: {
      listState.coversOnScreen.remove(.mediaServers)
      listState.coversOnScreen.remove(.transferFromComputer)
    }) { sheet in
      switch sheet {
      case .mediaServers:
        NavigationStack {
          MediaServersView(
            jellyfinService: jellyfinService,
            audiobookshelfService: audiobookshelfService,
            style: .libraryEntry
          )
        }
        .environment(\.closeMediaServers, CloseMediaServersAction { listState.activeLibrarySheet = nil })
        .onAppear { listState.coversOnScreen.insert(.mediaServers) }
      case .transferFromComputer:
        TransferView {
          TransferViewModel(importManager: importManager, libraryService: libraryService)
        }
        .onAppear { listState.coversOnScreen.insert(.transferFromComputer) }
      }
    }
    .fullScreenCover(isPresented: playerState.isShowingPlayerBinding, onDismiss: {
      listState.coversOnScreen.remove(.player)
      // A sharer closed the player: land on the mini player, the way back to it, which shows and
      // reads the sharing status (a sharer has no separate Listen Together row).
      if case .sharing = sharePlayService.state {
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(500))
          ListenTogetherFocusRequests.shared.requestMiniPlayerFocus()
        }
      }
    }) {
      PlayerView {
        PlayerViewModel(
          libraryService: libraryService,
          playbackService: playbackService,
          playerManager: playerManager,
          syncService: syncService,
          sharePlayService: sharePlayService
        )
      }
      .presentationBackground(.clear)
      .onAppear { listState.coversOnScreen.insert(.player) }
      .playbackAlerts(playerState: playerState, whenPlayerVisible: true)
    }
    // Posted by the failure alert's Media Servers button (PlaybackAlerts) when a book can't
    // play because its media server isn't configured here. Lives at this level because both
    // pieces of state it writes are owned above: the cover has to come down before the sheet
    // can present, since the sheet is attached underneath it.
    .onReceive(NotificationCenter.default.publisher(for: .showMediaServers)) { _ in
      playerState.isShowingPlayer = false
      listState.activeLibrarySheet = .mediaServers
    }
    // Sibling copy (see PlaybackAlerts): playback also starts with the player CLOSED —
    // mini-player, CarPlay, remote commands, last-book restore — and the copy inside the cover
    // isn't in the hierarchy then, silently dropping the prompt.
    .playbackAlerts(playerState: playerState, whenPlayerVisible: false)
    // A prompt belongs to the context that raised it and is NOT handed over when the player
    // opens or closes — a deliberate product decision, not a workaround. The two-copy gate
    // exists so exactly one copy can present, not so a prompt can migrate: an alert raised
    // against a closed player, re-appearing over an open one after something else (a widget,
    // an intent, Siri) opened it, has lost the context that made it make sense.
    // Dropping it is the conservative half of that trade, and the alert is re-raised by the
    // next attempt anyway.
    .onChange(of: playerState.isShowingPlayer) {
      playerState.clearPrompts()
    }
    // A failure raised while backgrounded outlives the attempt that caused it, so playback
    // succeeding in the meantime has to retire it — otherwise coming back to the app shows an
    // error for something that is playing right now.
    .onReceive(NotificationCenter.default.publisher(for: .bookPlayed)) { _ in
      playerState.pendingFailure = nil
    }
    .listenTogetherPresentation(service: sharePlayService, listState: listState, playerState: playerState)
    .accessibilityAction(.magicTap) {
      // During Listen Together the shared book plays, not the paused library book.
      switch ListenTogetherPresentation.magicTapTarget(
        state: sharePlayService.state, hasListener: sharePlayService.listener != nil)
      {
      case .listener: sharePlayService.listener?.userTogglePlay()
      case .nothing:
        // Joined, book not here yet: the library book must stay paused; say why nothing happened.
        ListenTogetherPresentation.announceNotAvailableYet()
      case .libraryPlayer: playerManager.playPause()
      }
    }
    .environmentObject(theme)
    .environmentObject(externalImportEvents)
    .environment(\.listState, listState)
    .tint(theme.linkColor)
    .onChange(of: scheme) {
      ThemeManager.shared.checkSystemMode()
    }
    .onChange(of: playerState.showPlayer) {
      if playerState.showPlayer {
        showPlayer()
        playerState.showPlayer = false
      }
    }
    // SyncService owns the active/inactive decision (it observes account/subscription
    // changes itself). The view only reacts to sync becoming active to refresh the
    // library list — it no longer writes `isActive`.
    .onChange(of: syncService.isActive) { _, isActive in
      guard isActive else { return }
      Task {
        try? await listSyncRefreshService.syncList(at: nil)
        listState.reloadAll()
      }
    }
  }
  
  private var bottomBar: ListenTogetherRow.BottomBar {
    ListenTogetherRow.bottomBar(
      state: sharePlayService.state,
      hasListener: sharePlayService.listener != nil,
      hasLoadedBook: playerState.loadedBookRelativePath != nil,
      isSearchingOrEditing: listState.isSearching || listState.isEditing,
      isKeyboardVisible: keyboardObserver.isKeyboardVisible)
  }

  private var sharerStatus: String {
    ListenTogetherRow.sharerAccessoryValue(
      state: sharePlayService.state, title: playerManager.currentItem?.title,
      isRetryingSend: sharePlayService.notice == .retryingSend, pauseCause: sharePlayService.pauseCause,
      isWaitingForListeners: sharePlayService.isWaitingForListeners,
      ownInterruption: sharePlayService.ownInterruption)
  }

  func showPlayer() {
    /// The import screen is a UIKit presentation from the same screen as the player's cover, so the
    /// cover can't present over it, and `isShowingPlayer` would stay true with no player showing,
    /// leaving every later request (the mini player included) a no-op. The import wins
    guard !importManager.isImportScreenShown else { return }
    playerState.isShowingPlayer = true
  }
  
  func hasPlayerShown() -> Bool {
    return playerState.isShowingPlayer
  }
}

#Preview {
  MainView {
  } showImport: {
  }
}
