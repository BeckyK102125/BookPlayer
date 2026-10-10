@testable import BookPlayer
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

  func testNoteIsShownOnTheFirstShareOnly() {
    let service = makeService()
    XCTAssertFalse(service.showsFirstShareNote)
    service.sharingStarted()
    XCTAssertTrue(service.showsFirstShareNote)
    service.acknowledgeFirstShareNote()
    XCTAssertFalse(service.showsFirstShareNote)
    XCTAssertTrue(defaults.bool(forKey: SharePlaySessionService.firstShareNoteSeenKey))

    service.sharingStarted()
    XCTAssertFalse(service.showsFirstShareNote, "second share")
    let laterService = makeService()
    laterService.sharingStarted()
    XCTAssertFalse(laterService.showsFirstShareNote, "remembered on this device")
  }

  func testNoteNotAcknowledgedIsShownAgain() {
    let service = makeService()
    service.sharingStarted()
    let next = makeService()
    next.sharingStarted()
    XCTAssertTrue(next.showsFirstShareNote)
  }
}
