import AVFoundation
import BookPlayerKit
import Combine
import Foundation

/// Drives the sharer's normal player through its protocol. PlayerManager itself is not modified.
///
/// Start-position fix D (build 4): `PlayerManager.jumpTo` always saves the new time as the book's
/// progress. So until every listener who joined has said it is in step at the sharer's place
/// (`.inStep`, fix round 1 C1: never a coordinator command, which can be the sharer's own echo), a group
/// time that differs is never applied with a jump: the sharer plays or pauses where it is and asks the
/// group to come to it (`.reasserted`, at most once per `reassertInterval`). Every join re-arms this
/// (`rearm()`). The shared book is the only one ever moved or played by the group.
@MainActor
final class SharerPlaybackTarget: ListenTogetherPlaybackTarget, BPLogger {
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
  /// The shared book's uuid; nil (tests) means whatever book the player holds.
  private let sharedItemUUID: String?
  /// The sharer's saved place in the shared book when the session started; the group starts here.
  let startPosition: TimeInterval?
  /// True once every listener who joined has reported `.inStep` at this device's place
  /// (`confirmGroup()`; the service decides). Until then, group times that differ are not applied
  /// (fix D). Always true without a start position.
  private(set) var isGroupEstablished: Bool
  /// The group has been confirmed at least once (the start position may be out of date since).
  private var hasEverBeenEstablished: Bool
  /// The place protected since the last `rearm()`: restored by the backstop if the session ends
  /// unconfirmed with the shared book moved back.
  private var protectedPosition: TimeInterval?
  /// The person moved their own place since the last arming (reported as a seek): never undone.
  private var didReportLocalSeek = false
  private var lastReassertAt: Date?
  /// A disagreement is answered with at most one re-assert per this many seconds (round 1, I1).
  static let reassertInterval: TimeInterval = 3

  var localEvents: AnyPublisher<LocalPlaybackEvent, Never> { subject.eraseToAnyPublisher() }
  /// The shared book's place: the player's while it holds that book, else where the share started
  /// (never 0, or another book's time, just because the player holds something else).
  var bookTime: TimeInterval {
    if holdsSharedBook, let current = playerManager.currentItem { return current.currentTime }
    return startPosition ?? 0
  }
  var isPlaying: Bool { playerManager.isPlaying }
  /// The shared book is playing here (not another book).
  var isPlayingForGroup: Bool { isPlaying && holdsSharedBook }
  /// The sharer's place may be asserted to the group: never while another book is loaded, and with
  /// no book loaded only before any confirmation (the start position is current until then).
  var canAssertPlace: Bool { !holdsOtherBook && (holdsSharedBook || !hasEverBeenEstablished) }
  /// How far a group time may be from this device's place and still count as "here" (round 1, I1):
  /// `bookTime` comes from PlayerManager's 1 s tick, so it lags by up to a second at the current speed.
  var placeTolerance: TimeInterval {
    let rate = Double(self.rate)
    return max(2, 1.5 * rate) + (isPlaying ? rate : 0)
  }
  func isAtOwnPlace(_ time: TimeInterval) -> Bool { abs(time - bookTime) <= placeTolerance }
  /// A listener's `.inStep` time was taken when its command arrived and then travelled as a message:
  /// while the shared book plays, up to 2 s more at the current speed is allowed for that delay. A
  /// listener says it once, so a report that misses would leave the protection on all session.
  func isInStepReportAtOwnPlace(_ time: TimeInterval) -> Bool {
    abs(time - bookTime) <= placeTolerance + (isPlayingForGroup ? 2 * Double(rate) : 0)
  }
  /// The player holds the shared book.
  var holdsSharedBook: Bool {
    guard let current = playerManager.currentItem else { return false }
    return sharedItemUUID == nil || current.uuid == sharedItemUUID
  }
  /// The player holds a book that is not the shared one: the group never plays or moves it.
  private var holdsOtherBook: Bool { playerManager.currentItem != nil && !holdsSharedBook }
  var rate: Float { playerManager.currentSpeed }

  /// `deliversOnMainQueue`: PlayerManager's playing publisher is fed from AVPlayer KVO, which is not
  /// promised to arrive on main (A-I1), so its values hop to the main queue (FIFO, so their order is
  /// kept) before this MainActor object touches them. Tests whose fake publishers already run on main
  /// may pass false to get the values synchronously.
  init(
    playerManager: PlayerManagerProtocol,
    sharedItemUUID: String? = nil,
    startPosition: TimeInterval? = nil,
    seekCheckInterval: TimeInterval = 0.5,
    now: @escaping () -> Date = Date.init,
    deliversOnMainQueue: Bool = true
  ) {
    self.playerManager = playerManager
    self.sharedItemUUID = sharedItemUUID
    self.startPosition = startPosition
    self.isGroupEstablished = startPosition == nil
    self.hasEverBeenEstablished = startPosition == nil
    self.protectedPosition = startPosition
    self.now = now

    Self.onMain(playerManager.isPlayingPublisher().removeDuplicates().dropFirst(), hop: deliversOnMainQueue)
      .sink { [weak self] playing in
        MainActor.assumeIsolated { self?.handleIsPlaying(playing) }
      }
      .store(in: &disposeBag)

    Self.onMain(playerManager.currentSpeedPublisher().removeDuplicates().dropFirst(), hop: deliversOnMainQueue)
      .sink { [weak self] speed in
        MainActor.assumeIsolated { self?.handleSpeed(speed) }
      }
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

  /// Values from `publisher`, delivered on the main queue when `hop` is true.
  private static func onMain<P: Publisher>(_ publisher: P, hop: Bool) -> AnyPublisher<P.Output, Never>
  where P.Failure == Never {
    hop ? publisher.receive(on: DispatchQueue.main).eraseToAnyPublisher() : publisher.eraseToAnyPublisher()
  }

  /// Stops the seek timer and every subscription. Called by the session's teardown, so nothing fires
  /// after the session even if something still holds this target (M4). The deinit stays as a backstop.
  func stop() {
    restoreStartPositionIfMoved()
    seekTimer?.invalidate()
    seekTimer = nil
    disposeBag.removeAll()
  }

  deinit { seekTimer?.invalidate() }

  func isReady(at bookTime: TimeInterval) -> Bool { true }   // the sharer has the whole book

  private func sample(_ time: TimeInterval, at date: Date) {
    lastSample = (time, date, playerManager.currentItem?.uuid)
  }

  /// Whether a group time may move this device. Before the group is established, only a time at this
  /// device's own place is accepted; it never establishes the group (only listeners' `.inStep` does).
  private func acceptsGroupTime(_ time: TimeInterval) -> Bool {
    guard !isGroupEstablished else { return true }
    guard isAtOwnPlace(time) else {
      Self.logger.info(
        "Listen Together: group time \(time, privacy: .public) ignored; the sharer is at \(self.bookTime, privacy: .public)")
      return false
    }
    return true
  }

  /// A joiner arrived: protect this place again until it reports `.inStep`.
  func rearm() {
    guard startPosition != nil else { return }
    isGroupEstablished = false
    if holdsSharedBook { protectedPosition = bookTime }
    didReportLocalSeek = false
    Self.logger.info("Listen Together: protecting the sharer's place \(self.bookTime, privacy: .public) for a joiner")
  }

  /// Every joiner is in step at this device's place.
  func confirmGroup() {
    guard !isGroupEstablished else { return }
    isGroupEstablished = true
    hasEverBeenEstablished = true
    Self.logger.info("Listen Together: every listener is at the sharer's place")
  }

  /// Whether a re-assert may go out now (it may be asserted, and none went out in the last
  /// `reassertInterval`). Records the time when it returns true.
  func allowsReassert() -> Bool {
    guard canAssertPlace else { return false }
    let date = now()
    if let last = lastReassertAt, date.timeIntervalSince(last) < Self.reassertInterval {
      Self.logger.info("Listen Together: re-assert skipped (one went out \(date.timeIntervalSince(last), privacy: .public)s ago)")
      return false
    }
    lastReassertAt = date
    return true
  }

  private func reassertIfAllowed() {
    if allowsReassert() { subject.send(.reasserted(at: bookTime)) }
  }

  func applyPlay(at bookTime: TimeInterval, rate: Float) {
    if abs(rate - playerManager.currentSpeed) > 0.001 {
      expectedRate = (rate, now())
      playerManager.setSpeed(rate)
    }
    let accepted = acceptsGroupTime(bookTime)
    if accepted, holdsSharedBook, abs(bookTime - self.bookTime) > 0.5 {
      playerManager.jumpTo(bookTime, recordBookmark: false)
    }
    sample(accepted ? bookTime : self.bookTime, at: now())
    if !holdsOtherBook {
      // Only expect an echo if the state will actually change.
      expectedIsPlaying = playerManager.isPlaying ? nil : (true, now())
      playerManager.play()
    }
    if !accepted { reassertIfAllowed() }
  }

  func applyPause(at bookTime: TimeInterval) {
    expectedIsPlaying = playerManager.isPlaying ? (false, now()) : nil
    playerManager.pause()
    // A pause never establishes the group (its time is this device's own) and never jumps before then.
    if isGroupEstablished, holdsSharedBook, abs(bookTime - self.bookTime) > 0.5 {
      playerManager.jumpTo(bookTime, recordBookmark: false)
      sample(bookTime, at: now())
    } else {
      sample(self.bookTime, at: now())
    }
  }

  func applySeek(to bookTime: TimeInterval) {
    guard acceptsGroupTime(bookTime) else {
      sample(self.bookTime, at: now())
      reassertIfAllowed()
      return
    }
    // Already there (for example the echo of this device's own coordinated seek): no jump, which
    // would only save the same time again and make the player stutter.
    guard holdsSharedBook, abs(bookTime - self.bookTime) > 0.5 else { return }
    playerManager.jumpTo(bookTime, recordBookmark: false)
    sample(bookTime, at: now())
  }

  /// The backstop for fix D: the session ends while a joiner was not yet in step, yet the shared book
  /// is now earlier than the protected place (something outside the guard moved it). Its saved place is
  /// put back. Listening on from there, or the person's own seek, is never undone. Only while the
  /// shared book is loaded (Notes.md: a book switched away from is not checked).
  private func restoreStartPositionIfMoved() {
    guard !isGroupEstablished, !didReportLocalSeek, sharedItemUUID != nil, let protectedPosition, holdsSharedBook,
      let current = playerManager.currentItem,
      current.currentTime < protectedPosition - 2
    else { return }
    Self.logger.info(
      "Listen Together: restoring the sharer's place \(protectedPosition, privacy: .public) (was \(current.currentTime, privacy: .public))")
    playerManager.jumpTo(protectedPosition, recordBookmark: false)
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
      didReportLocalSeek = true
      subject.send(.seeked(to: current, from: last.time))
    }
  }
}
