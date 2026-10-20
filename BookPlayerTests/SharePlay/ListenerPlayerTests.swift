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
    player.onBufferingNeeded = { [weak bridge] in bridge?.waitForReadiness() }
    player.onPieceWaitReopened = { [weak bridge] in bridge?.waitForPiece() }
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

  /// A player with a controllable clock and audio-session activation (no shared-session changes in
  /// these tests, I5), wired to a bridge like the service wires it.
  private func recoveryPlayer() throws -> (ListenerPlayer, ListenTogetherCoordinatorBridge, RecoveryCoordinatorControl) {
    let player = ListenerPlayer(manifest: manifest())
    player.player.volume = 0
    player.now = { [unowned self] in self.clock }
    player.schedule = { [unowned self] _, work in self.timers.append(work) }
    // Code M12: these tests never activate the shared audio session.
    player.activateSession = { true }
    player.pieceArrived(index: 0, url: try makePiece(0))
    let control = RecoveryCoordinatorControl()
    let bridge = ListenTogetherCoordinatorBridge(target: player, shareID: player.manifest.shareID, control: control)
    player.onBufferingNeeded = { [weak bridge] in bridge?.waitForReadiness() }
    player.onPieceWaitReopened = { [weak bridge] in bridge?.waitForPiece() }
    player.onPositionReady = { [weak bridge] in bridge?.pieceBecameAvailable() }
    player.onLocalStopBegan = { [weak bridge] in bridge?.beginLocalStop() }
    player.onLocalStopEnded = { [weak bridge] in bridge?.endLocalStopAndRejoin() }
    player.onActionWhileStoppedHere = { [unowned self] in self.refusedWhileStopped += 1 }
    bridge.start(session: nil)
    return (player, bridge, control)
  }

  private var clock = Date(timeIntervalSince1970: 1_000)
  private var refusedWhileStopped = 0
  private var timers: [() -> Void] = []
  private func runTimers() {
    let due = timers
    timers = []
    due.forEach { $0() }
  }

  private func playingRecoveryPlayer() async throws
    -> (ListenerPlayer, ListenTogetherCoordinatorBridge, RecoveryCoordinatorControl, () -> [LocalPlaybackEvent]) {
    let (player, bridge, control) = try recoveryPlayer()
    var events: [LocalPlaybackEvent] = []
    player.localEvents.sink { events.append($0) }.store(in: &bag)
    bridge.handlePlay(itemTime: 2, rate: 1)
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    return (player, bridge, control, { events })
  }

  // MARK: Option 1 (Becky, build 6 fix round 1): the group never waits for one listener's interruption

  // Fix round 2 (F4): a real coordinator suppresses commands during the local suspension and re-issues
  // the group's state only after it ends, asynchronously. These tests never deliver a command while
  // stopped here, and deliver the "reapplied" state by hand afterwards.

  func testAnInterruptionStopsOnlyThisPhoneAndItRejoinsAtTheGroupsCurrentPlace() async throws {
    let (player, bridge, control, events) = try await playingRecoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    player.handleInterruption(.began, shouldResume: false)
    XCTAssertFalse(player.isPlaying)
    XCTAssertEqual(player.localStop, .interrupted)
    XCTAssertEqual(control.activeHolds, 0, "nobody waits")
    XCTAssertEqual(control.localHolds, 1, "the coordinator stops driving this phone only")
    XCTAssertTrue(events().isEmpty, "the others hear nothing")
    var progress: [TimeInterval] = []
    player.onProgressChanged = { time, _ in progress.append(time) }
    let stoppedAt = player.bookTime
    player.handleInterruption(.ended, shouldResume: true)
    XCTAssertNil(player.localStop)
    XCTAssertEqual(control.localHolds, 0)
    XCTAssertEqual(control.reapplications, 1, "the coordinator is asked for the group's state")
    XCTAssertFalse(player.isPlayingForGroup, "no audio before the group's own state arrives")
    XCTAssertEqual(player.bookTime, stoppedAt, accuracy: 0.01)
    XCTAssertTrue(progress.isEmpty, "no progress saved from a cached place")
    bridge.handlePlay(itemTime: 5, rate: 1)   // the reapplied state, delivered later
    XCTAssertEqual(player.bookTime, 5, accuracy: 0.05)
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    XCTAssertTrue(control.rates.isEmpty, "never sends Play or Pause to the group")
    XCTAssertTrue(events().isEmpty)
  }

  func testRejoiningUsesTheGroupsStateNotTheLastPlaceSeenBeforeAGroupSeek() async throws {
    let (player, bridge, _, _) = try await playingRecoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    bridge.handleSeek(itemTime: 8)            // the group moved on from 2 before the interruption
    player.handleInterruption(.began, shouldResume: false)
    clock = clock.addingTimeInterval(1)
    player.handleInterruption(.ended, shouldResume: true)
    XCTAssertGreaterThan(player.bookTime, 7.5, "never back to the old play's place (2 s + elapsed)")
    XCTAssertFalse(player.isPlayingForGroup)
    bridge.handlePlay(itemTime: 9, rate: 1)
    XCTAssertEqual(player.bookTime, 9, accuracy: 0.05)
    XCTAssertTrue(player.isPlayingForGroup)
  }

  func testPlayWhileStoppedHereStartsAGroupThatPausedMeanwhile() async throws {
    let (player, bridge, control, events) = try await playingRecoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    player.activateSession = { true }
    player.handleInterruption(.began, shouldResume: false)
    // The group paused meanwhile; the suspended coordinator never told this phone.
    player.userTogglePlay()
    XCTAssertFalse(player.isPlayingForGroup, "waits for the group's state")
    XCTAssertTrue(events().isEmpty)
    bridge.handlePause(itemTime: 6)            // the reapplied state: paused at 6
    XCTAssertEqual(events(), [.played(at: 6, rate: 1)], "Play starts the paused group, as any Play does")
    XCTAssertEqual(control.rates, [1])
    XCTAssertTrue(player.isPlayingForGroup)
  }

  func testTheInterruptionEndingWhileTheGroupPausedMeanwhileStaysPaused() async throws {
    let (player, bridge, control, events) = try await playingRecoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    player.activateSession = { true }
    player.handleInterruption(.began, shouldResume: false)
    player.handleInterruption(.ended, shouldResume: true)
    bridge.handlePause(itemTime: 6)
    XCTAssertFalse(player.isPlayingForGroup, "never restarts a group that paused")
    XCTAssertTrue(events().isEmpty)
    XCTAssertTrue(control.rates.isEmpty)
  }

  func testARejoinThatGetsNoGroupStateAsksForPlayAgain() async throws {
    let (player, bridge, control, _) = try await playingRecoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    player.activateSession = { true }
    player.handleInterruption(.began, shouldResume: false)
    player.handleInterruption(.ended, shouldResume: true)
    XCTAssertNil(player.localStop)
    runTimers()
    XCTAssertEqual(player.localStop, .needsPlay, "visible again: Play tries once more")
    XCTAssertEqual(control.localHolds, 1)
  }

  // MARK: Fix round 3: the rejoin window (code I1, M3, M4; a11y M1-M3)

  /// Stopped by an interruption that then ended: the phone is waiting for the group's state.
  private func rejoiningPlayer() async throws
    -> (ListenerPlayer, ListenTogetherCoordinatorBridge, RecoveryCoordinatorControl, () -> [LocalPlaybackEvent], () -> Int) {
    let (player, bridge, control, events) = try await playingRecoveryPlayer()
    player.handleInterruption(.began, shouldResume: false)
    player.handleInterruption(.ended, shouldResume: true)
    var progress = 0
    player.onProgressChanged = { _, _ in progress += 1 }
    XCTAssertTrue(player.isRejoining)
    return (player, bridge, control, events, { progress })
  }

  func testPlayWhileRejoiningLoadsSavesAndSendsNothing() async throws {
    let (player, bridge, control, events, progress) = try await rejoiningPlayer()
    defer { bridge.invalidate(); player.stop() }
    let item = player.player.currentItem
    player.userTogglePlay()
    player.userPlay()
    XCTAssertTrue(events().isEmpty, "nothing sent from the cached place")
    XCTAssertEqual(progress(), 0, "nothing saved")
    XCTAssertTrue(player.player.currentItem === item, "nothing loaded")
    XCTAssertFalse(player.isPlayingForGroup)
    bridge.handlePause(itemTime: 6)   // the group's state: paused; the press means "start it"
    XCTAssertEqual(events(), [.played(at: 6, rate: 1)])
    XCTAssertEqual(control.rates, [1])
  }

  func testSkipsAndSpeedWhileRejoiningAreRefused() async throws {
    let (player, bridge, control, events, _) = try await rejoiningPlayer()
    defer { bridge.invalidate(); player.stop() }
    player.userSkip(by: 30)
    player.userJump(to: 1)
    player.userSetRate(1.5)
    XCTAssertEqual(refusedWhileStopped, 3, "each says why")
    XCTAssertTrue(events().isEmpty, "the group is never moved from the cached place")
    XCTAssertTrue(control.rates.isEmpty)
  }

  func testPauseWhileRejoiningCancelsItAndPausesTheGroup() async throws {
    let (player, bridge, control, events, _) = try await rejoiningPlayer()
    defer { bridge.invalidate(); player.stop() }
    player.userPause()
    XCTAssertFalse(player.isRejoining)
    XCTAssertEqual(control.rates, [0], "the group pauses")
    XCTAssertEqual(events().count, 1)
    bridge.handlePlay(itemTime: 6, rate: 1)   // the pause overtaken by an older play: plays normally
    XCTAssertTrue(player.isPlayingForGroup)
    runTimers()
    XCTAssertNil(player.localStop, "no 'Press Play' after a cancelled rejoin")
  }

  func testTheRejoinWindowKeepsAStatus() async throws {
    let (player, bridge, _, _, _) = try await rejoiningPlayer()
    defer { bridge.invalidate(); player.stop() }
    XCTAssertEqual(player.displayedStop.stop, .rejoining, "visible while waiting (a11y M2)")
    bridge.handlePlay(itemTime: 6, rate: 1)
    XCTAssertNil(player.displayedStop.stop)
  }

  func testABufferingPauseIsTheGroupsStateToo() async throws {
    let (player, bridge, _, _, _) = try await rejoiningPlayer()
    defer { bridge.invalidate(); player.stop() }
    bridge.handlePause(itemTime: 6, shouldBuffer: true)
    XCTAssertFalse(player.isRejoining)
    runTimers()
    XCTAssertNil(player.localStop, "code M3: never dropped to Press Play after the group's state came")
    bridge.handlePlay(itemTime: 6, rate: 1)
    XCTAssertTrue(player.isPlayingForGroup)
  }

  func testAFailedAutomaticRejoinGivesOneCorrectStatus() async throws {
    let (player, bridge, _, _) = try await playingRecoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    player.activateSession = { false }
    player.handleInterruption(.began, shouldResume: false)
    player.handleInterruption(.ended, shouldResume: true)
    XCTAssertEqual(player.localStop, .needsPlay)
    XCTAssertEqual(refusedWhileStopped, 0, "a11y M1: no 'will continue' before 'Press Play'")
    XCTAssertTrue(player.displayedStop.announces)
  }

  func testOwnPauseDuringAnInterruptionChangesTheStatusSilently() async throws {
    let (player, bridge, _, _) = try await playingRecoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    player.handleInterruption(.began, shouldResume: false)
    XCTAssertEqual(player.displayedStop, ListenTogetherLocalStopState(stop: .interrupted, announces: true))
    player.userPause()
    XCTAssertEqual(player.displayedStop, ListenTogetherLocalStopState(stop: .needsPlay, announces: false),
                   "a11y M3: the person's own action is not announced")
  }

  func testAMissingEndNeverHoldsTheGroupAndPlayWorksOnceIOSAllows() async throws {
    let (player, bridge, control, events) = try await playingRecoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    var activation = false
    player.activateSession = { activation }
    player.handleInterruption(.began, shouldResume: false)
    // No `.ended` ever comes (another app kept the audio). The suspended coordinator sends nothing.
    XCTAssertEqual(control.activeHolds, 0, "never a wait for this phone")
    XCTAssertFalse(player.isPlaying)
    player.userTogglePlay()
    XCTAssertEqual(refusedWhileStopped, 1, "Play can't start the audio yet: the status is said again")
    XCTAssertEqual(player.localStop, .interrupted)
    player.userSkip(by: 30)
    XCTAssertEqual(refusedWhileStopped, 2, "a skip would move the group for a phone that isn't listening")
    activation = true
    player.userTogglePlay()
    XCTAssertNil(player.localStop)
    XCTAssertEqual(control.reapplications, 1)
    bridge.handlePlay(itemTime: 8, rate: 1)
    XCTAssertEqual(player.bookTime, 8, accuracy: 0.05)
    XCTAssertTrue(events().isEmpty, "rejoining a playing group sends nothing")
  }

  func testAStaleInterruptionFromASuspendedAppIsIgnored() async throws {
    let (player, bridge, control, _) = try await playingRecoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    player.handleInterruption(.began, shouldResume: false, wasSuspended: true)
    XCTAssertNil(player.localStop)
    XCTAssertTrue(player.isPlayingForGroup)
    XCTAssertEqual(control.localHolds, 0)
    XCTAssertTrue(player.isPlaying)
  }

  func testAnInterruptionWhileTheGroupIsPausedHoldsNobodyUntilTheGroupPlays() throws {
    let (player, bridge, control) = try recoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    player.activateSession = { true }
    player.handleInterruption(.began, shouldResume: false)
    XCTAssertNil(player.localStop, "nothing is missed while the group is paused")
    XCTAssertEqual(control.localHolds, 0)
    bridge.handlePlay(itemTime: 2, rate: 1)   // arrives before this phone is suspended
    XCTAssertEqual(player.localStop, .interrupted, "now the others listen on without this phone")
    XCTAssertEqual(control.activeHolds, 0)
    XCTAssertFalse(player.isPlayingForGroup)
    player.handleInterruption(.ended, shouldResume: true)
    XCTAssertNil(player.localStop)
    bridge.handlePlay(itemTime: 3, rate: 1)
    XCTAssertTrue(player.isPlayingForGroup)
  }

  func testAnInterruptionThatEndsWithoutPermissionWaitsForPlay() async throws {
    let (player, bridge, control, events) = try await playingRecoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    player.handleInterruption(.began, shouldResume: false)
    player.handleInterruption(.ended, shouldResume: false)
    XCTAssertEqual(player.localStop, .needsPlay)
    XCTAssertEqual(control.activeHolds, 0, "the group is not held")
    XCTAssertEqual(control.reapplications, 0)
    XCTAssertFalse(player.isPlaying)
    player.userTogglePlay()
    XCTAssertNil(player.localStop)
    bridge.handlePlay(itemTime: 4, rate: 1)
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    XCTAssertTrue(control.rates.isEmpty)
    XCTAssertTrue(events().isEmpty)
  }

  func testPauseDuringAnInterruptionKeepsThisPhoneStoppedAfterIt() async throws {
    let (player, bridge, control, events) = try await playingRecoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    player.handleInterruption(.began, shouldResume: false)
    player.userPause()
    XCTAssertEqual(player.localStop, .needsPlay)
    XCTAssertTrue(events().isEmpty, "nothing sent: the group plays on")
    player.handleInterruption(.ended, shouldResume: true)
    XCTAssertEqual(player.localStop, .needsPlay, "Pause is respected")
    XCTAssertFalse(player.isPlayingForGroup)
    player.userTogglePlay()
    XCTAssertNil(player.localStop)
    bridge.handlePlay(itemTime: 4, rate: 1)
    XCTAssertTrue(player.isPlayingForGroup)
    XCTAssertTrue(control.rates.isEmpty)
  }

  func testRemovingTheHeadphonesStopsOnlyThisPhoneUntilPlay() async throws {
    let (player, bridge, control, events) = try await playingRecoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    player.audioRouteRemoved()
    XCTAssertFalse(player.isPlaying)
    XCTAssertEqual(player.localStop, .needsPlay)
    XCTAssertTrue(events().isEmpty, "no pause for the others")
    XCTAssertEqual(control.activeHolds, 0)
    XCTAssertFalse(player.isPlaying, "never through the speaker unasked")
    player.userTogglePlay()
    XCTAssertFalse(player.isPlayingForGroup, "waits for the group's state")
    bridge.handlePlay(itemTime: 7, rate: 1)
    XCTAssertEqual(player.bookTime, 7, accuracy: 0.05, "rejoins at the group's current place")
    try await AudioFixture.waitUntil(player: player.player) { player.isPlaying }
    XCTAssertTrue(events().isEmpty)
    XCTAssertTrue(control.rates.isEmpty)
  }

  func testRemovingTheHeadphonesWhilePausedStillNeedsPlayWhenTheGroupStarts() throws {
    let (player, bridge, _) = try recoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    player.audioRouteRemoved()
    XCTAssertNil(player.localStop)
    bridge.handlePlay(itemTime: 2, rate: 1)
    XCTAssertEqual(player.localStop, .needsPlay)
    XCTAssertFalse(player.isPlayingForGroup)
  }

  func testAGroupPauseWhileStoppedHereEndsTheLocalStop() async throws {
    let (player, bridge, control, _) = try await playingRecoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    player.handleInterruption(.began, shouldResume: false)
    bridge.handlePause(itemTime: 4)
    XCTAssertNil(player.localStop, "nothing is missed now")
    XCTAssertEqual(control.localHolds, 0)
    XCTAssertFalse(player.groupIsPlaying)
  }

  func testStoppingDuringInterruptionDiscardsLaterRecovery() async throws {
    let (player, bridge, control, _) = try await playingRecoveryPlayer()
    player.handleInterruption(.began, shouldResume: false)
    bridge.invalidate()
    player.stop()
    XCTAssertEqual(control.localHolds, 0)
    XCTAssertEqual(control.activeHolds, 0)
    player.handleInterruption(.ended, shouldResume: true)
    bridge.handlePlay(itemTime: 2, rate: 1)
    player.applyPlay(at: 2, rate: 1)
    XCTAssertEqual(control.reapplications, 0)
    XCTAssertNil(player.player.currentItem)
    XCTAssertFalse(player.isPlaying)
  }

  // MARK: Own copy saving at a file change (fix round 2, F3)

  func testTheSavedPlaceUsesTheItemTheQueueIsReallyPlaying() async throws {
    let player = ListenerPlayer(manifest: threePieces())
    defer { player.stop() }
    player.pieceArrived(index: 0, url: try makePiece(0))
    player.pieceArrived(index: 1, url: try makePiece(1))
    player.applySeek(to: 9)
    try await AudioFixture.waitUntil(player: player.player) { player.isReady(at: 9) }
    player.player.advanceToNextItem()          // the queue moved on; `queueAdvanced()` hasn't run yet
    player.itemTimeProvider = { CMTime(seconds: 0.5, preferredTimescale: 600) }
    XCTAssertEqual(player.fileIndexForSaving, 1)
    XCTAssertEqual(player.positionForSaving, 10.5, accuracy: 0.01, "file 1's clock on file 1, not file 0")
  }

  func testPlayPressedTwiceBeforeTheAudioStartsIsSentOnce() throws {
    let (player, bridge, control) = try recoveryPlayer()
    defer { bridge.invalidate(); player.stop() }
    bridge.handleSeek(itemTime: 2)
    player.userPlay()
    player.userPlay()
    XCTAssertEqual(control.rates, [1], "M2: a second press in the gap sends nothing more")
  }

  // MARK: Recovery paths (audit 2, I2 and I3)

  func testAnInterruptedSeekIsTriedAgainNotTreatedAsABrokenFile() async throws {
    let player = ListenerPlayer(manifest: manifest())
    defer { player.stop() }
    var failures: [Int] = []
    player.onPieceFailed = { failures.append($0) }
    player.pieceArrived(index: 0, url: try makePiece(0))
    player.applySeek(to: 4)
    try await AudioFixture.waitUntil(player: player.player) { player.isReady(at: 4) }
    let item = try XCTUnwrap(player.player.currentItem)
    player.seekCompleted(finished: false, generation: player.currentSeekGeneration, item: item, offset: 4)
    XCTAssertTrue(failures.isEmpty, "an interrupted seek is not a failed file")
    try await AudioFixture.waitUntil(player: player.player) { player.isReady(at: 4) }
    XCTAssertEqual(player.player.currentTime().seconds, 4, accuracy: 0.1)
    XCTAssertTrue(failures.isEmpty)
    // One that keeps being interrupted does count, once.
    for _ in 0...ListenerPlayer.seekRetryLimit {
      player.seekCompleted(finished: false, generation: player.currentSeekGeneration, item: item, offset: 4)
    }
    XCTAssertEqual(failures, [0])
  }

  func testAFailureOfThePieceThatPlayedOutKeepsTheHealthyNextOne() async throws {
    let player = ListenerPlayer(manifest: threePieces())
    defer { player.stop() }
    var failures: [Int] = []
    var needed: [Int] = []
    player.onPieceFailed = { failures.append($0) }
    player.onNeedsPiece = { needed.append($0) }
    player.pieceArrived(index: 0, url: try makePiece(0))
    player.pieceArrived(index: 1, url: try makePiece(1))
    player.applySeek(to: 9)
    try await AudioFixture.waitUntil(player: player.player) { player.isReady(at: 9) }
    let first = try XCTUnwrap(player.player.currentItem)
    // AVQueuePlayer moves on before our own queue bookkeeping has run, then piece 0 reports a failure.
    player.player.advanceToNextItem()
    let next = try XCTUnwrap(player.player.currentItem)
    player.itemFailed(first)
    await drainNotifications()
    XCTAssertTrue(failures.isEmpty, "the healthy next piece is not reloaded")
    XCTAssertTrue(needed.isEmpty)
    XCTAssertTrue(player.player.currentItem === next, "the next piece keeps playing")
    XCTAssertTrue(player.timeline.isReady(at: 12))
  }

  func testFinishingTheLastPieceSaysTheBookEnded() throws {
    let player = ListenerPlayer(manifest: manifest())
    defer { player.stop() }
    var ended = 0
    player.onReachedEndOfBook = { ended += 1 }
    player.pieceArrived(index: 0, url: try makePiece(0))
    player.pieceArrived(index: 1, url: try makePiece(1))
    player.applySeek(to: 15)
    player.advanceToNextPiece()
    XCTAssertEqual(ended, 1)
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
  var localHolds = 0
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
  func beginLocalSuspension() -> () -> Void {
    localHolds += 1
    return { [weak self] in self?.localHolds -= 1 }
  }
  func transitionToItem(withIdentifier identifier: String?, proposingTime time: TimeInterval?, rate: Float) {}
  func reapplyCurrentItemState() {
    reapplications += 1
    reapply?()
  }
}
