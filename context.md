# context.md - current snapshot

Date: 2026-10-11

## Goal
SharePlay "Listen Together" in Becky's fork of BookPlayer: one person shares a downloaded audiobook (from
Messages with no call, or on a FaceTime call); the others listen to a temporary copy (deleted when the
session ends) or their own copy; playback stays in sync; everything works with VoiceOver, and every
important message is also seen (Zoom, low vision).
Current goal: two-device run of TestFlight build 5.22.2 (3) (develop 4f589c33, transfer fix), uploaded 2026-10-11.
audio piece ever arrives ("Couldn't send part of the book"). Root cause and plan:
.superpowers/sdd/2026-10-10-shareplay-listen-together/transfer-root-cause-2026-10-11.md; brief
transfer-fix-brief.md; report transfer-fix-report.md. Branch `listen-together-transfer-fix` (from develop
b73bd061), not pushed, waiting for review, then a two-device run of build 3.
- Specs and plan: docs/superpowers/specs/2026-10-1*-*.md, docs/superpowers/plans/2026-10-10-*.md
- User guide: docs/Listen-Together-Guide.md
- Ledger, briefs, reports, rulings: .superpowers/sdd/2026-10-10-shareplay-listen-together/ (progress.md).
  Latest: transfer-root-cause-2026-10-11.md, transfer-fix-brief.md, transfer-fix-report.md.

## Branches and remotes
- origin = github.com/BeckyK102125/BookPlayer (Becky's fork, public). upstream = TortugaPower/BookPlayer.
- On origin: `develop` (85c42b29, pushed 2026-10-11), `listen-together-messages` (9c70dd06),
  `listen-together-lock-screen` (63e9578b), `shareplay-listen-together` (e634f5c7).
- `listen-together-transfer-fix` (local, not pushed): 41efa526 transfer fix A + B, readable errors,
  SharePlay really ends; f4d9cad4 fix round 1; this commit = fix round 2. Clean after the commit.
- `develop` (b73bd061, docs commit on top of 85c42b29, pushed) fast-forwarded from `listen-together-own-copy`
  (local branch, same commits, not pushed): addendum 2 (de1f5731,
  7bf22248, 0b5aacdd), addendum 3 ruling 1598e8d4, Task A (87f4a744, de116941, d786c79e, 9cedab87),
  Task B (482ba093, 572d267b, 282f27c4, 27d86fd2), final review fixes 85c42b29 (re-review: ready).
  No extra worktrees (the TestFlight worktree was removed after each upload).
- Never committed: BuildConfiguration/Debug.xcconfig. PlayerManager.swift and Shared/ are untouched.
- Change A (streamed-book alert) of addendum 1 is NOT done.

## TestFlight and devices
- Build 1: 5.22.2 (1) (9c70dd06) failed in the field (ended 0.4 s after Play) -> addendum 3. Build 2:
  5.22.2 (2) (85c42b29), internal group "Listen Together": no piece arrives -> this fix. Both phones must
  run the same build (protocol changes; chunk mode needs both sides on build 3).
- Local device installs: team Techopolis (M9SNPTXA44), bundle ID app.techopolis.BookPlayer-together, local
  Debug.xcconfig only. Pass signing on the command line; revert any pbxproj/Info.plist churn Xcode writes.

## Rulings in force (full text in progress.md)
- R1-R39 (build plumbing, sync, stalls, late joiners, Magic Tap, invitation from the topmost screen, End
  asks once, escape = back R35, own mini player hidden R36, sheet watchdogs R37, own book asks R38/R39).
- R40: every button Apple-style (SF Symbol + text), 44 pt, Dynamic Type, 4.5:1 text / 3:1 shapes in all 22
  theme variants, one VoiceOver element with a verb label; destructive role on destructive actions.
- R41: every important message is seen: failures and endings as a centred alert with OK (never a timed
  toast or only an announcement); ongoing status as persistent text next to the controls; VoiceOver hears
  each message once.
- Two-finger scrub is always cancel/back. End asks once, Leave asks once, Cancel Sharing acts at once.
- Addendum 3: piece failures never end a session; silence never ends a session (status only); only the
  sharer leaving the roster starts the 60 s grace; Becky: after the sharer ends/leaves, one message, then
  no Listen Together UI for that book. sharerLeft keeps the spec sentence.

## Transfer fix (this branch, build 3)
- A: `PieceTransfer` is a `DataRepresentation(contentType: .data)` (file memory-mapped on the sharer);
  `journal.add(_:metadata: PieceMetadata(pathExtension:))`; the listener names the file with that extension
  (`receivedFileName`, `m4a` fallback). `maxPieceBytes` 90 MB -> 25 MB (planner target still ~12 min).
- B: `MessengerPieceChannel` + `PieceChunks.swift`: second reliable messenger, raw `LTCK` chunks of 192 KB
  (48-byte header: id, index, count, size, CRC-32, extension), `LTCC` control frames (transportMode,
  chunksMissing, pieceGone). Window 2-3, back-off 100/250/500 ms/1 s, 8 failures in a row fail the piece.
  Listener: pre-sized `.part` in the share folder, gaps asked for after the last chunk and on the service's
  retry timer (stale 5 s), CRC check, `.attachmentReceived` as before. Sharer keeps the 3 latest pieces;
  older ones are deleted (only inside the share folder) and reported gone -> `needPiece` re-exports.
  Fix round 1: frames over 100 MB rejected (no overflow/alloc crash); chunks only from the sharer, at most
  4 pieces assembling; listener `journalUnusable` (notSupported or 2 load failures) switches the sharer and
  the listener re-asks its missing pieces with `needPiece`; journal-domain errors count in any app state;
  all mode logic in `ListenTogetherTransferCoordinator` (tested); chunk disk work off the main actor.
  Round 2: the listener re-asks missing pieces on every announcement after its report; incoming/ emptied
  at teardown; nothing starts after stop.
  Switch per session after 2 non-interruption journal failures or any `notSupported`; announced to all and
  to later joiners. B added `end()` and `stopPieceTransfers()` to the protocol (defaults; End uses both).
- Guide (41efa526, round 2): slower fallback, End stops SharePlay, sharer quitting, late joiners.
- Errors: `ListenTogetherErrorDescription` (type/case, domain, code, underlying) public on failure lines.
- End: sharer End -> `.sessionEnding`, 0.5 s, `transport.end()` (`GroupSession.end()`), all within 2 s;
  listeners leave; chunk transfers stop first. App terminating (only): sharer ends at once, listener leaves.

## What is built before this branch (summary; details in Notes.md)
- Addendum 2: own copy (fingerprint match, plays in place), owners-only mode.
- Task A: ~12 min pieces, send-ahead scheduler (.needPiece), retries with back-off, sharer kept awake,
  AVQueuePlayer, state requests, heartbeat, roster grace, diagnostics ("Listen Together:" logs).
- Task B: one message-delivery path (alerts, status + one announcement, speech), Speak, Leave buttons.
- Final review fixes (85c42b29): own copy unplayable -> leave with alert, and minors.

## Test evidence (2026-10-11, transfer fix)
- Red checks each round (Notes.md). Round 2 green: 29 SharePlay classes 487/0; full suite 1059/0
  (** TEST SUCCEEDED **, after one known InsertBooksTests crash rerun); TSan 487/0, 0 warnings.
- Command: xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -destination 'platform=iOS
  Simulator,id=98A8CF98-8142-4710-AD5E-5419F782752C' -testPlan "Unit Tests" -only-testing:BookPlayerTests
  test (per class `-only-testing:BookPlayerTests/<Class>`; TSan adds `-enableThreadSanitizer YES`).

## Local environment gotchas
- Xcode 27 here, CI uses 26.4. Simulator by id 98A8CF98-8142-4710-AD5E-5419F782752C.
- Wait for the FINAL ** TEST SUCCEEDED/FAILED **; xcodebuild often hangs after the results: log to a file,
  poll, kill your own xcodebuild, rerun if the final line is needed. Never pass -derivedDataPath.
  "Invalid API Key" lines are noise.
- New files: copy an existing file's four pbxproj entries with new ids (Notes.md, Task B).
- TSan on the whole suite stops at a pre-existing DirectoryWatcher race; run SharePlay classes by name.

## Device and assistive-technology checks (two-device run, both phones on the same build)
Setup: Becky (VoiceOver) + Michael (Zoom, VoiceOver off), two iPhones, Discord, start from Messages.
Capture both Console logs filtered on "Listen Together:".
0. Build 3 first: the sharer's log shows `uploaded piece 0` (journal works) or `journal upload failed:
   ... notSupported` then `transport mode chunks (sharer ...)` and `chunks sent piece ... rate=...B/s`;
   the listener shows `attachment ... loaded` or `transport mode chunks (listener ...)` and
   `chunks piece ... received`. Rate must be at least 32 KB/s. SharePlay indicator gone after End.
1. Start with a long single-file m4b and an mp3 book: listener plays within seconds; percent moves; no gap
   at piece joins.
2. Sharer switches apps / locks mid-send: session goes on; airplane mode 30 s then back.
3. Sharer End: listener cover closes, then one alert read once; OK/scrub; focus to the mini player.
4. Same for Michael at Zoom 3x with Speak on; with Control Center open; with FaceTime in front.
5. Sharer force-quits: waiting status + minute line + caption; back within 60 s, or the left alert.
6. Sharer locks while playing: "Can't reach the person sharing. The book keeps playing." with nothing said.
7. FaceTime call ends / connection drops: each side's "connection" alert.
8. Leave on "Getting the book" (button and Actions rotor) and in the player; no "ended" banner.
9. Own copy: delete or move the book in the library mid-session (final review I1): re-armed, or this phone
   leaves with the alert; the others keep listening and are not held.
10. Speak error messages: voice (Siri voice?), ducking vs pausing, locked, VoiceOver stop, calls, sample.
11. A book with 100+ files: the invitation arrives; late-join resend time (final review M4).
12. Paused + locked 5+ minutes, then Play from the lock screen, from each side.
13. R38/R39 own book during a listener session; cold launch from the Messages invitation.
14. Settings in Sky dark; switch and picker checkmark in Ayu light; AX5 on the smallest iPhone.
15. Parked: End action sheet at Zoom 3x (a11y M9); iOS 26.0 accessory status (M10).
Full lists: reliable-sending-task-B-report.md, own-copy-a11y-guidance.md, Notes.md.

## Known limitations
- Streamed books and video cannot be shared.
- The sharer's exported pieces take about the book's size in tmp until the session ends (journal mode;
  in chunk mode only the 3 latest are kept).
- Chunk fallback: no cloud copy; late joiners get pieces from the sharer's phone (bandwidth per listener);
  messenger throughput is undocumented and unmeasured.
- A piece that fails for good is retried every 30 s (sharer sees the retry status); listeners wait.
- If the sharer switches books mid-session, listeners keep the old book (R12).
- A killed sharer that iOS keeps in the roster never ends listeners' sessions (they see the silence line).
- Own book can't start from Siri/widget/CarPlay while locked during a listener session (R38/R39).
- Notifications dormant (no permission asked); SwiftUI alerts are outside the one-alert gate.
- Mixed builds degrade (old listeners on owners-only shares wait at 0 %): update both phones.
- New strings are English in every lproj; mark for translation before release.
- Own copy: other editions/recordings never match; plays at the sharer's file boundaries (±2 s).

## Open problems and next steps (in order)
1. Review of the transfer fix branch; merge to develop; TestFlight build 3 (Becky approves upload).
2. Two-device run on build 3 (item 0 first, then the list above); record results here and in Notes.md.
3. Parked minors: M3 protocol version, M4 late-join resend, M7 endNotice (unused outside the service), M8
   two notification-permission checks. Change A (streamed-book alert). Upstream PR decision later.

## Decisions waiting on Becky
- A killed sharer that iOS keeps in the roster never ends listeners' sessions (silence ruling). OK?
- After 60 s the listener sees "The person sharing left. Listen Together ended." (spec); one sentence for
  both endings instead?
- Siri dialog / CarPlay alert for the R39 refusal (not built)?
