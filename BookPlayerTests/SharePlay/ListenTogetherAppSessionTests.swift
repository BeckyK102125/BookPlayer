@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

/// SR7-02: a second window never removes a running session's files or makes a second service.
@MainActor
final class ListenTogetherAppSessionTests: XCTestCase {
  private var root: URL!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("AppSessionTests-\(UUID())")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func makeService() -> SharePlaySessionService {
    SharePlaySessionService(playerManager: PlayerManagerProtocolMock(), storage: ShareStorage(root: root))
  }

  func testEveryWindowGetsTheSameService() {
    let session = ListenTogetherAppSession(cleanStorage: {}, start: { _ in })
    var made = 0
    let first = session.service { made += 1; return makeService() }
    let second = session.service { made += 1; return makeService() }
    XCTAssertTrue(first === second)
    XCTAssertEqual(made, 1)
  }

  func testASecondWindowKeepsTheRunningSessionsFiles() throws {
    let storage = ShareStorage(root: root)
    var starts = 0
    let session = ListenTogetherAppSession(cleanStorage: { storage.cleanAll() }, start: { _ in starts += 1 })
    _ = session.service { makeService() }

    // First window: launch cleanup, then a session writes a piece.
    session.startOnce()
    let piece = root.appendingPathComponent("listener/\(UUID().uuidString)/piece-000.m4a")
    try FileManager.default.createDirectory(at: piece.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: piece)

    // Second window opens.
    _ = session.service { makeService() }
    session.startOnce()

    XCTAssertTrue(FileManager.default.fileExists(atPath: piece.path), "the second window removed the session's files")
    XCTAssertEqual(starts, 1, "sessions are watched once, not once per window")
  }

  func testLeftoverFilesAreStillRemovedAtLaunch() throws {
    let storage = ShareStorage(root: root)
    let leftover = root.appendingPathComponent("listener/old/piece-000.m4a")
    try FileManager.default.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: leftover)
    let session = ListenTogetherAppSession(cleanStorage: { storage.cleanAll() }, start: { _ in })
    _ = session.service { makeService() }
    session.startOnce()
    XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
  }

  func testOneWindowShowsTheScreensAndTheNextTakesOverWhenItCloses() {
    let session = ListenTogetherAppSession(cleanStorage: {}, start: { _ in })
    let first = NSObject(), second = NSObject()
    XCTAssertTrue(session.claimUI(for: first))
    XCTAssertFalse(session.claimUI(for: second))
    XCTAssertTrue(session.claimUI(for: first), "the owner keeps it")
    session.releaseUI(for: second)               // a window that isn't the owner closing changes nothing
    XCTAssertFalse(session.claimUI(for: second))
    session.releaseUI(for: first)
    XCTAssertTrue(session.claimUI(for: second))
  }

  func testAWindowThatWentAwayWithoutClosingFreesTheScreens() {
    let session = ListenTogetherAppSession(cleanStorage: {}, start: { _ in })
    var first: NSObject? = NSObject()
    XCTAssertTrue(session.claimUI(for: first!))
    first = nil
    XCTAssertTrue(session.claimUI(for: NSObject()))
  }
}
