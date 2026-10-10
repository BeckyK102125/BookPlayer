@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import XCTest

@MainActor
final class SharePlayMenuTests: XCTestCase {
  private var files: [URL] = []
  private var services: [SharePlaySessionService] = []
  private var posted: [String] = []
  private var root: URL!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("MenuTests-\(UUID())")
    posted = []
  }

  override func tearDown() async throws {
    services.forEach { $0.end() }
    services = []
    files.forEach { try? FileManager.default.removeItem(at: $0) }
    files = []
    try? FileManager.default.removeItem(at: root)
  }

  private func makeService() -> SharePlaySessionService {
    let playerManager = PlayerManagerProtocolMock()
    playerManager.isPlayingPublisherReturnValue = Just(false).eraseToAnyPublisher()
    playerManager.currentSpeedPublisherReturnValue = Just(Float(1)).eraseToAnyPublisher()
    let service = SharePlaySessionService(
      playerManager: playerManager,
      storage: ShareStorage(root: root),
      announcer: ListenTogetherAnnouncer(post: { [weak self] in self?.posted.append($0) }))
    services.append(service)
    return service
  }

  /// An item whose only chapter file exists in the processed folder (a downloaded book).
  private func makeLocalItem() throws -> PlayableItem {
    let url = DataManager.getProcessedFolderURL()
      .appendingPathComponent("MenuTests-\(UUID().uuidString).m4a")
    try Data([1]).write(to: url)
    files.append(url)
    return PlayableItem.stub(currentTime: 0, duration: 10, fileURL: url)
  }

  private func makeViewModel(item: PlayableItem, service: SharePlaySessionService?) -> PlayerViewModel {
    let playerManager = PlayerManager(
      libraryService: LibraryServiceProtocolMock(),
      playbackService: PlaybackServiceProtocolMock(),
      syncService: SyncServiceProtocolMock(),
      speedService: SpeedServiceProtocolMock(),
      shakeMotionService: ShakeMotionServiceProtocolMock(),
      widgetReloadService: WidgetReloadService()
    )
    playerManager.currentItem = item
    return PlayerViewModel(
      libraryService: LibraryService(),
      playbackService: PlaybackService(),
      playerManager: playerManager,
      syncService: SyncService(),
      sharePlayService: service
    )
  }

  private func listenTogetherCount(in viewModel: PlayerViewModel) -> Int {
    viewModel.setMoreAlert()
    return viewModel.currentAlert?.actionItems
      .filter { $0.title == "listen_together_title".localized }.count ?? 0
  }

  func testStreamedBookIsNotShareable() {
    // A chapter whose local file doesn't exist (as for streamed AudiobookShelf/Jellyfin/cloud books).
    let item = PlayableItem.stub(currentTime: 0, duration: 10)  // no file created
    let service = makeService()
    XCTAssertFalse(service.canShare(item))
  }

  func testMoreMenuOffersListenTogetherOnlyWhenShareable() throws {
    let service = makeService()
    let streamed = makeViewModel(item: PlayableItem.stub(currentTime: 0, duration: 10), service: service)
    XCTAssertEqual(listenTogetherCount(in: streamed), 0)

    let local = makeViewModel(item: try makeLocalItem(), service: service)
    XCTAssertEqual(listenTogetherCount(in: local), 1)

    // Without the service (existing call sites), nothing is offered.
    let withoutService = makeViewModel(item: try makeLocalItem(), service: nil)
    XCTAssertEqual(listenTogetherCount(in: withoutService), 0)
  }

  func testMoreMenuHidesListenTogetherDuringSession() async throws {
    let item = try makeLocalItem()

    let preparing = makeService()
    XCTAssertNotNil(preparing.beginPreparing(item))
    XCTAssertEqual(listenTogetherCount(in: makeViewModel(item: item, service: preparing)), 0)

    let listening = makeService()
    await listening.beginListening(with: FakeTransport(), shareID: UUID())
    XCTAssertEqual(listenTogetherCount(in: makeViewModel(item: item, service: listening)), 0)

    // Once the session has ended the item is offered again.
    listening.end()
    XCTAssertEqual(listenTogetherCount(in: makeViewModel(item: item, service: listening)), 1)
  }

  func testAcknowledgeNeedsFaceTimeReturnsToIdle() {
    let service = makeService()
    service.setState(.needsFaceTime)
    service.acknowledgeNeedsFaceTime()
    XCTAssertEqual(service.state, .idle)

    // Only the needs-FaceTime state is cleared.
    service.setState(.sharing(participants: 2))
    service.acknowledgeNeedsFaceTime()
    XCTAssertEqual(service.state, .sharing(participants: 2))
  }

  func testUnavailableEndIsAnnounced() {
    let service = makeService()
    service.endUnavailable()
    XCTAssertEqual(service.state, .ended(reason: .unavailable))
    XCTAssertEqual(posted, ["listen_together_unavailable".localized])
    XCTAssertNotEqual("listen_together_unavailable".localized, "listen_together_unavailable")
  }

  func testBannerSpeaksDownloadInQuarterSteps() {
    let state = ListenTogetherState.listening(participants: 2, downloaded: 0.6)
    XCTAssertEqual(
      ListenTogetherStatus.spokenText(for: state),
      String.localizedStringWithFormat("listen_together_status_downloading".localized, 50))
    XCTAssertEqual(
      ListenTogetherStatus.visibleText(for: state),
      String.localizedStringWithFormat("listen_together_status_downloading".localized, 60))
  }

  func testBannerHasNoPluralForOnePerson() {
    XCTAssertEqual(
      ListenTogetherStatus.visibleText(for: .sharing(participants: 1)),
      "listen_together_status_sharing_waiting".localized)
    XCTAssertEqual(
      ListenTogetherStatus.visibleText(for: .sharing(participants: 3)),
      String.localizedStringWithFormat("listen_together_status_sharing".localized, 3))
    XCTAssertNil(ListenTogetherStatus.visibleText(for: .idle))
  }
}
