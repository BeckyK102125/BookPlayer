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
- Branch `listen-together-lock-screen` (Change C of addendum 1), from develop at e634f5c7 (which holds
  the whole Listen Together work plus the guide and addendum 1). Last work: Change C (this commit;
  parent e634f5c7). Not pushed. Only worktree. Changes A and B of addendum 1 are NOT on this branch.
- Never committed (gitignored): BuildConfiguration/Debug.xcconfig. Local copy only.
- BookPlayer/Player/PlayerManager.swift is untouched (git diff eb19a92f --stat on it prints nothing).

## What is built
Everything lives in BookPlayer/SharePlay/ (views in SharePlay/Views/), tests in BookPlayerTests/SharePlay/.
Group Activities entitlement and NSSupportsGroupActivities; manifest, messages and GroupActivity; per-share
temporary storage (cleaned at end and at launch); piece planner and splitter (no re-encoding, under 90 MB);
piece timeline; sharer playback target over PlayerManagerProtocol; listener AVPlayer over the pieces;
coordinator bridge (AVDelegatingPlaybackCoordinator); session service state machine and announcements;
UI: More-menu item, banner with End, invitation sheet (presented by MainCoordinator from the topmost
screen), listener screen with a "getting the book" state, needs-FaceTime alert; Magic Tap to the listener.

## Most recent work: addendum 1 Change C (2026-10-10)
- ListenTogetherRemoteCommands (SharePlay/): the AppDelegate remote-command handlers (toggle, play, pause,
  skip fwd/back, next/previous track, seek end, change position) and AppDelegate Magic Tap ask it first.
  During a listener session (state .listening) they go to ListenerPlayer's user* methods; before the book
  details arrive they return .noActionableNowPlayingItem; otherwise PlayerManager runs as before. No new
  addTarget. Skip 30 s; next/previous = chapter (restart-current under 3 s rule), ±30 s without chapters;
  position events coalesced 0.3 s. Skip preferredIntervals [30] + enabled, position command enabled while
  listening; previous values restored after.
- ListenTogetherNowPlaying: pure builder (chapter / book / author, book-level times, rate 0 while paused or
  waiting for a piece, playbackState) and a publisher that publishes only on real changes plus every 15 s
  while playing, and again on didBecomeActive. At the end Now Playing is handed back by calling
  playerManager.pause() on the paused own book (re-publishes its info); with no own book it is cleared.
- Listening-only wording: a sentence added to the invitation; a one-time note for the sharer on the first
  share on the device (UserDefaults key listenTogetherFirstShareNoteSeen). 47 listen_together_* strings.
- Guide: new "With the screen locked" section; the lock-screen known limitation removed.
- Report: .superpowers/sdd/2026-10-10-shareplay-listen-together/change-c-report.md

## Earlier work
Final fix wave (R31, R32) and a11y residuals: see Notes.md and final-fix-report.md.

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
Change C (addendum-a11y-guidance.md C and G), listener phone locked, VoiceOver on:
- Lock screen reads chapter, book, position, buttons; skip buttons say 30 seconds even with a 15 s or
  chapter-skip own setting; play, pause, skip, scrubber, AirPods double and triple press move the shared
  book (not the own book); the other phone hears one announcement per action.
- While waiting for a piece the lock-screen time stops. After unlock and re-lock the shared book is still
  shown (PlayerManager must not overwrite it).
- Discord voice channel + Messages-started session, both phones locked: stays in sync; 5+ minute pause then
  Play from the lock screen; Discord and BookPlayer audio together (Start Speaking had a conflict before).
- Are announcements from the other phone spoken while locked? Is "Listen Together ended" spoken?
- End while locked (from either phone): wake: Now Playing is the own book or empty, never the shared one;
  lock-screen Play and AirPods then control the own book.
- FaceTime-based session: the guide's Magic Tap warning matches what happens.
- A11y residuals: Magic Tap before the book arrives gives no audio; after the getting-book swap focus
  lands on the player heading once.
Also from the a11y guidance (task-10-a11y-guidance.md section 7): the spoken percent changes only at
0/25/50/75; the position slider moves 30 s per swipe, the other side hears "skipped" once; Chapters sheet
focus; Z gesture does nothing on the listener screen; the largest Dynamic Type in portrait and landscape;
Reduce Motion; Voice Control ("Tap Join", "Tap End"); Switch Control and Full Keyboard Access.

## Known limitations
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
- Sleep timer and CarPlay on a listener act on the listener's own library book, not the shared one.
- Change C: Pause pressed while the group waits for a piece does nothing (the listener is already not
  playing); a Discord or Siri interruption pauses the shared book for everyone (ListenerPlayer reports it).
- The listener's speed picker shows no checkmark when the sharer uses a speed that is not one of its presets.
- Other deferred minor items are listed in the ledger (progress.md) under each task.

## Open problems and next steps (in order)
0. Review and merge `listen-together-lock-screen`; Changes A and B of addendum 1 are still to do.
1. Becky decides the three questions below.
2. Set up signing for two devices, install, run the acceptance lists above, record results here and in
   Notes.md.
3. Fix whatever the device run finds (most likely: layout and focus details, piece transitions).
4. Decide whether to push the branch to the fork and whether to offer it upstream.


## Decisions waiting on Becky
- Push the branch to GitHub (origin, the fork)? Not pushed.
- Signing team and bundle ID for device testing: choose them in BuildConfiguration/Debug.xcconfig (from
  Debug.template.xcconfig), and enable the Group Activities capability on that App ID in the Apple
  developer portal.
- Keep the End confirmation dialog, or end immediately?
