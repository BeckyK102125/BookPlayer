# context.md - current snapshot

Date: 2026-11-23
Branch: `fix/bp-20261112-high` (from develop 63df259e), pushed at f2dae4ac (before this notes commit).
Untested: the Pro has had no BookPlayer lead to take the test request. Also untested:
`fix/sr6-01-rejoin-other-audio` (SR6-01, develop merged in as 5048a778).
develop has since moved to c6057686 (SR7 fixes, upstream player merge: player core behind PlaybackEngine,
PlayerManagerProtocol made @MainActor, import fixes #1706 and #1708). Both branches need develop merged
in before testing; expect conflicts around ImportOperation (#1708) and the notes files.

## Goal
Listen Together: share downloaded audiobooks, keep playback and own-copy progress in sync, and support
VoiceOver and Zoom. Get develop ready for TestFlight build 7.

## Last work
- November 23 (Neo Lead): new Critical item AQL10-02 (2fb66906): PlayerManagerProtocolMock lacks
  @MainActor although PlayerManagerProtocol is now @MainActor (upstream b7ccd5ca). Not started. The mock
  is Sourcery output (never hand-edit); the fix is in the stencil or a sourcery annotation, regenerated
  with Sourcery, which only the Pro has.
- November 18 (Neo Lead): on fix/bp-20261112-high, fixed three P1 audit findings, each with new tests:
  BP-20261112-03 (LibraryServiceBackupTests), -07 (ImportOperationArchiveTests), -04
  (SyncListSessionTests). Not built.
- November 18: merged develop into the SR6-01 branch.

## Test results
- develop c6057686: the Pro reports the upstream player merge tested (see develop's own notes).
- fix/bp-20261112-high and fix/sr6-01-rejoin-other-audio: not built or tested yet.
- Whole-suite TSan has a known DirectoryWatcher race.
- Project still declares Swift 5.0; Swift 6 Complete checking is not established.

## Next steps
1. AQL10-02 (Critical): read the item and comments; fix via Sourcery template or annotation, regenerate
   on the Pro, prove with a test build. Comment when starting.
2. Merge develop into fix/bp-20261112-high and the SR6-01 branch; then a Pro chat builds and runs
   LibraryServiceBackupTests, ImportOperationArchiveTests, SyncListSessionTests (TSan), ListenerPlayerTests
   and the full suite; move BP-20261112-03, -04, -07 and SR6-01 to Testing if green. Builds on the Pro take
   `~/.local/bin/pro-slot` and stay out of Becky's time; ask the resource lead chat on the Pro.
3. BP-20261112-05 (sync operation admitted after logout), high effort. BP-20261112-06 needs Sourcery (Pro).
4. Open: SR9-01 (Medium), SR8-01 (Medium), SR9-02 and SR7-12 to -15 (Low), BP P2 items -11 to -22.
5. Needs Becky: BP-20261112-08, -09, -10 (PlayerManager, now behind PlaybackEngine; recheck they still
   apply); SR7-05 Hardcover; SR7-10 if still open; a user-facing message for a failed zip (BP-07).
6. Split files over 700 lines: SharePlaySessionService*.swift, ListenerPlayer.swift,
   MainCoordinator+ListenTogether.swift (SR7-15), SyncService.swift (1595).

## Open questions for Becky
- Should a share that keeps failing on one piece end with "Couldn't prepare the book" after a few tries,
  instead of retrying silently forever?

## Constraints
- PlayerManager / PlaybackEngine changes: Becky approves before implementation changes.
- Never commit BuildConfiguration/Debug.xcconfig. Never hand-edit AutoMockable.generated.swift.
- Phone and VoiceOver checks go through the Test Coordinator chat on the Pro.
