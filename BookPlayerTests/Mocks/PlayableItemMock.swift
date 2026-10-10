//
//  PlayableItemMock.swift
//  BookPlayerTests
//
//  Created by gianni.carlo on 5/6/23.
//  Copyright © 2023 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation

extension PlayableItem {
  static var mock: PlayableItem {
    return PlayableItem(
      title: "test-title",
      author: "test-author",
      chapters: [
        PlayableChapter(
          title: "test-chapter",
          author: "test-author",
          start: 0,
          duration: 100,
          relativePath: "test-path",
          remoteURL: nil,
          index: 0
        )
      ],
      currentTime: 0,
      duration: 100,
      relativePath: "test-path",
      uuid: "LEGACY_UUID",
      parentFolder: nil,
      percentCompleted: 0,
      lastPlayDate: nil,
      isFinished: false,
      isBoundBook: false
    )
  }

  static func mockWithExtension(_ fileExtension: String) -> PlayableItem {
    return PlayableItem(
      title: "test-title",
      author: "test-author",
      chapters: [
        PlayableChapter(
          title: "test-chapter",
          author: "test-author",
          start: 0,
          duration: 100,
          relativePath: "test-path",
          remoteURL: nil,
          index: 0
        )
      ],
      currentTime: 0,
      duration: 100,
      relativePath: "test-path.\(fileExtension)",
      uuid: "LEGACY_UUID",
      parentFolder: nil,
      percentCompleted: 0,
      lastPlayDate: nil,
      isFinished: false,
      isBoundBook: false
    )
  }
}

extension PlayableItem {
  /// Single-chapter item spanning the whole duration. When `fileURL` is given, the chapter's
  /// `relativePath` is its last path component, so `PlayableChapter.fileURL` resolves to
  /// `DataManager.getProcessedFolderURL()/<name>`.
  static func stub(
    currentTime: TimeInterval,
    duration: TimeInterval,
    fileURL: URL? = nil
  ) -> PlayableItem {
    let path = fileURL?.lastPathComponent ?? "stub-\(UUID().uuidString).m4a"
    return PlayableItem(
      title: "stub-title",
      author: "stub-author",
      chapters: [
        PlayableChapter(
          title: "stub-chapter",
          author: "stub-author",
          start: 0,
          duration: duration,
          relativePath: path,
          remoteURL: nil,
          index: 0
        )
      ],
      currentTime: currentTime,
      duration: duration,
      relativePath: path,
      uuid: UUID().uuidString,
      parentFolder: nil,
      percentCompleted: 0,
      lastPlayDate: nil,
      isFinished: false,
      isBoundBook: false
    )
  }
}
