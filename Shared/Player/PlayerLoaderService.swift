//
//  PlayerLoaderService.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 3/10/24.
//  Copyright © 2024 BookPlayer LLC. All rights reserved.
//

import Foundation

@Observable
public final class PlayerLoaderService: @unchecked Sendable {
  public var syncService: SyncService!
  public var libraryService: LibraryService!
  public var playbackService: PlaybackServiceProtocol!
  public var playerManager: PlayerManagerProtocol!
  /// Asked before a book starts playing through this service. The main app sets it (Listen Together:
  /// during a listener session it asks "Leave Listen Together to play this book?"). nil means play.
  /// The argument is the title of the book that would start (nil when unknown).
  @ObservationIgnored public var playbackStartGate: (@MainActor (_ bookTitle: String?) async -> Bool)?

  public init() {}

  /// Whether a book may start playing now (see `playbackStartGate`).
  @MainActor
  public func mayStartPlayback(bookTitle: String? = nil) async -> Bool {
    guard let playbackStartGate else { return true }
    return await playbackStartGate(bookTitle)
  }

  /// Play/pause for the book that is already loaded. Starting it goes through `mayStartPlayback()`;
  /// pausing never asks.
  @MainActor
  public func playPauseLoadedBook() async {
    if !playerManager.isPlaying, !(await mayStartPlayback(bookTitle: playerManager.currentItem?.title)) { return }
    playerManager.playPause()
  }

  /// Plays the book that is already loaded, if `mayStartPlayback()` allows it.
  @MainActor
  public func playLoadedBook() async {
    guard await mayStartPlayback(bookTitle: playerManager.currentItem?.title) else { return }
    playerManager.play()
  }

  public func setup(
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

  /// Returns false when nothing was loaded because `playbackStartGate` declined a load that would play
  /// (callers then don't open the player).
  @MainActor
  @discardableResult
  public func loadPlayer(
    _ relativePath: String,
    intent: PlayIntent,
    recordAsLastBook: Bool = true
  ) async throws -> Bool {
    // The loader's contract is a RELATIVE PATH — every launch surface speaks paths (App
    // Intents, CarPlay, search, watch, last-book restore, deep links). Resolution to the
    // item (and its uuid) happens here, in one place. A path that no longer resolves
    // (stale last-book restore, CarPlay/watch reference to a deleted item) must THROW —
    // develop surfaced fileMissing here, and a silent return leaves the tap doing
    // nothing with no explanation.
    guard let libraryItem = self.libraryService.getSimpleItem(with: relativePath)
    else {
      throw BPPlayerError.fileMissing(relativePath: relativePath)
    }
    
    let fileURL = DataManager.getProcessedFolderURL().appendingPathComponent(libraryItem.relativePath)
    
    // Only a media-server link can serve the file instead: a Hardcover link has none
    if syncService.isActive == false,
       libraryItem.externalResources?.streamingResource == nil,
       !FileManager.default.fileExists(atPath: fileURL.path)
    {
      throw BPPlayerError.fileMissing(relativePath: libraryItem.relativePath)
    }
    
    if case .wantsToPlay = intent, !(await mayStartPlayback(bookTitle: libraryItem.title)) {
      return false
    }
    
    // Only load if loaded book is a different one. Guard on a REAL uuid: two items
    // carrying a placeholder/empty uuid would otherwise match as "already loaded" and
    // the second tap would silently no-op (same rule as PlayableItem.id).
    if playerManager.hasLoadedBook() == true,
       Constants.isRealUuid(libraryItem.uuid),
       libraryItem.uuid == playerManager.currentItem?.uuid
    {
      if case .wantsToPlay(let origin) = intent {
        playerManager.play(origin: origin)
      }
      return true
    }
    
    /// If the selected item is a bound book, check that the contents are loaded
    if syncService.isActive == true,
       libraryItem.type == .bound,
       libraryService.getMaxItemsCount(at: libraryItem.relativePath) == 0
    {
      _ = try await syncService.syncListContents(at: libraryItem.relativePath)
    }
    
    let item = try self.playbackService.getPlayableItem(from: libraryItem)
    
    playerManager.load(item, intent: intent)
    
    if recordAsLastBook {
      libraryService.setLibraryLastBook(with: item.relativePath)
    }
    return true
  }
}
