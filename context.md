# context.md - current snapshot

Date: 2026-10-11

## Goal
SharePlay "Listen Together" in Becky's fork of BookPlayer: one person shares a downloaded audiobook (from
Messages with no call, or on a FaceTime call); the others listen to a temporary copy (deleted when the
session ends) or their own copy; playback stays in sync; everything works with VoiceOver, and every
important message is also seen (Zoom, low vision).
Current goal: build 4, start-position fix. Build 3 transfers audio and plays (FaceTime and Messages), but
the session started at 0:00 and Michael's own saved place in his book was reset to 0 (protecting the
sharer's progress is the top priority). Investigation: started-over-investigation.md; brief
start-position-brief.md; report start-position-report.md. Branch `listen-together-start-position` (from
develop 77c3037c), not pushed, waiting for review, then TestFlight build 4 and a two-device run.
- Specs and plan: docs/superpowers/specs/, docs/superpowers/plans/. User guide: docs/Listen-Together-Guide.md
- Ledger, briefs, reports, rulings: .superpowers/sdd/2026-10-10-shareplay-listen-together/ (progress.md).
  Latest: started-over-investigation.md, start-position-brief.md, start-position-report.md.

## Branches and remotes
- origin = github.com/BeckyK102125/BookPlayer (Becky's fork, public). upstream = TortugaPower/BookPlayer.
- On origin: `develop` (85c42b29, pushed 2026-10-11), `listen-together-messages` (9c70dd06),
  `listen-together-lock-screen` (63e9578b), `shareplay-listen-together` (e634f5c7).
- `listen-together-start-position` (local, not pushed; parent 77c3037c on develop): this commit = the
  start-position fix A-D with tests, guide and notes. Clean after the commit.
- `develop` at 77c3037c (notes commits on top of 4f589c33 = transfer fix, build 3; earlier history
  (addenda 2-3, Tasks A-B, final review) in Notes.md). No extra worktrees.
- Never committed: BuildConfiguration/Debug.xcconfig. PlayerManager.swift and Shared/ are untouched.
- Change A (streamed-book alert) of addendum 1 is NOT done.

## TestFlight and devices
- Build 1 (9c70dd06) ended 0.4 s after Play; build 2 (85c42b29) no piece arrived; build 3 (4f589c33) plays
  on FaceTime and Messages but started at 0:00 and reset the sharer's place -> this branch (build 4).
  Both phones must run the same build.
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

## Start-position fix (this branch, build 4)
- A: the bridge no longer transitions in `init`. `start(session:)` connects the coordinator
  (`coordinateWithSession`) and only then calls `transitionToItem` (Apple's sample order); runs once.
- B: the sharer then asserts its place with `coordinateSeek(to:)` (+ `coordinateRateChange` if playing).
  The place is `groupPosition(for: item)` (the shared book's saved time when the player holds no book or
  another one). `resendForLateJoiners` (roster growth, count growth, state requests) asserts it again while
  the group is not yet confirmed.
- C: a listener bridge has `hasGroupTiming` = false until its first play/pause/seek command for the item.
  Until then `ListenerPlayer.isJoiningGroup` makes Play/Pause/skips/speed (buttons, lock screen, AirPods,
  Magic Tap, rotor) do nothing and call `onActionWhileJoining`: "Joining…" announced, at most every 3 s
  (`joiningToggleLimiter`). The bridge also drops listener reports before timing. Visible: status line
  "Joining…" (hourglass, percent below while downloading), the caption under the controls and the Play
  button's value (`waitingCaption`), via `isListenerJoining` / `statusConditions.isJoiningGroup`.
- D: `SharerPlaybackTarget(playerManager:sharedItemUUID:startPosition:)`. Until a group play/seek arrives
  within 2 s of the sharer's own place (`isGroupEstablished`), other times are not applied: no `jumpTo`
  (it always saves progress), play/pause where it is, `.reasserted(at:)` -> the bridge coordinates a seek
  there on the next main-queue turn (after the command completes). Pauses never establish. Another book is
  never jumped or played. Backstop at `stop()`: unconfirmed, no local seek, shared book now more than 2 s
  before the start -> `jumpTo(start)`. Group seeks within 0.5 s of where the sharer is no longer jump.
- E: comments say nil timing = "paused at zero". New string `listen_together_joining` ("Joining…") in Base
  and all lproj (English).

## Built before this branch (on develop; details in Notes.md)
- Addendum 2 own copy + owners-only; Task A pieces/scheduler/retries/heartbeat/grace; Task B one message
  path, Speak, Leave; final review fixes; transfer fix (build 3): pieces as `Data` with a chunked messenger
  fallback, readable error logs, End really ends SharePlay.

## Test evidence (2026-10-11, start-position fix)
- New class ListenTogetherStartPositionTests (21 tests). Red with API stubs only: 19 of 21 failed (the 2
  passing guard behaviour that already held). Green: 30 SharePlay classes 508/0; full suite 1080/0
  (** TEST SUCCEEDED **); TSan on the 30 SharePlay classes 508/0, 0 ThreadSanitizer warnings.
- Command: xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -destination 'platform=iOS
  Simulator,id=98A8CF98-8142-4710-AD5E-5419F782752C' -testPlan "Unit Tests" -only-testing:BookPlayerTests
  test (per class `-only-testing:BookPlayerTests/<Class>`; TSan adds `-enableThreadSanitizer YES`).

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
S. Build 4 first (start position): Michael paused at, say, 2:13:00, starts from Messages; Becky joins.
   Becky hears 2:13:00; Michael's library still shows 2:13:00 afterwards. Logs: sharer "asserting the
   sharer's place", "the group is at the sharer's place"; listener "the group's timing is known"; no
   "Time = 0.0" rate change. Repeat with Becky pressing Play at once on join ("Joining…" seen and heard
   once, nothing moves), with the book not open in Michael's player, on FaceTime, and with End before
   anyone joined (Michael's place unchanged). Check "Joining…" at Zoom 3x and in the 11 themes.
0. Build 3 checks still open: which path carried the pieces (journal `uploaded piece` or `transport mode
   chunks`, rate at least 32 KB/s); SharePlay indicator gone after End.
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
- The sharer's exported pieces take about the book's size in tmp until the session ends (journal mode;
  in chunk mode only the 3 latest are kept).
- Chunk fallback: no cloud copy; late joiners get pieces from the sharer's phone (bandwidth per listener);
  messenger throughput is undocumented and unmeasured.
- A piece that fails for good is retried every 30 s (sharer sees the retry status); listeners wait.
- If the sharer switches books mid-session, listeners keep the old book (R12).
- A killed sharer that iOS keeps in the roster never ends listeners' sessions (they see the silence line).
- Own book can't start from Siri/widget/CarPlay while locked during a listener session (R38/R39).
- Notifications dormant (no permission asked); SwiftUI alerts are outside the one-alert gate.
- Mixed builds degrade (old listeners on owners-only shares wait at 0 %): update both phones.
- New strings are English in every lproj; mark for translation before release.
- Own copy: other editions/recordings never match; plays at the sharer's file boundaries (±2 s).

## Open problems and next steps (in order)
1. Review of the start-position branch; merge to develop; TestFlight build 4 (Becky approves upload).
2. Two-device run on build 4 (item S first, then the list above); record results here and in Notes.md.
3. If a listener ever stays on "Joining…" (no coordinator command arrives), there is no fallback yet:
   decide one from the device logs (for example `reapplyCurrentItemStateToPlaybackControlDelegate`).
4. Parked minors: M3 protocol version, M4 late-join resend, M7 endNotice (unused outside the service), M8
   two notification-permission checks. Change A (streamed-book alert). Upstream PR decision later.

## Decisions waiting on Becky
- A killed sharer that iOS keeps in the roster never ends listeners' sessions (silence ruling). OK?
- After 60 s the listener sees "The person sharing left. Listen Together ended." (spec); one sentence for
  both endings instead?
- Siri dialog / CarPlay alert for the R39 refusal (not built)?
