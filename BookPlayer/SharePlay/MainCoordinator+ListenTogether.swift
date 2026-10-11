import BookPlayerKit
import Combine
import GroupActivities
import SwiftUI
import UIKit

/// The Listen Together invitation. It is presented with UIKit from the topmost presented screen, so an
/// open sheet (Settings, an item's details, the import screen…) can't hide or drop it. The service
/// also announces the invitation, so a VoiceOver user hears it wherever focus is.
extension MainCoordinator: UIAdaptivePresentationControllerDelegate {
  func bindListenTogether() {
    sharePlayService.sharingSheetPresenter = self
    // R38: starting the user's own book during a listener session asks first (one gate for the
    // library, search, CarPlay, Siri and widget paths that go through PlayerLoaderService).
    playerLoaderService.playbackStartGate = { [weak self] in
      await self?.confirmOwnPlayback() ?? true
    }
    listenTogetherSubscription = sharePlayService.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        MainActor.assumeIsolated { self?.listenTogetherStateChanged(state) }
      }
  }

  private func listenTogetherStateChanged(_ state: ListenTogetherState) {
    if case .invitation = state {
      guard invitationController == nil else { return }
      startInvitationPresentation()
    } else if let controller = invitationController {
      // Declined, joined or the share went away.
      invitationController = nil
      controller.presentingViewController?.dismiss(animated: true)
    }
  }

  /// Whether an invitation that disappeared without an answer should be shown again. Test seam.
  nonisolated static func shouldRepresentInvitation(answered: Bool, state: ListenTogetherState) -> Bool {
    guard !answered, case .invitation = state else { return false }
    return true
  }

  /// The invitation left the screen. If that was not the user answering (something beneath it was
  /// closed and UIKit took it down too), show it again once the dismissal has finished.
  private func invitationDisappeared(_ host: UIViewController) {
    // Answering (Join, Not Now, swipe, state change) clears `invitationController` first.
    let answered = host !== invitationController
    if !answered { invitationController = nil }
    DispatchQueue.main.async { [weak self] in
      guard let self,
        Self.shouldRepresentInvitation(answered: answered, state: self.sharePlayService.state),
        self.invitationController == nil
      else { return }
      self.startInvitationPresentation()
    }
  }

  // MARK: Showing the invitation, with retries (W-I5)

  enum InvitationPresentationStep: Equatable {
    /// On screen.
    case shown
    /// Not shown (no window yet on a cold launch from Messages, or UIKit refused mid-transition): try
    /// again shortly.
    case retry
    /// Still not shown after every attempt: decline, so the service is not left waiting forever.
    case giveUp
    /// The invitation was answered or went away meanwhile.
    case notNeeded
  }

  nonisolated static let invitationRetryDelay: TimeInterval = 0.5
  /// 20 attempts, half a second apart: about 10 seconds for the window to appear.
  nonisolated static let invitationMaxAttempts = 20

  /// What to do after attempt number `attempt` (1-based). Test seam.
  nonisolated static func invitationPresentationStep(
    presented: Bool, attempt: Int, state: ListenTogetherState
  ) -> InvitationPresentationStep {
    if presented { return .shown }
    guard case .invitation = state else { return .notNeeded }
    return attempt < invitationMaxAttempts ? .retry : .giveUp
  }

  /// Starts a new chain of attempts; an older chain still waiting stops.
  private func startInvitationPresentation() {
    invitationPresentationGeneration += 1
    attemptInvitationPresentation(generation: invitationPresentationGeneration, attempt: 1)
  }

  private func attemptInvitationPresentation(generation: Int, attempt: Int) {
    guard generation == invitationPresentationGeneration, invitationController == nil else { return }
    var presented = false
    if case .invitation(let title, let author) = sharePlayService.state {
      presented = presentInvitation(title: title, author: author)
    }
    switch Self.invitationPresentationStep(presented: presented, attempt: attempt, state: sharePlayService.state) {
    case .shown, .notNeeded:
      return
    case .retry:
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.invitationRetryDelay) { [weak self] in
        MainActor.assumeIsolated {
          self?.attemptInvitationPresentation(generation: generation, attempt: attempt + 1)
        }
      }
    case .giveUp:
      SharePlaySessionService.logger.error("Listen Together: could not show the invitation; declining it")
      sharePlayService.declineInvitation()
    }
  }

  /// The topmost screen that is not on its way out: the invitation and the sharing sheet are shown
  /// from it, so an open sheet (Settings, an item's details, the player…) can't hide or drop them.
  func topmostPresenter() -> UIViewController? {
    guard var top = mainController, top.viewIfLoaded?.window != nil else { return nil }
    while let presented = top.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }

  @discardableResult
  private func presentInvitation(title: String, author: String) -> Bool {
    guard let top = topmostPresenter() else { return false }
    let view = ListenTogetherInvitationView(
      title: title,
      author: author,
      onJoin: { [weak self] in self?.joinListenTogether() },
      onDecline: { [weak self] in self?.sharePlayService.declineInvitation() }
    )
    .environmentObject(ThemeViewModel())
    let host = ListenTogetherInvitationHostingController(rootView: AnyView(view))
    host.onDisappear = { [weak self, weak host] in
      guard let self, let host else { return }
      self.invitationDisappeared(host)
    }
    host.modalPresentationStyle = .pageSheet
    if let sheet = host.sheetPresentationController {
      let isAccessibilitySize = UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory
      sheet.detents = isAccessibilitySize ? [.large()] : [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    host.presentationController?.delegate = self
    invitationController = host
    top.present(host, animated: true)
    // UIKit refuses a presentation while another is in progress: then nothing is on screen.
    guard host.presentingViewController != nil else {
      invitationController = nil
      return false
    }
    return true
  }

  /// Joins, then clears every screen above the main view so the listener screen can be presented.
  private func joinListenTogether() {
    let invitation = invitationController
    invitationController = nil
    sharePlayService.joinInvitation()
    guard let mainController else { return }
    if playerState.isShowingPlayer {
      // The player cover is SwiftUI's: close it through its state once the invitation has gone.
      invitation?.presentingViewController?.dismiss(animated: true) { [weak self] in
        self?.playerState.isShowingPlayer = false
      }
    } else if mainController.presentedViewController != nil {
      mainController.dismiss(animated: true)
    }
  }

  /// Swiping the invitation away counts as Not Now.
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    // `viewDidDisappear` already ran (and cleared `invitationController`); its re-present check runs on
    // the next main-loop turn, after this decline, so it sees the state has left `.invitation`.
    guard presentationController.presentedViewController is ListenTogetherInvitationHostingController
    else { return }
    invitationController = nil
    if sharePlayService.hasPendingInvitation { sharePlayService.declineInvitation() }
  }
}

// MARK: Sharing sheet (Change B: start from Messages)

extension MainCoordinator: ListenTogetherSharingSheetPresenting {
  var canPresentSharingSheet: Bool { mainController?.viewIfLoaded?.window != nil }

  var isSharingSheetPresented: Bool {
    guard let controller = sharingSheetController else { return false }
    return controller.presentingViewController != nil && !controller.isBeingDismissed
  }

  /// Apple's `GroupActivitySharingController`, shown when there is no FaceTime call. It is presented
  /// silently (it announces itself); the service announces what happens after it closes.
  func presentSharingSheet(for activity: ListenTogetherActivity) async -> ListenTogetherSharingSheetOutcome {
    // Let the More menu (or the first-share note) finish closing first; presenting over a closing
    // alert can fail without any sign, and a VoiceOver user would get no cue at all.
    try? await Task.sleep(for: .milliseconds(600))
    guard let top = topmostPresenter() else { return .unavailable }
    let controller: GroupActivitySharingController
    do {
      controller = try GroupActivitySharingController(activity)
    } catch {
      SharePlaySessionService.logger.error(
        "Listen Together: could not create the sharing sheet: \(error.localizedDescription)")
      return .unavailable
    }
    top.present(controller, animated: true)
    // UIKit refused the presentation (something else is being presented): use the fallback alert.
    // VERIFY on device that a refused presentation leaves `presentingViewController` nil.
    guard controller.presentingViewController != nil else { return .unavailable }
    sharingSheetController = controller
    let outcome = await ListenTogetherSharingSheetWatch.outcome(of: controller)
    if sharingSheetController === controller { sharingSheetController = nil }
    // The sheet normally closes itself; make sure it is gone before anything is announced.
    if controller.presentingViewController != nil, !controller.isBeingDismissed {
      controller.dismiss(animated: true)
    }
    return outcome
  }
}

// MARK: Own book during a listener session (R38)

/// Starting the user's own book while listening to someone else's asks first, so two books never
/// play at once and the lock screen never switches books under the user.
enum ListenTogetherOwnPlayback {
  enum Decision: Equatable {
    /// Not listening to anyone: play.
    case play
    /// Listening, and the question can be asked on screen.
    case ask
    /// Listening, but nothing can be shown (app in the background, locked phone, CarPlay with the
    /// phone locked, Siri): nothing plays; the listener session goes on.
    case refuse
  }

  enum Answer: Equatable {
    case leave
    case cancel
  }

  static func decision(isListenerSession: Bool, canAsk: Bool) -> Decision {
    guard isListenerSession else { return .play }
    return canAsk ? .ask : .refuse
  }

  /// After the question: Leave ends the listener session (if it is still on) and plays; Cancel (and
  /// escape, which is Cancel) leaves everything as it is.
  static func outcome(of answer: Answer, isListenerSession: Bool) -> (endsSession: Bool, plays: Bool) {
    switch answer {
    case .leave: return (isListenerSession, true)
    case .cancel: return (false, false)
    }
  }
}

/// The Leave / Cancel question. Taken down without an answer (a screen beneath it closed) counts as
/// Cancel, so the caller never waits forever.
final class ListenTogetherLeaveAlertController: UIAlertController {
  var onDisappear: (() -> Void)?

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if presentingViewController == nil || isBeingDismissed { onDisappear?() }
  }
}

extension MainCoordinator {
  /// The PlayerLoaderService gate: true when the user's own book may start now.
  func confirmOwnPlayback() async -> Bool {
    let canAsk = UIApplication.shared.applicationState == .active && topmostPresenter() != nil
    switch ListenTogetherOwnPlayback.decision(
      isListenerSession: sharePlayService.isListenerSession, canAsk: canAsk)
    {
    case .play:
      return true
    case .refuse:
      SharePlaySessionService.logger.info("Listen Together: own book not started during a listener session")
      return false
    case .ask:
      let answer = await askToLeaveListenTogether()
      let outcome = ListenTogetherOwnPlayback.outcome(
        of: answer, isListenerSession: sharePlayService.isListenerSession)
      if outcome.endsSession { sharePlayService.end() }
      return outcome.plays
    }
  }

  private func askToLeaveListenTogether() async -> ListenTogetherOwnPlayback.Answer {
    guard let top = topmostPresenter() else { return .cancel }
    return await withCheckedContinuation { continuation in
      var resume: ((ListenTogetherOwnPlayback.Answer) -> Void)?
      resume = { answer in
        resume = nil
        continuation.resume(returning: answer)
      }
      let alert = ListenTogetherLeaveAlertController(
        title: "listen_together_leave_to_play_title".localized,
        message: "listen_together_leave_to_play_message".localized,
        preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "listen_together_leave_button".localized, style: .destructive) { _ in
        resume?(.leave)
      })
      // The cancel style is what VoiceOver's escape (two-finger scrub) triggers.
      alert.addAction(UIAlertAction(title: "cancel_button".localized, style: .cancel) { _ in
        resume?(.cancel)
      })
      alert.onDisappear = { resume?(.cancel) }
      top.present(alert, animated: true)
      if alert.presentingViewController == nil { resume?(.cancel) }
    }
  }
}

/// Waits for the sharing sheet's `result`, but does not wait forever: if the sheet has left the screen
/// (checked every second, and again when the app comes back to the foreground) without reporting a
/// result, the outcome is `.abandoned`, so the pending share is released (B2.7, R37).
@MainActor
final class ListenTogetherSharingSheetWatch {
  private var continuation: CheckedContinuation<ListenTogetherSharingSheetOutcome, Never>?
  private var foregroundObserver: NSObjectProtocol?
  private var tasks: [Task<Void, Never>] = []
  /// Held weakly: once the sheet is gone nothing here keeps it alive (M6).
  private weak var controller: GroupActivitySharingController?

  private init() {}

  static func outcome(of controller: GroupActivitySharingController) async -> ListenTogetherSharingSheetOutcome {
    let watch = ListenTogetherSharingSheetWatch()
    let outcome = await withCheckedContinuation { continuation in
      watch.start(controller, continuation: continuation)
    }
    // The tasks hold the watch weakly; keep it alive until it has finished.
    withExtendedLifetime(watch) {}
    return outcome
  }

  private func start(
    _ controller: GroupActivitySharingController,
    continuation: CheckedContinuation<ListenTogetherSharingSheetOutcome, Never>
  ) {
    self.continuation = continuation
    self.controller = controller
    // Weak until it starts. While `result` is pending its getter holds the controller; `finish`
    // cancels this task, so an abandoned sheet's wait ends as soon as `result` honours cancellation.
    tasks.append(Task { [weak self, weak controller] in
      guard let controller else { return }
      let result = await controller.result
      guard !Task.isCancelled else { return }
      self?.finish(result == .success ? .sent : .cancelled)
    })
    tasks.append(Task { [weak self, weak controller] in
      var goneChecks = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, self.continuation != nil else { return }
        // Two checks in a row, so a result that arrives just after the sheet closes still wins.
        goneChecks = Self.isGone(controller) ? goneChecks + 1 : 0
        if goneChecks >= 2 { self.finish(.abandoned) }
      }
    })
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.scheduleForegroundCheck() }
    }
  }

  /// Back in the foreground: give UIKit a moment to restore the screen, then check once.
  private func scheduleForegroundCheck() {
    tasks.append(Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self else { return }
      if Self.isGone(self.controller) { self.finish(.abandoned) }
    })
  }

  private static func isGone(_ controller: UIViewController?) -> Bool {
    guard let controller else { return true }
    return controller.presentingViewController == nil && !controller.isBeingPresented
  }

  private func finish(_ outcome: ListenTogetherSharingSheetOutcome) {
    guard let continuation else { return }
    self.continuation = nil
    if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    foregroundObserver = nil
    tasks.forEach { $0.cancel() }
    tasks = []
    continuation.resume(returning: outcome)
  }
}

/// Reports when the invitation has left the screen for any reason (including a screen beneath it
/// being closed, which takes it down without `presentationControllerDidDismiss`).
final class ListenTogetherInvitationHostingController: UIHostingController<AnyView> {
  var onDisappear: (() -> Void)?

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Still presented means something was put over it, not that it went away.
    if presentingViewController == nil || isBeingDismissed { onDisappear?() }
  }
}
