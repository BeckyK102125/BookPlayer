# context.md - current snapshot

Date: 2026-10-12

## Goal
SharePlay "Listen Together" in Becky's fork of BookPlayer: one person shares a downloaded audiobook (from
Messages with no call, or on a FaceTime call); the others listen to a temporary copy (deleted when the
session ends) or their own copy; playback stays in sync; everything works with VoiceOver, and every
important message is also seen (Zoom, low vision).
Current goal: build 5 on `listen-together-build5` (implemented 2026-10-12; fix round 1 done, waiting for
re-review): the whole
group pauses when a listener leaves or drops; sharer start errors B1-B3; End background task (A3); own
cancelled shares ended (A4); state logs (A6); "SharePlay stays on until you close it in Control Center".
- Specs/plans: docs/superpowers/. Guide: docs/Listen-Together-Guide.md. Ledger, briefs, reports, rulings:
  .superpowers/sdd/2026-10-10-shareplay-listen-together/ (progress.md, build5-brief.md, build5-report.md).

## Branches and remotes
- origin = github.com/BeckyK102125/BookPlayer (Becky's fork, public). upstream = TortugaPower/BookPlayer.
- `develop` at f55d7e75 (start-position fix 06498b5b = TestFlight 5.22.2 (4), plus notes commits).
- `listen-together-build5` (local, not pushed; from f55d7e75): 302cd8c9 build 5; bf2e1a8e + 49a5abab move the
  InsertBooksTests @MainActor change into its own commit; 17fb4eff fix round 1; this commit = fix round 2. Clean after the commit
  except the untracked `review.md` (external Codex review; leave it, never commit it).
- Never committed: BuildConfiguration/Debug.xcconfig. PlayerManager.swift and Shared/ are untouched.
- Change A (streamed-book alert) of addendum 1 is NOT done.

## TestFlight and devices
- Build 1 (9c70dd06) ended 0.4 s after Play; build 2 (85c42b29) no piece arrived; build 3 (4f589c33) plays
  on FaceTime and Messages but started at 0:00 and reset the sharer's place -> this branch (build 4).
  Both phones must run the same build.
- Device installs: team M9SNPTXA44, bundle app.techopolis.BookPlayer-together, signing on the command
  line only (revert any pbxproj/Info.plist churn).

## Rulings in force (full text in progress.md)
- R1-R39 (see progress.md: sync, stalls, late joiners, Magic Tap, End/escape, own book R36-R39).
- R40: every button Apple-style (SF Symbol + text), 44 pt, Dynamic Type, 4.5:1 text / 3:1 shapes in all 22
  theme variants, one VoiceOver element with a verb label; destructive role on destructive actions.
- R41: every important message is seen: failures and endings as a centred alert with OK (never a timed
  toast or only an announcement); ongoing status as persistent text next to the controls; VoiceOver hears
  each message once.
- Two-finger scrub is always cancel/back. End asks once, Leave asks once, Cancel Sharing acts at once.
- Addendum 3: piece failures and silence never end a session; only the sharer leaving the roster starts
  the 60 s grace; after the sharer ends/leaves, one message, then no Listen Together UI for that book.

## Build 5 (this branch; details in Notes.md 2026-10-12)
- A listener's Leave (and Leave to play own book, listener End, own copy unplayable) sends `.listenerLeaving`
  (max 1 s, in a background task), then leaves. The sharer, if the shared book plays, pauses everyone:
  P1-P4 ("Paused. Someone left Listen Together." / "...lost their connection..." / "%d people ...") as a
  status (icon pause.circle), caption under Play + Play's value, row "paused, someone left, <title>", one
  announcement, Speak; away: notification only (existing permission), else announced on return if still
  paused. Listeners get `.groupPaused` (same sentence, no Speak); their "Someone left" waits 2 s for it.
  Any play clears it silently. Already paused: "Someone left" only. The sharer leaving stays the 60 s grace.
- B1 abandoned sheet waits 20 s like a send; B2 activate() failure opens the sharing sheet; B3 no export or
  upload until joined with someone else (`ListenTogetherSendGate`), retries silent while alone; alone text
  "Listen Together, sharing, waiting for people to join". A3 End in a background task (expiry ends at once).
  A4 own cancelled/stale shares `end()`. A6 state logs around end/leave.
- Fix round 1: listeners stop receiving before teardown deletes files; pause held by a background task (send +
  notification, max 5 s); away notification for listeners too; Paused notification removed on play/end; idle
  timer released while alone; no retry episode from a join; failed activation's share ended if it arrives;
  "left" wording when everyone vanishes at once; listeners ignore `.groupPaused` during/just after the sharer
  grace; `.groupPaused` carries departed ids (no double message); P-sentence caption under listeners' Play.

## Built before this branch (on develop; details in Notes.md)
- Start position (build 4): the group starts at the sharer's saved place, protected until each joiner reports
  `.inStep`. Earlier: own copy + owners-only, pieces/retries/grace, one message path, Speak, Leave, transfer
  fix (pieces as `Data`, chunk fallback), End really ends SharePlay.

## Test evidence (2026-10-12, build 5)
- Build 5: red 28 failed (old behaviour patched back); SharePlay 590/0; full 1162/0 (after InsertBooksTests
  @MainActor: before it, 4/4 branch runs crashed there in CoreData, develop 2/2 passed); TSan 590/0.
- Fix round 1: red 18 failed; SharePlay 609/0; full 1181/0. Fix round 2 (late `.groupPaused` on a playing
  listener waits 2 s; own-copy exit order test): red 3; SharePlay 612/0; full 1184/0 ** TEST SUCCEEDED **;
  TSan 612/0, 0 warnings, ** TEST SUCCEEDED **.
- Command: xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -destination 'platform=iOS
  Simulator,id=1525DDCB-A5AB-4EDE-B9F2-CAEDC19EEDB1' -testPlan "Unit Tests" -only-testing:BookPlayerTests
  test (per class `-only-testing:BookPlayerTests/<Class>`; TSan adds `-enableThreadSanitizer YES`).
  The usual iPhone 17 simulator (98A8CF98-...) hung installing the app on 2026-10-12 and was shut down.

## Local environment gotchas
- Xcode 27 here, CI uses 26.4. Simulator by id (98A8CF98-... wedged on 2026-10-12; 1525DDCB-... used).
- Wait for the FINAL ** TEST SUCCEEDED/FAILED **; xcodebuild often hangs after the results: log to a file,
  poll, kill your own xcodebuild, rerun if the final line is needed. Never pass -derivedDataPath.
  "Invalid API Key" lines are noise.
- New files: copy an existing file's four pbxproj entries with new ids (Notes.md, Task B).
- TSan on the whole suite stops at a pre-existing DirectoryWatcher race; run SharePlay classes by name.

## Device and assistive-technology checks (two-device run, both phones on the same build)
Setup: Becky (VoiceOver) + Michael (Zoom, VoiceOver off), two iPhones, Discord, start from Messages.
Capture both Console logs filtered on "Listen Together:".
B5. Build 5 first: (a) Becky VoiceOver, phone locked, on Discord; Michael shares; a third phone or Becky
   leaves: book pauses for everyone, notification read (with permission), Play on the lock screen resumes
   everyone. (b) Michael Zoom 3x, player open: caption under Play explains it. (c) Turn a listener's Wi-Fi
   off: "lost their connection" wording. (d) Does `CXCallObserver` report Discord calls (Speak only)? (e)
   After End and after Leave, which phones keep the SharePlay pill; exact Control Center names on iOS 18 and
   26 (fill the guide's "Close SharePlay completely"; add `listen_together_close_shareplay_hint` to
   listeners' ending alerts only if their pill stays). (f) Share from Messages before anyone joins: no
   "didn't start", no "Couldn't send part"; logs "pieces wait until the session is joined". (g) Sharer End
   then Home at once: log "ending the group session" within 2.5 s and "after end ... invalidated". (h)
   FaceTime ringing: sheet opens instead of "isn't available". (i) Order of events when the sharer's own
   connection drops and returns (no second P-announcement).
S. Build 4 checks (start position) remain as listed in Notes.md 2026-10-11.
0. Build 3 checks still open: which path carried the pieces (journal `uploaded piece` or `transport mode
   chunks`, rate at least 32 KB/s); SharePlay indicator gone after End.
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

## Known limitations
- Streamed books and video cannot be shared.
- Chunk fallback: no cloud copy; pieces come from the sharer's phone; throughput unmeasured.
- A piece that fails for good is retried every 30 s (sharer sees the retry status); listeners wait.
- If the sharer switches books mid-session, listeners keep the old book (R12).
- A killed sharer that iOS keeps in the roster never ends listeners' sessions (they see the silence line).
- Own book can't start from Siri/widget/CarPlay while locked during a listener session (R38/R39).
- Notifications dormant (no permission asked); SwiftUI alerts are outside the one-alert gate.
- Mixed builds degrade (old listeners on owners-only shares wait at 0 %; build 4 can't read build 5's pause
  messages): every phone on the same build.
- New strings are English in every lproj; mark for translation before release.
- Own copy: other editions/recordings never match; plays at the sharer's file boundaries (±2 s).

## Open problems and next steps (in order)
1. Review of build 5 (code + a11y); fix rounds; merge to develop; TestFlight 5.22.2 (5) (Becky approves upload).
2. Two-device run on build 5 (item B5 first); record results here and in Notes.md.
3. Fill the guide's Control Center steps from the device check; decide the listener hint string.
4. Parked minors: M3 protocol version, M4 late-join resend, M7 endNotice, M8 two notification-permission
   checks; skip `leave()` on an already invalidated session (investigation tidy-up). Change A. Upstream PR later.

## Decisions waiting on Becky
- A5: a sharer who swipes BookPlayer away leaves the activity open until iOS times it out (no reliable fix);
  end after a grace when backgrounded alone? Not built.
- Pause for everyone on each departure (built, per ruling) vs only when the last listener leaves.
- A killed sharer that iOS keeps in the roster never ends listeners' sessions (silence ruling). OK?
- After 60 s: "The person sharing left. Listen Together ended." (spec); one sentence for both endings?
- Siri dialog / CarPlay alert for the R39 refusal (not built)?
