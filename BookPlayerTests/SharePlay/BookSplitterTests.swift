@testable import BookPlayer
@testable import BookPlayerKit
import AVFoundation
import XCTest

final class BookSplitterTests: XCTestCase {
  private var folder: URL!
  private var processedFiles: [URL] = []

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("BookSplitterTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder)
    processedFiles.forEach { try? FileManager.default.removeItem(at: $0) }
    processedFiles = []
  }

  private func fileSize(_ url: URL) throws -> Int64 {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
  }

  func testExportsTimeRangeAsPlayableFile() async throws {
    let source = folder.appendingPathComponent("source.m4a")
    try AudioFixture.makeM4A(seconds: 20, at: source)
    let size = try fileSize(source)
    let file = SourceFile(url: source, bookStart: 100, duration: 20, byteSize: size)
    let piece = PlannedPiece(
      index: 1, sourceIndex: 0, sourceStart: 10, duration: 10, bookStart: 110,
      isWholeFile: false, estimatedBytes: size / 2)

    let (url, shared) = try await BookSplitter().export(piece, from: [file], to: folder)

    let duration = try await AVURLAsset(url: url).load(.duration).seconds
    XCTAssertEqual(duration, 10, accuracy: 0.5)
    XCTAssertEqual(shared.index, 1)
    XCTAssertEqual(shared.bookStart, 110)
    XCTAssertLessThanOrEqual(shared.byteSize, ListenTogetherLimits.maxPieceBytes)
  }

  func testWholeFilePieceIsCopiedNotReencoded() async throws {
    let source = folder.appendingPathComponent("whole.m4a")
    try AudioFixture.makeM4A(seconds: 5, at: source)
    let size = try fileSize(source)
    let piece = PlannedPiece(
      index: 0, sourceIndex: 0, sourceStart: 0, duration: 5, bookStart: 0,
      isWholeFile: true, estimatedBytes: size)
    let (url, shared) = try await BookSplitter().export(
      piece, from: [SourceFile(url: source, bookStart: 0, duration: 5, byteSize: size)], to: folder)
    XCTAssertEqual(shared.byteSize, size)
    XCTAssertNotEqual(url, source)
  }

  // MARK: - isShareable / sourceFiles

  private func makeItem(paths: [String], create: Bool) throws -> PlayableItem {
    var chapters: [PlayableChapter] = []
    for (i, name) in paths.enumerated() {
      let relative = "BookSplitterTests-\(UUID())-\(name)"
      let url = DataManager.getProcessedFolderURL().appendingPathComponent(relative)
      if create {
        processedFiles.append(url)
        try AudioFixture.makeM4A(seconds: 2, at: url)
      }
      chapters.append(PlayableChapter(
        title: "c\(i)", author: "a", start: Double(i) * 2, duration: 2,
        relativePath: relative, remoteURL: nil, index: Int16(i + 1)))
    }
    return PlayableItem(
      title: "t", author: "a", chapters: chapters, currentTime: 0,
      duration: Double(paths.count) * 2, relativePath: chapters[0].relativePath,
      uuid: UUID().uuidString, parentFolder: nil, percentCompleted: 0, lastPlayDate: nil,
      isFinished: false, isBoundBook: true)
  }

  func testIsShareableTrueWhenAllFilesExist() throws {
    let item = try makeItem(paths: ["a.m4a", "b.m4a"], create: true)
    XCTAssertTrue(BookSplitter.isShareable(item))
    let files = try BookSplitter().sourceFiles(for: item)
    XCTAssertEqual(files.count, 2)
    XCTAssertEqual(files[1].bookStart, 2)
    XCTAssertEqual(files[1].duration, 2)
  }

  func testIsShareableFalseWhenFileMissing() throws {
    let item = try makeItem(paths: ["a.m4a", "b.m4a"], create: true)
    try FileManager.default.removeItem(at: item.chapters[1].fileURL)
    XCTAssertFalse(BookSplitter.isShareable(item))
    XCTAssertThrowsError(try BookSplitter().sourceFiles(for: item)) {
      XCTAssertEqual($0 as? BookSplitterError, .noLocalFile)
    }
  }

  // MARK: - sourceFiles layouts

  private typealias ChapterSpec = (file: String, start: Double, duration: Double, offset: Double)

  private func makeItem(specs: [ChapterSpec]) throws -> PlayableItem {
    let prefix = "BookSplitterTests-\(UUID())-"
    var created = Set<String>()
    var chapters: [PlayableChapter] = []
    for (i, spec) in specs.enumerated() {
      let relative = prefix + spec.file
      if created.insert(relative).inserted {
        let url = DataManager.getProcessedFolderURL().appendingPathComponent(relative)
        processedFiles.append(url)
        try AudioFixture.makeM4A(seconds: 1, at: url)
      }
      chapters.append(PlayableChapter(
        title: "c\(i)", author: "a", start: spec.start, duration: spec.duration,
        relativePath: relative, remoteURL: nil, index: Int16(i + 1), chapterOffset: spec.offset))
    }
    return PlayableItem(
      title: "t", author: "a", chapters: chapters, currentTime: 0,
      duration: chapters.last.map(\.end) ?? 0, relativePath: chapters[0].relativePath,
      uuid: UUID().uuidString, parentFolder: nil, percentCompleted: 0, lastPlayDate: nil,
      isFinished: false, isBoundBook: false)
  }

  func testSingleFileWithSharedChaptersYieldsOneSourceFile() throws {
    let item = try makeItem(specs: [
      ("one.m4a", 100, 5, 0), ("one.m4a", 105, 7, 5), ("one.m4a", 112, 18, 12),
    ])
    let files = try BookSplitter().sourceFiles(for: item)
    XCTAssertEqual(files.count, 1)
    XCTAssertEqual(files[0].bookStart, 100)
    XCTAssertEqual(files[0].duration, 30)
  }

  func testMixedLayoutYieldsFilesInBookOrder() throws {
    let item = try makeItem(specs: [
      ("a.m4a", 50, 10, 0), ("a.m4a", 60, 15, 10), ("b.m4a", 75, 25, 0),
    ])
    let files = try BookSplitter().sourceFiles(for: item)
    XCTAssertEqual(files.count, 2)
    XCTAssertEqual(files[0].bookStart, 50)
    XCTAssertEqual(files[0].duration, 25)
    XCTAssertEqual(files[1].bookStart, 75)
    XCTAssertEqual(files[1].duration, 25)
  }

  // MARK: - Error paths

  func testOversizedWholeFilePieceThrowsAndRemovesOutput() async throws {
    let source = folder.appendingPathComponent("big.m4a")
    XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
    let handle = try FileHandle(forWritingTo: source)
    try handle.truncate(atOffset: 100_000_001)
    try handle.close()
    let piece = PlannedPiece(
      index: 3, sourceIndex: 0, sourceStart: 0, duration: 5, bookStart: 0,
      isWholeFile: true, estimatedBytes: 100_000_001)
    let file = SourceFile(url: source, bookStart: 0, duration: 5, byteSize: 100_000_001)
    do {
      _ = try await BookSplitter().export(piece, from: [file], to: folder)
      XCTFail("expected pieceTooLarge")
    } catch {
      XCTAssertEqual(error as? BookSplitterError, .pieceTooLarge(index: 3))
    }
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: folder.appendingPathComponent("piece-003.m4a").path))
  }

  func testOutOfRangeSourceIndexThrowsNoLocalFile() async throws {
    let piece = PlannedPiece(
      index: 0, sourceIndex: 2, sourceStart: 0, duration: 1, bookStart: 0,
      isWholeFile: true, estimatedBytes: 1)
    do {
      _ = try await BookSplitter().export(piece, from: [], to: folder)
      XCTFail("expected noLocalFile")
    } catch {
      XCTAssertEqual(error as? BookSplitterError, .noLocalFile)
    }
  }

  func testNonAudioSourceRangeExportThrowsExportFailed() async throws {
    let source = folder.appendingPathComponent("fake.m4a")
    try Data("not audio".utf8).write(to: source)
    let piece = PlannedPiece(
      index: 4, sourceIndex: 0, sourceStart: 0, duration: 1, bookStart: 0,
      isWholeFile: false, estimatedBytes: 1)
    let file = SourceFile(url: source, bookStart: 0, duration: 5, byteSize: 9)
    do {
      _ = try await BookSplitter().export(piece, from: [file], to: folder)
      XCTFail("expected exportFailed")
    } catch {
      XCTAssertEqual(error as? BookSplitterError, .exportFailed(index: 4))
    }
  }
}
