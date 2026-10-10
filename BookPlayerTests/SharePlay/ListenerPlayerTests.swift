@testable import BookPlayer
import Combine
import XCTest

@MainActor
final class ListenerPlayerTests: XCTestCase {
  private var folder: URL!
  private var bag = Set<AnyCancellable>()

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("ListenerPlayerTests-\(UUID())")
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

  func testSeekToMissingPieceBeginsSuspension() throws {
    let player = ListenerPlayer(manifest: manifest())
    var needed: [Int] = []
    player.onNeedsPiece = { needed.append($0) }
    player.pieceArrived(index: 0, url: try makePiece(0))

    player.applySeek(to: 15)

    XCTAssertEqual(needed, [1])
    XCTAssertFalse(player.isReady(at: 15))
    XCTAssertTrue(player.isReady(at: 5))
    player.stop()
  }

  func testOnNeedsPieceIsCalledOncePerWait() throws {
    let player = ListenerPlayer(manifest: manifest())
    var needed: [Int] = []
    player.onNeedsPiece = { needed.append($0) }
    player.pieceArrived(index: 0, url: try makePiece(0))

    player.applySeek(to: 15)
    player.applySeek(to: 16)
    player.applyPlay(at: 17, rate: 1)
    player.applyPause(at: 17)
    XCTAssertEqual(needed, [1])
    XCTAssertFalse(player.isPlaying)

    // After the piece arrives the wait is over; the same piece missing later is a new wait.
    player.pieceArrived(index: 1, url: try makePiece(1))
    XCTAssertTrue(player.isReady(at: 15))
    player.applySeek(to: 2)
    player.applySeek(to: 15)
    XCTAssertEqual(needed, [1])
    player.stop()
  }

  func testPlayInMissingPieceDoesNotReportLocalPlay() throws {
    let player = ListenerPlayer(manifest: manifest())
    var events: [LocalPlaybackEvent] = []
    player.localEvents.sink { events.append($0) }.store(in: &bag)

    player.userTogglePlay()

    XCTAssertFalse(player.isPlaying)
    XCTAssertTrue(events.isEmpty)
  }

  func testRemoteCommandsDoNotEmitLocalEvents() throws {
    let player = ListenerPlayer(manifest: manifest())
    var events: [LocalPlaybackEvent] = []
    player.localEvents.sink { events.append($0) }.store(in: &bag)
    player.pieceArrived(index: 0, url: try makePiece(0))

    player.applyPlay(at: 2, rate: 1)
    player.applyPause(at: 3)
    XCTAssertTrue(events.isEmpty)

    player.userSkip(by: 5)
    XCTAssertEqual(events.count, 1)
    if case let .seeked(to, _) = events[0] { XCTAssertEqual(to, 8, accuracy: 0.6) } else { XCTFail() }
    player.stop()
  }
}
