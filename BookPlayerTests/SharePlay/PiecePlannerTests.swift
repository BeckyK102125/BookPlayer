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

  // MARK: - Small pieces (addendum 3, decision 1)

  func testManyTwoMinuteChaptersAreGroupedUpToTheTarget() {
    // 1 h, 30 MB, a chapter every 2 minutes: six chapters (12 min) per piece, cut at chapter starts.
    let files = [SourceFile(url: url, bookStart: 0, duration: 3600, byteSize: 30_000_000)]
    let pieces = PiecePlanner.plan(files: files, chapterStarts: stride(from: 0.0, to: 3600, by: 120).map { $0 })
    XCTAssertEqual(pieces.map(\.bookStart), [0, 720, 1440, 2160, 2880])
    XCTAssertTrue(pieces.allSatisfy { !$0.isWholeFile && $0.duration == 720 })
    assertTiles(pieces, files: files)
    assertWithinLimit(pieces)
  }

  func testOneTenHourChapterIsSplitIntoPartsOfAboutTheTarget() {
    let files = [SourceFile(url: url, bookStart: 0, duration: 36_000, byteSize: 280_000_000)]
    let pieces = PiecePlanner.plan(files: files, chapterStarts: [0])
    XCTAssertEqual(pieces.count, 50)
    XCTAssertTrue(pieces.allSatisfy { abs($0.duration - PiecePlanner.targetDuration) < 0.001 })
    assertTiles(pieces, files: files)
    assertWithinLimit(pieces)
  }

  func testBookWithoutChaptersIsSplitIntoPartsOfAboutTheTarget() {
    // 50 minutes: five parts of 10 minutes (never longer than the 15 minute maximum).
    let files = [SourceFile(url: url, bookStart: 0, duration: 3000, byteSize: 20_000_000)]
    let pieces = PiecePlanner.plan(files: files, chapterStarts: [])
    XCTAssertEqual(pieces.count, 5)
    XCTAssertEqual(pieces[1].bookStart, 600, accuracy: 0.001)
    XCTAssertTrue(pieces.allSatisfy { $0.duration <= PiecePlanner.maxDuration })
    assertTiles(pieces, files: files)
  }

  func testMultiFileBookKeepsFileBoundariesAsCuts() {
    let a = SourceFile(url: URL(fileURLWithPath: "/tmp/01.mp3"), bookStart: 0, duration: 600, byteSize: 5_000_000)
    let b = SourceFile(url: URL(fileURLWithPath: "/tmp/02.mp3"), bookStart: 600, duration: 2000, byteSize: 16_000_000)
    let c = SourceFile(url: URL(fileURLWithPath: "/tmp/03.mp3"), bookStart: 2600, duration: 300, byteSize: 2_000_000)
    let pieces = PiecePlanner.plan(files: [a, b, c], chapterStarts: [0, 600, 2600])
    XCTAssertEqual(pieces.map(\.sourceIndex), [0, 1, 1, 1, 2])
    XCTAssertEqual(pieces.map(\.isWholeFile), [true, false, false, false, true])
    XCTAssertEqual(pieces.map(\.index), [0, 1, 2, 3, 4])
    assertTiles(pieces, files: [a, b, c])
  }

  func testMixedChaptersGroupShortOnesAndSplitLongOnes() {
    // Four 2-minute chapters, a 30-minute chapter, then a 28:40 chapter.
    let files = [SourceFile(url: url, bookStart: 0, duration: 4000, byteSize: 40_000_000)]
    let pieces = PiecePlanner.plan(files: files, chapterStarts: [0, 120, 240, 360, 480, 2280])
    let starts = pieces.map(\.bookStart)
    XCTAssertEqual(starts.count, 7)
    for (got, want) in zip(starts, [0, 480, 1080, 1680, 2280, 2853.333, 3426.667]) {
      XCTAssertEqual(got, want, accuracy: 0.01)
    }
    assertTiles(pieces, files: files)
  }

  func testHighBitrateKeepsPiecesUnderTheByteCap() {
    // 200 KB/s: 12 minutes would be 144 MB, so pieces are shorter.
    let files = [SourceFile(url: url, bookStart: 0, duration: 1800, byteSize: 360_000_000)]
    let pieces = PiecePlanner.plan(files: files, chapterStarts: [0])
    XCTAssertGreaterThanOrEqual(pieces.count, 4)
    assertTiles(pieces, files: files)
    assertWithinLimit(pieces)
  }

  func testHourLongChaptersAreSplitAndEveryChapterStartIsACut() {
    let files = [SourceFile(url: url, bookStart: 0, duration: 36_000, byteSize: 280_000_000)]
    let pieces = PiecePlanner.plan(files: files, chapterStarts: stride(from: 0.0, to: 36_000, by: 3600).map { $0 })
    XCTAssertEqual(pieces.count, 50)
    let starts = Set(pieces.map { $0.bookStart.rounded() })
    for hour in stride(from: 0.0, to: 36_000, by: 3600) { XCTAssertTrue(starts.contains(hour), "cut at \(hour)") }
    assertTiles(pieces, files: files)
    assertWithinLimit(pieces)
  }

  func testChapterLargerThanTheMaximumIsSplitEvenly() {
    // One 50-minute chapter: five equal parts of 10 minutes.
    let pieces = PiecePlanner.plan(
      files: [SourceFile(url: url, bookStart: 0, duration: 3000, byteSize: 200_000_000)],
      chapterStarts: [0])
    XCTAssertEqual(pieces.count, 5)
    XCTAssertEqual(pieces[1].bookStart, 600, accuracy: 0.001)
    XCTAssertTrue(pieces.allSatisfy { $0.estimatedBytes <= ListenTogetherLimits.maxPieceBytes })
    assertTiles(pieces, files: [SourceFile(url: url, bookStart: 0, duration: 3000, byteSize: 200_000_000)])
  }

  func testMultiFileBookKeepsBookTimeAndIndexes() {
    let a = URL(fileURLWithPath: "/tmp/01.mp3"), b = URL(fileURLWithPath: "/tmp/02.mp3")
    let pieces = PiecePlanner.plan(
      files: [SourceFile(url: a, bookStart: 0, duration: 600, byteSize: 10_000_000),
              SourceFile(url: b, bookStart: 600, duration: 800, byteSize: 13_000_000)],
      chapterStarts: [0, 600])
    XCTAssertEqual(pieces.map(\.index), [0, 1])
    XCTAssertEqual(pieces.map(\.sourceIndex), [0, 1])
    XCTAssertEqual(pieces[1].bookStart, 600)
    XCTAssertEqual(pieces[1].sourceStart, 0)
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
    // B: chapter at 1200 is file-relative 600; the 40-minute span 600..3000 is split into four parts.
    XCTAssertEqual(pieces.map(\.sourceIndex), [0, 1, 1, 1, 1, 1])
    XCTAssertEqual(pieces.map(\.sourceStart), [0, 0, 600, 1200, 1800, 2400])
    XCTAssertEqual(pieces.map(\.bookStart), [0, 600, 1200, 1800, 2400, 3000])
    XCTAssertEqual(pieces.map(\.duration), [600, 600, 600, 600, 600, 600])
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
