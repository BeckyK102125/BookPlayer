# context.md - current snapshot

Date: 2026-11-18
Branch: `fix/sr6-01-rejoin-other-audio` (SR6-01 fix 050d480f, with develop 63df259e merged in), pushed.
develop is at 63df259e on GitHub (SR7-01 and SR7-02 merged with Becky's approval).

## Goal
Listen Together: share downloaded audiobooks, keep playback and own-copy progress in sync, and support
VoiceOver and Zoom. Get develop ready for TestFlight build 7.

## Last work
- November 18 (Neo Lead): merged develop into the SR6-01 branch so the fix can go into develop once tested.
- November 17: SR7-01 (sharer's other book controlled the group) and SR7-02 (second window deleted the
  session's files) fixed as fab311c9; in Testing. November 18: in develop with Becky's approval.
- November 17: Swift Reviewer SR7 audit (Review.md 5a4f4586): 15 findings in Start Testing. Not ready for
  TestFlight 7 until Becky decides SR7-05 (Hardcover client id).
- November 16: merged 13 upstream TortugaPower commits (up to 6027e850) as aa1d5632; the 13 newer ones
  (PlayerManager moved behind PlaybackEngine) are held back until Becky approves PlayerManager changes.
- November 16: investigated dd0bde92 (Michael's share of a book only he has failed). No code defect found.
  Likeliest cause: Michael's phone set to "Only people who have the book can join". Details in Notes.md.
- November 12: Codex recheck of the October 23 audit; BP-20261112-03 to -22 open in Start Testing.
- November 2: SR6-01 fixed (050d480f): after an interruption ends without "should resume" while another
  app's audio plays, the listener waits for Play. Never built or tested yet.

## Test results
- 2026-11-17 at fab311c9 (now develop): 1848 tests, 0 failures; TSan on the three touched test classes clean.
  `xcodebuild test-without-building -scheme BookPlayer -only-testing:BookPlayerTests`
- SR6-01 branch: not built or tested (the Neo doesn't run simulators).
- Whole-suite TSan has a known DirectoryWatcher race.
- Project still declares Swift 5.0; Swift 6 Complete checking is not established.

## Next steps
1. Pro: build this branch and run ListenerPlayerTests (and the SharePlay classes); if green, fast-forward
   develop to it and move SR6-01 to Testing.
2. Michael checks Settings, Playback, Listen Together, "When someone doesn't have the book" on his phone;
   then retest dd0bde92 with both phones and Console logs ("Listen Together") from the sharer's phone.
3. Becky: decide SR7-05, and SR7-03/04 wording. Then TestFlight 7. Device checks: SR7-01 on two phones,
   SR7-02 with two iPad windows.
4. BP-20261112-03 to -07 and -10 (P1, Safe Alone); -08 and -09 need Becky (PlayerManager). Then P2 findings
   and the open SR7 items; read item status and comments first.
5. Split files over 700 lines: SharePlaySessionService.swift, SharePlaySessionService+Session.swift
   (1785), ListenerPlayer.swift.
6. Mark the new Listen Together strings for translation before a release.

## Open questions for Becky
- Merge the 13 newer upstream commits (they change PlayerManager)?
- Should a share that keeps failing on one piece end with "Couldn't prepare the book" after a few tries,
  instead of retrying silently forever?

## Constraints
- PlayerManager.swift: Becky approves before implementation changes.
- Never commit BuildConfiguration/Debug.xcconfig. Leave the untracked .nova/ folder alone.
- Simulator (Pro only): BookPlayer uses iPhone 18 Pro 7B46F85F, taking
  /private/tmp/agents/claude/start-speaking-xcodebuild.lock.
