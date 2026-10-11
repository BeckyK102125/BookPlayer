# Notes.md - full history (append-only)

## 2026-10-10 - Fork, spec, plan, Task 0

Branch `shareplay-listen-together` from upstream `develop` at eb19a92f (merge of PR #1630). Remotes:
origin = BeckyK102125/BookPlayer (fork), upstream = TortugaPower/BookPlayer.

- 906acbf7 Add SharePlay Listen Together design spec.
- 95eda2e0 Add SharePlay Listen Together implementation plan.

### Project-editing helper
The project uses classic groups (objectVersion 54), so new files are not picked up automatically.
Created outside the repo:
  python3 -m venv /private/tmp/bp-tools/venv
  /private/tmp/bp-tools/venv/bin/pip install pbxproj==4.2.1
  /private/tmp/bp-tools/add_to_xcodeproj.py
Usage (run from repo root):
  /private/tmp/bp-tools/venv/bin/python /private/tmp/bp-tools/add_to_xcodeproj.py <target> <group-path> <file>...
  e.g. ... BookPlayer BookPlayer/BookPlayer/SharePlay BookPlayer/SharePlay/Foo.swift
       ... BookPlayerTests BookPlayerTests/SharePlay BookPlayerTests/SharePlay/FooTests.swift
Changes from the plan's version, all needed:
- Groups in this project have `path` but no `name`; the library's get_or_create_group matches by name
  and would have made stray top-level groups. The helper now walks from the main group, matching each
  component against a child group's name or path, and creates a missing one with path = component.
- A leading duplicate `BookPlayer/BookPlayer/...` is treated as `BookPlayer/...` (the app group is
  `BookPlayer` directly under the main group).
- The file is added by basename with sourceTree "<group>", not by absolute path.
- force=True is passed to add_file; without it the library crashes (AttributeError: PBXBuildFile has
  no fileRef) on the package-product build files. Duplicates are checked in the helper instead.
Dry check: added throwaway files; SharePlay group landed inside the `BookPlayer` app group next to
Player and inside the existing BookPlayerTests group; files went into the Sources phases. Reverted the
pbxproj with git checkout and deleted the throwaway files.

### Capability
Added com.apple.developer.group-session = true to BookPlayer.entitlements and
BookPlayer-NoCarPlay.entitlements, and NSSupportsGroupActivities = true to BookPlayer/Info.plist
(before UIBackgroundModes). plutil -lint OK on all three.

### Baseline
Copied BuildConfiguration/Debug.template.xcconfig to Debug.xcconfig (gitignored, not committed).
First attempt with `-destination 'platform=iOS Simulator,name=iPhone 17'` failed: "Unable to find a
device matching the provided destination specifier" (Xcode 27.0 resolves OS:latest = 27.0, which has
only iPhone 18 Pro/Pro Max; iPhone 17 exists on iOS 26.5). Used the id instead:
  xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer \
    -destination 'platform=iOS Simulator,id=98A8CF98-8142-4710-AD5E-5419F782752C' \
    -testPlan "Unit Tests" -only-testing:BookPlayerTests build-for-testing
  -> ** TEST BUILD SUCCEEDED **
  same flags with test-without-building
  -> Executed 572 tests, with 0 failures (0 unexpected); ** TEST EXECUTE SUCCEEDED **
No -derivedDataPath used. No pre-existing failures.

## 2026-10-10 - Task 8: ListenTogetherCoordinatorBridge (branch shareplay-listen-together)
- Added BookPlayer/SharePlay/ListenTogetherCoordinatorBridge.swift and
  BookPlayerTests/SharePlay/ListenTogetherCoordinatorBridgeTests.swift (4 tests).
- hostClockTime on the play command is deliberately ignored: starting a few tens of ms late is
  inaudible for spoken audio and keeps PlayerManager untouched.
- SDK differences from the brief: AVDelegatingPlaybackCoordinatorPauseCommand has no itemTime, so
  handlePause uses the target's own bookTime; expectedCurrentItemIdentifier is non-optional String,
  so it is compared directly (checked for all four commands, not just play).
- Added a seam, ListenTogetherCoordinatorControlling (rate change, seek, begin stall suspension),
  with the real AVDelegatingPlaybackCoordinator as default, so tests assert against a fake.
- RED: tests failed to compile (cannot find ListenTogetherCoordinatorBridge). GREEN: 4 tests, 0
  failures. Full suite: 621 tests, 0 failures.

## 2026-10-10 - Task 9: session service, transport and VoiceOver announcements (branch shareplay-listen-together, parent b36ee048)
- Added BookPlayer/SharePlay/ListenTogetherAnnouncer.swift, ListenTogetherTransport.swift
  (TransportEvent, ListenTogetherTransport, PieceTransfer, GroupSessionTransport),
  SharePlaySessionService.swift (state, start/join/decline/end, teardown) and
  SharePlaySessionService+Session.swift (sharer pipeline, event loop, piece placement, local
  events -> messages). Split into two files to keep each under ~300 lines.
- Tests: ListenTogetherAnnouncerTests (2), SharePlaySessionServiceTests (5, FakeTransport).
  Fixed-yield settle() replaced by a bounded 10 ms polling waitUntil (ruling R4).
- SDK check (iPhoneSimulator27.0): every GroupActivities API in the brief exists as written.
- Differences from the brief: transportFactory is typed @MainActor; announcer init param is
  optional (a default argument would build a @MainActor object outside the main actor);
  published setters for the extension are setState/setListener; the sharer re-sends the
  pieceUploaded map along with the manifest when participants increase (late joiners never
  received the earlier messages; nothing is uploaded again); GroupSessionTransport never loads
  attachments once it has uploaded (so the sharer does not download its own pieces).
- Localization: en.lproj takes precedence over Base.lproj, so Base-only keys showed as raw keys
  (the announcer test failed on that). Copied the 24 English listen_together_* strings (including
  Task 1's activity title) into every *.lproj/Localizable.strings, as the repo does for new keys.
- RED: tests failed to compile (cannot find ListenTogetherAnnouncer / SharePlaySessionService /
  TransportEvent). GREEN: 7 tests, 0 failures. Full suite: 634 tests, 0 failures.

## 2026-10-10 - Task 9 fix round 1 (branch shareplay-listen-together)
- R18: the first participantsChanged of a session is only a baseline (no joined/left
  announcement, no manifest re-send); a count of 0 is ignored. GroupSession's
  $activeParticipants publisher reports the current roster on subscribe.
- end() while preparing cancels the pending share (back to .idle); a second startSharing while
  preparing is ignored. startSharing re-checks the pending share after the system sheet.
- Incoming pieces are moved into ShareStorage.defaultRoot/incoming/ (covered by cleanAll());
  a failed final move deletes the loaded file.
- Tests: 3 added (baseline, zero ignored, end while preparing). Focused 10/0; full suite 637/0.
- Runner pitfall: in the full suite, "Test Suite 'Selected tests' passed" can appear before the
  run is really over (495 tests); wait for "** TEST SUCCEEDED/FAILED **" instead.

## 2026-10-10 - Task 9 fix round 2 (branch shareplay-listen-together)
- A share cancelled while preparing could still deliver its session (activate() in flight) and
  was offered back to the user as an invitation. Cancelled share ids are now remembered and such
  a session is left. Incoming sessions are classified by decision(forIncoming:) (ownShare,
  cancelledShare, invitation, busy). The set is not cleared when a new share starts (that would
  bring the bug back); each id is removed when its session arrives.
- Tests: 2 added. Focused 12/0; full suite 639/0.

## 2026-10-10 - Task 10: accessible Listen Together UI (branch shareplay-listen-together, parent 0d8fe1a6)
- Accessibility consult (Step 1) was done by the controller with mobile-accessibility:
  .superpowers/sdd/2026-10-10-shareplay-listen-together/task-10-a11y-guidance.md. Rulings R19-R25 applied.
  The Step 9 re-review was not dispatched (implementers may not dispatch subagents); a per-view checklist
  is in task-10-report.md.
- New views in BookPlayer/SharePlay/Views/: ListenTogetherBanner (+ ListenTogetherStatus text mapping and
  the needs-FaceTime alert modifier), ListenTogetherInvitationView, ListenTogetherPresentation (MainView
  modifier: invitation sheet, listener cover, closes the player cover / media servers sheet first and
  presents once coversOnScreen shows them gone), ListenerPlayerView (+ header), ListenerControls (position
  adjustable element, transport row, chapters/speed row), ListenerChaptersView.
- Service: canOfferSharing (menu item hidden while preparing/in session/invitation), hasPendingInvitation,
  acknowledgeNeedsFaceTime() (R22), endUnavailable() announces listen_together_unavailable on every
  .ended(.unavailable) path (R22).
- Wiring: MainCoordinator creates the service, calls ShareStorage().cleanAll() then
  startObservingSessions() in start(), injects .environmentObject. PlayerViewModel takes an optional
  sharePlayService (default nil). MainView Magic Tap goes to the listener during a session (R19).
  ListStateManager.Cover gains listenTogetherInvitation and listenTogether. ArtworkView takes an optional
  focus binding so focus lands on the title when the banner leaves while focused.
- Decisions: the slider value is "Elapsed X, remaining Y" and the visible time row is hidden from
  VoiceOver (guidance 4.3 single-element variant); banner sits below title/author/chapter on the listener
  screen (reading order = visual order, no sort priorities); End asks for confirmation except while
  preparing; needs-FaceTime alert waits 0.6 s so it isn't dropped while the More dialog closes.
- 13 new strings in every *.lproj (R16).
- RED: SharePlayMenuTests failed to compile (no sharePlayService init arg, ListenTogetherStatus,
  acknowledgeNeedsFaceTime, endUnavailable). GREEN: 7/0. Full suite: 646 tests, 0 failures.
  The app was installed and launched in the iPhone 17 simulator: boots to the library, no crash.

## 2026-10-10 - Task 10 fix round 1 (branch shareplay-listen-together, parent fb25638b)
- R28: invitations are now presented by MainCoordinator (MainCoordinator+ListenTogether.swift) in a
  UIHostingController from the topmost presented view controller, so open sheets/UIKit modals can't
  drop them; dismissed when the state leaves .invitation; swipe-away declines
  (presentationControllerDidDismiss). Join dismisses the invitation, then closes the player cover
  through playerState, or otherwise dismisses everything above the main view. The service announces
  each invitation (queued; new strings listen_together_invitation_announcement[_no_author]). The
  SwiftUI invitation sheet and its Cover case were removed. ListenTogetherPresentation reads
  coversOnScreen in body and clears the player/media servers when listening starts.
- A-I1: banner remembers the last focused element and when focus was lost, and recovers whether the
  focus reset arrives before or after the removal; End's confirm/cancel move focus to the status first.
- A-I2: Join label colour chosen at runtime (ListenTogetherContrast); banner fill is systemBackgroundColor.
- A-M2 "Normal speed" for 1 (menu and remote announcement); A-M3 position hint; declineInvitation()
  guarded; needs-FaceTime alert acknowledged when the player disappears.
- ListenTogetherStatus moved to its own file (banner under 250 lines).
- Tests: 4 added (invitation announcement, guarded decline, contrast, normal speed). SharePlay tests
  23/0; full suite 650/0. App boots in the simulator.

## 2026-10-10 - Task 10 fix round 2 (branch shareplay-listen-together, parent 633d76fa)
- R29: if a screen beneath the invitation is closed in code, UIKit takes the invitation down without
  presentationControllerDidDismiss. ListenTogetherInvitationHostingController reports viewDidDisappear
  (when no longer presented); the coordinator re-presents it on the next main-loop turn from the topmost
  non-dismissing controller if the state is still .invitation and the user did not answer
  (shouldRepresentInvitation(answered:state:)), and declines if there is no window to present in.
  The swipe-away decline now matches the presented controller by type (viewDidDisappear runs first and
  clears the weak reference).
- Join only calls mainController.dismiss when something is presented. Invitation view doc comment updated.
- Tests: 1 added. SharePlay tests 24/0; full suite 651/0. One full run printed an early
  "BookPlayerTests.xctest passed, 512 tests" summary; rerun waiting for ** TEST SUCCEEDED ** gave 651.

## 2026-10-10 - Task 11: verification and hand-off (branch shareplay-listen-together, parent baf2b739)
- Full unit run (Unit Tests plan, -only-testing:BookPlayerTests, simulator id 98A8CF98-...): last lines
  "Executed 651 tests, with 0 failures (0 unexpected)" and "** TEST SUCCEEDED **". Release build for
  'generic/platform=iOS Simulator': ** BUILD SUCCEEDED **. `git diff eb19a92f --stat --
  BookPlayer/Player/PlayerManager.swift` printed nothing (the brief said "develop"; the local develop may
  have moved, so the branch point was used).
- context.md rewritten as the hand-off snapshot with the device checklist. Nothing pushed.

### Correction (2026-10-10) to the Task 9 entry
The Task 9 entry says the service was split to keep each file "under ~300 lines". That held only at first
(286 and 269 lines). After fix rounds the files are SharePlaySessionService.swift 380 and
SharePlaySessionService+Session.swift 277 lines. The task report said 348 at one point. Current counts are
the ones in the repo.

### Summary of Tasks 0-11 (commits, in order)
- Task 0: 906acbf7 spec, 95eda2e0 plan, 064099dc capability + project notes. Tests 572 baseline.
- Task 1: ab2be765 models and activity.
- Task 2: 5f87672f share storage.
- Task 3: 8d27aec9 piece planner; fix round 1 73edf99e (edge-case tests).
- Task 4: e409a060 book splitter; fix round 1 08dffa53 (source layouts, error paths, 597 tests).
- Task 5: 817a62d2 piece timeline.
- Task 6: e7664daf sharer target; fix round 1 38b2cfd5 (seek detection, echo suppression).
- Task 7: eb79aa75 listener player; fix round 1 5cc5169a (play into missing piece, real pause time, session
  errors); fix round 2 f3dcf59b (discriminating test via item-time seam).
- Task 8: 3fbee6cc coordinator bridge; fix round 1 b36ee048 (buffer flag, nil target, invalidation, NaN).
- Task 9: c47bf7e7 session service/transport/announcements; fix round 1 cf291cbf (baseline participant,
  cancel while preparing, incoming pieces under share root); fix round 2 0d8fe1a6 (cancelled share must
  not become a self-invitation). 639 tests.
- Task 10: fb25638b UI; fix round 1 633d76fa (invitations never dropped, focus recovery, contrast);
  fix round 2 baf2b739 (re-present invitation if a screen beneath closes). 651 tests.
- Task 11: this verification commit. Final: 651 tests, 0 failures; Release simulator build succeeded.
- Test counts along the way: 572 (baseline), 583, 592, 597, 621, 627, 634, 637, 639, 646, 650, 651.
- Fix rounds happened because reviewers found real gaps: untested edge cases (T3, T4), wrong or
  non-discriminating behaviour (T6, T7, T8), and lifecycle bugs in the session (T9, T10).
- Runner pitfall, explained: xcodebuild prints an intermediate "Executed N tests" summary (452, 457, 495,
  512) before the final one. Earlier "flaky short runs" in Tasks 3, 4 and 10 were this, not flakes. One
  run crashed in unrelated RegisterExistingProcessedItemsTests.testRegisterRelinksOrphanedBook; the rerun
  was 627/0 and it was not seen again. xcodebuild also hangs after TEST SUCCEEDED; kill it.

### Rulings R1-R29 (copied from the ledger, one line of reason each)
- R1: Task 6 creates one PlayableItem stub with fileURL so Tasks 9/10 reuse it without editing the mock.
- R2: Manifest is sent once with estimates and re-sent only when participants increase; a "real sizes"
  resend made the late-joiner test racy and sizes only drive a progress fraction.
- R3: beginSharing/beginListening start the event loop in its own Task first, so uploads and events run
  concurrently as the tests need.
- R4: Task 9 tests use a bounded 10 ms polling wait instead of five fixed yields, because real export
  makes yield counts unreliable; assertions unchanged.
- R5: Participant count starts at 1 until the first participantsChanged event, matching the test.
- R6: Tests use the simulator by id 98A8CF98-..., because Xcode 27 has no iPhone 17 on its default
  runtime and iOS 26.5 is closer to CI.
- R7: Accept the Task 0 helper changes (walk groups by name or path, force=True), because the plan's
  helper crashed on the installed pbxproj library.
- R8: Plan paths BookPlayer/BookPlayer/SharePlay mean repo path BookPlayer/SharePlay (plan copied the
  repo-name prefix from CLAUDE.md).
- R9: Commit trailers name the model that actually wrote the commit, for truthful attribution.
- R10: context.md and Notes.md are updated at Tasks 10 and 11, to keep per-task diffs focused.
- R11: The test factory is PlayableItem.stub(currentTime:duration:fileURL:) in an extension, same
  signature and intent as R1.
- R12: When the sharer's current item changes, the target resets its baseline and emits nothing; changing
  books mid-session is out of scope (the spec covers one book).
- R13: A lagging clock (stall, buffering) is not a seek; only backward jumps over 1 s or forward jumps
  beyond expected + max(2, 1.5 x rate) count, to avoid false skips during stalls and at high speed.
- R14: A listener pressing Play with the piece missing emits played so the group plays and the stall
  suspension holds everyone; pausing into a missing piece does not suspend. Matches the spec.
- R15: The bridge honours the buffering flag on seek and pause, and Task 9 also wires onNeedsPiece to
  waitForPiece; both are idempotent.
- R16: New listen_together_* strings go into every *.lproj, because en.lproj overrides Base and Base-only
  keys showed as raw keys; translators replace them later.
- R17: Late-joiner re-send of pieceUploaded messages alongside the manifest is accepted, because the
  joiner cannot map journal attachments to pieces without them.
- R18: The first participantsChanged of a session only sets the baseline (no announcement, no manifest
  re-send) and a count of 0 is ignored, because the publisher reports the current roster on subscribe.
- R19: During a listener session Magic Tap toggles the listener, not the library player (a11y consult
  had it wrong).
- R20: The More-menu item is hidden while preparing, sharing or listening, to prevent a second start.
- R21: When an invitation arrives or listening starts while the player cover is open, close it first,
  because SwiftUI cannot present a second cover over an open one.
- R22: Two small service changes allowed: acknowledgeNeedsFaceTime() and a queued announcement for
  ended(.unavailable), both found missing by the a11y consult.
- R23: Listener skip labels use a fixed 30 s, not the main player's skip settings, since listener skips
  are fixed.
- R24: The spec's SharePlay icon on the More item is dropped because BPActionItem has no icon.
- R25: Two-finger Z is ignored on the listener screen so a session is not ended by accident; the End
  button is labelled.
- R26: Lock-screen and AirPods commands still drive PlayerManager during a listener session; out of scope
  this version, listed as a known limitation.
- R27: Accepted Task 10 choices pending review: End confirmation (flagged for Becky), banner below the
  title block, FaceTime alert delayed 0.6 s, media-servers sheet also closed, optional focus binding.
- R28: Invitations must never be dropped: queued announcement plus presentation from the topmost
  presented view controller by MainCoordinator; Join dismisses everything above the main view.
- R29: If the invitation controller disappears while the state is still .invitation, re-present it
  rather than decline, to keep the user's choice.

### Handed on
Device acceptance not started (see context.md). Temporary clone /private/tmp/bp-src removed;
/private/tmp/bp-tools kept until the branch is merged or abandoned.

## 2026-10-10 - Final fix wave after the whole-branch review (branch shareplay-listen-together, parent f2b926a3)
Rulings R31 and R32 (ledger). Fixed in one pass, each with a fake-based unit test:
- C1: the coordinator bridge now knows its role (new init parameter `role`, default `.listener`). The
  sharer calls transitionToItem with a CMTimebase snapshot on the host clock (time = its book time,
  rate = its rate when playing, else 0); before, both roles passed nil, which the SDK treats as paused
  at 0:00, so a later play jumped the sharer to the start. Listeners still pass nil. The call goes
  through ListenTogetherCoordinatorControlling.transitionToItem(withIdentifier:proposingTime:rate:) so
  tests can see it; invalidate() uses the same call with a nil identifier.
- I1: PieceTimeline.location(for:) picks the last piece starting at or before t + 1e-6 (clamped to
  the end of the last piece; nil only for negative, NaN or empty). The old strict [start, end) lookup
  returned nil in one-ULP seams between pieces, and the listener stalled. ListenerPlayer.advanceToNextPiece
  now loads the next piece in book order by index at its own start (PieceTimeline.piece(after:)).
- I2 (R31): ListenerPlayer's user actions emit their event BEFORE applying locally, so coordinateSeek /
  coordinateRateChange reach the coordinator before a missing piece starts the stall suspension (calls
  made while suspended only affect the local object, per AVPlaybackCoordinator.h).
- I3: a speed change made while paused arrives only as an announcement; now the receiver also sets it
  silently (ListenTogetherPlaybackTarget.applyRate; the sharer uses setSpeed with the echo guard).
  Decision in SharePlaySessionService.silentRate(for:target:).
- I4: SharerPlaybackTarget uses removeDuplicates().dropFirst(); the first value equal to the initial one
  is no longer reported. testNoOpRemotePlayDoesNotSwallowLaterUserPause's setup was corrected to give
  the publisher a current value that matches "already playing".
- Cheap: "0 seconds" (listen_together_zero_seconds) instead of an empty string in the position value;
  an incoming session while this device is preparing its own share is .busy; the listener cover is
  shown from .listening with a "getting the book" screen (invitation title, banner with status and End,
  listen_together_getting_book_message) until the manifest arrives, then the normal controls, same cover.
  Two strings added to all 26 lproj (44 in total).
- context.md corrected: iOS 18.0, R1-R32, string count, known limitations (I5 sharer killed mid-call,
  speed saved in the sharer's library, sleep timer/CarPlay/lock screen on listeners, speed picker gaps).
Evidence: RED run with the behaviour reverted (new APIs kept): 69 focused tests, 13 failures across the
9 behaviour tests. GREEN focused: 69 tests, 0 failures. Full: xcodebuild ... -testPlan "Unit Tests"
-only-testing:BookPlayerTests test -> "Executed 668 tests, with 0 failures", ** TEST SUCCEEDED **.
Not device-tested; SharePlay timing (C1, I2) needs the two-device run.
Report: .superpowers/sdd/2026-10-10-shareplay-listen-together/final-fix-report.md

## 2026-10-10 - shareplay-listen-together - a11y residuals (final-a11y-check items 1-5)
- Item 1 (Important): Magic Tap on "Getting the book" could start the paused library book. Added a no-op
  .accessibilityAction(.magicTap) on ListenerGettingBookView and ListenTogetherPresentation.magicTapTarget(
  state:hasListener:) (.listener / .nothing while .listening with no listener / .libraryPlayer); MainView
  switches on it. Unit test testMagicTapNeverReachesTheLibraryBookInAListenerSession.
- Item 2 (Important): ListenerPlayerView takes initialFocusDelay (default 600 ms); the listener screen passes
  150 ms when it replaces the getting-book view (@State set in that view's onAppear). Heading still focused once.
- Item 3: no separate change (ordering follows from item 2). Item 4: message moved above the banner (title,
  explanation, status, End). Item 5: spinner/message use a VStack at accessibility Dynamic Type sizes.
- Evidence: focused SharePlayMenuTests 15 tests, 0 failures; full suite "Executed 669 tests, with 0 failures",
  ** TEST SUCCEEDED **. Not device-tested (VoiceOver swap focus on title/status/End still needs hardware).

## 2026-10-10 - listen-together-lock-screen - addendum 1 Change C (lock screen, Control Center, AirPods)
Branch listen-together-lock-screen from develop e634f5c7. Spec: addendum-1 Change C; binding guidance:
addendum-a11y-guidance.md section C.
- New BookPlayer/SharePlay/ListenTogetherRemoteCommands.swift: @MainActor router (static shared, weak
  service, attached in MainCoordinator.init after startObservingSessions). Every existing AppDelegate
  handler (toggle, play, pause, skip fwd/back, next/previous track, seek fwd/back endSeeking, change
  position) and accessibilityPerformMagicTap ask `handle(_:)` first. No addTarget added (still 10).
  Gate: service.state == .listening. Listener nil -> .noActionableNowPlayingItem (guidance C2; never
  .success for nothing, never PlayerManager). play/pause idempotent. Skip ±30. next/previous track ->
  next chapter start / current chapter start (or previous chapter within 3 s, same rule as PlayerManager);
  no chapters or no next chapter -> ±30 (brief said chapters; guidance said ±30 - brief followed, flagged).
  changePosition uses book time (no chapter offset) and is coalesced 0.3 s via an injectable scheduler.
- Skip preferredIntervals [30] + enabled and changePlaybackPosition enabled on entering .listening;
  previous values snapshotted and restored on leaving (ListenTogetherCommandSettings seam).
- New ListenTogetherNowPlaying.swift: pure builder (title = chapter or book, artist = book or author,
  album = author, chapter number/count, duration, elapsed in book time, rate 0 while paused or waiting
  for a piece, default rate 1, media type audio, no artwork) + playbackState; shouldPublish() publishes on
  play/pause/wait, rate, chapter, position jumps > 1.5 s (any change when paused) and every 15 s while
  playing; republish on didBecomeActive with fresh values. Before the manifest: the invitation title, paused.
- ListenerPlayer: @Published isWaitingForPiece (didSet of waitingPieceIndex).
- Hand-back: PlayerManagerProtocol exposes no Now Playing call; pause() re-publishes the paused own book's
  stored info (rate 0, .paused) and is called only when an own book is loaded and not playing. No own book:
  nowPlayingInfo nil, .stopped. PlayerManager.swift untouched.
- Wording: listen_together_invitation_listen_only appended to the invitation message; one-time sharer
  alert (listen_together_first_share_title / _message) on PlayerView, shown 600 ms after the first
  .sharing on the device, remembered on OK (UserDefaults.standard listenTogetherFirstShareNoteSeen, injected
  `defaults`); a note not acknowledged before the session ends shows next time. 3 strings in Base + 26 lproj.
- Guide: "With the screen locked" section, invitation/first-share wording, lock-screen limitation removed,
  Magic Tap warnings kept.
- Tests: ListenTogetherRemoteCommandsTests (17), ListenTogetherNowPlayingTests (6),
  ListenTogetherFirstShareNoteTests (2). Timing-free (fixed clock, hand-run scheduler).
  RED (mutation: router gate removed, waiting ignored in isActuallyPlaying, defaults check removed):
  25 tests, 46 failures in 5 tests. GREEN focused: 25 tests, 0 failures, ** TEST SUCCEEDED **.
- Process slip: rm /private/tmp/bp-tools/*.bak also deleted an older LP.bak left by an earlier task
  (not tracked by git; ListenerPlayer.swift in git is intact).
- Not device-tested. Open: announcements while locked may be silent (guidance C3 VERIFY); pause during a
  piece wait does nothing; interruption pauses the group (guidance D3).
Report: .superpowers/sdd/2026-10-10-shareplay-listen-together/change-c-report.md

## 2026-10-10 - listen-together-lock-screen - Change C fix round 1 (review change-c-a11y-review.md)
Parent e09474bd. Ruling R33 and reviewer items CT-I1..I4, CT-M1..M7.
- R33: next/previous track during a listener session = userSkip(±30), not chapters (chapter helpers and
  their tests removed). Guide bullet updated.
- Skip settings (also CT-M4): at session end the router restores the LIVE user settings
  (PlayerManager.forwardInterval/rewindInterval, !isForward/RewindChapterSkip, UserDefaults
  seekProgressBarEnabled; injectable `userSettings` provider), not a start snapshot. Mid-session changes:
  [30]/enabled/position re-applied on UIApplication.willResignActiveNotification. Why: PlayerManager's
  static setters write the command centre directly AFTER UserDefaults (a defaults-change observer would be
  overwritten), settings can only change while the app is active, and the lock screen / Control Center
  are visible only after the app resigns active. Rejected: didBecomeActive (too late for the lock screen).
- MPNowPlayingInfoPropertyChapterNumber is zero-based (MPNowPlayingInfoCenter.h:111): publish the index.
- CT-I4: the first-share note now appears BEFORE sharing starts. More menu -> chooseListenTogether(item):
  first time, note shown (state stays idle, menu item hidden); OK -> acknowledgeFirstShareNote() saves the
  flag and calls startSharing. Player closes first -> cancelFirstShareNote(), nothing shared, shown next
  time. sharingStarted() removed. No announcement can collide with it.
- CT-M1/M2 wording: invitation "You can only listen. The book is not saved on your device."; note title
  "People who join can only listen", message "They do not get a copy of the book. What they download is
  deleted when the session ends." (reviewer's "Their copy is deleted" contradicted "no copy").
- CT-M3: Magic Tap before the book arrives announces listen_together_not_available_now ("Not available
  yet") and returns true. New key in all 26 Localizable.strings (48 listen_together_* keys).
- Guide (CT-I1, I2, M7 + coordinator list): note moved to "Share a book" step 4; invitation sentence as a
  Join step; "the book changes for everyone" plus a hedge that spoken messages may be silent while locked;
  Magic Tap bullet; interruption on a listener pauses everyone; starting your own book switches the lock
  screen; CarPlay line corrected. CT-I3 resolved by R33. CT-M5/M6: device checks only.
- Tests: RemoteCommands (chapter tests replaced by one ±30 test; settings test reads live user settings;
  new testUserSettingChangedMidSessionKeepsThirtyThenIsRestoredLive), NowPlaying (chapter number 1 for
  the second chapter), FirstShareNote rewritten (note before sharing; cancel). Focused (+SharePlayMenuTests):
  39 tests, 0 failures, ** TEST SUCCEEDED **. Full: "Executed 693 tests, with 0 failures",
  ** TEST SUCCEEDED ** (694 before; net -1 test).

## 2026-10-10 - listen-together-lock-screen - Change C fix round 2 (R34)
Parent 2d324abb. Ruling R34: escape never starts an action. The first-share note now has two buttons:
"Share" (new key listen_together_share_button, default action; calls acknowledgeFirstShareNote(): saves the
shown-once flag and starts sharing) and "Cancel" (existing cancel_button, cancel role; two-finger Z picks it;
calls cancelFirstShareNote(): nothing shared, flag not saved, note shown next time). Closing the player also
cancels. export_button ("Share") not reused: it means export and its translations may differ.
Tests: ListenTogetherFirstShareNoteTests renamed testShareStartsSharingAndSavesTheFlag /
testCancelSharesNothingSavesNothingAndShowsAgain (+ a late Share after Cancel does nothing). Focused
(note + SharePlayMenuTests): 17 tests, 0 failures, ** TEST SUCCEEDED **. Full: "Executed 693 tests, with
0 failures", ** TEST SUCCEEDED **. 49 listen_together_* keys in all 26 Localizable.strings.

## 2026-10-10 - listen-together-lock-screen - escape goes back + Listen Together row (R35, R36)
Parent 54399521. Guidance: .superpowers/sdd/2026-10-10-shareplay-listen-together/escape-row-a11y-guidance.md
(supersedes "escape is ignored on the listener screen"). Rulings: R35 escape on the listener screen and on
"Getting the book" closes to the library, the session continues; R36 a listener's own mini player is hidden
and the row takes its slot, the sharer gets the row above their mini player. Becky's rule: escape is always
cancel/back.
- User intent: ListStateManager.isListenerScreenRequested. ListenTogetherPresentation gains pure functions:
  showsListenerScreen(state:hasListener:isCovered:isRequested:) (false when not requested; covered logic
  unchanged), isListenerScreenRequested(after: .sessionStarted/.opened/.closedByUser/.stateChanged)
  (stateChanged to anything but .listening clears it: end, idle, new invitation), closeListenerScreen
  (listState:) (no service parameter, so escape cannot end, pause or start anything), and
  focusesRowAfterListenerScreenCloses. The cover binding setter now clears the request (system dismissal).
  Escape on ListenerPlayerView and ListenerGettingBookView calls onClose (no announcement, no pause).
- ListenTogetherStatusRow (new, SharePlay/Views): one Button; label listen_together_title; value from
  ListenTogetherRow.value (playing/paused/waiting + title, "getting the book, N percent" in 25 percent steps
  plus the joined title when known, "sharing, title" or "sharing"); hint per role; id listenTogether.row;
  no End and no custom actions; bpFont headline/subheadline, no line limit, AX sizes stack vertically
  without the icon, min height 56, theme background + secondary outline (banner treatment), width capped
  at 600. Listener snapshot (isPlaying, isWaitingForPiece) via Combine so the row does not observe the
  twice-a-second time. Focus: ListStateManager.listenTogetherRowFocusRequest, bumped 500 ms after the
  listener cover closes by the user, or after the sharer closes the player while sharing.
- MainView: ListenTogetherRow.bottomBar decides row / mini player; VStack(spacing 8) row above the mini
  player, one bottom clearance (moved out of MiniPlayerView; Spacing.S1 in edit mode). Row hides only for
  the keyboard. iOS 26.0 accessory: listener = row (isAccessory style), sharer = MiniPlayerAccessoryView with
  accessibilityValue "Listen Together, sharing, title". Environment listenTogetherRowIsShown makes
  MiniPlayerSafeAreaInsetModifier keep the inset when only the row shows (no own book loaded).
- 8 keys (listen_together_row_hint_listener/_sharer, _value_playing/_paused/_sharing/_sharing_untitled/
  _waiting/_downloading) in all 26 Localizable.strings. _sharing_untitled added because the guidance says
  to drop an empty sharer title.
- Guide: section 8 wording (join step 7, mini player hidden, during the session, share step 6, end section).
- Tests: ListenTogetherRowTests (19, new) + SharePlayMenuTests updated for isRequested. RED: build failed
  (ListenTogetherRow / isRequested missing). GREEN: "Executed 19 tests, with 0 failures", ** TEST
  SUCCEEDED **. Full: first run crashed in unrelated InsertBooksTests.testInsertMultipleBooksIntoPlaylist
  (EXC_BAD_ACCESS in CoreData _PFFastMOCObjectWillChange from LibraryService.createFolder; pre-existing
  threading flake, like the RegisterExistingProcessedItemsTests one) -> 570 executed, TEST FAILED. Rerun:
  "Executed 712 tests, with 0 failures", ** TEST SUCCEEDED ** (693 + 19). No new warnings.
- Not done: device / VoiceOver checks (guidance section 11). Decision 1 settled by R36 as "always hide"
  (the guidance had recommended showing the own mini player while the own book plays).
