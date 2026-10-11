import Combine
import Foundation
import MediaPlayer
import UIKit

/// What the lock screen, Control Center and AirPods surfaces show during a listener session.
/// Book-level times only: the position control, the 30 second skips and the change-position command
/// all work on the whole book, not the chapter.
struct ListenTogetherNowPlayingState: Equatable {
  var title: String
  var author: String
  var chapters: [SharedChapter]
  var duration: TimeInterval
  var bookTime: TimeInterval
  var rate: Float
  var isPlaying: Bool
  var isWaitingForPiece: Bool
  /// The listener's place in the book is not known yet: no elapsed time and no chapter (a11y I2).
  var isPlaceUnknown = false

  /// `isPlaying` can stay set while the group is held for a missing piece: the time is not moving then.
  var isActuallyPlaying: Bool { isPlaying && !isWaitingForPiece }

  var chapterIndex: Int? {
    guard !isPlaceUnknown else { return nil }
    return chapters.firstIndex { bookTime >= $0.start && bookTime < $0.end }
  }

  init(
    title: String, author: String, chapters: [SharedChapter], duration: TimeInterval,
    bookTime: TimeInterval, rate: Float, isPlaying: Bool, isWaitingForPiece: Bool
  ) {
    self.title = title
    self.author = author
    self.chapters = chapters
    self.duration = duration
    self.bookTime = bookTime
    self.rate = rate
    self.isPlaying = isPlaying
    self.isWaitingForPiece = isWaitingForPiece
  }

  init(
    manifest: SharedBookManifest, bookTime: TimeInterval, rate: Float, isPlaying: Bool, isWaitingForPiece: Bool,
    isPlaceUnknown: Bool = false
  ) {
    self.init(
      title: manifest.title, author: manifest.author, chapters: manifest.chapters, duration: manifest.duration,
      bookTime: bookTime, rate: rate, isPlaying: isPlaying, isWaitingForPiece: isWaitingForPiece)
    self.isPlaceUnknown = isPlaceUnknown
  }
}

/// Pure builders for the Now Playing dictionary. Same shape as PlayerManager's (chapter, then book,
/// then author), so the lock screen reads the shared book the way it reads the user's own.
enum ListenTogetherNowPlaying {
  /// While playing, the info is refreshed at most this often (besides real changes), to correct drift.
  /// Not every tick: that makes VoiceOver re-read the lock-screen position control.
  static let refreshInterval: TimeInterval = 15

  static func info(for state: ListenTogetherNowPlayingState) -> [String: Any] {
    var info: [String: Any] = [:]
    let chapter = state.chapterIndex.map { state.chapters[$0] }
    if let chapter, !chapter.title.isEmpty, chapter.title != state.title {
      info[MPMediaItemPropertyTitle] = chapter.title
      info[MPMediaItemPropertyArtist] = state.title
    } else {
      info[MPMediaItemPropertyTitle] = state.title
      if !state.author.isEmpty { info[MPMediaItemPropertyArtist] = state.author }
    }
    if !state.author.isEmpty { info[MPMediaItemPropertyAlbumTitle] = state.author }
    if let index = state.chapterIndex {
      // Zero-based (MPNowPlayingInfoCenter.h).
      info[MPNowPlayingInfoPropertyChapterNumber] = index
      info[MPNowPlayingInfoPropertyChapterCount] = state.chapters.count
    }
    // While the place is unknown: no length and no elapsed time, so no scrubber at 0:00 (round 2, I-B).
    if !state.isPlaceUnknown {
      info[MPMediaItemPropertyPlaybackDuration] = state.duration
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.bookTime
    }
    info[MPNowPlayingInfoPropertyPlaybackRate] = state.isActuallyPlaying ? Double(state.rate) : 0.0
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
    info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
    return info
  }

  static func playbackState(for state: ListenTogetherNowPlayingState) -> MPNowPlayingPlaybackState {
    state.isActuallyPlaying ? .playing : .paused
  }

  /// Joined, the book details have not arrived: only the title from the invitation, paused.
  static func gettingBookInfo(title: String) -> [String: Any] {
    [
      MPMediaItemPropertyTitle: title,
      MPNowPlayingInfoPropertyPlaybackRate: 0.0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]
  }

  /// Whether `current` must be published, given what was last published (`previous`, at `publishedAt`).
  /// The system extrapolates elapsed time from the rate, so only real changes need publishing: play or
  /// pause (including a wait for a piece starting or ending), speed, chapter, a jump in position, and a
  /// modest refresh while playing.
  static func shouldPublish(
    _ current: ListenTogetherNowPlayingState,
    previous: ListenTogetherNowPlayingState?,
    publishedAt: Date?,
    now: Date
  ) -> Bool {
    guard let previous, let publishedAt else { return true }
    if current.isActuallyPlaying != previous.isActuallyPlaying || current.rate != previous.rate
      || current.chapterIndex != previous.chapterIndex || current.title != previous.title
      || current.duration != previous.duration
    {
      return true
    }
    let elapsed = max(0, now.timeIntervalSince(publishedAt))
    guard current.isActuallyPlaying else {
      // Paused: the time only moves on a seek or when a pause settles on the real position.
      return abs(current.bookTime - previous.bookTime) > 0.01
    }
    if elapsed >= refreshInterval { return true }
    let expected = previous.bookTime + Double(previous.rate) * elapsed
    return abs(current.bookTime - expected) > 1.5
  }
}

/// Where Now Playing info goes. Seam for tests; the app uses `SystemNowPlayingSink`.
@MainActor
protocol ListenTogetherNowPlayingSink: AnyObject {
  func publish(_ info: [String: Any]?, playbackState: MPNowPlayingPlaybackState)
}

@MainActor
final class SystemNowPlayingSink: ListenTogetherNowPlayingSink {
  func publish(_ info: [String: Any]?, playbackState: MPNowPlayingPlaybackState) {
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = info
    center.playbackState = playbackState
  }
}

/// Publishes the shared book's Now Playing info while this device is a listener.
@MainActor
final class ListenTogetherNowPlayingPublisher {
  private let sink: ListenTogetherNowPlayingSink
  private let now: () -> Date
  private var listenerBag = Set<AnyCancellable>()
  private var activeObserver: AnyCancellable?
  private var lastState: ListenTogetherNowPlayingState?
  private var lastPublishedAt: Date?
  private var gettingBookTitle: String?
  private weak var listener: ListenerPlayer?
  private(set) var isActive = false

  init(sink: ListenTogetherNowPlayingSink, now: @escaping () -> Date = Date.init) {
    self.sink = sink
    self.now = now
  }

  /// Starts publishing. Before the book details arrive the invitation's title is shown, paused.
  func start(gettingBookTitle title: String?) {
    isActive = true
    gettingBookTitle = title
    // PlayerManager can rewrite its own (paused) book's info, e.g. around foregrounding.
    activeObserver = NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in
        MainActor.assumeIsolated { self?.republish() }
      }
    if lastState == nil, let title { sink.publish(ListenTogetherNowPlaying.gettingBookInfo(title: title), playbackState: .paused) }
  }

  /// Follows `listener` (nil stops following, e.g. during tear-down).
  func observe(_ listener: ListenerPlayer?) {
    listenerBag.removeAll()
    self.listener = listener
    guard let listener, isActive else { return }
    let manifest = listener.manifest
    // The published values, not the properties: @Published emits before the property is stored.
    Publishers.CombineLatest4(listener.$bookTime, listener.$isPlaying, listener.$rate, listener.$isWaitingForPiece)
      .combineLatest(listener.$isJoiningGroup)
      .sink { [weak self] values, isFindingPlace in
        let (bookTime, isPlaying, rate, isWaiting) = values
        MainActor.assumeIsolated {
          self?.update(ListenTogetherNowPlayingState(
            manifest: manifest, bookTime: bookTime, rate: rate, isPlaying: isPlaying, isWaitingForPiece: isWaiting,
            isPlaceUnknown: isFindingPlace))
        }
      }
      .store(in: &listenerBag)
  }

  /// Stops publishing. The caller hands Now Playing back to the user's own book.
  func stop() {
    isActive = false
    listenerBag.removeAll()
    activeObserver = nil
    listener = nil
    lastState = nil
    lastPublishedAt = nil
    gettingBookTitle = nil
  }

  func update(_ state: ListenTogetherNowPlayingState) {
    guard isActive else { return }
    let date = now()
    guard ListenTogetherNowPlaying.shouldPublish(state, previous: lastState, publishedAt: lastPublishedAt, now: date)
    else { return }
    publish(state, at: date)
  }

  /// Publishes again whatever is current, whether or not it changed. Internal for tests.
  func republish() {
    guard isActive else { return }
    if let listener {
      // Fresh values: the system extrapolates elapsed time from the moment of publishing.
      publish(
        ListenTogetherNowPlayingState(
          manifest: listener.manifest, bookTime: listener.bookTime, rate: listener.rate,
          isPlaying: listener.isPlaying, isWaitingForPiece: listener.isWaitingForPiece,
          isPlaceUnknown: listener.isJoiningGroup),
        at: now())
    } else if let gettingBookTitle {
      sink.publish(ListenTogetherNowPlaying.gettingBookInfo(title: gettingBookTitle), playbackState: .paused)
    }
  }

  private func publish(_ state: ListenTogetherNowPlayingState, at date: Date) {
    lastState = state
    lastPublishedAt = date
    sink.publish(ListenTogetherNowPlaying.info(for: state), playbackState: ListenTogetherNowPlaying.playbackState(for: state))
  }
}
