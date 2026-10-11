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

## 2026-10-10 - listen-together-lock-screen - escape + row fix round 1
Parent 8b76a6e5. Code review: the row covered the edit-mode bottom toolbar (Move/Delete) because edit mode
only got Spacing.S1. New MiniPlayerLayout (View+BookPlayer.swift): bottomClearance = tabBarContentHeight + 8
whenever there is bottom chrome (compact width, or edit mode in any width, since the editing toolbar takes the
tab bar's place), else Spacing.S1; contentInset = stack + 20 - chrome height, used by MiniPlayerModifier
(now reads listState.isEditing), so content scrolls clear in every combination. Minors: row snapshot seeded in
init and receive(on:) dropped (main-actor publishers); session start only on a real false->true change
(isSessionStart; onChange(initial:) on a rebuild no longer re-requests the screen after escape); vacuous
service assertion replaced by testEscapeOnlyClearsTheRequest; comment on the iOS 26.0 sharer focus path.
A11y review WARN-1/2: iOS 26.0 accessory row capped at .xxxLarge Dynamic Type and uses the system .primary
colour on glass; TIP-1: accessory value "Listen Together, sharing" (title not repeated). Guide: "(or the back
gesture)" removed; TIP-2 sentence on pausing your own book from the lock screen added. context.md: the
-derivedDataPath and "Invalid API Key" notes restored in one line. Tests: ListenTogetherRowTests 23 +
SharePlayMenuTests: "Executed 38 tests, with 0 failures", ** TEST SUCCEEDED **. Full: "Executed 716 tests,
with 0 failures", ** TEST SUCCEEDED ** (no restart). No new warnings; no project file changes.

## 2026-10-10 - listen-together-messages - addendum 1 Change B: start from Messages
Branch `listen-together-messages` from develop at 63e9578b. No FaceTime call needed: when
GroupStateObserver.isEligibleForGroupSession is false, Apple's GroupActivitySharingController is presented
instead of the "start a FaceTime call" alert. SDK check: the class lives in _GroupActivities_UIKit
(re-exported by GroupActivities), `init(_ activity:) throws`, `var result: GroupActivitySharingResult
{ get async }` with .success / .cancelled. No delegate callback exists; `result` is what tells us the sheet
finished.
- ListenTogetherSharingSheet.swift (new): ListenTogetherStartRoute (activate / sharingSheet /
  needsFaceTime), ListenTogetherSharingSheetOutcome (sent / cancelled / unavailable), protocol
  ListenTogetherSharingSheetPresenting (canPresentSharingSheet, presentSharingSheet(for:) async).
- SharePlaySessionService: pure `startRoute(isEligibleForGroupSession:canPresentSharingSheet:)`;
  startSharing routes through it. Test seams: `isEligibleForGroupSession` closure (wraps the observer),
  `schedule` (delay + action; tests use a ManualScheduler, no real clock), weak `sharingSheetPresenter`
  (nil = fallback alert, so the existing first-share-note tests still end at needsFaceTime). Sheet path:
  the share is recorded pending WITHOUT `.preparing` (no banner, nothing announced before the sheet).
  Cancelled: cancelledShareIDs + clear + .idle at once, "Listen Together was not started." announced
  0.7 s later. Sent: at 0.7 s, if our session has not arrived, `.preparing` + "Preparing <title> to share"
  announced; at 3 s, if still pending, same cancel path. Unavailable: `.needsFaceTime` (fallback alert).
  Timers check the share ID, so End on the banner or a newer share is never touched by an old timer.
  `received` now uses `claimOwnShare(_:)` (test seam).
- MainCoordinator+ListenTogether: conforms to the presenter; sets itself in bindListenTogether. Waits
  600 ms (More menu / first-share note closing, same as the alerts), presents from the topmost screen
  (shared `topmostPresenter()` helper, also used by the invitation), falls back to .unavailable if the
  init throws or UIKit does not accept the presentation, awaits `result`, dismisses the sheet if it is
  still up.
- Strings (all 26 files, English values): invitation messages no longer mention FaceTime ("Listen to %@ by
  %@ together." / "Listen to %@ together."); needs-FaceTime title/message -> "Couldn't open sharing" text
  from the guidance; new listen_together_cancelled_announcement.
- Guide: "Two ways to start" (Messages, FaceTime), Magic Tap warning only for FaceTime (Discord VERIFY
  hedge), share steps rewritten, join step for Messages invitations, end/limitations wording.
- Tests: ListenTogetherSharingSheetTests (11). RED: build failed (startRoute, presenter, outcome,
  schedule, delays missing). GREEN after two test fixes (item file must exist in the processed folder;
  cancel announcement is a second scheduled step): "Executed 11 tests, with 0 failures", ** TEST
  SUCCEEDED **. Full: "Executed 727 tests, with 0 failures", ** TEST SUCCEEDED ** (716 + 11). No new
  warnings in touched files.
- Not done / VERIFY on device: whether the sheet dismisses itself and when `result` resolves (assumed on
  close); whether `result` resolves if the app is backgrounded or the player closes under the sheet (if it
  never resolves the share stays pending and Listen Together stays hidden until relaunch); B2.7 (timeout
  on return to foreground) not implemented separately.

## 2026-10-10 - listen-together-messages - Change B fix round 1 (R37)
Parent f2ad757b. From the code review (I1, I2) and change-b-a11y-review.md (I-1..I-4, M-1..M-5).
- R37 timing: after a send, wait up to 20 s (was 3 s) for our session. On timeout the share is RELEASED,
  not cancelled: pending cleared, .idle, "Listen Together didn't start. Try again." (new key). It is kept
  as `lateShare` (most recent only): if its session still arrives while nothing is pending, running or
  offered, decision `.lateOwnShare` starts it as our share and announces "Listen Together started." (new
  key). If something else is going on, `.staleOwnShare`: the session is left (its people would otherwise
  wait in a session nobody shares into). Only an explicit `.cancelled` result (or End) adds to
  cancelledShareIDs; a Cancel reported after a release moves the late share to cancelledShareIDs.
- Stuck sheet (B2.7): new outcome `.abandoned`. MainCoordinator's ListenTogetherSharingSheetWatch races
  `controller.result` with a 1 s poll (sheet off screen on two checks in a row) and a willEnterForeground
  check (1 s after return). GroupActivitySharingController is not open, so no subclass; I did not take
  over its presentationController delegate either, so Apple's own handling stays as it is. The service
  also schedules a 120 s watchdog when the sheet opens. Abandoned/watchdog release the share like the
  timeout (Listen Together and invitations work again).
- I-4: result announcements go through announceSheetResult, which re-checks at 0.7 s that this is still
  the latest sheet share and nothing is pending or running.
- `received` now runs through `action(forIncoming:)` (leave / ignore / offer / share(item, late:)), a
  test seam without a GroupSession; claimOwnShare is private again.
- Guide: Magic Tap "should play and pause", Discord hedge in all three places (I-3); "Two ways to start"
  bullets carry the Magic Tap line (M-2); "sharing screen from Apple", "cannot start Listen Together"
  (M-3); Share step 4 split into three steps, FaceTime confirmation mentioned, "You may hear Preparing"
  (M-4); 20 s wait explained. M-5: comment where .needsFaceTime is set; translation noted in context.md.
  M-1: device check only (no focus code added).
- Tests: ListenTogetherSharingSheetTests now 17 (ManualScheduler keeps an absolute clock). New: first-share
  note Share opens the sheet; own session after explicit Cancel is left; session at 19 s claimed; at 25 s
  after the timeout claimed when idle; late session left while another share is pending; announcement
  dropped when a new share starts; never-returning sheet released by the watchdog (then a late Cancel
  marks it cancelled); abandoned outcome. No separate RED run was captured this round (code and tests
  written together). The first run crashed in the test scheduler (unowned capture of a scheduler nobody
  retained); I fixed the test helper. Focused: "Executed 17 tests, with 0 failures", ** TEST SUCCEEDED **.
  Full: "Executed 733 tests, with 0 failures", ** TEST SUCCEEDED ** (716 + 17). No new warnings.

## 2026-10-10 - develop - merge shareplay-listen-together and push (backfilled by fix wave 2)
- With Becky's approval, develop was fast-forwarded to e634f5c7 (shareplay-listen-together: guide and
  addendum 1 design). Merged-result tests: 669 tests, 0 failures, ** TEST SUCCEEDED **. Pushed develop and
  shareplay-listen-together to origin (BeckyK102125/BookPlayer). Source: progress.md ledger.

## 2026-10-10 - listen-together-lock-screen - device signing and install (backfilled by fix wave 2)
- Becky chose team Techopolis (M9SNPTXA44) and bundle ID app.techopolis.BookPlayer-together, set only in
  the gitignored BuildConfiguration/Debug.xcconfig, with BookPlayer-NoCarPlay entitlements (the CarPlay
  entitlement needs Apple approval). BookPlayer backend, account and sync do not work under this ID.
- The lowercase bundle ID (app.techopolis.bookplayer-together) clashed with the existing App ID (IDs are
  case-insensitive), so the local setting uses the existing casing. The App ID and the app group
  group.app.techopolis.BookPlayer-together.files already existed.
- Becky approved the install (automatic signing registers App IDs, app group, iCloud container). Built
  Debug from listen-together-lock-screen @ 54399521 and installed on her iPhone 15 Pro
  (00008130-001C08390232001C). Log: /private/tmp/bp-tools/device-build.log, ** BUILD SUCCEEDED **.
- Side effect: Xcode wrote team, bundle ID and automatic signing into project.pbxproj and reordered
  Info.plist. Both reverted with git checkout, never committed. Future device builds pass signing
  overrides on the command line and revert any churn before committing.

## 2026-10-10 - listen-together-lock-screen - R35/R36 approved; develop fast-forward and push (backfilled)
- Becky approved the escape change (R35, supersedes R25: escape on the listener screen goes back to the
  library while the session continues; End only through the End button) and the Listen Together row
  above the tab bar (R36: listener hides the own mini player; sharer gets the row above it).
- After the escape/row change and its fix round (54399521..63e9578b, re-review approved), develop was
  fast-forwarded to 63e9578b and develop + listen-together-lock-screen were pushed to origin. Branch
  listen-together-messages was started from 63e9578b for Change B. listen-together-messages is not pushed.

## 2026-10-10 - listen-together-messages - fix wave 2 (whole-branch review + concurrency audit)
Parent cd821236. Inputs: whole-branch review 609ce7e8..cd821236 (I1-I5 + minors, ruling R38),
concurrency-audit.md (A-I1, A-I2, M1-M9, 2 strict diagnostics), Change B re-review minors.
- W-I1 / R38: PlayerLoaderService gets `playbackStartGate` (main app sets it in bindListenTogether) and
  `mayStartPlayback()`, `playPauseLoadedBook()`, `playLoadedBook()`. loadPlayer(autoplay: true) asks
  before loading and returns false (discardable) when declined; ItemListView, SearchView and
  MainCoordinator.loadPlayer then don't open the player. Same-book paths gated too: widget
  BookPlaybackToggleIntent, ActionParserService toggle/play deep links, AppServices.playLastBook.
  Decision: ListenTogetherOwnPlayback.decision(isListenerSession:canAsk:) -> play / ask / refuse;
  canAsk = app active and a presenter exists. Ask = UIAlertController "Leave Listen Together to play this
  book?" with Leave (destructive; ends the listener session via end(), then plays) and Cancel (cancel
  style, so escape = Cancel); taken down without an answer = Cancel. Refuse (locked, background, Siri,
  CarPlay with phone locked): nothing plays, logged. Not gated (they call PlayerManager directly and are
  hidden or closed during a listener session): player screen Play, mini player, ButtonFree, video,
  LibraryRootView cold-launch restore. PlayerManager untouched.
- W-I2: the 120 s sheet watchdog asks the presenter `isSharingSheetPresented` and reschedules itself
  while the sheet is up (pure `sheetWatchdogAction`); MainCoordinator tracks the sheet weakly.
- W-I3: MainView's Magic Tap (.nothing) and the getting-book screen's Magic Tap post "Not available yet"
  (ListenTogetherPresentation.announceNotAvailableYet, immediate post like AppDelegate's).
- W-I5: invitation shown through a retry chain (generation-checked): presentInvitation now reports a
  refused present (presentingViewController nil after present). Retry every 0.5 s up to 20 attempts,
  then decline (pure MainCoordinator.invitationPresentationStep). The R29 re-present path uses it too.
- Minors: ListenerPlayer toggle while held for a piece during a playing wait (play, playing seek or next
  piece missing) sends nothing and calls onToggleWhileWaiting -> "Waiting for the book to download"; a
  paused seek into a missing piece followed by Play still sends play (R14). "Listen Together started"
  announced for every sheet share's session (startedAnnouncement; FaceTime shares stay silent), once.
  Replaced late share -> cancelledShareIDs. "didn't start" not announced while an invitation shows.
  Sharing-sheet watch: controller held weakly, result task checks cancellation, foreground observer calls
  a MainActor method (fixes the 2 strict diagnostics at MainCoordinator+ListenTogether.swift:198).
  AppDelegate remote commands and Magic Tap call ListenTogetherRemoteCommands.route / isRoutingNow
  (nonisolated; on main -> assumeIsolated, else main.sync). Listen-only wording unified on "downloaded
  for this session only and deleted when it ends" (invitation, End hint, first-share message, guide).
  New strings (Base + 25 lproj, English): listen_together_leave_to_play_title/_message, _leave_button.
- Audit: A-I1 SharerPlaybackTarget's isPlaying/speed sinks use receive(on: DispatchQueue.main) +
  assumeIsolated (seam deliversOnMainQueue: false for the synchronous fake-publisher tests). A-I2
  startListening / startSharingSession are synchronous and run in the same turn as session.join() in
  joinInvitation / received; a refused setup leaves the transport; uploadPieces is the only async part,
  stored as sharingTask (M1) and cancelled in tearDown, with cancellation checks in the loops. M2 sharer
  end message limited to 2 s (withTimeLimit, continuation-based so a stalled send can't hold it). M3 one
  outbox stream + consumer per session. M4 SharerPlaybackTarget.stop() from tearDown. M9 coordinator
  delegate commands hop via DispatchQueue.main.async (FIFO) instead of separate Tasks.
  Not done: M5 (ListenerPlayer deinit; stop() already covers it), M7 (moving setActive(false) off main
  could deactivate after R38 Leave started the own book), M8 (transport deinit backstop; A-I2 removes
  the leak path).
- Guide: R38 section replaces "pause it from the lock screen" and "lock screen switches to your own
  book"; invitation retry note; toggle-while-waiting; "Listen Together started" step; limitation line.
- Tests: new ListenTogetherOwnPlaybackTests (13); SharePlaySessionServiceTests +7; SharingSheetTests +5;
  SharerPlaybackTargetTests +2; ListenerPlayerTests +2; RemoteCommandsTests: testPlayAndToggleReportAPlay
  now expects nothing sent on the second press (held for the piece) and a new testToggleReportsAPlay.
  No separate RED run was captured (code and tests written together). Results: see the next entry
  lines and fix-wave-2-report.md.
- Results: SharePlay classes 191 tests, 0 failures; full suite "Executed 763 tests, with 0 failures",
  ** TEST SUCCEEDED ** (733 + 30). TSan (17 SharePlay classes, -enableThreadSanitizer YES): 191/0, 0
  ThreadSanitizer warnings. First TSan run aborted inside CoreMedia figTimelineCoordinator_endSuspensionOnQueue
  (CFRelease trap) in the new toggle-while-waiting service test, the first test that begins and ends a stall
  suspension on a real session-less AVDelegatingPlaybackCoordinator. A throwaway test (deleted) reproduced it
  under TSan only; 12/12 passed without TSan. Pre-existing product path (End while a listener waits); the
  test now clears onNeedsPiece. Device check added. Strict concurrency (complete, local build in default
  DerivedData, not committed): the 2 audit diagnostics are gone; 2 new ones from this wave's main-hop helpers
  fixed with @Sendable; 0 left in SharePlay files.

## 2026-10-10 - listen-together-messages - fix round 2 (wave-2 reviews: C1, a11y I-1..I-3, minors)
Parent ab5df6f7. Inputs: wave-2 code review (C1 + minors), fix-wave-2-a11y-review.md, ruling R39.
- C1: Leave on "Leave Listen Together to play this book?" resolved as Cancel: UIKit runs a UIAlertAction
  handler in the alert's dismissal completion, AFTER viewDidDisappear, and viewDidDisappear answered
  Cancel at once. New ListenTogetherLeaveQuestion.makeAlert: a MainActor `Once` box delivers the first
  answer; a disappearance answers Cancel only after 0.3 s (asyncAfter), so the handler wins. Evidence:
  hosted ListenTogetherLeaveAlertTests presents the real alert from a key window, dismisses it and runs the
  Leave handler in the completion (as UIKit does), records the order ["disappear", "handler"] and gets
  [.leave]; Cancel and no-answer (-> .cancel after the delay) also tested; no preferredAction on Leave.
- Second Leave alert ignored while one is up (MainCoordinator.isAskingToLeaveListenTogether).
- R39 / a11y I-1: refusal (question can't be shown) is never silent: ListenTogetherOwnBookFeedback (new
  file) posts the queued announcement "You're in Listen Together. Unlock to play your own book." and, only
  when notification permission was already granted (authorized/provisional/ephemeral), a local
  notification "Your book did not start" / "You are in Listen Together. Open BookPlayer and choose the book,
  then choose Leave.", at most once per 30 s. BookPlayer has never requested notification permission, so in
  practice only the announcement happens (and VoiceOver may not speak it while locked). No permission
  prompt added. Siri dialog / CarPlay alert not built (listed as an open decision).
- a11y I-2: the gate now receives the book's title (PlayerLoaderService passes it). Leave calls
  SharePlaySessionService.leaveForOwnBook(announcement:) = tearDown with "You left Listen Together. Playing
  <title>." instead of "Listen Together ended" (one announcement), then requests player-title focus;
  PlayerView consumes the request (10 s lifetime) and focuses the title 600 ms after it appears. Cancel:
  nothing announced, focus stays.
- a11y I-3: "listen_together_not_available_now" = "Waiting for the book. Play is not available yet.",
  queued (ListenTogetherAnnouncer.postQueued), at most once per 2 s; AppDelegate's lock-screen path uses
  the same helper. Toggle-while-waiting "Waiting for the book to download" at most once per 3 s
  (ListenTogetherRepeatLimiter).
- Cheap a11y minors: M-1 prompt message "You will leave Listen Together on this iPhone. The others keep
  listening."; M-5 "saved on your iPhone/their device for this session only" in invitation, first-share
  message and guide; End hint "Leaves Listen Together and deletes the downloaded book.". Not done: M-2,
  M-3 (key rename / naming the book), M-4 immediate post and percent.
- Code minors: AppServices.loadAndKeepAlive returns false on a declined load and restores the widget's
  previous now-playing path; CarPlayManager.playItem doesn't push Now Playing after a decline.
- Docs: guide (heard texts, Leave announcement, Magic Tap wording, ignored-invitations limitation);
  context.md (R27 decided, R39, Known limitations: invitations ignored during own sheet/20 s wait,
  play?showPlayer=true deep link can open the own player; decisions updated).
- New strings (Base + 25 lproj, English): listen_together_own_book_blocked, _notification_title,
  _notification_body, listen_together_left_for_own_book, listen_together_left_for_own_book_playing.
- Tests: ListenTogetherLeaveAlertTests (4, new, hosted), ListenTogetherOwnPlaybackTests +7 (title to gate,
  left announcement, leaveForOwnBook, refusal feedback + 30 s limit, focus request, repeat limiter),
  toggle-while-waiting test presses twice. Focused 18 SharePlay classes: 202/0. Full: first run crashed in
  pre-existing InsertBooksTests.testInsertExistingBookFromPlaylistIntoLibrary (CoreData flake, seen before);
  rerun "Executed 774 tests, with 0 failures", ** TEST SUCCEEDED **. One earlier full run failed the
  no-answer alert test (fixed 0.6 s wait too short under full-suite load): waits are now bounded polls.
- TSan (18 SharePlay classes, -enableThreadSanitizer YES): "Executed 202 tests, with 0 failures",
  ** TEST SUCCEEDED **, 0 ThreadSanitizer warnings, no restarts. Strict concurrency not re-run this round.

## 2026-10-11 - listen-together-own-copy - addendum 2 "Both have the book"
Parent 9c70dd06 (develop). Inputs: docs/superpowers/specs/2026-10-10-shareplay-listen-together-addendum-2.md
(committed here), own-copy-a11y-guidance.md, controller-notes.md. Report: own-copy-report.md.
- Fingerprint: new BookPlayer/SharePlay/BookFingerprint.swift. Normalised title/author (case and diacritic
  folded, whitespace/punctuation trimmed, inner whitespace collapsed), total duration, per file book start
  + duration + byte size, SHA-256 hex of the first 64 KB of the first file (FileHandle read, no decoding,
  Task.detached so it never runs on the main actor). BookFingerprintMatcher: layout (±2 s total and per
  file, same count) AND (hash equal OR title AND author AND every size within ±1 %); bestMatch picks the
  most recent lastPlayDate (nil last). Carried in ListenTogetherActivity (new optional `fingerprint`,
  `ownersOnly`) because the manifest only reaches a listener after joining and the guidance needs the
  match before the invitation is shown; also in SharedBookManifest (optional `fingerprint`). Optional
  fields: older JSON still decodes (tested).
- Library lookup: new ListenTogetherOwnCopy.swift. LibraryOwnCopyFinder(libraryService:, playbackService:)
  built by MainCoordinator from CoreServices and injected into SharePlaySessionService (init param, nil
  in tests). Reads only: searchAllBooks(query: nil) (books + bound folders, main context, SimpleLibraryItem),
  filtered by duration, skips remoteURL items, PlaybackService.getPlayableItem -> BookSplitter.sourceFiles
  for the layout; only layout matches are hashed. No Shared/ change (no new LibraryService method).
- Invitation: offerInvitation stores the session, runs prepareInvitation (test seam) with a 3 s limit
  (ListenTogetherFirstResult, cancels the slow check), then: own copy -> invitationOwnCopy + .invitation
  (sheet message "You have this book, so BookPlayer plays your copy...", Join hint "Pauses your current book
  and plays your copy together."); no copy + send -> today's invitation; no copy + owners-only ->
  declineWithoutCopy: ListenTogetherDecline.sendAndLeave (join, wait for .joined, send .declinedNoCopy,
  leave; 3 s limit), needsCopyNotice set, no sheet, no invitation announcement. MainCoordinator presents a
  single-button alert (OK = cancel style, so escape closes it) with the invitation's 0.5 s x 20 retry,
  only while the app is active; otherwise ListenTogetherNeedsCopyFeedback (queued announcement, notification
  only with existing permission, max one per 30 s). Deviation, deliberate: the decline is sent when the
  decision is made, not when OK is pressed, so the sharer hears it promptly and nothing stays pending if
  the alert can't be shown; OK/escape only closes the alert (no second action either way).
- Join: joinPlan re-checks the copy (files exist with the matched sizes). Usable -> own copy; unusable ->
  download in send mode, "Your copy can't be used" + decline in owners-only. Own copy:
  transport.stopReceivingPieces() before join (GroupSessionTransport skips journal loads), ListenerPlayer
  built at once from ListenTogetherOwnCopy.manifest (own files as pieces placed at the sharer's file book
  starts/durations, all marked arrived), so no getting-book screen; state .listening(_, 1) from the start
  (no transient fraction); "Joined. Playing your copy." once after sheetAnnouncementDelay; later pieces,
  attachments and the sharer's manifest are ignored. End hint "Leaves Listen Together. Your own copy is
  kept." (ListenTogetherStatus.endHint usesOwnCopy).
- Safety: nothing new deletes files. Tests: own library file (Documents/Processed) survives end(), the
  sharer's .sessionEnding, .invalidated, leaveForOwnBook, ShareStorage.remove/cleanAll (custom and default
  root). Mutation check: a temporary tearDown change that deleted every played file made the 4 teardown
  tests fail (8 assertion failures); reverted (diffed against a backup).
- Sharer: Settings -> Playback -> Listen Together (SettingsScreen.listenTogether, new
  Settings/ListenTogether/SettingsListenTogetherView.swift): inline Picker "When someone doesn't have the
  book" with "Send it for this session" (default) / "Only people who have the book can join", footer per
  guidance, row accessibilityValue "Sends the book"/"Owners only". UserDefaults.standard key
  listenTogetherWhenNoCopy (ListenTogetherSharingMode), read in makeActivity, so a change applies to the
  next share. Owners-only: manifest without pieces, nothing exported or uploaded. Send mode: always uploads
  (late joiners without a copy; owners never load pieces). First-share note message depends on the mode
  (send-mode text changed to "If they don't have the book, it is saved...").
- Roster: TransportEvent.participantsChanged gains ids (default []), new .participantDeclined(id:) (the
  transport maps the .declinedNoCopy message with its sender). With ids: baseline, then new ids are counted
  and announced "Someone joined" only after joinConfirmationDelay (2 s, via the schedule seam) if still
  present and not declined; counted ids that leave -> "Someone left"; decliners never counted/announced.
  Sharer hears "Someone couldn't join because they don't have the book." at most once per 10 s
  (ListenTogetherRepeatLimiter, `now` seam); listeners hear nothing. Count-only events keep the old path.
- Strings (Base + 25 lproj, English): listen_together_invitation_own_copy(_no_author), _join_hint_own_copy,
  _joined_own_copy, _end_hint_listener_own_copy, _need_copy_title/_message, _copy_unusable_title/_message,
  _declined_no_copy, _first_share_message_owners_only, settings_listen_together_title/_header/_send/
  _owners_only/_value_send/_value_owners_only/_footer; changed listen_together_first_share_message.
- Guide: intro, "Using your own copy", "When someone doesn't have the book", first-share note, decline line,
  join steps, Leave keeps own place, temporary copy vs own copy, known limitations.
- Tests: BookFingerprintTests (22) and ListenTogetherOwnCopyTests (23), written after the code in this
  round (no separate RED run except the mutation check above). Focused 20 SharePlay classes: "Executed 247
  tests, with 0 failures". Full suite run 1: InsertBooksTests.testInsertOneBookIntoPlaylist crashed (known
  pre-existing CoreData flake), 818 others passed, xcodebuild then hung without a final marker (killed);
  rerun "Executed 819 tests, with 0 failures", ** TEST SUCCEEDED **. TSan (20 SharePlay classes,
  -enableThreadSanitizer YES): "Executed 247 tests, with 0 failures", ** TEST SUCCEEDED **, 0
  ThreadSanitizer warnings. No new compiler warnings in changed files.
- Contrast: the Settings screen's header and footer use the theme's primary colour (lowest 6.4:1 over the
  11 themes, light and dark); the secondary colour measured 2.46-4.91:1 (fails 4.5:1 in most themes).

## 2026-10-11 - listen-together-own-copy - own copy fix round 1
Parent de1f5731. Inputs: own-copy-fix-round-1.md (rulings), own-copy-code-review.md, own-copy-a11y-review.md.
- Code I1: BookFingerprint.sampleHash now hashes the first 64 KB of AUDIO DATA: `audioDataOffset` walks
  top-level MP4 atoms when `ftyp` is first (32-bit, size==1 64-bit, size==0 to end) to the `mdat`
  payload; skips an ID3v2 tag (synchsafe size, +10 with the footer flag); anything else or any parse
  failure (atom past the end, no mdat) falls back to the file start.
- A11y I1 / M10: removed the extra accessibilityLabel on the inline picker (labelsHidden keeps the name).
- A11y I2: "Joined. Playing your copy." is scheduled 300 ms after ListenerPlayerView puts focus on the
  title (`listenerTitleFocused`), with a 1.5 s fallback from Join; said once per session.
- A11y I3 / code M5 (reverses the earlier deviation): owners-only decline (ListenTogetherPendingDecline
  send/abandon) is sent only when the "You need your own copy" alert is presented
  (`needsCopyNoticePresented`). If the app isn't active, the notice waits (no 10 s drop) and is shown on
  the next didBecomeActive; meanwhile a notification only with existing permission (max one per 30 s).
  A newer notice abandons an older unsent decline (plain leave).
- Code M6 / a11y M1: the join-confirmation delay applies only to owners-only sessions (sharer and
  listener, `isOwnersOnlySession`), raised to 4 s (a11y M2: covers the decliner's 3 s join wait).
  Send mode announces and counts at once.
- Code M1 / a11y M2: test for a decline after "Someone joined": only the decline line, count back, no
  "left" (already behaved so; the test passed in the red run).
- Code M2: owners-only timeout -> cause .checkTimedOut: "Couldn't check your library" / "BookPlayer
  couldn't check your library for %@ in time, so you can't join. Ask the person sharing to send it."
  (new keys, Base + 25 lproj, English).
- Code M3: if this device is in a session or preparing its own share when the check finishes, the
  invitation is left (abandon) and cleared instead of overwriting "Preparing".
- Code M7: not changed. LibraryService.searchAllBooks and PlaybackService.getPlayableItem read the
  viewContext internally; moving them off main needs a background-context API in Shared/ (out of
  scope). The per-candidate file stats are cheap; hashing is already off main.
- Parked: M4 drift, M8 activity size (device checks), M9 first-share note after a mode change.
- Also: stale escape comment in ListenerPlayerView; guide (decline timing, next-open, timeout wording,
  owners-only join delay).
- TDD: red run with API stubs: "Executed 59 tests, with 21 failures" (10 tests: 3 hash, step function,
  joined line, decline on present, newer notice, timeout cause, own share during check, send-mode join);
  green "Executed 59 tests, with 0 failures". 20 SharePlay classes: 261/0. Full: "Executed 833 tests,
  with 0 failures", ** TEST SUCCEEDED ** (first run). TSan 20 classes: 261/0, 0 ThreadSanitizer warnings.

## 2026-10-11 - listen-together-own-copy - own copy fix round 2
Parent 7bf22248. Inputs: own-copy-rereview-1.md (N1, M-a, M-b), coordinator rulings 1-4.
- N1 (1): ListenTogetherPendingDecline.watchInvalidation (test seam; production = session.$state sink
  for .invalidated). declineWithoutCopy keeps that observation in `noticeObservation` (apart from
  invitationBag, which clearInvitation empties). On invalidation the notice and its decline are cleared
  with no send; MainCoordinator bumps needsCopyPresentationGeneration whenever the notice becomes nil.
- N1 (2): ListenTogetherNeedsCopyNotice.createdAt from the service's `now`; needsCopyNoticeIsCurrent()
  discards a notice older than 60 s (abandon = plain leave, no alert, no send). Checked at
  didBecomeActive and before every presentation attempt.
- M-a (3): active with no presenter now retries every 0.5 s until shown or expired (step returns
  .retry while active), instead of waiting for a didBecomeActive that may not come.
- M-b (4): tests for an invalid synchsafe ID3 size (falls back to file start) and a size==0 mdat.
- TDD: red with stubs "Executed 63 tests, with 9 failures": the invalidation test, the age test and the
  step-function test failed; the two hash tests passed in red (behaviour already implemented in round 1;
  they pin it). Green 63/0. 20 SharePlay classes 265/0; full "Executed 837 tests, with 0 failures",
  ** TEST SUCCEEDED ** (first run); TSan 20 classes 265/0, 0 ThreadSanitizer warnings.
- Guide: the message appears if BookPlayer is opened within a minute; dropped after that or when the
  sharer stopped.

## 2026-10-11 - listen-together-own-copy - addendum 3, Task A: reliable sending engine (no UI)
Parent 1598e8d4 (spec docs/superpowers/specs/2026-10-11-listen-together-addendum-3-reliable-sending.md,
brief .superpowers/sdd/2026-10-10-shareplay-listen-together/reliable-sending-task-A-brief.md). Code commit
87f4a744. Why: field test on 5.22.2 (1): the listener pressed Play, 0.4 s later the sharer's phone sent
"session ending" (only End or failSharing after 3 failed piece attempts send it); the sharer's error was not
captured. Investigation: getting-book-investigation.md (paths 1-5).
- PiecePlanner: target 12 min, max 15 min, byte cap 90 MB as a duration cap; files <= 15 min and <= 90 MB
  are copied whole; chapters grouped until >= 12 min (never past 15); spans > 15 min split evenly into
  ceil(len/12 min) parts (more if the byte cap needs it). Multi-file books: file boundaries are cuts.
  Tests: 2-min chapters, 10-h chapter, no chapters, multi-file, mixed, high bitrate. `uploadOrder` removed.
- PieceUploadScheduler (new file): requested pieces (listener `.needPiece`) first, then the piece at the
  group position (sharer's own player time when it holds the book, else item.currentTime; seam
  groupPositionProvider), then forward, wrapping. Asked before every piece, so a far seek re-prioritises.
- Retry: PieceRetryPolicy 2/5/15/30 s (cap); interruptions (CancellationError, AVError
  operationInterrupted/mediaServicesWereReset, URLError.cancelled, or the app not active at the start or
  end of the attempt) do not count: 2 s when active, 30 s in the background. ListenTogetherRetryWaiter ends
  a wait early on didBecomeActive and at teardown. failSharing now only for "could not prepare the book"
  (sourceFiles/folder), not for piece failures. Typed notice `.retryingSend` while retrying.
- Awake: ListenTogetherAppSystem (new file; UIKit implementation + tests' FakeAppSystem). Idle timer held
  off while pieces are left (previous value restored when all sent or at teardown; re-asserted per piece
  and on activation). ListenTogetherBackgroundTask around each export+upload: end() from the defer and
  from the expiration handler, guarded by .invalid. Test covers success, upload error, expiration, end.
- Listener: AVQueuePlayer; the next arrived piece is inserted behind the current one (on load and on
  arrival); `queueAdvanced` follows currentItem KVO; `decisionAtEnd` (pure) decides between the queued
  piece, waiting, and end of book. Periodic time maps through the current item's piece. Item status
  .failed and failedToPlayToEndTime logged with domain/code and extension.
- Path 3: ListenerPlayer.onPositionReady after any successful load -> bridge.pieceBecameAvailable; the
  bridge also re-checks after play/seek/pause commands. Tests: move back into an arrived piece ends the
  stall; a listener at 0 is released when piece 0 arrives late.
- Path 5: listener `.requestState` on join and every 5 s while it has no manifest or holds an unmapped
  attachment (scheduleSessionTimer seam, separate from `schedule`); sharer answers with
  resendForLateJoiners. The count-increase re-send stays.
- Decision 9 (logic): sharer `.heartbeat` every 5 s. Listener: sharer messages (manifest, pieceUploaded,
  heartbeat) refresh contact; silence > 15 s while the group needs the sharer (playing, waiting for a
  piece, or no manifest yet), or a roster of 1 after seeing 2+, -> notice `.waitingForSharer`, player
  paused locally, bridge.holdForSharer (its own stall suspension). Back (any sharer message) -> released.
  Missing 60 s -> tearDown(.sharerLeft). `.sessionEnding` -> tearDown(.sharerEnded) on listeners.
  `endNotice` keeps sharerEnded/sharerLeft until acknowledgeEndNotice() or a new session. Status line and
  announcement stay the generic "Listen Together ended" until Task B.
  Judgment call (flagged in the report): silence while the group is paused and nothing is awaited does
  not count, so a sharer who paused and locked the phone (app suspended) does not end the session after
  75 s (device check "paused + locked 5+ minutes"). Leaving the roster still counts at once.
- Diagnostics: export start (index, whole, source, range, estimate, app state) and end (preset, bytes,
  seconds), upload start/end, every failure with domain/code (public) and description (private), app
  state changes in a session, stall begin/end and "still not ready", coordinator commands, attachment
  load start/end/bytes/ext, group session state, manifest/piece/placement lines, end reason.
  BookSplitterError.exportFailed(index:preset:underlying:) and pieceTooLarge(index:bytes:).
- Seams added: appSystem (init), retrySleep, pieceExporter, groupPositionProvider, scheduleSessionTimer,
  coordinatorControlFactory. uploadRetryDelay removed.
- Removed the stale "Not shown after every attempt..." lines on NeedsCopyPresentationStep.waitForActive.
- Tests: new ListenTogetherReliableSendingTests (30); planner, splitter, models, bridge, listener player,
  session tests updated. Existing test changes: upload failure now keeps the session; own-copy sharer
  ending expects .sharerEnded; local-action tests filter .action (listeners now also send .requestState).
- TDD: red run = test build failed on the missing APIs (ExportedPiece, PiecePlanner.targetDuration,
  ListenTogetherAppSystem, queuedPieceIndex, holdForSharer, new messages...). First green run 306 tests,
  2 failures (own-copy test expecting .normal; a test that set the idle timer before reading its
  history), both test fixes. Then 306/0. Presence refinement (paused = harmless) added with 2 tests:
  21 SharePlay classes 308/0. Full: "Executed 880 tests, with 0 failures", ** TEST SUCCEEDED ** (first
  run). TSan 21 classes: 308/0, 0 ThreadSanitizer warnings (one pre-existing "Thread Performance
  Checker" priority-inversion line from CoreData in an own-copy test, also in an earlier TSan log).
- Guide: small parts and faster start, sharer keeps BookPlayer open while sending, failures retried and
  never end the session, sharer End ends for listeners, sharer missing -> wait up to a minute.

## 2026-10-11 - listen-together-own-copy - addendum 3 Task A, fix round 1
Parent de116941. Inputs: reliable-sending-task-A-review.md, reliable-sending-task-A-fix-1.md (rulings).
- I1: transport keeps failed attachment loads (`hasFailedPieceLoads`, `retryFailedPieceLoads()`,
  `reloadPiece(attachmentID:)`); the listener retries them on a 5/10/20/30 s timer until teardown. Sharer:
  `.needPiece` for a sent piece re-sends its pieceUploaded; if `hasAttachment` says it is gone from the
  journal, the piece is unmarked and re-exported/uploaded, restarting `runSendLoop` if it had finished.
- I2 (new ruling, replaces "silence while needed -> wait/end"): silence only shows `.waitingForSharer`
  (no hold, never ends). Only the sharer leaving the roster (by participant id from
  `TransportEvent.sharerParticipant`, else roster of one) starts the 60 s grace -> `.sharerLeft`.
- I3: `endedShareIDs` (sharerEnded/sharerLeft/sharerCouldNotPrepare, own End, Leave for own book);
  `decision(forIncoming:)` -> `.endedShare` -> leave silently.
- Minor: unplayable piece dropped + reloaded + awaited (`ListenerPlayer.pieceFailed`); failed piece goes
  behind the others (scheduler `markFailed`, per-piece back-off); idle timer only switched back if we
  switched it off; state answers max 1 per 2 s, coalesced; planner merges segments < 30 s (byte cap
  kept); `.sharerCouldNotPrepare` message and EndReason; one heartbeat queued at most; test seam moved
  to a test extension. Parked: listener position lag one hop after a queue advance; real app system in
  SharePlaySessionServiceTests.
- TDD: red = test build failed with the production changes stashed (minimumDuration,
  sharerCouldNotPrepare...). Green: 21 SharePlay classes 327/0.
- Full run 1: all 899 tests passed but xcodebuild hung before printing the final line; killed and rerun.
- Full run 2: "Executed 899 tests, with 0 failures", ** TEST SUCCEEDED **. TSan 21 SharePlay classes:
  327/0, 0 ThreadSanitizer warnings (the same pre-existing CoreData "Thread Performance Checker" line).

## 2026-10-11 - listen-together-own-copy - addendum 3 Task A, fix round 2
Parent d786c79e. Input: reliable-sending-task-A-rereview-1.md.
- I-A: an unplayable piece is reloaded on the 5/10/20/30 s schedule, counted per piece
  (`pieceDecodeFailures`), via scheduleSessionTimer guarded by the transport; teardown stops it.
  Before: reloaded at once, a tight loop for a file that never plays.
- Transport retry/reload Tasks now go into `tasks`, so `leave()` cancels them.
- endedShareIDs also on `.sendFailed` and on invalidation of a known share (`.unavailable` has no share).
- Guide: "can't be used to join again until BookPlayer is restarted".
- New test: a sharer rejoining with a new participant id (passed in red: pins existing behaviour).
- TDD: red ReliableSending 47 tests, 5 failures (immediate reload x4 asserts, invalidation). Green:
  21 SharePlay classes 330/0; full "Executed 902 tests, with 0 failures", ** TEST SUCCEEDED ** (first
  run); TSan 21 classes 330/0, 0 ThreadSanitizer warnings.

## 2026-10-11 - listen-together-own-copy - addendum 3 Task B (what people see and hear)
Parent 9cedab87. Code commit 482ba093. Inputs: reliable-sending-task-B-brief.md,
reliable-sending-a11y-guidance.md, leave-button-a11y-guidance.md, reviewer-common.md (R40, R41).
- New ListenTogetherMessages.swift: ListenTogetherUserMessage (text, key, kind, speaks, isEnding,
  waitsForListenerCover), ListenTogetherDeliveryPlan (pure, per message and app state),
  ListenTogetherAlertQueue (one on screen, FIFO, newest ending replaces pending, no duplicates),
  ListenTogetherMessageDelivery (owned by the service as `messages`; announcer, speaker, notification
  only with existing permission, afterListenerCoverGone), ListenTogetherCoverTracker (listener cover
  onAppear/onDismiss), ListenTogetherFocusRequests (mini player focus; MiniPlayerView and the iOS 26
  accessory observe it).
- New ListenTogetherSpeaker.swift: one AVSpeechSynthesizer (usesApplicationAudioSession=false,
  mixToTelephonyUplink=false), utterance.prefersAssistiveTechnologySettings only, gate = setting on,
  VoiceOver off, no connected call (CXCallObserver), checked at speak time; same key never queued twice;
  background task per utterance (ended on finish, cancel, expiry); VoiceOver turning on stops at the next
  word and clears; Hear a Sample after 0.5 s, even with VoiceOver, a repeat tap restarts.
- Service: tearDown(reason:announcement:announces:leaveTransport:). Endings by others (sharerEnded,
  sharerLeft, sharerCouldNotPrepare, prepareFailed) post no announcement, have no banner text, and deliver
  one alert after everything is cleared (OK acknowledges endNotice). EndReason.sendFailed -> prepareFailed.
  endUnavailable and "didn't start" deliver alerts. setNotice delivers waitingForSharer / retryingSend once
  per episode and "The person sharing is back." when the wait clears in session. New published
  isSharerGraceRunning, isListenerWaitingForPiece (mirrors the player), isPausedByOther, someoneDeclined;
  statusConditions. leave() for listeners (focus then "You left Listen Together." after the cover).
  clearEndNotice and showInvitation drop pending alerts.
- ListenerPlayer.isHeldForSharer + onToggleWhileHeldForSharer (2 s limiter); remote play/pause/toggle
  return .success silently while held.
- Views: ListenTogetherStatus.line (priorities, detail line, spoken text, icon), waitingCaption,
  ListenTogetherSessionAction (Cancel Sharing / End / Leave). Banner: status + optional second line,
  primary-colour icon, ListenTogetherSessionButton (symbol + text, primary outline), custom action label
  per state, leave confirmation modifier. ListenTogetherListenerScreen owns "Leave Listen Together?";
  getting-book draws the button full width under the card; player skips its title focus while the
  question is up; ListenerWaitingCaption under the transport row; play button value. Invitation Join
  (.borderedProminent, primary tint, background-colour label, shareplay symbol) and Not Now (xmark,
  primary outline). Transport icons, Chapters, Speed (+ gauge symbol), position bar/times, author line,
  getting-book text in primary. Row value "waiting for the person sharing, %@".
- MainCoordinator: listenTogetherAlertStep (pure), presenter with 0.5 s settle delay after every trigger
  (new alert, cover gone, alert closed, app active), retry while another Listen Together alert is up;
  needs-copy presenter waits while a message alert is up. Needs-copy and needs-FaceTime alerts are also
  spoken (E18, title only).
- Settings > Playback > Listen Together: "Messages" section, "Speak error messages" toggle (AppStorage
  listenTogetherSpeakErrors, off), footer, Hear a Sample when on.
- Strings (Base + 26 lproj, English): 22 keys added or changed (send_failed and waiting_download changed).
- Deviations: sharerLeft says "The person sharing left. Listen Together ended." (spec decision 9; the a11y
  guidance wanted the End sentence; controller said spec wins). Listener side of a prepare failure uses
  "Couldn't prepare the book for sharing. Listen Together ended." Own-copy leave hint/confirmation say the
  copy stays (new strings). E6b not shown (coordinator doesn't expose it). Silence-only waiting shows no
  "within a minute" line and doesn't hold Play (Task A ruling: silence never ends).
- TDD: tests written with the code; red check by disabling the ending mapping and the held-for-sharer gate:
  ListenTogetherMessagesTests 31 tests, 5 failures (alert order, sharerLeft alert, play while held). Then
  green. One test expectation fixed (E8 "Someone left/joined" announcements also posted; filtered).
- Results: 24 SharePlay classes 373/0 (new: Messages 31, Speaker 9, Contrast 3). Full: "Executed 945
  tests, with 0 failures" (test-without-building) before the commit; full `test` on 482ba093: "Executed 945
  tests, with 0 failures", ** TEST SUCCEEDED ** (first run, no hang).
  TSan 24 SharePlay classes: 373/0, 0 ThreadSanitizer warnings (one pre-existing CoreData Thread Performance
  Checker line in ListenTogetherOwnCopyTests).
- New files were registered by copying an existing file's four pbxproj entries (build file, file ref,
  group child, sources phase) with fresh 24-hex ids (script in the session scratchpad).

## 2026-10-11 - listen-together-own-copy - addendum 3 Task B, fix round 1
Parent 572d267b. Inputs: reliable-sending-task-B-fix-1.md (rulings), -code-review.md, -a11y-review.md.
- I1: EndReason.connectionEnded for `.invalidated` and the event stream ending while still in session
  (own End/Leave tear down first, so one ending per session). Listener alert "Listen Together ended
  because the connection to the person sharing was lost." (waits for the cover, endNotice); sharer
  "Listen Together ended because the call or connection ended.". No announcement, no banner.
- I2: cover wait bounded: the listener screen's onDisappear also reports the cover gone; a 2 s watchdog
  after an ending is queued (and the same limit in whenListenerCoverGone, run once); re-checked on
  didBecomeActive (`forceCoverGoneIfOverdue`); the tracker is reset when a new session starts. If a
  full-screen cover is still up, the alert shows over it and the cover is dismissed after OK, focus to the
  mini player 0.5 s later. Both fallbacks are logged.
- I3/M6: the getting-book banner gets onRequestLeave; the banner has no Leave question of its own and
  offers Leave only when the host owns the question (`ListenTogetherSessionAction.isOffered`).
- I1/I2 (a11y): plan takes a context (app state, locked = protected data unavailable, VoiceOver). Only
  `.background` is away; `.inactive` keeps the alert. Away + unlocked + VoiceOver off: notification and the
  alert stays pending (already spoken). Notification counts only when `.authorized` with alerts enabled.
- I4: "Waiting for the person sharing" (announced, spoken, minute line, caption, row "waiting for the
  person sharing") only in the roster grace; delivered where the grace starts/ends ("is back" only then).
  Silence: "Can't reach the person sharing. The book keeps playing." status and row value, nothing said.
- I5/I6/M8: Settings Listen Together sections are plain Sections on the system background; the switch tint
  is chosen per theme (link, primary, or link blended toward black/white in 5 % steps) so the track is
  3:1 on the row and the white thumb 3:1 on the track; test over 22 variants; test comment corrected.
- I7: sharer row value "couldn't send part of the book, trying again, %@" while retrying.
- Minors: listener prepare-failure sentence; Leave = EndReason.left (no "ended" banner, also leave to play
  own book); focus-to-announcement gap 500 ms; Cancel after the getting-book -> player swap focuses the
  title; isConfirmingLeave read through a binding; speaker keeps its utterances and drops an entry when its
  background time runs out (log names the task); invitation waits while a message alert is up (not counted
  towards giving up), message alerts wait for the invitation, retry backs off 0.5 s -> 5 s; needs-copy
  notice doesn't age while held back by a message alert; footer without ">" and mentions calls; three unused
  end_hint keys removed from all lproj; guide updated (no ducking claim, background rules, new sentences).
- Parked (device checks): sharer End action sheet position at Zoom (a11y M9); iOS 26.0 accessory status (M10).
- TDD: new tests first; red check with the cover watchdog, the inactive rule and the invalidation reason
  reverted: ListenTogetherMessagesTests 48 tests, 11 failures. Green after restoring.
- Results: 24 SharePlay classes 392/0 (Messages 48, Speaker 10, Contrast 4; old invalidation test updated).
  Full: "Executed 964 tests, with 0 failures", ** TEST SUCCEEDED **. TSan 24 classes 392/0, 0
  ThreadSanitizer warnings (same pre-existing CoreData performance-checker line). One SharePlay run hung after
  its results (known xcodebuild hang); killed and rerun.

## 2026-10-11 - listen-together-own-copy - addendum 3 Task B, fix round 2
Parent 282f27c4. Inputs: reliable-sending-task-B-code-rereview-1.md, -a11y-rereview-1.md.
- N1: the stuck-cover fallback records the exact controller presented when the cover watchdog fires
  (`currentCoverSnapshot`, held weakly as `stuckCover`), and only while an ending alert is pending (never on
  the Leave path). MainCoordinator dismisses it only if it is still that presented controller
  (`closesStuckCover`, pure). Forgotten by tearDown, Leave, dropPendingAlerts (new invitation/session).
  The Leave-path watchdog now resets a stuck tracker first (its change runs the action once).
- N2: a cover that goes away normally clears `coverWaitStartedAt`, so a later wait gets its full 2 s.
- N3: invitation and needs-copy waits behind a message alert back off 0.5 -> 5 s; closing a message alert
  retries both at once.
- a11y N1/N3: guide lines (sharer leaves the app while sending; "for one of these reasons"; ongoing list
  includes "can't reach the person sharing"). a11y N2: Picker tinted primary (checkmark), contrast test.
- TDD: red with the fixes reverted: Messages 53 tests, 4 failures; the Leave-path recording test 2
  failures when recording was unconditional. Green: 24 SharePlay classes 398/0; full "Executed 970 tests,
  with 0 failures", ** TEST SUCCEEDED ** (two earlier full runs hung after the results and were killed);
  TSan 398/0, 0 warnings (same pre-existing CoreData performance-checker line).

## 2026-10-11 - listen-together-own-copy - final whole-branch review fixes
Parent 27d86fd2. Inputs: final-branch-review-2026-10-11.md, final-fix-round.md (rulings).
- I1 (own copy can't be played): `listenerPieceFailed` branches for own copy (`ownCopyFileFailed`). After the
  5/10/20 s back-off the own file is armed again (`pieceArrived`) if it still exists with its matched size
  (`ownFileIsUsable`); if it is gone, or on the 3rd failure (`ownCopyFailureLimit`), this phone leaves with
  `EndReason.ownCopyFailed` and one alert `ownCopyUnplayable` "Your copy of this book can't be played right
  now. You left Listen Together." (new key, Base + all lproj; waits for the cover, Speak covers it). Own
  copy never gets "Waiting for the book" (no announcement, status, caption, toggle line or row value).
  The others' stall ends when this phone leaves (bridge invalidated).
- M1: BookFingerprint MP4 walk uses `fileSize - position` bounds (loop `position < fileSize`, remaining >= 8;
  `size >= headerLength, size <= fileSize - position`); ID3 offset uses addingReportingOverflow.
- M2: new `isListenerPlaying` mirror; the silence line shows only while the book plays (row too); before the
  manifest "Getting the book N percent" stays.
- M5: `.needPiece` before the scheduler exists goes to `pendingPieceRequests`, requested when the send order
  is made. M6: during the roster grace a message ends the grace only if the sharer's id is in the roster.
  M9: `sessionGeneration` in the delivery; a background ending whose notification check outlives a new
  session is dropped. M10: session timers capture the transport weakly.
- M11: context.md rewritten (TestFlight build 1 done, build 2 pending Becky, R40/R41, device list).
- Guide: own-copy failure line.
- Parked: M3 (update both phones; protocol version later), M4 (late-join burst; device check with 100+
  files), M7 (endNotice unused outside the service), M8 (two notification-permission checks).
- TDD: red with the fixes reverted: 94 tests (Messages, OwnCopy, early-request test), 17 failures; the M1
  test crashed the test process with the old bound. Green: 24 SharePlay classes 406/0; full "Executed 978
  tests, with 0 failures", ** TEST SUCCEEDED **; TSan 406/0, 0 ThreadSanitizer warnings (same pre-existing
  CoreData performance-checker line).

## 2026-10-11 — develop merged, pushed, TestFlight build 2 (develop)
- Final whole-branch review fixes 85c42b29 re-reviewed: ready to merge. `develop` fast-forwarded from
  `listen-together-own-copy` to 85c42b29 and pushed to origin (Becky approved).
- TestFlight: temporary worktree at 85c42b29, Release with Techopolis automatic signing (command-line overrides
  as for build 1 plus CURRENT_PROJECT_VERSION=2), archive succeeded (5.22.2 (2), app.techopolis.BookPlayer-together),
  exported with app-store-connect/upload, internal testing only: "Upload succeeded". Warning: Sentry.framework
  dSYM missing for symbol upload (harmless). Worktree, archive, export and logs deleted.
- Device log capture from Becky's phone (idevicesyslog over USB) deleted after analysis.

## 2026-10-11 - listen-together-transfer-fix - transfer fix (build 3): A + B, readable errors, real End
Parent b73bd061 (develop). Inputs: transfer-fix-brief.md, transfer-root-cause-2026-10-11.md (H1-H4).
Field facts (build 2): messages cross both ways, no audio piece ever arrives, sharer shows "Couldn't send
part of the book" (Messages and FaceTime, single local .m4b).
- Fix A (ListenTogetherTransport.swift): `PieceTransfer` = `DataRepresentation(contentType: .data)`,
  exporting `Data(contentsOf:options: .mappedIfSafe)`, importing writes into ShareStorage root/incoming.
  `journal.add(_:metadata: PieceMetadata(pathExtension:))`; load reads `loadMetadata` and names the file
  `PieceTransfer.receivedFileName` (extension sanitised by `ChunkFrame.wireExtension`, `m4a` fallback).
  `ListenTogetherLimits.maxPieceBytes` 90 MB -> 25 MB. Two planner tests rescaled (200 MB -> 60 MB
  sources) so they still test the duration rule, not the byte cap.
- Fix B (new PieceChunks.swift, MessengerPieceChannel.swift; transport only): second reliable messenger,
  `LTCK` 48-byte-header chunks of 192 KB (id, index, count, size, CRC-32, extension), `LTCC` JSON control
  frames (transportMode, chunksMissing, pieceGone) kept off `ListenTogetherMessage` so the protocol and
  the session service are unchanged for B (deviation from the report, which put the control messages in the
  Codable enum). Window 2 -> 3 after 10 clean sends, halved on a failed send, back-off 100/250/500 ms/1 s;
  more than 8 failures in a row fail the upload (session back-off as before). Listener writes into a
  pre-sized `.part` in the share folder, verifies size + CRC off main, renames `<id>.<ext>`, yields
  `.attachmentReceived`. Gaps: asked for 1 s after the last chunk is in (re-armed by every later chunk),
  and by the service's retry timer (stale after 5 s via `hasFailedPieceLoads`/`retryFailedPieceLoads`);
  checksum failure -> whole piece again; `reloadPiece` -> whole piece. Late joiners: the listener transport
  watches `pieceUploaded` and asks for unknown ids once in chunk mode (ids heard before the mode are kept and
  asked for on the switch); sharer answers `.only([participant])`. Sharer keeps the 3 latest pieces; older
  files are deleted (only inside the share folder) and reported `pieceGone`; `hasAttachment` false then, so
  the existing `needPiece` path re-exports. Switch per session (`TransportModeSwitch`): 2 consecutive
  non-interruption journal add failures (interruption = PieceRetryPolicy or app not active at start/end)
  or any error whose reflection names `notSupported` (the journal error type isn't public). The failing
  piece goes out as chunks in the same `upload` call. Sharer announces to all and to each later joiner.
- Item 3: `ListenTogetherErrorDescription.describe` (Swift enum: reflected case with paths redacted;
  BookSplitterError: case, index, preset; others: type name; plus domain, code, underlying domain/code) is
  public on export/upload/load/store/chunk failure lines. Deviation: no String(reflecting:) for NSError /
  CocoaError / structs, whose reflection prints user info with file paths and book titles.
- Item 4: protocol gains `end()` (default = `leave()`); GroupSessionTransport.end() -> `session.end()`.
  Sharer End: `.sessionEnding`, 0.5 s pause, then `end()`, inside the existing 2 s limit. Listener End/Leave
  unchanged. `observeAppExit`: willTerminate, or the last `.windowApplication` scene disconnecting
  (`endsOnSceneDisconnect`) -> `endForAppExit`: sharer tears down silently and ends, listener leaves.
  New init parameter `notificationCenter` (test seam).
- Guide: fallback paragraph, End stops SharePlay for everyone, sharer closing the app, late joiners in
  fallback (known limitation).
- TDD: tests first; red = compile failure (missing types). Behaviour red with A/B/item-4 fixes reverted
  (FileRepresentation, leave instead of end, app exit no-op, 90 MB, no notSupported switch, no window
  halving): 5 classes 69 tests, 23 failures in 11 tests. Green: 28 SharePlay classes 457/0.
- Full run 1: 1029 tests, 2 failures, both in my new gap test: a chunk landing after the last chunk
  stopped the gap check for good (real bug). Fixed: the check is re-armed by every chunk once the last is
  in; new test `testAGapIsAskedForOnceEvenWhenTheLastChunkCameFirst`; the fake network's gap wait now takes
  100 ms real time (it reorders deliveries). Channel tests 5/5 runs green.
- Full run 2: "Executed 1030 tests, with 0 failures", ** TEST EXECUTE SUCCEEDED **.
- TSan, 28 SharePlay classes: "Executed 458 tests, with 0 failures", 0 ThreadSanitizer warnings.

## 2026-10-11 - listen-together-transfer-fix - fix round 1
Parent 41efa526. Inputs: transfer-fix-review.md (3 Critical, 3 Important, 9 Minor), transfer-fix-round-1.md.
- Correction to the transfer fix entry above: the scene-disconnect trigger it describes
  (`UIScene.didDisconnectNotification`, `endsOnSceneDisconnect`) is removed (C3, controller ruling). iOS
  can disconnect a background scene that keeps playing; only `willTerminate` ends or leaves now. The test
  is replaced by `testASceneDisconnectingDoesNotEndTheSession`.
- C1: `ChunkFrame.decode` rejects totals above `ListenTogetherLimits.maxChunkedPieceBytes` (100 MB) before
  any count math; `chunkCount` uses quotientAndRemainder (no overflow); `ChunkReassembler` refuses frames
  over the cap or with an inconsistent count. Hostile-frame tests (Int64.max, UInt64.max, over the cap,
  UInt32.max count, count mismatch, offset past the end, wrong payload length, non-ASCII extension,
  truncated header).
- C2: new `ChunkControl.journalUnusable`. A listener sends it after a `notSupported` load failure or 2
  real load failures in a row; the sharer switches (or stays) in chunks, announces the mode again and from
  then on reports journal pieces gone (`hasAttachment` false). On that announcement the listener sends
  `needPiece` for every announced piece not received, in announcement order, and stops retrying journal
  loads; `listenerNeeds` then re-exports them as chunks.
- I1: chunks are taken only from the sharer once known (from manifest/pieceUploaded/heartbeat); at most 4
  pieces assemble at once (a stale one makes room; otherwise the new one waits for the retry timer).
- I2: `TransportModeSwitch.isJournalRejection` (notSupported, or a GroupActivities / GroupSession error
  domain) counts whatever the app state; other errors count only while active; cancellations never.
- I3: new `ListenTogetherTransferCoordinator` holds every mode decision (upload switch, announcements,
  late joiners, listener adoption and replay, C2, hasAttachment, reload routing); `GroupSessionTransport`
  only wires SharePlay to it. 13 coordinator tests with a sharer and a listener on the fake chunk network.
- Minors fixed: (1) protocol `stopPieceTransfers()` (default no-op), called before teardown on End and on
  termination; (2) splitter limit `maxExportedPieceBytes` = 30 MB; (3) chunk writes and the final fsync on a
  serial queue (`ChunkFileWriter`), sharer chunk reads in detached tasks; (7) End tests assert the order
  stopPieceTransfers -> send:sessionEnding -> end; (8) enum errors log type and case name only; (9)
  transport and coordinator tasks forget themselves. The window test's fake network now takes 5 ms per
  send (reads are awaited now, so instant sends never overlap).
- Minors left: (4) `pieceUploaded` overtaking the chunks makes that listener ask for the piece once more
  (sent `.only` to it; bounded to one piece; a delay would slow late joiners); (5) a piece whose chunk
  upload fails for good is re-sent under a new id (rare; listeners' partial files are dropped by
  `pieceGone`/teardown); (6) a journal import whose load throws after the importer ran stays in
  `incoming/` until launch cleanup (the URL is not returned to us).
- TDD red with the round-1 fixes reverted: 5 classes, 79 tests, 24 failures in 14 tests (C3 is a removal:
  its test passes either way). Green: 29 SharePlay classes 481/0; full suite 1053/0.
- Verification: full suite "Executed 1053 tests, with 0 failures", ** TEST SUCCEEDED **; TSan on 29 SharePlay classes 481/0, 0 ThreadSanitizer warnings.

## 2026-10-11 - listen-together-transfer-fix - fix round 2
Parent f4d9cad4. Inputs: transfer-fix-rereview-1.md (ready to merge; 5 new Minors).
- N1: after its own `journalUnusable` report, the listener asks again (`needPiece`) on every explicit
  chunk-mode announcement while announced pieces are still missing, not once: the sharer's own add-failure
  switch can announce before it has read the report, and those first `needPiece`s only bring map entries
  back. "Missing" is per piece index (a piece sent again under a new chunk id counts once it is here or
  arriving). Tests: the crossing order (report held in transit, the sharer switches through add, then the
  report arrives -> 4,5,4,5), and a re-exported piece that arrived is not asked for again.
- N2: the coordinator has a `stopped` flag: `track` starts nothing after `stop()`, and a load failure after
  stop reports nothing.
- N3: test with two listeners where only one fails (the other adopts chunks, asks for nothing, keeps the
  journal).
- Minor 6: `ShareStorage.removeIncoming()` empties `incoming/` at every teardown (and launch as before).
- N5: context.md protocol line corrected (B added `end()` and `stopPieceTransfers()`); guide line moved
  to the transfer-fix section; guide fallback paragraph now says the switch can come from a listener's
  iPhone too, and that listeners may simply wait a little longer.
- N4 (sharer accepts chunk frames / implicit mode hints from anyone) not in this round's list; left.
- TDD red with the round-2 fixes reverted: coordinator + session-end classes 3 failures (incoming, after-stop
  x2); the crossing test then lacked a count assertion and passed by timing out, so it was tightened to the
  full message list and failed (1 failure) with the one-shot code. Green: 29 SharePlay classes 487/0.
- Full run 1: 892 tests, 0 failures but ** TEST FAILED **: InsertBooksTests.testInsertEmptyBooksIntoPlaylist
  crashed (known CoreData flake, restarted); rerun below.
- Full run 2: "Executed 1059 tests, with 0 failures", ** TEST SUCCEEDED **. TSan, 29 SharePlay classes: 487/0, 0 ThreadSanitizer warnings.

## 2026-10-11 — transfer fix merged, pushed, TestFlight build 5.22.2 (3)
- `develop` fast-forwarded to 4f589c33 (transfer fix 41efa526, f4d9cad4, 4f589c33) and pushed (Becky approved).
- TestFlight 5.22.2 (3) archived from 4f589c33 in a temporary worktree (same overrides as builds 1-2, CURRENT_PROJECT_VERSION=3),
  exported and uploaded (internal only): "Upload succeeded". Worktree, archive and export deleted.
- Device test to do: both phones on build 3; sharer's phone on a Mac to read "journal upload failed: … rejection=" and transport-mode lines.
- 2026-10-11 device result (Becky): build 5.22.2 (3) WORKS on a FaceTime call — audio arrives and plays in sync. Not yet known which path (journal Data vs chunk fallback); Messages start, locked phones, End/session end still to test.

## 2026-10-11 - listen-together-start-position - start-position fix (build 4)
Parent 77c3037c (develop). Field result on build 3: audio arrives and plays (FaceTime and Messages), but the
session started at 0:00 and Michael's own saved place in the book became 0:00. Root cause:
started-over-investigation.md (the sharer's `transitionToItem` proposal was made before
`coordinateWithSession`; the listener's nil proposal is "paused at 0"; the listener's Play then made 0 the
group's state; the sharer obeyed `play at 0` with `jumpTo(0)`, and `PlayerManager.jumpTo` always saves the
time as progress). Brief: start-position-brief.md. Report: start-position-report.md.
- A: `ListenTogetherCoordinatorBridge.start(session:)` replaces `coordinate(with:)`: connect the coordinator,
  then `transitionToItem` (Apple's sample order); nothing is proposed in `init`; runs once.
- B: sharer `assertPosition()` = `coordinateSeek(to: bookTime)` (+ rate change if playing) right after the
  transition, and from `resendForLateJoiners` (roster/count growth, state requests) while the sharer target
  is not yet `isGroupEstablished`. Start place = `groupPosition(for: item)`.
- C: listener bridge `hasGroupTiming` false until its first play/pause/seek command (any matching command;
  buffering doesn't count). `ListenerPlayer.isJoiningGroup` holds userTogglePlay/userJump/userSkip/
  userSetRate (so buttons, lock screen, AirPods, Magic Tap, rotor) and calls `onActionWhileJoining` ->
  "Joining…" announced, `joiningToggleLimiter` 3 s (same as the waiting message). Bridge also drops
  listener reports before timing. Visible: `isListenerJoining` -> `statusConditions.isJoiningGroup` ->
  status line "Joining…" (hourglass; percent as detail while downloading) and `waitingCaption` (caption
  under the controls + Play button value). Reset in tearDown.
- D: `SharerPlaybackTarget(playerManager:sharedItemUUID:startPosition:)`. `bookTime` = player time while it
  holds the shared book, else the start place. Before `isGroupEstablished` (a group play/seek within 2 s of
  the sharer's own place), other play/seek times are not applied: no `jumpTo`, play/pause in place, and
  `LocalPlaybackEvent.reasserted(at:)` -> bridge `coordinateSeek` on the next main-queue turn (after the
  command's completion handler). Pauses never establish or jump before then. Another book is never jumped
  or played (`play()` skipped when the player holds a different book). Group seeks within 0.5 s of the
  sharer's place no longer jump (avoids re-saving and a stutter on the echo of its own seek). Backstop in
  `stop()`: unconfirmed, no local seek reported, shared book more than 2 s before the start -> `jumpTo(start,
  recordBookmark: false)`. `remoteAction(.reasserted)` = nil (never a message).
- E: comments say nil timing = "paused at zero"; listener test renamed testListenerProposesPausedAtZero.
- Strings: `listen_together_joining` = "Joining…" in Base and all 25 other lproj (English).
- Guide: Share step 10 (starts at your saved place, never moved back, kept if it ends early); Join step 7
  ("Joining…" visible + spoken, controls do nothing until in step); Messages list includes joining.
- Tests: new ListenTogetherStartPositionTests (21). Existing tests that drive a listener's own actions now
  first deliver a coordinator command (`bridge.handlePause(itemTime: 0)`), and the bridge tests call
  `start(session: nil)` before checking transitions.
- TDD red: compile red first (new API), then with API stubs only: 21 tests, 19 failed (the 2 passing are
  guards for behaviour that already held: deliberate jumps after confirmation, no restore after listening
  on). Green: 30 SharePlay classes 508/0 (** TEST SUCCEEDED **); full suite "Executed 1080 tests, with 0
  failures", ** TEST SUCCEEDED **; TSan on the 30 SharePlay classes 508/0, 0 ThreadSanitizer warnings
  (xcodebuild hung after the results and was killed, as usual).
- Not done / open: no fallback if a listener never receives a coordinator command (it would stay on
  "Joining…"); Apple's behaviour for the explicit seek before anyone joined and for late joiners is
  inferred, to be checked on devices (context.md item S).
