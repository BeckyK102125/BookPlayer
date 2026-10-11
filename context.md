# context.md - current snapshot

Date: 2026-10-11

## Goal
SharePlay "Listen Together" in Becky's fork of BookPlayer: one person shares a downloaded audiobook (from
Messages with no call, or on a FaceTime call); the others listen to a temporary copy (deleted when the
session ends) or their own copy; playback stays in sync; everything works with VoiceOver, and every
important message is also seen (Zoom, low vision).
Current goal: finish the final whole-branch review fixes on `listen-together-own-copy`, then the two-device
run, then merge into develop and TestFlight build 2 (needs Becky's approval).
- Specs: docs/superpowers/specs/2026-10-10-shareplay-listen-together-design.md, -addendum-2.md,
  2026-10-11-listen-together-addendum-3-reliable-sending.md. Plan: docs/superpowers/plans/2026-10-10-*.md
- User guide: docs/Listen-Together-Guide.md
- Ledger, briefs, reports, rulings: .superpowers/sdd/2026-10-10-shareplay-listen-together/ (progress.md).
  Latest: final-branch-review-2026-10-11.md, final-fix-round.md, final-fix-round-report.md.

## Branches and remotes
- origin = github.com/BeckyK102125/BookPlayer (Becky's fork, public). upstream = TortugaPower/BookPlayer.
- On origin: `develop` and `listen-together-messages` (9c70dd06), `listen-together-lock-screen` (63e9578b),
  `shareplay-listen-together` (e634f5c7).
- `listen-together-own-copy` (this branch, from develop 9c70dd06, NOT pushed): addendum 2 (de1f5731,
  7bf22248, 0b5aacdd), addendum 3 ruling 1598e8d4, Task A (87f4a744, de116941, d786c79e, 9cedab87),
  Task B (482ba093, 572d267b, 282f27c4, 27d86fd2), final review fixes in this commit (parent 27d86fd2).
  Clean after commit. Worktree BookPlayer-testflight (detached at 9c70dd06) belongs to another session.
- Never committed: BuildConfiguration/Debug.xcconfig. PlayerManager.swift and Shared/ are untouched.
- Change A (streamed-book alert) of addendum 1 is NOT done.

## TestFlight and devices
- Build 1: 5.22.2 (1) from develop 9c70dd06 (Release, Techopolis automatic signing), uploaded; internal
  group "Listen Together" (becnhazel, mikedoise, tayarndt). Its field test failed (ended 0.4 s after Play),
  which led to addendum 3.
- Build 2 (this branch, after merge into develop): pending Becky's approval. Both test phones must run
  the same build: the protocol gained messages (final review M3; a protocol version is a later change).
- Local device installs: team Techopolis (M9SNPTXA44), bundle ID app.techopolis.BookPlayer-together, local
  Debug.xcconfig only. Pass signing on the command line; revert any pbxproj/Info.plist churn Xcode writes.

## Rulings in force (full text in progress.md)
- R1-R39 (build plumbing, sync, stalls, late joiners, Magic Tap, invitation from the topmost screen, End
  asks once, escape = back R35, own mini player hidden R36, sheet watchdogs R37, own book asks R38/R39).
- R40: every button Apple-style (SF Symbol + text), 44 pt, Dynamic Type, 4.5:1 text / 3:1 shapes in all 22
  theme variants, one VoiceOver element with a verb label; destructive role on destructive actions.
- R41: every important message is seen: failures and endings as a centred alert with OK (never a timed
  toast or only an announcement); ongoing status as persistent text next to the controls; VoiceOver hears
  each message once.
- Two-finger scrub is always cancel/back. End asks once, Leave asks once, Cancel Sharing acts at once.
- Addendum 3: piece failures never end a session; silence never ends a session (status only); only the
  sharer leaving the roster starts the 60 s grace; Becky: after the sharer ends/leaves, one message, then
  no Listen Together UI for that book. sharerLeft keeps the spec sentence.

## What is built (summary; details in Notes.md)
- Addendum 2: own copy (fingerprint match, plays in place, nothing downloaded), owners-only mode.
- Task A: ~12 min pieces, send-ahead scheduler (.needPiece), retries with back-off, sharer kept awake,
  AVQueuePlayer, state requests, heartbeat, roster grace, diagnostics ("Listen Together:" logs).
- Task B: one message-delivery path (alert / status + one announcement / speech), alert queue in
  MainCoordinator, endings after the listener cover has gone (2 s watchdog), notifications only with
  existing permission, status lines (waiting for the person sharing, waiting for the book, can't reach the
  person sharing, retrying, paused by another listener, someone couldn't join), Zoom caption, "Speak error
  messages" setting, Leave / Cancel Sharing buttons, R40 colour fixes.
- Final review fixes (this commit):
  - I1: an own file that can't be played is armed again after the back-off; if it is gone or fails
    3 times, this phone leaves with the alert "Your copy of this book can't be played right now. You
    left Listen Together.". An own copy never shows "Waiting for the book".
  - M1: the fingerprint parser is overflow-safe (huge 64-bit atom sizes, truncated files).
  - M2: no "Can't reach..." line before the manifest or while paused.
  - M5: an early .needPiece is kept until the send order exists.
  - M6: a late heartbeat no longer ends the grace (only the sharer back in the roster).
  - M9: a background ending from an earlier session is dropped.
  - M10: session timers hold the transport weakly.

## Test evidence (2026-10-11, final review fixes)
- 24 SharePlay classes 406/0; full "Executed 978 tests, with 0 failures", ** TEST SUCCEEDED **; TSan 406/0, 0 warnings.
- Command: xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -destination 'platform=iOS
  Simulator,id=98A8CF98-8142-4710-AD5E-5419F782752C' -testPlan "Unit Tests" -only-testing:BookPlayerTests
  test (per class `-only-testing:BookPlayerTests/<Class>`; TSan adds `-enableThreadSanitizer YES`).
- Session tests use coordinatorControlFactory: ending a real stall suspension aborts in CoreMedia under
  TSan only.

## Local environment gotchas
- Xcode 27 here, CI uses 26.4. Simulator by id 98A8CF98-8142-4710-AD5E-5419F782752C.
- Wait for the FINAL ** TEST SUCCEEDED/FAILED **; xcodebuild often hangs after the results: log to a file,
  poll, kill your own xcodebuild, rerun if the final line is needed. Never pass -derivedDataPath.
  "Invalid API Key" lines are noise.
- New files: copy an existing file's four pbxproj entries with new ids (Notes.md, Task B).
- TSan on the whole suite stops at a pre-existing DirectoryWatcher race; run SharePlay classes by name.

## Device and assistive-technology checks (two-device run, both phones on the same build)
Setup: Becky (VoiceOver) + Michael (Zoom, VoiceOver off), two iPhones, Discord, start from Messages.
Capture both Console logs filtered on "Listen Together:".
1. Start with a long single-file m4b and an mp3 book: listener plays within seconds; percent moves; no gap
   at piece joins.
2. Sharer switches apps / locks mid-send: session goes on; airplane mode 30 s then back.
3. Sharer End: listener cover closes, then one alert read once; OK/scrub; focus to the mini player.
4. Same for Michael at Zoom 3x with Speak on; with Control Center open; with FaceTime in front.
5. Sharer force-quits: waiting status + minute line + caption; back within 60 s, or the left alert.
6. Sharer locks while playing: "Can't reach the person sharing. The book keeps playing." with nothing said.
7. FaceTime call ends / connection drops: each side's "connection" alert.
8. Leave on "Getting the book" (button and Actions rotor) and in the player; no "ended" banner.
9. Own copy: delete or move the book in the library mid-session (final review I1): re-armed, or this phone
   leaves with the alert; the others keep listening and are not held.
10. Speak error messages: voice (Siri voice?), ducking vs pausing, locked, VoiceOver stop, calls, sample.
11. A book with 100+ files: the invitation arrives; late-join resend time (final review M4).
12. Paused + locked 5+ minutes, then Play from the lock screen, from each side.
13. R38/R39 own book during a listener session; cold launch from the Messages invitation.
14. Settings in Sky dark; switch and picker checkmark in Ayu light; AX5 on the smallest iPhone.
15. Parked: End action sheet at Zoom 3x (a11y M9); iOS 26.0 accessory status (M10).
Full lists: reliable-sending-task-B-report.md, own-copy-a11y-guidance.md, Notes.md.

## Known limitations
- Streamed books and video cannot be shared.
- The sharer's exported pieces take about the book's size in tmp until the session ends.
- A piece that fails for good is retried every 30 s; listeners who need it wait. The sharer sees
  "Couldn't send part of the book. Trying again." "Waiting for the others to get the book" is not shown.
- If the sharer switches books mid-session, listeners keep the old book (R12).
- A killed sharer that iOS keeps in the roster never ends listeners' sessions (they see the silence line).
- Speed changes are saved in the sharer's library; sleep timer/CarPlay chapters on a listener: own book.
- Own book can't start from Siri/widget/CarPlay while locked during a listener session (R38/R39).
- The notification path is dormant (BookPlayer never asks for permission). The SwiftUI alerts
  ("Couldn't open sharing", End confirmation) are outside the one-alert-at-a-time gate.
- Mixed builds degrade (old listeners on owners-only shares wait at 0 %): update both phones.
- Late-join resends send one message per piece (M4, parked).
- New strings are English in every lproj; mark for translation before release.
- Own copy: other editions/recordings never match; plays at the sharer's file boundaries (±2 s).

## Open problems and next steps (in order)
1. Re-review the final review fixes (this commit).
2. Two-device run (list above); record results here and in Notes.md.
3. Merge into develop (ask Becky); TestFlight build 2 after her approval.
4. Parked minors: M3 protocol version, M4 late-join resend, M7 endNotice (unused outside the service), M8
   two notification-permission checks. Change A (streamed-book alert). Upstream PR decision later.

## Decisions waiting on Becky
- TestFlight build 2 from develop after the merge: approve?
- A killed sharer that iOS keeps in the roster never ends listeners' sessions (silence ruling). OK?
- After 60 s the listener sees "The person sharing left. Listen Together ended." (spec); one sentence for
  both endings instead?
- Siri dialog / CarPlay alert for the R39 refusal (not built)?
