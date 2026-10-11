# Listen Together — Addendum 2: "Both have the book" (approved by Becky, 2026-10-10)

## Goal

When a listener already has the shared book in their own BookPlayer library, their phone plays its own copy. Nothing is downloaded, and playback stays in sync. The sharer can also choose to listen only with people who own the book. This is the Apple-style mode: every listener has their own right to listen, and no copy is sent.

## Decisions

- **Matching is automatic.** If a listener's library has a matching book, their phone uses it without asking. The invitation and the getting-ready status say "using your copy".
- **New sharer setting:** Settings → Listen Together, "When someone doesn't have the book". It has two choices:
  - **Send it for this session** (default in this fork). This is the current behaviour: a temporary copy, deleted afterwards.
  - **Only people who have the book can join.** A listener without a match hears a short message and the invitation is declined. Nothing is sent. When this feature is offered upstream to TortugaPower, this is proposed as the default.
- **Owners still get their own copy when sending is on.** With "Send it for this session" selected, listeners who own the book still use their own copy. Only listeners without it receive pieces.
- **The user's own place is untouched.** A listener's progress, bookmarks and "last played" for their own copy are NOT changed by a Listen Together session. The session uses its own playback position.

## Book fingerprint (in the manifest)

The manifest records the following:

- Title and author, normalised: case-folded, with whitespace and punctuation trimmed.
- Total duration, in seconds.
- File layout: the number of audio files, and each file's duration and byte size.
- An audio sample hash: SHA-256 of the first 64 KB of audio data in the first file, read directly from the file. The audio is not decoded.

A listener's book matches when all of these hold:

- The total duration is within ±2 s.
- The file count is equal.
- Every file's duration is within ±2 s, **and**
  - either the sample hash matches,
  - or (title AND author match) AND every byte size is within ±1 %.

These rules avoid false matches between different editions or recordings. If more than one library item matches, the most recently played one is used.

## Playback with your own copy

The listener plays their own files through the existing `ListenerPlayer`, as if each own file were a piece that had already arrived. The pieces are built from the listener's file layout, mapped onto the shared book-time timeline. The coordinator, remote commands, Now Playing, row, escape and End behave exactly as they do today.

## Accessibility

Accessibility guidance comes before the build, following the established pattern. The open points it covers:

- the wording of the "using your copy" and "you need your own copy" messages;
- how the setting is presented;
- that announcements are not duplicated.

## Out of scope

- Matching books streamed from servers.
- Matching across different editions or recordings.
- Merging the session's position back into the listener's own progress.
