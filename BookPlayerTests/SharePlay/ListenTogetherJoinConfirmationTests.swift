@testable import BookPlayer
import UIKit
import XCTest

/// SR7-06: Join asks before it closes an open sheet, and doesn't ask when nothing would be lost.
@MainActor
final class ListenTogetherJoinConfirmationTests: XCTestCase {
  func testNoQuestionWhenTheInvitationIsOverTheMainView() {
    let main = UIViewController()
    XCTAssertFalse(MainCoordinator.joinClosesAnOpenScreen(
      invitationPresenter: main, main: main, isShowingPlayer: false))
  }

  func testNoQuestionWhenTheInvitationIsOverThePlayer() throws {
    let main = UIViewController(), player = UIViewController()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene, "the test host has a scene")
    let window = UIWindow(windowScene: scene)
    window.rootViewController = main
    window.makeKeyAndVisible()
    main.present(player, animated: false)
    XCTAssertFalse(MainCoordinator.joinClosesAnOpenScreen(
      invitationPresenter: player, main: main, isShowingPlayer: true))
    window.isHidden = true
  }

  func testAsksWhenTheInvitationIsOverASheet() {
    let main = UIViewController(), sheet = UIViewController()
    XCTAssertTrue(MainCoordinator.joinClosesAnOpenScreen(
      invitationPresenter: sheet, main: main, isShowingPlayer: false))
    XCTAssertTrue(MainCoordinator.joinClosesAnOpenScreen(
      invitationPresenter: sheet, main: main, isShowingPlayer: true),
      "a sheet that isn't the player cover still closes")
  }

  func testNoQuestionWithoutAnInvitation() {
    XCTAssertFalse(MainCoordinator.joinClosesAnOpenScreen(
      invitationPresenter: nil, main: UIViewController(), isShowingPlayer: false))
  }
}
