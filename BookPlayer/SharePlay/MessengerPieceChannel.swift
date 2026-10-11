import BookPlayerKit
import Foundation

enum ChunkChannelError: Error, Equatable {
  /// The sharer no longer keeps this piece.
  case pieceGone
  /// Sends kept failing (more than `MessengerPieceChannel.maxConsecutiveSendFailures` in a row).
  case tooManySendFailures
  /// The channel was stopped (the session ended).
  case stopped
  /// The piece file changed size while it was being sent.
  case sizeMismatch
}

/// A `.part` file's disk work (fix round 1, Minor 3): writes and the final flush run in order on a
/// serial queue, off the main actor. The handle is only touched on that queue after `init`.
final class ChunkFileWriter: @unchecked Sendable {
  let url: URL
  private let queue = DispatchQueue(label: "ListenTogether.chunks.writer", qos: .utility)
  private var handle: FileHandle?

  /// Creates the file pre-sized to `size` (sparse, so this is quick).
  init(url: URL, size: Int64) throws {
    self.url = url
    try? FileManager.default.removeItem(at: url)
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(size))
    self.handle = handle
  }

  /// A failed write isn't reported: the size and checksum check at the end catches it.
  func write(_ data: Data, at offset: UInt64) {
    queue.async { [self] in
      guard let handle else { return }
      do {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
      } catch {
        MessengerPieceChannel.logger.error(
          "Listen Together: chunk write failed: \(ListenTogetherErrorDescription.describe(error), privacy: .public)")
      }
    }
  }

  /// Waits for every write, flushes and closes.
  func finish() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async { [self] in
        closeOnQueue()
        continuation.resume()
      }
    }
  }

  /// Closes (after any pending write) and deletes the file.
  func discard() {
    queue.sync { closeOnQueue() }
    try? FileManager.default.removeItem(at: url)
  }

  private func closeOnQueue() {
    try? handle?.synchronize()
    try? handle?.close()
    handle = nil
  }
}

/// Writes one piece's chunks straight into a `.part` file pre-sized to the whole piece, in any
/// order. Only the bitset of received chunks stays in memory; the disk work is `ChunkFileWriter`'s.
@MainActor
final class ChunkReassembler {
  let pieceID: UUID
  let count: Int
  let totalBytes: Int64
  let checksum: UInt32
  let pathExtension: String
  let partURL: URL
  private(set) var received: [Bool]
  private(set) var lastChunkAt: Date
  /// How many chunks were written so far (tells whether anything arrived during a wait).
  private(set) var chunksWritten = 0
  /// The last chunk is in and the file is being checked: further chunks are ignored.
  var isFinishing = false
  private let file: ChunkFileWriter

  init(first frame: ChunkFrame, folder: URL, now: Date) throws {
    // Decoded frames are already capped; this guards any other caller (fix round 1, C1).
    guard frame.totalBytes <= ListenTogetherLimits.maxChunkedPieceBytes,
      frame.count == ChunkFrame.chunkCount(forBytes: frame.totalBytes)
    else { throw ChunkChannelError.sizeMismatch }
    pieceID = frame.pieceID
    count = frame.count
    totalBytes = frame.totalBytes
    checksum = frame.checksum
    pathExtension = frame.pathExtension
    received = Array(repeating: false, count: frame.count)
    lastChunkAt = now
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    partURL = folder.appendingPathComponent("\(frame.pieceID.uuidString).part")
    file = try ChunkFileWriter(url: partURL, size: frame.totalBytes)
  }

  var isComplete: Bool { !received.contains(false) }
  var missingRanges: [ClosedRange<Int>] { ChunkGaps.missingRanges(received) }

  /// The same piece as this one (a frame with other sizes or checksum is ignored).
  func matches(_ frame: ChunkFrame) -> Bool {
    frame.count == count && frame.totalBytes == totalBytes && frame.checksum == checksum
      && frame.pathExtension == pathExtension
  }

  /// Queues the chunk's write at its place. False when it was already here or doesn't belong.
  @discardableResult
  func write(_ frame: ChunkFrame, now: Date) -> Bool {
    guard matches(frame), !received[frame.index] else { return false }
    let offset = ChunkFrame.byteRange(ofChunk: frame.index, totalBytes: totalBytes).lowerBound
    file.write(frame.payload, at: UInt64(offset))
    received[frame.index] = true
    lastChunkAt = now
    chunksWritten += 1
    return true
  }

  /// Waits for the writes, flushes and closes the file.
  func close() async {
    await file.finish()
  }

  func discard() {
    file.discard()
  }
}

/// Transfer fix B: audio pieces as raw chunks on a second, reliable `GroupSessionMessenger`, used
/// when the journal refuses pieces. Knows nothing about SharePlay: it sends through `send` and is fed
/// what arrives through `receive(_:from:)`, so it is tested without a session.
///
/// Sharer: `upload` reads the piece in 192 KB chunks and sends them to everyone, at most a window of
/// 2-3 in flight, backing off when a send fails. Requests for missing chunks (gaps, late joiners) are
/// answered to the one listener who asked. Only the `cacheLimit` latest pieces are kept; an older one
/// is reported gone, and the listener's player then asks the sharer to prepare it again.
///
/// Listener: chunks are written into a pre-sized `.part` file; a complete file is checked (size and
/// CRC-32), renamed `<id>.<ext>` and reported through `onPieceReceived`. Gaps are asked for after the
/// last chunk, and again whenever the session's retry timer finds a piece stale.
@MainActor
final class MessengerPieceChannel: BPLogger {
  typealias Send = @MainActor @Sendable (Data, _ recipient: UUID?) async throws -> Void

  /// The sharer keeps this many pieces to send again; older ones are deleted.
  static let cacheLimit = 3
  /// A listener's piece with nothing heard for this long is asked for again.
  static let staleAfter: TimeInterval = 5
  /// More failed sends in a row than this fail the piece (the session tries it again later).
  static let maxConsecutiveSendFailures = 8
  /// At most this many pieces are assembled at once (fix round 1, I1).
  static let maxAssemblies = 4
  /// Once the last chunk is in, a gap is asked for if nothing else arrives for this long.
  static let gapCheckDelay: Duration = .seconds(1)

  /// Where listener files are written, and the only folder whose sharer files may be deleted.
  let folder: URL
  /// Listener: the person sharing, who requests go to (nil: everyone).
  var sharerID: UUID?
  /// Listener: a complete, checked piece file (in `folder`).
  var onPieceReceived: (@MainActor (UUID, URL) -> Void)?
  /// A mode announcement (`explicit`), or the first chunk heard (which means chunks too).
  var onModeAnnounced: (@MainActor (ListenTogetherTransportMode, _ explicit: Bool) -> Void)?
  /// Sharer: a listener can't load journal pieces (fix round 1, C2). The argument is who said so.
  var onJournalUnusable: (@MainActor (UUID?) -> Void)?

  private let send: Send
  private let sleep: @MainActor (Duration) async -> Void
  private let now: @MainActor () -> Date
  private var stopped = false
  private var tasks: [UUID: Task<Void, Never>] = [:]

  // Sharer
  private struct Source {
    let url: URL
    let totalBytes: Int64
    let checksum: UInt32
    let pathExtension: String
    var count: Int { ChunkFrame.chunkCount(forBytes: totalBytes) }
  }

  private struct Job {
    let pieceID: UUID
    let recipient: UUID?
    /// Nil: every chunk.
    var chunks: [Int]?
    let waiter: CheckedContinuation<Void, Error>?
  }

  private var sources: [UUID: Source] = [:]
  private var sourceOrder: [UUID] = []
  private var evicted = Set<UUID>()
  /// This device has sent pieces: unknown pieces asked for are answered "gone".
  private var isSharer = false
  private var jobs: [Job] = []
  private var pump: Task<Void, Never>?
  private(set) var window = ChunkSendWindow()

  // Listener
  private var assemblies: [UUID: ChunkReassembler] = [:]
  private var completed = Set<UUID>()
  /// Asked for and not complete, with when it was last asked for.
  private var requested: [UUID: Date] = [:]
  private var receivesPieces = true
  private var heardChunks = false

  init(
    folder: URL,
    send: @escaping Send,
    sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    now: @escaping @MainActor () -> Date = Date.init
  ) {
    self.folder = folder
    self.send = send
    self.sleep = sleep
    self.now = now
  }

  // MARK: Sharer

  /// Sends the piece to everyone and returns its id once every chunk has been sent.
  func upload(fileAt url: URL) async throws -> UUID {
    guard !stopped else { throw ChunkChannelError.stopped }
    isSharer = true
    let source = try await Self.makeSource(url)
    guard !stopped else { throw ChunkChannelError.stopped }
    let id = UUID()
    keep(source, as: id)
    Self.logger.info(
      "Listen Together: chunks piece \(id.uuidString, privacy: .public) bytes=\(source.totalBytes, privacy: .public) chunks=\(source.count, privacy: .public) ext=\(source.pathExtension, privacy: .public)")
    do {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        enqueue(Job(pieceID: id, recipient: nil, chunks: nil, waiter: continuation))
      }
    } catch {
      // Not kept: the session exports the piece again for its next attempt.
      sources[id] = nil
      sourceOrder.removeAll { $0 == id }
      throw error
    }
    return id
  }

  /// True while the piece can be sent again, false once it was dropped, nil when unknown.
  func hasPiece(_ id: UUID) -> Bool? {
    if sources[id] != nil { return true }
    return evicted.contains(id) ? false : nil
  }

  /// Listener: tells the sharer that journal pieces can't be loaded here (fix round 1, C2).
  func reportJournalUnusable() async {
    Self.logger.info("Listen Together: telling the sharer that journal pieces can't be loaded here")
    await sendControl(.journalUnusable, to: sharerID)
  }

  /// Sharer: tells `recipient` (nil: everyone) that pieces come as chunks.
  func announceMode(to recipient: UUID?) async {
    isSharer = true
    await sendControl(.transportMode(.chunks), to: recipient)
  }

  /// Size and checksum, read off the main actor (a piece is 6-25 MB).
  private static func makeSource(_ url: URL) async throws -> Source {
    try await Task.detached(priority: .utility) {
      let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
      let checksum = try ListenTogetherCRC32.checksum(ofFileAt: url)
      return Source(
        url: url, totalBytes: size, checksum: checksum,
        pathExtension: ChunkFrame.wireExtension(url.pathExtension))
    }.value
  }

  private func keep(_ source: Source, as id: UUID) {
    sources[id] = source
    sourceOrder.append(id)
    while sourceOrder.count > Self.cacheLimit {
      let old = sourceOrder.removeFirst()
      guard let dropped = sources.removeValue(forKey: old) else { continue }
      evicted.insert(old)
      // Only the share's own exported copies are deleted, never a file outside its folder.
      let stillUsed = sources.values.contains { $0.url == dropped.url }
      if !stillUsed, Self.isInside(dropped.url, folder: folder) {
        try? FileManager.default.removeItem(at: dropped.url)
      }
      Self.logger.info("Listen Together: chunks piece \(old.uuidString, privacy: .public) dropped from the cache")
    }
  }

  private static func isInside(_ url: URL, folder: URL) -> Bool {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
    return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
  }

  private func enqueue(_ job: Job) {
    guard !stopped else {
      job.waiter?.resume(throwing: ChunkChannelError.stopped)
      return
    }
    // A request for a piece already waiting for the same listener is merged into it.
    if job.waiter == nil,
      let existing = jobs.firstIndex(where: { $0.waiter == nil && $0.pieceID == job.pieceID && $0.recipient == job.recipient })
    {
      if let old = jobs[existing].chunks, let new = job.chunks {
        jobs[existing].chunks = Array(Set(old).union(new)).sorted()
      } else {
        jobs[existing].chunks = nil
      }
    } else {
      jobs.append(job)
    }
    guard pump == nil else { return }
    pump = Task { [weak self] in await self?.drainJobs() }
  }

  private func drainJobs() async {
    while !stopped, !jobs.isEmpty {
      let job = jobs.removeFirst()
      do {
        try await run(job)
        job.waiter?.resume()
      } catch {
        job.waiter?.resume(throwing: error)
        Self.logger.error(
          "Listen Together: chunks send of piece \(job.pieceID.uuidString, privacy: .public) failed: \(ListenTogetherErrorDescription.describe(error), privacy: .public)")
      }
    }
    pump = nil
  }

  private func run(_ job: Job) async throws {
    guard let source = sources[job.pieceID] else {
      if let recipient = job.recipient { await sendControl(.pieceGone(pieceID: job.pieceID), to: recipient) }
      throw ChunkChannelError.pieceGone
    }
    let indices = job.chunks ?? Array(0..<source.count)
    let handle = try FileHandle(forReadingFrom: source.url)
    defer { try? handle.close() }
    let started = now()
    var queue = indices[...]
    var retry: [Int] = []
    var sentBytes: Int64 = 0
    let send = self.send
    let recipient = job.recipient
    try await withThrowingTaskGroup(of: (Int, Error?).self) { group in
      var inFlight = 0
      while true {
        guard !stopped else { throw ChunkChannelError.stopped }
        while inFlight < window.size, let index = retry.isEmpty ? queue.popFirst() : retry.removeFirst() {
          let data = try await Self.frame(index, of: job.pieceID, source: source, handle: handle).encoded()
          sentBytes += Int64(data.count)
          group.addTask {
            do {
              try await send(data, recipient)
              return (index, nil)
            } catch {
              return (index, error)
            }
          }
          inFlight += 1
        }
        guard inFlight > 0, let (index, error) = try await group.next() else { break }
        inFlight -= 1
        guard let error else {
          window.sent()
          continue
        }
        guard !stopped, !(error is CancellationError) else { throw ChunkChannelError.stopped }
        let delay = window.failed()
        Self.logger.error(
          "Listen Together: chunk \(index, privacy: .public) send failed (\(self.window.consecutiveFailures, privacy: .public) in a row), window \(self.window.size, privacy: .public), waiting \(String(describing: delay), privacy: .public): \(ListenTogetherErrorDescription.describe(error), privacy: .public)")
        guard window.consecutiveFailures <= Self.maxConsecutiveSendFailures else {
          throw ChunkChannelError.tooManySendFailures
        }
        retry.append(index)
        await sleep(delay)
      }
    }
    let seconds = max(now().timeIntervalSince(started), 0.001)
    Self.logger.info(
      "Listen Together: chunks sent piece \(job.pieceID.uuidString, privacy: .public) chunks=\(indices.count, privacy: .public) to=\(job.recipient == nil ? "all" : "one", privacy: .public) in \(seconds, privacy: .public)s rate=\(Int(Double(sentBytes) / seconds), privacy: .public)B/s")
  }

  /// Reads one chunk off the main actor (Minor 3). Reads of one job are awaited one after another, so
  /// the handle is never used by two at once.
  private static func frame(_ index: Int, of id: UUID, source: Source, handle: FileHandle) async throws -> ChunkFrame {
    let range = ChunkFrame.byteRange(ofChunk: index, totalBytes: source.totalBytes)
    let payload = try await Task.detached(priority: .utility) { () throws -> Data in
      try handle.seek(toOffset: UInt64(range.lowerBound))
      return try handle.read(upToCount: Int(range.count)) ?? Data()
    }.value
    guard Int64(payload.count) == range.count else { throw ChunkChannelError.sizeMismatch }
    return ChunkFrame(
      pieceID: id, index: index, count: source.count, totalBytes: source.totalBytes,
      checksum: source.checksum, pathExtension: source.pathExtension, payload: payload)
  }

  // MARK: Receiving (both roles)

  /// Everything that arrives on the chunk messenger. Anything that isn't a chunk or a control
  /// message is dropped.
  func receive(_ data: Data, from sender: UUID?) {
    guard !stopped else { return }
    if let frame = ChunkFrame.decode(data) {
      // I1: once the sharer is known, only their chunks are taken.
      if let sharerID, sender != sharerID { return }
      receiveChunk(frame)
    } else if let control = ChunkControl.decode(data) {
      receiveControl(control, from: sender)
    }
  }

  private func receiveControl(_ control: ChunkControl, from sender: UUID?) {
    switch control {
    case .transportMode(let mode):
      onModeAnnounced?(mode, true)
    case .journalUnusable:
      onJournalUnusable?(sender)
    case .chunksMissing(let id, let ranges):
      guard let source = sources[id] else {
        // Only the sharer answers; a listener ignores other listeners' requests.
        guard isSharer else { return }
        Self.logger.info("Listen Together: chunks piece \(id.uuidString, privacy: .public) asked for but gone")
        track { [weak self] in await self?.sendControl(.pieceGone(pieceID: id), to: sender) }
        return
      }
      let indices = ChunkGaps.indices(in: ranges, count: source.count)
      guard !indices.isEmpty else { return }
      Self.logger.info(
        "Listen Together: chunks piece \(id.uuidString, privacy: .public) asked for again, chunks=\(indices.count, privacy: .public)")
      enqueue(Job(pieceID: id, recipient: sender, chunks: indices.count == source.count ? nil : indices, waiter: nil))
    case .pieceGone(let id):
      guard requested[id] != nil || assemblies[id] != nil else { return }
      Self.logger.info("Listen Together: chunks piece \(id.uuidString, privacy: .public) is gone on the sharer's side")
      requested[id] = nil
      assemblies.removeValue(forKey: id)?.discard()
    }
  }

  private func receiveChunk(_ frame: ChunkFrame) {
    guard receivesPieces, sources[frame.pieceID] == nil, !completed.contains(frame.pieceID) else { return }
    if !heardChunks {
      heardChunks = true
      onModeAnnounced?(.chunks, false)
    }
    let assembly: ChunkReassembler
    do {
      if let existing = assemblies[frame.pieceID] {
        assembly = existing
      } else {
        guard makeRoomForAssembly() else {
          // Asked for again by the retry timer once there is room.
          Self.logger.info("Listen Together: chunks piece \(frame.pieceID.uuidString, privacy: .public) waits, too many pieces arriving")
          requested[frame.pieceID] = requested[frame.pieceID] ?? now()
          return
        }
        assembly = try ChunkReassembler(first: frame, folder: folder, now: now())
        assemblies[frame.pieceID] = assembly
      }
      guard !assembly.isFinishing else { return }
      assembly.write(frame, now: now())
    } catch {
      Self.logger.error(
        "Listen Together: chunks piece \(frame.pieceID.uuidString, privacy: .public) could not be written: \(ListenTogetherErrorDescription.describe(error), privacy: .public)")
      assemblies.removeValue(forKey: frame.pieceID)?.discard()
      // Asked for again by the retry timer.
      requested[frame.pieceID] = now()
      return
    }
    if assembly.isComplete {
      assembly.isFinishing = true
      track { [weak self] in await self?.finish(assembly) }
    } else if assembly.received[assembly.count - 1] {
      // The last chunk is in (now or earlier, chunks can arrive out of order): checked again after
      // every later chunk, so a chunk that comes after the last one can't hide a gap.
      let written = assembly.chunksWritten
      track { [weak self] in
        guard let self else { return }
        await self.sleep(Self.gapCheckDelay)
        // Nothing arrived since the last chunk: whatever is missing was lost.
        guard self.assemblies[frame.pieceID] === assembly, assembly.chunksWritten == written, !assembly.isComplete
        else { return }
        self.request(frame.pieceID)
      }
    }
  }

  /// True when a new piece may start: under `maxAssemblies`, or after dropping the stalest one that
  /// is stale (it is asked for again later).
  private func makeRoomForAssembly() -> Bool {
    guard assemblies.count >= Self.maxAssemblies else { return true }
    let now = now()
    let stale = assemblies.values
      .filter { !$0.isFinishing && now.timeIntervalSince($0.lastChunkAt) >= Self.staleAfter }
      .min { $0.lastChunkAt < $1.lastChunkAt }
    guard let stale else { return false }
    assemblies[stale.pieceID] = nil
    stale.discard()
    requested[stale.pieceID] = now
    return true
  }

  private func finish(_ assembly: ChunkReassembler) async {
    await assembly.close()
    let url = assembly.partURL
    let expectedSize = assembly.totalBytes
    let expectedChecksum = assembly.checksum
    let intact = await Task.detached(priority: .utility) { () -> Bool in
      guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
        size == expectedSize, let checksum = try? ListenTogetherCRC32.checksum(ofFileAt: url)
      else { return false }
      return checksum == expectedChecksum
    }.value
    let id = assembly.pieceID
    guard !stopped, assemblies[id] === assembly else {
      try? FileManager.default.removeItem(at: url)
      return
    }
    assemblies[id] = nil
    guard intact else {
      Self.logger.error("Listen Together: chunks piece \(id.uuidString, privacy: .public) failed its checksum; asking for all of it")
      try? FileManager.default.removeItem(at: url)
      request(id)
      return
    }
    let ext = assembly.pathExtension.isEmpty ? "m4a" : assembly.pathExtension
    let destination = folder.appendingPathComponent("\(id.uuidString).\(ext)")
    do {
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: url, to: destination)
    } catch {
      Self.logger.error(
        "Listen Together: chunks piece \(id.uuidString, privacy: .public) could not be stored: \(ListenTogetherErrorDescription.describe(error), privacy: .public)")
      try? FileManager.default.removeItem(at: url)
      requested[id] = now()
      return
    }
    completed.insert(id)
    requested[id] = nil
    Self.logger.info(
      "Listen Together: chunks piece \(id.uuidString, privacy: .public) received bytes=\(expectedSize, privacy: .public) ext=\(ext, privacy: .public)")
    onPieceReceived?(id, destination)
  }

  // MARK: Listener

  /// The sharer said this piece was sent (`pieceUploaded`): asked for unless it is here or arriving.
  func pieceAnnounced(_ id: UUID) {
    guard receivesPieces, !stopped, sources[id] == nil, !completed.contains(id) else { return }
    if let lastActivity = lastActivity(of: id), now().timeIntervalSince(lastActivity) < Self.staleAfter { return }
    request(id)
  }

  /// Asks the sharer for what is missing of the piece (all of it when nothing is here).
  func request(_ id: UUID) {
    guard receivesPieces, !stopped, sources[id] == nil, !completed.contains(id) else { return }
    let ranges = assemblies[id]?.missingRanges ?? []
    requested[id] = now()
    let recipient = sharerID
    Self.logger.info(
      "Listen Together: asking for chunks of piece \(id.uuidString, privacy: .public) ranges=\(ranges.count, privacy: .public)")
    track { [weak self] in await self?.sendControl(.chunksMissing(pieceID: id, ranges: ranges), to: recipient) }
  }

  /// Pieces asked for or partly here with nothing heard for `staleAfter`.
  var hasStalePieces: Bool { !stalePieces.isEmpty }

  private var stalePieces: [UUID] {
    let now = now()
    let candidates = Set(requested.keys).union(assemblies.keys)
    return candidates.filter { id in
      guard !completed.contains(id), assemblies[id]?.isFinishing != true,
        let last = lastActivity(of: id)
      else { return false }
      return now.timeIntervalSince(last) >= Self.staleAfter
    }.sorted { $0.uuidString < $1.uuidString }
  }

  private func lastActivity(of id: UUID) -> Date? {
    [requested[id], assemblies[id]?.lastChunkAt].compactMap { $0 }.max()
  }

  /// Asks again for every stale piece (on the session's retry timer).
  func retryStale() {
    for id in stalePieces { request(id) }
  }

  /// Whether this piece came, or is coming, as chunks.
  func knows(_ id: UUID) -> Bool {
    completed.contains(id) || assemblies[id] != nil || requested[id] != nil
  }

  /// The received file could not be played: the whole piece is asked for again.
  func reload(_ id: UUID) {
    completed.remove(id)
    assemblies.removeValue(forKey: id)?.discard()
    request(id)
  }

  /// A listener with their own copy: nothing is received or asked for any more.
  func stopReceiving() {
    receivesPieces = false
    requested = [:]
    assemblies.values.forEach { $0.discard() }
    assemblies = [:]
  }

  /// The session ended: nothing more is sent or received, a waiting upload fails, partial files are
  /// deleted.
  func stop() {
    guard !stopped else { return }
    stopped = true
    pump?.cancel()
    pump = nil
    let waiting = jobs
    jobs = []
    waiting.forEach { $0.waiter?.resume(throwing: ChunkChannelError.stopped) }
    tasks.values.forEach { $0.cancel() }
    tasks = [:]
    assemblies.values.forEach { $0.discard() }
    assemblies = [:]
    requested = [:]
  }

  // MARK: Helpers

  private func sendControl(_ control: ChunkControl, to recipient: UUID?) async {
    do {
      try await send(control.encoded(), recipient)
    } catch {
      Self.logger.error(
        "Listen Together: chunk control message failed: \(ListenTogetherErrorDescription.describe(error), privacy: .public)")
    }
  }

  /// Runs `work` as a task that `stop()` cancels; it forgets itself when done.
  private func track(_ work: @escaping @MainActor () async -> Void) {
    let key = UUID()
    tasks[key] = Task { [weak self] in
      await work()
      self?.tasks[key] = nil
    }
  }
}
