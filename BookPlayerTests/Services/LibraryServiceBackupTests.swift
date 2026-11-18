//
//  LibraryServiceBackupTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

/// BP-20261112-03: a sync removal deletes an item only once its file is safely in Backup.
@MainActor
final class LibraryServiceBackupTests: XCTestCase {
  var sut: LibraryService!
  var temporaryFolderURL: URL!

  override func setUpWithError() throws {
    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    DataTestUtils.clearFolderContents(url: DataManager.getBackupFolderURL())
    let dataManager = DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null"))
    sut = LibraryService()
    sut.setup(dataManager: dataManager, audioMetadataService: AudioMetadataService())
    _ = sut.getLibrary()

    temporaryFolderURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("LibraryServiceBackupTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporaryFolderURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: DataManager.getBackupFolderURL().path
    )
    DataTestUtils.clearFolderContents(url: DataManager.getBackupFolderURL())
    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    try? FileManager.default.removeItem(at: temporaryFolderURL)
    sut = nil
  }

  // MARK: - backUpBeforeRemoval

  func testNoFileOnThisDeviceNeedsNoBackup() throws {
    let (processedURL, backupURL) = try makeFolders()

    XCTAssertTrue(
      sut.backUpBeforeRemoval(relativePath: "missing.mp3", processedFolderURL: processedURL, backupFolderURL: backupURL)
    )
  }

  func testAnOlderBackupWithTheSameNameIsKeptAndTheFileGetsAFreeName() throws {
    let (processedURL, backupURL) = try makeFolders()
    let older = Data("older audio".utf8)
    let current = Data("current audio".utf8)
    try older.write(to: backupURL.appendingPathComponent("book.mp3"))
    try current.write(to: processedURL.appendingPathComponent("book.mp3"))

    XCTAssertTrue(
      sut.backUpBeforeRemoval(relativePath: "book.mp3", processedFolderURL: processedURL, backupFolderURL: backupURL)
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: processedURL.appendingPathComponent("book.mp3").path))
    XCTAssertEqual(try Data(contentsOf: backupURL.appendingPathComponent("book.mp3")), older)
    XCTAssertEqual(try Data(contentsOf: backupURL.appendingPathComponent("book-1.mp3")), current)
  }

  func testAFolderInsideAFolderIsBackedUpUnderAFreeNameWithoutSplittingADot() throws {
    let (processedURL, backupURL) = try makeFolders()
    try FileManager.default.createDirectory(
      at: processedURL.appendingPathComponent("Series/Vol. 2"),
      withIntermediateDirectories: true
    )
    try Data("part".utf8).write(to: processedURL.appendingPathComponent("Series/Vol. 2/part.mp3"))
    try FileManager.default.createDirectory(
      at: backupURL.appendingPathComponent("Series/Vol. 2"),
      withIntermediateDirectories: true
    )

    XCTAssertTrue(
      sut.backUpBeforeRemoval(relativePath: "Series/Vol. 2", processedFolderURL: processedURL, backupFolderURL: backupURL)
    )

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("Series/Vol. 2-1/part.mp3").path)
    )
  }

  func testAFailedMoveLeavesTheFileInPlaceAndSaysSo() throws {
    let (processedURL, backupURL) = try makeFolders()
    try FileManager.default.createDirectory(
      at: processedURL.appendingPathComponent("Folder"),
      withIntermediateDirectories: true
    )
    let current = Data("current audio".utf8)
    try current.write(to: processedURL.appendingPathComponent("Folder/book.mp3"))
    // A file where the backup's parent folder has to go: the folder can't be created
    try Data("in the way".utf8).write(to: backupURL.appendingPathComponent("Folder"))

    XCTAssertFalse(
      sut.backUpBeforeRemoval(relativePath: "Folder/book.mp3", processedFolderURL: processedURL, backupFolderURL: backupURL)
    )

    XCTAssertEqual(try Data(contentsOf: processedURL.appendingPathComponent("Folder/book.mp3")), current)
  }

  // MARK: - removeItems(notIn:parentFolder:)

  func testARemovedBookIsBackedUpBesideAnOlderBackupThenDeleted() async throws {
    let current = Data("current audio".utf8)
    let older = Data("older audio".utf8)
    let fileURL = DataTestUtils.generateTestFile(
      name: "book.txt",
      contents: current,
      destinationFolder: DataManager.getProcessedFolderURL()
    )
    _ = await sut.insertItems(from: [fileURL])
    try older.write(to: DataManager.getBackupFolderURL().appendingPathComponent("book.txt"))

    await sut.removeItems(notIn: [], parentFolder: nil)

    XCTAssertFalse(itemExists(relativePath: "book.txt"))
    XCTAssertEqual(try Data(contentsOf: DataManager.getBackupFolderURL().appendingPathComponent("book.txt")), older)
    XCTAssertEqual(try Data(contentsOf: DataManager.getBackupFolderURL().appendingPathComponent("book-1.txt")), current)
  }

  func testABookWhoseFileCantBeBackedUpIsKept() async throws {
    let current = Data("current audio".utf8)
    let fileURL = DataTestUtils.generateTestFile(
      name: "book.txt",
      contents: current,
      destinationFolder: DataManager.getProcessedFolderURL()
    )
    _ = await sut.insertItems(from: [fileURL])
    // Backup refuses new entries, so the move fails
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555],
      ofItemAtPath: DataManager.getBackupFolderURL().path
    )

    await sut.removeItems(notIn: [], parentFolder: nil)

    XCTAssertTrue(itemExists(relativePath: "book.txt"))
    XCTAssertEqual(
      try Data(contentsOf: DataManager.getProcessedFolderURL().appendingPathComponent("book.txt")),
      current
    )
  }

  // MARK: - Helpers

  private func makeFolders() throws -> (processed: URL, backup: URL) {
    let processedURL = temporaryFolderURL.appendingPathComponent("Processed")
    let backupURL = temporaryFolderURL.appendingPathComponent("Backup")
    try FileManager.default.createDirectory(at: processedURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: true)
    return (processedURL, backupURL)
  }

  private func itemExists(relativePath: String) -> Bool {
    let service: LibraryService = sut
    let context = service.dataManager.getBackgroundContext()
    var exists = false
    context.performAndWait {
      exists = service.getItemReference(with: relativePath, context: context) != nil
    }
    return exists
  }
}
