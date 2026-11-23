//
//  SharePlaySessionService+SleepTimer.swift
//  BookPlayer
//
//  SR7-07: the sleep timer while this phone listens to someone else's share.
//

import Combine
import Foundation

extension SharePlaySessionService {
  /// While a listener player exists, the shared book plays through it, not PlayerManager. The timer
  /// then belongs to the session: when it runs out, the group pauses, as the listener's own Pause
  /// button does (Becky, November 18: "It should stop the share"). PlayerManager leaves its own paused
  /// book alone, so it no longer deactivates the audio session under the listener's audio.
  func listenerChangedForSleepTimer() {
    let listens = listener != nil
    playerManager.sleepTimerBelongsToListenTogether = listens
    guard listens else {
      sleepTimerSubscription = nil
      return
    }
    guard sleepTimerSubscription == nil else { return }
    sleepTimerSubscription = sleepTimerEnded
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.sleepTimerRanOut() }
  }

  func sleepTimerRanOut() {
    guard let listener else { return }
    Self.logger.info("Listen Together: the sleep timer ran out; pausing the group")
    listener.userPause()
  }
}
