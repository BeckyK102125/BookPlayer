# context.md - current snapshot

Date: 2026-11-16
Branch: develop (BookPlayer fork), 16 commits ahead of origin/develop, not pushed.

## Goal
Listen Together: share downloaded audiobooks, keep playback and own-copy progress in sync, and support
VoiceOver and Zoom. Get develop ready for TestFlight build 7.

## Last work
- November 16: merged 13 upstream TortugaPower commits (up to 6027e850) as aa1d5632; the 13 newer ones
  (PlayerManager moved behind PlaybackEngine) are held back until Becky approves PlayerManager changes.
- November 16: investigated Start Testing dd0bde92 (Michael's share of a book only he has failed; Becky's
  worked). No code defect found. MP3 and M4B cutting proven by new BookSplitterTests. Likeliest cause:
  Michael's phone set to "Only people who have the book can join" (per-device setting). Details in Notes.md.
- November 16: a Swift Reviewer audit of develop was requested for TestFlight 7 readiness.
- November 12: Codex recheck of the October 23 audit; BP-20261112-03 to -22 open in Start Testing.

## Test results
- 2026-11-16 full unit suite on develop after the merge, iPhone 17 Pro simulator:
  `xcodebuild test-without-building -scheme BookPlayer -only-testing:BookPlayerTests`
  "Executed 1838 tests, with 0 failures".
- No TSan run this time (no concurrency code changed). Whole-suite TSan has a known DirectoryWatcher race.
- Project still declares Swift 5.0; Swift 6 Complete checking is not established.

## Next steps
1. Michael checks Settings, Playback, Listen Together, "When someone doesn't have the book" on his phone.
2. Retest dd0bde92 with both phones and Console logs ("Listen Together") from the sharer's phone.
3. Act on the Swift Reviewer's findings (Start Testing and Review.md); it judges TestFlight 7 readiness.
4. BP-20261112-03 to -10 (P1), then the P2 findings; read item status and comments first.
5. Split files over 700 lines: SharePlaySessionService.swift, SharePlaySessionService+Session.swift
   (1785), ListenerPlayer.swift.
6. Mark the new Listen Together strings for translation before a release.

## Open questions for Becky
- Push develop (merge plus tests) to GitHub?
- Merge the 13 newer upstream commits (they change PlayerManager)?
- Should a share that keeps failing on one piece end with "Couldn't prepare the book" after a few tries,
  instead of retrying silently forever?

## Constraints
- PlayerManager.swift: Becky approves before implementation changes.
- Never commit BuildConfiguration/Debug.xcconfig. Leave the untracked .nova/ folder alone.
- Simulator: share iPhone 17 Pro 3949B098 through /private/tmp/agents/claude/start-speaking-xcodebuild.lock.
