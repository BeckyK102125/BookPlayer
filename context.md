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
- Head: Task 10 fix round 1 ("this commit"), parent fb25638b. Clean after it.
- Local only, not committed: BuildConfiguration/Debug.xcconfig (gitignored).

## Done so far
- Tasks 0-9: capability, models, splitter, planner, timeline, sharer target, listener player,
  coordinator bridge, session service, transport and announcements (see Notes.md).
- Task 10: accessible UI (More-menu item, banner, invitation sheet, listener screen) and wiring in
  MainCoordinator/MainView. Views live in BookPlayer/SharePlay/Views/.

## Verification
- Full unit suite (Unit Tests plan, -only-testing:BookPlayerTests): 650 tests, 0 failures.
- App launches in the simulator to the library. SharePlay itself can't run in the simulator.
- Destination: iPhone 17 simulator by id 98A8CF98-8142-4710-AD5E-5419F782752C.
- Helper for registering new files: /private/tmp/bp-tools/add_to_xcodeproj.py (may be removed by the
  weekly cleanup; Notes.md records how to rebuild it).

## Device and assistive-technology acceptance
- Not started. Needs two real devices on FaceTime with VoiceOver: run the device checklist in
  .superpowers/sdd/2026-10-10-shareplay-listen-together/task-10-a11y-guidance.md section 7.

## Open problems / known limitations
- Lock-screen and AirPods play/pause still control the library player during a listener session (R26).
- Magic Tap while the speed menu is open may not reach the listener (system menu).
- The ended banner is visible 3 s; the announcement carries the message.
- While sharing, closing the player hides the status and End (a11y review M-1, follow-up).
- Invitation over other screens and Join dismissing them need device verification.

## Next steps
1. Controller review of Task 10, then any remaining plan tasks.
2. Two-device VoiceOver test.

## Decisions waiting on Becky
- Keep the End confirmation dialog (sharing/listening)? Implemented; easy to remove.
- Push the branch to GitHub: not yet.
- Signing team and bundle ID for device testing (group-session capability on the App ID).
