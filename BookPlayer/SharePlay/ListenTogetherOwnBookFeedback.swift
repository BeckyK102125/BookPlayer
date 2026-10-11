import Foundation
import UserNotifications

/// What the user hears around their own book during a listener session (R38, R39).
/// - Refused (the question could not be shown: locked, background, Siri, CarPlay with the phone
///   locked): a queued announcement, plus a local notification when notification permission was
///   already granted. BookPlayer never asks for that permission here.
/// - After Leave: the player that opens next puts VoiceOver on the book's title.
@MainActor
final class ListenTogetherOwnBookFeedback {
  static let shared = ListenTogetherOwnBookFeedback()

  /// At most one notification per 30 seconds.
  static let notificationInterval: TimeInterval = 30
  /// A focus request older than this is stale (the player was never opened).
  static let titleFocusLifetime: TimeInterval = 10

  var now: () -> Date = Date.init
  /// Test seam: posts the notification (when permission allows).
  var postNotification: @MainActor () -> Void = { Task { await ListenTogetherOwnBookFeedback.postNotificationIfAllowed() } }
  private var notificationLimiter = ListenTogetherRepeatLimiter(interval: notificationInterval)
  private var titleFocusRequestedAt: Date?

  func refused(announcer: ListenTogetherAnnouncer) {
    announcer.announce("listen_together_own_book_blocked".localized)
    if notificationLimiter.allows(at: now()) { postNotification() }
  }

  func requestPlayerTitleFocus() { titleFocusRequestedAt = now() }

  /// True once, for a request made in the last few seconds.
  func consumePlayerTitleFocusRequest() -> Bool {
    defer { titleFocusRequestedAt = nil }
    guard let requested = titleFocusRequestedAt else { return false }
    return now().timeIntervalSince(requested) <= Self.titleFocusLifetime
  }

  /// Only with permission the user already gave; never prompts.
  static func postNotificationIfAllowed() async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral: break
    default: return
    }
    let content = UNMutableNotificationContent()
    content.title = "listen_together_own_book_blocked_notification_title".localized
    content.body = "listen_together_own_book_blocked_notification_body".localized
    let request = UNNotificationRequest(
      identifier: "listenTogether.ownBookBlocked", content: content, trigger: nil)
    try? await center.add(request)
  }
}
