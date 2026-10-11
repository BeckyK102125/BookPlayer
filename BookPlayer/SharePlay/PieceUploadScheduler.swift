import AVFoundation
import Foundation

/// Which piece the sharer sends next (addendum 3, decision 2). Asked again before every piece, so it
/// follows the group:
/// 1. a piece a listener is waiting for (`request`), oldest request first;
/// 2. the piece at the group's position;
/// 3. the pieces after it, in book order, so the next two or three are always ahead of the group;
/// 4. then the rest: on to the end of the book, then from its start.
/// A seek far away simply moves the position, so the piece there goes next. A piece that failed goes
/// behind every other piece still to send (it is still retried), unless a listener waits for it.
struct PieceUploadScheduler {
  private let pieces: [PlannedPiece]
  private var sent = Set<Int>()
  private var requested: [Int] = []
  private var failed = Set<Int>()

  init(pieces: [PlannedPiece]) {
    self.pieces = pieces.sorted { $0.bookStart < $1.bookStart }
  }

  var isComplete: Bool { pieces.allSatisfy { sent.contains($0.index) } }

  mutating func markSent(_ index: Int) {
    sent.insert(index)
    failed.remove(index)
    requested.removeAll { $0 == index }
  }

  /// The piece must be sent again (its attachment is gone from the journal).
  mutating func markUnsent(_ index: Int) { sent.remove(index) }

  /// The piece failed: it goes behind the others still to send.
  mutating func markFailed(_ index: Int) { failed.insert(index) }

  /// A listener waits for this piece. Ignored when it is already sent or unknown.
  mutating func request(_ index: Int) {
    guard !sent.contains(index), !requested.contains(index), pieces.contains(where: { $0.index == index })
    else { return }
    requested.append(index)
  }

  func next(at position: TimeInterval) -> PlannedPiece? {
    for index in requested {
      if let piece = pieces.first(where: { $0.index == index }), !sent.contains(index) { return piece }
    }
    guard !pieces.isEmpty else { return nil }
    let start = pieces.lastIndex(where: { $0.bookStart <= position + PieceTimeline.seamTolerance }) ?? 0
    let order = (0..<pieces.count).map { pieces[(start + $0) % pieces.count] }.filter { !sent.contains($0.index) }
    return order.first { !failed.contains($0.index) } ?? order.first
  }
}

/// How the sharer retries a piece that failed (addendum 3, decision 5). Nothing ends the session:
/// a failure waits and tries again, longer each time up to a cap. Interruptions (the app was
/// suspended or sent to the background, the export was interrupted or cancelled) never count.
enum PieceRetryPolicy {
  static let delays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30)]
  /// After an interruption while the app is active: a short pause, not counted.
  static let interruptionDelay: Duration = .seconds(2)
  /// After an interruption in the background: wait for the app (becoming active ends the wait early).
  static let backgroundInterruptionDelay: Duration = .seconds(30)

  /// `failures` is 1 after the first real failure of the current run of failures.
  static func delay(afterFailures failures: Int) -> Duration {
    delays[min(max(failures, 1), delays.count) - 1]
  }

  static func isInterruption(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if case .exportFailed(_, _, let underlying?)? = error as? BookSplitterError {
      return isInterruption(underlying)
    }
    let nsError = error as NSError
    switch nsError.domain {
    case AVFoundationErrorDomain:
      return nsError.code == AVError.operationInterrupted.rawValue
        || nsError.code == AVError.mediaServicesWereReset.rawValue
    case NSURLErrorDomain:
      return nsError.code == NSURLErrorCancelled
    case "Swift.CancellationError":
      return true
    default:
      return false
    }
  }
}

/// One back-off wait at a time: it ends when its time is up, or earlier with `wake()` (the app became
/// active, or the session ended).
@MainActor
final class ListenTogetherRetryWaiter {
  private var continuation: CheckedContinuation<Void, Never>?
  private var timer: Task<Void, Never>?
  /// Changes with every wait and every wake, so a late timer of an earlier wait does nothing.
  private var generation = 0

  func wait(_ delay: Duration, sleep: @escaping @MainActor (Duration) async -> Void) async {
    wake()
    let current = generation
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      self.continuation = continuation
      timer = Task { @MainActor [weak self] in
        await sleep(delay)
        self?.timeUp(current)
      }
    }
  }

  /// Ends the current wait now, if there is one.
  func wake() {
    generation += 1
    timer?.cancel()
    timer = nil
    resume()
  }

  private func timeUp(_ waitGeneration: Int) {
    guard waitGeneration == generation else { return }
    generation += 1
    timer = nil
    resume()
  }

  private func resume() {
    let waiting = continuation
    continuation = nil
    waiting?.resume()
  }
}
