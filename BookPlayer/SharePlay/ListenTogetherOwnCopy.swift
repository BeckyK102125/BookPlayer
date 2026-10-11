import BookPlayerKit
import Foundation

// MARK: The sharer's setting

/// Settings → Playback → Listen Together, "When someone doesn't have the book". Per device
/// (`UserDefaults.standard`); read when a share starts, so a change applies to the next share.
enum ListenTogetherSharingMode: String, CaseIterable {
  /// A temporary copy is sent to people who don't have the book (the default in this fork).
  case sendCopy
  /// Only people who already have the book can join; nothing is sent.
  case ownersOnly

  static let defaultsKey = "listenTogetherWhenNoCopy"
  static let defaultMode: ListenTogetherSharingMode = .sendCopy

  static func current(in defaults: UserDefaults) -> ListenTogetherSharingMode {
    defaults.string(forKey: defaultsKey).flatMap(ListenTogetherSharingMode.init(rawValue:)) ?? defaultMode
  }

  /// The option's name in Settings.
  var title: String {
    switch self {
    case .sendCopy: return "settings_listen_together_send".localized
    case .ownersOnly: return "settings_listen_together_owners_only".localized
    }
  }

  /// The short spoken value of the Settings row.
  var shortValue: String {
    switch self {
    case .sendCopy: return "settings_listen_together_value_send".localized
    case .ownersOnly: return "settings_listen_together_value_owners_only".localized
    }
  }

  /// The sharer's one-time first-share note, which depends on the mode.
  var firstShareMessage: String {
    switch self {
    case .sendCopy: return "listen_together_first_share_message".localized
    case .ownersOnly: return "listen_together_first_share_message_owners_only".localized
    }
  }
}

// MARK: The listener's own copy

/// A book in the listener's own library that matches the shared one. Value types only: no
/// NSManagedObject leaves the library lookup.
struct ListenTogetherOwnCopy: Equatable {
  let relativePath: String
  /// The own audio files in book order, with their sizes when matched.
  let files: [SourceFile]
  let chapters: [SharedChapter]
  let duration: TimeInterval

  /// Re-checked at Join: every file is still there with the size it had when matched. Cheap
  /// (file attributes only), so it can run in the same main-actor turn as the join.
  func isStillAvailable(fileManager: FileManager = .default) -> Bool {
    !files.isEmpty && files.allSatisfy { file in
      guard let size = (try? fileManager.attributesOfItem(atPath: file.url.path))?[.size] as? Int64 else {
        return false
      }
      return size == file.byteSize
    }
  }

  /// The own files as pieces on the shared book timeline: piece i is own file i, placed where the
  /// sharer's file i starts and lasting as long as the sharer's file (they match within ±2 s), so
  /// the coordinator's book times mean the same position on every phone.
  static func pieces(ownFiles: [SourceFile], sharedFiles: [BookFingerprint.File]) -> [SharedPiece] {
    ownFiles.enumerated().map { index, file in
      let shared = sharedFiles.indices.contains(index) ? sharedFiles[index] : nil
      return SharedPiece(
        index: index,
        bookStart: shared?.bookStart ?? file.bookStart,
        duration: shared?.duration ?? file.duration,
        byteSize: file.byteSize)
    }
  }

  /// The listener's manifest for this session: the shared title and author, this copy's chapters,
  /// and this copy's files as pieces.
  func manifest(shareID: UUID, title: String, author: String, shared: BookFingerprint?) -> SharedBookManifest {
    SharedBookManifest(
      shareID: shareID, title: title, author: author, duration: shared?.duration ?? duration,
      chapters: chapters, pieces: Self.pieces(ownFiles: files, sharedFiles: shared?.files ?? []),
      fingerprint: shared)
  }
}

/// Finds the listener's own copy of a shared book. Test seam.
@MainActor
protocol ListenTogetherOwnCopyFinding: AnyObject {
  func findOwnCopy(matching fingerprint: BookFingerprint) async -> ListenTogetherOwnCopy?
}

/// Looks for the shared book in the library. Reads only: nothing in the library is changed.
/// CoreData is read on the main context through LibraryService and PlaybackService, which hand back
/// `SimpleLibraryItem` / `PlayableItem` snapshots; only the 64 KB sample hash runs off the main actor.
@MainActor
final class LibraryOwnCopyFinder: ListenTogetherOwnCopyFinding, BPLogger {
  private let libraryService: LibraryServiceProtocol
  private let playbackService: PlaybackServiceProtocol

  init(libraryService: LibraryServiceProtocol, playbackService: PlaybackServiceProtocol) {
    self.libraryService = libraryService
    self.playbackService = playbackService
  }

  func findOwnCopy(matching fingerprint: BookFingerprint) async -> ListenTogetherOwnCopy? {
    // Books and bound folders, most recently played first. Streamed books (no local file) never match.
    let items = (libraryService.searchAllBooks(query: nil, limit: nil, offset: nil) ?? [])
      .filter { abs($0.duration - fingerprint.duration) <= BookFingerprintMatcher.durationTolerance }
    var candidates: [(fingerprint: BookFingerprint, lastPlayed: Date?, value: ListenTogetherOwnCopy)] = []
    for item in items {
      guard let candidate = Self.candidate(for: item, playbackService: playbackService),
        BookFingerprintMatcher.layoutMatches(shared: fingerprint, candidate: candidate.fingerprint)
      else { continue }
      // Hash only books whose layout already matches (usually none or one).
      let hash = await BookFingerprint.sampleHashOffMain(of: candidate.copy.files[0].url)
      let full = BookFingerprint(
        title: candidate.fingerprint.title, author: candidate.fingerprint.author,
        duration: candidate.fingerprint.duration,
        files: candidate.fingerprint.files, sampleHash: hash)
      candidates.append((full, item.lastPlayDate, candidate.copy))
    }
    return BookFingerprintMatcher.bestMatch(shared: fingerprint, candidates: candidates)
  }

  /// The candidate's layout (no hash yet) and own-copy details, or nil when it has no local files.
  static func candidate(
    for item: SimpleLibraryItem, playbackService: PlaybackServiceProtocol
  ) -> (fingerprint: BookFingerprint, copy: ListenTogetherOwnCopy)? {
    guard item.remoteURL == nil,
      let playable = try? playbackService.getPlayableItem(from: item),
      BookSplitter.isShareable(playable),
      let files = try? BookSplitter().sourceFiles(for: playable), !files.isEmpty
    else { return nil }
    let chapters = playable.chapters.sorted { $0.start < $1.start }.map {
      SharedChapter(title: $0.title, start: $0.start, duration: $0.duration)
    }
    let copy = ListenTogetherOwnCopy(
      relativePath: item.relativePath, files: files, chapters: chapters, duration: playable.duration)
    let fingerprint = BookFingerprint(
      title: playable.title, author: playable.author, duration: playable.duration, sourceFiles: files,
      sampleHash: nil)
    return (fingerprint, copy)
  }
}

// MARK: The invitation

/// What a listener is offered for an incoming share.
enum ListenTogetherInvitationKind: Equatable {
  /// The listener has the book: the invitation says so, and Join plays their copy (case A).
  case ownCopy
  /// No copy, the sharer sends one: today's invitation (case B).
  case sendCopy
  /// No copy and the sharer listens only with owners: no invitation, the "You need your own copy"
  /// alert, and the invitation is declined (case C).
  case needsOwnCopy

  static func decide(hasOwnCopy: Bool, ownersOnly: Bool) -> ListenTogetherInvitationKind {
    if hasOwnCopy { return .ownCopy }
    return ownersOnly ? .needsOwnCopy : .sendCopy
  }
}

/// Shown when the listener can't join an owners-only share: a single-button alert.
struct ListenTogetherNeedsCopyNotice: Equatable, Identifiable {
  enum Cause: Equatable {
    /// No matching book in the library.
    case notFound
    /// The match found for the invitation could not be used at Join (moved or deleted meanwhile).
    case copyUnusable
  }

  let id = UUID()
  let bookTitle: String
  let cause: Cause

  var title: String {
    switch cause {
    case .notFound: return "listen_together_need_copy_title".localized
    case .copyUnusable: return "listen_together_copy_unusable_title".localized
    }
  }

  var message: String {
    switch cause {
    case .notFound:
      return String.localizedStringWithFormat("listen_together_need_copy_message".localized, bookTitle)
    case .copyUnusable:
      return String.localizedStringWithFormat("listen_together_copy_unusable_message".localized, bookTitle)
    }
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.bookTitle == rhs.bookTitle && lhs.cause == rhs.cause
  }
}
