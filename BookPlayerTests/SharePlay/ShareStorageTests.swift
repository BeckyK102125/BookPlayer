@testable import BookPlayer
import XCTest

final class ShareStorageTests: XCTestCase {
  private var root: URL!

  override func setUp() {
    super.setUp()
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ShareStorageTests-\(UUID())")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
    super.tearDown()
  }

  func testFolderIsCreatedPerShareAndRole() throws {
    let storage = ShareStorage(root: root)
    let id = UUID()
    let listener = try storage.folder(for: id, role: .listener)
    let sharer = try storage.folder(for: id, role: .sharer)
    XCTAssertNotEqual(listener, sharer)
    XCTAssertTrue(FileManager.default.fileExists(atPath: listener.path))
  }

  func testRemoveDeletesOnlyThatShare() throws {
    let storage = ShareStorage(root: root)
    let a = UUID(), b = UUID()
    let folderA = try storage.folder(for: a, role: .listener)
    let folderB = try storage.folder(for: b, role: .listener)
    try Data([1]).write(to: folderA.appendingPathComponent("piece-0.m4a"))
    storage.remove(shareID: a)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folderA.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: folderB.path))
  }

  func testCleanAllRemovesEverything() throws {
    let storage = ShareStorage(root: root)
    try Data([1]).write(to: try storage.folder(for: UUID(), role: .sharer).appendingPathComponent("x"))
    storage.cleanAll()
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }
}
