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
  R24 no menu icon; R26 superseded by Change C; R27 End asks for confirmation once (decided: it stays).
- R32 final fix wave; R33 AirPods next/previous = 30 s; R34 first-share note Share/Cancel.
- R35 escape on the listener screen goes back to the library, session continues (supersedes R25,
  approved by Becky); R36 listener hides the own mini player, Listen Together row (approved with R35).
- R37 sharing-sheet watchdogs, 20 s wait, late share accepted when idle.
- R38 own book during a listener session asks "Leave Listen Together to play this book?" (fix wave 2).
- R39 when that question can't be shown, the refusal is never silent: queued "You're in Listen
  Together. Unlock to play your own book." plus a local notification only if permission already exists.
- Standing rule: VoiceOver two-finger scrub/escape is always cancel or back; never starts or ends.

## Most recent work: fix round 2 (2026-10-10, on top of fix wave 2)
- C1: the Leave alert answered Cancel because UIKit runs action handlers after viewDidDisappear; an
  unanswered disappearance now counts as Cancel only after 0.3 s (hosted XCTest proves the UIKit order).
- R39 refusal feedback; Leave says "You left Listen Together. Playing <title>." (instead of "ended") and
  the player opens with VoiceOver on the title; one Leave alert at a time; Magic Tap before the book says
  "Waiting for the book. Play is not available yet." (queued, once per 2 s); toggle-while-waiting said at
  most once per 3 s; declined loads don't touch the widget path or push CarPlay Now Playing; wording
  "saved on your iPhone for this session only" everywhere; shorter End hint.

## Fix wave 2 (2026-10-10)
Whole-branch review + concurrency audit fixes, one wave (report: fix-wave-2-report.md):
- R38 gate: PlayerLoaderService.playbackStartGate (set by MainCoordinator). loadPlayer(autoplay: true)
  and the loaded-book paths (widget toggle, deep links, playLastBook) ask during a listener session:
  Leave ends the session then plays; Cancel/escape plays nothing. Background/locked/CarPlay-locked:
  refused (R39 feedback since fix round 2). Pure decision ListenTogetherOwnPlayback; callers don't open the player on Cancel.
- Sheet watchdog waits while the sheet is open; Magic Tap before the book answers in the app too.
- Invitation presentation retried every 0.5 s up to 20 times (cold launch from Messages, refused
  present), then declined.
- Minors: toggle-while-waiting, "started" after sheet shares, replaced late share cancelled, explicit
  main hop for AppDelegate remote commands, unified listen-only wording.
- Concurrency audit: A-I1 sharer PlayerManager sinks hop to the main queue; A-I2 session setup is
  synchronous with the join (no lost End, no leaked joined session); M1 owned upload task; M2 2 s limit on
  the end message; M3 ordered outbox; M4 SharerPlaybackTarget.stop(); M6 weak controller + strict
  diagnostic fixed; M9 coordinator commands in FIFO order. Not done: M5, M7, M8 (see report).

## Test evidence (2026-10-10, fix round 2)
Command: xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -destination
'platform=iOS Simulator,id=98A8CF98-8142-4710-AD5E-5419F782752C' -testPlan "Unit Tests"
-only-testing:BookPlayerTests test (focused/TSan: `-only-testing:BookPlayerTests/<Class>` for the 18
SharePlay classes, TSan adds `-enableThreadSanitizer YES`).
- SharePlay classes (18): 202 tests, 0 failures. Full suite: 774 tests, 0 failures, ** TEST SUCCEEDED **
  (first full run crashed in the known pre-existing InsertBooksTests CoreData flake; rerun clean).
- TSan, SharePlay classes: 202 tests, 0 failures, 0 ThreadSanitizer warnings, no aborts.
- Strict concurrency: last checked at fix wave 2 (0 in SharePlay files); not re-run for round 2.
- Ending a real stall suspension aborts inside CoreMedia under TSan only (wave-2 report, concern 1).

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
2. R38: during a listener session double-tap an own book (library, Search, deep link): question heard,
   Leave ends, says "You left Listen Together. Playing <title>." once (no "ended" on top) and focus lands
   on the player's title; Cancel and two-finger scrub keep the session, play nothing, focus stays on the
   row. Siri/widget/CarPlay while locked: nothing plays; is "Unlock to play your own book" heard?
3. Cold launch from the Messages invitation: the invitation screen appears (W-I5 retries), announced.
4. Sharing sheet left open over 2 minutes: nothing announced; close it: released within ~2 s / next check.
5. Magic Tap before the book arrives, in the app and locked: "Waiting for the book. Play is not
   available yet." once, not stacked on repeated taps.
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
- Own book cannot start from Siri/widget/CarPlay while locked during a listener session (R38/R39
  refuse; spoken when possible; notification only if permission exists, which BookPlayer never asks).
- Invitations from other people are ignored while your own share's sharing sheet is up or its 20 s wait
  is running.
- The `play?showPlayer=true` deep link can open your own player screen during a listener session (its
  Play is not gated).
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
- Siri dialog / CarPlay alert for the R39 refusal (not built: would need intent result dialogs and a
  CarPlay alert template)?
