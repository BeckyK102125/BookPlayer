@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

/// Change B: starting Listen Together from Messages through Apple's sharing sheet when there is no
/// FaceTime call. No real sheet and no real clock: the presenter and the scheduler are fakes.
@MainActor
final class ListenTogetherSharingSheetTests: XCTestCase {
  private var posted: [String] = []
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var audioFile: URL!

  override func setUp() async throws {
    posted = []
    // `canOfferSharing` needs the book's file to exist.
    audioFile = DataManager.getProcessedFolderURL().appendingPathComponent("SheetTests-\(UUID().uuidString).m4a")
    FileManager.default.createFile(atPath: audioFile.path, contents: Data([0]))
    suiteName = "SharingSheetTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.set(true, forKey: SharePlaySessionService.firstShareNoteSeenKey)
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: audioFile)
  }

  private func makeService(
    presenter: FakeSharingSheetPresenter?,
    scheduler: ManualScheduler
  ) -> SharePlaySessionService {
    let service = SharePlaySessionService(
      playerManager: PlayerManagerProtocolMock(),
      storage: ShareStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("SheetTests-\(UUID())")),
      announcer: ListenTogetherAnnouncer(post: { [weak self] in self?.posted.append($0) }),
      defaults: defaults)
    service.isEligibleForGroupSession = { false }
    service.sharingSheetPresenter = presenter
    service.schedule = scheduler.schedule
    return service
  }

  private var preparingText: String {
    String.localizedStringWithFormat("listen_together_status_preparing".localized, makeItem().title)
  }

  private func makeItem() -> PlayableItem {
    PlayableItem.stub(currentTime: 0, duration: 10, fileURL: audioFile)
  }

  // MARK: Route

  func testStartRoute() {
    typealias S = SharePlaySessionService
    XCTAssertEqual(S.startRoute(isEligibleForGroupSession: true, canPresentSharingSheet: true), .activate)
    XCTAssertEqual(S.startRoute(isEligibleForGroupSession: true, canPresentSharingSheet: false), .activate)
    XCTAssertEqual(S.startRoute(isEligibleForGroupSession: false, canPresentSharingSheet: true), .sharingSheet)
    XCTAssertEqual(S.startRoute(isEligibleForGroupSession: false, canPresentSharingSheet: false), .needsFaceTime)
  }

  // MARK: Presenting

  /// The sheet opens silently: the share is pending, but no preparing banner and no announcement yet.
  func testSheetIsPresentedSilentlyWithTheSharePending() async {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    presenter.onPresent = { [unowned self] in
      XCTAssertTrue(service.isPreparing, "the share is pending while the sheet is up")
      XCTAssertEqual(service.state, .idle, "no preparing banner while the sheet has the screen")
      XCTAssertFalse(service.canOfferSharing(self.makeItem()), "Listen Together is hidden while pending")
      XCTAssertEqual(self.posted, [], "nothing announced before the sheet")
    }

    await service.startSharing(makeItem())

    XCTAssertEqual(presenter.presented.count, 1)
    XCTAssertEqual(presenter.presented.first?.title, makeItem().title)
  }

  func testNoPresenterFallsBackToNeedsFaceTime() async {
    let service = makeService(presenter: nil, scheduler: ManualScheduler())
    await service.startSharing(makeItem())
    XCTAssertEqual(service.state, .needsFaceTime)
    XCTAssertFalse(service.isPreparing)
  }

  func testPresenterThatCannotPresentFallsBackToNeedsFaceTime() async {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    presenter.canPresentSharingSheet = false
    let service = makeService(presenter: presenter, scheduler: ManualScheduler())
    await service.startSharing(makeItem())
    XCTAssertEqual(service.state, .needsFaceTime)
    XCTAssertEqual(presenter.presented.count, 0)
  }

  /// The controller could not be created (its init threw) or not shown: the fallback alert.
  func testUnavailableSheetFallsBackToNeedsFaceTime() async {
    let presenter = FakeSharingSheetPresenter(outcome: .unavailable)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    await service.startSharing(makeItem())
    XCTAssertEqual(service.state, .needsFaceTime)
    XCTAssertFalse(service.isPreparing)
    scheduler.runAll()
    XCTAssertEqual(posted, [], "the alert explains; no announcement")
  }

  // MARK: Cancel

  /// Cancel in the sheet: cleared at once, the share is cancelled, and one short announcement follows
  /// after the sheet's dismissal has settled.
  func testExplicitCancelCancelsTheShareAndAnnouncesOnce() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .cancelled)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    await service.startSharing(makeItem())
    let shareID = try XCTUnwrap(presenter.presented.first?.shareID)

    XCTAssertEqual(service.state, .idle)
    XCTAssertFalse(service.isPreparing)
    XCTAssertTrue(service.canOfferSharing(makeItem()), "Listen Together is offered again")
    XCTAssertEqual(posted, [], "the announcement waits for the dismissal to settle")
    XCTAssertEqual(scheduler.pendingDelays, [SharePlaySessionService.sheetAnnouncementDelay])

    scheduler.runAll()
    XCTAssertEqual(posted, ["listen_together_cancelled_announcement".localized])
    XCTAssertEqual(service.decision(forIncoming: shareID), .cancelledShare, "a late session is left")
  }

  /// Sent, but no session within the wait: treated as a cancel.
  func testSentWithoutASessionIsCancelledAfterTheWait() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    await service.startSharing(makeItem())
    let shareID = try XCTUnwrap(presenter.presented.first?.shareID)
    XCTAssertEqual(service.state, .idle)
    XCTAssertEqual(
      scheduler.pendingDelays,
      [SharePlaySessionService.sheetAnnouncementDelay, SharePlaySessionService.sheetSessionTimeout])

    scheduler.runNext()
    XCTAssertEqual(service.state, .preparing(title: makeItem().title))
    XCTAssertEqual(posted, [preparingText], "preparing is announced after the sheet has closed")

    scheduler.runNext()
    XCTAssertEqual(service.state, .idle)
    XCTAssertFalse(service.isPreparing)
    XCTAssertEqual(posted, [preparingText], "the announcement waits for the banner change to settle")
    scheduler.runAll()
    XCTAssertEqual(posted, [preparingText, "listen_together_cancelled_announcement".localized])
    XCTAssertEqual(service.decision(forIncoming: shareID), .cancelledShare)
  }

  /// The normal path: our session arrives. No cancel, no cancel announcement.
  func testSessionArrivingInTimeIsNotCancelled() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    await service.startSharing(makeItem())
    let shareID = try XCTUnwrap(presenter.presented.first?.shareID)

    scheduler.runNext()
    XCTAssertEqual(posted, [preparingText])
    XCTAssertEqual(service.decision(forIncoming: shareID), .ownShare)
    XCTAssertNotNil(service.claimOwnShare(shareID), "what `received` does with our session")

    scheduler.runAll()
    XCTAssertEqual(posted, [preparingText], "no cancel announcement once the session is here")
    XCTAssertNotEqual(service.decision(forIncoming: shareID), .cancelledShare)
  }

  /// The session arrived before the preparing moment: preparing is not shown or announced.
  func testSessionArrivingBeforeThePreparingMomentSkipsIt() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    await service.startSharing(makeItem())
    let shareID = try XCTUnwrap(presenter.presented.first?.shareID)
    XCTAssertNotNil(service.claimOwnShare(shareID))

    scheduler.runAll()
    XCTAssertEqual(posted, [])
    XCTAssertEqual(service.state, .idle)
  }

  /// End on the preparing banner before the wait is over: an ordinary cancel, announced by nobody,
  /// and the timer does not announce afterwards.
  func testEndDuringTheWaitIsNotAnnouncedTwice() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    await service.startSharing(makeItem())
    let shareID = try XCTUnwrap(presenter.presented.first?.shareID)
    scheduler.runNext()
    service.end()
    XCTAssertEqual(service.state, .idle)

    scheduler.runAll()
    XCTAssertEqual(posted, [preparingText])
    XCTAssertEqual(service.decision(forIncoming: shareID), .cancelledShare)
  }

  /// A new share started after an old one timed out is not cancelled by the old timer.
  func testOldTimerDoesNotCancelANewerShare() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    await service.startSharing(makeItem())
    let firstTimers = scheduler.takeAll()
    service.end()
    await service.startSharing(makeItem())
    XCTAssertEqual(presenter.presented.count, 2)
    firstTimers.forEach { $0() }
    XCTAssertTrue(service.isPreparing, "the first share's timers do not touch the second")
    XCTAssertEqual(service.state, .idle)
    XCTAssertEqual(posted, [])
  }
}

@MainActor
final class FakeSharingSheetPresenter: ListenTogetherSharingSheetPresenting {
  var outcome: ListenTogetherSharingSheetOutcome
  var canPresentSharingSheet = true
  var presented: [ListenTogetherActivity] = []
  var onPresent: (() -> Void)?

  init(outcome: ListenTogetherSharingSheetOutcome) { self.outcome = outcome }

  func presentSharingSheet(for activity: ListenTogetherActivity) async -> ListenTogetherSharingSheetOutcome {
    presented.append(activity)
    onPresent?()
    return outcome
  }
}

/// Collects scheduled work; the test runs it in delay order. No real time passes.
@MainActor
final class ManualScheduler {
  private var items: [(delay: Duration, order: Int, action: @MainActor () -> Void)] = []
  private var counter = 0

  var schedule: @MainActor (Duration, @escaping @MainActor () -> Void) -> Void {
    { [unowned self] delay, action in
      counter += 1
      items.append((delay, counter, action))
      items.sort { ($0.delay, $0.order) < ($1.delay, $1.order) }
    }
  }

  var pendingDelays: [Duration] { items.map(\.delay) }

  func runNext() {
    guard !items.isEmpty else { return }
    items.removeFirst().action()
  }

  func runAll() {
    while !items.isEmpty { runNext() }
  }

  func takeAll() -> [@MainActor () -> Void] {
    defer { items = [] }
    return items.map(\.action)
  }
}
