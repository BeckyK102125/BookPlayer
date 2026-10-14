@testable import BookPlayer
import AVFoundation
import Combine
import XCTest

@MainActor
final class ListenerPlayerTests: XCTestCase {
  private var folder: URL!
  private var bag = Set<AnyCancellable>()

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("ListenerPlayerTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  override func tearDown() { try? FileManager.default.removeItem(at: folder) }

  private func manifest() -> SharedBookManifest {
    SharedBookManifest(shareID: UUID(), title: "T", author: "A", duration: 20,
                       chapters: [SharedChapter(title: "One", start: 0, duration: 20)],
                       pieces: [SharedPiece(index: 0, bookStart: 0, duration: 10, byteSize: 1),
                                SharedPiece(index: 1, bookStart: 10, duration: 10, byteSize: 1)])
  }

  private func makePiece(_ index: Int) throws -> URL {
    let url = folder.appendingPathComponent("p\(index).m4a")
    try AudioFixture.makeM4A(seconds: 10, at: url)
    return url
  }

  func testSeekToMissingPieceBeginsSuspension() throws {
    let player = ListenerPlayer(manifest: manifest())
    var needed: [Int] = []
    player.onNeedsPiece = { needed.append($0) }
    player.pieceArrived(index: 0, url: try makePiece(0))

    player.applySeek(to: 15)

    XCTAssertEqual(needed, [1])
    XCTAssertFalse(player.isReady(at: 15))
    XCTAssertTrue(player.timeline.isReady(at: 5), "the other file remains available, though not loaded")
    player.stop()
  }

  func testOnNeedsPieceIsCalledOncePerWait() async throws {
    let player = ListenerPlayer(manifest: manifest())
    defer { player.stop() }
    var needed: [Int] = []
    player.onNeedsPiece = { needed.append($0) }
    player.pieceArrived(index: 0, url: try makePiece(0))

    player.applySeek(to: 15)
    player.applySeek(to: 16)
    player.applyPlay(at: 17, rate: 1)
    player.applyPause(at: 17)
    XCTAssertEqual(needed, [1])
    XCTAssertFalse(player.isPlaying)

    // After the piece arrives the wait is over; the same piece missing later is a new wait.
    player.pieceArrived(index: 1, url: try makePiece(1))
    try await AudioFixture.waitUntil(player: player.player) { player.isReady(at: 17) }
    XCTAssertTrue(player.isReady(at: 15))
    player.applySeek(to: 2)
    player.applySeek(to: 15)
    XCTAssertEqual(needed, [1])
  }

  func testPlayInMissingPieceIsReportedAndRequestsPieceOnce() throws {
    let player = ListenerPlayer(manifest: manifest())
    var events: [LocalPlaybackEvent] = []
    var needed: [Int] = []
    player.onNeedsPiece = { needed.append($0) }
    player.localEvents.sink { events.append($0) }.store(in: &bag)

    player.userTogglePlay()

    XCTAssertFalse(player.isPlaying)
    XCTAssertEqual(events, [.played(at: 0, rate: 1)])
    XCTAssertEqual(needed, [0])
    player.stop()
  }

  func testPauseIntoMissingPieceDoesNotRequestPiece() throws {
    let player = ListenerPlayer(manifest: manifest())
    var needed: [Int] = []
    player.onNeedsPiece = { needed.append($0) }
    player.pieceArrived(index: 0, url: try makePiece(0))

    player.applyPause(at: 15)

    XCTAssertTrue(needed.isEmpty)
    XCTAssertEqual(player.bookTime, 15, accuracy: 0.001)
    player.stop()
  }

  func testUserPauseReportsRealPositionWithoutReseeking() async throws {
    let player = ListenerPlayer(manifest: manifest())
    defer { player.stop() }
    var events: [LocalPlaybackEvent] = []
    player.localEvents.sink { events.append($0) }.store(in: &bag)
    player.pieceArrived(index: 0, url: try makePiece(0))

    player.applyPlay(at: 2, rate: 1)
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    player.itemTimeProvider = { CMTime(seconds: 7, preferredTimescale: 600) }
    player.userTogglePlay()

    XCTAssertFalse(player.isPlaying)
    XCTAssertEqual(events.count, 1)
    guard case let .paused(at) = events[0] else { return XCTFail("expected paused") }
    XCTAssertEqual(at, 7, accuracy: 0.01)
    XCTAssertEqual(player.bookTime, 7, accuracy: 0.01)
  }

  func testRemoteCommandsDoNotEmitLocalEvents() throws {
    let player = ListenerPlayer(manifest: manifest())
    var events: [LocalPlaybackEvent] = []
    player.localEvents.sink { events.append($0) }.store(in: &bag)
    player.pieceArrived(index: 0, url: try makePiece(0))

    player.applyPlay(at: 2, rate: 1)
    player.applyPause(at: 3)
    XCTAssertTrue(events.isEmpty)

    player.userSkip(by: 5)
    XCTAssertEqual(events.count, 1)
    if case let .seeked(to, _) = events[0] { XCTAssertEqual(to, 8, accuracy: 0.6) } else { XCTFail() }
    player.stop()
  }

  func testAdvanceLoadsTheNextPieceByIndexAtItsOwnStart() throws {
    // Piece 0 ends one ULP before piece 1 starts.
    let seamed = SharedBookManifest(
      shareID: UUID(), title: "T", author: "A", duration: 20,
      chapters: [SharedChapter(title: "One", start: 0, duration: 20)],
      pieces: [SharedPiece(index: 0, bookStart: 0, duration: (10.0).nextDown, byteSize: 1),
               SharedPiece(index: 1, bookStart: 10, duration: 10, byteSize: 1)])
    let player = ListenerPlayer(manifest: seamed)
    var needed: [Int] = []
    player.onNeedsPiece = { needed.append($0) }
    player.pieceArrived(index: 0, url: try makePiece(0))
    player.applySeek(to: 9)

    player.advanceToNextPiece()

    XCTAssertEqual(needed, [1])
    XCTAssertEqual(player.bookTime, 10)
    player.stop()
  }

  func testUserActionsAreReportedBeforeTheyApply() throws {
    let player = ListenerPlayer(manifest: manifest())
    var log: [String] = []
    player.onNeedsPiece = { log.append("needs \($0)") }
    player.localEvents.sink { event in
      if case .seeked(let to, _) = event { log.append("seeked \(Int(to))") }
      if case .played = event { log.append("played") }
    }.store(in: &bag)

    player.userJump(to: 15)
    player.userJump(to: 2)
    player.userTogglePlay()

    XCTAssertEqual(log, ["seeked 15", "needs 1", "seeked 2", "needs 0", "played"])
    player.stop()
  }

  func testApplyRateSetsSpeedWithoutReporting() {
    let player = ListenerPlayer(manifest: manifest())
    var events: [LocalPlaybackEvent] = []
    player.localEvents.sink { events.append($0) }.store(in: &bag)

    player.applyRate(1.5)

    XCTAssertEqual(player.rate, 1.5)
    XCTAssertTrue(events.isEmpty)
    player.stop()
  }

  /// Minor (fix wave 2): the group is playing but held for this device's piece. Play/pause then sends
  /// nothing to the others (no pause to the group) and asks the service to say we are waiting.
  func testToggleWhileHeldForAPieceSendsNothing() {
    let player = ListenerPlayer(manifest: manifest())
    var events: [LocalPlaybackEvent] = []
    var waitingToggles = 0
    player.onToggleWhileWaiting = { waitingToggles += 1 }
    player.localEvents.sink { events.append($0) }.store(in: &bag)

    player.applyPlay(at: 0, rate: 1)          // the group plays; piece 0 is missing
    XCTAssertTrue(player.isWaitingForPiece)

    player.userTogglePlay()
    player.userTogglePlay()

    XCTAssertTrue(events.isEmpty, "nothing is sent to the group")
    XCTAssertEqual(waitingToggles, 2)
    XCTAssertFalse(player.isPlaying)
    player.stop()
  }

  /// R14 still holds after a paused seek into a missing piece: Play starts the group (held for us).
  func testPlayAfterAPausedSeekIntoAMissingPieceIsStillSent() {
    let player = ListenerPlayer(manifest: manifest())
    var events: [LocalPlaybackEvent] = []
    var waitingToggles = 0
    player.onToggleWhileWaiting = { waitingToggles += 1 }
    player.localEvents.sink { events.append($0) }.store(in: &bag)

    player.applySeek(to: 2)                   // paused; piece 0 is missing
    XCTAssertTrue(player.isWaitingForPiece)
    player.userTogglePlay()

    XCTAssertEqual(events, [.played(at: 2, rate: 1)])
    XCTAssertEqual(waitingToggles, 0)
    player.stop()
  }

  // MARK: Seamless joins (addendum 3, decision 4)

  private func threePieces() -> SharedBookManifest {
    SharedBookManifest(shareID: UUID(), title: "T", author: "A", duration: 30,
                       chapters: [SharedChapter(title: "One", start: 0, duration: 30)],
                       pieces: (0..<3).map { SharedPiece(index: $0, bookStart: Double($0) * 10, duration: 10, byteSize: 1) })
  }

  func testTheNextArrivedPieceIsQueuedBehindTheCurrentOne() throws {
    let player = ListenerPlayer(manifest: threePieces())
    player.pieceArrived(index: 0, url: try makePiece(0))
    player.pieceArrived(index: 1, url: try makePiece(1))
    player.applySeek(to: 2)
    XCTAssertEqual(player.queuedPieceIndex, 1)
    player.stop()
  }

  func testAPieceArrivingWhileThePreviousOneIsLoadedIsQueuedAtOnce() throws {
    let player = ListenerPlayer(manifest: threePieces())
    player.pieceArrived(index: 0, url: try makePiece(0))
    player.applySeek(to: 2)
    XCTAssertNil(player.queuedPieceIndex, "piece 1 is not here yet")
    player.pieceArrived(index: 2, url: try makePiece(2))
    XCTAssertNil(player.queuedPieceIndex, "only the very next piece is queued")
    player.pieceArrived(index: 1, url: try makePiece(1))
    XCTAssertEqual(player.queuedPieceIndex, 1)
    player.stop()
  }

  func testSeekIntoAnotherPieceRebuildsTheQueue() throws {
    let player = ListenerPlayer(manifest: threePieces())
    for index in 0..<3 { player.pieceArrived(index: index, url: try makePiece(index)) }
    player.applySeek(to: 2)
    XCTAssertEqual(player.queuedPieceIndex, 1)
    player.applySeek(to: 25)
    XCTAssertNil(player.queuedPieceIndex, "the last piece has nothing after it")
    player.applySeek(to: 12)
    XCTAssertEqual(player.queuedPieceIndex, 2)
    player.stop()
  }

  func testWhatHappensWhenAPieceEnds() {
    var timeline = PieceTimeline(pieces: threePieces().pieces)
    timeline.markArrived(index: 0, url: URL(fileURLWithPath: "/tmp/p0.m4a"))
    XCTAssertEqual(ListenerPlayer.decisionAtEnd(of: 0, queued: 1, timeline: timeline), .queuedNextPlays(1))
    XCTAssertEqual(ListenerPlayer.decisionAtEnd(of: 0, queued: nil, timeline: timeline), .waitForNext(1))
    XCTAssertEqual(ListenerPlayer.decisionAtEnd(of: 2, queued: nil, timeline: timeline), .endOfBook)
  }

  func testBookTimeFollowsTheQueueAcrossTheBoundary() async throws {
    let player = ListenerPlayer(manifest: threePieces())
    defer { player.stop() }
    var events: [LocalPlaybackEvent] = []
    player.localEvents.sink { events.append($0) }.store(in: &bag)
    for index in 0..<3 { player.pieceArrived(index: index, url: try makePiece(index)) }
    player.applyPlay(at: 8, rate: 1)
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    player.queueAdvancedForTesting()            // piece 0 played out; the queue moved to piece 1
    XCTAssertEqual(player.queuedPieceIndex, 2, "the piece after it is queued in turn")
    try await AudioFixture.waitUntil(player: player.player) { player.isReady(at: 10) }
    player.itemTimeProvider = { CMTime(seconds: 3, preferredTimescale: 600) }
    player.userTogglePlay()
    guard case let .paused(at)? = events.last else { return XCTFail("expected paused") }
    XCTAssertEqual(at, 13, accuracy: 0.01)
    player.applySeek(to: 15)                    // a coordinator seek inside the queued-in piece
    XCTAssertEqual(player.bookTime, 15, accuracy: 0.001)
    XCTAssertEqual(player.queuedPieceIndex, 2)
  }

  func testALoadAtAnArrivedPieceReportsThatThePositionIsReady() async throws {
    let player = ListenerPlayer(manifest: threePieces())
    defer { player.stop() }
    var ready = 0
    player.onPositionReady = { ready += 1 }
    player.applySeek(to: 15)
    XCTAssertEqual(ready, 0)
    player.pieceArrived(index: 1, url: try makePiece(1))   // the awaited piece: loaded in place
    XCTAssertEqual(ready, 0, "arrival alone is not readiness")
    try await AudioFixture.waitUntil { ready > 0 && player.isReady(at: 15) }
    let previous = ready
    player.applySeek(to: 16)
    XCTAssertEqual(ready, previous, "readiness waits for the new seek")
    try await AudioFixture.waitUntil { ready > previous && player.isReady(at: 16) }
    XCTAssertEqual(player.player.currentTime().seconds, 6, accuracy: 0.1)
  }

  // MARK: Fix round 1: a piece that can't be played

  func testAFailedLoadedPieceIsForgottenAndAwaited() throws {
    let player = ListenerPlayer(manifest: threePieces())
    var needed: [Int] = []
    var failed: [Int] = []
    player.onNeedsPiece = { needed.append($0) }
    player.onPieceFailed = { failed.append($0) }
    player.pieceArrived(index: 0, url: try makePiece(0))
    player.pieceArrived(index: 1, url: try makePiece(1))
    player.applySeek(to: 2)
    player.pieceFailed(index: 0)
    XCTAssertEqual(failed, [0])
    XCTAssertFalse(player.isReady(at: 2))
    XCTAssertEqual(needed, [0], "the group waits for it again")
    XCTAssertTrue(player.isWaitingForPiece)
    player.stop()
  }

  func testAFailedQueuedPieceLeavesTheQueue() async throws {
    let player = ListenerPlayer(manifest: threePieces())
    defer { player.stop() }
    var needed: [Int] = []
    player.onNeedsPiece = { needed.append($0) }
    player.pieceArrived(index: 0, url: try makePiece(0))
    player.pieceArrived(index: 1, url: try makePiece(1))
    player.applySeek(to: 2)
    try await AudioFixture.waitUntil(player: player.player) { player.isReady(at: 2) }
    XCTAssertEqual(player.queuedPieceIndex, 1)
    player.pieceFailed(index: 1)
    XCTAssertNil(player.queuedPieceIndex)
    XCTAssertTrue(needed.isEmpty, "not needed yet: piece 0 still plays")
    XCTAssertTrue(player.isReady(at: 2))
  }
  // MARK: Playback recovery

  func testExplicitPauseDuringCoordinatorBufferingCancelsPendingPlaybackOnce() {
    let player = ListenerPlayer(manifest: manifest())
    let control = RecoveryCoordinatorControl()
    let bridge = ListenTogetherCoordinatorBridge(target: player, shareID: player.manifest.shareID, control: control)
    defer { bridge.invalidate(); player.stop() }
    var requests: [Int] = []
    player.onNeedsPiece = { [weak bridge] index in
      requests.append(index)
      bridge?.waitForPiece()
    }
    player.onBufferingNeeded = { [weak bridge] in bridge?.waitForPiece() }
    bridge.start(session: nil)
    bridge.handlePlay(itemTime: 2, rate: 1)
    bridge.handlePause(itemTime: 2, shouldBuffer: true)
    XCTAssertFalse(player.isPlaying)
    XCTAssertEqual(control.activeHolds, 1)

    player.userPause()
    XCTAssertEqual(control.rates, [0], "an explicit Pause must reach the group while recovery is pending")
    XCTAssertEqual(control.holdsWhenRateChanged, [0], "release the local stall before proposing the group Pause")
    XCTAssertFalse(player.isPlayingForGroup)
    player.userPause()
    XCTAssertEqual(control.rates, [0], "repeated Pause remains idempotent")
    XCTAssertEqual(control.activeHolds, 0)
    player.userPlay()
    XCTAssertEqual(control.rates, [0, 1], "a fresh Play is allowed after cancellation")
    XCTAssertEqual(control.activeHolds, 1, "the same missing file needs a renewed hold")
    XCTAssertEqual(requests, [0], "resuming must not duplicate the transfer request")
  }

  func testExplicitPauseDuringBufferingStaysPausedUntilLaterGroupPlay() async throws {
    let (player, bridge, control) = try recoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    bridge.handlePlay(itemTime: 2, rate: 1)
    bridge.handlePause(itemTime: 2, shouldBuffer: true)
    player.userPause()
    try await AudioFixture.waitUntil(player: player.player) { player.isReady(at: 2) }
    XCTAssertFalse(player.isPlaying)
    XCTAssertFalse(player.isPlayingForGroup)
    XCTAssertEqual(control.activeHolds, 0)
    XCTAssertEqual(control.rates, [0])

    bridge.handlePlay(itemTime: 2, rate: 1)
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    XCTAssertEqual(control.activeHolds, 0)
  }

  private func drainNotifications() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  private func interrupt(_ type: AVAudioSession.InterruptionType, resume: Bool = false) async throws {
    NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
      AVAudioSessionInterruptionTypeKey: type.rawValue,
      AVAudioSessionInterruptionOptionKey: resume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0,
    ])
    await drainNotifications()
    if type == .began {
      // A real interruption deactivates the audio session. After the synthetic notification has
      // paused the player, reproduce that system state so resume tests exercise reactivation and
      // stopping during interruption cannot leave an active session for the next test.
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  private func recoveryPlayer() throws -> (ListenerPlayer, ListenTogetherCoordinatorBridge, RecoveryCoordinatorControl) {
    let player = ListenerPlayer(manifest: manifest())
    player.player.volume = 0
    player.pieceArrived(index: 0, url: try makePiece(0))
    let control = RecoveryCoordinatorControl()
    let bridge = ListenTogetherCoordinatorBridge(target: player, shareID: player.manifest.shareID, control: control)
    player.onBufferingNeeded = { [weak bridge] in bridge?.waitForPiece() }
    player.onPositionReady = { [weak bridge] in bridge?.pieceBecameAvailable() }
    player.onInterruptionBegan = { [weak bridge] in bridge?.holdForInterruption() }
    player.onInterruptionEnded = { [weak bridge] in bridge?.releaseInterruptionHold() }
    bridge.start(session: nil)
    return (player, bridge, control)
  }

  func testTemporaryInterruptionReappliesGroupPlaybackWithoutSendingPause() async throws {
    let (player, bridge, control) = try recoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    var events: [LocalPlaybackEvent] = []
    player.localEvents.sink { events.append($0) }.store(in: &bag)
    bridge.handlePlay(itemTime: 2, rate: 1)
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    control.reapply = { [weak bridge] in bridge?.handlePlay(itemTime: 2, rate: 1) }
    let before = control.activeHolds
    try await interrupt(.began)
    XCTAssertFalse(player.isPlaying)
    XCTAssertEqual(control.activeHolds, before + 1)
    XCTAssertTrue(events.isEmpty)
    try await interrupt(.ended, resume: true)
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    XCTAssertEqual(control.reapplications, 1)
    XCTAssertEqual(control.activeHolds, 0)
    XCTAssertTrue(control.rates.isEmpty, "recovery adopts group state, never sends unconditional Play")
  }

  func testInterruptionRecoveryAdoptsAGroupPause() async throws {
    let (player, bridge, control) = try recoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    bridge.handlePlay(itemTime: 2, rate: 1)
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    try await interrupt(.began)
    control.reapply = { [weak bridge] in bridge?.handlePause(itemTime: 2) }
    try await interrupt(.ended, resume: true)
    XCTAssertEqual(control.reapplications, 1)
    XCTAssertFalse(player.isPlayingForGroup)
    XCTAssertFalse(player.isPlaying)
    XCTAssertTrue(control.rates.isEmpty)
  }

  func testInterruptionWithoutResumePermissionRequiresExplicitPlay() async throws {
    let (player, bridge, control) = try recoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    bridge.handlePlay(itemTime: 2, rate: 1)
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    try await interrupt(.began)
    try await interrupt(.ended)
    XCTAssertEqual(control.reapplications, 0)
    XCTAssertEqual(control.activeHolds, 1)
    XCTAssertFalse(player.isPlaying)
    player.userTogglePlay()
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    XCTAssertEqual(control.activeHolds, 0)
    XCTAssertEqual(control.rates.last, 1)
  }

  func testExplicitPauseDuringInterruptionPreventsDelayedRestart() async throws {
    let (player, bridge, control) = try recoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    bridge.handlePlay(itemTime: 2, rate: 1)
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    try await interrupt(.began)
    player.userPause()
    let reapplications = control.reapplications
    try await interrupt(.ended, resume: true)
    XCTAssertEqual(control.reapplications, reapplications)
    XCTAssertEqual(control.rates.last, 0)
    bridge.handlePlay(itemTime: 2, rate: 1) // delayed coordinator command must not override consent
    try await AudioFixture.waitUntil(player: player.player) { player.isReady(at: 2) }
    XCTAssertFalse(player.isPlaying)
    player.userPause() // repeated Pause must not clear the explicit-resume requirement
    bridge.handlePlay(itemTime: 2, rate: 1)
    await drainNotifications()
    XCTAssertFalse(player.isPlaying)
    player.userTogglePlay()
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    XCTAssertEqual(control.rates.last, 1)
  }

  func testHeadphoneRemovalRequiresPlayEvenAfterDelayedGroupCommand() async throws {
    let (player, bridge, control) = try recoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    bridge.handlePlay(itemTime: 2, rate: 1)
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
      userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
    await drainNotifications()
    XCTAssertFalse(player.isPlaying)
    XCTAssertEqual(control.rates.last, 0)
    bridge.handlePlay(itemTime: 2, rate: 1)
    try await AudioFixture.waitUntil(player: player.player) { player.isReady(at: 2) }
    XCTAssertFalse(player.isPlaying)
    player.userTogglePlay()
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    XCTAssertEqual(control.rates.last, 1)
  }

  func testStoppingDuringInterruptionDiscardsLaterRecovery() async throws {
    let (player, bridge, control) = try recoveryPlayer()
    bridge.handlePlay(itemTime: 2, rate: 1)
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    try await interrupt(.began)
    bridge.invalidate()
    player.stop()
    XCTAssertEqual(control.activeHolds, 0)
    try await interrupt(.ended, resume: true)
    bridge.handlePlay(itemTime: 2, rate: 1)
    player.applyPlay(at: 2, rate: 1)
    XCTAssertEqual(control.reapplications, 0)
    XCTAssertNil(player.player.currentItem)
    XCTAssertFalse(player.isPlaying)
  }

  func testFailedToEndNotificationRecoversOnceAndIgnoresDiscardedItem() async throws {
    let player = ListenerPlayer(manifest: manifest())
    defer { player.stop() }
    let file = try makePiece(0)
    player.pieceArrived(index: 0, url: file)
    player.applySeek(to: 4)
    try await AudioFixture.waitUntil(player: player.player) { player.isReady(at: 4) }
    let item = try XCTUnwrap(player.player.currentItem)
    var failures: [Int] = []
    player.onPieceFailed = { failures.append($0) }
    for _ in 0..<2 {
      NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
    }
    await drainNotifications()
    XCTAssertEqual(failures, [0])
    XCTAssertTrue(player.isWaitingForPiece)
    XCTAssertFalse(player.isReady(at: 4))
    XCTAssertEqual(player.bookTime, 4, accuracy: 0.1)
    player.pieceArrived(index: 0, url: file)
    try await AudioFixture.waitUntil(player: player.player) { player.isReady(at: 4) }
    NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
    await drainNotifications()
    XCTAssertEqual(failures, [0])
    XCTAssertTrue(player.isReady(at: 4))
  }

  func testLatestSeekBecomesReadyAndStopCancelsPendingReadiness() async throws {
    let player = ListenerPlayer(manifest: manifest())
    defer { player.stop() }
    player.pieceArrived(index: 0, url: try makePiece(0))
    XCTAssertFalse(player.isReady(at: 2), "an arrived URL is not a prepared player")
    player.applySeek(to: 2)
    XCTAssertFalse(player.isReady(at: 2))
    player.applySeek(to: 8)
    try await AudioFixture.waitUntil(player: player.player) { player.isReady(at: 8) }
    XCTAssertEqual(player.player.currentTime().seconds, 8, accuracy: 0.1)
    var readyAfterStop = false
    player.onPositionReady = { readyAfterStop = true }
    player.applySeek(to: 3)
    player.stop()
    await drainNotifications()
    XCTAssertFalse(readyAfterStop)
    XCTAssertFalse(player.isReady(at: 3))
    XCTAssertNil(player.player.currentItem)
  }

  func testSpeedChangeDuringPreparationIsCoordinated() throws {
    let (player, bridge, control) = try recoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    bridge.handlePlay(itemTime: 2, rate: 1)
    XCTAssertFalse(player.isPlaying)
    player.userSetRate(1.5)
    XCTAssertEqual(control.rates.last, 1.5)
    XCTAssertEqual(player.rate, 1.5)
  }

}

/// Test-only: the current piece played out and the queue moved to the queued one.
extension ListenerPlayer {
  func queueAdvancedForTesting() {
    player.advanceToNextItem()
    queueAdvanced()
  }
}



@MainActor
private final class RecoveryCoordinatorControl: ListenTogetherCoordinatorControlling {
  var activeHolds = 0
  var rates: [Float] = []
  var holdsWhenRateChanged: [Int] = []
  var reapplications = 0
  var reapply: (() -> Void)?
  func coordinateRateChange(to rate: Float) {
    rates.append(rate)
    holdsWhenRateChanged.append(activeHolds)
  }
  func coordinateSeek(to bookTime: TimeInterval) {}
  func beginStallSuspension() -> () -> Void {
    activeHolds += 1
    return { [weak self] in self?.activeHolds -= 1 }
  }
  func transitionToItem(withIdentifier identifier: String?, proposingTime time: TimeInterval?, rate: Float) {}
  func reapplyCurrentItemState() {
    reapplications += 1
    reapply?()
  }
}
