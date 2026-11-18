//
//  ImportOperationArchiveTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

/// BP-20261112-07: an archive is removed only after it's extracted, and only when the app owns it.
final class ImportOperationArchiveTests: XCTestCase {
  private var externalFolderURL: URL!

  override func setUpWithError() throws {
    DataTestUtils.clearFolderContents(url: DataManager.getDocumentsFolderURL())
    externalFolderURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ImportOperationArchiveTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: externalFolderURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: externalFolderURL)
    DataTestUtils.clearFolderContents(url: DataManager.getDocumentsFolderURL())
  }

  func testACorruptArchiveIsKeptAndNothingIsImported() {
    let archive = DataTestUtils.generateTestFile(
      name: "broken.zip",
      contents: Data("not a zip archive".utf8),
      destinationFolder: DataManager.getDocumentsFolderURL()
    )
    let operation = ImportOperation(files: [archive], libraryService: makeLibraryService())

    run(operation)

    XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    XCTAssertTrue(operation.processedFiles.isEmpty)
    XCTAssertNil(operation.suggestedFolderName)
  }

  func testAFailedExtractionKeepsTheArchiveAndStillImportsTheOtherFiles() throws {
    let archive = DataTestUtils.generateTestFile(
      name: "book.zip",
      contents: Data("archive".utf8),
      destinationFolder: DataManager.getDocumentsFolderURL()
    )
    let other = DataTestUtils.generateTestFile(
      name: "other-\(UUID().uuidString).txt",
      contents: Data("other".utf8),
      destinationFolder: DataManager.getDocumentsFolderURL()
    )
    var extractionFolder: URL?
    let operation = ImportOperation(
      files: [archive, other],
      libraryService: makeLibraryService(),
      unzip: { _, destination in
        extractionFolder = destination
        return false
      }
    )

    run(operation)

    XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    XCTAssertEqual(operation.processedFiles.map(\.lastPathComponent), [other.lastPathComponent])
    let folder = try XCTUnwrap(extractionFolder)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    if let processedFile = operation.processedFiles.first {
      try? FileManager.default.removeItem(at: processedFile)
    }
  }

  func testAnExtractedArchiveTheAppOwnsIsRemovedAndItsFilesImported() throws {
    let archive = DataTestUtils.generateTestFile(
      name: "Series.zip",
      contents: Data("archive".utf8),
      destinationFolder: DataManager.getDocumentsFolderURL()
    )
    let partName = "part-\(UUID().uuidString).txt"
    var extractionFolder: URL?
    let operation = ImportOperation(
      files: [archive],
      libraryService: makeLibraryService(),
      unzip: { _, destination in
        extractionFolder = destination
        return FileManager.default.createFile(
          atPath: destination.appendingPathComponent(partName).path,
          contents: Data("part".utf8)
        )
      }
    )

    run(operation)

    XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    XCTAssertEqual(operation.processedFiles.map(\.lastPathComponent), [partName])
    XCTAssertEqual(operation.suggestedFolderName, "Series")
    let processedFile = try XCTUnwrap(operation.processedFiles.first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: processedFile.path))
    // The temporary extraction folder is gone once the import finishes
    let folder = try XCTUnwrap(extractionFolder)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    try? FileManager.default.removeItem(at: processedFile)
  }

  func testAnExtractedArchiveInAFolderTheUserOwnsIsKept() throws {
    let archive = DataTestUtils.generateTestFile(
      name: "Series.zip",
      contents: Data("archive".utf8),
      destinationFolder: externalFolderURL
    )
    let partName = "part-\(UUID().uuidString).txt"
    let operation = ImportOperation(
      files: [archive],
      libraryService: makeLibraryService(),
      unzip: { _, destination in
        FileManager.default.createFile(
          atPath: destination.appendingPathComponent(partName).path,
          contents: Data("part".utf8)
        )
      }
    )

    run(operation)

    XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    XCTAssertEqual(operation.processedFiles.map(\.lastPathComponent), [partName])
    if let processedFile = operation.processedFiles.first {
      try? FileManager.default.removeItem(at: processedFile)
    }
  }

  // MARK: - Helpers

  private func makeLibraryService() -> LibraryService {
    let dataManager = DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null"))
    let libraryService = LibraryService()
    libraryService.setup(dataManager: dataManager, audioMetadataService: AudioMetadataService())
    return libraryService
  }

  /// Runs the import to the end; it works synchronously on the calling thread
  private func run(_ operation: ImportOperation) {
    let finished = XCTestExpectation(description: "Import finished")
    operation.completionBlock = { finished.fulfill() }
    operation.start()
    wait(for: [finished], timeout: 15)
  }
}
