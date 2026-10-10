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
    assertTiles(pieces, files: [SourceFile(url: url, bookStart: 0, duration: 36_000, byteSize: 280_000_000)])
  }

  func testChapterLargerThanLimitIsSplitEvenly() {
    // One 200 MB file with a single chapter → 3 equal pieces.
    let pieces = PiecePlanner.plan(
      files: [SourceFile(url: url, bookStart: 0, duration: 3000, byteSize: 200_000_000)],
      chapterStarts: [0])
    XCTAssertEqual(pieces.count, 3)
    XCTAssertEqual(pieces[1].bookStart, 1000, accuracy: 0.001)
    XCTAssertTrue(pieces.allSatisfy { $0.estimatedBytes <= ListenTogetherLimits.maxPieceBytes })
    assertTiles(pieces, files: [SourceFile(url: url, bookStart: 0, duration: 3000, byteSize: 200_000_000)])
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

  // MARK: - Tiling and limit invariants

  func testChapterSpanExactlyMaxBytesStaysOnePiece() {
    // 1 byte per second; each 100 s chapter is exactly the 100-byte limit.
    let files = [SourceFile(url: url, bookStart: 0, duration: 300, byteSize: 300)]
    let pieces = PiecePlanner.plan(files: files, chapterStarts: [0, 100, 200], maxBytes: 100)
    XCTAssertEqual(pieces.map(\.bookStart), [0, 100, 200])
    XCTAssertEqual(pieces.map(\.duration), [100, 100, 100])
    XCTAssertEqual(pieces.map(\.estimatedBytes), [100, 100, 100])
    assertTiles(pieces, files: files)
    assertWithinLimit(pieces, maxBytes: 100)
  }

  func testUnsortedChapterStartsMatchSorted() {
    let file = SourceFile(url: url, bookStart: 0, duration: 36_000, byteSize: 280_000_000)
    let sorted = stride(from: 0.0, to: 36_000, by: 3600).map { $0 }
    let planned = PiecePlanner.plan(files: [file], chapterStarts: sorted)
    XCTAssertFalse(planned.isEmpty)
    XCTAssertEqual(PiecePlanner.plan(files: [file], chapterStarts: Array(sorted.reversed())), planned)
    XCTAssertEqual(PiecePlanner.plan(files: [file], chapterStarts: [7200, 0, 21_600, 3600, 32_400, 10_800, 14_400, 18_000, 25_200, 28_800]), planned)
  }

  func testZeroDurationFilesProduceNoPiecesAndKeepSourceIndexes() {
    let empty = URL(fileURLWithPath: "/tmp/empty.mp3"), c = URL(fileURLWithPath: "/tmp/03.mp3")
    let files = [
      SourceFile(url: url, bookStart: 0, duration: 600, byteSize: 5_000_000),
      SourceFile(url: empty, bookStart: 600, duration: 0, byteSize: 1_000),
      SourceFile(url: c, bookStart: 600, duration: 600, byteSize: 5_000_000),
    ]
    let pieces = PiecePlanner.plan(files: files, chapterStarts: [0, 600])
    XCTAssertEqual(pieces.map(\.index), [0, 1])
    XCTAssertEqual(pieces.map(\.sourceIndex), [0, 2])
    XCTAssertEqual(pieces.map(\.bookStart), [0, 600])
    assertTiles(pieces, files: files)
  }

  func testOversizedNonFirstFileRebasesCutsOntoBookTimeline() {
    let a = SourceFile(url: URL(fileURLWithPath: "/tmp/01.mp3"), bookStart: 0, duration: 600, byteSize: 5_000_000)
    let b = SourceFile(url: URL(fileURLWithPath: "/tmp/02.mp3"), bookStart: 600, duration: 3000, byteSize: 200_000_000)
    let pieces = PiecePlanner.plan(files: [a, b], chapterStarts: [0, 600, 1200])
    // B: chapter at 1200 is file-relative 600; span 600..3000 is 160 MB, so it is split in two.
    XCTAssertEqual(pieces.map(\.sourceIndex), [0, 1, 1, 1])
    XCTAssertEqual(pieces.map(\.sourceStart), [0, 0, 600, 1800])
    XCTAssertEqual(pieces.map(\.bookStart), [0, 600, 1200, 2400])
    XCTAssertEqual(pieces.map(\.duration), [600, 600, 1200, 1200])
    assertTiles(pieces, files: [a, b])
    assertWithinLimit(pieces)
  }

  func testTrailingChapterLargerThanLimitAfterFittingChaptersIsSplit() {
    // Chapter [0, 40] fits and is flushed; trailing span [40, 250] is 210 bytes, split into 3 parts.
    let files = [SourceFile(url: url, bookStart: 0, duration: 250, byteSize: 250)]
    let pieces = PiecePlanner.plan(files: files, chapterStarts: [0, 40], maxBytes: 100)
    XCTAssertEqual(pieces.map(\.bookStart), [0, 40, 110, 180])
    XCTAssertEqual(pieces.map(\.duration), [40, 70, 70, 70])
    assertTiles(pieces, files: files)
    assertWithinLimit(pieces, maxBytes: 100)
  }

  // MARK: - Helpers

  /// Checks that each source file's pieces tile it exactly, from its bookStart to its end, with no gaps or overlaps.
  /// Zero-duration files must produce no pieces.
  private func assertTiles(
    _ pieces: [PlannedPiece],
    files: [SourceFile],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for (sourceIndex, source) in files.enumerated() {
      let own = pieces.filter { $0.sourceIndex == sourceIndex }
      guard source.duration > 0 else {
        XCTAssertTrue(own.isEmpty, "zero-duration file \(sourceIndex) produced pieces", file: file, line: line)
        continue
      }
      guard let first = own.first, let last = own.last else {
        XCTFail("file \(sourceIndex) produced no pieces", file: file, line: line)
        continue
      }
      XCTAssertEqual(first.bookStart, source.bookStart, accuracy: 1e-6, file: file, line: line)
      XCTAssertEqual(last.bookStart + last.duration, source.bookStart + source.duration, accuracy: 1e-6, file: file, line: line)
      for (a, b) in zip(own, own.dropFirst()) {
        XCTAssertEqual(a.bookStart + a.duration, b.bookStart, accuracy: 1e-6, file: file, line: line)
      }
    }
  }

  private func assertWithinLimit(
    _ pieces: [PlannedPiece],
    maxBytes: Int64 = ListenTogetherLimits.maxPieceBytes,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for piece in pieces {
      XCTAssertLessThanOrEqual(piece.estimatedBytes, maxBytes, "piece \(piece.index) too large", file: file, line: line)
    }
  }
}
