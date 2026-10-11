# context.md - current snapshot

Date: 2026-10-11

## Goal
SharePlay "Listen Together" in Becky's fork of BookPlayer: one person shares a downloaded audiobook (from
Messages with no call, or on a FaceTime call); the others listen to a copy that is downloaded for the
session only and deleted when it ends; playback stays in sync; everything works with VoiceOver.
Current goal: addendum 3 (reliable sending, visible messages, spoken errors), after a field test where
the session ended 0.4 s after Play (most likely a failed piece on the sharer). Task A (engine) is done
(87f4a744 .. 9cedab87). Task B (visible messages R41, Leave/Cancel Sharing, R40 fixes, "Speak error
messages") is implemented on top of 9cedab87, awaiting review.
Addendum 2 ("Both have the book") is done on this branch.
- Spec: docs/superpowers/specs/2026-10-10-shareplay-listen-together-design.md
- Addendum 2: docs/superpowers/specs/2026-10-10-shareplay-listen-together-addendum-2.md
- Addendum 3: docs/superpowers/specs/2026-10-11-listen-together-addendum-3-reliable-sending.md;
  Task A brief/report: .superpowers/sdd/.../reliable-sending-task-A-{brief,report}.md
- Plan: docs/superpowers/plans/2026-10-10-shareplay-listen-together.md
- User guide: docs/Listen-Together-Guide.md
- Ledger, briefs, reports, rulings R1-R38: .superpowers/sdd/2026-10-10-shareplay-listen-together/
  (progress.md). Latest report: reliable-sending-task-B-report.md.

## Branches and remotes
- origin = github.com/BeckyK102125/BookPlayer (Becky's fork, public). upstream = TortugaPower/BookPlayer.
- Tracked on origin: `develop`, `listen-together-messages` (both 9c70dd06), `listen-together-lock-screen`
  (63e9578b), `shareplay-listen-together` (e634f5c7). Becky and Michael are testing develop on devices.
- `listen-together-own-copy` (this branch, from develop at 9c70dd06): addendum 2 (de1f5731), fix rounds
  (7bf22248, 0b5aacdd), addendum 3 ruling (1598e8d4), Task A (87f4a744, de116941, d786c79e, 9cedab87),
  Task B (code commit on 9cedab87, then this docs commit). NOT pushed. Clean after commit. Worktree BookPlayer-testflight (detached at
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

## Most recent work: addendum 3 Task B, what people see and hear (2026-10-11)
- One delivery path (ListenTogetherMessages.swift): every message has one plan (alert / status +
  announcement / announcement / speech only); an alert never also announces. Alerts queue in
  ListenTogetherMessageDelivery (one at a time, newest ending replaces pending ones, dropped by a new
  invitation/session); MainCoordinator presents them (UIAlertController, title only, OK = cancel style).
- Sharer End / sharer left (60 s) / couldn't prepare: tearDown first (no "ended" announcement, no banner),
  then one alert ~0.5 s after the listener cover's onDismiss (ListenTogetherCoverTracker); after OK focus
  goes to the mini player when shown. Not active: one local notification if already permitted, else a
  pending alert on next active. sharerLeft uses the spec's sentence (guidance differs; see report).
- E12 unavailable, E13 didn't start, E14 prepare failed (EndReason .sendFailed renamed .prepareFailed):
  alerts. Banner status lines: waiting for the person sharing (+ "within a minute" only in the roster
  grace), waiting for the book (+ percent), retrying a piece (sharer), paused by another listener,
  someone couldn't join (sharer). Zoom caption under the listener controls (VoiceOver hidden) = play
  button value. Play while the sharer is missing does nothing and says why; lock-screen play is silent.
- Settings > Playback > Listen Together > Messages: "Speak error messages" (off, listenTogetherSpeakErrors)
  + "Hear a Sample". ListenTogetherSpeaker: one AVSpeechSynthesizer, prefersAssistiveTechnologySettings
  only, usesApplicationAudioSession=false, mixToTelephonyUplink=false, silent with VoiceOver (checked at
  speak time; stops when it turns on) and in connected calls, background task per utterance.
- Leave Listen Together (listener, asks once; confirmation lives in ListenTogetherListenerScreen),
  Cancel Sharing (preparing, at once), End Listen Together (sharer). R40 fixes: Join/Not Now with
  symbols; primary colour for status icon, transport icons, Chapters, Speed (+ gauge), A9 texts.
- Task A (87f4a744 .. 9cedab87): ~12 min pieces, send-ahead scheduler (.needPiece), piece failures never
  end the session (back-off 2/5/15/30 s), sharer kept awake + background task per piece, AVQueuePlayer,
  .requestState, heartbeat; sharer leaving the roster -> 60 s grace -> .sharerLeft; silence only shows
  .waitingForSharer; ended shares never rejoined; diagnostics with domain/code. Details in Notes.md.

## Test evidence (2026-10-11, addendum 3 Task B)
- 24 SharePlay classes 373/0 (new: ListenTogetherMessagesTests 31, ListenTogetherSpeakerTests 9,
  ListenTogetherContrastTests 3); full 945/0 ** TEST SUCCEEDED **; TSan 24 classes 373/0, 0 warnings.
Command: xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -destination 'platform=iOS
Simulator,id=98A8CF98-8142-4710-AD5E-5419F782752C' -testPlan "Unit Tests" -only-testing:BookPlayerTests test
(per class `-only-testing:BookPlayerTests/<Class>`; TSan adds `-enableThreadSanitizer YES`). Session tests use
coordinatorControlFactory: ending a real stall suspension aborts in CoreMedia under TSan only.

## Local environment gotchas
- Xcode 27 here, CI uses 26.4. Use the simulator by id 98A8CF98-8142-4710-AD5E-5419F782752C.
- Wait for the FINAL ** TEST SUCCEEDED/FAILED **; xcodebuild can hang after it: log to a file, poll, then
  kill your own xcodebuild. Never pass -derivedDataPath. "Invalid API Key" lines are noise.
- New files must be registered (classic groups): copy an existing file's four pbxproj lines (build file,
  file ref, group, sources phase) with new ids, as Task B did (Notes.md).
- A pre-existing test leaves file.txt in the simulator app's Documents (app boots to Import there).
- TSan on the whole suite stops at a pre-existing DirectoryWatcher race; run SharePlay classes by name.

## Device and assistive-technology acceptance
Field test of 5.22.2 (1) failed (ended after Play, addendum 3). Two-device run of Task A + B NOT done.
Setup: Becky + Michael, two iPhones, Discord, session from Messages, both locked.
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
10. Task B list in reliable-sending-task-B-report.md. Earlier lists (spec, escape/row, Change B/C, contrast)
still apply; see Notes.md and the a11y guidance files.

## Known limitations
- Streamed books and video cannot be shared (hidden or refused).
- The sharer's exported pieces take about the book's size in tmp until the session ends.
- A piece that fails for good is retried every 30 s for ever; listeners who need it wait. The sharer
  sees "Couldn't send part of the book. Trying again." Sharer E6b ("others waiting") is not shown.
- If the sharer switches books mid-session, listeners keep the old book (R12).
- If the sharer's app is killed, listeners end 60 s after iOS removes the sharer from the roster; if iOS
  keeps them, listeners only see "waiting for the sharer" (silence never ends a session; open question).
- Speed changes are saved in the sharer's library; sleep timer/CarPlay chapters on a listener: own book.
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
1. Review Task B (code + a11y). Its device checks are in reliable-sending-task-B-report.md (ducking, Siri
   voice, speech while locked, alert after the cover, Zoom 3x, AX5, focus after OK and after Leave).
2. Two-device run of Task A + B (list above); record results here and in Notes.md.
3. Merge into develop (ask; Becky and Michael test develop).
4. Change A (streamed-book alert) of addendum 1. 5. Upstream PR decision later.

## Decisions waiting on Becky
- A killed sharer that iOS keeps in the roster never ends listeners' sessions (silence ruling). OK?
- TestFlight: record whether a TestFlight build is wanted (and under which bundle ID) or device installs only.
- Siri dialog / CarPlay alert for the R39 refusal (not built: would need intent result dialogs and a
  CarPlay alert template)?
- Task B: after 60 s the listener sees the spec's "The person sharing left. Listen Together ended."; the
  a11y guidance wanted the same sentence as End. Keep, or use one sentence for both?
