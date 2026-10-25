# context.md - current snapshot

Date: 2026-10-23

## Goal
SharePlay "Listen Together" in Becky's fork of BookPlayer: one person shares a downloaded audiobook (from
Messages with no call, or on a FaceTime call); the others listen to a temporary copy (deleted when the
session ends) or their own copy; playback stays in sync; everything works with VoiceOver, and every
important message is also seen (Zoom, low vision).
Current goal: build 6 on `listen-together-6.0` = build 6 work (fix round 4 done) + upstream develop 6.0.0 merged
in (iPhone Duo layouts and 89 other upstream commits, Becky asked 2026-10-23). Next: Codex read-only re-audit of
`listen-together-6.0`, fix anything noteworthy, then merge to `develop` and TestFlight 5.22.2 (6). Later: Siri/CarPlay rules, streamed-book alert,
translations, upstream own-copy-only branch.
- Specs/plans: docs/superpowers/. Guide: docs/Listen-Together-Guide.md. Ledger, briefs, reports, audits:
  .superpowers/sdd/2026-10-10-shareplay-listen-together/ (build6-fix-round-1.md, -report.md, codex-audit*.md).

## Branches and remotes
- origin = github.com/BeckyK102125/BookPlayer (Becky's fork, public). upstream = TortugaPower/BookPlayer.
- `develop` at 3515e742 (build 5 = TestFlight 5.22.2 (5), plus notes).
- `listen-together-6.0` (local, not pushed, current): `listen-together-build6` + 698698a3 (merge of upstream/develop
  a8e2cac7, marketing version now 6.0.0) + 3adbca24 (main-actor timer seams) + this docs commit.
- `listen-together-build6` (local, not pushed, kept as the pre-merge state at feb50669): e2428f4b + 8ed9a541 (Codex snapshots, audited), then fix
  round 1: 531f89ea TSan crash, c3408e85 Option 1 + audit 2, bd56544d decisions A-D + audit 1, c42b02e3 docs;
  453d36a5 fix round 2 (Codex F2-F4); 2621724a + 68941208 fix round 3; b7b080ce option A; fix round 4 =
  the code commit after it plus this docs commit. Earlier rule "never commit review.md" was replaced on 2026-10-25: Review.md is tracked (agents.md).
- Reviews: agents.md (2026-10-25) = Start Speaking's rules 9 and 10 for Aquila (Grok bot) audits: Review.md in the
  repo root (tracked), newest first, prefix BP-; off-Mac reviews on review/<reviewer>-<date> branches; hand-offs in
  ~/Developer/Swift/swift-dev-review/BookPlayer/HANDOFF.md. Aquila reads GitHub, so only pushed commits.
  Aquila's findings go into Start Testing (project "BookPlayer - Listen together", agents.md rule 3), not Review.md.
- Never committed: BuildConfiguration/Debug.xcconfig. Shared/ untouched. PlayerManager.swift: only the two
  edits Becky approved (A01 end-of-item check, A08 no fatalError on session activation failure).

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
- Option 1 (`ListenerPlayer.localStop`): a listener's interruption or headphone removal stops that phone only
  (`.audioSessionInterrupted` suspension, nobody waits, nothing sent); status/Play value/caption/row, one
  announcement (away rules). Rejoin waits for the coordinator's own play/pause ("Rejoining the others.", 3 s
  fallback to "Press Play"); Play/skips/speed/Pause in the window are handled without the cached place.
- Option A (sharer's own interruption): `SharerPlaybackTarget.interruption`; a group Play never calls
  `PlayerManager.play()` meanwhile; `.sharerInterrupted` / `.sharerInterruptionEnded(resumed:)` give listeners
  "The person sharing has an interruption…" (Play/skips refused with that reason) and then either a resume or
  "Paused. Waiting for the person sharing to press Play."; the sharer sees its own status. The sharer's pause
  reads "Paused by the person sharing" (a11y M8).
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
- Fix round 4: PlayerManager only finishes a book for its own current AVPlayerItem (A01, `acceptsEndOfItem`);
  a failed audio-session activation no longer crashes production (A08: Sentry capture, Play stays inert, retry
  by pressing Play). Siri (A17, `ListenTogetherIntentRouting`): listener Pause/skips go to the shared book,
  bookmark refused, starting a book leaves first; sharer may resume only the shared book. Late joiners get the
  sharer's interruption state with the manifest/state answer.

## Upstream 6.0.0 merge (2026-10-23, details in Notes.md)
- Mini player: upstream uses the tab view's single bottom accessory on every iOS version (overlay MiniPlayerView
  deleted). Listen Together now uses the former iOS 26.0 design everywhere: listener = the Listen Together row in
  the accessory; sharer = the mini player, whose second line SHOWS "Listen Together, sharing" instead of the
  author (and VoiceOver reads it as the value). Closing the sharer's player focuses the mini player.
- PlayerView = upstream side-by-side/Duo version + our banner, play controls, title focus, alerts.
- loadPlayer = upstream body + our start gate; Settings split view has the Listen Together row.
- Upstream removed the SiriKit extension (BookPlayerIntents); our App Intents routing (A17) is unchanged.
  Now Playing suggestions and Siri PlayMedia go through loadPlayer, so the Listen Together gate applies.

## Test evidence (commands and full history in Notes.md 2026-10-19/20)
- Simulator 98A8CF98-8142-4710-AD5E-5419F782752C, default DerivedData, scheme BookPlayer, plan "Unit Tests".
- Rounds 1-3 and option A all green (SharePlay, full suite, TSan with 0 crashes and 0 warnings).
- After the 6.0.0 merge (3adbca24): full suite "Executed 1757 tests, with 0 failures" ** TEST SUCCEEDED **;
  0 Sendable warnings in SharePlay code. TSan on the 34 SharePlay classes + PlayerManagerTests: 745/0, 0 warnings,
  0 crashes.
- Fix round 4: SharePlay (35 classes) + PlayerManagerTests 736/0; full 1295/0 ** TEST EXECUTE SUCCEEDED **; TSan
  on the same 736 tests: 0 crashes, 0 warnings, 0 restarts.

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
4. B: last listener's Wi-Fi off: sharer pause + minute line; back within 30 s -> continues; else ends after
   60 s with the alert and the sharer's book paused. Same with the sharer locked (does it end at 60 s or earlier?).
5. A: last listener chooses Leave with the sharer locked: book stops (audible cue) + notification/alert.
6. C: listener leaves while others remain: confirmation text read fully; record what SharePlay shows after
   (fill the guide's "Close SharePlay completely" names). Last listener: "You are the last listener" text.
7. D: own copy behind/ahead of the group by > 30 s: bookmark "Your place before Listen Together" in the
   bookmarks list; library place follows the group; leave restores the player paused there.
8. Own copy deleted/moved mid-session: no ghost mini player, no "Error Metadata" alert.
9. Brief buffering at file boundaries (long multi-file book): no group-wide stalls.
10. Fix round 3: locked listener, call ends without resume or AirPods out in a pocket: one notification (with
   permission) or "Press Play" said on return; "Rejoining the others." visible during the gap; row text at Zoom 3x.
11. Fix round 4: Siri "pause"/"skip forward" as a listener (group moves, own book untouched); "play <my book>"
   (leaves with the announcement); sharer "play <another book>" (refused sentence). Join during the sharer's
   interruption: the new listener sees the interruption line.
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
- A08: no automatic retry after an activation failure (Play again retries); the CLAUDE.md hotlist line about
  that fatalError is now out of date (not changed, per the brief).

## Later (inherited findings; 2026-10-23 audit renumbered them R03-R22: A02->R03, A04->R04, A05->R06, A06->R07,
## A07->R08, A09->R11, A10->R12, A11->R14, A12->R15, A13->R16, A15->R17, A16->R18, A18->R19, A19->R20, A20->R21;
## A03 and A14 fixed upstream; new: R05 sync queue admission vs logout, R09 player-status KVO isolation, R10 Watch
## resumes after Pause during activation, R13 chapter refresh across servers, R22 share extension drops duplicates)
- P1: A02 failed backup moves still lead to permanent deletion; A03 HTTP storage rejection recorded as upload
  success; A04 former-account responses reconcile after logout; A05 import workers violate Core Data context
  ownership; A06 ZIP failure deletes the source archive; A07 obsolete chapter operations reinstall old playback.
- P2: A09 live backup can omit committed WAL data; A10 empty remote listing never removes local contents; A11
  download queue ownership assigned after suspension; A12 failed login leaves identities inconsistent; A13
  Hardcover status updates out of order; A14 Hardcover progress insert loses the row id; A15 cancelled searches
  alert/publish stale results; A16 old fetch cleanup clears the new task handle; A18 late bookmark loading
  replaces the new book's list; A19 adjustable playback controls lack accessible names; A20 button-free actions
  lack accessible equivalents.

## Open problems and next steps (in order)
1. Codex re-audit 2026-10-23 (Review.md, copy codex-full-audit-2026-10-23.md, R01-R22) read. Fixed: R01 (Siri
   PlayMedia now routed), R02 (video player restored), transfer-sheet cover, live sharer status in the mini
   player. Becky 2026-10-23: the other 20 (upstream code) wait; once TestFlight 6 proves stable on the two-phone
   test, we work through them (R09 touches PlayerManager.swift: ask before editing).
2. DONE 2026-10-23: develop fast-forwarded to d55292ea and pushed; TestFlight 5.22.2 (6) uploaded (internal only;
   Becky: keep the 5.22.2 train for the fork, so MARKETING_VERSION=5.22.2 is passed on the archive command line).
   The 6.0.0 (6) upload from the same commit was expired in App Store Connect (2026-10-23).
   Next: the two-phone test on build 6. Device checks add: Duo/landscape side-by-side
   player as sharer (banner and Listen Together controls visible), sharer mini player line at Zoom 3x.
3. Deferred audit items above when Becky schedules them. Files over 700 lines (pre-existing):
   SharePlaySessionService.swift 1729, ListenerPlayer.swift 1032; split them in a focused pass.
4. Two-device run (checks above); fill the guide's Control Center names.
5. Parked: a11y M1 two messages in the owners-only arrival window; M5 Join hint wording; M6 system Leave
   SharePlay wording on the listener; build-5 parked minors.

## Decisions waiting on Becky
- Interruption ended without "should resume" waits for Play (Apple's rule); OK, or always rejoin?
- (Ruled 2026-10-20: option A for the sharer's interruption.)
