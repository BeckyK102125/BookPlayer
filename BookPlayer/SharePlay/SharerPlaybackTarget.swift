import AVFoundation
import BookPlayerKit
import Combine
import Foundation

/// Drives the sharer's normal player through its protocol. PlayerManager itself is not modified.
@MainActor
final class SharerPlaybackTarget: ListenTogetherPlaybackTarget {
  private let playerManager: PlayerManagerProtocol
  private let subject = PassthroughSubject<LocalPlaybackEvent, Never>()
  private var disposeBag = Set<AnyCancellable>()
  private nonisolated(unsafe) var seekTimer: Timer?

  /// State we just applied for a remote command; matching publisher output is our own echo.
  private var expectedIsPlaying: Bool?
  private var expectedRate: Float?
  private var lastSample: (time: TimeInterval, date: Date)?

  var localEvents: AnyPublisher<LocalPlaybackEvent, Never> { subject.eraseToAnyPublisher() }
  var bookTime: TimeInterval { playerManager.currentItem?.currentTime ?? 0 }
  var isPlaying: Bool { playerManager.isPlaying }
  var rate: Float { playerManager.currentSpeed }

  init(playerManager: PlayerManagerProtocol, seekCheckInterval: TimeInterval = 0.5) {
    self.playerManager = playerManager

    playerManager.isPlayingPublisher()
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] playing in self?.handleIsPlaying(playing) }
      .store(in: &disposeBag)

    playerManager.currentSpeedPublisher()
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] speed in self?.handleSpeed(speed) }
      .store(in: &disposeBag)

    seekTimer = Timer.scheduledTimer(withTimeInterval: seekCheckInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkForSeek(now: Date()) }
    }

    // Upstream PlayerManager keeps playing when headphones disconnect. During a session that would
    // leave everyone else listening while this phone plays out loud, so pause (reported as local).
    NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
          .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        MainActor.assumeIsolated {
          if reason == .oldDeviceUnavailable, self?.isPlaying == true { self?.playerManager.pause() }
        }
      }
      .store(in: &disposeBag)
  }

  deinit { seekTimer?.invalidate() }

  func isReady(at bookTime: TimeInterval) -> Bool { true }   // the sharer has the whole book

  func applyPlay(at bookTime: TimeInterval, rate: Float) {
    if abs(rate - playerManager.currentSpeed) > 0.001 {
      expectedRate = rate
      playerManager.setSpeed(rate)
    }
    if abs(bookTime - self.bookTime) > 0.5 {
      playerManager.jumpTo(bookTime, recordBookmark: false)
    }
    lastSample = (bookTime, Date())
    expectedIsPlaying = true
    playerManager.play()
  }

  func applyPause(at bookTime: TimeInterval) {
    expectedIsPlaying = false
    playerManager.pause()
    if abs(bookTime - self.bookTime) > 0.5 {
      playerManager.jumpTo(bookTime, recordBookmark: false)
    }
    lastSample = (bookTime, Date())
  }

  func applySeek(to bookTime: TimeInterval) {
    playerManager.jumpTo(bookTime, recordBookmark: false)
    lastSample = (bookTime, Date())
  }

  private func handleIsPlaying(_ playing: Bool) {
    if expectedIsPlaying == playing {
      expectedIsPlaying = nil
      return
    }
    expectedIsPlaying = nil
    lastSample = (bookTime, Date())
    subject.send(playing ? .played(at: bookTime, rate: rate) : .paused(at: bookTime))
  }

  private func handleSpeed(_ speed: Float) {
    if let expected = expectedRate, abs(expected - speed) < 0.001 {
      expectedRate = nil
      return
    }
    subject.send(.rateChanged(speed))
  }

  /// PlayerManager has no seek publisher, so compare where we are with where we should be.
  func checkForSeek(now: Date) {
    let current = bookTime
    defer { lastSample = (current, now) }
    guard let last = lastSample else { return }
    let elapsed = now.timeIntervalSince(last.date)
    let expected = last.time + (isPlaying ? elapsed * Double(rate) : 0)
    if abs(current - expected) > 2 {
      subject.send(.seeked(to: current, from: last.time))
    }
  }
}
