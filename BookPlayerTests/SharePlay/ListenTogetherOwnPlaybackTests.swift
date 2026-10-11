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

  private func makeLoader(isPlaying: Bool, gate: (@MainActor () async -> Bool)?) -> (PlayerLoaderService, PlayerManagerProtocolMock) {
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
    let (loader, playerManager) = makeLoader(isPlaying: false, gate: { asked += 1; return false })
    await loader.playLoadedBook()
    await loader.playPauseLoadedBook()
    XCTAssertEqual(asked, 2)
    XCTAssertEqual(playerManager.playCallsCount, 0)
    XCTAssertEqual(playerManager.playPauseCallsCount, 0)
  }

  /// Pausing never asks.
  func testPauseNeverAsks() async {
    var asked = 0
    let (loader, playerManager) = makeLoader(isPlaying: true, gate: { asked += 1; return false })
    await loader.playPauseLoadedBook()
    XCTAssertEqual(asked, 0)
    XCTAssertEqual(playerManager.playPauseCallsCount, 1)
  }

  func testAllowedGatePlays() async {
    let (loader, playerManager) = makeLoader(isPlaying: false, gate: { true })
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
}
