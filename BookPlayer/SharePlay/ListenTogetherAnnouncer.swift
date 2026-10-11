import UIKit

/// The text VoiceOver speaks for things other people do during Listen Together.
enum ListenTogetherAnnouncements {
  static func text(for action: RemoteAction) -> String {
    switch action {
    case .paused:
      return "listen_together_remote_paused".localized
    case .resumed:
      return "listen_together_remote_resumed".localized
    case .skipped(let seconds):
      let amount = VoiceOverService.secondsToMinutes(Double(abs(seconds)))
      let key = seconds >= 0 ? "listen_together_remote_skipped_forward" : "listen_together_remote_skipped_back"
      return String.localizedStringWithFormat(key.localized, amount)
    case .movedToChapter(let title):
      return String.localizedStringWithFormat("listen_together_remote_chapter".localized, title)
    case .speedChanged(let rate) where rate == 1:
      return "listen_together_remote_speed_normal".localized
    case .speedChanged(let rate):
      return String.localizedStringWithFormat(
        "listen_together_remote_speed".localized,
        rate.formatted(.number.precision(.fractionLength(0...2))))
    }
  }

  static func invitation(title: String, author: String) -> String {
    author.isEmpty
      ? String.localizedStringWithFormat("listen_together_invitation_announcement_no_author".localized, title)
      : String.localizedStringWithFormat("listen_together_invitation_announcement".localized, title, author)
  }

  static func joined() -> String { "listen_together_joined".localized }
  static func left() -> String { "listen_together_left".localized }
  static func ended() -> String { "listen_together_ended".localized }

  /// Said once after Leave on "Leave Listen Together to play this book?" (instead of "ended").
  static func leftForOwnBook(title: String?) -> String {
    guard let title, !title.isEmpty else { return "listen_together_left_for_own_book".localized }
    return String.localizedStringWithFormat("listen_together_left_for_own_book_playing".localized, title)
  }

  static func download(percent: Int) -> String {
    String.localizedStringWithFormat("listen_together_download_progress".localized, percent)
  }
}

/// Posts queued VoiceOver announcements, so they never cut off what VoiceOver is already saying.
/// Only for other people's actions and session events; never for the local user's own actions.
@MainActor
final class ListenTogetherAnnouncer {
  private let post: @MainActor (String) -> Void
  private var lastDownloadStep = 0

  init(post: @escaping @MainActor (String) -> Void = ListenTogetherAnnouncer.postQueued) {
    self.post = post
  }

  func announce(_ text: String) { post(text) }

  /// Announces download progress only at 25, 50, 75 and 100 percent, once each.
  func announceDownload(fraction: Double) {
    let step = min(Int((fraction * 4).rounded(.down)) * 25, 100)
    guard step > lastDownloadStep else { return }
    lastDownloadStep = step
    post(ListenTogetherAnnouncements.download(percent: step))
  }

  /// Starts download progress over for a new session.
  func resetDownloadProgress() { lastDownloadStep = 0 }

  static func postQueued(_ text: String) {
    let queued = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
    UIAccessibility.post(notification: .announcement, argument: queued)
  }
}

/// Lets a repeated message through at most once per `interval`, so repeated taps don't stack speech.
struct ListenTogetherRepeatLimiter {
  let interval: TimeInterval
  private var last: Date?

  init(interval: TimeInterval) { self.interval = interval }

  mutating func allows(at now: Date) -> Bool {
    if let last, now.timeIntervalSince(last) < interval { return false }
    last = now
    return true
  }
}
