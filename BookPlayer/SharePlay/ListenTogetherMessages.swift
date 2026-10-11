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
    case .sharerEnded, .sharerLeft, .sharerCouldNotPrepare, .prepareFailed, .unavailable, .didntStart:
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
    case .sharerCouldNotPrepare, .prepareFailed: return "listen_together_prepare_failed".localized
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
    case .sharerEnded, .sharerLeft, .sharerCouldNotPrepare, .prepareFailed, .unavailable, .didntStart,
      .waitingForSharer, .retryingSend, .alertShownElsewhere:
      return true
    case .sharerBack, .waitingForBook:
      return false
    }
  }

  /// The session ended because of someone else, or could not run at all.
  var isEnding: Bool {
    switch self {
    case .sharerEnded, .sharerLeft, .sharerCouldNotPrepare, .prepareFailed: return true
    default: return false
    }
  }

  /// A listener's ending: shown only after the listener cover has left (guidance A.0).
  var waitsForListenerCover: Bool {
    switch self {
    case .sharerEnded, .sharerLeft, .sharerCouldNotPrepare: return true
    default: return false
    }
  }

  /// The one message for a session that ended for `reason`; nil when the end was the person's own
  /// action (their End or Leave) and is handled by the existing announcement.
  static func ending(for reason: ListenTogetherState.EndReason) -> ListenTogetherUserMessage? {
    switch reason {
    case .sharerEnded: return .sharerEnded
    case .sharerLeft: return .sharerLeft
    case .sharerCouldNotPrepare: return .sharerCouldNotPrepare
    case .prepareFailed: return .prepareFailed
    case .normal, .unavailable: return nil
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
  /// App not active: one local notification when permission was already given, else a pending alert.
  var notifiesOrWaits = false
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
  private let isAppActive: @MainActor () -> Bool
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
  /// focus can't cut the sentence off (leave guidance, "After leaving").
  static let afterCoverFocusDelay: Duration = .milliseconds(500)
  static let afterCoverAnnouncementDelay: Duration = .milliseconds(300)

  init(
    announcer: ListenTogetherAnnouncer,
    speaker: ListenTogetherSpeaking,
    coverTracker: ListenTogetherCoverTracker,
    focusRequests: ListenTogetherFocusRequests,
    isAppActive: @escaping @MainActor () -> Bool
  ) {
    self.announcer = announcer
    self.speaker = speaker
    self.coverTracker = coverTracker
    self.focusRequests = focusRequests
    self.isAppActive = isAppActive
  }

  nonisolated static func plan(for message: ListenTogetherUserMessage, isActive: Bool) -> ListenTogetherDeliveryPlan {
    var plan = ListenTogetherDeliveryPlan()
    switch message.kind {
    case .alert:
      if isActive {
        plan.showsAlert = true
        plan.speaksWithAlert = message.speaks
      } else {
        // A.0: no announcement from the background (unreliable, and the later alert would repeat it).
        plan.notifiesOrWaits = true
        plan.speaksNow = message.speaks
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
    let plan = Self.plan(for: message, isActive: isAppActive())
    if plan.announces { announcer.announce(message.text) }
    if plan.speaksNow { speaker.speak(message.text, key: message.key) }
    if plan.showsAlert {
      enqueue(message, isSpoken: false, onClose: onClose)
    } else if plan.notifiesOrWaits {
      Task { @MainActor [weak self] in
        guard let self else { return }
        if await self.postNotification("listen_together_title".localized, message.text) {
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
  }

  /// MainCoordinator put the alert on screen: it is spoken now (unless it already was).
  func alertPresented(_ id: UUID) {
    guard alerts.markPresented(id), let item = alerts.onScreen else { return }
    if Self.plan(for: item.message, isActive: true).speaksWithAlert, !item.isSpoken {
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
  func whenListenerCoverGone(_ action: @escaping @MainActor () -> Void) {
    guard coverTracker.isListenerCoverOnScreen else {
      action()
      return
    }
    var cancellable: AnyCancellable?
    cancellable = coverTracker.$isListenerCoverOnScreen
      .dropFirst()
      .first { !$0 }
      .sink { [weak self] _ in
        MainActor.assumeIsolated {
          if let cancellable { self?.coverWaits.remove(cancellable) }
          action()
        }
      }
    if let cancellable { coverWaits.insert(cancellable) }
  }

  /// Only with permission the user already gave; never prompts.
  static func postNotificationIfAllowed(title: String, body: String) async -> Bool {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral: break
    default: return false
    }
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
