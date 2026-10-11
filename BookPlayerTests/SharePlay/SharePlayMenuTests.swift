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

  func testUnavailableEndIsAnAlert() {
    let service = makeService()
    service.endUnavailable()
    XCTAssertEqual(service.state, .ended(reason: .unavailable))
    // E12: a centred alert (R41), not an announcement and not a timed banner.
    XCTAssertEqual(posted, [])
    XCTAssertEqual(service.messages.alerts.next?.message, .unavailable)
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

  // MARK: Fix round 1

  func testInvitationIsAnnounced() {
    let service = makeService()
    service.showInvitation(title: "Moby-Dick", author: "Herman Melville")
    XCTAssertEqual(service.state, .invitation(title: "Moby-Dick", author: "Herman Melville"))
    XCTAssertEqual(posted, [
      String.localizedStringWithFormat(
        "listen_together_invitation_announcement".localized, "Moby-Dick", "Herman Melville")
    ])
    XCTAssertEqual(posted.first, "Listen Together invitation: Moby-Dick by Herman Melville")

    service.showInvitation(title: "Untitled", author: "")
    XCTAssertEqual(posted.last, "Listen Together invitation: Untitled")
  }

  func testDeclineDoesNothingWithoutPendingInvitation() {
    let service = makeService()
    service.setState(.sharing(participants: 2))
    service.declineInvitation()
    XCTAssertEqual(service.state, .sharing(participants: 2))
  }

  func testJoinLabelUsesTheHigherContrastColour() {
    XCTAssertEqual(ListenTogetherContrast.ratio(.white, .black), 21, accuracy: 0.01)
    let lightGray = UIColor(white: 0.85, alpha: 1)
    XCTAssertEqual(ListenTogetherContrast.bestLabel(on: .white, from: [lightGray, .black]), .black)
    let navy = UIColor(red: 0.05, green: 0.1, blue: 0.3, alpha: 1)
    XCTAssertEqual(ListenTogetherContrast.bestLabel(on: navy, from: [.black, .white]), .white)
  }

  func testNormalSpeedIsNotReadAsOneTimes() {
    XCTAssertEqual(ListenerExtrasRow.spokenRate(1), "listen_together_speed_normal".localized)
    XCTAssertEqual(ListenerExtrasRow.spokenRate(1.5), "1.5 times")
    XCTAssertEqual(
      ListenTogetherAnnouncements.text(for: .speedChanged(rate: 1)),
      "listen_together_remote_speed_normal".localized)
    XCTAssertFalse(ListenTogetherAnnouncements.text(for: .speedChanged(rate: 1)).contains("1 times"))
  }

  // MARK: Fix round 2

  func testInvitationTakenDownWithoutAnswerIsShownAgain() {
    let invitation = ListenTogetherState.invitation(title: "T", author: "A")
    XCTAssertTrue(MainCoordinator.shouldRepresentInvitation(answered: false, state: invitation))
    XCTAssertFalse(MainCoordinator.shouldRepresentInvitation(answered: true, state: invitation))
    XCTAssertFalse(MainCoordinator.shouldRepresentInvitation(answered: false, state: .idle))
    XCTAssertFalse(
      MainCoordinator.shouldRepresentInvitation(answered: false, state: .listening(participants: 2, downloaded: 0)))
  }

  func testListenerScreenShowsFromListeningBeforeTheBookArrives() {
    typealias P = ListenTogetherPresentation
    let listening = ListenTogetherState.listening(participants: 1, downloaded: 0)
    XCTAssertTrue(P.showsListenerScreen(state: listening, hasListener: false, isCovered: false, isRequested: true))
    XCTAssertTrue(P.showsListenerScreen(state: listening, hasListener: true, isCovered: false, isRequested: true))
    XCTAssertFalse(P.showsListenerScreen(state: listening, hasListener: false, isCovered: true, isRequested: true))
    XCTAssertFalse(P.showsListenerScreen(state: .invitation(title: "T", author: "A"), hasListener: false, isCovered: false, isRequested: true))
    XCTAssertFalse(P.showsListenerScreen(state: .ended(reason: .normal), hasListener: false, isCovered: false, isRequested: true))
    XCTAssertFalse(P.showsListenerScreen(state: .sharing(participants: 2), hasListener: false, isCovered: false, isRequested: true))
  }

  func testMagicTapNeverReachesTheLibraryBookInAListenerSession() {
    typealias P = ListenTogetherPresentation
    let listening = ListenTogetherState.listening(participants: 1, downloaded: 0)
    XCTAssertEqual(P.magicTapTarget(state: listening, hasListener: false), .nothing)
    XCTAssertEqual(P.magicTapTarget(state: listening, hasListener: true), .listener)
    XCTAssertEqual(P.magicTapTarget(state: .idle, hasListener: false), .libraryPlayer)
    XCTAssertEqual(P.magicTapTarget(state: .sharing(participants: 2), hasListener: false), .libraryPlayer)
    XCTAssertEqual(P.magicTapTarget(state: .ended(reason: .normal), hasListener: false), .libraryPlayer)
  }

  func testZeroTimeIsSpokenAsZeroSeconds() {
    XCTAssertEqual(ListenerTimeText.spoken(0), "listen_together_zero_seconds".localized)
    XCTAssertEqual(ListenerTimeText.spoken(0.3), "listen_together_zero_seconds".localized)
    XCTAssertEqual(ListenerTimeText.spoken(30), VoiceOverService.secondsToMinutes(30))
    XCTAssertNotEqual("listen_together_zero_seconds".localized, "listen_together_zero_seconds")
  }
}
