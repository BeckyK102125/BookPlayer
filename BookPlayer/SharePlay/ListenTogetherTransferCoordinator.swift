import BookPlayerKit
import Foundation

/// Which way pieces travel in one session, journal or chunks (transfer fix B, fix round 1 I3). Holds
/// every decision `GroupSessionTransport` used to make inline, behind closures, so it is tested without
/// a `GroupSession`:
/// - sharer: the journal first; the failure that switches the session is not thrown, the same piece goes
///   out as chunks after the announcement; a listener's "journal unusable" switches it too (C2), and then
///   journal pieces are reported gone so `needPiece` sends them again as chunks;
/// - sharer: anyone who joins a chunk session is told the mode;
/// - listener: adopts an announced mode and asks for pieces announced before it; reports journal load
///   failures (C2) and then asks for every missing journal piece again with `needPiece`;
/// - both: `hasAttachment` and `reloadPiece` routing.
@MainActor
final class ListenTogetherTransferCoordinator: BPLogger {
  typealias JournalAdd = @MainActor (URL) async throws -> UUID
  typealias SendMessage = @MainActor (ListenTogetherMessage) async throws -> Void

  /// A listener reports the journal unusable after this many real load failures in a row.
  static let loadFailureLimit = 2

  let channel: MessengerPieceChannel
  private let journalAdd: JournalAdd
  private let sendMessage: SendMessage
  private let isAppActive: @MainActor () -> Bool

  private(set) var modeSwitch = TransportModeSwitch()
  var mode: ListenTogetherTransportMode { modeSwitch.mode }
  /// This device sends pieces (set by its first upload).
  private(set) var isUploader = false
  private var receivesPieces = true
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var stopped = false

  // Journal state, from the transport.
  private var journalIDs = Set<UUID>()
  private var hasJournalList = false
  /// Sharer: a listener can't load journal pieces; they count as gone.
  private(set) var journalUnusableForListeners = false

  // Listener.
  /// Pieces announced by `pieceUploaded`, in the order they were announced.
  private var announced: [(id: UUID, index: Int)] = []
  private var announcedBeforeChunks: [UUID] = []
  private var receivedIDs = Set<UUID>()
  private var loadFailuresInARow = 0
  private(set) var reportedJournalUnusable = false
  /// The missing journal pieces were asked for again after the sharer switched.
  private(set) var resentNeeds = false

  // Sharer roster (for late joiners in chunk mode).
  private var participantIDs = Set<UUID>()

  init(
    channel: MessengerPieceChannel,
    journalAdd: @escaping JournalAdd,
    sendMessage: @escaping SendMessage,
    isAppActive: @escaping @MainActor () -> Bool
  ) {
    self.channel = channel
    self.journalAdd = journalAdd
    self.sendMessage = sendMessage
    self.isAppActive = isAppActive
    channel.onModeAnnounced = { [weak self] mode, explicit in self?.modeAnnounced(mode, explicit: explicit) }
    channel.onJournalUnusable = { [weak self] sender in self?.listenerReportedJournalUnusable(from: sender) }
  }

  // MARK: Sharer

  /// The journal first. A failure that switches the session isn't thrown: the same piece goes out as
  /// chunks once the listeners have been told.
  func upload(fileAt url: URL) async throws -> UUID {
    isUploader = true
    if modeSwitch.mode == .journal {
      let activeAtStart = isAppActive()
      do {
        let id = try await journalAdd(url)
        modeSwitch.journalAddSucceeded()
        journalIDs.insert(id)
        return id
      } catch {
        let notSupported = TransportModeSwitch.isNotSupported(error)
        let interrupted = TransportModeSwitch.isInterruption(error, appWasActive: activeAtStart && isAppActive())
        let switched = modeSwitch.journalAddFailed(isNotSupported: notSupported, isInterruption: interrupted)
        Self.logger.error(
          "Listen Together: journal upload failed: \(ListenTogetherErrorDescription.describe(error), privacy: .public) notSupported=\(notSupported, privacy: .public) rejection=\(TransportModeSwitch.isJournalRejection(error), privacy: .public) interruption=\(interrupted, privacy: .public) switching=\(switched, privacy: .public)")
        guard switched else { throw error }
        Self.logger.info(
          "Listen Together: transport mode chunks (sharer, after \(notSupported ? "notSupported" : "\(TransportModeSwitch.failureLimit) journal failures", privacy: .public))")
        await channel.announceMode(to: nil)
      }
    }
    return try await channel.upload(fileAt: url)
  }

  /// C2: a listener can't load journal pieces. The session switches (if it hasn't) and the mode is
  /// announced again, which makes that listener ask for its missing pieces with `needPiece`.
  private func listenerReportedJournalUnusable(from sender: UUID?) {
    guard isUploader else { return }
    let switched = modeSwitch.listenerReportedJournalUnusable()
    journalUnusableForListeners = true
    Self.logger.info(
      "Listen Together: a listener can't load journal pieces; transport mode chunks (sharer, switched=\(switched, privacy: .public))")
    track { [weak self] in await self?.channel.announceMode(to: nil) }
  }

  /// The roster: in a chunk session the sharer tells anyone new the mode (`localID`: this device).
  func rosterChanged(_ ids: Set<UUID>, localID: UUID?) {
    let previous = participantIDs
    participantIDs = ids
    guard isUploader, modeSwitch.mode == .chunks else { return }
    for id in ids.subtracting(previous) where id != localID {
      track { [weak self] in await self?.channel.announceMode(to: id) }
    }
  }

  /// Sharer: whether the piece can still be had. Chunk pieces first; journal pieces count as gone once
  /// a listener said the journal is unusable.
  func hasAttachment(_ id: UUID) -> Bool? {
    if let kept = channel.hasPiece(id) { return kept }
    if journalUnusableForListeners { return false }
    return hasJournalList ? journalIDs.contains(id) : nil
  }

  // MARK: Messages and the journal (both roles)

  /// A message from the main messenger and who sent it.
  func messageReceived(_ message: ListenTogetherMessage, from sender: UUID) {
    switch message {
    case .manifest, .heartbeat:
      heardSharer(sender)
    case .pieceUploaded(let index, let id):
      heardSharer(sender)
      pieceAnnounced(id, index: index)
    default:
      break
    }
  }

  /// The journal's latest list of attachment ids.
  func journalListChanged(_ ids: Set<UUID>) {
    hasJournalList = true
    journalIDs = ids
  }

  /// Listener: a journal piece arrived.
  func journalPieceLoaded(_ id: UUID) {
    receivedIDs.insert(id)
    loadFailuresInARow = 0
  }

  /// Listener: a chunk piece arrived.
  func chunkPieceReceived(_ id: UUID) {
    receivedIDs.insert(id)
  }

  /// Listener (C2): a journal load failed. `notSupported`, or `loadFailureLimit` real failures in a
  /// row, make this phone tell the sharer the journal is unusable here.
  func journalLoadFailed(_ id: UUID, error: Error, appWasActive: Bool) {
    guard !stopped, !isUploader, receivesPieces, !resentNeeds else { return }
    let notSupported = TransportModeSwitch.isNotSupported(error)
    if !TransportModeSwitch.isInterruption(error, appWasActive: appWasActive) { loadFailuresInARow += 1 }
    guard notSupported || loadFailuresInARow >= Self.loadFailureLimit else { return }
    reportedJournalUnusable = true
    track { [weak self] in await self?.channel.reportJournalUnusable() }
  }

  /// Listener: after the sharer switched because this phone couldn't load journal pieces, failed
  /// journal loads are no longer retried (the pieces come again as chunks).
  var hasAbandonedJournal: Bool { resentNeeds }

  /// Listener: routes a reload. True when the piece is a chunk piece (the channel asks for it again);
  /// false when the caller should load it from the journal.
  func reloadChunkPiece(_ id: UUID, isJournalAttachment: Bool) -> Bool {
    guard !isJournalAttachment else { return false }
    guard channel.knows(id) || modeSwitch.mode == .chunks else { return false }
    receivedIDs.remove(id)
    channel.reload(id)
    return true
  }

  func stopReceiving() {
    receivesPieces = false
    channel.stopReceiving()
  }

  /// Stops chunk sending and receiving (End, before the share folder is deleted; leave).
  func stop() {
    stopped = true
    tasks.values.forEach { $0.cancel() }
    tasks = [:]
    channel.stop()
  }

  // MARK: Listener internals

  private func heardSharer(_ id: UUID) {
    guard !isUploader else { return }
    channel.sharerID = id
  }

  private func pieceAnnounced(_ id: UUID, index: Int) {
    guard !isUploader, receivesPieces else { return }
    if !announced.contains(where: { $0.id == id }) {
      announced.append((id, index))
      if announced.count > 1000 { announced.removeFirst() }
    }
    guard !journalIDs.contains(id) else { return }
    guard modeSwitch.mode == .chunks else {
      // Kept in case the switch is heard later (messages on two messengers have no common order).
      if !announcedBeforeChunks.contains(id) { announcedBeforeChunks.append(id) }
      if announcedBeforeChunks.count > 500 { announcedBeforeChunks.removeFirst() }
      return
    }
    channel.pieceAnnounced(id)
  }

  private func modeAnnounced(_ mode: ListenTogetherTransportMode, explicit: Bool) {
    guard !isUploader else { return }
    if modeSwitch.adopt(mode) {
      Self.logger.info("Listen Together: transport mode chunks (listener, \(explicit ? "announced by the sharer" : "chunks heard", privacy: .public))")
      let waiting = announcedBeforeChunks
      announcedBeforeChunks = []
      for id in waiting where !journalIDs.contains(id) { channel.pieceAnnounced(id) }
    }
    // C2: after this phone's report, every announcement from the sharer asks again for every piece still
    // missing, in the order they were announced (fix round 2, N1: not once, because the sharer's own
    // switch can announce before it has read the report; asking again is harmless). The sharer reports
    // journal pieces gone once it has the report, and sends them as chunks.
    guard explicit, reportedJournalUnusable, modeSwitch.mode == .chunks else { return }
    resentNeeds = true
    let missing = missingIndices()
    guard !missing.isEmpty else { return }
    Self.logger.info("Listen Together: asking again for \(missing.count, privacy: .public) pieces as chunks")
    track { [weak self] in
      for index in missing {
        do {
          try await self?.sendMessage(.needPiece(index: index))
        } catch {
          Self.logger.error(
            "Listen Together: could not ask for piece \(index, privacy: .public) again: \(ListenTogetherErrorDescription.describe(error), privacy: .public)")
        }
      }
    }
  }

  /// Announced piece indices with no copy here and none arriving, in announcement order. A piece sent
  /// again gets a new id: an index counts as here once any of its ids is.
  private func missingIndices() -> [Int] {
    var present = Set<Int>()
    for piece in announced where receivedIDs.contains(piece.id) || channel.knows(piece.id) {
      present.insert(piece.index)
    }
    var result: [Int] = []
    for piece in announced where !present.contains(piece.index) && !result.contains(piece.index) {
      result.append(piece.index)
    }
    return result
  }

  /// Runs `work` as a task that `stop()` cancels; it forgets itself when done (Minor 9). Nothing starts
  /// after `stop()` (fix round 2, N2).
  private func track(_ work: @escaping @MainActor () async -> Void) {
    guard !stopped else { return }
    let key = UUID()
    tasks[key] = Task { [weak self] in
      await work()
      self?.tasks[key] = nil
    }
  }
}
