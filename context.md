# context.md - current snapshot

Date: 2026-10-10

## Goal
Add SharePlay "Listen Together" to Becky's fork of BookPlayer: one person shares a local audiobook (from
Messages, or on a FaceTime call), the other listens to a copy that is deleted when the session ends, and playback stays
in sync. Everything must work with VoiceOver.
- Spec: docs/superpowers/specs/2026-10-10-shareplay-listen-together-design.md
- Plan: docs/superpowers/plans/2026-10-10-shareplay-listen-together.md
- Task-by-task ledger, briefs, reports, rulings R1-R32: .superpowers/sdd/2026-10-10-shareplay-listen-together/

## Branch and remotes
- origin = github.com/BeckyK102125/BookPlayer (Becky's fork). upstream = github.com/TortugaPower/BookPlayer.
- Branch `shareplay-listen-together`, started from upstream develop at eb19a92f. NOT pushed anywhere.
- Branch `listen-together-messages` (Change B of addendum 1), from develop at 63e9578b (which holds Change
  C, escape + row R35/R36). Last work: Change B fix round 1, R37 (this commit; parent f2ad757b). Not pushed. Only
  worktree, clean after commit. Change A (streamed-book alert) is NOT done yet.
- Never committed (gitignored): BuildConfiguration/Debug.xcconfig. Local copy only.
- BookPlayer/Player/PlayerManager.swift is untouched (git diff eb19a92f --stat on it prints nothing).

## What is built
Everything lives in BookPlayer/SharePlay/ (views in SharePlay/Views/), tests in BookPlayerTests/SharePlay/.
Entitlement; manifest, messages, GroupActivity; per-share temp storage (cleaned at end and launch); piece
planner and splitter (no re-encoding); sharer target over PlayerManagerProtocol; listener AVPlayer; coordinator
bridge; session service state machine and announcements; More-menu item, banner with End, invitation sheet
(topmost screen), listener screen, sharing sheet (Change B), fallback alert; Magic Tap to the listener.

## Most recent work: Change B, start from Messages (2026-10-10)
- Not on a FaceTime call: Apple's GroupActivitySharingController opens (from MainCoordinator's topmost
  screen, after 600 ms) instead of the FaceTime alert. Pure SharePlaySessionService.startRoute decides
  activate / sharingSheet / needsFaceTime (fallback only when the sheet can't be created or shown).
- Sheet up: share pending, no banner, nothing announced. Cancel: cancelled at once, "Listen Together was
  not started." 0.7 s later. Sent: "Preparing <title> to share" at 0.7 s if no session yet; no session by
  20 s (R37) = released, "Listen Together didn't start. Try again.", but a later session is still started
  if the device is idle ("Listen Together started"); left if another share is pending or running.
- Stuck sheet (B2.7): presenter returns .abandoned if the sheet leaves the screen (1 s polls, foreground
  check) without a result; 120 s watchdog in the service. Both release the share (not cancelled).
- Result announcements keyed to the share ID. Invitation strings drop FaceTime; fallback "Couldn't open
  sharing"; guide "Two ways to start", Magic Tap hedged. Report: change-b-report.md (sdd folder).

## Earlier work
- Escape goes back + Listen Together row (R35, R36): escape-row-report.md.
- Addendum 1 Change C (lock screen, Control Center, AirPods control the shared book; first-share note with
  Share/Cancel, R33/R34): ListenTogetherRemoteCommands, ListenTogetherNowPlaying. See Notes.md and
  change-c-report.md. Final fix wave (R31, R32): final-fix-report.md.

## Test evidence (2026-10-10)
- Change B fix 1: ListenTogetherSharingSheetTests 17 tests; full suite "Executed 733 tests, with 0 failures".
- Before (escape + row fix round 1): 716 tests, 0 failures. Command: xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -destination
  'platform=iOS Simulator,id=98A8CF98-8142-4710-AD5E-5419F782752C' -testPlan "Unit Tests"
  -only-testing:BookPlayerTests test.
- SharePlay cannot run in the simulator (no FaceTime). Release build (Change C): `-configuration Release -destination 'generic/platform=iOS Simulator' build` OK.

## Local environment gotchas
- This Mac has Xcode 27; upstream CI uses Xcode 26.4. Xcode 27 resolves "iPhone 17" to nothing, so use
  the simulator by id 98A8CF98-8142-4710-AD5E-5419F782752C (iPhone 17, iOS 26.5, machine specific).
- xcodebuild prints intermediate "Executed N tests" summaries; wait for ** TEST SUCCEEDED/FAILED **. It
  can hang after that (or after "Selected tests failed"): log to a file, poll, then `pkill -x xcodebuild`.
- Never pass -derivedDataPath (see ~/.claude/CLAUDE.md). "Invalid API Key" lines in test output are expected noise.
- Project file editing: the project uses classic groups, so new files must be registered. Helper:
  /private/tmp/bp-tools/add_to_xcodeproj.py with /private/tmp/bp-tools/venv/bin/python (pbxproj 4.2.1).
  /private/tmp is swept weekly (Sundays); Notes.md (Task 0 entry) says how to rebuild it. Keep it until
  the branch is merged or abandoned.
- A pre-existing test leaves file.txt in the simulator app's Documents, so the app boots to the Import
  screen instead of the library on that simulator.

## Device and assistive-technology acceptance
Status: NOT STARTED. No real-device run has happened. Needs two devices (iOS 18.0 or later), signed with a team and bundle ID that has the Group Activities capability (see decisions).

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
Change B (addendum-a11y-guidance.md B and G), VoiceOver on:
- Start from Messages with no call: sheet read in full; "Preparing" heard after it closes; focus back on
  More (after Cancel too). Does the sheet close itself? MEASURE seconds from Send to the session arriving
  (decides whether 20 s is right). Two-finger scrub on the sheet must give .cancelled ("not started").
- VERIFY: a refused presentation leaves presentingViewController nil (fallback alert shown, not silence).
- Listener opens the Messages invitation: BookPlayer opens, "Listen Together invitation: ..." spoken.
- Discord voice + Messages session, both phones locked (see Change C items); Magic Tap in a Discord call.
- Cancel the sheet (button and Z): "not started"; More offers it again. Background the app, lock, or close the player while the sheet is up: within ~2 s of return Listen
  Together is back in More (or after 120 s at worst). Are the result announcements heard when locked?
- First-share note read in full, Share starts sharing, Cancel and Z do not; the 15 s refresh does not re-read the scrubber.
- A11y residuals: Magic Tap before the book arrives gives no audio; after the getting-book swap focus
  lands on the player heading once.
Also task-10-a11y-guidance.md section 7 (percent steps, 30 s slider, Chapters focus, Z closes the listener
screen, largest Dynamic Type, Reduce Motion, Voice Control, Switch Control, Full Keyboard Access).

## Known limitations
- Streamed books (AudiobookShelf, Jellyfin, cloud) and video cannot be shared. They are hidden or refused.
- The sharer's exported pieces take about the book's size in tmp until the session ends.
- End asks for confirmation (except while preparing). Becky to decide if it stays.
- If the sharer switches to a different book mid-session, listeners keep the old book (R12).
- A failed piece load is retried only when new pieces arrive (the very last piece may not retry).
- If the sharer's app is killed while the FaceTime call continues, listeners wait (I5, R32).
- Speed changes from anyone are saved in the sharer's library for that book (not the listener's).
- Sleep timer and CarPlay chapter buttons on a listener act on the own book, not the shared one.
- Change C: Pause pressed while the group waits for a piece does nothing (the listener is already not
  playing); a Discord or Siri interruption pauses the shared book for everyone (ListenerPlayer reports it).
- The listener's speed picker shows no checkmark when the sharer uses a speed that is not one of its presets.
- New Change B strings are English in every lproj; mark them for translation before release.
- Other deferred minor items are listed in the ledger (progress.md) under each task.

## Open problems and next steps (in order)
0. Review and merge `listen-together-messages` (Change B); Change A of addendum 1 is still to do.
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
