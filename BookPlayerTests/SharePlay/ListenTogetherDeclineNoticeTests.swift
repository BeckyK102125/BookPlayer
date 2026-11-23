@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

/// SR7-04: a sharer whose owners-only share turned someone away is told clearly, with the player
/// closed and with the app in the background.
@MainActor
final class ListenTogetherDeclineNoticeTests: XCTestCase {
  /// SR7-04: the sharer's mini player and row say why nobody joined, with the player closed too.
  func testTheSharerRowSaysSomeoneCouldNotJoin() {
    let value = ListenTogetherRow.sharerAccessoryValue(
      state: .sharing(participants: 1), title: "Moby Dick", someoneDeclined: true)
    XCTAssertEqual(value, "listen_together_title".localized + ", "
      + String.localizedStringWithFormat("listen_together_row_value_sharing_declined".localized, "Moby Dick"))
  }

  func testSomeoneCouldNotJoinIsSpokenAndNotifiedWhenAway() {
    let message = ListenTogetherUserMessage.someoneCouldNotJoin
    XCTAssertEqual(message.kind, .status)
    XCTAssertTrue(message.speaks)
    XCTAssertTrue(message.notifiesWhenAway)
    XCTAssertTrue(message.text.contains("Settings"))
  }
}
