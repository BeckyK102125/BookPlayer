@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

@MainActor
final class ListenTogetherFirstShareNoteTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    suiteName = "FirstShareNoteTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
  }

  private func makeService() -> SharePlaySessionService {
    SharePlaySessionService(
      playerManager: PlayerManagerProtocolMock(),
      storage: ShareStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("NoteTests-\(UUID())")),
      announcer: ListenTogetherAnnouncer(post: { _ in }),
      defaults: defaults)
  }

  private func makeItem() -> PlayableItem {
    PlayableItem.stub(currentTime: 0, duration: 10, fileURL: URL(fileURLWithPath: "/note-test.m4a"))
  }

  /// Share on the note: shares and saves the shown-once flag.
  func testShareStartsSharingAndSavesTheFlag() async {
    let service = makeService()
    await service.chooseListenTogether(makeItem())
    XCTAssertTrue(service.showsFirstShareNote)
    XCTAssertEqual(service.state, .idle, "nothing shared (and nothing announced) before the note is read")

    await service.acknowledgeFirstShareNote()
    XCTAssertFalse(service.showsFirstShareNote)
    XCTAssertTrue(defaults.bool(forKey: SharePlaySessionService.firstShareNoteSeenKey))
    // Sharing started (no FaceTime call in the simulator, so it stops at needs-FaceTime).
    XCTAssertEqual(service.state, .needsFaceTime)
    service.acknowledgeNeedsFaceTime()

    let laterService = makeService()
    await laterService.chooseListenTogether(makeItem())
    XCTAssertFalse(laterService.showsFirstShareNote, "remembered on this device")
    XCTAssertEqual(laterService.state, .needsFaceTime, "shares straight away")
  }

  /// Cancel, two-finger Z and closing the player all call cancelFirstShareNote() (R34).
  func testCancelSharesNothingSavesNothingAndShowsAgain() async {
    let service = makeService()
    await service.chooseListenTogether(makeItem())
    service.cancelFirstShareNote()
    XCTAssertFalse(service.showsFirstShareNote)
    XCTAssertEqual(service.state, .idle)
    XCTAssertFalse(defaults.bool(forKey: SharePlaySessionService.firstShareNoteSeenKey))
    // A late Share tap after Cancel does nothing.
    await service.acknowledgeFirstShareNote()
    XCTAssertEqual(service.state, .idle)
    XCTAssertFalse(defaults.bool(forKey: SharePlaySessionService.firstShareNoteSeenKey))
    await service.chooseListenTogether(makeItem())
    XCTAssertTrue(service.showsFirstShareNote)
  }
}
