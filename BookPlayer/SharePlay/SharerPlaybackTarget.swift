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
  /// Expectations older than this are stale (the player never reacted) and must not swallow a real user action.
  private static let expectationLifetime: TimeInterval = 1.5
  private var expectedIsPlaying: (value: Bool, date: Date)?
  private var expectedRate: (value: Float, date: Date)?
  private var lastSample: (time: TimeInterval, date: Date, uuid: String?)?
  private let now: () -> Date

  var localEvents: AnyPublisher<LocalPlaybackEvent, Never> { subject.eraseToAnyPublisher() }
  var bookTime: TimeInterval { playerManager.currentItem?.currentTime ?? 0 }
  var isPlaying: Bool { playerManager.isPlaying }
  var rate: Float { playerManager.currentSpeed }

  init(
    playerManager: PlayerManagerProtocol,
    seekCheckInterval: TimeInterval = 0.5,
    now: @escaping () -> Date = Date.init
  ) {
    self.playerManager = playerManager
    self.now = now

    playerManager.isPlayingPublisher()
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] playing in self?.handleIsPlaying(playing) }
      .store(in: &disposeBag)

    playerManager.currentSpeedPublisher()
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] speed in self?.handleSpeed(speed) }
      .store(in: &disposeBag)

    seekTimer = Timer.scheduledTimer(withTimeInterval: seekCheckInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { if let self { self.checkForSeek(now: self.now()) } }
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

  private func sample(_ time: TimeInterval, at date: Date) {
    lastSample = (time, date, playerManager.currentItem?.uuid)
  }

  func applyPlay(at bookTime: TimeInterval, rate: Float) {
    if abs(rate - playerManager.currentSpeed) > 0.001 {
      expectedRate = (rate, now())
      playerManager.setSpeed(rate)
    }
    if abs(bookTime - self.bookTime) > 0.5 {
      playerManager.jumpTo(bookTime, recordBookmark: false)
    }
    sample(bookTime, at: now())
    // Only expect an echo if the state will actually change.
    expectedIsPlaying = playerManager.isPlaying ? nil : (true, now())
    playerManager.play()
  }

  func applyPause(at bookTime: TimeInterval) {
    expectedIsPlaying = playerManager.isPlaying ? (false, now()) : nil
    playerManager.pause()
    if abs(bookTime - self.bookTime) > 0.5 {
      playerManager.jumpTo(bookTime, recordBookmark: false)
    }
    sample(bookTime, at: now())
  }

  func applySeek(to bookTime: TimeInterval) {
    playerManager.jumpTo(bookTime, recordBookmark: false)
    sample(bookTime, at: now())
  }

  func applyRate(_ rate: Float) {
    guard abs(rate - playerManager.currentSpeed) > 0.001 else { return }
    expectedRate = (rate, now())
    playerManager.setSpeed(rate)
  }

  private func handleIsPlaying(_ playing: Bool) {
    let expected = expectedIsPlaying
    expectedIsPlaying = nil
    if let expected, expected.value == playing,
      now().timeIntervalSince(expected.date) <= Self.expectationLifetime
    {
      return
    }
    sample(bookTime, at: now())
    subject.send(playing ? .played(at: bookTime, rate: rate) : .paused(at: bookTime))
  }

  private func handleSpeed(_ speed: Float) {
    let expected = expectedRate
    expectedRate = nil
    if let expected, abs(expected.value - speed) < 0.001,
      now().timeIntervalSince(expected.date) <= Self.expectationLifetime
    {
      return
    }
    subject.send(.rateChanged(speed))
  }

  /// PlayerManager has no seek publisher, so compare where we are with where we should be.
  func checkForSeek(now: Date) {
    let current = bookTime
    let uuid = playerManager.currentItem?.uuid
    defer { lastSample = (current, now, uuid) }
    // A different (or no) book is a new baseline, never a seek.
    guard let last = lastSample, let uuid, last.uuid == uuid else { return }
    let elapsed = now.timeIntervalSince(last.date)
    let rate = Double(self.rate)
    let advance = isPlaying ? elapsed * rate : 0
    let threshold = max(2, 1.5 * rate)
    // A lagging clock (stall, slow start) is not a seek; only backward jumps or forward overshoots are.
    if current < last.time - 1 || current > last.time + advance + threshold {
      subject.send(.seeked(to: current, from: last.time))
    }
  }
}
