@testable import BookPlayer
import XCTest

final class PiecePlannerTests: XCTestCase {
  private let url = URL(fileURLWithPath: "/tmp/book.m4b")

  func testSmallFileIsOneWholePiece() {
    let pieces = PiecePlanner.plan(
      files: [SourceFile(url: url, bookStart: 0, duration: 600, byteSize: 5_000_000)],
      chapterStarts: [0, 300])
    XCTAssertEqual(pieces.count, 1)
    XCTAssertTrue(pieces[0].isWholeFile)
    XCTAssertEqual(pieces[0].duration, 600)
  }

  func testLargeFileCutsOnChapterBoundaries() {
    // 10 h, 280 MB → ~7.8 KB/s; chapters every hour (~28 MB each) → pieces of 3 chapters (~84 MB).
    let pieces = PiecePlanner.plan(
      files: [SourceFile(url: url, bookStart: 0, duration: 36_000, byteSize: 280_000_000)],
      chapterStarts: stride(from: 0.0, to: 36_000, by: 3600).map { $0 })
    XCTAssertEqual(pieces.map(\.bookStart), [0, 10_800, 21_600, 32_400])
    XCTAssertTrue(pieces.allSatisfy { $0.estimatedBytes <= ListenTogetherLimits.maxPieceBytes })
    XCTAssertEqual(pieces.last.map { $0.bookStart + $0.duration }, 36_000)
  }

  func testChapterLargerThanLimitIsSplitEvenly() {
    // One 200 MB file with a single chapter → 3 equal pieces.
    let pieces = PiecePlanner.plan(
      files: [SourceFile(url: url, bookStart: 0, duration: 3000, byteSize: 200_000_000)],
      chapterStarts: [0])
    XCTAssertEqual(pieces.count, 3)
    XCTAssertEqual(pieces[1].bookStart, 1000, accuracy: 0.001)
    XCTAssertTrue(pieces.allSatisfy { $0.estimatedBytes <= ListenTogetherLimits.maxPieceBytes })
  }

  func testMultiFileBookKeepsBookTimeAndIndexes() {
    let a = URL(fileURLWithPath: "/tmp/01.mp3"), b = URL(fileURLWithPath: "/tmp/02.mp3")
    let pieces = PiecePlanner.plan(
      files: [SourceFile(url: a, bookStart: 0, duration: 1200, byteSize: 20_000_000),
              SourceFile(url: b, bookStart: 1200, duration: 1500, byteSize: 25_000_000)],
      chapterStarts: [0, 1200])
    XCTAssertEqual(pieces.map(\.index), [0, 1])
    XCTAssertEqual(pieces.map(\.sourceIndex), [0, 1])
    XCTAssertEqual(pieces[1].bookStart, 1200)
    XCTAssertEqual(pieces[1].sourceStart, 0)
  }

  func testUploadOrderStartsAtCurrentPiece() {
    let pieces = PiecePlanner.plan(
      files: [SourceFile(url: url, bookStart: 0, duration: 36_000, byteSize: 280_000_000)],
      chapterStarts: stride(from: 0.0, to: 36_000, by: 3600).map { $0 })
    XCTAssertEqual(pieces.uploadOrder(startingAt: 15_000).map(\.index), [1, 2, 3, 0])
  }
}
