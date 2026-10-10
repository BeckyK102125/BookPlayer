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
