@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

/// Fix wave 2: the user's own book during a listener session (R38), Magic Tap before the book arrives
/// (W-I3) and retrying the invitation when it could not be shown (W-I5). Pure decisions and the
/// PlayerLoaderService gate; no UI and no clock.
@MainActor
final class ListenTogetherOwnPlaybackTests: XCTestCase {
  typealias Own = ListenTogetherOwnPlayback

  // MARK: R38 decision

  func testOwnBookPlaysWhenNotListening() {
    XCTAssertEqual(Own.decision(isListenerSession: false, canAsk: true), .play)
    XCTAssertEqual(Own.decision(isListenerSession: false, canAsk: false), .play)
  }

  func testOwnBookAsksFirstDuringAListenerSession() {
    XCTAssertEqual(Own.decision(isListenerSession: true, canAsk: true), .ask)
  }

  /// Nothing can be shown (background, locked, CarPlay with the phone locked, Siri): nothing plays.
  func testOwnBookIsRefusedWhenTheQuestionCannotBeAsked() {
    XCTAssertEqual(Own.decision(isListenerSession: true, canAsk: false), .refuse)
  }

  func testLeaveEndsTheSessionThenPlays() {
    let outcome = Own.outcome(of: .leave, isListenerSession: true)
    XCTAssertTrue(outcome.endsSession)
    XCTAssertTrue(outcome.plays)
  }

  /// Cancel (and escape, which is the alert's cancel action) changes nothing and plays nothing.
  func testCancelChangesNothing() {
    let outcome = Own.outcome(of: .cancel, isListenerSession: true)
    XCTAssertFalse(outcome.endsSession)
    XCTAssertFalse(outcome.plays)
  }

  /// The session ended while the question was up: Leave just plays.
  func testLeaveAfterTheSessionEndedOnlyPlays() {
    let outcome = Own.outcome(of: .leave, isListenerSession: false)
    XCTAssertFalse(outcome.endsSession)
    XCTAssertTrue(outcome.plays)
  }

  // MARK: PlayerLoaderService gate

  private func makeLoader(isPlaying: Bool, gate: (@MainActor (String?) async -> Bool)?) -> (PlayerLoaderService, PlayerManagerProtocolMock) {
    let playerManager = PlayerManagerProtocolMock()
    playerManager.underlyingIsPlaying = isPlaying
    let loader = PlayerLoaderService()
    loader.playerManager = playerManager
    loader.playbackStartGate = gate
    return (loader, playerManager)
  }

  func testNoGateAlwaysPlays() async {
    let (loader, playerManager) = makeLoader(isPlaying: false, gate: nil)
    let allowed = await loader.mayStartPlayback()
    XCTAssertTrue(allowed)
    await loader.playLoadedBook()
    XCTAssertEqual(playerManager.playCallsCount, 1)
  }

  func testDeclinedGateStartsNothing() async {
    var asked = 0
    let (loader, playerManager) = makeLoader(isPlaying: false, gate: { _ in asked += 1; return false })
    await loader.playLoadedBook()
    await loader.playPauseLoadedBook()
    XCTAssertEqual(asked, 2)
    XCTAssertEqual(playerManager.playCallsCount, 0)
    XCTAssertEqual(playerManager.playPauseCallsCount, 0)
  }

  /// Pausing never asks.
  func testPauseNeverAsks() async {
    var asked = 0
    let (loader, playerManager) = makeLoader(isPlaying: true, gate: { _ in asked += 1; return false })
    await loader.playPauseLoadedBook()
    XCTAssertEqual(asked, 0)
    XCTAssertEqual(playerManager.playPauseCallsCount, 1)
  }

  func testAllowedGatePlays() async {
    let (loader, playerManager) = makeLoader(isPlaying: false, gate: { _ in true })
    await loader.playPauseLoadedBook()
    XCTAssertEqual(playerManager.playPauseCallsCount, 1)
  }

  // MARK: W-I3 Magic Tap before the book arrives

  func testMagicTapBeforeTheBookArrivesSaysNotAvailableYet() {
    typealias P = ListenTogetherPresentation
    let target = P.magicTapTarget(state: .listening(participants: 2, downloaded: 0), hasListener: false)
    XCTAssertEqual(P.magicTapAnnouncement(for: target), "listen_together_not_available_now".localized)
    XCTAssertNil(P.magicTapAnnouncement(for: .listener))
    XCTAssertNil(P.magicTapAnnouncement(for: .libraryPlayer))
  }

  // MARK: W-I5 invitation retries

  func testInvitationIsRetriedUntilShownThenGivenUp() {
    typealias M = MainCoordinator
    let invitation = ListenTogetherState.invitation(title: "T", author: "A")
    XCTAssertEqual(M.invitationPresentationStep(presented: true, attempt: 1, state: invitation), .shown)
    XCTAssertEqual(M.invitationPresentationStep(presented: false, attempt: 1, state: invitation), .retry)
    XCTAssertEqual(
      M.invitationPresentationStep(presented: false, attempt: M.invitationMaxAttempts - 1, state: invitation), .retry)
    XCTAssertEqual(
      M.invitationPresentationStep(presented: false, attempt: M.invitationMaxAttempts, state: invitation), .giveUp)
  }

  func testNoRetryOnceTheInvitationIsAnsweredOrGone() {
    typealias M = MainCoordinator
    XCTAssertEqual(M.invitationPresentationStep(presented: false, attempt: 1, state: .idle), .notNeeded)
    XCTAssertEqual(
      M.invitationPresentationStep(presented: false, attempt: 3, state: .listening(participants: 1, downloaded: 0)),
      .notNeeded)
  }

  // MARK: Fix round 2

  /// The gate is told which book would start (for "Playing <title>" after Leave).
  func testGateReceivesTheLoadedBooksTitle() async {
    var titles: [String?] = []
    let (loader, playerManager) = makeLoader(isPlaying: false, gate: { titles.append($0); return true })
    playerManager.currentItem = PlayableItem.stub(currentTime: 0, duration: 10)
    await loader.playLoadedBook()
    XCTAssertEqual(titles, [playerManager.currentItem?.title])
  }

  func testLeftForOwnBookAnnouncementNamesTheBook() {
    XCTAssertEqual(
      ListenTogetherAnnouncements.leftForOwnBook(title: "Moby Dick"),
      String.localizedStringWithFormat("listen_together_left_for_own_book_playing".localized, "Moby Dick"))
    XCTAssertEqual(ListenTogetherAnnouncements.leftForOwnBook(title: nil), "listen_together_left_for_own_book".localized)
  }

  /// I-2: Leave ends the listener session with one announcement in context, not the generic "ended".
  func testLeaveForOwnBookEndsTheListenerSessionWithOneAnnouncement() {
    var posted: [String] = []
    let service = SharePlaySessionService(
      playerManager: PlayerManagerProtocolMock(),
      storage: ShareStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("OwnTests-\(UUID())")),
      announcer: ListenTogetherAnnouncer(post: { posted.append($0) }))
    let transport = FakeTransport()
    service.startListening(with: transport, shareID: UUID())

    service.leaveForOwnBook(announcement: "You left Listen Together. Playing T.")

    XCTAssertFalse(service.isInSession)
    XCTAssertTrue(transport.left)
    XCTAssertEqual(posted, ["You left Listen Together. Playing T."])
  }

  func testLeaveForOwnBookDoesNothingForASharerOrIdle() {
    let service = SharePlaySessionService(playerManager: PlayerManagerProtocolMock())
    service.leaveForOwnBook(announcement: "x")
    XCTAssertEqual(service.state, .idle)
  }

  // MARK: R39 refusal feedback

  func testRefusalIsSpokenAndNotifiedAtMostEvery30Seconds() {
    var clock = Date(timeIntervalSince1970: 1_000)
    var notifications = 0
    var posted: [String] = []
    let feedback = ListenTogetherOwnBookFeedback()
    feedback.now = { clock }
    feedback.postNotification = { notifications += 1 }
    let announcer = ListenTogetherAnnouncer(post: { posted.append($0) })

    feedback.refused(announcer: announcer)
    clock += 10
    feedback.refused(announcer: announcer)
    clock += 25
    feedback.refused(announcer: announcer)

    XCTAssertEqual(posted, Array(repeating: "listen_together_own_book_blocked".localized, count: 3))
    XCTAssertEqual(notifications, 2, "one notification per 30 seconds")
  }

  func testPlayerTitleFocusRequestIsUsedOnceAndExpires() {
    var clock = Date(timeIntervalSince1970: 1_000)
    let feedback = ListenTogetherOwnBookFeedback()
    feedback.now = { clock }
    XCTAssertFalse(feedback.consumePlayerTitleFocusRequest())
    feedback.requestPlayerTitleFocus()
    XCTAssertTrue(feedback.consumePlayerTitleFocusRequest())
    XCTAssertFalse(feedback.consumePlayerTitleFocusRequest(), "used once")
    feedback.requestPlayerTitleFocus()
    clock += 11
    XCTAssertFalse(feedback.consumePlayerTitleFocusRequest(), "stale after 10 s")
  }

  func testRepeatLimiter() {
    var limiter = ListenTogetherRepeatLimiter(interval: 2)
    let start = Date(timeIntervalSince1970: 0)
    XCTAssertTrue(limiter.allows(at: start))
    XCTAssertFalse(limiter.allows(at: start.addingTimeInterval(1.9)))
    XCTAssertTrue(limiter.allows(at: start.addingTimeInterval(2)))
  }
}

