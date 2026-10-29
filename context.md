# context.md - current snapshot

Date: 2026-10-29
Branch: `develop` (Becky's fork, origin github.com/BeckyK102125/BookPlayer; upstream TortugaPower/BookPlayer).
Full history and the old long snapshot (rulings, build 6 design, device checks): Notes.md, entry 2026-10-28.

## Goal
SharePlay "Listen Together" in the fork: one person shares a downloaded audiobook, the others listen to a
temporary copy or their own copy, playback stays in sync, and everything works with VoiceOver and Zoom.
Now: TestFlight 5.22.2 (6) is out (internal only); next is the two-phone test on build 6.
Lead: the "BookPlayer Lead" chat on the Neo fixes Start Testing items (project "BookPlayer - Listen together",
697bd58a) on weekdays 7 AM to 3 PM, following agents.md rule 3 (comment with the branch on start; comment with
commit and tests, then move to Testing, when fixed).

## Branches
- `develop`: TestFlight 5.22.2 (6) code at d55292ea, then notes, agents.md and Review.md commits.
- `listen-together-6.0` (local only): build 6 plus the upstream 6.0.0 merge; merged into develop on 2026-10-23.
- `listen-together-build6` and older `listen-together-*` branches: local only, kept for history.
- Never commit BuildConfiguration/Debug.xcconfig. PlayerManager.swift: ask Becky before editing.

## Last work
- 2026-10-29: new Lead chat (the first one was full); develop with the rejoin change pushed to GitHub.
- 2026-10-27: lead chat started; develop fast-forwarded to c16411f4; Start Testing project had 0 items.
- 2026-10-28: this file trimmed to 60 lines (old text in Notes.md). Becky's answers: a listener now always
  rejoins the group when an interruption ends (even without iOS's "should resume"); a weekday noon Start Testing
  check (scheduled task bookplayer-start-testing-noon-check) messages this chat with new items.
- 2026-10-23: Codex re-audit (Review.md, R01 to R22); R01 (Siri PlayMedia routing), R02 (video player), the
  transfer-sheet cover and the live sharer status were fixed; develop pushed; TestFlight 5.22.2 (6) uploaded
  with MARKETING_VERSION=5.22.2 on the archive command line (6.0.0 (6) expired).

## Test results (fix round 4 and the 6.0.0 merge, scheme BookPlayer, plan "Unit Tests", default DerivedData)
- Full suite after the merge: "Executed 1757 tests, with 0 failures", ** TEST SUCCEEDED **.
- SharePlay classes plus PlayerManagerTests: 736/0; TSan on them: 0 crashes, 0 warnings.
- 2026-10-28 rejoin change: ListenerPlayer, OwnCopy, SessionEnd and SharerPlaybackTarget tests 135/0, ** TEST SUCCEEDED **.
- TSan on the whole suite stops at a pre-existing DirectoryWatcher race; run SharePlay classes by name.

## Next steps (in order)
1. Two-phone test on build 6 (Becky with VoiceOver, Michael with Zoom 3x): the 13 device checks in Notes.md
   (2026-10-28 snapshot), plus the Duo side-by-side player as sharer and the sharer mini player line at Zoom 3x,
   plus: a listener whose audio Music or a video took rejoins by itself once that app stops (needs a new build).
2. Fix Start Testing items as they arrive (Swift Reviewer, Aquila BP-, testers).
3. Once build 6 is stable: the 20 deferred upstream findings R03 to R22 in Review.md (R09 touches
   PlayerManager.swift: ask first).
4. Split files over 700 lines: SharePlaySessionService.swift (1729), ListenerPlayer.swift (1032).
5. Mark the new Listen Together strings for translation before a release.

## Open questions for Becky
- None.
