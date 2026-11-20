//
//  PlayerManagerProtocol.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 3/10/24.
//  Copyright © 2024 BookPlayer LLC. All rights reserved.
//

import Combine
import Foundation

/// Who asked for playback. Only a play the user asked for arms the remembered sleep timer
public enum PlayOrigin: Equatable {
  case user
  case system
  /// A Listen Together group command on the sharer's phone (SR7-09). Like `.system` it never arms the
  /// remembered sleep timer or restarts a finished book, and it also skips Smart Rewind, whose backward
  /// seek the whole group would follow.
  case group
}

/// Whether the player should be playing once its item can, and who asked for it
public enum PlayIntent: Equatable {
  case idle
  case wantsToPlay(PlayOrigin)
}

/// sourcery: AutoMockable
@MainActor
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

  /// Loads `item`, and plays it once it's ready when `intent` wants to
  func load(_ item: PlayableItem, intent: PlayIntent)
  func awaitCurrentLoad() async
  func hasLoadedBook() -> Bool

  func playPreviousItem()
  func playNextItem(autoPlayed: Bool, shouldAutoplay: Bool)
  /// A play the user asked for
  func play()
  func play(origin: PlayOrigin)
  /// SR7-09: `play(origin: .group)`, for a Listen Together group command on the sharer's phone. Unlike
  /// `play()`, there's no Smart Rewind, whose seek would move the whole group back, and no automatic
  /// sleep timer.
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
  func reloadCurrentItem()
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
