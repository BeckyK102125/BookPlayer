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
