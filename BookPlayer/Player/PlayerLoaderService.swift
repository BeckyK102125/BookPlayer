//
//  PlayerLoaderService.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 3/10/24.
//  Copyright © 2024 BookPlayer LLC. All rights reserved.
//

#if os(watchOS)
  import BookPlayerWatchKit
#else
  import BookPlayerKit
#endif
import Foundation

@Observable
final class PlayerLoaderService: @unchecked Sendable {
  var syncService: SyncService!
  var libraryService: LibraryService!
  var playbackService: PlaybackServiceProtocol!
  var playerManager: PlayerManagerProtocol!
  /// Asked before a book starts playing through this service. The main app sets it (Listen Together:
  /// during a listener session it asks "Leave Listen Together to play this book?"). nil means play.
  @ObservationIgnored var playbackStartGate: (@MainActor () async -> Bool)?

  init() {}

  /// Whether a book may start playing now (see `playbackStartGate`).
  @MainActor
  func mayStartPlayback() async -> Bool {
    guard let playbackStartGate else { return true }
    return await playbackStartGate()
  }

  /// Play/pause for the book that is already loaded. Starting it goes through `mayStartPlayback()`;
  /// pausing never asks.
  @MainActor
  func playPauseLoadedBook() async {
    if !playerManager.isPlaying, !(await mayStartPlayback()) { return }
    playerManager.playPause()
  }

  /// Plays the book that is already loaded, if `mayStartPlayback()` allows it.
  @MainActor
  func playLoadedBook() async {
    guard await mayStartPlayback() else { return }
    playerManager.play()
  }

  func setup(
    syncService: SyncService,
    libraryService: LibraryService,
    playbackService: PlaybackServiceProtocol,
    playerManager: PlayerManagerProtocol
  ) {
    self.syncService = syncService
    self.libraryService = libraryService
    self.playbackService = playbackService
    self.playerManager = playerManager
  }

  /// Returns false when nothing was loaded because `playbackStartGate` declined an autoplay load
  /// (callers then don't open the player).
  @MainActor
  @discardableResult
  func loadPlayer(
    _ relativePath: String,
    autoplay: Bool,
    recordAsLastBook: Bool = true
  ) async throws -> Bool {
    let fileURL = DataManager.getProcessedFolderURL().appendingPathComponent(relativePath)

    if syncService.isActive == false,
      !FileManager.default.fileExists(atPath: fileURL.path)
    {
      throw BPPlayerError.fileMissing(relativePath: relativePath)
    }

    if autoplay, !(await mayStartPlayback()) { return false }

    // Only load if loaded book is a different one
    if playerManager.hasLoadedBook() == true,
      relativePath == playerManager.currentItem?.relativePath
    {
      if autoplay {
        playerManager.play()
      }
      return true
    }

    guard
      let libraryItem = self.libraryService.getSimpleItem(with: relativePath)
    else { return true }

    /// If the selected item is a bound book, check that the contents are loaded
    if syncService.isActive == true,
      libraryItem.type == .bound,
      libraryService.getMaxItemsCount(at: relativePath) == 0
    {
      _ = try await syncService.syncListContents(at: relativePath)
    }

    let item = try self.playbackService.getPlayableItem(from: libraryItem)

    playerManager.load(item, autoplay: autoplay)

    if recordAsLastBook {
      libraryService.setLibraryLastBook(with: item.relativePath)
    }
    return true
  }
}
