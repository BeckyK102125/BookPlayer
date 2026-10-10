# context.md - current snapshot

Date: 2026-10-10

## Goal
Add SharePlay "Listen Together" to Becky's fork of BookPlayer. Spec:
docs/superpowers/specs/2026-10-10-shareplay-listen-together-design.md. Plan:
docs/superpowers/plans/ (the SharePlay Listen Together implementation plan).

## Repos and branches
- origin: github.com/BeckyK102125/BookPlayer (Becky's fork). Nothing pushed yet.
- upstream: github.com/TortugaPower/BookPlayer.
- Branch `shareplay-listen-together`, started from upstream `develop` at eb19a92f. Only worktree.
- Working tree is clean after the Task 0 commit ("this commit").
- Local only, not committed: BuildConfiguration/Debug.xcconfig (copied from the template; gitignored).

## Done so far
- Spec and plan committed (906acbf7, 95eda2e0).
- Task 0: Group Activities capability added (com.apple.developer.group-session in both
  entitlements files, NSSupportsGroupActivities in Info.plist). Project notes created.
- Helper for registering new files in the Xcode project exists outside the repo at
  /private/tmp/bp-tools/add_to_xcodeproj.py (see Notes.md for usage). The weekly cleanup job may
  remove /private/tmp after 3 days; Notes.md records how to rebuild it.

## Verification
- Baseline on the untouched code plus the Task 0 plist changes:
  build-for-testing: TEST BUILD SUCCEEDED.
  test-without-building: Executed 572 tests, with 0 failures. No pre-existing failures.
- Destination must be the iPhone 17 simulator by id (98A8CF98-8142-4710-AD5E-5419F782752C, iOS 26.5).
  `name=iPhone 17` alone fails on this Mac because the latest simulator runtime is iOS 27.0 and has
  no iPhone 17.
- Xcode 27.0 (27A266a) here; CI uses Xcode 26.4.

## Device and assistive-technology acceptance
- Not started. SharePlay needs two real devices on FaceTime; the simulator cannot test it.

## Open problems
- None.

## Next steps
1. Task 1 of the plan.
2. Every new Swift file must be registered with the helper (the project uses classic groups).

## Decisions waiting on Becky
- Push the branch to GitHub: not yet.
- Signing team and bundle ID for device testing (the group-session capability must be enabled on
  the App ID in the developer portal).
