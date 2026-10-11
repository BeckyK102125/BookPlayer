# context.md - current snapshot

Date: 2026-10-11

## Goal
SharePlay "Listen Together" in Becky's fork of BookPlayer: one person shares a downloaded audiobook (from
Messages with no call, or on a FaceTime call); the others listen to a temporary copy (deleted when the
session ends) or their own copy; playback stays in sync; everything works with VoiceOver, and every
important message is also seen (Zoom, low vision).
Current goal: build 4, start-position fix (build 3 started at 0:00 and reset Michael's saved place; his
progress is the top priority). Docs: started-over-investigation.md, start-position-brief.md,
start-position-fix-round-1.md, start-position-report.md. Waiting for review, then TestFlight build 4.
- Specs/plans: docs/superpowers/. Guide: docs/Listen-Together-Guide.md. Ledger, briefs, reports, rulings:
  .superpowers/sdd/2026-10-10-shareplay-listen-together/ (progress.md).

## Branches and remotes
- origin = github.com/BeckyK102125/BookPlayer (Becky's fork, public). upstream = TortugaPower/BookPlayer.
- On origin: `develop` (85c42b29, pushed 2026-10-11), `listen-together-messages` (9c70dd06),
  `listen-together-lock-screen` (63e9578b), `shareplay-listen-together` (e634f5c7).
- `listen-together-start-position` (local, not pushed; from 77c3037c): 017ab284 fix A-D; this commit =
  fix round 1 (d891ae79); this commit = fix round 2. Clean after the commit.
- `develop` at 77c3037c (notes commits on top of 4f589c33 = transfer fix, build 3; earlier history
  (addenda 2-3, Tasks A-B, final review) in Notes.md). No extra worktrees.
- Never committed: BuildConfiguration/Debug.xcconfig. PlayerManager.swift and Shared/ are untouched.
- Change A (streamed-book alert) of addendum 1 is NOT done.

## TestFlight and devices
- Build 1 (9c70dd06) ended 0.4 s after Play; build 2 (85c42b29) no piece arrived; build 3 (4f589c33) plays
  on FaceTime and Messages but started at 0:00 and reset the sharer's place -> this branch (build 4).
  Both phones must run the same build.
- Device installs: team M9SNPTXA44, bundle app.techopolis.BookPlayer-together, signing on the command
  line only (revert any pbxproj/Info.plist churn).

## Rulings in force (full text in progress.md)
- R1-R39 (see progress.md: sync, stalls, late joiners, Magic Tap, End/escape, own book R36-R39).
- R40: every button Apple-style (SF Symbol + text), 44 pt, Dynamic Type, 4.5:1 text / 3:1 shapes in all 22
  theme variants, one VoiceOver element with a verb label; destructive role on destructive actions.
- R41: every important message is seen: failures and endings as a centred alert with OK (never a timed
  toast or only an announcement); ongoing status as persistent text next to the controls; VoiceOver hears
  each message once.
- Two-finger scrub is always cancel/back. End asks once, Leave asks once, Cancel Sharing acts at once.
- Addendum 3: piece failures and silence never end a session; only the sharer leaving the roster starts
  the 60 s grace; after the sharer ends/leaves, one message, then no Listen Together UI for that book.

## Start-position fix (this branch, build 4; 017ab284 + fix round 1)
- A: `bridge.start(session:)` connects (`coordinateWithSession`), then `transitionToItem`; runs once.
- B: sharer asserts its place (`coordinateSeek`, + rate if the shared book plays) after the transition and
  on every join; place = `groupPosition(for:)`. Never asserts while another book is loaded
  (`canAssertPlace`); with no book loaded only until first confirmed.
- C (+ round 1 I2): listener gate `hasGroupTiming` opens only on a play/seek command (not a pause). Until
  then Play/Pause/skips/speed/position/chapters do nothing (in the player: "Finding the group's place",
  at most every 3 s, no tap haptic; lock screen/AirPods/Control Center: silent `.success`). Visible:
  status line, caption under the controls, Play value, row "finding the group's place, <title>"; times
  "--:--", no bar, no chapter, no lock-screen length or time; a position swipe says nothing. After every
  play/seek command: `.inStep(at:)` to the sharer (at once, then at most one per 2 s, latest time).
  "Ready. Play works now." once if a press was refused and the group is paused (also after the own-copy
  "Joined. Playing your copy.", which waits for the place).
- Round 1 fallback (listener, session clock, stopped by teardown): 3 s `reapplyCurrentItemState`; from 5 s
  `.requestState` every 5 s, every 15 s after the 12 s line (own copy too); 12 s second status line "If
  this doesn't change, choose Leave Listen Together and join again.", said once when it is the visible
  status (not under the grace or waiting lines). Sharer on `.requestState`: `requestReassert()`.
- D (+ round 1 C1/I1): confirmation only from listeners: `TransportEvent.inStep(at:from:)` (participant
  id). Every join re-arms (`rearm()`, protected place = current); established when every awaited joiner
  (ids, or a count) reported in step at the place; joiners who leave or decline stop counting. Coordinator
  commands (incl. the echo) and reports after confirmation never count. Tolerance `max(2, 1.5*rate) + rate`
  playing (+2 s*rate for inStep). `requestReassert()`: one per 3 s, a refused one pending to the end of
  the limit (cancelled by stop/confirm), current place. No `jumpTo` before confirmation; another book is
  never jumped or played. Restore backstop at `stop()`: unconfirmed, no local seek since arming, shared
  book loaded and > 2 s before the protected place.
- Strings (Base + all lproj, English): `listen_together_finding_place`, `_finding_place_slow`,
  `_row_value_finding_place`, `_ready`, `_time_unknown`; `listen_together_joining` removed.
- Mixed builds: a build-3 listener never sends `inStep` (sharer protected all session); build-3 decoding.

## Built before this branch (on develop; details in Notes.md)
- Addendum 2 own copy + owners-only; Task A pieces/scheduler/retries/heartbeat/grace; Task B one message
  path, Speak, Leave; final review fixes; transfer fix (build 3): pieces as `Data` with a chunked messenger
  fallback, readable error logs, End really ends SharePlay.

## Test evidence (2026-10-11, start-position fix round 2)
- ListenTogetherStartPositionTests 57 tests. Round-2 red (old behaviour patched back): 11 failed. Green:
  SharePlay 545/0; full suite 1117/0 (** TEST SUCCEEDED **); TSan 545/0, 0 warnings (** TEST SUCCEEDED **).
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
S. Build 4 first: Michael paused at ~2:13:00 starts from Messages; Becky joins. She hears 2:13:00; his
   library still shows it. Sharer log: "asserting the sharer's place", "a listener is in step at the
   sharer's place", "every listener is at the sharer's place", no "group time ... ignored" followed by a
   jump; listener: "the group's timing is known (7980...)". Repeat: Becky presses Play at once ("Finding
   the group's place" seen, said once, nothing moves, then "Ready. Play works now."); book not open on
   Michael's phone; FaceTime; End before anyone joined; a late third joiner; join at 2x/3x playing (count
   "reasserting" lines); own copy (line only after the place); force a long wait (12 s line, Leave
   reachable, row text); position reads the waiting text, "--:--", no chapter, no lock-screen time;
   lock screen/AirPods/Control Center silent; Zoom 3x, largest text, light/dark, Increase Contrast.
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
- Chunk fallback: no cloud copy; pieces come from the sharer's phone; throughput unmeasured.
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
3. If "Finding the group's place" ever reaches the 12 s line on devices, read which fallback stage (if
   any) brought the place (reapply at 3 s, requestState from 5 s) in the listener's log.
4. Parked minors: M3 protocol version, M4 late-join resend, M7 endNotice (unused outside the service), M8
   two notification-permission checks. Change A (streamed-book alert). Upstream PR decision later.

## Decisions waiting on Becky
- A killed sharer that iOS keeps in the roster never ends listeners' sessions (silence ruling). OK?
- After 60 s: "The person sharing left. Listen Together ended." (spec); one sentence for both endings?
- Siri dialog / CarPlay alert for the R39 refusal (not built)?
