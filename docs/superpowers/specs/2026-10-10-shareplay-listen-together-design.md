# SharePlay "Listen Together" — Design

Date: 2026-10-10. Branch: `shareplay-listen-together` (fork BeckyK102125/BookPlayer, from upstream `develop` at eb19a92f).

## Goal

People on a FaceTime call listen to an audiobook together. The person sharing has the book. The
listeners do not need their own copy: the sharer's app sends it to them over SharePlay. Playback
(play, pause, seek, chapter, speed) stays in sync for everyone, and anyone can control it. A
listener's copy is temporary and is deleted when the session ends.

**Success:** Becky shares a book from her iPhone on a FaceTime call. Someone without the book hears
it within about a minute, in sync. A pause or skip on either phone follows on both. When the call
ends, the listener's copy is gone. Every part of it works with VoiceOver.

## Decisions already made with Becky

| Topic | Decision |
|---|---|
| Purpose | Listen together, for real use (not just a test bed) |
| Book source | Sharer sends the audio; listener needs no copy |
| Listener's copy | Deleted when the session ends. (The option also said "their place is saved". Playback always follows the shared session's position, so a saved listener position would never be used; it is left out unless Becky wants it.) |
| Controls | Everyone can pause, play, seek, change chapter and change speed |
| Sync approach | Apple's coordinator for timing, plus our own messages for everything else |
| Fork owner | BeckyK102125 (personal), public, GPL v3 like the original |

## Platform facts this design depends on

- The deployment target is already iOS 18, so `GroupSessionJournal` (iOS 17) is available everywhere.
- Each journal attachment is limited to **100 MB** (WWDC23 session 10241). Books are sent in pieces.
- `GroupSession` participants are anonymous. The app cannot learn the other person's name.
- SharePlay needs the `com.apple.developer.group-session` entitlement and `NSSupportsGroupActivities`
  in Info.plist. Real testing needs two devices on a FaceTime call; the simulator cannot join SharePlay.

## Key finding: why the delegating coordinator

`PlayerManager` plays **one file at a time**. A single-file `.m4b` is one `AVPlayerItem`; a multi-file
book swaps `AVPlayerItem`s as chapters change, and "book time" is worked out from chapter offsets.
The listener will hold different files (pieces), so the two `AVPlayer`s will never have matching
items. Apple's built-in `AVPlayer.playbackCoordinator` needs matching items, so it cannot be used.

Instead, both sides use **`AVDelegatingPlaybackCoordinator`**, which syncs one abstract timeline that
we define: **book time in seconds** (the same number `PlayableItem.currentTime` already uses).
Apple still handles the hard parts (agreeing on play and pause, the start time, waiting for everyone
to be ready). Our delegate converts its commands into calls on each phone's own player.

- Sharer: commands go through `PlayerManagerProtocol` (`play`, `pause`, `jumpTo`, `setSpeed`).
  **`PlayerManager.swift` is not modified.** Its `CLAUDE.md` calls it the riskiest file in the app.
- Listener: a small dedicated player plays the received pieces on the same book-time timeline.

## Components

All new code goes in `BookPlayer/BookPlayer/SharePlay/` (app target only; nothing in `Shared/`, so the
Watch build is unaffected).

1. **`ListenTogetherActivity`** — the `GroupActivity`. Carries a share ID plus the book's title, author,
   duration and chapter list (titles and book-time ranges), so a listener can show the book before any
   audio arrives. Metadata title: "Listen to <book title>".
2. **`SharePlaySessionService`** (`@MainActor`, `ObservableObject`) — owns the `GroupSession`, the
   messenger and the journal. Publishes the session state for the UI: not active, preparing, sharing,
   listening, waiting for audio, ended. Starts the session (`activity.prepareForActivation()` then
   `activate()`), and listens for incoming sessions via `ListenTogetherActivity.sessions()`.
3. **`BookSplitter`** (sharer) — turns the book into pieces under 90 MB (margin under the 100 MB limit),
   cut on chapter boundaries where possible, using `AVAssetExportSession` with the passthrough preset (no
   re-encoding). Writes to a temporary folder. Each piece records its book-time start and length. Pieces
   are uploaded to the journal in playback order, starting with the piece containing the current position.
4. **`SharedBookAssembler`** (listener) — downloads pieces into a temporary folder, and builds an
   `AVMutableComposition` on the book-time timeline as pieces arrive. Reports which time ranges are ready.
5. **`ListenerPlayer`** (listener) — its own `AVPlayer` over the composition. Separate from
   `PlayerManager`, so a listener's library, progress and sync are never touched.
6. **`ListenTogetherCoordinatorBridge`** — the `AVDelegatingPlaybackCoordinator` delegate on both sides.
   Maps coordinator commands (play, pause, seek, buffering) to the sharer's `PlayerManagerProtocol` or the
   `ListenerPlayer`. Reports local actions back to the coordinator. Marks the listener as not ready
   (buffering) while the needed piece is still downloading, so everyone waits.
7. **Messages (`GroupSessionMessenger`)** — small Codable messages the coordinator does not carry:
   - `speedChanged(rate)` and `chapterJumped(title)` — so listeners can announce them;
   - `actionPerformed(kind)` — "paused", "resumed", "skipped forward 30 seconds", for announcements;
   - `pieceManifest` — the list of pieces and their book-time ranges.
8. **UI** — see Accessibility below.

## Data flow

1. Sharer opens a book, chooses **More → Listen Together**. The app checks a FaceTime call is active.
   If not, it explains how to start one (it does not try to start the call).
2. The session activates. The sharer's player keeps playing normally; the bridge attaches.
3. `BookSplitter` starts. The first piece is uploaded with the manifest.
4. Each listener's app receives the session, shows "Listen Together: <title>", and on Join downloads
   the first piece. The coordinator holds playback for everyone until the listener is ready.
5. Playback runs in sync. Any participant's play, pause, seek, chapter or speed change goes to the
   coordinator (timing) and the messenger (announcement).
6. When the sharer leaves or the session ends, listeners stop, are told "Listen Together ended", and the
   temporary folder is deleted. The sharer's temporary pieces are deleted too.

## Error handling

- **No FaceTime call:** clear message with the steps to start one; nothing else happens.
- **Book can't be split** (for example a streamed AudiobookShelf or Jellyfin book with no local file):
  Listen Together is unavailable for that book, with a reason given. Streaming books are out of scope for
  the first version.
- **Piece upload or download fails:** retry twice, then tell everyone "Couldn't send part of the book"
  and end the session cleanly.
- **Listener falls behind** (a piece isn't there yet at the play position): coordinator buffering state
  holds everyone; listener hears "Waiting for the book to download"; sharer hears "Waiting for a listener".
- **Headphones unplugged / audio route lost on any phone:** that phone pauses, which pauses everyone.
  (Upstream BookPlayer doesn't pause on route loss; this is handled inside the SharePlay layer only.)
- **Audio interruptions** (a call, Siri): treated like a local pause.
- **App sent to background on the listener's phone:** keeps playing (the app already has background audio).
- **Session ends unexpectedly** (crash, call dropped): temporary files are also cleaned at next launch.

## Accessibility

The player's "More" menu is the entry point. Specific requirements:

- **Button:** "Listen Together" in the More menu with a SharePlay icon; hidden on books that can't be
  shared, with no greyed-out mystery button.
- **Status banner** in the player while a session is active: a single accessibility element, for
  example "Listen Together, 2 people, sharing" or "Listen Together, waiting for the book, 40 percent".
  Includes an "End" button labelled "End Listen Together".
- **Announcements** (via `AccessibilityNotification.Announcement`, queued so they don't cut each other
  off or interrupt VoiceOver speech already in progress):
  - "Another listener paused", "Another listener resumed", "Another listener skipped forward 30 seconds",
    "Another listener moved to chapter <title>", "Speed changed to 1.5 times by another listener".
  - "Someone joined Listen Together", "Someone left", "Listen Together ended".
  - Download progress at 25 percent steps only, never every update.
  - Only remote actions are announced; your own actions are not echoed back.
- **Listener screen:** shows title, author, chapter, elapsed and remaining time, play/pause, skip back and
  forward, chapter list and speed. Uses the same labels and the adjustable (swipe up and down) behaviour
  as BookPlayer's existing player controls. One heading level 1 for the book title.
- **Magic Tap** plays and pauses on the listener screen, as it does in the main player.
- **Dynamic Type** throughout; no fixed font sizes. Status text never truncates.
- **Focus:** when a listener joins, VoiceOver focus moves to the book title on the listener screen.
  When the session ends, focus returns to where it was, with the "ended" announcement.
- **Reduce Motion** respected for any progress animation. Colour is never the only state indicator.
- Strings localized in English; other languages fall back to English until translated.

## Testing

- **Unit tests** (BookPlayerTests, Swift Testing where the target allows it):
  - `BookSplitter` piece planning: sizes under 90 MB, chapter-boundary cuts, single-file and multi-file
    books, a book smaller than one piece.
  - Book-time mapping for the sharer (book time ↔ chapter + file offset) and listener (composition).
  - Message encoding and decoding.
  - Bridge: coordinator commands become the right `PlayerManagerProtocol` calls (using the existing
    `PlayerManagerProtocolMock`).
  - Announcement text for each remote action, and that local actions produce none.
  - Temporary folder cleanup on end and on next launch.
- **Build:** the `BookPlayer` scheme builds for an iOS simulator with no new warnings.
- **Device acceptance (Becky, two devices on FaceTime, VoiceOver on):** share a single-file m4b, share a
  multi-file book, pause and seek from each side, change speed, end from each side, unplug headphones,
  join late, and confirm the listener's copy is deleted.

## Out of scope for this version

- Streamed books (AudiobookShelf, Jellyfin, BookPlayer cloud) as the shared book.
- Video files.
- Apple Watch, CarPlay and widgets during a session.
- Showing participants' names (SharePlay doesn't provide them).
- Saving a listener's position for a later session.
- Sending the feature upstream to TortugaPower (possible later as a pull request).

## Signing note

The fork uses Becky's Apple developer team. `Debug.xcconfig` is created from `Debug.template.xcconfig`
with her team and a bundle ID of her choosing; the Group Activities capability is enabled on that ID.
Signing details are not committed.
