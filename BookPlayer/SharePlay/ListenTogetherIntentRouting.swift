import BookPlayerKit
import Foundation

/// Siri and Shortcuts during a Listen Together session (fork audit A17). The intents act on the
/// normal player; during a listener session that is the user's own paused book, which must never be
/// moved or bookmarked by them. So:
/// - Listener: Pause and the skips act on the shared book, for the group (like the lock screen);
///   a bookmark is refused (there is no book of the user's own playing); starting a book leaves Listen
///   Together first ("You left Listen Together. Playing <title>."), then plays it (Becky's Siri ruling).
/// - Sharer: their book is the shared one, so Pause, skips, bookmarks and resuming it work as usual;
///   starting another book is refused.
/// Outside a session nothing changes.
@MainActor
enum ListenTogetherIntentRouting {
  /// Set by MainCoordinator. Nil (extensions, tests that don't set it): no session.
  static weak var service: SharePlaySessionService?

  enum Command: Equatable {
    case pause
    case skip(seconds: TimeInterval)
    case createBookmark
    /// A book is about to start (`relativePath`, `title` for the announcement).
    case startBook(relativePath: String?, title: String?)
  }

  enum Outcome: Equatable {
    /// Carry on as usual (no session, the sharer's own book, or the listener has left first).
    case proceed
    /// Done for the shared book; the intent must not touch the normal player.
    case handled
    /// Not done; the sentence is what Siri says.
    case refused(String)
  }

  static func route(_ command: Command) -> Outcome { route(command, service: service) }

  static func route(_ command: Command, service: SharePlaySessionService?) -> Outcome {
    guard let service, service.isInSession else { return .proceed }
    if service.isListenerSession {
      switch command {
      case .pause:
        // The same rule as the lock screen's Pause (audit 2 M1).
        if let listener = service.listener {
          if listener.isWaitingForPiece, listener.refusesUserActions { listener.userTogglePlay() } else { listener.userPause() }
        }
        return .handled
      case .skip(let seconds):
        service.listener?.userSkip(by: seconds)
        return .handled
      case .createBookmark:
        return .refused("listen_together_intent_bookmark_unavailable".localized)
      case .startBook(_, let title):
        SharePlaySessionService.logger.info("Listen Together: Siri starts the listener's own book; leaving first")
        service.leaveForOwnBook(announcement: ListenTogetherAnnouncements.leftForOwnBook(title: title))
        return .proceed
      }
    }
    // Sharer.
    if case .startBook(let relativePath, _) = command, relativePath != service.sharingRelativePath {
      return .refused("listen_together_intent_sharer_refused".localized)
    }
    return .proceed
  }

  /// For an intent: true when it must stop here (handled); throws the sentence when refused.
  static func handle(_ command: Command) async throws -> Bool {
    switch route(command) {
    case .proceed: return false
    case .handled: return true
    case .refused(let text): throw text
    }
  }
}
