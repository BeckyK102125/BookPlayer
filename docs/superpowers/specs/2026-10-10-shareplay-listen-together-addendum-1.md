# Listen Together — Addendum 1 (approved by Becky, 2026-10-10)

Three follow-up changes to the approved design. Becky's use case: she and Michael talk in a Discord voice channel and want to listen to a book together **with both phones locked**, to save battery.

Accessibility findings that drove these changes:

- During a FaceTime call, VoiceOver's Magic Tap ends the call, and iOS handles this before any app can. A FaceTime-based session can therefore be ended by a VoiceOver user's habitual Magic Tap.
- Discord screen sharing stops when the screen locks. SharePlay sends no audio, only timing, so it keeps working with the screen locked.

## Change A — Streamed books: explain instead of hide

- **What changes:** books that are not fully saved on the iPhone now show **Listen Together** in the More menu. This covers books streamed from AudiobookShelf, Jellyfin or BookPlayer cloud. Video items still never show it.
- **What choosing it does:** shows a standard alert.
  - Title: "Download this book first" (`listen_together_streamed_title`).
  - Message: "This book is streamed, not saved on your iPhone. Download it, then choose Listen Together again." (`listen_together_streamed_message`).
  - One OK button.
- **What stays the same:** nothing else changes. Starting a session still requires `BookSplitter.isShareable`.
- **Tests:** the menu item is present for a streamed book, and choosing it shows the alert and never calls `startSharing`.

## Change B — Start from Messages (no FaceTime call needed)

- **On a FaceTime call** (`GroupStateObserver.isEligibleForGroupSession == true`): no change. The app uses `prepareForActivation()` and then `activate()`.
- **Not on a call:** present Apple's `GroupActivitySharingController` (GroupActivities, UIKit) for the `ListenTogetherActivity`. It replaces the "Start a FaceTime call first" alert. The sharer chooses people from Messages or contacts, or starts FaceTime from the sheet.
  - The controller is presented from the topmost view controller, using the same helper MainCoordinator already uses for invitations.
  - The share is recorded as pending, exactly as `startSharing` does today. The session then arrives through `ListenTogetherActivity.sessions()` as the device's own share, and the existing own-share path takes over.
  - If the person cancels the sheet, clear the pending share and return to `.idle`. Treat it like `end()` during `.preparing`: the share ID goes into `cancelledShareIDs`.
- **Listeners:** they receive the invitation in Messages. Opening it launches BookPlayer, and the existing invitation flow runs: an announcement plus the Join / Not Now screen.
- **Magic Tap:** in a Messages-started session there is no call, so Magic Tap plays and pauses through the existing R19 routing.
- **`.needsFaceTime`:** the state and its alert are kept only for the case where the sharing controller cannot be created. Otherwise they are no longer used.
- **Strings:** the guide and any on-screen wording describe both ways to start. The Magic Tap warning applies only to FaceTime.
- **Tests:** a pure decision function covers eligible (activate), not eligible (show the sharing controller), and controller unavailable (`needsFaceTime`). A second test covers cancelling the controller, which leaves the share cancelled.

## Change C — Lock screen, Control Center and AirPods control the shared book

Remote commands are wired once, in `AppDelegate.setupMPRemoteCommands()`. Do not add second targets; that is a CLAUDE.md invariant.

- **Routing in AppDelegate:** at the very start of each existing handler, ask a small router whether a Listen Together listener session is active. If it is, route the command and return `.success`. The commands covered are toggle play/pause, play, pause, skip forward, skip backward and change playback position.
  - The router is `ListenTogetherRemoteCommands`, `@MainActor`. It holds a weak reference to `SharePlaySessionService` and is set by MainCoordinator.
  - It routes to `listener.userTogglePlay()`, `userSkip(by:)`, `userJump(to:)` and so on, so commands are reported to the group like any other user action.
  - Skip intervals use the listener's fixed 30 seconds.
  - The sharer needs no routing: the sharer's session player is `PlayerManager`, so existing handlers already control it.
- **Now Playing:** while a listener session is active, `ListenerPlayer` (or a small helper beside it) publishes `MPNowPlayingInfoCenter` info. That is the shared book's title, author, chapter, elapsed time, duration and rate, updated on play, pause, seek, rate change and piece change.
- **When the session ends:** Now Playing is handed back to the user's own book. Use whatever PlayerManager already exposes, through the protocol, to re-publish its Now Playing info. If nothing exists, clear the info, and PlayerManager's next update restores it. Do not modify `PlayerManager.swift`.
- **The sharer's own book while listening:** it stays paused, as already happens on Join.
- **Tests:**
  - The router routes each command to the listener only during a listener session, and returns "not handled" otherwise.
  - The Now Playing dictionary is built from the listener's state. Use a pure builder function for this.

## Device checks added

These are added to the two-device list in context.md:

- Discord voice channel plus a Messages-started session, with both phones locked:
  - playback continues and stays in sync;
  - long pauses (5 minutes or more) with both phones locked, then resume from the lock screen;
  - Discord voice and BookPlayer audio play together without interrupting each other. Start Speaking had a Discord audio-session conflict before, so watch for it.
- AirPods double-tap, the lock-screen controls and Control Center on a listener control the shared book. After the session ends they control the user's own book again.
- During a FaceTime-based session, confirm that the guide's Magic Tap warning matches what actually happens.
