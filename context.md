# context.md - current snapshot

Date: 2026-10-20

## Goal
SharePlay "Listen Together" in Becky's fork of BookPlayer: one person shares a downloaded audiobook (from
Messages with no call, or on a FaceTime call); the others listen to a temporary copy (deleted when the
session ends) or their own copy; playback stays in sync; everything works with VoiceOver, and every
important message is also seen (Zoom, low vision).
Current goal: build 6 on `listen-together-build6` with the sharer interruption (option A, this commit):
external full-fork audit, then merge to
`develop` and TestFlight 5.22.2 (6) once Becky approves. Later: Siri/CarPlay rules, streamed-book alert,
translations, upstream own-copy-only branch.
- Specs/plans: docs/superpowers/. Guide: docs/Listen-Together-Guide.md. Ledger, briefs, reports, audits:
  .superpowers/sdd/2026-10-10-shareplay-listen-together/ (build6-fix-round-1.md, -report.md, codex-audit*.md).

## Branches and remotes
- origin = github.com/BeckyK102125/BookPlayer (Becky's fork, public). upstream = TortugaPower/BookPlayer.
- `develop` at 3515e742 (build 5 = TestFlight 5.22.2 (5), plus notes).
- `listen-together-build6` (local, not pushed): e2428f4b + 8ed9a541 (Codex snapshots, audited), then fix
  round 1: 531f89ea TSan crash, c3408e85 Option 1 + audit 2, bd56544d decisions A-D + audit 1, c42b02e3 docs;
  453d36a5 fix round 2 (Codex F2-F4); 2621724a + 68941208 fix round 3; this commit = sharer
  interruption, option A. Clean after the commit except the untracked `review.md` (never commit it).
- Never committed: BuildConfiguration/Debug.xcconfig. PlayerManager.swift and Shared/ are untouched.

## Rulings in force (full text in progress.md and reviewer-common.md)
- R1-R39 (sync, stalls, late joiners, Magic Tap, End/escape, own book R36-R39).
- R40: buttons Apple-style (SF Symbol + text), 44 pt, Dynamic Type, contrast, one VoiceOver element.
- R41: failures/endings = centred alert with OK; ongoing status = persistent text near the controls;
  VoiceOver hears each message once. Two-finger scrub = cancel only. End asks once, Leave asks once.
- Becky 2026-10-13/19 (binding):
  - Option 1: the group never waits for one listener's audio interruption (details below).
  - A: everyone left -> the sharer's book pauses too, plus the one ending alert.
  - B: last listener vanishes without `.listenerLeaving` -> pause + wait 60 s, rejoin cancels; a deliberate
    last Leave ends at once.
  - C: "SharePlay stays on until you close it in Control Center." for a listener leaving while others remain.
  - D: own copy joining: a place > 30 s from the group's is kept as bookmark "Your place before Listen Together".

## Build 6 as it stands (details in Notes.md 2026-10-19)
- Last listener leaves on purpose: ends for everyone (`.sessionEnding` + `GroupSession.end()` in the End
  background task), sharer gets "Listen Together ended because everyone left." (alert), book paused (A).
- Last listener vanishes (B): P-pause (or "Someone left" when paused), status detail "If nobody is back within
  a minute, Listen Together ends.", `everyoneLeftWait` 60 s on the session clock, background task "Listen
  Together wait for listeners" (expiry ends at once), rejoin (`participantCountChanged` > 1) cancels.
- Option 1 (`ListenerPlayer.localStop`): `.began` (not `appWasSuspended`) while the group plays, or headphones
  removed -> stop here only; `bridge.beginLocalStop()` = `.audioSessionInterrupted` suspension (nobody waits),
  ends this phone's piece/readiness waits, refuses new ones; nothing sent. Status + Play value + Zoom caption,
  one announcement: "Listen Together will continue when the interruption ends." / "Stopped on this iPhone.
  Press Play to rejoin the others." `.ended`+shouldResume rejoins; otherwise needsPlay. Play tries the session
  (refusal says the status again, max every 3 s); rejoin = end suspension + reapply, then NOTHING plays or is
  saved until the coordinator's own play/pause arrives (fix round 2, F4; Play on a group that paused meanwhile
  starts it); no command within 3 s -> "Press Play" again. Skips refused while stopped.
- Rejoin window (fix round 3): status/row "Rejoining the others." (never announced); Play only marks "start a
  paused group", skips/speed refused, Pause cancels and pauses the group; a buffering pause counts as the
  group's state. Away: "Press Play" = one notification (existing permission) or announced on return if still
  stopped, removed when over; "will continue" never said from the background; own Pause changes it silently.
  Row values for every local stop.
- Sharer's own interruption (option A, Becky 2026-10-20): `SharerPlaybackTarget.interruption` (stale
  `appWasSuspended` ignored). While set, a group Play never calls `PlayerManager.play()` (it re-proposes rate 0,
  `.heldPaused`, not sent as an action). `.sharerInterrupted` / `.sharerInterruptionEnded(resumed:)` tell
  listeners: status/Play value/caption/row "The person sharing has an interruption. Listen Together will
  continue when it ends.", Play/skips/speed refused with that reason (3 s limit). Ended with shouldResume and
  the book was playing: the sharer resumes the group; else sharer "Press Play to continue Listen Together.",
  listeners "Paused. Waiting for the person sharing to press Play." Sharer's own status "Paused for your
  interruption…" (never said away). The sharer's own pause reads "The person sharing paused" / "Paused by the
  person sharing" (a11y M8), held 1.5 s so an interruption message replaces it.
- Waits: piece waits (unbounded by design: the book is still arriving; once the file is here the wait becomes
  the bounded readiness wait, F2), readiness waits bounded to 10 s (`readinessLimit`, session clock) and at
  most once per item, sharer hold bounded by the 60 s grace, local stop blocks nobody. Waits < 1 s and
  `.noItemToPlay` never stall the group. B: the minute is in the announcement, notification and row; a late
  `.listenerLeaving` ends at once; an unconfirmed joiner at 60 s gets one more 5 s window, then it ends.
- TSan crash fix: no suspension on a coordinator that is not connected to a session; every suspension in
  `ListenTogetherSuspensionLedger` (ends once; coordinator kept alive until it reports no suspension, 1-10 s).
- Own copy: the saved place uses the item the queue really plays (F3, file changes); progress saved once a second; bookmark (D: once per share, no duplicate, the loaded player's place); finishing together marks it finished; teardown
  re-looks the copy up and skips restoring a gone/moved/converted/failed copy.
- Leave texts: last listener (roster <= 2) gets "ends for everyone" in confirmations and hint; others get
  the Control Center sentence (C); neutral wording before a roster arrives. Invitation and Settings footer
  say the place moves to the group and name the bookmark.
- Lock-screen Pause while the group waits for this phone's piece is refused like the in-app button (M1).

## Test evidence (fix rounds 1-3, 2026-10-19/20)
- See Notes.md 2026-10-19 for the full commands. Simulator 98A8CF98-8142-4710-AD5E-5419F782752C, default
  DerivedData, scheme BookPlayer, plan "Unit Tests".
- Before: TSan on OwnCopy + SessionService tests crashed twice per run in figTimelineCoordinator_endSuspensionOnQueue.
- Fix round 1: SharePlay 669/0 x2; full 1245/0; TSan 669/0 x3, 0 crashes, 0 warnings.
- Fix round 2: SharePlay 676/0; full 1252/0 ** TEST EXECUTE SUCCEEDED ** (first attempt died at
  launch before any test, "Early unexpected exit", rerun after a rebuild); TSan 676/0 x3, 0 crashes, 0 warnings.
- Fix round 3: SharePlay 698/0 x2; full 1274/0 ** TEST EXECUTE SUCCEEDED **; TSan 698/0 x3, 0 crashes, 0 warnings.
- Option A: SharePlay 709/0; full 1285/0 ** TEST EXECUTE SUCCEEDED **; TSan 709/0, 0 crashes, 0 warnings (two
  earlier TSan attempts were SIGTERMed while another session ran tests on the same simulator; see Notes).

## Local environment gotchas
- Xcode 27 here, CI uses 26.4. Wait for the FINAL ** TEST SUCCEEDED/FAILED **; log to a file and poll.
  Never pass -derivedDataPath. "Invalid API Key" lines are noise. A build-for-testing takes 7-10 min here.
- TSan on the whole suite stops at a pre-existing DirectoryWatcher race; run SharePlay classes by name.
- A real AVDelegatingPlaybackCoordinator without a group session must never get a suspension (CoreMedia crash).
- Interruption/route tests call `handleInterruption` / `audioRouteRemoved` directly (no global notifications,
  no shared-session deactivation); `ListenerPlayer.now` / `activateSession` / `schedule` are the seams.

## Device and assistive-technology checks (two iPhones, same build; Becky VoiceOver, Michael Zoom 3x)
Capture both Console logs filtered on "Listen Together:".
1. Option 1: phone call on a listener while playing: others keep playing and hear nothing; listener sees and
   hears "Listen Together will continue when the interruption ends." once; after the call it rejoins at the
   group's current place (compare times). Repeat with Siri, an alarm, Maps voice, YouTube/Music taking the audio
   (expect "Stopped on this iPhone. Press Play to rejoin the others." and Play rejoining).
2. Headphones/AirPods out while listening: stops only there, never speaker; Play rejoins at the group's place.
3. Interruption while the group is paused, then the sharer presses Play: group plays; interrupted phone shows status.
4. Sharer gets a call: group pauses ("Paused by another listener"); a listener's Play resumes everyone.
5. B: last listener's Wi-Fi off: sharer pause + minute line; back within 30 s -> continues; else ends after
   60 s with the alert and the sharer's book paused. Same with the sharer locked (does it end at 60 s or earlier?).
6. A: last listener chooses Leave with the sharer locked: book stops (audible cue) + notification/alert.
7. C: listener leaves while others remain: confirmation text read fully; record what SharePlay shows after
   (fill the guide's "Close SharePlay completely" names). Last listener: "You are the last listener" text.
8. D: own copy behind/ahead of the group by > 30 s: bookmark "Your place before Listen Together" in the
   bookmarks list; library place follows the group; leave restores the player paused there.
9. Own copy deleted/moved mid-session: no ghost mini player, no "Error Metadata" alert.
10. Brief buffering at file boundaries (long multi-file book): no group-wide stalls.
11. Fix round 3: locked listener, call ends without resume or AirPods out in a pocket: one notification (with
   permission) or "Press Play" said on return; "Rejoining the others." visible during the gap; row text at Zoom 3x.
12. Option A: the sharer takes a call while playing: listeners see/hear the interruption line once, Play does
   nothing and says why; call ends -> group resumes; ended without resume -> "Press Play to continue" on the
   sharer and "Waiting for the person sharing to press Play" on listeners. App Store-like build: no crash.
13. Build 5 checks (B5 a-i in Notes.md 2026-10-12) and older checks still apply.

## Known limitations
- Streamed books and video cannot be shared. Chunk fallback throughput unmeasured.
- A piece that never arrives keeps the group waiting (retries every 30 s); this is the piece-wait design.
- Rejoin waits for the coordinator's re-issued command (device check 1: how fast it arrives; 3 s fallback).
- Last-listener detection uses the listener's raw roster (<= 2 = sharer + me); an unconfirmed third person
  can still give "The others keep listening" (code M10, not changed).
- New strings are English in every lproj; mark for translation before release.
- Mixed builds degrade: every phone on the same build.

## Open problems and next steps (in order)
1. External full-fork audit (option A is in).
2. Merge to develop; TestFlight 5.22.2 (6) (Becky approves the upload).
3. Two-device run (checks above); fill the guide's Control Center names.
4. Parked: a11y M1 two messages in the owners-only arrival window; M5 Join hint wording; M6 system Leave
   SharePlay wording on the listener; build-5 parked minors.

## Decisions waiting on Becky
- Interruption ended without "should resume" waits for Play (Apple's rule); OK, or always rejoin?
- (Ruled 2026-10-20: option A for the sharer's interruption.)
