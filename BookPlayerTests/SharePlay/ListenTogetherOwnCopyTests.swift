@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import CryptoKit
import XCTest

/// A transport that records whether pieces were refused (own copy) and what was sent.
@MainActor
final class OwnCopyTransport: ListenTogetherTransport {
  private var continuation: AsyncStream<TransportEvent>.Continuation!
  lazy var events: AsyncStream<TransportEvent> = AsyncStream { self.continuation = $0 }
  var sent: [ListenTogetherMessage] = []
  var uploads: [URL] = []
  var left = false
  var stoppedReceivingPieces = false
  func emit(_ event: TransportEvent) { _ = events; continuation.yield(event) }
  func send(_ message: ListenTogetherMessage) async throws { sent.append(message) }
  func upload(fileAt url: URL) async throws -> UUID { uploads.append(url); return UUID() }
  func leave() { left = true; _ = events; continuation.finish() }
  func stopReceivingPieces() { stoppedReceivingPieces = true }
}

@MainActor
final class FakeOwnCopyFinder: ListenTogetherOwnCopyFinding {
  var result: ListenTogetherOwnCopy?
  /// Simulates a slow library; the check's time limit cancels it.
  var delay: Duration?
  /// Holds the check until `release()` (no clock).
  var holdUntilReleased = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private(set) var calls = 0
  func findOwnCopy(matching fingerprint: BookFingerprint) async -> ListenTogetherOwnCopy? {
    calls += 1
    if let delay { try? await Task.sleep(for: delay) }
    if holdUntilReleased { await withCheckedContinuation { waiters.append($0) } }
    return result
  }
  func release() {
    holdUntilReleased = false
    waiters.forEach { $0.resume() }
    waiters = []
  }
}

/// Addendum 2, "Both have the book": the invitation's own-copy check, owners-only declines, playing
/// the own copy, and (critical) that no session cleanup ever deletes or moves a library file.
@MainActor
final class ListenTogetherOwnCopyTests: XCTestCase {
  private var root: URL!
  private var posted: [String] = []
  private var scheduled: [(delay: Duration, action: @MainActor () -> Void)] = []
  private var libraryFiles: [URL] = []
  private var services: [SharePlaySessionService] = []
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var finder: FakeOwnCopyFinder!
  private let pausedText = "listen_together_remote_paused".localized

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("OwnCopyTests-\(UUID())")
    posted = []
    scheduled = []
    suiteName = "OwnCopyTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    finder = FakeOwnCopyFinder()
  }

  override func tearDown() async throws {
    services.forEach { $0.end() }
    services = []
    try? FileManager.default.removeItem(at: root)
    libraryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
    libraryFiles = []
    defaults.removePersistentDomain(forName: suiteName)
  }

  private func makeService() -> SharePlaySessionService {
    let playerManager = PlayerManagerProtocolMock()
    playerManager.isPlayingPublisherReturnValue = Just(false).eraseToAnyPublisher()
    playerManager.currentSpeedPublisherReturnValue = Just(Float(1)).eraseToAnyPublisher()
    playerManager.underlyingIsPlaying = false
    playerManager.underlyingCurrentSpeed = 1
    let service = SharePlaySessionService(
      playerManager: playerManager,
      storage: ShareStorage(root: root),
      announcer: ListenTogetherAnnouncer(post: { [weak self] in self?.posted.append($0) }),
      defaults: defaults,
      ownCopyFinder: finder)
    service.schedule = { [weak self] delay, action in self?.scheduled.append((delay, action)) }
    services.append(service)
    return service
  }

  /// A real 10 s book in the library's Processed folder.
  private func makeLibraryFile(seconds: Double = 10) throws -> URL {
    let url = DataManager.getProcessedFolderURL().appendingPathComponent("OwnCopyTests-\(UUID().uuidString).m4a")
    try AudioFixture.makeM4A(seconds: seconds, at: url)
    libraryFiles.append(url)
    return url
  }

  private func ownCopy(of url: URL) throws -> ListenTogetherOwnCopy {
    let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
    return ListenTogetherOwnCopy(
      relativePath: url.lastPathComponent,
      files: [SourceFile(url: url, bookStart: 0, duration: 10, byteSize: size)],
      chapters: [SharedChapter(title: "One", start: 0, duration: 10)], duration: 10)
  }

  private func fingerprint() -> BookFingerprint {
    BookFingerprint(
      title: "T", author: "A", duration: 10,
      files: [BookFingerprint.File(bookStart: 0, duration: 10, byteSize: 1)], sampleHash: "h")
  }

  private func details(ownersOnly: Bool, fingerprint: BookFingerprint? = nil) -> ListenTogetherInvitationDetails {
    ListenTogetherInvitationDetails(
      shareID: UUID(), title: "T", author: "A", fingerprint: fingerprint ?? self.fingerprint(),
      ownersOnly: ownersOnly)
  }

  private func digest(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }

  private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Every event emitted before this has been handled once the marker's announcement is posted.
  private func flush(_ transport: OwnCopyTransport) async {
    transport.emit(.message(.action(.paused)))
    await waitUntil { self.posted.last == self.pausedText }
    XCTAssertEqual(posted.last, pausedText)
    posted.removeLast()
  }

  private func runScheduled() {
    let actions = scheduled
    scheduled = []
    actions.forEach { $0.action() }
  }

  // MARK: The invitation

  func testListenerWithTheBookIsInvitedToUseTheirCopy() async throws {
    let service = makeService()
    finder.result = try ownCopy(of: makeLibraryFile())
    await service.prepareInvitation(details(ownersOnly: false))
    XCTAssertEqual(service.state, .invitation(title: "T", author: "A"))
    XCTAssertTrue(service.invitationUsesOwnCopy)
    XCTAssertEqual(posted, [ListenTogetherAnnouncements.invitation(title: "T", author: "A")], "announced once")
  }

  func testOwnersOnlyListenerWithTheBookIsInvited() async throws {
    let service = makeService()
    finder.result = try ownCopy(of: makeLibraryFile())
    await service.prepareInvitation(details(ownersOnly: true))
    XCTAssertEqual(service.state, .invitation(title: "T", author: "A"))
    XCTAssertTrue(service.invitationUsesOwnCopy)
    XCTAssertNil(service.needsCopyNotice)
  }

  func testListenerWithoutTheBookGetsTodaysInvitationWhenTheBookIsSent() async {
    let service = makeService()
    await service.prepareInvitation(details(ownersOnly: false))
    XCTAssertEqual(service.state, .invitation(title: "T", author: "A"))
    XCTAssertFalse(service.invitationUsesOwnCopy)
    XCTAssertNil(service.needsCopyNotice)
  }

  func testOwnersOnlyWithoutTheBookShowsOnlyTheNeedsCopyAlert() async {
    let service = makeService()
    await service.prepareInvitation(details(ownersOnly: true))
    XCTAssertEqual(service.state, .idle, "no invitation sheet")
    XCTAssertEqual(posted, [], "no invitation announcement: the alert is the only speech")
    XCTAssertEqual(service.needsCopyNotice?.cause, .notFound)
    XCTAssertEqual(service.needsCopyNotice?.bookTitle, "T")
    service.acknowledgeNeedsCopyNotice()
    XCTAssertNil(service.needsCopyNotice)
  }

  func testASlowCheckIsTreatedAsNoCopy() async throws {
    let service = makeService()
    service.ownCopyCheckLimit = .milliseconds(20)
    finder.result = try ownCopy(of: makeLibraryFile())
    finder.delay = .seconds(30)
    await service.prepareInvitation(details(ownersOnly: false))
    XCTAssertEqual(service.state, .invitation(title: "T", author: "A"))
    XCTAssertFalse(service.invitationUsesOwnCopy, "the wording never changes after the sheet is up")
  }

  func testNoFingerprintNeverSearchesTheLibrary() async {
    let service = makeService()
    let plain = ListenTogetherInvitationDetails(shareID: UUID(), title: "T", author: "A", fingerprint: nil, ownersOnly: false)
    await service.prepareInvitation(plain)
    XCTAssertEqual(finder.calls, 0)
    XCTAssertEqual(service.state, .invitation(title: "T", author: "A"))
  }

  func testAnInvitationAnsweredDuringTheCheckShowsNothing() async {
    let service = makeService()
    await service.prepareInvitation(details(ownersOnly: true)) { false }
    XCTAssertEqual(service.state, .idle)
    XCTAssertNil(service.needsCopyNotice)
    XCTAssertEqual(posted, [])
  }

  // MARK: Playing the own copy

  func testJoiningWithOwnCopyPlaysAtOnceAndNeverDownloads() async throws {
    let service = makeService(), transport = OwnCopyTransport(), id = UUID()
    let url = try makeLibraryFile()
    XCTAssertTrue(service.startListening(
      with: transport, shareID: id, ownCopy: try ownCopy(of: url), title: "T", author: "A", shared: fingerprint()))

    // No "getting the book" screen: the player exists from Join, complete, nothing downloading.
    let listener = try XCTUnwrap(service.listener)
    XCTAssertTrue(transport.stoppedReceivingPieces)
    XCTAssertTrue(service.isUsingOwnCopy)
    XCTAssertEqual(service.state, .listening(participants: 1, downloaded: 1))
    XCTAssertTrue(listener.isReady(at: 5))
    XCTAssertEqual(listener.timeline.arrivedFraction, 1)
    XCTAssertEqual(listener.timeline.url(forPiece: 0), url, "played in place")
    XCTAssertEqual(listener.manifest.title, "T")
    XCTAssertEqual(service.joinedTitle, nil)

    // Exactly one announcement, after the screen change.
    XCTAssertEqual(posted, [])
    XCTAssertEqual(scheduled.count, 1)
    XCTAssertEqual(scheduled.first?.delay, SharePlaySessionService.ownCopyJoinedFallbackDelay)
    runScheduled()
    XCTAssertEqual(posted, ["listen_together_joined_own_copy".localized])
    posted = []

    // Pieces and the sharer's manifest are ignored: same player, still complete, no percent.
    let stray = root.appendingPathComponent("stray.m4a")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([1]).write(to: stray)
    let attachment = UUID()
    transport.emit(.message(.pieceUploaded(index: 0, attachmentID: attachment)))
    transport.emit(.attachmentReceived(id: attachment, url: stray))
    transport.emit(.message(.manifest(SharedBookManifest(
      shareID: id, title: "Other", author: "", duration: 10, chapters: [],
      pieces: [SharedPiece(index: 0, bookStart: 0, duration: 10, byteSize: 1)]))))
    await flush(transport)
    XCTAssertTrue(service.listener === listener)
    XCTAssertEqual(listener.timeline.url(forPiece: 0), url)
    XCTAssertEqual(service.state, .listening(participants: 1, downloaded: 1))
    XCTAssertEqual(posted, [], "no download progress, no waiting")
    XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path), "a stray piece is not placed")
  }

  func testOwnCopyEndHintSaysTheCopyIsKept() async throws {
    let service = makeService(), transport = OwnCopyTransport()
    service.startListening(with: transport, shareID: UUID(), ownCopy: try ownCopy(of: makeLibraryFile()))
    XCTAssertEqual(
      ListenTogetherStatus.endHint(for: service.state, usesOwnCopy: service.isUsingOwnCopy),
      "listen_together_end_hint_listener_own_copy".localized)
    service.end()
    XCTAssertFalse(service.isUsingOwnCopy)
  }

  // MARK: Critical safety: the library file survives every cleanup

  func testEndingKeepsTheLibraryFile() async throws {
    let service = makeService(), transport = OwnCopyTransport(), id = UUID()
    let url = try makeLibraryFile()
    let before = try digest(url)
    service.startListening(with: transport, shareID: id, ownCopy: try ownCopy(of: url))
    let sessionFolder = try ShareStorage(root: root).folder(for: id, role: .listener)
    service.end()
    XCTAssertEqual(service.state, .ended(reason: .normal))
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(try digest(url), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFolder.path), "only the session folder goes")
  }

  func testSharerEndingKeepsTheLibraryFile() async throws {
    let service = makeService(), transport = OwnCopyTransport(), id = UUID()
    let url = try makeLibraryFile()
    let before = try digest(url)
    service.startListening(with: transport, shareID: id, ownCopy: try ownCopy(of: url))
    transport.emit(.message(.sessionEnding))
    await waitUntil { service.state == .ended(reason: .normal) }
    XCTAssertEqual(service.state, .ended(reason: .normal))
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(try digest(url), before)
  }

  func testTeardownOnInvalidationKeepsTheLibraryFile() async throws {
    let service = makeService(), transport = OwnCopyTransport(), id = UUID()
    let url = try makeLibraryFile()
    let before = try digest(url)
    service.startListening(with: transport, shareID: id, ownCopy: try ownCopy(of: url))
    transport.emit(.invalidated)
    await waitUntil { service.state == .ended(reason: .normal) }
    XCTAssertFalse(service.isInSession)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(try digest(url), before)
  }

  func testLeavingForOwnBookKeepsTheLibraryFile() async throws {
    let service = makeService(), transport = OwnCopyTransport()
    let url = try makeLibraryFile()
    let before = try digest(url)
    service.startListening(with: transport, shareID: UUID(), ownCopy: try ownCopy(of: url))
    service.leaveForOwnBook(announcement: "left")
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(try digest(url), before)
  }

  func testLaunchCleanupKeepsTheLibraryFile() async throws {
    let service = makeService(), transport = OwnCopyTransport(), id = UUID()
    let url = try makeLibraryFile()
    let before = try digest(url)
    service.startListening(with: transport, shareID: id, ownCopy: try ownCopy(of: url))
    // A relaunch with a session's files still around: the launch cleanup runs.
    ShareStorage(root: root).remove(shareID: id)
    ShareStorage(root: root).cleanAll()
    ShareStorage().cleanAll()
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(try digest(url), before)
  }

  // MARK: Owners-only sharing

  func testOwnersOnlyShareUploadsNothing() async throws {
    let service = makeService(), transport = OwnCopyTransport()
    let url = try makeLibraryFile()
    let item = PlayableItem.stub(currentTime: 0, duration: 10, fileURL: url)
    await service.beginSharing(with: transport, item: item, ownersOnly: true)
    XCTAssertEqual(transport.uploads, [])
    guard case .manifest(let manifest) = transport.sent.first else { return XCTFail("no manifest") }
    XCTAssertEqual(manifest.pieces, [])
    XCTAssertEqual(service.state, .sharing(participants: 1))
  }

  func testActivityCarriesTheFingerprintAndTheSettingAtShareTime() async throws {
    let service = makeService()
    let url = try makeLibraryFile()
    let item = PlayableItem.stub(currentTime: 0, duration: 10, fileURL: url)
    let sendActivity = await service.makeActivity(shareID: UUID(), item: item)
    XCTAssertFalse(sendActivity.isOwnersOnly, "Send it for this session is the default")
    let print = try XCTUnwrap(sendActivity.fingerprint)
    XCTAssertEqual(print.title, "stub-title")
    XCTAssertEqual(print.author, "stub-author")
    XCTAssertEqual(print.files.count, 1)
    XCTAssertEqual(print.sampleHash, BookFingerprint.sampleHash(of: url))

    defaults.set(ListenTogetherSharingMode.ownersOnly.rawValue, forKey: ListenTogetherSharingMode.defaultsKey)
    let ownersActivity = await service.makeActivity(shareID: UUID(), item: item)
    XCTAssertTrue(ownersActivity.isOwnersOnly)
  }

  // MARK: Someone couldn't join

  private func startSharing(_ service: SharePlaySessionService, _ transport: OwnCopyTransport) throws {
    let item = PlayableItem.stub(currentTime: 0, duration: 10, fileURL: try makeLibraryFile())
    XCTAssertTrue(service.startSharingSession(with: transport, item: item, shareID: UUID(), ownersOnly: true))
  }

  func testADeclinerIsNeverCountedOrAnnouncedAndTheSharerHearsOneLine() async throws {
    let service = makeService(), transport = OwnCopyTransport()
    try startSharing(service, transport)
    let me = UUID(), decliner = UUID()
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    transport.emit(.participantsChanged(count: 2, ids: [me, decliner]))
    transport.emit(.participantDeclined(id: decliner))
    await flush(transport)
    XCTAssertEqual(posted, ["listen_together_declined_no_copy".localized])
    XCTAssertEqual(service.state, .sharing(participants: 1))
    runScheduled()
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    await flush(transport)
    XCTAssertEqual(posted, ["listen_together_declined_no_copy".localized], "no joined, no left")
    XCTAssertEqual(service.state, .sharing(participants: 1))
  }

  func testDeclinesAreCoalescedToOneLinePerTenSeconds() async throws {
    let service = makeService(), transport = OwnCopyTransport()
    var clock = Date(timeIntervalSince1970: 1_000)
    service.now = { clock }
    try startSharing(service, transport)
    transport.emit(.participantsChanged(count: 1, ids: [UUID()]))
    transport.emit(.participantDeclined(id: UUID()))
    transport.emit(.participantDeclined(id: UUID()))
    transport.emit(.participantDeclined(id: UUID()))
    await flush(transport)
    XCTAssertEqual(posted, ["listen_together_declined_no_copy".localized])
    clock = clock.addingTimeInterval(11)
    transport.emit(.participantDeclined(id: UUID()))
    await flush(transport)
    XCTAssertEqual(posted.count, 2)
  }

  func testSomeoneWhoStaysIsAnnouncedAfterTheConfirmationAndCounted() async throws {
    let service = makeService(), transport = OwnCopyTransport()
    try startSharing(service, transport)
    let me = UUID(), friend = UUID()
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    transport.emit(.participantsChanged(count: 2, ids: [me, friend]))
    await flush(transport)
    XCTAssertEqual(posted, [])
    XCTAssertEqual(service.state, .sharing(participants: 1), "not counted yet")
    XCTAssertEqual(scheduled.first?.delay, SharePlaySessionService.joinConfirmationDelay)
    runScheduled()
    XCTAssertEqual(posted, [ListenTogetherAnnouncements.joined()])
    XCTAssertEqual(service.state, .sharing(participants: 2))
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    await flush(transport)
    XCTAssertEqual(posted, [ListenTogetherAnnouncements.joined(), ListenTogetherAnnouncements.left()])
    XCTAssertEqual(service.state, .sharing(participants: 1))
  }

  func testSomeoneWhoLeavesBeforeTheConfirmationIsNeverAnnounced() async throws {
    let service = makeService(), transport = OwnCopyTransport()
    try startSharing(service, transport)
    let me = UUID(), brief = UUID()
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    transport.emit(.participantsChanged(count: 2, ids: [me, brief]))
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    await flush(transport)
    runScheduled()
    XCTAssertEqual(posted, [])
    XCTAssertEqual(service.state, .sharing(participants: 1))
  }

  func testListenersDoNotHearTheDeclineLine() async throws {
    let service = makeService(), transport = OwnCopyTransport()
    service.startListening(
      with: transport, shareID: UUID(), ownCopy: try ownCopy(of: makeLibraryFile()), ownersOnly: true)
    runScheduled()
    posted = []
    let me = UUID(), sharer = UUID(), decliner = UUID()
    transport.emit(.participantsChanged(count: 2, ids: [me, sharer]))
    transport.emit(.participantsChanged(count: 3, ids: [me, sharer, decliner]))
    transport.emit(.participantDeclined(id: decliner))
    transport.emit(.participantsChanged(count: 2, ids: [me, sharer]))
    await flush(transport)
    runScheduled()
    XCTAssertEqual(posted, [])
    XCTAssertEqual(service.state, .listening(participants: 2, downloaded: 1))
  }

  // MARK: Fix round 1

  /// a11y I2: the line comes ~300 ms after the player's title has VoiceOver focus, once.
  func testJoinedLineFollowsTheTitleFocusOnce() async throws {
    let service = makeService(), transport = OwnCopyTransport()
    service.startListening(with: transport, shareID: UUID(), ownCopy: try ownCopy(of: makeLibraryFile()))
    XCTAssertEqual(scheduled.map(\.delay), [SharePlaySessionService.ownCopyJoinedFallbackDelay])
    let fallback = scheduled.removeFirst()
    service.listenerTitleFocused()
    XCTAssertEqual(scheduled.map(\.delay), [SharePlaySessionService.ownCopyJoinedAfterFocusDelay])
    runScheduled()
    XCTAssertEqual(posted, ["listen_together_joined_own_copy".localized])
    fallback.action()
    service.listenerTitleFocused()
    runScheduled()
    XCTAssertEqual(posted, ["listen_together_joined_own_copy".localized], "said once")
  }

  func testJoinedLineFallsBackWhenThePlayerIsNotShown() async throws {
    let service = makeService(), transport = OwnCopyTransport()
    service.startListening(with: transport, shareID: UUID(), ownCopy: try ownCopy(of: makeLibraryFile()))
    runScheduled()
    XCTAssertEqual(posted, ["listen_together_joined_own_copy".localized])
  }

  /// a11y I3 / code M5: the decline is sent only once the alert is on screen.
  func testOwnersOnlyDeclineIsSentWhenTheAlertIsShown() async {
    let service = makeService()
    var sent = 0, abandoned = 0
    await service.prepareInvitation(
      details(ownersOnly: true),
      decline: ListenTogetherPendingDecline(send: { sent += 1 }, abandon: { abandoned += 1 }))
    XCTAssertNotNil(service.needsCopyNotice)
    XCTAssertEqual(sent, 0, "nothing is sent before the user is told")
    service.needsCopyNoticePresented()
    XCTAssertEqual(sent, 1)
    service.needsCopyNoticePresented()
    service.acknowledgeNeedsCopyNotice()
    XCTAssertEqual(sent, 1)
    XCTAssertEqual(abandoned, 0)
    XCTAssertNil(service.needsCopyNotice)
  }

  func testANewerNoticeAbandonsTheOlderPendingDecline() async {
    let service = makeService()
    var log: [String] = []
    await service.prepareInvitation(
      details(ownersOnly: true),
      decline: ListenTogetherPendingDecline(send: { log.append("send 1") }, abandon: { log.append("abandon 1") }))
    await service.prepareInvitation(
      details(ownersOnly: true),
      decline: ListenTogetherPendingDecline(send: { log.append("send 2") }, abandon: { log.append("abandon 2") }))
    service.needsCopyNoticePresented()
    XCTAssertEqual(log, ["abandon 1", "send 2"])
  }

  /// code M2: a check that ran out of time doesn't claim the book is missing.
  func testOwnersOnlyTimeoutSaysTheLibraryCouldNotBeChecked() async throws {
    let service = makeService()
    service.ownCopyCheckLimit = .milliseconds(20)
    finder.result = try ownCopy(of: makeLibraryFile())
    finder.delay = .seconds(30)
    await service.prepareInvitation(details(ownersOnly: true))
    XCTAssertEqual(service.state, .idle)
    XCTAssertEqual(service.needsCopyNotice?.cause, .checkTimedOut)
    XCTAssertEqual(posted, [])
  }

  func testOwnersOnlyWithNoMatchStillSaysNotFound() async {
    let service = makeService()
    await service.prepareInvitation(details(ownersOnly: true))
    XCTAssertEqual(service.needsCopyNotice?.cause, .notFound)
  }

  /// code M3: starting an own share during the check drops the invitation instead of overwriting
  /// "Preparing" with it (and blocking later invitations).
  func testOwnShareDuringTheCheckDropsTheInvitation() async throws {
    let service = makeService()
    finder.holdUntilReleased = true
    var abandoned = 0
    let check = Task {
      await service.prepareInvitation(
        self.details(ownersOnly: false),
        decline: ListenTogetherPendingDecline(send: {}, abandon: { abandoned += 1 }))
    }
    await waitUntil { self.finder.calls == 1 }
    let item = PlayableItem.stub(currentTime: 0, duration: 10, fileURL: try makeLibraryFile())
    XCTAssertNotNil(service.beginPreparing(item))
    finder.release()
    await check.value
    XCTAssertEqual(service.state, .preparing(title: item.title))
    XCTAssertFalse(service.invitationUsesOwnCopy)
    XCTAssertEqual(posted, [])
    XCTAssertEqual(abandoned, 1, "the invitation is left, not kept pending")
  }

  /// code M6 / a11y M1: send mode can't have decliners, so joins are announced and counted at once.
  func testSendModeAnnouncesJoinsAtOnce() async throws {
    let service = makeService(), transport = OwnCopyTransport()
    let item = PlayableItem.stub(currentTime: 0, duration: 10, fileURL: try makeLibraryFile())
    XCTAssertTrue(service.startSharingSession(with: transport, item: item, shareID: UUID(), ownersOnly: false))
    let me = UUID(), friend = UUID()
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    transport.emit(.participantsChanged(count: 2, ids: [me, friend]))
    await flush(transport)
    XCTAssertEqual(posted, [ListenTogetherAnnouncements.joined()])
    XCTAssertEqual(service.state, .sharing(participants: 2))
    XCTAssertTrue(scheduled.isEmpty)
  }

  /// code M1 / a11y M2: a decline that arrives after "Someone joined": only the decline line, the
  /// count goes back, no "left".
  func testALateDeclineFixesTheCountWithoutJoinedOrLeft() async throws {
    let service = makeService(), transport = OwnCopyTransport()
    try startSharing(service, transport)
    let me = UUID(), late = UUID()
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    transport.emit(.participantsChanged(count: 2, ids: [me, late]))
    await flush(transport)
    runScheduled()
    XCTAssertEqual(posted, [ListenTogetherAnnouncements.joined()])
    XCTAssertEqual(service.state, .sharing(participants: 2))
    posted = []
    transport.emit(.participantDeclined(id: late))
    transport.emit(.participantsChanged(count: 1, ids: [me]))
    await flush(transport)
    XCTAssertEqual(posted, ["listen_together_declined_no_copy".localized])
    XCTAssertEqual(service.state, .sharing(participants: 1))
  }

  // MARK: The library lookup

  private func simpleItem(_ url: URL?, duration: Double, lastPlayed: Date?, remote: URL? = nil) -> SimpleLibraryItem {
    SimpleLibraryItem(
      title: "stub-title", details: "stub-author", speed: 1, currentTime: 0, duration: duration,
      percentCompleted: 0, isFinished: false, relativePath: url?.lastPathComponent ?? "remote-\(UUID())",
      remoteURL: remote, artworkURL: nil, orderRank: 0, parentFolder: nil,
      originalFileName: url?.lastPathComponent ?? "remote", lastPlayDate: lastPlayed, type: .book,
      uuid: UUID().uuidString)
  }

  func testLibraryFinderPicksTheMostRecentlyPlayedMatchAndOnlyReads() async throws {
    let original = try makeLibraryFile()
    let older = DataManager.getProcessedFolderURL().appendingPathComponent("OwnCopyTests-\(UUID()).m4a")
    let recent = DataManager.getProcessedFolderURL().appendingPathComponent("OwnCopyTests-\(UUID()).m4a")
    try FileManager.default.copyItem(at: original, to: older)
    try FileManager.default.copyItem(at: original, to: recent)
    libraryFiles += [older, recent]
    let longer = try makeLibraryFile(seconds: 20)
    let sharedPrint = await SharePlaySessionService.fingerprint(
      for: PlayableItem.stub(currentTime: 0, duration: 10, fileURL: original))
    let shared = try XCTUnwrap(sharedPrint)

    let library = LibraryServiceProtocolMock()
    library.searchAllBooksQueryLimitOffsetReturnValue = [
      simpleItem(nil, duration: 10, lastPlayed: Date(), remote: URL(string: "https://example.com/book.m4a")),
      simpleItem(older, duration: 10, lastPlayed: Date(timeIntervalSince1970: 1_000)),
      simpleItem(recent, duration: 10, lastPlayed: Date(timeIntervalSince1970: 2_000)),
      simpleItem(longer, duration: 20, lastPlayed: Date()),
    ]
    let playback = PlaybackServiceProtocolMock()
    playback.getPlayableItemFromClosure = { item in
      PlayableItem.stub(
        currentTime: 0, duration: item.duration,
        fileURL: DataManager.getProcessedFolderURL().appendingPathComponent(item.relativePath))
    }
    let found = await LibraryOwnCopyFinder(libraryService: library, playbackService: playback)
      .findOwnCopy(matching: shared)
    XCTAssertEqual(found?.relativePath, recent.lastPathComponent)
    XCTAssertEqual(found?.files.map(\.url), [recent])
    // Remote and wrong-length books are never opened; nothing is written to the library.
    XCTAssertEqual(playback.getPlayableItemFromCallsCount, 2)
    XCTAssertFalse(library.setLibraryLastBookWithCalled)
    XCTAssertFalse(library.updatePlaybackTimeRelativePathTimeDateScheduleSaveCalled)
    XCTAssertFalse(playback.updatePlaybackTimeItemTimeCalled)
  }

  func testLibraryFinderFindsNothingForADifferentRecording() async throws {
    let mine = try makeLibraryFile()
    let theirs = BookFingerprint(
      title: "Other", author: "Someone", duration: 10,
      files: [BookFingerprint.File(bookStart: 0, duration: 10, byteSize: 1)], sampleHash: "not-the-same")
    let library = LibraryServiceProtocolMock()
    library.searchAllBooksQueryLimitOffsetReturnValue = [simpleItem(mine, duration: 10, lastPlayed: Date())]
    let playback = PlaybackServiceProtocolMock()
    playback.getPlayableItemFromClosure = { _ in PlayableItem.stub(currentTime: 0, duration: 10, fileURL: mine) }
    let found = await LibraryOwnCopyFinder(libraryService: library, playbackService: playback)
      .findOwnCopy(matching: theirs)
    XCTAssertNil(found)
  }
}
