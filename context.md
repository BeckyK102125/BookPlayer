# context.md - current snapshot

Date: 2026-11-20
Branch: merge/upstream-player-engine (from develop da2b7321). develop is on GitHub at 075673a4; da2b7321
(notes) is local only.

## Goal
Listen Together: share downloaded audiobooks, keep playback and own-copy progress in sync, and support
VoiceOver and Zoom. Get develop ready for TestFlight build 7.

## Last work
- November 20: Becky approved merging the 13 held-back upstream commits (player core behind PlaybackEngine,
  moved into BookPlayerKit). Merged as b566c354 on merge/upstream-player-engine, 15 conflicts resolved:
  SR7-07 guards kept, SR7-09 is now PlayOrigin.group, A08 no-crash moved to PhonePlayerPlatform, A01 guard
  dropped (upstream's engine scopes end-of-item), mocks regenerated. NOT built or tested yet: Friday evening
  is Becky's time on the Pro and the pro-slot override needs her explicit OK.
- November 20: Becky decided SR7-05: leave Hardcover alone (sign-in shows "isn't set up in this build").
- November 16: merged 13 upstream TortugaPower commits (up to 6027e850) as aa1d5632; the 13 newer ones
  (PlayerManager moved behind PlaybackEngine) are held back until Becky approves PlayerManager changes.
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
- 2026-11-18 on fix/sr7-mediums: 1863 tests, 0 failures; TSan on 7 touched SharePlay classes clean.
- 2026-11-18 on fix/sr7-07-09: 1866 tests, 0 failures; TSan on 6 touched classes clean.
- Project still declares Swift 5.0; Swift 6 Complete checking is not established.

## Next steps
0. Build and run the full unit suite on merge/upstream-player-engine (Pro slot), fix fallout, TSan on
   touched classes, then fast-forward develop (Becky approved the merge). Then phone checks SR7-01, 07, 09
   on two iPhones on the merged build; SR7-02 on an iPad simulator only (Becky has no iPad).
   Phone tests go to the On-device testing coordinator chat (local_2c35a663), never to Becky directly.
1. dd0bde92 (continuing on the Neo): Michael's shares fail even when both have the book, so the
   owners-only guess is wrong. Find what differs when Michael's phone shares; get Console logs from it.
2. Retest dd0bde92 with both phones and Console logs ("Listen Together") from Michael's phone.
3. dd0bde92 is a TestFlight 7 blocker.
4. BP-20261112-03 to -10 (P1), then the P2 findings; read item status and comments first.
5. Split files over 700 lines: SharePlaySessionService.swift, SharePlaySessionService+Session.swift
   (1785), ListenerPlayer.swift.
6. Mark the new Listen Together strings for translation before a release.

## Open questions for Becky
- Swift 6: recommend keeping Swift 5 mode (as upstream) and making SharePlay code Swift 6 clean via Codex,
  before an upstream PR. Awaiting Becky.
- dd0bde92: Michael's free storage, iOS version and BookPlayer build.

## Constraints
- PlayerManager.swift: Becky approves before implementation changes.
- Never commit BuildConfiguration/Debug.xcconfig. Leave the untracked .nova/ folder alone.
- Simulator: BookPlayer uses iPhone 18 Pro 7B46F85F, taking /private/tmp/agents/claude/start-speaking-xcodebuild.lock.
