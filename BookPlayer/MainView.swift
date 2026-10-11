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
  @Environment(\.libraryService) private var libraryService
  @Environment(\.playerState) private var playerState
  @Environment(\.syncService) private var syncService
  @Environment(\.jellyfinService) private var jellyfinService
  @Environment(\.audiobookshelfService) private var audiobookshelfService
  @Environment(\.playbackService) private var playbackService
  @Environment(\.colorScheme) private var scheme
  @Environment(\.horizontalSizeClass) private var hSize

  @State private var tabBarContentHeight: CGFloat = 49

  @EnvironmentObject private var listSyncRefreshService: ListSyncRefreshService
  @EnvironmentObject private var playerManager: PlayerManager
  @EnvironmentObject private var sharePlayService: SharePlaySessionService

  var body: some View {
    TabView {
      Tab("library_title", systemImage: "books.vertical") {
        LibraryRootView(
          showSecondOnboarding: showSecondOnboarding,
          showImport: showImport
        )
        .background {
          TabBarHeightReader { height in
            if tabBarContentHeight != height {
              tabBarContentHeight = height
            }
          }
        }
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(theme.systemBackgroundColor, for: .tabBar)
        .toolbar(listState.isEditing ? .hidden : .visible, for: .tabBar)
        .onDrop(
          of: ImportableItem.readableTypeIdentifiers,
          isTargeted: nil
        ) { providers in
          handleDrop(providers)
          return true
        }
      }
      Tab("profile_title", systemImage: "person.crop.circle") {
        ProfileView()
      }
      Tab("settings_title", systemImage: "gearshape") {
        SettingsView()
      }
      if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom == .phone {
        Tab("search_title", systemImage: "magnifyingglass", role: .search) {
          SearchView {
            SearchViewModel(libraryService: libraryService)
          }
        }
      }

    }
    .miniPlayer {
      // R36: the Listen Together row sits in the mini player's slot, above the mini player when both
      // show; a listener's own mini player is hidden. One bottom clearance for the whole stack.
      let bar = bottomBar
      VStack(spacing: 8) {
        if bar.showsRow {
          ListenTogetherStatusRow(service: sharePlayService, showPlayer: showPlayer)
            .transition(.opacity)
        }
        if bar.showsMiniPlayer, let relativePath = playerState.loadedBookRelativePath {
          MiniPlayerView(relativePath: relativePath, showPlayer: showPlayer)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(), value: playerState.loadedBookRelativePath != nil)
        }
      }
      // Clear the tab bar, or in edit mode the editing toolbar that takes its place (so the row never
      // covers Move or Delete); in regular width outside edit mode only minimal spacing.
      .padding(
        .bottom,
        bar.showsRow || bar.showsMiniPlayer
          ? MiniPlayerLayout.bottomClearance(
            isCompact: hSize == .compact, isEditing: listState.isEditing, tabBarContentHeight: tabBarContentHeight)
          : 0
      )
      .animation(.easeInOut(duration: 0.25), value: bar)
    } accessoryContent: {
      // iOS 26.0 has a single accessory slot: a listener gets the row there; a sharer keeps the mini
      // player, which reads the sharing status as its value.
      let bar = bottomBar
      if bar.showsRow && !bar.showsMiniPlayer {
        ListenTogetherStatusRow(service: sharePlayService, isAccessory: true, showPlayer: showPlayer)
          // The accessory's height is fixed: text stops growing at the largest non-accessibility size
          // (one row, no clipping) instead of wrapping; VoiceOver still reads the full label and value.
          .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
      } else if bar.showsMiniPlayer, let relativePath = playerState.loadedBookRelativePath {
        MiniPlayerAccessoryView(
          relativePath: relativePath, showPlayer: showPlayer,
          listenTogetherValue: bar.showsRow ? ListenTogetherRow.sharerAccessoryValue : nil)
      }
    }
    .sheet(item: $listState.activeIntegrationSheet, onDismiss: {
      listState.coversOnScreen.remove(.mediaServers)
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
        .onAppear { listState.coversOnScreen.insert(.mediaServers) }
      }
    }
    .fullScreenCover(isPresented: playerState.isShowingPlayerBinding, onDismiss: {
      listState.coversOnScreen.remove(.player)
      // A sharer closed the player: land on the Listen Together row, the way back to it. On iOS 26.0
      // exactly there is no row for a sharer (the accessory mini player reads the status instead), so
      // the request finds no focused element and VoiceOver keeps its default landing, which is fine.
      if case .sharing = sharePlayService.state {
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(500))
          listState.listenTogetherRowFocusRequest += 1
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
    }
    .listenTogetherPresentation(service: sharePlayService, listState: listState, playerState: playerState)
    .accessibilityAction(.magicTap) {
      // During Listen Together the shared book plays, not the paused library book.
      switch ListenTogetherPresentation.magicTapTarget(
        state: sharePlayService.state, hasListener: sharePlayService.listener != nil)
      {
      case .listener: sharePlayService.listener?.userTogglePlay()
      case .nothing: break  // joined, book not here yet: the library book must stay paused
      case .libraryPlayer: playerManager.playPause()
      }
    }
    .environment(\.tabBarContentHeight, tabBarContentHeight)
    .environment(\.listenTogetherRowIsShown, bottomBar.showsRow)
    .environmentObject(theme)
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

  func showPlayer() {
    playerState.isShowingPlayer = true
  }
  
  func hasPlayerShown() -> Bool {
    return playerState.isShowingPlayer
  }

  func handleDrop(_ providers: [NSItemProvider]) {
    for provider in providers {
      let suggestedName = provider.suggestedName
      provider.loadObject(ofClass: ImportableItem.self) { [suggestedName] (object, _) in
        guard let item = object as? ImportableItem else { return }
        /// Set `suggesteName` from the provider
        item.suggestedName = suggestedName

        importData(from: item)
      }
    }
  }

  func importData(from item: ImportableItem) {
    let filename: String

    if let suggestedName = item.suggestedName {
      let pathExtension = (suggestedName as NSString).pathExtension
      /// Use  `suggestedFileExtension` only if the curret name does not include an extension
      if pathExtension.isEmpty {
        filename = "\(suggestedName).\(item.suggestedFileExtension)"
      } else {
        filename = suggestedName
      }
    } else {
      /// Fallback if the provider didn't have a suggested name
      filename = "\(Date().timeIntervalSince1970).\(item.suggestedFileExtension)"
    }

    let destinationURL = DataManager.getDocumentsFolderURL()
      .appendingPathComponent(filename)

    do {
      try item.data.write(to: destinationURL)
    } catch {
      print("Fail to move dropped file to the Documents directory: \(error.localizedDescription)")
    }
  }
}

#Preview {
  MainView {
  } showImport: {
  }
}
