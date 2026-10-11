@testable import BookPlayer
import UIKit
import XCTest

/// C1 (fix round 2): the Leave / Cancel alert presented for real in the app-hosted test runner. UIKit
/// runs an action's handler in the alert's dismissal completion, after `viewDidDisappear`; Leave must
/// still be answered as Leave.
@MainActor
final class ListenTogetherLeaveAlertTests: XCTestCase {
  private var window: UIWindow!

  override func setUp() async throws {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    window.makeKeyAndVisible()
  }

  override func tearDown() async throws {
    window.rootViewController?.presentedViewController?.dismiss(animated: false)
    window.isHidden = true
    window = nil
  }

  private typealias ActionHandler = @convention(block) (UIAlertAction) -> Void

  /// The handler UIKit calls for `action` (private storage, read the way UIKit tests usually do).
  private func handler(of action: UIAlertAction) throws -> ActionHandler {
    let block = try XCTUnwrap(action.value(forKey: "handler") as AnyObject?)
    return unsafeBitCast(block, to: ActionHandler.self)
  }

  /// Presents the alert and returns it plus the answers it reports.
  private func present() throws -> (ListenTogetherLeaveAlertController, () -> [ListenTogetherOwnPlayback.Answer]) {
    var answers: [ListenTogetherOwnPlayback.Answer] = []
    let alert = ListenTogetherLeaveQuestion.makeAlert { answers.append($0) }
    window.rootViewController?.present(alert, animated: false)
    XCTAssertNotNil(alert.presentingViewController, "the alert is on screen")
    return (alert, { answers })
  }

  /// Lets the main queue run for `seconds` (the unanswered-cancel delay is 0.3 s).
  private func runMainQueue(for seconds: TimeInterval) async {
    let done = expectation(description: "main queue ran")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
    await fulfillment(of: [done], timeout: seconds + 5)
  }

  /// Leave tapped: dismiss, then the handler in the completion, as UIKit does. The answer is Leave,
  /// and nothing else is reported afterwards.
  func testLeaveIsAnsweredAsLeaveEvenThoughTheAlertDisappearsFirst() async throws {
    let (alert, answers) = try present()
    var order: [String] = []
    let originalDisappear = alert.onDisappear
    alert.onDisappear = { order.append("disappear"); originalDisappear?() }
    let leave = try XCTUnwrap(alert.actions.first { $0.style == .destructive })
    let leaveHandler = try handler(of: leave)

    alert.dismiss(animated: false) {
      order.append("handler")
      leaveHandler(leave)
    }
    for _ in 0..<20 where answers().isEmpty { await runMainQueue(for: 0.25) }
    await runMainQueue(for: 0.5)   // a late Cancel, if any, would arrive now

    XCTAssertEqual(order, ["disappear", "handler"], "UIKit order: viewDidDisappear before the handler")
    XCTAssertEqual(answers(), [.leave])
  }

  func testCancelIsAnsweredAsCancel() async throws {
    let (alert, answers) = try present()
    let cancel = try XCTUnwrap(alert.actions.first { $0.style == .cancel })
    let cancelHandler = try handler(of: cancel)
    alert.dismiss(animated: false) { cancelHandler(cancel) }
    for _ in 0..<20 where answers().isEmpty { await runMainQueue(for: 0.25) }
    await runMainQueue(for: 0.5)
    XCTAssertEqual(answers(), [.cancel])
  }

  /// Taken down without any action (a screen beneath it closed): Cancel, after the short delay.
  func testAlertTakenDownWithoutAnAnswerIsCancel() async throws {
    let (alert, answers) = try present()
    alert.dismiss(animated: false)
    XCTAssertEqual(answers(), [], "not answered straight away: an action handler may still be coming")
    // Bounded wait: the disappearance can land a little later when the whole suite runs.
    for _ in 0..<20 where answers().isEmpty { await runMainQueue(for: 0.25) }
    XCTAssertEqual(answers(), [.cancel])
  }

  /// Leave stays the destructive action and is not the preferred (default) one.
  func testLeaveIsNotThePreferredAction() throws {
    let alert = ListenTogetherLeaveQuestion.makeAlert { _ in }
    XCTAssertNil(alert.preferredAction)
    XCTAssertEqual(alert.actions.map(\.style), [.destructive, .cancel])
  }
}
