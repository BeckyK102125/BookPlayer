@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

/// R35/R36: escape closes the listener screen while the session continues, and the Listen Together
/// row (above the tab bar) is the way back. All pure decisions, no timing.
@MainActor
final class ListenTogetherRowTests: XCTestCase {
  typealias P = ListenTogetherPresentation
  typealias R = ListenTogetherRow

  private let gettingBook = ListenTogetherState.listening(participants: 2, downloaded: 0.3)
  private let listening = ListenTogetherState.listening(participants: 2, downloaded: 1)
  private let sharing = ListenTogetherState.sharing(participants: 2)
  private let ended = ListenTogetherState.ended(reason: .normal)

  // MARK: (a) Whether the listener cover is shown

  func testListenerScreenIsNeverShownWhenNotRequested() {
    XCTAssertFalse(P.showsListenerScreen(state: gettingBook, hasListener: false, isCovered: false, isRequested: false))
    XCTAssertFalse(P.showsListenerScreen(state: listening, hasListener: true, isCovered: false, isRequested: false))
    XCTAssertFalse(P.showsListenerScreen(state: listening, hasListener: true, isCovered: true, isRequested: false))
  }

  func testListenerScreenWhenRequestedBehavesAsBefore() {
    XCTAssertTrue(P.showsListenerScreen(state: gettingBook, hasListener: false, isCovered: false, isRequested: true))
    XCTAssertTrue(P.showsListenerScreen(state: listening, hasListener: true, isCovered: false, isRequested: true))
    // Join while reading: waits for the player cover to leave, then appears.
    XCTAssertFalse(P.showsListenerScreen(state: listening, hasListener: true, isCovered: true, isRequested: true))
    XCTAssertFalse(P.showsListenerScreen(state: .idle, hasListener: false, isCovered: false, isRequested: true))
    XCTAssertFalse(P.showsListenerScreen(state: ended, hasListener: false, isCovered: false, isRequested: true))
    XCTAssertFalse(P.showsListenerScreen(state: sharing, hasListener: false, isCovered: false, isRequested: true))
  }

  func testEscapeClosesTheScreenAndNothingReopensItFromServiceState() {
    var requested = P.isListenerScreenRequested(after: .sessionStarted, current: false)
    XCTAssertTrue(requested)
    requested = P.isListenerScreenRequested(after: .closedByUser, current: requested)
    XCTAssertFalse(requested)
    // Participants join, pieces download, the book arrives: the screen stays closed.
    for state in [gettingBook, .listening(participants: 3, downloaded: 0.6), listening] {
      requested = P.isListenerScreenRequested(after: .stateChanged(state), current: requested)
      XCTAssertFalse(requested)
      XCTAssertFalse(P.showsListenerScreen(state: state, hasListener: true, isCovered: false, isRequested: requested))
    }
    // The row (or any explicit open) brings it back.
    requested = P.isListenerScreenRequested(after: .opened, current: requested)
    XCTAssertTrue(P.showsListenerScreen(state: listening, hasListener: true, isCovered: false, isRequested: requested))
  }

  func testOpenStaysOpenThroughStateChangesDuringTheSession() {
    var requested = P.isListenerScreenRequested(after: .sessionStarted, current: false)
    for state in [gettingBook, listening, .listening(participants: 1, downloaded: 1)] {
      requested = P.isListenerScreenRequested(after: .stateChanged(state), current: requested)
      XCTAssertTrue(requested)
    }
  }

  func testEndOrANewInvitationResetsTheRequest() {
    XCTAssertFalse(P.isListenerScreenRequested(after: .stateChanged(ended), current: true))
    XCTAssertFalse(P.isListenerScreenRequested(after: .stateChanged(.idle), current: true))
    XCTAssertFalse(P.isListenerScreenRequested(after: .stateChanged(.invitation(title: "T", author: "A")), current: true))
    // The next session presents itself again.
    XCTAssertTrue(P.isListenerScreenRequested(after: .sessionStarted, current: false))
  }

  func testEscapeOnlyClearsTheRequest() {
    let listState = ListStateManager()
    listState.isListenerScreenRequested = true
    listState.coversOnScreen = [.listenTogether]
    P.closeListenerScreen(listState: listState)
    XCTAssertFalse(listState.isListenerScreenRequested)
    // Nothing else moves: no focus request, the cover registration is left to onDismiss.
    XCTAssertEqual(listState.listenTogetherRowFocusRequest, 0)
    XCTAssertEqual(listState.coversOnScreen, [.listenTogether])
    // A second escape is still only a close.
    P.closeListenerScreen(listState: listState)
    XCTAssertFalse(listState.isListenerScreenRequested)
  }

  func testOnlyARealStartOfListeningRequestsTheScreen() {
    // A rebuild fires onChange(initial:) with old == new: an escape must not be undone by it.
    XCTAssertTrue(P.isSessionStart(wasListening: false, isListening: true))
    XCTAssertFalse(P.isSessionStart(wasListening: true, isListening: true))
    XCTAssertFalse(P.isSessionStart(wasListening: true, isListening: false))
    XCTAssertFalse(P.isSessionStart(wasListening: false, isListening: false))
  }

  func testFocusMovesToTheRowOnlyWhenTheUserClosedTheScreenInASession() {
    XCTAssertTrue(P.focusesRowAfterListenerScreenCloses(state: listening, hasListener: true, isRequested: false))
    XCTAssertTrue(P.focusesRowAfterListenerScreenCloses(state: gettingBook, hasListener: false, isRequested: false))
    // The session ended: the "ended" announcement owns the moment and the row is gone.
    XCTAssertFalse(P.focusesRowAfterListenerScreenCloses(state: ended, hasListener: false, isRequested: false))
    XCTAssertFalse(P.focusesRowAfterListenerScreenCloses(state: listening, hasListener: true, isRequested: true))
  }

  // MARK: (b) Which bottom elements show

  private func bar(
    _ state: ListenTogetherState, hasListener: Bool = false, hasLoadedBook: Bool = true,
    searchingOrEditing: Bool = false, keyboard: Bool = false
  ) -> R.BottomBar {
    R.bottomBar(
      state: state, hasListener: hasListener, hasLoadedBook: hasLoadedBook,
      isSearchingOrEditing: searchingOrEditing, isKeyboardVisible: keyboard)
  }

  func testIdleShowsOnlyTheOwnMiniPlayer() {
    XCTAssertEqual(bar(.idle), R.BottomBar(showsRow: false, showsMiniPlayer: true))
    XCTAssertEqual(bar(.idle, hasLoadedBook: false), R.BottomBar(showsRow: false, showsMiniPlayer: false))
    XCTAssertEqual(bar(.preparing(title: "T")), R.BottomBar(showsRow: false, showsMiniPlayer: true))
    XCTAssertEqual(bar(.invitation(title: "T", author: "A")), R.BottomBar(showsRow: false, showsMiniPlayer: true))
  }

  func testSharerGetsTheRowAboveTheirMiniPlayer() {
    XCTAssertEqual(bar(sharing), R.BottomBar(showsRow: true, showsMiniPlayer: true))
    XCTAssertEqual(bar(.sharing(participants: 1)), R.BottomBar(showsRow: true, showsMiniPlayer: true))
  }

  func testListenerGetsOnlyTheRowInTheMiniPlayersSlot() {
    XCTAssertEqual(bar(listening, hasListener: true), R.BottomBar(showsRow: true, showsMiniPlayer: false))
    XCTAssertEqual(
      bar(listening, hasListener: true, hasLoadedBook: false), R.BottomBar(showsRow: true, showsMiniPlayer: false))
  }

  func testGettingTheBookShowsOnlyTheRow() {
    XCTAssertEqual(bar(gettingBook), R.BottomBar(showsRow: true, showsMiniPlayer: false))
  }

  func testEndedReturnsTheOwnMiniPlayer() {
    XCTAssertEqual(bar(ended), R.BottomBar(showsRow: false, showsMiniPlayer: true))
    XCTAssertEqual(bar(.ended(reason: .prepareFailed)), R.BottomBar(showsRow: false, showsMiniPlayer: true))
  }

  func testRowStaysInSearchAndEditModeButNotOverTheKeyboard() {
    XCTAssertEqual(
      bar(listening, hasListener: true, searchingOrEditing: true), R.BottomBar(showsRow: true, showsMiniPlayer: false))
    XCTAssertEqual(bar(sharing, searchingOrEditing: true), R.BottomBar(showsRow: true, showsMiniPlayer: false))
    XCTAssertEqual(bar(sharing, keyboard: true), R.BottomBar(showsRow: false, showsMiniPlayer: false))
    XCTAssertEqual(bar(.idle, searchingOrEditing: true), R.BottomBar(showsRow: false, showsMiniPlayer: false))
  }

  // MARK: (c) The row's value

  private func value(
    _ state: ListenTogetherState, joinedTitle: String? = nil, listener: R.ListenerSnapshot? = nil,
    sharerTitle: String? = nil
  ) -> String? {
    R.value(state: state, joinedTitle: joinedTitle, listener: listener, sharerTitle: sharerTitle)
  }

  func testListenerValueSaysPlayingOrPausedWithTheTitle() {
    let playing = R.ListenerSnapshot(title: "Moby Dick", isPlaying: true, isWaiting: false)
    let paused = R.ListenerSnapshot(title: "Moby Dick", isPlaying: false, isWaiting: false)
    XCTAssertEqual(
      value(listening, listener: playing),
      String.localizedStringWithFormat("listen_together_row_value_playing".localized, "Moby Dick"))
    XCTAssertEqual(
      value(listening, listener: paused),
      String.localizedStringWithFormat("listen_together_row_value_paused".localized, "Moby Dick"))
  }

  func testListenerValueSaysWaitingWhenAPieceIsMissing() {
    let waiting = R.ListenerSnapshot(title: "Moby Dick", isPlaying: true, isWaiting: true)
    XCTAssertEqual(
      value(.listening(participants: 2, downloaded: 0.6), listener: waiting),
      String.localizedStringWithFormat("listen_together_row_value_waiting".localized, "Moby Dick"))
  }

  func testGettingTheBookValueStepsBy25Percent() {
    let fiftyish = value(.listening(participants: 2, downloaded: 0.6))
    XCTAssertEqual(fiftyish, String.localizedStringWithFormat("listen_together_row_value_downloading".localized, 50))
    XCTAssertEqual(
      value(.listening(participants: 2, downloaded: 0.1)),
      String.localizedStringWithFormat("listen_together_row_value_downloading".localized, 0))
    XCTAssertEqual(
      value(.listening(participants: 2, downloaded: 0.6), joinedTitle: "Moby Dick"),
      String.localizedStringWithFormat("listen_together_row_value_downloading".localized, 50) + ", Moby Dick")
  }

  func testSharerAccessoryValueDoesNotRepeatTheTitle() {
    XCTAssertEqual(
      R.sharerAccessoryValue,
      "listen_together_title".localized + ", " + "listen_together_row_value_sharing_untitled".localized)
  }

  func testSharerValueSaysSharingWithTheTitle() {
    XCTAssertEqual(
      value(sharing, sharerTitle: "Moby Dick"),
      String.localizedStringWithFormat("listen_together_row_value_sharing".localized, "Moby Dick"))
    XCTAssertEqual(value(sharing, sharerTitle: ""), "listen_together_row_value_sharing_untitled".localized)
    XCTAssertEqual(value(sharing, sharerTitle: nil), "listen_together_row_value_sharing_untitled".localized)
  }

  func testNoValueOutsideASession() {
    XCTAssertNil(value(.idle))
    XCTAssertNil(value(ended))
    XCTAssertNil(value(.preparing(title: "T")))
  }

  func testValueStringsExist() {
    for key in [
      "listen_together_row_value_playing", "listen_together_row_value_paused", "listen_together_row_value_sharing",
      "listen_together_row_value_sharing_untitled", "listen_together_row_value_waiting",
      "listen_together_row_value_downloading", "listen_together_row_hint_listener", "listen_together_row_hint_sharer",
    ] {
      XCTAssertNotEqual(key.localized, key, key)
    }
    XCTAssertEqual(
      String.localizedStringWithFormat("listen_together_row_value_playing".localized, "Moby Dick"),
      "playing, Moby Dick")
  }
}
