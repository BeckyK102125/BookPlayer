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
  private let cancelledText = "listen_together_cancelled_announcement".localized
  private let didntStartText = "listen_together_didnt_start_announcement".localized

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

  /// Starts a sheet share that comes back `.sent` at t = 0 and returns its share ID.
  private func startSentShare(
    _ service: SharePlaySessionService, _ presenter: FakeSharingSheetPresenter
  ) async throws -> UUID {
    presenter.outcome = .sent
    await service.startSharing(makeItem())
    return try XCTUnwrap(presenter.presented.last?.shareID)
  }

  private func isShare(_ action: SharePlaySessionService.IncomingSessionAction, late: Bool) -> Bool {
    if case .share(_, let isLate) = action { return isLate == late }
    return false
  }

  private func isLeave(_ action: SharePlaySessionService.IncomingSessionAction) -> Bool {
    if case .leave = action { return true }
    return false
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
    let service = makeService(presenter: presenter, scheduler: ManualScheduler())
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

  /// First time on this device: the note's Share opens the sheet; nothing before that.
  func testFirstShareNoteShareOpensTheSheet() async {
    defaults.removeObject(forKey: SharePlaySessionService.firstShareNoteSeenKey)
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    let service = makeService(presenter: presenter, scheduler: ManualScheduler())
    await service.chooseListenTogether(makeItem())
    XCTAssertTrue(service.showsFirstShareNote)
    XCTAssertEqual(presenter.presented.count, 0, "no sheet before the note is answered")

    await service.acknowledgeFirstShareNote()
    XCTAssertEqual(presenter.presented.count, 1)
    XCTAssertTrue(service.isPreparing)
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

    XCTAssertEqual(service.state, .idle)
    XCTAssertFalse(service.isPreparing)
    XCTAssertTrue(service.canOfferSharing(makeItem()), "Listen Together is offered again")
    XCTAssertEqual(posted, [], "the announcement waits for the dismissal to settle")

    scheduler.advance(by: .milliseconds(700))
    XCTAssertEqual(posted, [cancelledText])
    scheduler.runAll()
    XCTAssertEqual(posted, [cancelledText], "said once; the watchdog does nothing afterwards")
  }

  /// Our own session arriving after an explicit Cancel is left (what `received` does with it).
  func testOwnSessionAfterExplicitCancelIsLeft() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .cancelled)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    await service.startSharing(makeItem())
    let shareID = try XCTUnwrap(presenter.presented.first?.shareID)
    scheduler.advance(by: .seconds(25))

    XCTAssertTrue(isLeave(service.action(forIncoming: shareID)))
    XCTAssertEqual(service.state, .idle)
    XCTAssertTrue(isShare(service.action(forIncoming: UUID()), late: false) == false)
  }

  // MARK: Waiting for the session (R37: up to 20 s, late sessions still accepted)

  func testSessionAt19SecondsIsClaimed() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    let shareID = try await startSentShare(service, presenter)
    XCTAssertEqual(service.state, .idle, "still no banner straight after the sheet closes")

    scheduler.advance(by: .milliseconds(700))
    XCTAssertEqual(service.state, .preparing(title: makeItem().title))
    XCTAssertEqual(posted, [preparingText], "preparing is announced after the sheet has closed")

    scheduler.advance(to: .seconds(19))
    XCTAssertTrue(service.isPreparing, "still waiting at 19 s")
    XCTAssertTrue(isShare(service.action(forIncoming: shareID), late: false))
    XCTAssertFalse(service.isPreparing)

    scheduler.runAll()
    XCTAssertEqual(posted, [preparingText], "no didn't-start once the session is here")
  }

  /// No session by 20 s: Listen Together says it didn't start and is offered again, but the share is not
  /// cancelled. Its session at 25 s, with nothing else going on, starts as our share.
  func testSessionAt25SecondsAfterTheWaitIsStillClaimedWhenIdle() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    let shareID = try await startSentShare(service, presenter)

    scheduler.advance(to: .seconds(20))
    XCTAssertEqual(service.state, .idle)
    XCTAssertFalse(service.isPreparing)
    XCTAssertTrue(service.canOfferSharing(makeItem()))
    XCTAssertEqual(posted, [preparingText], "the announcement waits for the banner change to settle")
    scheduler.advance(to: .seconds(21))
    // E13: a centred alert, not an announcement.
    XCTAssertEqual(posted, [preparingText])
    XCTAssertEqual(service.messages.alerts.next?.message, .didntStart)

    scheduler.advance(to: .seconds(25))
    XCTAssertTrue(isShare(service.action(forIncoming: shareID), late: true))
    XCTAssertTrue(isLeave(service.action(forIncoming: shareID)) == false, "claimed once")
  }

  /// A late session while another share is pending is left: this device is busy with the new share, and
  /// staying in the old one would leave its people waiting in a session nobody shares into.
  func testLateSessionWhileAnotherShareIsPendingIsLeft() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    let oldID = try await startSentShare(service, presenter)
    scheduler.advance(to: .seconds(21))
    let newID = try await startSentShare(service, presenter)
    XCTAssertNotEqual(oldID, newID)

    scheduler.advance(to: .seconds(25))
    XCTAssertTrue(isLeave(service.action(forIncoming: oldID)))
    XCTAssertTrue(service.isPreparing, "the new share is untouched")
    XCTAssertTrue(isShare(service.action(forIncoming: newID), late: false))
  }

  /// The session arrived before the preparing moment: preparing is not shown or announced.
  func testSessionArrivingBeforeThePreparingMomentSkipsIt() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    let shareID = try await startSentShare(service, presenter)
    XCTAssertTrue(isShare(service.action(forIncoming: shareID), late: false))

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
    let shareID = try await startSentShare(service, presenter)
    scheduler.advance(by: .seconds(1))
    service.end()
    XCTAssertEqual(service.state, .idle)

    scheduler.runAll()
    XCTAssertEqual(posted, [preparingText])
    XCTAssertTrue(isLeave(service.action(forIncoming: shareID)), "End cancels the share")
  }

  /// A new share started after an old one was ended is not touched by the old timers.
  func testOldTimerDoesNotTouchANewerShare() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    _ = try await startSentShare(service, presenter)
    let firstTimers = scheduler.takeAll()
    service.end()
    _ = try await startSentShare(service, presenter)
    XCTAssertEqual(presenter.presented.count, 2)
    firstTimers.forEach { $0() }
    XCTAssertTrue(service.isPreparing, "the first share's timers do not touch the second")
    XCTAssertEqual(service.state, .idle)
    XCTAssertEqual(posted, [])
  }

  /// I-4: a "not started" result is not announced over a newer share started within 0.7 s.
  func testCancelAnnouncementIsDroppedWhenANewShareStarts() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .cancelled)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    await service.startSharing(makeItem())
    presenter.outcome = .sent
    await service.startSharing(makeItem())

    scheduler.advance(by: .milliseconds(700))
    XCTAssertFalse(posted.contains(cancelledText))
  }

  // MARK: Stuck sheet (B2.7)

  /// The sheet never reports a result: the watchdog releases the share, Listen Together and invitations
  /// work again, and the share is not cancelled (its session may still come).
  func testSheetThatNeverReturnsIsReleasedByTheWatchdog() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    presenter.holdsResult = true
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    let task = Task { await service.startSharing(self.makeItem()) }
    while presenter.presented.isEmpty { await Task.yield() }
    let shareID = try XCTUnwrap(presenter.presented.first?.shareID)
    XCTAssertTrue(service.isPreparing)
    XCTAssertFalse(service.canOfferSharing(makeItem()))

    scheduler.advance(to: .seconds(119))
    XCTAssertTrue(service.isPreparing, "the sheet may simply still be open")
    scheduler.advance(to: .seconds(121))
    XCTAssertFalse(service.isPreparing)
    XCTAssertEqual(service.state, .idle)
    XCTAssertTrue(service.canOfferSharing(makeItem()), "Listen Together is offered again")
    XCTAssertEqual(service.decision(forIncoming: UUID()), .invitation, "invitations are offered again")
    XCTAssertEqual(posted, [])
    XCTAssertEqual(service.messages.alerts.next?.message, .didntStart)

    // The sheet finally reports Cancel: its session must not start later.
    presenter.release(.cancelled)
    await task.value
    XCTAssertTrue(isLeave(service.action(forIncoming: shareID)))
  }

  /// The presenter saw the sheet leave the screen without a result: released straight away.
  func testAbandonedSheetReleasesTheShare() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .abandoned)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    await service.startSharing(makeItem())
    let shareID = try XCTUnwrap(presenter.presented.first?.shareID)
    XCTAssertFalse(service.isPreparing)
    XCTAssertEqual(service.state, .idle)
    scheduler.advance(by: .milliseconds(700))
    XCTAssertEqual(posted, [])
    XCTAssertEqual(service.messages.alerts.next?.message, .didntStart)
    XCTAssertTrue(isShare(service.action(forIncoming: shareID), late: true), "a late session still starts")
  }

  // MARK: Fix wave 2

  private let startedText = "listen_together_started_late_announcement".localized

  /// W-I2: the watchdog never releases (or speaks over) a sheet that is still on screen. It checks again
  /// later and releases once the sheet has gone.
  func testWatchdogWaitsWhileTheSheetIsStillOpen() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    presenter.holdsResult = true
    presenter.isSharingSheetPresented = true
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    let task = Task { await service.startSharing(self.makeItem()) }
    while presenter.presented.isEmpty { await Task.yield() }

    scheduler.advance(to: .seconds(121))
    XCTAssertTrue(service.isPreparing, "the sheet is still open: nothing released")
    scheduler.advance(to: .seconds(239))
    XCTAssertTrue(service.isPreparing)
    XCTAssertEqual(posted, [], "nothing is said over the open sheet")
    XCTAssertNil(service.messages.alerts.next)

    presenter.isSharingSheetPresented = false
    scheduler.advance(to: .seconds(241))
    XCTAssertFalse(service.isPreparing, "released at the next check once the sheet is gone")
    scheduler.advance(by: .milliseconds(700))
    XCTAssertEqual(posted, [])
    XCTAssertEqual(service.messages.alerts.next?.message, .didntStart)

    presenter.release(.cancelled)
    await task.value
  }

  func testSheetWatchdogAction() {
    typealias S = SharePlaySessionService
    XCTAssertEqual(S.sheetWatchdogAction(isSheetStillPresented: true), .checkAgainLater)
    XCTAssertEqual(S.sheetWatchdogAction(isSheetStillPresented: false), .release)
  }

  /// Minor: our own session after the sharing sheet is announced as started (once); a FaceTime share
  /// (no sheet) is not; a late one is.
  func testStartedIsAnnouncedOnceForSheetShares() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    let service = makeService(presenter: presenter, scheduler: ManualScheduler())
    let shareID = try await startSentShare(service, presenter)
    XCTAssertEqual(service.startedAnnouncement(forShare: shareID, late: false), startedText)
    XCTAssertEqual(service.startedAnnouncement(forShare: shareID, late: true), startedText)
    XCTAssertNil(service.startedAnnouncement(forShare: UUID(), late: false), "FaceTime share: no sheet")
  }

  /// Minor: when a newer late share replaces an older one, the older one is cancelled, so its session
  /// can't come back as a self-invitation.
  func testReplacedLateShareIsCancelled() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    let first = try await startSentShare(service, presenter)
    scheduler.advance(to: .seconds(21))          // first released (late share)
    let second = try await startSentShare(service, presenter)
    scheduler.advance(to: .seconds(42))          // second released, replaces the first

    XCTAssertTrue(isLeave(service.action(forIncoming: first)), "the replaced share is left")
    XCTAssertTrue(isShare(service.action(forIncoming: second), late: true))
  }

  /// Change B minor: "didn't start" is not spoken over an invitation that is showing.
  func testDidntStartIsNotSpokenWhileAnInvitationShows() async throws {
    let presenter = FakeSharingSheetPresenter(outcome: .sent)
    let scheduler = ManualScheduler()
    let service = makeService(presenter: presenter, scheduler: scheduler)
    _ = try await startSentShare(service, presenter)
    scheduler.advance(to: .seconds(20))          // released; the announcement waits 0.7 s
    service.showInvitation(title: "Moby Dick", author: "Herman Melville")
    posted = []

    scheduler.advance(to: .seconds(21))

    XCTAssertFalse(posted.contains(didntStartText))
    XCTAssertNil(service.messages.alerts.next, "nothing shown over the invitation")
  }
}

@MainActor
final class FakeSharingSheetPresenter: ListenTogetherSharingSheetPresenting {
  var outcome: ListenTogetherSharingSheetOutcome
  var canPresentSharingSheet = true
  var isSharingSheetPresented = false
  /// When true, the sheet does not report back until `release(_:)`.
  var holdsResult = false
  var presented: [ListenTogetherActivity] = []
  var onPresent: (() -> Void)?
  private var held: CheckedContinuation<ListenTogetherSharingSheetOutcome, Never>?

  init(outcome: ListenTogetherSharingSheetOutcome) { self.outcome = outcome }

  func presentSharingSheet(for activity: ListenTogetherActivity) async -> ListenTogetherSharingSheetOutcome {
    presented.append(activity)
    onPresent?()
    guard holdsResult else { return outcome }
    return await withCheckedContinuation { held = $0 }
  }

  func release(_ outcome: ListenTogetherSharingSheetOutcome) {
    held?.resume(returning: outcome)
    held = nil
  }
}

/// Collects scheduled work on a fake clock; the test moves the clock. Each action runs at
/// (time it was scheduled + delay), in time order. No real time passes.
@MainActor
final class ManualScheduler {
  private var items: [(due: Duration, order: Int, action: @MainActor () -> Void)] = []
  private var counter = 0
  private(set) var now: Duration = .zero

  var schedule: @MainActor (Duration, @escaping @MainActor () -> Void) -> Void {
    { [self] delay, action in
      counter += 1
      items.append((now + delay, counter, action))
      items.sort { ($0.due, $0.order) < ($1.due, $1.order) }
    }
  }

  /// Runs everything due up to `time` (including work scheduled meanwhile), then sets the clock there.
  func advance(to time: Duration) {
    while let first = items.first, first.due <= time {
      items.removeFirst()
      now = first.due
      first.action()
    }
    now = max(now, time)
  }

  func advance(by delay: Duration) { advance(to: now + delay) }

  func runAll() {
    while let first = items.first {
      items.removeFirst()
      now = first.due
      first.action()
    }
  }

  func takeAll() -> [@MainActor () -> Void] {
    defer { items = [] }
    return items.map(\.action)
  }
}
