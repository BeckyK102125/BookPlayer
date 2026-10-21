//
//  LastBookStartPlaybackIntent.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 30/9/23.
//  Copyright © 2023 BookPlayer LLC. All rights reserved.
//

import AppIntents
import BookPlayerKit
import Foundation

@available(macOS 14.0, watchOS 10.0, *)
struct LastBookStartPlaybackIntent: AudioPlaybackIntent {
  static var title: LocalizedStringResource = "intent_lastbook_play_title"

  #if !MAIN_APP
  @Dependency
  var playerLoaderService: PlayerLoaderService

  @Dependency
  var libraryService: LibraryService
  #endif

  func perform() async throws -> some IntentResult {
    #if MAIN_APP
    let coreServices = try await AppServices.shared.awaitCoreServices()
    let playerLoaderService = coreServices.playerLoaderService
    let libraryService = coreServices.libraryService
    #endif

    guard let book = libraryService.getLastPlayedItems(limit: 1)?.first else {
      throw "intent_lastbook_empty_error".localized
    }

    #if MAIN_APP
    // Listen Together (fork audit A17): a listener leaves first; a sharer can only resume the shared book.
    _ = try await ListenTogetherIntentRouting.handle(.startBook(relativePath: book.relativePath, title: book.title))
    try await AppServices.shared.loadAndKeepAlive(
      relativePath: book.relativePath,
      playerLoaderService: playerLoaderService
    )
    #else
    try await playerLoaderService.loadPlayer(book.relativePath, autoplay: true)
    #endif

    return .result()
  }
}
