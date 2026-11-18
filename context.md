# context.md - current snapshot

Date: 2026-11-17
Branch: fix/sr7-01-02-sharer-and-windows (off develop 5a4f4586), not merged or pushed.

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
  session's files) fixed on the branch above; Start Testing items moved to Testing.
- November 12: Codex recheck of the October 23 audit; BP-20261112-03 to -22 open in Start Testing.

## Test results
- 2026-11-16 full unit suite on develop after the merge, iPhone 17 Pro simulator:
  `xcodebuild test-without-building -scheme BookPlayer -only-testing:BookPlayerTests`
  "Executed 1838 tests, with 0 failures".
- 2026-11-17 on the fix branch: 1848 tests, 0 failures; TSan on the three touched test classes clean.
- Whole-suite TSan has a known DirectoryWatcher race.
- Project still declares Swift 5.0; Swift 6 Complete checking is not established.

## Next steps
1. Michael checks Settings, Playback, Listen Together, "When someone doesn't have the book" on his phone.
2. Retest dd0bde92 with both phones and Console logs ("Listen Together") from the sharer's phone.
3. Becky: merge the SR7 fix branch into develop; decide SR7-05, and SR7-03/04 wording. Then TestFlight 7.
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
- Simulator: BookPlayer uses iPhone 18 Pro 7B46F85F, taking /private/tmp/agents/claude/start-speaking-xcodebuild.lock.
