# context.md - current snapshot

Date: 2026-10-11

## Goal
SharePlay "Listen Together" in Becky's fork of BookPlayer: one person shares a downloaded audiobook (from
Messages with no call, or on a FaceTime call); the others listen to a copy that is downloaded for the
session only and deleted when it ends; playback stays in sync; everything works with VoiceOver.
Current goal: addendum 3 (reliable sending, visible messages, spoken errors), after a field test where
the session ended 0.4 s after Play (most likely a failed piece on the sharer). Task A (engine, no UI) is done
(87f4a744, fix round 1 in this commit); Task B (visible messages R41, Leave button, "Speak error messages" setting) is next.
Addendum 2 ("Both have the book") is done on this branch.
- Spec: docs/superpowers/specs/2026-10-10-shareplay-listen-together-design.md
- Addendum 2: docs/superpowers/specs/2026-10-10-shareplay-listen-together-addendum-2.md
- Addendum 3: docs/superpowers/specs/2026-10-11-listen-together-addendum-3-reliable-sending.md;
  Task A brief/report: .superpowers/sdd/.../reliable-sending-task-A-{brief,report}.md
- Plan: docs/superpowers/plans/2026-10-10-shareplay-listen-together.md
- User guide: docs/Listen-Together-Guide.md
- Ledger, briefs, reports, rulings R1-R38: .superpowers/sdd/2026-10-10-shareplay-listen-together/
  (progress.md). Latest report: reliable-sending-task-A-report.md.

## Branches and remotes
- origin = github.com/BeckyK102125/BookPlayer (Becky's fork, public). upstream = TortugaPower/BookPlayer.
- Tracked on origin: `develop`, `listen-together-messages` (both 9c70dd06), `listen-together-lock-screen`
  (63e9578b), `shareplay-listen-together` (e634f5c7). Becky and Michael are testing develop on devices.
- `listen-together-own-copy` (this branch, from develop at 9c70dd06): addendum 2 (de1f5731), fix rounds
  (7bf22248, 0b5aacdd), addendum 3 ruling (1598e8d4), Task A (87f4a744, de116941), Task A fix round 1
  in this commit (parent de116941). NOT pushed. Clean after commit. Worktree BookPlayer-testflight (detached at
  9c70dd06) belongs to another session (TestFlight archive); not touched here.
- Change A (streamed-book alert) of addendum 1 is NOT done.
- Never committed: BuildConfiguration/Debug.xcconfig (gitignored; holds the signing below).
- BookPlayer/Player/PlayerManager.swift and Shared/ are untouched.

## Signing and device install (settled)
- Team Techopolis (M9SNPTXA44), bundle ID app.techopolis.BookPlayer-together (existing App ID; the
  lowercase variant clashed), BookPlayer-NoCarPlay entitlements. Local Debug.xcconfig only.
- Installed on Becky's iPhone 15 Pro from listen-together-lock-screen @ 54399521 (Debug, automatic
  signing). Xcode wrote signing into project.pbxproj and reordered Info.plist: reverted, never committed.
  Pass signing overrides on the command line for device builds; revert any pbxproj/Info.plist churn.
  BookPlayer backend, account and sync do not work under this bundle ID.

## Rulings in force (full text in progress.md)
- R1-R11 build plumbing; R12 sharer switching books out of scope; R13-R15, R31 seek/stall/buffering;
  R16 new strings in every lproj (English); R17/R18 late joiners, participant baseline; R19 Magic Tap;
  R20 menu hidden mid-session; R21/R28/R29 invitation from the topmost screen; R22-R24, R27 (End asks
  once), R32-R34; R35 escape on the listener screen goes back, session continues; R36 own mini player
  hidden; R37 sheet watchdogs; R38 own book asks "Leave Listen Together to play this book?"; R39 refusal
  never silent.
- Standing rule: VoiceOver two-finger scrub/escape is always cancel or back; never starts or ends.

## Most recent work: addendum 3 Task A, reliable sending engine (2026-10-11, 87f4a744)
- Pieces ~12 min (max 15, < 90 MB), cut at chapter starts; whole files <= 15 min copied.
- PieceUploadScheduler: listener-requested piece (.needPiece) first, then the group position, forward,
  wrap; re-asked before every piece (a far seek re-prioritises).
- Piece failures never end the session: back-off 2/5/15/30 s, immediate retry on becoming active,
  interruptions (cancel, AVError -11847, background) not counted; notice .retryingSend.
- Sharer awake while pieces are left: idle timer off (restored), background task per piece ended on every
  path (ListenTogetherAppSystem protocol).
- Listener: AVQueuePlayer queues the next arrived piece (seamless); stall released after any load/seek/
  play at an arrived piece; .requestState every 5 s until the manifest (sharer re-sends manifest + map).
- Sharer presence (fix round 1 ruling): heartbeat 5 s; silence > 15 s while the group needs the sharer
  only shows .waitingForSharer (never ends). The sharer leaving the roster (by participant id) holds
  the group; back within 60 s resumes, else .sharerLeft. Sharer End -> .sharerEnded; unreadable book ->
  .sharerCouldNotPrepare; endNotice holds these for Task B. Ended shares are never rejoined.
- Fix round 1 also: failed piece loads retried on a 5-30 s timer; .needPiece for a sent piece re-sends
  its map entry (re-upload if gone); unplayable pieces reloaded; failed pieces go behind others; idle
  timer only reset if we set it; state answers max 1/2 s; tiny pieces merged; one queued heartbeat.
- Diagnostics (os Logger): export/upload start/end with preset/size/time, failures with domain/code,
  app state, stall begin/end, commands, attachment loads, AVPlayerItem failures.
- Earlier: addendum 2 own copy (fingerprint, own-copy playback, owners-only mode); see Notes.md.

## Test evidence (2026-10-11, addendum 3 Task A fix round 1)
- 21 SharePlay classes 327/0; full 899/0 ** TEST SUCCEEDED **; TSan 327/0, 0 warnings. (First pass:
  308/880, TSan 308/0.)
Command: xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -destination
'platform=iOS Simulator,id=98A8CF98-8142-4710-AD5E-5419F782752C' -testPlan "Unit Tests"
-only-testing:BookPlayerTests test (focused/TSan: `-only-testing:BookPlayerTests/<Class>` per SharePlay
class, TSan adds `-enableThreadSanitizer YES`).
- Ending a real stall suspension aborts inside CoreMedia under TSan only (wave-2 report, concern 1);
  new session tests use coordinatorControlFactory (fake control) for that reason.

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
Status: install done on Becky's iPhone 15 Pro (from 54399521). Field test of 5.22.2 (1) failed (session
ended after Play, see addendum 3). Two-device run of Task A NOT done yet. Setup for
the run: Becky + Michael, two iPhones, talking on Discord, session started from Messages, both locked.
Task A checks (first): start from Messages with a long single-file m4b and an mp3 book; listener
plays within seconds; percent moves; no gap at piece joins; sharer switches apps / locks mid-send
(sending resumes, session never ends, listeners may see "waiting for the sharer"); airplane mode on the
sharer 30 s then back; sharer force-quits (ends 60 s after iOS drops them from the roster: measure);
re-tap an ended invitation (nothing happens); pause/seek right after a piece join (position right);
sharer End; capture both devices' Console logs ("Listen Together:").
Priority checks (new or risky; full wording in Notes.md, fix round 2 entry):
1. Paused + locked 5+ minutes, then Play from the lock screen, from EACH side (whole-branch I4).
2. R38/R39: own book during a listener session (question, Leave/Cancel/scrub, focus; locked refusal).
3. Cold launch from the Messages invitation (W-I5 retries). 4. Sharing sheet open over 2 minutes.
5. Magic Tap before the book arrives. 6. Join then End at once; End as sharer with no network.
7. Lock-screen/AirPods commands on main. 8. Toggle while waiting for a piece.
9. Addendum 2: own-copy-a11y-guidance.md device checklist (both modes, decliner, Settings screen).
Earlier lists still apply (unchanged, see Notes.md and the a11y guidance files): spec checklist (single and
multi-file book, pause/seek/speed/end from each side, headphone unplug, late join, copy deleted incl.
after force-quit); escape + row items; Change C lock-screen items; Change B sheet items (measure Send to
session time; refused presentation leaves presentingViewController nil); contrast in every theme.

## Known limitations
- Streamed books and video cannot be shared (hidden or refused).
- The sharer's exported pieces take about the book's size in tmp until the session ends.
- A piece that fails for good (for example always too large) is retried every 30 s for ever; listeners
  who need it wait. The sharer is told only by the .retryingSend notice (Task B shows it).
- If the sharer switches books mid-session, listeners keep the old book (R12).
- If the sharer's app is killed, listeners end 60 s after iOS removes the sharer from the roster; if iOS
  keeps them, listeners only see "waiting for the sharer" (silence never ends a session; open question).
- Speed changes are saved in the sharer's library for that book.
- Sleep timer and CarPlay chapter buttons on a listener act on the own book.
- Own book cannot start from Siri/widget/CarPlay while locked during a listener session (R38/R39
  refuse; spoken when possible; notification only if permission exists, which BookPlayer never asks).
- Invitations are ignored while your own sharing sheet is up or its 20 s wait runs.
- The `play?showPlayer=true` deep link can open your own player screen during a listener session (its
  Play is not gated).
- In-app paths that call PlayerManager directly (player screen Play, mini player) are not gated; they are
  hidden or closed during a listener session (R21, R36).
- The listener's speed picker shows no checkmark for a non-preset sharer speed.
- New strings are English in every lproj; mark for translation before release.
- Own copy: streamed books and other editions/recordings never match; the own copy plays at the
  sharer's file boundaries (files may differ by up to 2 s). Send mode uploads the pieces even when
  everyone so far owns the book.
- Audio session deactivation at listener end runs on main (M7, deliberately not moved: see report).

## Open problems and next steps (in order)
1. Review Task A (code); then Task B: visible messages (R41) for .waitingForSharer, .retryingSend,
   endNotice (.sharerEnded/.sharerLeft, one alert then nothing of the session), download percent;
   Leave/Cancel Sharing buttons (R40); "Speak error messages" setting.
2. Two-device run of Task A + B (list above); record results here and in Notes.md.
3. Merge into develop (ask; Becky and Michael test develop).
4. Change A (streamed-book alert) of addendum 1. 5. Upstream PR decision later.

## Decisions waiting on Becky
- A killed sharer that iOS keeps in the roster never ends listeners' sessions (silence ruling). OK?
- TestFlight: record whether a TestFlight build is wanted (and under which bundle ID) or device installs only.
- Siri dialog / CarPlay alert for the R39 refusal (not built: would need intent result dialogs and a
  CarPlay alert template)?
