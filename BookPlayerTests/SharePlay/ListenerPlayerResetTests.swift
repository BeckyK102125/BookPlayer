@testable import BookPlayer
import AVFoundation
import XCTest

/// SR7-08: after iOS resets its media services, the listener's player loads its pieces again at the
/// same place and plays on, instead of reloading dead items until the group stalls.
@MainActor
final class ListenerPlayerResetTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("ListenerPlayerReset-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  override func tearDown() { try? FileManager.default.removeItem(at: folder) }

  private func manifest() -> SharedBookManifest {
    SharedBookManifest(shareID: UUID(), title: "T", author: "A", duration: 20,
                       chapters: [SharedChapter(title: "One", start: 0, duration: 20)],
                       pieces: [SharedPiece(index: 0, bookStart: 0, duration: 10, byteSize: 1),
                                SharedPiece(index: 1, bookStart: 10, duration: 10, byteSize: 1)])
  }

  private func makePiece(_ index: Int) throws -> URL {
    let url = folder.appendingPathComponent("p\(index).m4a")
    try AudioFixture.makeM4A(seconds: 10, at: url)
    return url
  }

  func testAResetReloadsThePieceAtTheSamePlaceAndPlaysOn() async throws {
    let player = ListenerPlayer(manifest: manifest())
    defer { player.stop() }
    var activations = 0
    player.activateSession = { activations += 1; return true }
    var resets = 0
    player.onMediaServicesReset = { resets += 1 }
    player.player.volume = 0
    player.pieceArrived(index: 0, url: try makePiece(0))
    player.applySeek(to: 4)
    try await AudioFixture.waitUntil(player: player.player) { player.isReady(at: 4) }
    player.applyPlay(at: 4, rate: 1)
    try await AudioFixture.waitUntil { player.isPlaying }
    let itemBefore = try XCTUnwrap(player.player.currentItem)

    // Called directly: posting the system notification would also reset the test host's PlayerManager.
    player.mediaServicesWereReset()
    XCTAssertEqual(resets, 1)

    XCTAssertFalse(player.player.currentItem === itemBefore, "a fresh item replaces the dead one")
    try await AudioFixture.waitUntil { player.isPlaying }
    XCTAssertEqual(player.bookTime, 4, accuracy: 1.5, "at the same place")
    XCTAssertGreaterThanOrEqual(activations, 1)
  }

  func testAResetAfterStopDoesNothing() throws {
    let player = ListenerPlayer(manifest: manifest())
    var resets = 0
    player.onMediaServicesReset = { resets += 1 }
    player.stop()
    player.mediaServicesWereReset()
    XCTAssertEqual(resets, 0)
  }
}
