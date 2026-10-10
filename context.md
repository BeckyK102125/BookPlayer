# context.md - current snapshot

Date: 2026-10-10

## Goal
Add SharePlay "Listen Together" to Becky's fork of BookPlayer: one person shares a local audiobook over
a FaceTime call, the other listens to a copy that is deleted when the session ends, and playback stays
in sync. Everything must work with VoiceOver.
- Spec: docs/superpowers/specs/2026-10-10-shareplay-listen-together-design.md
- Plan: docs/superpowers/plans/2026-10-10-shareplay-listen-together.md
- Task-by-task ledger, briefs, reports, rulings R1-R32: .superpowers/sdd/2026-10-10-shareplay-listen-together/

## Branch and remotes
- origin = github.com/BeckyK102125/BookPlayer (Becky's fork). upstream = github.com/TortugaPower/BookPlayer.
- Branch `shareplay-listen-together`, started from upstream develop at eb19a92f. NOT pushed anywhere.
- Only worktree. Last work: the final fix wave after the whole-branch review (this commit; parent
  f2b926a3). No uncommitted work.
- Never committed (gitignored): BuildConfiguration/Debug.xcconfig. Local copy only.
- BookPlayer/Player/PlayerManager.swift is untouched (git diff eb19a92f --stat on it prints nothing).

## What is built
Everything lives in BookPlayer/SharePlay/ (views in SharePlay/Views/), tests in BookPlayerTests/SharePlay/.
- Capability: the Group Activities entitlement (both entitlements files) and NSSupportsGroupActivities in
  Info.plist.
- Models and activity: the shared-book description (manifest of pieces and chapters), the messages the
  two sides exchange, and the GroupActivity that shows the title in the FaceTime sheet.
- Share storage: a temporary folder per share and role, cleaned when a session ends and at every launch.
- Piece planner and book splitter: a book is cut at file or chapter boundaries into pieces under the
  SharePlay size limit (90 MB planned, 100 MB hard check) without re-encoding. Upload order starts at the
  sharer's current position so the listener can start early.
- Piece timeline: maps book time to the pieces received so far and says which piece is needed next.
- Sharer playback target: watches the sharer's own player through its protocol and turns play, pause,
  seek and speed into events. Detects manual seeks and ignores echoes of remote commands.
- Listener player: the listener's own AVPlayer over the downloaded pieces. Handles gaps (holds everyone
  until the piece arrives), piece changes, speed, audio session, route changes (headphone unplug).
- Coordinator bridge: connects both sides to AVDelegatingPlaybackCoordinator so play, pause, seek and
  rate stay in step; honours the buffering flag.
- Session service and transport: the state machine (idle, preparing, sharing, invitation, listening,
  ended), start, join, decline, end, late joiners, cancelled shares, error handling, and the queued
  VoiceOver announcements (joined, left, skipped, speed, invitation, ended).
- Interface: a "Listen Together" item in the More menu, a status banner with End in the player, an
  invitation sheet, the listener screen (title, banner, 30 s position slider, play/pause, chapters,
  speed, End) and the needs-FaceTime alert. MainCoordinator presents the invitation from the topmost
  view controller so open sheets cannot drop it (R28, R29); MainView sends Magic Tap to the listener (R19).
- 44 listen_together_* strings in every *.lproj (R16), English text in all of them.

## Most recent work: final fix wave (2026-10-10, R31, R32)
- C1: the sharer proposes its real time and rate to the coordinator (CMTimebase snapshot); listeners
  propose nothing. I1: piece seams within 1e-6 s resolve to the next piece; the listener advances to the
  next piece by index. I2 (R31): listener actions are reported before they are applied. I3: a speed
  change made while paused is applied silently on the other devices. I4: removeDuplicates before
  dropFirst in the sharer target. Plus: "0 seconds" in the position value, invitations ignored while
  preparing, and the listener screen shown from Join with a "getting the book" state (title, status, End).
- Report: .superpowers/sdd/2026-10-10-shareplay-listen-together/final-fix-report.md

## Test evidence (2026-10-10)
- Full unit run: xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer
  -destination 'platform=iOS Simulator,id=98A8CF98-8142-4710-AD5E-5419F782752C'
  -testPlan "Unit Tests" -only-testing:BookPlayerTests test
  Result after the final fix wave: "Executed 668 tests, with 0 failures (0 unexpected)" then
  "** TEST SUCCEEDED **" (651 before it, 17 tests added).
- Release build: xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -configuration Release
  -destination 'generic/platform=iOS Simulator' build  ->  ** BUILD SUCCEEDED **.
- Baseline before this work was 572 tests, 0 failures.
- SharePlay itself cannot run in the simulator (no FaceTime); the simulator only proves the app boots to
  the library and nothing crashes.

## Local environment gotchas
- This Mac has Xcode 27; upstream CI uses Xcode 26.4. Xcode 27 resolves "iPhone 17" to nothing, so use
  the simulator by id 98A8CF98-8142-4710-AD5E-5419F782752C (iPhone 17, iOS 26.5, machine specific).
- xcodebuild prints an intermediate "Executed N tests" summary (512, 452, 457 ...) before the real one.
  Wait for ** TEST SUCCEEDED ** or ** TEST FAILED ** and read the last "Executed" line before it.
- xcodebuild test sometimes hangs after printing TEST SUCCEEDED: send output to a log, poll for the
  result line, then kill the xcodebuild you started (pkill -f "xcodebuild -project BookPlayer.xcodeproj").
- Never pass -derivedDataPath (see ~/.claude/CLAUDE.md).
- Project file editing: the project uses classic groups, so new files must be registered. Helper:
  /private/tmp/bp-tools/add_to_xcodeproj.py with /private/tmp/bp-tools/venv/bin/python (pbxproj 4.2.1).
  /private/tmp is swept weekly (Sundays); Notes.md (Task 0 entry) says how to rebuild it. Keep it until
  the branch is merged or abandoned.
- A pre-existing test leaves file.txt in the simulator app's Documents, so the app boots to the Import
  screen instead of the library on that simulator.
- "Invalid API Key" log lines in test output are pre-existing noise.

## Device and assistive-technology acceptance
Status: NOT STARTED. No real-device run has happened. Needs two devices (iOS 18.0 or later, the deployment target) on a FaceTime
call, signed with a team and bundle ID that has the Group Activities capability (see decisions).

Spec checklist, two devices, VoiceOver on, on both:
1. Share a single-file m4b.
2. Share a multi-file book.
3. Pause and seek from each side.
4. Change speed from each side.
5. End from each side.
6. Unplug headphones (see below, each side).
7. Join late.
8. Confirm the listener's copy is deleted (also after a force-quit and relaunch).

Device-only items collected during the build:
- Join while a Settings, ItemDetails or media-servers sheet is open on the listener (Join closes
  everything above the main view; check nothing breaks and focus lands on the listener title).
- An invitation arriving while another screen is being dismissed (must not be lost or stuck).
- Invitation re-presented after an import (or any screen beneath it) closes (R29); no duplicate or loop.
- Focus after End on both sides: lands somewhere sensible; "Listen Together ended" is heard in full.
- Contrast in every theme, light and dark, with Increase Contrast on: text 4.5:1, icons 3:1, including
  the Join button (colour chosen at runtime) and the banner.
- Magic Tap inside the speed menu (system menu, may not reach the listener).
- Speed changes and piece transitions: no audible gap or drift at piece boundaries, at 1x and 2x.
- Headphone unplug on the sharer side, and on the listener side: both pause, the other side is told.
- Late joiner: joins mid-book, gets the right position, hears the remaining pieces in order.
- Listener copy deleted after End, after leaving, and after a crash/force-quit.
Also from the a11y guidance (task-10-a11y-guidance.md section 7): the spoken percent changes only at
0/25/50/75; the position slider moves 30 s per swipe, the other side hears "skipped" once; Chapters sheet
focus; Z gesture does nothing on the listener screen; the largest Dynamic Type in portrait and landscape;
Reduce Motion; Voice Control ("Tap Join", "Tap End"); Switch Control and Full Keyboard Access.

## Known limitations
- Lock-screen and AirPods play/pause still control the user's own library player during a listener
  session, not the shared book (R26, out of scope this version).
- Streamed books (AudiobookShelf, Jellyfin, cloud) and video cannot be shared. They are hidden or refused.
- The sharer's exported pieces take about the book's size in tmp until the session ends.
- End asks for confirmation (except while preparing). Becky to decide if it stays.
- If the sharer switches to a different book mid-session, listeners keep the old book (R12).
- While sharing, closing the player hides the status banner and End (a11y review M-1).
- A failed piece load is retried only when new pieces arrive (the very last piece may not retry).
- A pre-existing test leaves file.txt in the simulator app's Documents (see gotchas).
- If the sharer's app is killed while the FaceTime call continues, listeners are not stopped; they wait
  (review item I5, R32). Ending the call does end it.
- Speed changes from anyone are applied to the sharer's own player, so the sharer's library saves that
  speed for the book. A listener's own library speed is not affected.
- Sleep timer, CarPlay and the lock screen on a listener act on the listener's own library book, not the
  shared one (R26 family).
- The listener's speed picker shows no checkmark when the sharer uses a speed that is not one of its presets.
- Other deferred minor items are listed in the ledger (progress.md) under each task.

## Open problems and next steps (in order)
1. Becky decides the three questions below.
2. Set up signing for two devices, install, run the acceptance lists above, record results here and in
   Notes.md.
3. Fix whatever the device run finds (most likely: layout and focus details, piece transitions).
4. Decide whether to push the branch to the fork and whether to offer it upstream.

## A11y residuals (2026-10-10)
Magic Tap during getting-book and the getting-book to player focus delay are fixed (Notes.md, 2026-10-10).
On device, verify: Magic Tap before the book arrives gives no audio; after the swap focus lands on the
player heading once, from title, status and End.

## Decisions waiting on Becky
- Push the branch to GitHub (origin, the fork)? Not pushed.
- Signing team and bundle ID for device testing: choose them in BuildConfiguration/Debug.xcconfig (from
  Debug.template.xcconfig), and enable the Group Activities capability on that App ID in the Apple
  developer portal.
- Keep the End confirmation dialog, or end immediately?
