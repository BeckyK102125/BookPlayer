@testable import BookPlayer
import XCTest

final class ListenTogetherModelsTests: XCTestCase {
  private func sampleManifest() -> SharedBookManifest {
    SharedBookManifest(
      shareID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      title: "Moby Dick", author: "Herman Melville", duration: 7200,
      chapters: [SharedChapter(title: "Loomings", start: 0, duration: 3600),
                 SharedChapter(title: "The Carpet-Bag", start: 3600, duration: 3600)],
      pieces: [SharedPiece(index: 0, bookStart: 0, duration: 3600, byteSize: 50_000_000),
               SharedPiece(index: 1, bookStart: 3600, duration: 3600, byteSize: 50_000_000)]
    )
  }

  func testMessagesRoundTrip() throws {
    let messages: [ListenTogetherMessage] = [
      .manifest(sampleManifest()),
      .pieceUploaded(index: 1, attachmentID: UUID(uuidString: "AAAAAAAA-2222-3333-4444-555555555555")!),
      .action(.paused), .action(.resumed), .action(.skipped(seconds: -30)),
      .action(.movedToChapter(title: "Loomings")), .action(.speedChanged(rate: 1.5)),
      .sessionEnding, .requestState, .heartbeat, .needPiece(index: 7), .sharerCouldNotPrepare,
    ]
    for message in messages {
      let data = try JSONEncoder().encode(message)
      XCTAssertEqual(try JSONDecoder().decode(ListenTogetherMessage.self, from: data), message)
    }
  }

  func testChapterLookup() {
    let manifest = sampleManifest()
    XCTAssertEqual(manifest.chapter(at: 10)?.title, "Loomings")
    XCTAssertEqual(manifest.chapter(at: 3600)?.title, "The Carpet-Bag")
    XCTAssertNil(manifest.chapter(at: 9000))
  }

  func testPieceLimitIsUnderSharePlayLimit() {
    XCTAssertLessThan(ListenTogetherLimits.maxPieceBytes, 100_000_000)
  }
}
