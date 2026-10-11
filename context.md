# context.md - current snapshot

Date: 2026-10-11

## Goal
SharePlay "Listen Together" in Becky's fork of BookPlayer: one person shares a downloaded audiobook (from
Messages with no call, or on a FaceTime call); the others listen to a copy that is downloaded for the
session only and deleted when it ends; playback stays in sync; everything works with VoiceOver.
Current goal: addendum 2, "Both have the book": a listener who owns the book plays their own copy
(nothing downloaded); the sharer can choose "Only people who have the book can join".
- Spec: docs/superpowers/specs/2026-10-10-shareplay-listen-together-design.md
- Addendum 2: docs/superpowers/specs/2026-10-10-shareplay-listen-together-addendum-2.md, a11y guidance
  .superpowers/sdd/2026-10-10-shareplay-listen-together/own-copy-a11y-guidance.md
- Plan: docs/superpowers/plans/2026-10-10-shareplay-listen-together.md
- User guide: docs/Listen-Together-Guide.md
- Ledger, briefs, reports, rulings R1-R38: .superpowers/sdd/2026-10-10-shareplay-listen-together/
  (progress.md). Latest report: own-copy-report.md.

## Branches and remotes
- origin = github.com/BeckyK102125/BookPlayer (Becky's fork, public). upstream = TortugaPower/BookPlayer.
- Tracked on origin: `develop`, `listen-together-messages` (both 9c70dd06), `listen-together-lock-screen`
  (63e9578b), `shareplay-listen-together` (e634f5c7). Becky and Michael are testing develop on devices.
- `listen-together-own-copy` (this branch, from develop at 9c70dd06): addendum 2 in this commit (parent
  9c70dd06). NOT pushed. Clean after commit. Worktree BookPlayer-testflight (detached at 9c70dd06)
  belongs to another session (TestFlight archive); not touched here.
- Change A (streamed-book alert) of addendum 1 is NOT done.
- Fix wave 2 and fix round 2 are in develop (Notes.md has the details).
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

## Most recent work: addendum 2 "Both have the book" (2026-10-11, this commit)
- Fingerprint (BookFingerprint.swift): normalised title/author, total duration, per-file book start,
  duration and byte size, SHA-256 of the first 64 KB of the first file (read off the main actor). It
  travels in the activity (so the invitation knows the match before it is shown; the manifest only
  arrives after joining) and in the manifest. Pure matcher (BookFingerprintMatcher): ±2 s total and per
  file, same file count, and hash match OR (title AND author AND every size ±1 %); tie -> most recent.
- Listener (ListenTogetherOwnCopy.swift): LibraryOwnCopyFinder reads the library through
  LibraryService.searchAllBooks + PlaybackService.getPlayableItem on the main context (Simple*/Playable*
  snapshots only, read only). The invitation waits up to 3 s for the check, then is shown once with the
  right words (case A "You have this book..." + own Join hint; case B unchanged). Owners-only and no copy
  (case C): no sheet, no invitation announcement; the listener joins just long enough to send
  `.declinedNoCopy`, leaves, and shows "You need your own copy" (single OK, cancel-style; fallback
  announcement/notification when it can't be shown). Join re-checks the files (sizes): unusable copy ->
  download (send mode) or "Your copy can't be used" + decline (owners-only).
- Own-copy playback: ListenerPlayer built at Join with the own files as already-arrived pieces at the
  sharer's book times; the transport stops loading pieces; state is .listening(_, 1) from the start;
  one announcement "Joined. Playing your copy." after 0.7 s; End hint "Leaves Listen Together. Your own
  copy is kept." The library is never written (no progress, bookmarks, last played).
- Safety: session cleanup only removes ShareStorage folders; tests prove a library file survives End,
  sharer end, invalidation, Leave-for-own-book and launch cleanup (mutation check: deleting played files in
  tearDown makes 4 of them fail).
- Sharer: Settings -> Playback -> Listen Together ("When someone doesn't have the book": Send it for this
  session (default) / Only people who have the book can join), inline picker, footer, row value. Owners-
  only shares upload nothing (manifest without pieces). Send mode always uploads (late joiners without a
  copy; owners never download). First-share note depends on the mode.
- Roster by participant id: someone new is counted and announced only after 2 s if still there and not
  declined; decliners are never counted or announced; the sharer hears "Someone couldn't join because
  they don't have the book." at most once per 10 s; listeners hear nothing.
- Guide updated (guidance section 5). 18 new strings + changed first-share message, in all 26 lproj.

## Test evidence (2026-10-11, addendum 2)
- New: BookFingerprintTests (22), ListenTogetherOwnCopyTests (23). 20 SharePlay classes: 247/0. Full: 819/0,
  ** TEST SUCCEEDED ** (run 1 hit the known InsertBooksTests crash). TSan 20 classes: 247/0, 0 warnings.
Command: xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -destination
'platform=iOS Simulator,id=98A8CF98-8142-4710-AD5E-5419F782752C' -testPlan "Unit Tests"
-only-testing:BookPlayerTests test (focused/TSan: `-only-testing:BookPlayerTests/<Class>` for the 20
SharePlay classes, TSan adds `-enableThreadSanitizer YES`). Before addendum 2: 774 full, 202 SharePlay.
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
Priority checks (new or risky; full wording in Notes.md, fix round 2 entry):
1. Paused + locked 5+ minutes, then Play from the lock screen, from EACH side (whole-branch I4).
2. R38/R39: own book during a listener session (question, Leave/Cancel/scrub, focus; locked refusal).
3. Cold launch from the Messages invitation (W-I5 retries). 4. Sharing sheet open over 2 minutes.
5. Magic Tap before the book arrives. 6. Join then End at once; End as sharer with no network.
7. Lock-screen/AirPods commands on main. 8. Toggle while waiting for a piece.
9. Addendum 2 (own-copy-a11y-guidance.md device checklist): own copy in both modes (Join goes straight
   to the player, one "Joined. Playing your copy.", no download wording, audio in sync); no copy +
   owners-only (alert read in full, OK and scrub both decline, sharer hears "Someone couldn't join" once,
   no "joined"/"left"; does iOS show a SharePlay banner during the decliner's brief join?); End/Leave
   keeps the library book and its place; file moved between invitation and Join; Settings screen
   (picker label spoken once, footer, back keeps the choice); Voice Control "Tap Join"/"Tap OK".
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
- Own copy: streamed books and other editions/recordings never match; the own copy plays at the
  sharer's file boundaries (files may differ by up to 2 s). Send mode uploads the pieces even when
  everyone so far owns the book.
- Audio session deactivation at listener end runs on main (M7, deliberately not moved: see report).

## Open problems and next steps (in order)
1. Review addendum 2 (code + a11y) on `listen-together-own-copy`; then merge into develop (ask; Becky
   and Michael are testing develop now, so not before they say).
2. Two-device run of develop (list above); record results here and in Notes.md.
3. Two-device run of addendum 2 (item 9), needs both phones to own the same book.
4. Change A (streamed-book alert) of addendum 1.
5. Upstream PR decision later (propose owners-only as the default upstream).

## Decisions waiting on Becky
- TestFlight: record whether a TestFlight build is wanted (and under which bundle ID) or device installs only.
- Siri dialog / CarPlay alert for the R39 refusal (not built: would need intent result dialogs and a
  CarPlay alert template)?
