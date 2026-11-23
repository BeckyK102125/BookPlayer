# context.md - current snapshot

Date: 2026-11-23
Branch: `fix/bp-20261112-high` (Neo's BP-03/04/07 fixes), develop c6057686 merged in. Local only, not
built or tested yet. develop c6057686 is on GitHub.

## Goal
Listen Together: share downloaded audiobooks, keep playback and own-copy progress in sync, and support
VoiceOver and Zoom. Get develop ready for TestFlight build 7.

## Last work
- November 23 (Pro): AQL10-02 closed as Cannot Reproduce: the mock inherits @MainActor from its
  conformance (SE-0316), proved with a Swift 6 type-check. develop merged into this branch; only the
  notes files conflicted; ImportOperation's BP-07 fix merged cleanly over #1708.
- November 20: upstream player core merged into develop (PlaybackEngine, PlayerManager in BookPlayerKit,
  SR7-09 as PlayOrigin.group, A08 no-crash in PhonePlayerPlatform). Becky: leave Hardcover alone (SR7-05).
- November 18 (Neo): on this branch, BP-20261112-03 (LibraryServiceBackupTests), -07
  (ImportOperationArchiveTests), -04 (SyncListSessionTests) fixed. Never built.
- November 17 to 18: SR7-01 to -11 fixed and in develop.

## Test results
- develop e0491b1f/c6057686, Nov 20, iPhone 18 Pro sim, no parallel testing: 1937 tests, 0 failures.
  TSan on 8 classes: 246 tests, clean.
- fix/bp-20261112-high (with develop merged) and fix/sr6-01-rejoin-other-audio: not built or tested.
- Whole-suite TSan has a known DirectoryWatcher race.
- Project still declares Swift 5.0; Swift 6 Complete checking is not established.

## Next steps
1. Tuesday 7 AM to 3 PM (pro-slot): build this branch; run LibraryServiceBackupTests,
   ImportOperationArchiveTests, SyncListSessionTests (TSan) and the full suite; if green, push the branch
   and move BP-20261112-03, -04, -07 to Testing.
2. Merge develop into fix/sr6-01-rejoin-other-audio, build, run ListenerPlayerTests and the full suite.
3. Get the develop build onto both iPhones (TestFlight 7 is Becky's upload, or an Xcode install), then
   send SR7-01, 07, 09 to the testing coordinator (local_2c35a663).
4. dd0bde92: Michael's shares fail; needs Console logs ("Listen Together") from Michael's phone.
   TestFlight 7 blocker.
5. BP-20261112-05 (sync op admitted after logout), -06 (needs Sourcery, Pro), then P2 -11 to -22.
6. Needs Becky: BP-20261112-08, -09, -10 (PlayerManager, recheck after the engine merge); a message
   for a failed zip (BP-07).
7. Split files over 700 lines: SharePlaySessionService*.swift, ListenerPlayer.swift, SyncService.swift.

## Open questions for Becky
- TestFlight build 7 or an Xcode install to get develop onto both iPhones?
- Swift 6: recommend keeping Swift 5 mode (as upstream) and making SharePlay code Swift 6 clean via Codex,
  before an upstream PR.
- Should a share that keeps failing on one piece end with "Couldn't prepare the book"? (SR7-03 now ends
  it after 8 tries; recheck if still open.)

## Constraints
- PlayerManager / PlaybackEngine: Becky approves implementation changes.
- Never commit BuildConfiguration/Debug.xcconfig. Leave the untracked .nova/ folder alone.
- Never hand-edit AutoMockable.generated.swift. Phone and VoiceOver checks go through the Test Coordinator.
- Simulator: iPhone 18 Pro 7B46F85F-B32A-4BD1-BFBC-38C2EB73425A, behind pro-slot, out of Becky's time.
