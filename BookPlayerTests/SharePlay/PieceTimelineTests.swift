@testable import BookPlayer
import XCTest

final class PieceTimelineTests: XCTestCase {
  private let pieces = [SharedPiece(index: 0, bookStart: 0, duration: 100, byteSize: 10),
                        SharedPiece(index: 1, bookStart: 100, duration: 50, byteSize: 30)]

  func testLocationMapsBookTimeToPieceAndOffset() {
    let timeline = PieceTimeline(pieces: pieces)
    XCTAssertEqual(timeline.location(for: 120)?.piece.index, 1)
    XCTAssertEqual(timeline.location(for: 120)?.offset ?? -1, 20, accuracy: 0.001)
    XCTAssertEqual(timeline.location(for: 0)?.piece.index, 0)
  }

  func testEndOfBookClampsToLastPiece() {
    XCTAssertEqual(PieceTimeline(pieces: pieces).location(for: 150)?.piece.index, 1)
    XCTAssertNil(PieceTimeline(pieces: pieces).location(for: -1))
  }

  func testReadinessAndFractionFollowArrivals() {
    var timeline = PieceTimeline(pieces: pieces)
    XCTAssertFalse(timeline.isReady(at: 10))
    timeline.markArrived(index: 0, url: URL(fileURLWithPath: "/tmp/p0.m4a"))
    XCTAssertTrue(timeline.isReady(at: 10))
    XCTAssertFalse(timeline.isReady(at: 110))
    XCTAssertEqual(timeline.arrivedFraction, 0.25, accuracy: 0.001)  // by bytes: 10 of 40
  }

  /// Piece 0 ends one ULP before piece 1 starts, as float seams from the planner can.
  private let seamed = [SharedPiece(index: 0, bookStart: 0, duration: (100.0).nextDown, byteSize: 10),
                        SharedPiece(index: 1, bookStart: 100, duration: 50, byteSize: 30)]

  func testTimeInAOneULPGapResolvesToTheNextPiece() {
    let timeline = PieceTimeline(pieces: seamed)
    let gap = seamed[0].bookEnd
    XCTAssertLessThan(gap, 100)
    XCTAssertEqual(timeline.location(for: gap)?.piece.index, 1)
    XCTAssertEqual(timeline.location(for: gap)?.offset ?? -1, 0, accuracy: 1e-9)
    XCTAssertEqual(timeline.location(for: gap.nextDown.nextDown)?.piece.index, 1, "within the tolerance")
    XCTAssertEqual(timeline.location(for: 99)?.piece.index, 0)
  }

  func testOnlyNegativeNaNOrEmptyHaveNoLocation() {
    XCTAssertNil(PieceTimeline(pieces: pieces).location(for: .nan))
    XCTAssertNil(PieceTimeline(pieces: pieces).location(for: -0.5))
    XCTAssertNil(PieceTimeline(pieces: []).location(for: 0))
    let past = PieceTimeline(pieces: pieces).location(for: 1000)
    XCTAssertEqual(past?.piece.index, 1)
    XCTAssertEqual(past?.offset ?? -1, 50, accuracy: 0.001)
  }

  func testPieceAfterFollowsBookOrder() {
    let timeline = PieceTimeline(pieces: seamed.reversed())
    XCTAssertEqual(timeline.piece(after: 0)?.index, 1)
    XCTAssertNil(timeline.piece(after: 1))
  }
}
