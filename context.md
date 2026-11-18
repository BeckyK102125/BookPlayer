# context.md - current snapshot

Date: 2026-11-18
Branch: `fix/bp-20261112-high` (from develop 63df259e), pushed. Waits for the Pro to build and test.
Also waiting: `fix/sr6-01-rejoin-other-audio` (SR6-01, develop merged in as 5048a778), pushed, untested.

## Goal
Listen Together: share downloaded audiobooks, keep playback and own-copy progress in sync, and support
VoiceOver and Zoom. Get develop ready for TestFlight build 7.

## Last work
- November 18 (Neo Lead): on fix/bp-20261112-high, fixed three P1 audit findings, each with new tests:
  BP-20261112-03 (sync removal kept only after the file is in Backup; LibraryServiceBackupTests),
  BP-20261112-07 (failed or user-owned zip kept; ImportOperationArchiveTests),
  BP-20261112-04 (old account's list response dropped after logout; SyncListSessionTests).
  Not built: the Neo doesn't run builds or simulators.
- November 18: merged develop into the SR6-01 branch (only notes conflicted).
- November 17: SR7-01 and SR7-02 fixed (fab311c9), in Testing; in develop with Becky's approval.
- November 17: Swift Reviewer SR7 audit (Review.md 5a4f4586): 15 findings in Start Testing.
- November 16: upstream merge to 6027e850 (aa1d5632); the 13 newer upstream commits (PlayerManager behind
  PlaybackEngine) held until Becky approves PlayerManager changes. dd0bde92 investigated: no code defect
  found; likeliest cause Michael's "Only people who have the book can join" setting.

## Test results
- 2026-11-17 at fab311c9 (now develop): 1848 tests, 0 failures; TSan on the three touched test classes clean.
  `xcodebuild test-without-building -scheme BookPlayer -only-testing:BookPlayerTests`
- fix/bp-20261112-high and fix/sr6-01-rejoin-other-audio: not built or tested yet.
- Whole-suite TSan has a known DirectoryWatcher race.
- Project still declares Swift 5.0; Swift 6 Complete checking is not established.

## Next steps
1. Pro: build fix/bp-20261112-high; run LibraryServiceBackupTests, ImportOperationArchiveTests,
   SyncListSessionTests, then the full unit suite (TSan on SyncListSessionTests). If green, move
   BP-20261112-03, -04 and -07 to Testing. Same for SR6-01 on its branch (ListenerPlayerTests).
2. BP-20261112-05 (sync operation admitted after logout) next, at high effort; BP-20261112-06 changes an
   AutoMockable protocol, so it needs Sourcery (not installed on the Neo): Pro.
3. Needs Becky: BP-20261112-08, -09 (iOS PlayerManager) and -10 (Watch PlayerManager, playback);
   SR7-05 and SR7-03/04 wording; SR7-10 (VoiceOver focus); a user-facing message for a failed zip (BP-07).
4. Michael checks "When someone doesn't have the book" on his phone; retest dd0bde92 with Console logs.
5. P2 findings (BP-20261112-11 to -22) and open SR7 items; read item status and comments first.
6. Split files over 700 lines: SharePlaySessionService.swift, SharePlaySessionService+Session.swift,
   ListenerPlayer.swift, MainCoordinator+ListenTogether.swift (SR7-15), SyncService.swift (1595).

## Open questions for Becky
- Merge the 13 newer upstream commits (they change PlayerManager)?
- Should a share that keeps failing on one piece end with "Couldn't prepare the book" after a few tries,
  instead of retrying silently forever?

## Constraints
- PlayerManager.swift (iOS and Watch): Becky approves before implementation changes.
- Never commit BuildConfiguration/Debug.xcconfig. Leave the untracked .nova/ folder alone.
- Simulator (Pro only): BookPlayer uses iPhone 18 Pro 7B46F85F, taking
  /private/tmp/agents/claude/start-speaking-xcodebuild.lock.
