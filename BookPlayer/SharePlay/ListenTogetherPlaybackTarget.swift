import Combine
import Foundation

enum LocalPlaybackEvent: Equatable {
  case played(at: TimeInterval, rate: Float)
  case paused(at: TimeInterval)
  case seeked(to: TimeInterval, from: TimeInterval)
  case rateChanged(Float)
  /// Sharer only: a group time was ignored because the group has not yet been seen at the sharer's
  /// place (start-position fix D). The group is asked to seek to `at`. Never a message to others.
  case reasserted(at: TimeInterval)
}

@MainActor
protocol ListenTogetherPlaybackTarget: AnyObject {
  var bookTime: TimeInterval { get }
  var isPlaying: Bool { get }
  var rate: Float { get }
  var localEvents: AnyPublisher<LocalPlaybackEvent, Never> { get }
  func isReady(at bookTime: TimeInterval) -> Bool
  func applyPlay(at bookTime: TimeInterval, rate: Float)
  func applyPause(at bookTime: TimeInterval)
  /// A buffering pause suspends local playback while the group still intends to play.
  func applyPause(at bookTime: TimeInterval, shouldBuffer: Bool)
  func applySeek(to bookTime: TimeInterval)
  /// Sets the speed without playing or reporting it (a speed change made elsewhere while paused).
  func applyRate(_ rate: Float)
  /// The book the group shares is playing here (the sharer may be playing another book).
  var isPlayingForGroup: Bool { get }
  /// This device's place may be asserted to the group (sharer only; never while another book plays).
  var canAssertPlace: Bool { get }
}

extension ListenTogetherPlaybackTarget {
  func applyPause(at bookTime: TimeInterval, shouldBuffer: Bool) { applyPause(at: bookTime) }
  var isPlayingForGroup: Bool { isPlaying }
  var canAssertPlace: Bool { true }
}
