//
//  PlayerManagerProtocol.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 3/10/24.
//  Copyright © 2024 BookPlayer LLC. All rights reserved.
//

#if os(watchOS)
  import BookPlayerWatchKit
#else
  import BookPlayerKit
#endif
import Combine
import Foundation
/// sourcery: AutoMockable
public protocol PlayerManagerProtocol: AnyObject {
  var currentItem: PlayableItem? { get set }
  var currentSpeed: Float { get set }
  var isPlaying: Bool { get }
  var syncProgressDelegate: PlaybackSyncProgressDelegate? { get set }
  /// SR7-07: true while this phone listens to someone else's Listen Together share, whose audio plays
  /// through the session's own player. The sleep timer then belongs to the session: PlayerManager
  /// doesn't fade, pause or bookmark its own (paused) book when the timer fires, and the session pauses
  /// the group instead, as the listener's Pause button does.
  var sleepTimerBelongsToListenTogether: Bool { get set }

  func load(_ item: PlayableItem, autoplay: Bool)
  func awaitCurrentLoad() async
  func hasLoadedBook() -> Bool

  func playPreviousItem()
  func playNextItem(autoPlayed: Bool, shouldAutoplay: Bool)
  func play()
  /// SR7-09: play for a Listen Together group command (the sharer's phone). Unlike `play()`, there's
  /// no Smart Rewind, whose seek would move the whole group back, and no automatic sleep timer.
  func playForGroup()
  func playPause()
  func pause()
  func stop()
  func rewind()
  func forward()
  func skipToNextChapter()
  func skipToPreviousChapter()
  func skip(_ interval: TimeInterval)
  /// Bypass checks on chapter limits
  func directSkip(_ interval: TimeInterval)
  func jumpTo(_ time: Double, recordBookmark: Bool)
  func jumpToChapter(_ chapter: PlayableChapter)
  /// Rebuild `currentItem` from storage (and re-bind the chapter subscription) so externally
  /// changed data — e.g. re-parsed chapters — takes effect. Preserves playback position.
  @MainActor func reloadCurrentItem()
  func markAsCompleted(_ flag: Bool)
  func setSpeed(_ newValue: Float)
  func setBoostVolume(_ newValue: Bool)

  func currentSpeedPublisher() -> AnyPublisher<Float, Never>
  func isPlayingPublisher() -> AnyPublisher<Bool, Never>
  func currentItemPublisher() -> AnyPublisher<PlayableItem?, Never>
}

/// Delegate that hooks into the playback sequence
public protocol PlaybackSyncProgressDelegate: AnyObject {
  func waitForSyncInProgress() async
}
