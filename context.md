# context.md - current snapshot

Date: 2026-10-10

## Goal
SharePlay "Listen Together" in Becky's fork of BookPlayer: one person shares a downloaded audiobook (from
Messages with no call, or on a FaceTime call); the others listen to a copy that is downloaded for the
session only and deleted when it ends; playback stays in sync; everything works with VoiceOver.
- Spec: docs/superpowers/specs/2026-10-10-shareplay-listen-together-design.md
- Plan: docs/superpowers/plans/2026-10-10-shareplay-listen-together.md
- User guide: docs/Listen-Together-Guide.md
- Ledger, briefs, reports, rulings R1-R38: .superpowers/sdd/2026-10-10-shareplay-listen-together/
  (progress.md). Latest report: fix-wave-2-report.md.

## Branches and remotes
- origin = github.com/BeckyK102125/BookPlayer (Becky's fork, public). upstream = TortugaPower/BookPlayer.
- Pushed to origin: `develop` (63e9578b), `shareplay-listen-together` (e634f5c7),
  `listen-together-lock-screen` (63e9578b). develop was fast-forwarded twice (to e634f5c7, then to
  63e9578b), each time with Becky's approval.
- `listen-together-messages` (this branch, from develop at 63e9578b): Change B (start from Messages), its
  fix round (R37), and fix wave 2 (this commit; parent cd821236). NOT pushed. Only worktree; clean after
  commit. Change A (streamed-book alert) is NOT done.
- Never committed: BuildConfiguration/Debug.xcconfig (gitignored; holds the signing below).
- BookPlayer/Player/PlayerManager.swift and Shared/ are untouched.

## Signing and device install (settled)
- Team Techopolis (M9SNPTXA44), bundle ID app.techopolis.BookPlayer-together (existing App ID; the
  lowercase variant clashed), BookPlayer-NoCarPlay entitlements. Local Debug.xcconfig only.
- Installed on Becky's iPhone 15 Pro from listen-together-lock-screen @ 54399521 (Debug, automatic
  signing). Xcode wrote signing into project.pbxproj and reordered Info.plist: reverted, never committed.
  Pass signing overrides on the command line for device builds; revert any pbxproj/Info.plist churn.
- BookPlayer backend, account and sync do not work under this bundle ID.

## Rulings in force (full text in progress.md)
- R1-R11: build plumbing (test seams, paths, simulator id, helper, attribution, notes schedule).
- R12 sharer switching books is out of scope; R13 seek detection; R14/R31 a listener's play into a
  missing piece is sent first and the stall suspension holds the group; R15 buffering flag on seek/pause.
- R16 new strings in every lproj (English); R17/R18 late joiners and participant baseline.
- R19 Magic Tap to the listener; R20 menu item hidden mid-session; R21/R28/R29 invitation from the
  topmost screen, re-presented if taken down; R22 needs-FaceTime acknowledge; R23 fixed 30 s skips;
  R24 no menu icon; R26 superseded by Change C; R27 End asks for confirmation (open decision).
- R32 final fix wave; R33 AirPods next/previous = 30 s; R34 first-share note Share/Cancel.
- R35 escape on the listener screen goes back to the library, session continues (supersedes R25,
  approved by Becky); R36 listener hides the own mini player, Listen Together row (approved with R35).
- R37 sharing-sheet watchdogs, 20 s wait, late share accepted when idle.
- R38 own book during a listener session asks "Leave Listen Together to play this book?" (fix wave 2).
- Standing rule: VoiceOver two-finger scrub/escape is always cancel or back; never starts or ends.

## Most recent work: fix wave 2 (2026-10-10)
Whole-branch review + concurrency audit fixes, one wave (report: fix-wave-2-report.md):
- R38 gate: PlayerLoaderService.playbackStartGate (set by MainCoordinator). loadPlayer(autoplay: true)
  and the loaded-book paths (widget toggle, deep links, playLastBook) ask during a listener session:
  Leave ends the session then plays; Cancel/escape plays nothing. Background/locked/CarPlay-locked:
  refused silently. Pure decision ListenTogetherOwnPlayback; callers don't open the player on Cancel.
- Sheet watchdog (120 s) re-checks instead of releasing while the sheet is still presented.
- Magic Tap before the book arrives says "Not available yet" in the app too (MainView, getting-book).
- Invitation presentation retried every 0.5 s up to 20 times (cold launch from Messages, refused
  present), then declined.
- Minors: toggle while the group is held for our piece sends nothing and says "Waiting..."; "Listen
  Together started" after every sheet share (once); a replaced late share is cancelled; "didn't start"
  not spoken over an invitation; listen-only wording unified (invitation, End hint, first-share note,
  guide); AppDelegate remote commands go through ListenTogetherRemoteCommands.route (explicit main hop).
- Concurrency audit: A-I1 sharer PlayerManager sinks hop to the main queue; A-I2 session setup is
  synchronous with the join (no lost End, no leaked joined session); M1 owned upload task; M2 2 s limit on
  the end message; M3 ordered outbox; M4 SharerPlaybackTarget.stop(); M6 weak controller + strict
  diagnostic fixed; M9 coordinator commands in FIFO order. Not done: M5, M7, M8 (see report).

## Test evidence (2026-10-10, fix wave 2)
Command: xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -destination
'platform=iOS Simulator,id=98A8CF98-8142-4710-AD5E-5419F782752C' -testPlan "Unit Tests"
-only-testing:BookPlayerTests test (plus `-only-testing:BookPlayerTests/<Class>` for each of the 17
SharePlay classes for the focused and TSan runs).
- SharePlay classes (17): Executed 191 tests, 0 failures, ** TEST SUCCEEDED **.
- Full suite: Executed 763 tests, 0 failures, ** TEST SUCCEEDED ** (was 733).
- Thread Sanitizer, SharePlay classes: 191/0, 0 ThreadSanitizer warnings. Caveat: ending a real stall
  suspension aborts inside CoreMedia under TSan only (report concern 1; device check).
- Strict concurrency (complete, local build only): 0 diagnostics in SharePlay files.
- SharePlay cannot run in the simulator (no FaceTime/Messages sessions). Before this wave: 733/0.

## Local environment gotchas
- Xcode 27 here, CI uses 26.4. Use the simulator by id 98A8CF98-8142-4710-AD5E-5419F782752C.
- Wait for the FINAL ** TEST SUCCEEDED/FAILED **; xcodebuild can hang after it: log to a file, poll, then
  kill your own xcodebuild. Never pass -derivedDataPath. "Invalid API Key" lines are noise.
- New files must be registered (classic groups): /private/tmp/bp-tools/add_to_xcodeproj.py with
  /private/tmp/bp-tools/venv/bin/python (pbxproj 4.2.1). /private/tmp is swept weekly; Notes.md (Task 0)
  says how to rebuild it.
- A pre-existing test leaves file.txt in the simulator app's Documents (app boots to Import there).
- TSan on the whole suite stops at a pre-existing DirectoryWatcher race; run SharePlay classes by name.

## Device and assistive-technology acceptance
Status: install done on Becky's iPhone 15 Pro (from 54399521). Two-device run NOT done yet. Setup for
the run: Becky + Michael, two iPhones, talking on Discord, session started from Messages, both locked.
Priority checks (new or risky):
1. Paused + locked: pause from one phone, lock both, wait 5+ minutes, Play from the lock screen. Test from
   EACH side (sharer paused, listener paused). If iOS suspends the paused app the session may drop
   (architectural if so; whole-branch I4).
2. R38: during a listener session double-tap an own book: question heard, Leave ends and plays, Cancel
   and two-finger scrub keep the session and play nothing. Siri/widget while locked: nothing plays.
3. Cold launch from the Messages invitation: the invitation screen appears (W-I5 retries), announced.
4. Sharing sheet left open over 2 minutes: nothing announced; close it: released within ~2 s / next check.
5. Magic Tap before the book arrives, in the app and locked: "Not available yet".
6. Join then End at once; End as the sharer with no network: the other phone sees the end, this phone
   leaves within ~2 s.
7. Lock-screen and AirPods commands, Magic Tap: run on main (Main Thread Checker) during a session.
8. Toggle while waiting for a piece: "Waiting for the book to download", the other phone keeps waiting.
Earlier lists still apply (unchanged, see Notes.md and the a11y guidance files): spec checklist (single and
multi-file book, pause/seek/speed/end from each side, headphone unplug, late join, copy deleted incl.
after force-quit); escape + row items; Change C lock-screen items; Change B sheet items (measure Send to
session time; refused presentation leaves presentingViewController nil); contrast in every theme.

## Known limitations
- Streamed books and video cannot be shared (hidden or refused).
- The sharer's exported pieces take about the book's size in tmp until the session ends.
- If the sharer switches books mid-session, listeners keep the old book (R12).
- If the sharer's app is killed while the call continues, listeners wait (I5, R32).
- Speed changes are saved in the sharer's library for that book.
- Sleep timer and CarPlay chapter buttons on a listener act on the own book.
- Own book cannot start from Siri/widget/CarPlay while locked during a listener session (R38 refuse).
- In-app paths that call PlayerManager directly (player screen Play, mini player) are not gated; they are
  hidden or closed during a listener session (R21, R36).
- The listener's speed picker shows no checkmark for a non-preset sharer speed.
- New strings are English in every lproj; mark for translation before release.
- Audio session deactivation at listener end runs on main (M7, deliberately not moved: see report).

## Open problems and next steps (in order)
1. Review fix wave 2 (code + a11y), then merge `listen-together-messages` into develop and push (ask).
2. Build and install the merged result on both iPhones (command-line signing overrides; revert churn).
3. Two-device run (list above); record results here and in Notes.md.
4. Change A (streamed-book alert) of addendum 1.
5. Upstream PR decision later.

## Decisions waiting on Becky
- TestFlight: record whether a TestFlight build is wanted (and under which bundle ID) or device installs only.
- Keep the End confirmation dialog, or end immediately (R27)?
- R38 refuse-when-locked behaviour (silent): acceptable, or should Siri/CarPlay say something?
