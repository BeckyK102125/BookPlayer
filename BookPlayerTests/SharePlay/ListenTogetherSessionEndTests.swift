@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import UIKit
import XCTest

/// Transfer fix, item 4: the sharer's End really ends SharePlay (`GroupSession.end()`, through the
/// transport's `end()`), listeners only leave, and the app closing ends or leaves best-effort.
@MainActor
final class ListenTogetherSessionEndTests: XCTestCase {
  private var root: URL!
  private var posted: [String] = []
  private var processedFiles: [URL] = []
  private var center: NotificationCenter!
  private var services: [SharePlaySessionService] = []

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionEndTests-\(UUID())")
    posted = []
    center = NotificationCenter()
  }

  override func tearDown() async throws {
    services.forEach { $0.end() }
    services = []
    try? FileManager.default.removeItem(at: root)
    processedFiles.forEach { try? FileManager.default.removeItem(at: $0) }
    processedFiles = []
  }

  private func makeService() -> SharePlaySessionService {
    let playerManager = PlayerManagerProtocolMock()
    playerManager.isPlayingPublisherReturnValue = Just(false).eraseToAnyPublisher()
    playerManager.currentSpeedPublisherReturnValue = Just(Float(1)).eraseToAnyPublisher()
    playerManager.underlyingIsPlaying = false
    playerManager.underlyingCurrentSpeed = 1
    let service = SharePlaySessionService(
      playerManager: playerManager,
      storage: ShareStorage(root: root),
      announcer: ListenTogetherAnnouncer(post: { [weak self] in self?.posted.append($0) }),
      notificationCenter: center)
    service.retrySleep = { _ in await Task.yield() }
    services.append(service)
    return service
  }

  private func makeSharedItem() throws -> PlayableItem {
    let url = DataManager.getProcessedFolderURL()
      .appendingPathComponent("SessionEndTests-\(UUID().uuidString).m4a")
    try AudioFixture.makeM4A(seconds: 10, at: url)
    processedFiles.append(url)
    return PlayableItem.stub(currentTime: 0, duration: 10, fileURL: url)
  }

  private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
  }

  // MARK: End

  func testSharerEndSendsTheEndMessageThenEndsTheGroupSessionForEveryone() async throws {
    let service = makeService(), transport = FakeTransport()
    XCTAssertTrue(service.startSharingSession(with: transport, item: try makeSharedItem(), shareID: UUID()))

    service.end()

    await waitUntil { transport.ended }
    XCTAssertTrue(transport.ended)
    XCTAssertFalse(transport.left, "the sharer ends SharePlay, it doesn't just leave it")
    XCTAssertEqual(transport.sent, [.sessionEnding])
    XCTAssertEqual(service.state, .ended(reason: .normal))
  }

  func testSharerEndStillEndsWhenTheEndMessageNeverGoesOut() async throws {
    let service = makeService(), transport = FakeTransport()
    service.startSharingSession(with: transport, item: try makeSharedItem(), shareID: UUID())
    transport.holdSends = true

    service.end()

    await waitUntil(timeout: 6) { transport.ended }
    XCTAssertTrue(transport.ended, "ended after the time limit")
    transport.releaseSends()
  }

  func testListenerEndOnlyLeaves() {
    let service = makeService(), transport = FakeTransport()
    service.startListening(with: transport, shareID: UUID())

    service.end()

    XCTAssertTrue(transport.left)
    XCTAssertFalse(transport.ended, "a listener never ends the session for the others")
  }

  // MARK: The app closing

  func testTerminatingWhileSharingEndsTheGroupSessionAtOnce() throws {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    service.startSharingSession(with: transport, item: try makeSharedItem(), shareID: id)
    posted = []

    center.post(name: UIApplication.willTerminateNotification, object: nil)

    XCTAssertTrue(transport.ended)
    XCTAssertFalse(transport.left)
    XCTAssertFalse(service.isInSession)
    XCTAssertEqual(posted, [], "nothing is announced while the app closes")
    XCTAssertEqual(service.decision(forIncoming: id), .endedShare)
  }

  func testTerminatingWhileListeningLeaves() {
    let service = makeService(), transport = FakeTransport()
    service.startListening(with: transport, shareID: UUID())

    center.post(name: UIApplication.willTerminateNotification, object: nil)

    XCTAssertTrue(transport.left)
    XCTAssertFalse(transport.ended)
    XCTAssertFalse(service.isInSession)
    XCTAssertNil(service.endNotice)
  }

  func testTerminatingOutsideASessionDoesNothing() {
    let service = makeService()
    center.post(name: UIApplication.willTerminateNotification, object: nil)
    XCTAssertEqual(service.state, .idle)
  }

  func testOnlyTheLastAppWindowSceneGoingAwayEndsTheSession() {
    XCTAssertTrue(SharePlaySessionService.endsOnSceneDisconnect(
      isAppWindowScene: true, otherConnectedAppWindowScenes: 0))
    XCTAssertFalse(SharePlaySessionService.endsOnSceneDisconnect(
      isAppWindowScene: true, otherConnectedAppWindowScenes: 1), "another window still shows the app (iPad)")
    XCTAssertFalse(SharePlaySessionService.endsOnSceneDisconnect(
      isAppWindowScene: false, otherConnectedAppWindowScenes: 0), "CarPlay going away is not the app closing")
  }
}
