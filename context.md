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
  the whole Listen Together work plus the guide and addendum 1). Last work: escape goes back + Listen
  Together status row, R35/R36 (this commit; parent 54399521, guide for R34). Not pushed. Only worktree. Changes A and B of addendum 1 are NOT on this branch.
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

## Most recent work: escape goes back + Listen Together row (R35, R36; 2026-10-10)
- Escape on the listener screen and "Getting the book" closes the screen only (never ends, pauses or
  starts anything). ListStateManager.isListenerScreenRequested (user intent): on at session start and
  from the row; off after escape, a system dismissal, session end or a new invitation. Pure functions in
  ListenTogetherPresentation: showsListenerScreen(..., isRequested:), isListenerScreenRequested(after:),
  closeListenerScreen(listState:) (takes no service), focusesRowAfterListenerScreenCloses.
- ListenTogetherStatusRow (SharePlay/Views/): one Button, label "Listen Together", value "playing, Moby
  Dick" / paused / waiting / "getting the book, N percent" (25 percent steps) / "sharing, title"; hint;
  id listenTogether.row; no End. MainView stacks it above the mini player in the mini player slot (one
  bottom clearance, moved out of MiniPlayerView). Listener: own mini player hidden (R36); sharer: row +
  mini player. iOS 26.0 accessory: listener = row; sharer = mini player with the sharing value.
  After escape (or a sharer closing the player) focus goes to the row after 500 ms.
- 8 new listen_together_row_* keys in all 26 Localizable.strings. Guide updated (guidance section 8).
- Report: .superpowers/sdd/2026-10-10-shareplay-listen-together/escape-row-report.md

## Earlier work
- Addendum 1 Change C (lock screen, Control Center, AirPods control the shared book; first-share note with
  Share/Cancel, R33/R34): ListenTogetherRemoteCommands, ListenTogetherNowPlaying. See Notes.md and
  change-c-report.md. Final fix wave (R31, R32): final-fix-report.md.

## Test evidence (2026-10-10)
- Escape + row: ListenTogetherRowTests 19 tests, 0 failures; full suite "Executed 712 tests, with 0 failures" (rerun; first run hit an unrelated CoreData flake).
- Before (Change C fix round 2): 693 tests, 0 failures. Command: xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -destination
  'platform=iOS Simulator,id=98A8CF98-8142-4710-AD5E-5419F782752C' -testPlan "Unit Tests"
  -only-testing:BookPlayerTests test.
- Release build (Change C): `-configuration Release -destination 'generic/platform=iOS Simulator' build` OK.
- SharePlay itself cannot run in the simulator (no FaceTime).

## Local environment gotchas
- This Mac has Xcode 27; upstream CI uses Xcode 26.4. Xcode 27 resolves "iPhone 17" to nothing, so use
  the simulator by id 98A8CF98-8142-4710-AD5E-5419F782752C (iPhone 17, iOS 26.5, machine specific).
- xcodebuild prints intermediate "Executed N tests" summaries; wait for ** TEST SUCCEEDED/FAILED **. It
  can hang after that (or after "Selected tests failed"): log to a file, poll, then `pkill -x xcodebuild`.
- Project file editing: the project uses classic groups, so new files must be registered. Helper:
  /private/tmp/bp-tools/add_to_xcodeproj.py with /private/tmp/bp-tools/venv/bin/python (pbxproj 4.2.1).
  /private/tmp is swept weekly (Sundays); Notes.md (Task 0 entry) says how to rebuild it. Keep it until
  the branch is merged or abandoned.
- A pre-existing test leaves file.txt in the simulator app's Documents, so the app boots to the Import
  screen instead of the library on that simulator.

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
Escape + row (escape-row-a11y-guidance.md section 11, all 16 items): escape closes, focus on the row,
nothing re-presents the cover, row order and size at AX5, Voice Control "Tap Listen Together".
Change C (addendum-a11y-guidance.md C and G), listener phone locked, VoiceOver on:
- Lock screen reads chapter, book, position, buttons; skips say 30 seconds whatever the own setting (also
  changed mid-session); play, pause, skip, scrubber, AirPods (30 s) move only the shared book.
- While waiting for a piece the lock-screen time stops. After unlock and re-lock the shared book is still
  shown (PlayerManager must not overwrite it).
- Discord voice channel + Messages-started session, both phones locked: stays in sync; 5+ minute pause then
  Play from the lock screen; Discord and BookPlayer audio together (Start Speaking had a conflict before).
- Are announcements from the other phone, and "Listen Together ended", spoken while locked? (Guide hedges.)
- End while locked (from either phone): wake: Now Playing is the own book or empty, never the shared one;
  lock-screen Play and AirPods then control the own book.
- FaceTime-based session: the guide's Magic Tap warning matches what happens.
- First-share note read in full, Share starts sharing, Cancel and Z do not; the 15 s refresh does not re-read the scrubber.
- A11y residuals: Magic Tap before the book arrives gives no audio; after the getting-book swap focus
  lands on the player heading once.
Also from the a11y guidance (task-10-a11y-guidance.md section 7): the spoken percent changes only at
0/25/50/75; the position slider moves 30 s per swipe, the other side hears "skipped" once; Chapters sheet
focus; Z gesture now CLOSES the listener screen (R35; escape-row-a11y-guidance.md section 11 checklist); the largest Dynamic Type in portrait and landscape;
Reduce Motion; Voice Control ("Tap Join", "Tap End"); Switch Control and Full Keyboard Access.

## Known limitations
- Streamed books (AudiobookShelf, Jellyfin, cloud) and video cannot be shared. They are hidden or refused.
- The sharer's exported pieces take about the book's size in tmp until the session ends.
- End asks for confirmation (except while preparing). Becky to decide if it stays.
- If the sharer switches to a different book mid-session, listeners keep the old book (R12).
- While sharing, closing the player hides the status banner and End; the Listen Together row (R35) now
  shows the session and reopens the player.
- A failed piece load is retried only when new pieces arrive (the very last piece may not retry).
- If the sharer's app is killed while the FaceTime call continues, listeners are not stopped; they wait
  (review item I5, R32). Ending the call does end it.
- Speed changes from anyone are applied to the sharer's own player, so the sharer's library saves that
  speed for the book. A listener's own library speed is not affected.
- Sleep timer and CarPlay chapter buttons on a listener act on the own book, not the shared one.
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
