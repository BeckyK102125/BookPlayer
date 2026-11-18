//
//  LibraryService+Backup.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import CoreData
import Foundation

/// Keeping a copy of a file in Backup ("Cloud deleted files" in Settings) before a sync removes the item
/// that owns it. The item may be deleted only once its file is safely there (BP-20261112-03).
extension LibraryService {
  /// Removes the level's local items the server no longer lists. Each file goes to Backup first, and an
  /// item whose file couldn't be moved there is kept until a later sync.
  public func removeItems(notIn identifiers: [String], parentFolder: String?) async {
    return await withCheckedContinuation { continuation in
      let context = dataManager.getBackgroundContext()
      context.perform { [unowned self, context] in
        guard
          let items = getItems(notIn: identifiers, parentFolder: parentFolder, context: context)
        else {
          continuation.resume()
          return
        }

        let backupFolderURL = DataManager.getBackupFolderURL()
        let processedFolderURL = DataManager.getProcessedFolderURL()

        /// Only items whose files are safely in Backup are deleted; the rest stay until a later sync
        var removableItems = [SimpleLibraryItem]()
        for item in items
        where backUpBeforeRemoval(
          relativePath: item.relativePath,
          processedFolderURL: processedFolderURL,
          backupFolderURL: backupFolderURL
        ) {
          removableItems.append(item)
        }

        try? delete(removableItems, mode: .deep, context: context)
        continuation.resume()
      }
    }
  }

  /// Moves the file or folder at `relativePath` from Processed into Backup, under a free name if
  /// Backup already holds one with that name. True when there was nothing to keep (no file on this
  /// device) or the move succeeded; false when the file is still in Processed, so deleting the item
  /// would lose it.
  func backUpBeforeRemoval(
    relativePath: String,
    processedFolderURL: URL,
    backupFolderURL: URL,
    fileManager: FileManager = .default
  ) -> Bool {
    let sourceURL = processedFolderURL.appendingPathComponent(relativePath)
    var isDirectory: ObjCBool = false

    guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else { return true }

    let destinationURL = Self.freeBackupURL(
      for: backupFolderURL.appendingPathComponent(relativePath),
      isDirectory: isDirectory.boolValue,
      fileManager: fileManager
    )

    do {
      try fileManager.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try fileManager.moveItem(at: sourceURL, to: destinationURL)
      return true
    } catch {
      Self.logger.error("Kept an item a sync removed: its file couldn't be moved to Backup: \(error.localizedDescription)")
      return false
    }
  }

  /// `url` itself when nothing is there, else the first of `name-1.ext`, `name-2.ext`, … that is free.
  /// A folder's name is never split at a dot ("Vol. 2" becomes "Vol. 2-1").
  static func freeBackupURL(for url: URL, isDirectory: Bool, fileManager: FileManager) -> URL {
    guard fileManager.fileExists(atPath: url.path) else { return url }

    let folderURL = url.deletingLastPathComponent()
    let fileExtension = isDirectory ? "" : url.pathExtension
    let baseName = fileExtension.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    var counter = 1
    var candidateURL: URL

    repeat {
      let name = fileExtension.isEmpty ? "\(baseName)-\(counter)" : "\(baseName)-\(counter).\(fileExtension)"
      candidateURL = folderURL.appendingPathComponent(name)
      counter += 1
    } while fileManager.fileExists(atPath: candidateURL.path)

    return candidateURL
  }
}
