import AVFoundation
import BookPlayerKit
import Combine
import Foundation

/// The listener's own player. It plays received pieces on the shared "book time" timeline. The next
/// piece, once it has arrived, is queued behind the current one (`AVQueuePlayer`), so playback runs on
/// across piece boundaries without a gap (addendum 3, decision 4). Remote commands (`apply*`) are never
/// reported back; the user's own actions (`user*`) are.
@MainActor
final class ListenerPlayer: ObservableObject, ListenTogetherPlaybackTarget, BPLogger {
  @Published private(set) var bookTime: TimeInterval = 0
  @Published private(set) var isPlaying = false
  @Published private(set) var rate: Float = 1
  @Published private(set) var timeline: PieceTimeline
  let manifest: SharedBookManifest
  /// Asks the service to wait for a piece. Called at most once per missing piece per wait.
  var onNeedsPiece: ((Int) -> Void)?
  /// Play or pause was pressed while the group waits for this device's piece. Nothing is sent to the
  /// others (a pause there would stop everyone for no reason); the service says what is happening.
  var onToggleWhileWaiting: (() -> Void)?
  /// True while the group waits for the person sharing to come back (set by the service).
  var isHeldForSharer = false
  /// Play or pause pressed while `isHeldForSharer`: nothing happens; the service says why.
  var onToggleWhileHeldForSharer: (() -> Void)?
  /// True until the group's place is known here (the first play or seek command; set by the service).
  /// Meanwhile this player's timeline is "paused at 0", so play, pause, skips and speed would move the
  /// whole group there (the 0:00 start, build 3): they do nothing, and the service says "Finding the
  /// group's place". The position, chapter and lock-screen time are not shown meanwhile (a11y I2).
  @Published var isJoiningGroup = false
  /// A press now does nothing (the service says why): no "pressed" haptic for it (a11y M5).
  var refusesUserActions: Bool {
    isHeldForSharer || isJoiningGroup || (isWaitingForPiece && isHeldWhilePlaying)
  }
  /// A control was used while `isJoiningGroup`: nothing happened; the service says why.
  var onActionWhileJoining: (() -> Void)?
  /// The player is at an arrived piece after a load (a placement, seek, play or pause): a stall that
  /// is no longer needed can end (path 3).
  var onPositionReady: (() -> Void)?
  /// Decoder/seek readiness and system interruptions are separate from missing file transfers.
  var onBufferingNeeded: (() -> Void)?
  var onInterruptionBegan: (() -> Void)?
  var onInterruptionEnded: (() -> Void)?
  /// Shared book time and the actual source file; file durations can differ slightly between copies.
  var onProgressChanged: ((TimeInterval, Int) -> Void)?
  /// A received piece could not be played (its item failed): it was dropped and must come again.
  var onPieceFailed: ((Int) -> Void)?

  /// Internal (not private) only so tests can move the queue on.
  let player = AVQueuePlayer()
  private nonisolated(unsafe) var timeObserver: Any?
  private var loadedPieceIndex: Int?
  /// The piece queued behind the current one (it plays on by itself when the current one ends).
  private(set) var queuedPieceIndex: Int?
  /// Which piece each item in the queue plays, and its status observation (for the log).
  private var pieceIndexByItem: [ObjectIdentifier: Int] = [:]
  private var itemObservations: [ObjectIdentifier: AnyCancellable] = [:]
  /// The piece we are currently waiting for; cleared when it arrives or another piece loads.
  private var waitingPieceIndex: Int? {
    didSet { if isWaitingForPiece != (waitingPieceIndex != nil) { isWaitingForPiece = waitingPieceIndex != nil } }
  }
  /// True while playback is held for a piece that has not arrived. The lock screen shows paused then.
  @Published private(set) var isWaitingForPiece = false
  /// True when the current wait began while the group was playing (a play, a playing seek or the next
  /// piece missing), false when it began while paused.
  private var isHeldWhilePlaying = false
  private var sessionConfigured = false
  private var isStopped = false
  private var isAudioInterrupted = false
  private var requiresUserResume = false
  private var hasInterruptionHold = false
  private var wantsPlayback = false
  /// The coordinator paused for buffering; preserve intent for an explicit cancellation, but do
  /// not let local readiness alone resume playback while other participants are still waiting.
  private var awaitingGroupPlayback = false
  private var isBuffering = false
  private var pendingSeekOffset: TimeInterval?
  /// True from issuing a seek until its completion handler runs; periodic ticks in between are stale.
  private var isSeeking = false
  /// Test seam: overrides the player's item time when computing the real position.
  var itemTimeProvider: (() -> CMTime)?
  private var seekGeneration = 0
  private let subject = PassthroughSubject<LocalPlaybackEvent, Never>()
  private var disposeBag = Set<AnyCancellable>()

  /// Playback intent remains true during asynchronous preparation, unlike audible playback state.
  var isPlayingForGroup: Bool { wantsPlayback || awaitingGroupPlayback }

  var localEvents: AnyPublisher<LocalPlaybackEvent, Never> { subject.eraseToAnyPublisher() }

  init(manifest: SharedBookManifest) {
    self.manifest = manifest
    self.timeline = PieceTimeline(pieces: manifest.pieces)
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated {
        guard let self, !self.isStopped, !self.isSeeking, time.isNumeric,
          let item = self.player.currentItem,
          let index = self.pieceIndexByItem[ObjectIdentifier(item)],
          let piece = self.timeline.pieces.first(where: { $0.index == index })
        else { return }
        self.bookTime = piece.bookStart + time.seconds
        self.onProgressChanged?(self.bookTime, piece.index)
      }
    }
    NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        MainActor.assumeIsolated {
          guard let self, let item = note.object as? AVPlayerItem else { return }
          self.itemPlayedToEnd(item)
        }
      }
      .store(in: &disposeBag)
    NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
        MainActor.assumeIsolated {
          guard let self, let item = note.object as? AVPlayerItem,
            let index = self.pieceIndexByItem[ObjectIdentifier(item)]
          else { return }
          Self.logger.error(
            "Listen Together: piece \(index, privacy: .public) failed to play to its end: \(error?.domain ?? "", privacy: .public) \(error?.code ?? 0, privacy: .public)")
          self.itemFailed(item)
        }
      }
      .store(in: &disposeBag)
    // The queue moved on by itself (the current piece ended and the queued one took over).
    player.publisher(for: \.currentItem)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        MainActor.assumeIsolated { self?.queueAdvanced() }
      }
      .store(in: &disposeBag)
    NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
          .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        MainActor.assumeIsolated {
          guard let self, !self.isStopped, reason == .oldDeviceUnavailable else { return }
          Self.logger.info("Listen Together: listener audio route removed; requiring explicit Play")
          self.userPause(requiringUserResume: true)
        }
      }
      .store(in: &disposeBag)
    NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
          .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
        let options = AVAudioSession.InterruptionOptions(
          rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
        MainActor.assumeIsolated {
          guard let self, let type else { return }
          self.handleInterruption(type, shouldResume: options.contains(.shouldResume))
        }
      }
      .store(in: &disposeBag)
    player.publisher(for: \.timeControlStatus)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        MainActor.assumeIsolated { self?.playbackStateChanged() }
      }
      .store(in: &disposeBag)
  }

  deinit {
    if let timeObserver { player.removeTimeObserver(timeObserver) }
  }

  func pieceArrived(index: Int, url: URL) {
    guard !isStopped else { return }
    timeline.markArrived(index: index, url: url)
    // We were waiting for this piece: load it in place (paused). The caller decides when to resume.
    if waitingPieceIndex == index {
      load(at: bookTime)
    } else {
      // The piece after the loaded one: queue it now, so it plays on without a gap.
      enqueueSuccessorIfArrived()
    }
  }

  func isReady(at bookTime: TimeInterval) -> Bool {
    guard !isStopped, !isSeeking, !isBuffering,
      let piece = timeline.location(for: bookTime)?.piece,
      let item = player.currentItem, item.status == .readyToPlay,
      pieceIndexByItem[ObjectIdentifier(item)] == piece.index
    else { return false }
    return timeline.isReady(at: bookTime)
  }

  // MARK: Remote commands (never reported back)

  func applyPlay(at bookTime: TimeInterval, rate: Float) {
    guard !isStopped else { return }
    self.rate = rate
    awaitingGroupPlayback = false
    wantsPlayback = true
    isHeldWhilePlaying = true
    if load(at: bookTime) {
      resumeIfReady()
    } else {
      // A preceding explicit Pause may have released the wait for this same missing file.
      // Reopen the hold without repeating the deduplicated transfer request.
      onBufferingNeeded?()
    }
  }

  func applyPause(at bookTime: TimeInterval) {
    applyPause(at: bookTime, shouldBuffer: false)
  }

  func applyPause(at bookTime: TimeInterval, shouldBuffer: Bool) {
    guard !isStopped else { return }
    awaitingGroupPlayback = shouldBuffer
    wantsPlayback = false
    player.pause()
    isPlaying = false
    isHeldWhilePlaying = shouldBuffer
    // An already-loaded item needs no seek to its own pause position. In particular, a buffering
    // pause must not cancel the seek whose completion will release the group's wait.
    if loadedPieceIndex == nil || abs(positionForSaving - bookTime) > 0.05 {
      load(at: bookTime, requestIfMissing: false)
    }
  }

  func applySeek(to bookTime: TimeInterval) {
    guard !isStopped else { return }
    isHeldWhilePlaying = wantsPlayback
    if load(at: bookTime) { resumeIfReady() }
  }

  /// Another participant changed the speed while playback is paused (so no play command carries it):
  /// use it from the next play. Never reported back.
  func applyRate(_ newRate: Float) {
    guard !isStopped else { return }
    rate = newRate
    if isPlaying { player.rate = newRate }
  }

  // MARK: Local user actions (reported)
  //
  // Each action is reported BEFORE it is applied locally. Applying it can find the piece missing, and
  // the stall suspension that starts then makes the coordinator ignore commands for the group: a seek
  // or play reported after that would only ever move this device.

  func userTogglePlay() {
    // The person sharing is missing (decision 9, C.2): the group is paused for them. Play would only
    // play here; do nothing and say why.
    if isHeldForSharer {
      onToggleWhileHeldForSharer?()
      return
    }
    // The group is playing but held for our piece: toggling would only send everyone a second play
    // (or, to the user's ear, a pause that stops the group for no reason). Do nothing; say we wait.
    // A paused seek into a missing piece is different: Play there still starts the group (R14).
    // Checked in the status line's order: sharer, waiting for the book, finding the place (a11y M6).
    if isWaitingForPiece, isHeldWhilePlaying {
      onToggleWhileWaiting?()
      return
    }
    if isJoiningGroup {
      onActionWhileJoining?()
      return
    }
    // Match the displayed control. A pending or blocked Play is not audible playback, and a
    // fresh Play after headphone removal must clear the explicit-resume requirement.
    if isPlaying && !requiresUserResume { userPause() } else { userPlay() }
  }

  func userPause(requiringUserResume: Bool = false) {
    guard !isStopped else { return }
    requiresUserResume = requiresUserResume || requiringUserResume || isAudioInterrupted || hasInterruptionHold
    // A repeated Pause is a no-op, but a silent player with pending recovery still needs cancellation.
    guard wantsPlayback || awaitingGroupPlayback || isPlaying || hasInterruptionHold else { return }
    wantsPlayback = false
    awaitingGroupPlayback = false
    isHeldWhilePlaying = false
    let position = positionForSaving
    player.pause()
    isPlaying = false
    bookTime = position
    // Release our temporary hold before proposing a deliberate pause to the group.
    releaseInterruptionHold()
    subject.send(.paused(at: position))
  }

  func userPlay() {
    guard !isStopped, !isAudioInterrupted else { return }
    if isHeldForSharer { onToggleWhileHeldForSharer?(); return }
    if isJoiningGroup { onActionWhileJoining?(); return }
    if isWaitingForPiece, isHeldWhilePlaying { onToggleWhileWaiting?(); return }
    requiresUserResume = false
    releaseInterruptionHold()
    subject.send(.played(at: bookTime, rate: rate))
    applyPlay(at: bookTime, rate: rate)
  }

  func userSkip(by seconds: TimeInterval) { userJump(to: bookTime + seconds) }

  func userJump(to target: TimeInterval) {
    guard !isStopped, !isAudioInterrupted else { return }
    if isJoiningGroup {
      onActionWhileJoining?()
      return
    }
    let from = bookTime
    let clamped = min(max(0, target), manifest.duration)
    subject.send(.seeked(to: clamped, from: from))
    applySeek(to: clamped)
  }

  func userSetRate(_ newRate: Float) {
    guard !isStopped else { return }
    if isJoiningGroup {
      onActionWhileJoining?()
      return
    }
    subject.send(.rateChanged(newRate))
    applyRate(newRate)
  }

  /// The person sharing is missing (decision 9): stop here without telling anyone (the service's
  /// suspension makes the whole group wait). When they are back, the coordinator resumes the group.
  func holdForSharer() {
    guard !isStopped else { return }
    wantsPlayback = false
    awaitingGroupPlayback = false
    let position = positionForSaving
    player.pause()
    isPlaying = false
    bookTime = position
  }

  func stop() {
    isStopped = true
    wantsPlayback = false
    awaitingGroupPlayback = false
    seekGeneration += 1
    pendingSeekOffset = nil
    disposeBag.removeAll()
    onInterruptionBegan = nil
    onInterruptionEnded = nil
    onBufferingNeeded = nil
    onPositionReady = nil
    hasInterruptionHold = false
    player.pause()
    player.removeAllItems()
    forgetItems(keeping: [])
    loadedPieceIndex = nil
    queuedPieceIndex = nil
    isSeeking = false
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    timeObserver = nil
    isPlaying = false
    if sessionConfigured {
      do {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
        Self.logger.error("Listen Together: could not deactivate the audio session: \(error.localizedDescription)")
      }
      sessionConfigured = false
    }
  }

  // MARK: Private

  /// Loads the piece containing `bookTime` and seeks inside it. Returns false if it hasn't arrived,
  /// in which case nothing is loaded and `onNeedsPiece` has been called (once per wait).
  @discardableResult
  private func load(at bookTime: TimeInterval, requestIfMissing: Bool = true) -> Bool {
    guard let location = timeline.location(for: bookTime) else { return false }
    return load(location.piece, offset: location.offset, bookTime: bookTime, requestIfMissing: requestIfMissing)
  }

  /// Loads `piece` and seeks to `offset` inside it; `bookTime` is the matching book position.
  private func load(
    _ piece: SharedPiece, offset: TimeInterval, bookTime: TimeInterval, requestIfMissing: Bool
  ) -> Bool {
    guard !isStopped else { return false }
    // Ignore an echo at an already-prepared position; repeatedly seeking on recovery would create
    // another suspension every time the coordinator reapplies Play.
    if loadedPieceIndex == piece.index, player.currentItem != nil,
      abs(positionForSaving - bookTime) < 0.05, (isSeeking || isReady(at: bookTime)) {
      return true
    }
    self.bookTime = bookTime
    onProgressChanged?(bookTime, piece.index)
    seekGeneration += 1
    pendingSeekOffset = nil
    isSeeking = false
    isBuffering = false
    player.pause()
    isPlaying = false
    guard let url = timeline.url(forPiece: piece.index) else {
      player.removeAllItems()
      forgetItems(keeping: [])
      loadedPieceIndex = nil
      queuedPieceIndex = nil
      if requestIfMissing, waitingPieceIndex != piece.index {
        waitingPieceIndex = piece.index
        onNeedsPiece?(piece.index)
      }
      return false
    }
    waitingPieceIndex = nil
    if loadedPieceIndex != piece.index || player.currentItem == nil {
      player.removeAllItems()
      forgetItems(keeping: [])
      queuedPieceIndex = nil
      let item = makeItem(url: url, index: piece.index)
      player.insert(item, after: nil)
      loadedPieceIndex = piece.index
      enqueueSuccessorIfArrived()
    }
    isSeeking = true
    pendingSeekOffset = offset
    if player.currentItem?.status != .readyToPlay { onBufferingNeeded?() }
    seekWhenReady()
    return true
  }

  private func seekWhenReady() {
    guard !isStopped, let offset = pendingSeekOffset,
      let item = player.currentItem, item.status == .readyToPlay else { return }
    pendingSeekOffset = nil
    let generation = seekGeneration
    player.seek(to: CMTime(seconds: offset, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] finished in
      Task { @MainActor in
        guard let self, !self.isStopped, self.seekGeneration == generation,
          let item, self.player.currentItem === item else { return }
        guard finished else {
          self.itemFailed(item)
          return
        }
        self.isSeeking = false
        self.positionBecameReady()
      }
    }
  }

  private func makeItem(url: URL, index: Int) -> AVPlayerItem {
    let item = AVPlayerItem(url: url)
    item.audioTimePitchAlgorithm = .timeDomain
    let id = ObjectIdentifier(item)
    pieceIndexByItem[id] = index
    let pathExtension = url.pathExtension
    itemObservations[id] = Publishers.CombineLatest3(
      item.publisher(for: \.status), item.publisher(for: \.isPlaybackLikelyToKeepUp),
      item.publisher(for: \.isPlaybackBufferFull))
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak item] status, _, _ in
        MainActor.assumeIsolated {
          guard let self, !self.isStopped, let item,
            self.pieceIndexByItem[id] != nil else { return }
          if status == .failed {
            let error = item.error as NSError?
            Self.logger.error(
              "Listen Together: piece \(index, privacy: .public) (\(pathExtension, privacy: .public)) can't be played: \(error?.domain ?? "", privacy: .public) \(error?.code ?? 0, privacy: .public)")
            self.itemFailed(item)
          } else if self.player.currentItem === item, status == .readyToPlay {
            self.seekWhenReady()
            if self.isBuffering, item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull {
              self.isBuffering = false
            }
            self.positionBecameReady()
          }
        }
      }
    return item
  }

  /// Forgets every item that is no longer in the queue (and `keeping`, for one being added).
  private func forgetItems(keeping: [AVPlayerItem]) {
    let live = Set((player.items() + keeping).map(ObjectIdentifier.init))
    pieceIndexByItem = pieceIndexByItem.filter { live.contains($0.key) }
    itemObservations = itemObservations.filter { live.contains($0.key) }
  }

  /// Queues the piece after the loaded one behind it, if it has arrived and nothing is queued yet.
  private func enqueueSuccessorIfArrived() {
    guard queuedPieceIndex == nil, let loaded = loadedPieceIndex, let current = player.currentItem,
      let next = timeline.piece(after: loaded), let url = timeline.url(forPiece: next.index)
    else { return }
    let item = makeItem(url: url, index: next.index)
    guard player.canInsert(item, after: current) else {
      forgetItems(keeping: [])
      return
    }
    player.insert(item, after: current)
    queuedPieceIndex = next.index
  }

  /// The queue's current item changed. When it is the queued piece (the previous one played out), it
  /// becomes the loaded piece and the one after it is queued in turn. Changes made by `load` are
  /// already accounted for and do nothing here.
  func queueAdvanced() {
    guard !isStopped, let item = player.currentItem, let index = pieceIndexByItem[ObjectIdentifier(item)],
      index != loadedPieceIndex, index == queuedPieceIndex
    else { return }
    loadedPieceIndex = index
    queuedPieceIndex = nil
    waitingPieceIndex = nil
    bookTime = currentPosition
    forgetItems(keeping: [])
    enqueueSuccessorIfArrived()
    if item.status != .readyToPlay { onBufferingNeeded?() }
  }

  /// A piece's file can't be played (AVPlayerItem failed): it no longer counts as arrived, the
  /// service is told (it loads the piece again and the group waits), and it leaves the queue. If it was
  /// playing, playback is held here as for any missing piece, instead of "playing" in silence.
  func pieceFailed(index: Int) {
    recoverFailedPiece(index: index, position: positionForSaving)
  }

  private func recoverFailedPiece(index: Int, position: TimeInterval) {
    guard !isStopped, timeline.url(forPiece: index) != nil else { return }
    timeline.forget(index: index)
    if index == loadedPieceIndex {
      let wasPlaying = wantsPlayback
      player.pause()
      isPlaying = false
      loadedPieceIndex = nil
      if !load(at: position) { isHeldWhilePlaying = wasPlaying }
    } else if index == queuedPieceIndex {
      if let item = player.items().first(where: { pieceIndexByItem[ObjectIdentifier($0)] == index }) {
        player.remove(item)
      }
      queuedPieceIndex = nil
      forgetItems(keeping: [])
    }
    onPieceFailed?(index)
  }

  private func itemFailed(_ item: AVPlayerItem) {
    let id = ObjectIdentifier(item)
    guard !isStopped, let index = pieceIndexByItem[id] else { return }
    // AVQueuePlayer may have advanced before our queued KVO callbacks. Snapshot the failed item's
    // position before removing it, rather than attributing its clock to the preceding file.
    let isCurrent = player.currentItem === item
    let time = item.currentTime()
    let piece = timeline.pieces.first { $0.index == index }
    let position = isCurrent && !isSeeking && time.isNumeric
      ? (piece?.bookStart ?? bookTime) + time.seconds : positionForSaving
    pieceIndexByItem.removeValue(forKey: id)
    itemObservations.removeValue(forKey: id)
    if isCurrent {
      loadedPieceIndex = index
      if queuedPieceIndex == index { queuedPieceIndex = nil }
    } else if queuedPieceIndex == index {
      player.remove(item)
    }
    recoverFailedPiece(index: index, position: position)
  }

  enum PieceEndDecision: Equatable {
    /// The next piece is queued and plays on by itself.
    case queuedNextPlays(Int)
    /// The next piece has not arrived: wait for it (the group waits too).
    case waitForNext(Int)
    case endOfBook
  }

  /// What happens when piece `index` plays to its end, with `queued` behind it.
  nonisolated static func decisionAtEnd(of index: Int, queued: Int?, timeline: PieceTimeline) -> PieceEndDecision {
    guard let next = timeline.piece(after: index) else { return .endOfBook }
    if queued == next.index { return .queuedNextPlays(next.index) }
    return .waitForNext(next.index)
  }

  /// A piece played to its end. If the next one was queued, the queue already continues (seamless);
  /// otherwise the next piece is loaded, or waited for.
  private func itemPlayedToEnd(_ item: AVPlayerItem) {
    guard let index = pieceIndexByItem[ObjectIdentifier(item)], index == loadedPieceIndex else { return }
    switch Self.decisionAtEnd(of: index, queued: queuedPieceIndex, timeline: timeline) {
    case .queuedNextPlays:
      queueAdvanced()
    case .waitForNext, .endOfBook:
      advanceToNextPiece()
    }
  }

  /// Where the player really is, computed from the player rather than the last periodic tick.
  /// During a seek the AVPlayer clock still belongs to the old position.
  var positionForSaving: TimeInterval { isSeeking ? bookTime : currentPosition }
  var fileIndexForSaving: Int? {
    isSeeking ? timeline.location(for: bookTime)?.piece.index : loadedPieceIndex
  }

  private var currentPosition: TimeInterval {
    guard player.currentItem != nil, let index = loadedPieceIndex,
      let piece = timeline.pieces.first(where: { $0.index == index })
    else { return bookTime }
    let time = itemTimeProvider?() ?? player.currentTime()
    guard time.isNumeric else { return bookTime }
    return piece.bookStart + time.seconds
  }

  /// The current piece played to its end: continue with the next piece in book order, from its own
  /// start (not from this piece's end time, which float seams can put just before it). Internal for tests.
  func advanceToNextPiece() {
    guard !isStopped else { return }
    guard let index = loadedPieceIndex, let next = timeline.piece(after: index) else {
      wantsPlayback = false
      isPlaying = false
      return
    }
    // A missing next piece pauses us locally; the service decides what to tell the others.
    let wasPlaying = wantsPlayback
    if load(next, offset: 0, bookTime: next.bookStart, requestIfMissing: true) {
      resumeIfReady()
    } else {
      isHeldWhilePlaying = wasPlaying
      isPlaying = false
    }
  }

  private func handleInterruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool) {
    guard !isStopped else { return }
    switch type {
    case .began:
      guard !isAudioInterrupted else { return }
      Self.logger.info("Listen Together: listener audio interrupted; holding the group")
      bookTime = positionForSaving
      isAudioInterrupted = true
      sessionConfigured = false
      player.pause()
      isPlaying = false
      if !hasInterruptionHold {
        hasInterruptionHold = true
        onInterruptionBegan?()
      }
    case .ended:
      guard isAudioInterrupted else { return }
      isAudioInterrupted = false
      requiresUserResume = requiresUserResume || !shouldResume
      Self.logger.info("Listen Together: listener interruption ended; requires Play=\(self.requiresUserResume, privacy: .public)")
      if !requiresUserResume {
        // Release the hold and adopt the group's current state. Never propose an unconditional Play.
        wantsPlayback = false
        releaseInterruptionHold()
      } else {
        wantsPlayback = false
      }
    @unknown default:
      break
    }
  }

  private func releaseInterruptionHold() {
    guard hasInterruptionHold else { return }
    hasInterruptionHold = false
    onInterruptionEnded?()
  }

  private func playbackStateChanged() {
    guard !isStopped else { return }
    queueAdvanced()
    let status = player.timeControlStatus
    isPlaying = status == .playing && !isAudioInterrupted && !requiresUserResume
    Self.logger.debug("Listen Together: listener playback state=\(status.rawValue, privacy: .public)")
    if status == .waitingToPlayAtSpecifiedRate, !isSeeking, wantsPlayback, !isBuffering {
      isBuffering = true
      onBufferingNeeded?()
      if let item = player.currentItem, item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull {
        isBuffering = false
        positionBecameReady()
      }
    }
  }

  private func positionBecameReady() {
    guard isReady(at: bookTime) else { return }
    onPositionReady?()
    resumeIfReady()
  }

  private func resumeIfReady() {
    guard !isStopped, wantsPlayback, !isAudioInterrupted, !requiresUserResume,
      !isHeldForSharer, isReady(at: bookTime), activateSessionIfNeeded() else { return }
    player.playImmediately(atRate: rate)
  }

  private func activateSessionIfNeeded() -> Bool {
    guard !sessionConfigured else { return true }
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .spokenAudio)
      try session.setActive(true)
      sessionConfigured = true
    } catch {
      Self.logger.error("Listen Together: could not activate the audio session: \(error.localizedDescription)")
    }
    return sessionConfigured
  }
}
