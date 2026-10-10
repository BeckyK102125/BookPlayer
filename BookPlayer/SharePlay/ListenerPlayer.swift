import AVFoundation
import Combine
import Foundation

/// The listener's own player. It plays received pieces one at a time on the shared "book time" timeline.
/// Remote commands (`apply*`) are never reported back; the user's own actions (`user*`) are.
@MainActor
final class ListenerPlayer: ObservableObject, ListenTogetherPlaybackTarget {
  @Published private(set) var bookTime: TimeInterval = 0
  @Published private(set) var isPlaying = false
  @Published private(set) var rate: Float = 1
  @Published private(set) var timeline: PieceTimeline
  let manifest: SharedBookManifest
  /// Asks the service to wait for a piece. Called at most once per missing piece per wait.
  var onNeedsPiece: ((Int) -> Void)?

  private let player = AVPlayer()
  private nonisolated(unsafe) var timeObserver: Any?
  private var loadedPieceIndex: Int?
  /// The piece we are currently waiting for; cleared when it arrives or another piece loads.
  private var waitingPieceIndex: Int?
  private var sessionConfigured = false
  private let subject = PassthroughSubject<LocalPlaybackEvent, Never>()
  private var disposeBag = Set<AnyCancellable>()

  var localEvents: AnyPublisher<LocalPlaybackEvent, Never> { subject.eraseToAnyPublisher() }

  init(manifest: SharedBookManifest) {
    self.manifest = manifest
    self.timeline = PieceTimeline(pieces: manifest.pieces)
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated {
        guard let self, let index = self.loadedPieceIndex,
          let piece = self.timeline.pieces.first(where: { $0.index == index }),
          time.isNumeric
        else { return }
        self.bookTime = piece.bookStart + time.seconds
      }
    }
    NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        MainActor.assumeIsolated {
          guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
          self.advanceToNextPiece()
        }
      }
      .store(in: &disposeBag)
    NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
          .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        MainActor.assumeIsolated {
          if reason == .oldDeviceUnavailable, self?.isPlaying == true { self?.userTogglePlay() }
        }
      }
      .store(in: &disposeBag)
    NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
          .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
        MainActor.assumeIsolated {
          if type == .began, self?.isPlaying == true { self?.userTogglePlay() }
        }
      }
      .store(in: &disposeBag)
  }

  deinit {
    if let timeObserver { player.removeTimeObserver(timeObserver) }
  }

  func pieceArrived(index: Int, url: URL) {
    timeline.markArrived(index: index, url: url)
    // We were waiting for this piece: load it in place (paused). The caller decides when to resume.
    if waitingPieceIndex == index { load(at: bookTime) }
  }

  func isReady(at bookTime: TimeInterval) -> Bool { timeline.isReady(at: bookTime) }

  // MARK: Remote commands (never reported back)

  func applyPlay(at bookTime: TimeInterval, rate: Float) {
    self.rate = rate
    guard load(at: bookTime) else {
      player.pause()
      isPlaying = false
      return
    }
    activateSessionIfNeeded()
    player.playImmediately(atRate: rate)
    isPlaying = true
  }

  func applyPause(at bookTime: TimeInterval) {
    player.pause()
    isPlaying = false
    load(at: bookTime)
  }

  func applySeek(to bookTime: TimeInterval) {
    let wasPlaying = isPlaying
    guard load(at: bookTime) else {
      player.pause()
      isPlaying = false
      return
    }
    if wasPlaying { player.playImmediately(atRate: rate) }
  }

  // MARK: Local user actions (reported)

  func userTogglePlay() {
    if isPlaying {
      applyPause(at: bookTime)
      subject.send(.paused(at: bookTime))
    } else {
      applyPlay(at: bookTime, rate: rate)
      // If the piece is missing nothing started, so there is nothing to tell the others.
      if isPlaying { subject.send(.played(at: bookTime, rate: rate)) }
    }
  }

  func userSkip(by seconds: TimeInterval) { userJump(to: bookTime + seconds) }

  func userJump(to target: TimeInterval) {
    let from = bookTime
    let clamped = min(max(0, target), manifest.duration)
    applySeek(to: clamped)
    subject.send(.seeked(to: clamped, from: from))
  }

  func userSetRate(_ newRate: Float) {
    rate = newRate
    if isPlaying { player.rate = newRate }
    subject.send(.rateChanged(newRate))
  }

  func stop() {
    player.pause()
    player.replaceCurrentItem(with: nil)
    loadedPieceIndex = nil
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    timeObserver = nil
    isPlaying = false
    if sessionConfigured {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      sessionConfigured = false
    }
  }

  // MARK: Private

  /// Loads the piece containing `bookTime` and seeks inside it. Returns false if it hasn't arrived,
  /// in which case nothing is loaded and `onNeedsPiece` has been called (once per wait).
  @discardableResult
  private func load(at bookTime: TimeInterval) -> Bool {
    guard let location = timeline.location(for: bookTime) else { return false }
    let piece = location.piece
    self.bookTime = bookTime
    guard let url = timeline.url(forPiece: piece.index) else {
      player.replaceCurrentItem(with: nil)
      loadedPieceIndex = nil
      if waitingPieceIndex != piece.index {
        waitingPieceIndex = piece.index
        onNeedsPiece?(piece.index)
      }
      return false
    }
    waitingPieceIndex = nil
    if loadedPieceIndex != piece.index {
      let item = AVPlayerItem(url: url)
      item.audioTimePitchAlgorithm = .timeDomain
      player.replaceCurrentItem(with: item)
      loadedPieceIndex = piece.index
    }
    player.seek(
      to: CMTime(seconds: location.offset, preferredTimescale: 600),
      toleranceBefore: .zero, toleranceAfter: .zero)
    return true
  }

  private func advanceToNextPiece() {
    guard let index = loadedPieceIndex,
      let current = timeline.pieces.first(where: { $0.index == index }),
      current.bookEnd < manifest.duration - 0.1
    else {
      isPlaying = false
      return
    }
    // A missing next piece pauses us locally; the service decides what to tell the others.
    if load(at: current.bookEnd), isPlaying {
      player.playImmediately(atRate: rate)
    } else {
      isPlaying = false
    }
  }

  private func activateSessionIfNeeded() {
    guard !sessionConfigured else { return }
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .spokenAudio)
    try? session.setActive(true)
    sessionConfigured = true
  }
}
