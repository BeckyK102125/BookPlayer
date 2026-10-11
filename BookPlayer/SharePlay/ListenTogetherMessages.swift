import Combine
import Foundation
import UIKit
import UserNotifications

/// Every Listen Together message that is shown, announced or spoken (addendum 3, R41). Each one has
/// one treatment, chosen by `ListenTogetherMessageDelivery.plan(for:isActive:)`, so no event ever gets
/// both an alert and a VoiceOver announcement.
enum ListenTogetherUserMessage: Hashable {
  /// Listener: the person sharing pressed End (E1).
  case sharerEnded
  /// Listener: the person sharing was gone for longer than the grace (E2, spec decision 9).
  case sharerLeft
  /// Listener: the person sharing couldn't prepare the book at all.
  case sharerCouldNotPrepare
  /// Listener: the session was invalidated, or its messages stopped, without an end message (the
  /// FaceTime call ended, the connection dropped).
  case connectionEnded
  /// Sharer: the same, not caused by their own End.
  case connectionEndedSharer
  /// Sharer: the book couldn't be prepared at all; the session ends (E14).
  case prepareFailed
  /// Listen Together isn't available (E12).
  case unavailable
  /// The sharing sheet was used but the session never started (E13).
  case didntStart
  /// Listener: the person sharing is missing (E3).
  case waitingForSharer
  /// Listener: the person sharing is back (E4).
  case sharerBack
  /// Sharer: a piece failed and is tried again (E5).
  case retryingSend
  /// Listener: the group waits for this device's piece (E6).
  case waitingForBook
  /// An alert shown elsewhere (E18: "Couldn't open sharing", "You need your own copy"…): only spoken
  /// here, with `key` so the same alert is never queued twice.
  case alertShownElsewhere(text: String, key: String)

  enum Kind: Equatable {
    /// A centred alert with OK, until dismissed.
    case alert
    /// Persistent status text (drawn by the banner) plus one announcement.
    case status
    /// An announcement only (the visible change is already on screen).
    case announcement
    /// The alert is presented elsewhere; only speech is left to do.
    case spokenOnly
  }

  var kind: Kind {
    switch self {
    case .sharerEnded, .sharerLeft, .sharerCouldNotPrepare, .connectionEnded, .connectionEndedSharer,
      .prepareFailed, .unavailable, .didntStart:
      return .alert
    case .waitingForSharer, .retryingSend, .waitingForBook:
      return .status
    case .sharerBack:
      return .announcement
    case .alertShownElsewhere:
      return .spokenOnly
    }
  }

  /// The exact visible (and spoken) sentence.
  var text: String {
    switch self {
    case .sharerEnded: return "listen_together_sharer_ended".localized
    case .sharerLeft: return "listen_together_sharer_left".localized
    case .sharerCouldNotPrepare: return "listen_together_sharer_could_not_prepare".localized
    case .connectionEnded: return "listen_together_connection_ended".localized
    case .connectionEndedSharer: return "listen_together_connection_ended_sharer".localized
    case .prepareFailed: return "listen_together_prepare_failed".localized
    case .unavailable: return "listen_together_unavailable".localized
    case .didntStart: return "listen_together_didnt_start_announcement".localized
    case .waitingForSharer: return "listen_together_waiting_for_sharer".localized
    case .sharerBack: return "listen_together_sharer_back".localized
    case .retryingSend: return "listen_together_send_failed".localized
    case .waitingForBook: return "listen_together_waiting_download".localized
    case .alertShownElsewhere(let text, _): return text
    }
  }

  /// Identifies the message for the speaker (never queued twice) and the alert queue (never twice).
  var key: String {
    switch self {
    case .sharerEnded: return "sharerEnded"
    case .sharerLeft: return "sharerLeft"
    case .sharerCouldNotPrepare: return "sharerCouldNotPrepare"
    case .connectionEnded: return "connectionEnded"
    case .connectionEndedSharer: return "connectionEndedSharer"
    case .prepareFailed: return "prepareFailed"
    case .unavailable: return "unavailable"
    case .didntStart: return "didntStart"
    case .waitingForSharer: return "waitingForSharer"
    case .sharerBack: return "sharerBack"
    case .retryingSend: return "retryingSend"
    case .waitingForBook: return "waitingForBook"
    case .alertShownElsewhere(_, let key): return key
    }
  }

  /// Read aloud by "Speak error messages" (guidance B.3): errors and endings only. Never progress,
  /// "Waiting for the book", the person's own actions or "The person sharing is back".
  var speaks: Bool {
    switch self {
    case .sharerEnded, .sharerLeft, .sharerCouldNotPrepare, .connectionEnded, .connectionEndedSharer,
      .prepareFailed, .unavailable, .didntStart, .waitingForSharer, .retryingSend, .alertShownElsewhere:
      return true
    case .sharerBack, .waitingForBook:
      return false
    }
  }

  /// The session ended because of someone else, or could not run at all.
  var isEnding: Bool {
    switch self {
    case .sharerEnded, .sharerLeft, .sharerCouldNotPrepare, .connectionEnded, .connectionEndedSharer,
      .prepareFailed:
      return true
    default: return false
    }
  }

  /// A listener's ending: shown only after the listener cover has left (guidance A.0).
  var waitsForListenerCover: Bool {
    switch self {
    case .sharerEnded, .sharerLeft, .sharerCouldNotPrepare, .connectionEnded: return true
    default: return false
    }
  }

  /// The one message for a session that ended for `reason`; nil when the end was the person's own
  /// action (their End or Leave) and is handled by the existing announcement. `wasListener`: the role
  /// the session had (a connection that ended reads differently for the sharer).
  static func ending(for reason: ListenTogetherState.EndReason, wasListener: Bool = true) -> ListenTogetherUserMessage? {
    switch reason {
    case .sharerEnded: return .sharerEnded
    case .sharerLeft: return .sharerLeft
    case .sharerCouldNotPrepare: return .sharerCouldNotPrepare
    case .connectionEnded: return wasListener ? .connectionEnded : .connectionEndedSharer
    case .prepareFailed: return .prepareFailed
    case .normal, .left, .unavailable: return nil
    }
  }
}

/// Which channels a message uses (guidance A.2). Pure; unit tested for every message.
struct ListenTogetherDeliveryPlan: Equatable {
  /// Queue a centred alert (app active).
  var showsAlert = false
  /// Post a queued VoiceOver announcement.
  var announces = false
  /// Ask the speaker now (it stays silent while VoiceOver runs, during a call, or with the setting off).
  var speaksNow = false
  /// Ask the speaker when the alert is on screen.
  var speaksWithAlert = false
  /// App in the background: one local notification when permission was already given, else a pending
  /// alert.
  var notifiesOrWaits = false
  /// Also keep the alert pending after a notification (fix round 1, a11y I2): unlocked phone with
  /// VoiceOver off, where the notification is only a short banner at the screen's edge.
  var keepsAlertAfterNotification = false
}

/// Where the person is when a message arrives (fix round 1).
struct ListenTogetherDeliveryContext: Equatable {
  /// Only `.background` counts as away: an `.inactive` app (Control Center, Siri, a call banner) is in
  /// front and gets the alert once it is active again (a11y I1).
  var appState: ListenTogetherAppState = .active
  /// Locked (protected data unavailable).
  var isLocked = false
  var isVoiceOverRunning = false

  var isAway: Bool { appState == .background }
}

/// One Listen Together alert at a time (guidance A.4). FIFO; at most one pending ending: a newer
/// ending replaces whatever is pending. The alert on screen is never replaced.
struct ListenTogetherAlertQueue: Equatable {
  struct Item: Equatable, Identifiable {
    let id: UUID
    let message: ListenTogetherUserMessage
    /// Already spoken (the app was not active when it arrived).
    var isSpoken: Bool
  }

  private(set) var onScreen: Item?
  private(set) var pending: [Item] = []

  /// The alert to show next, when none is on screen.
  var next: Item? { onScreen == nil ? pending.first : nil }

  mutating func enqueue(_ item: Item) {
    if item.message.isEnding {
      pending.removeAll()
    } else if pending.contains(where: { $0.message == item.message }) || onScreen?.message == item.message {
      return
    }
    pending.append(item)
  }

  /// The first pending alert is now on screen. False if it is not the one expected.
  @discardableResult
  mutating func markPresented(_ id: UUID) -> Bool {
    guard onScreen == nil, pending.first?.id == id else { return false }
    onScreen = pending.removeFirst()
    return true
  }

  /// The alert on screen was closed. Returns it, or nil if it was not on screen.
  @discardableResult
  mutating func markClosed(_ id: UUID) -> Item? {
    guard let item = onScreen, item.id == id else { return nil }
    onScreen = nil
    return item
  }

  /// A new invitation or session: alerts about an earlier one are no longer relevant.
  mutating func dropPending() { pending.removeAll() }
}

/// Whether the listener cover is on screen, from its content's `onAppear` until the cover's
/// `onDismiss`. A listener's ending alert waits for it to be gone (guidance A.0).
@MainActor
final class ListenTogetherCoverTracker: ObservableObject {
  static let shared = ListenTogetherCoverTracker()

  @Published private(set) var isListenerCoverOnScreen = false

  func coverAppeared() { isListenerCoverOnScreen = true }
  func coverDismissed() { isListenerCoverOnScreen = false }
}

/// Requests for VoiceOver focus that come from outside the view that holds the element.
@MainActor
final class ListenTogetherFocusRequests {
  static let shared = ListenTogetherFocusRequests()

  /// Asks the mini player (when it is on screen) to take VoiceOver focus. A subject, not a counter,
  /// so a mini player that appears later is never focused by an old request.
  let miniPlayer = PassthroughSubject<Void, Never>()

  func requestMiniPlayerFocus() { miniPlayer.send(()) }
}

/// Routes every Listen Together message to its channels (guidance A.2): the alert queue (presented by
/// MainCoordinator), queued VoiceOver announcements, "Speak error messages" and, while the app is not
/// active, a local notification. Nothing else in Listen Together posts an alert-type message.
@MainActor
final class ListenTogetherMessageDelivery: ObservableObject {
  @Published private(set) var alerts = ListenTogetherAlertQueue()

  let announcer: ListenTogetherAnnouncer
  let speaker: ListenTogetherSpeaking
  let coverTracker: ListenTogetherCoverTracker
  let focusRequests: ListenTogetherFocusRequests
  private let context: @MainActor () -> ListenTogetherDeliveryContext
  /// Posts a local notification and returns true, only when permission was already given (never
  /// asks). Test seam.
  var postNotification: @MainActor (_ title: String, _ body: String) async -> Bool = { title, body in
    await ListenTogetherMessageDelivery.postNotificationIfAllowed(title: title, body: body)
  }
  /// Runs `action` after `delay`. Test seam.
  var schedule: @MainActor (Duration, @escaping @MainActor () -> Void) -> Void = { delay, action in
    Task { @MainActor in
      try? await Task.sleep(for: delay)
      action()
    }
  }
  private var closeActions: [UUID: @MainActor () -> Void] = [:]
  private var coverWaits = Set<AnyCancellable>()

  /// After the listener cover has gone: VoiceOver focus first, then the queued sentence, so moving
  /// focus can't cut the sentence off (leave guidance, "After leaving"; a11y M4: 500 ms gap).
  static let afterCoverFocusDelay: Duration = .milliseconds(500)
  static let afterCoverAnnouncementDelay: Duration = .milliseconds(500)
  /// The longest a message waits for the listener cover to report that it has gone (fix round 1, I2).
  /// Past it the cover is taken as gone; if it is in fact still up, the alert is shown over it.
  static let coverWaitLimit: Duration = .seconds(2)
  /// True after `coverWaitLimit` passed without the cover reporting its dismissal. MainCoordinator then
  /// closes a cover that is still up once the alert's OK is chosen. Logged.
  private(set) var coverWaitTimedOut = false
  /// When the oldest item waiting for the cover was queued (for the check on becoming active).
  private var coverWaitStartedAt: Date?
  /// Test seam.
  var now: () -> Date = Date.init

  init(
    announcer: ListenTogetherAnnouncer,
    speaker: ListenTogetherSpeaking,
    coverTracker: ListenTogetherCoverTracker,
    focusRequests: ListenTogetherFocusRequests,
    context: @escaping @MainActor () -> ListenTogetherDeliveryContext
  ) {
    self.announcer = announcer
    self.speaker = speaker
    self.coverTracker = coverTracker
    self.focusRequests = focusRequests
    self.context = context
  }

  nonisolated static func plan(
    for message: ListenTogetherUserMessage, context: ListenTogetherDeliveryContext
  ) -> ListenTogetherDeliveryPlan {
    var plan = ListenTogetherDeliveryPlan()
    switch message.kind {
    case .alert:
      if !context.isAway {
        plan.showsAlert = true
        plan.speaksWithAlert = message.speaks
      } else {
        // A.0: no announcement from the background (unreliable, and the later alert would repeat it).
        plan.notifiesOrWaits = true
        plan.speaksNow = message.speaks
        // Unlocked and VoiceOver off: the notification is a short edge banner (outside a Zoom
        // viewport), so the alert also waits for the return. Locked or VoiceOver: the notification is
        // read on the lock screen and is the one message.
        plan.keepsAlertAfterNotification = !context.isLocked && !context.isVoiceOverRunning
      }
    case .status:
      plan.announces = true
      plan.speaksNow = message.speaks
    case .announcement:
      plan.announces = true
    case .spokenOnly:
      plan.speaksNow = message.speaks
    }
    return plan
  }

  /// Shows, announces or speaks `message` as its plan says. `onClose` runs once the alert has been
  /// closed (or the notification posted instead).
  func deliver(_ message: ListenTogetherUserMessage, onClose: (@MainActor () -> Void)? = nil) {
    let plan = Self.plan(for: message, context: context())
    if plan.announces { announcer.announce(message.text) }
    if plan.speaksNow { speaker.speak(message.text, key: message.key) }
    if plan.showsAlert {
      enqueue(message, isSpoken: false, onClose: onClose)
    } else if plan.notifiesOrWaits {
      Task { @MainActor [weak self] in
        guard let self else { return }
        let posted = await self.postNotification("listen_together_title".localized, message.text)
        if posted, !plan.keepsAlertAfterNotification {
          // The notification is the one message: no alert later (A.0).
          onClose?()
        } else {
          self.enqueue(message, isSpoken: plan.speaksNow, onClose: onClose)
        }
      }
    } else {
      onClose?()
    }
  }

  private func enqueue(_ message: ListenTogetherUserMessage, isSpoken: Bool, onClose: (@MainActor () -> Void)?) {
    let item = ListenTogetherAlertQueue.Item(id: UUID(), message: message, isSpoken: isSpoken)
    var queue = alerts
    let before = Set(queue.pending.map(\.id))
    queue.enqueue(item)
    let after = Set(queue.pending.map(\.id))
    // Replaced items close without being shown.
    for removed in before.subtracting(after) { closeActions.removeValue(forKey: removed)?() }
    if after.contains(item.id), let onClose { closeActions[item.id] = onClose }
    alerts = queue
    if message.waitsForListenerCover { startCoverWatchdog() }
  }

  /// I2: a listener's ending never waits for the cover for longer than `coverWaitLimit`.
  private func startCoverWatchdog() {
    guard coverTracker.isListenerCoverOnScreen else { return }
    if coverWaitStartedAt == nil { coverWaitStartedAt = now() }
    schedule(Self.coverWaitLimit) { [weak self] in self?.forceCoverGoneIfOverdue() }
  }

  /// Takes the cover as gone when an item has waited `coverWaitLimit` for it. Also called when the app
  /// becomes active (timers may not have run in the background). Returns true when it forced it.
  @discardableResult
  func forceCoverGoneIfOverdue() -> Bool {
    guard coverTracker.isListenerCoverOnScreen else {
      coverWaitStartedAt = nil
      return false
    }
    let waiting = alerts.pending.contains { $0.message.waitsForListenerCover } || !coverWaits.isEmpty
    guard waiting, let started = coverWaitStartedAt,
      now().timeIntervalSince(started) >= Double(Self.coverWaitLimit.components.seconds)
    else { return false }
    SharePlaySessionService.logger.info("Listen Together: the listener cover did not report its dismissal; going on")
    coverWaitTimedOut = true
    coverWaitStartedAt = nil
    coverTracker.coverDismissed()
    return true
  }

  /// MainCoordinator handled a cover that had not reported its dismissal.
  func acknowledgeCoverWaitTimeout() { coverWaitTimedOut = false }

  /// MainCoordinator put the alert on screen: it is spoken now (unless it already was).
  func alertPresented(_ id: UUID) {
    guard alerts.markPresented(id), let item = alerts.onScreen else { return }
    if Self.plan(for: item.message, context: .init()).speaksWithAlert, !item.isSpoken {
      speaker.speak(item.message.text, key: item.message.key)
    }
  }

  /// The alert on screen was closed (OK, the two-finger scrub, or taken down).
  func alertClosed(_ id: UUID) {
    guard alerts.markClosed(id) != nil else { return }
    closeActions.removeValue(forKey: id)?()
  }

  /// A new invitation or session: alerts still waiting about an earlier one are dropped.
  func dropPendingAlerts() {
    for item in alerts.pending { closeActions.removeValue(forKey: item.id)?() }
    alerts.dropPending()
  }

  /// Leave (guidance): after the listener cover has gone, focus the mini player (when it is on
  /// screen) and then say `announcement` once, queued.
  func afterListenerCoverGone(announce announcement: String) {
    whenListenerCoverGone { [weak self] in
      guard let self else { return }
      self.schedule(Self.afterCoverFocusDelay) { [weak self] in
        guard let self else { return }
        self.focusRequests.requestMiniPlayerFocus()
        self.schedule(Self.afterCoverAnnouncementDelay) { [weak self] in self?.announcer.announce(announcement) }
      }
    }
  }

  /// Runs `action` once the listener cover is no longer on screen (at once when it isn't).
  /// Never waits longer than `coverWaitLimit` (fix round 1, I2).
  func whenListenerCoverGone(_ action: @escaping @MainActor () -> Void) {
    guard coverTracker.isListenerCoverOnScreen else {
      action()
      return
    }
    let once = ListenTogetherOnce(action)
    var cancellable: AnyCancellable?
    cancellable = coverTracker.$isListenerCoverOnScreen
      .dropFirst()
      .first { !$0 }
      .sink { [weak self] _ in
        MainActor.assumeIsolated {
          if let cancellable { self?.coverWaits.remove(cancellable) }
          once.run()
        }
      }
    if let cancellable { coverWaits.insert(cancellable) }
    if coverWaitStartedAt == nil { coverWaitStartedAt = now() }
    schedule(Self.coverWaitLimit) { [weak self] in
      guard let self else { return }
      if let cancellable, self.coverWaits.contains(cancellable) {
        self.coverWaits.remove(cancellable)
        SharePlaySessionService.logger.info("Listen Together: the listener cover did not report its dismissal (leave)")
        once.run()
      }
      self.forceCoverGoneIfOverdue()
    }
  }

  /// Only with permission the user already gave; never prompts.
  static func postNotificationIfAllowed(title: String, body: String) async -> Bool {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    // Only a notification that is shown as an alert counts as seen (code M1): provisional and
    // ephemeral ones go quietly to Notification Center. BookPlayer has no willPresent delegate and never
    // asks for permission, so this path runs only for people who allowed notifications elsewhere, and
    // only in the background.
    guard settings.authorizationStatus == .authorized, settings.alertSetting == .enabled else { return false }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    let request = UNNotificationRequest(identifier: "listenTogether.message", content: content, trigger: nil)
    do {
      try await center.add(request)
      return true
    } catch {
      return false
    }
  }
}
