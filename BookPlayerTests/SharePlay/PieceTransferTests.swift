@testable import BookPlayer
import CoreTransferable
import UniformTypeIdentifiers
import XCTest

/// Transfer fix A: a journal piece travels as Data (the journal's add only packages Data-producing
/// representations), and its extension travels as attachment metadata.
final class PieceTransferTests: XCTestCase {
  private var made: [URL] = []

  override func tearDown() {
    made.forEach { try? FileManager.default.removeItem(at: $0) }
    made = []
    super.tearDown()
  }

  private func makeFile(_ data: Data, ext: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-\(UUID()).\(ext)")
    try data.write(to: url)
    made.append(url)
    return url
  }

  func testThePieceIsOfferedAsDataOnly() throws {
    guard #available(iOS 18.2, *) else { throw XCTSkip("Needs the iOS 18.2 Transferable test API") }
    XCTAssertEqual(PieceTransfer.exportedContentTypes(), [.data])
    XCTAssertEqual(PieceTransfer.importedContentTypes(), [.data])
  }

  func testThePieceRoundTripsThroughDataIntoTheListenTogetherFolder() async throws {
    guard #available(iOS 18.2, *) else { throw XCTSkip("Needs the iOS 18.2 Transferable test API") }
    let bytes = Data((0..<300_000).map { UInt8($0 % 253) })
    let source = try makeFile(bytes, ext: "m4b")

    let exported = try await PieceTransfer(url: source).exported(as: .data)
    XCTAssertEqual(exported, bytes)

    let imported = try await PieceTransfer(importing: exported, contentType: .data)
    made.append(imported.url)
    XCTAssertEqual(try Data(contentsOf: imported.url), bytes)
    XCTAssertTrue(
      imported.url.standardizedFileURL.path.hasPrefix(ShareStorage.defaultRoot.standardizedFileURL.path),
      "received files stay inside the Listen Together folder, which launch cleanup deletes")
  }

  func testMetadataCarriesTheExtension() throws {
    for ext in ["mp3", "m4b", "m4a"] {
      let data = try JSONEncoder().encode(PieceMetadata(pathExtension: ext))
      XCTAssertEqual(try JSONDecoder().decode(PieceMetadata.self, from: data).pathExtension, ext)
    }
  }

  func testTheReceivedFileIsNamedWithTheSendersExtension() {
    let imported = URL(fileURLWithPath: "/tmp/ListenTogether/incoming/ABC")
    XCTAssertEqual(PieceTransfer.receivedFileName(for: imported, pathExtension: "mp3"), "ABC.mp3")
    XCTAssertEqual(PieceTransfer.receivedFileName(for: imported, pathExtension: "m4b"), "ABC.m4b")
    XCTAssertEqual(PieceTransfer.receivedFileName(for: imported, pathExtension: ""), "ABC.m4a")
    XCTAssertEqual(PieceTransfer.receivedFileName(for: imported, pathExtension: nil), "ABC.m4a")
    XCTAssertEqual(PieceTransfer.receivedFileName(for: imported, pathExtension: "../x"), "ABC.m4a")
  }

  /// Fix A: a whole-file piece is held in memory by the listener's import, so pieces stay small.
  func testPiecesAreCappedAt25MB() {
    XCTAssertLessThanOrEqual(ListenTogetherLimits.maxPieceBytes, 25_000_000)
    XCTAssertGreaterThanOrEqual(ListenTogetherLimits.maxPieceBytes, 20_000_000)
  }
}
