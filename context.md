# context.md - current snapshot

Date: 2026-11-18
Branch: develop at b9fe9f06 (fix/sr7-07-09 fast-forwarded in), not pushed. develop is 20+ commits ahead of origin/develop.

## Goal
Listen Together: share downloaded audiobooks, keep playback and own-copy progress in sync, and support
VoiceOver and Zoom. Get develop ready for TestFlight build 7.

## Last work
- November 16: merged 13 upstream TortugaPower commits (up to 6027e850) as aa1d5632; the 13 newer ones
  (PlayerManager moved behind PlaybackEngine) are held back until Becky approves PlayerManager changes.
- November 16: investigated Start Testing dd0bde92 (Michael's share of a book only he has failed; Becky's
  worked). No code defect found. MP3 and M4B cutting proven by new BookSplitterTests. Likeliest cause:
  Michael's phone set to "Only people who have the book can join" (per-device setting). Details in Notes.md.
- November 17: Swift Reviewer SR7 audit (Review.md 5a4f4586): 15 findings in Start Testing. Not ready for
  TestFlight 7 until SR7-01 and SR7-02 are fixed and Becky decides SR7-05 (Hardcover client id).
- November 17: SR7-01 (sharer's other book controlled the group) and SR7-02 (second window deleted the
  session's files) fixed as fab311c9; Start Testing items moved to Testing. November 18: fast-forwarded
  into develop with Becky's approval.
- November 18: SR7-03, 04, 05, 06, 08, 10, 11 fixed (b578b168), fast-forwarded into develop with Becky's OK.
- November 18: SR7-07 (sleep timer pauses the group while listening) and SR7-09 (group Play skips Smart
  Rewind and the auto timer) fixed on fix/sr7-07-09, Becky approved the PlayerManager change. Fast-forwarded into develop with Becky's OK.
- November 12: Codex recheck of the October 23 audit; BP-20261112-03 to -22 open in Start Testing.

## Test results
- 2026-11-16 full unit suite on develop after the merge, iPhone 17 Pro simulator:
  `xcodebuild test-without-building -scheme BookPlayer -only-testing:BookPlayerTests`
  "Executed 1838 tests, with 0 failures".
- 2026-11-17 at fab311c9 (now develop): 1848 tests, 0 failures; TSan on the three touched test classes clean.
- 2026-11-18 on fix/sr7-mediums: 1863 tests, 0 failures; TSan on 7 touched SharePlay classes clean.
- 2026-11-18 on fix/sr7-07-09: 1866 tests, 0 failures; TSan on 6 touched classes clean.
- Whole-suite TSan has a known DirectoryWatcher race.
- Project still declares Swift 5.0; Swift 6 Complete checking is not established.

## Next steps
1. dd0bde92 (continuing on the Neo): Michael's shares fail even when both have the book, so the
   owners-only guess is wrong. Find what differs when Michael's phone shares; get Console logs from it.
2. Retest dd0bde92 with both phones and Console logs ("Listen Together") from Michael's phone.
3. Becky: approve merging fix/sr7-07-09; decide SR7-05 (keep Hardcover?). Then TestFlight 7. Device checks: SR7-01 on two phones,
   SR7-02 with two iPad windows.
4. BP-20261112-03 to -10 (P1), then the P2 findings; read item status and comments first.
5. Split files over 700 lines: SharePlaySessionService.swift, SharePlaySessionService+Session.swift
   (1785), ListenerPlayer.swift.
6. Mark the new Listen Together strings for translation before a release.

## Open questions for Becky
- Push develop (merge plus tests) to GitHub?
- Merge the 13 newer upstream commits (they change PlayerManager)?
- dd0bde92: Michael's free storage, iOS version and BookPlayer build.

## Constraints
- PlayerManager.swift: Becky approves before implementation changes.
- Never commit BuildConfiguration/Debug.xcconfig. Leave the untracked .nova/ folder alone.
- Simulator: BookPlayer uses iPhone 18 Pro 7B46F85F, taking /private/tmp/agents/claude/start-speaking-xcodebuild.lock.
