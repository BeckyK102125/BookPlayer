# Listen Together — Addendum 3: reliable sending, visible messages, spoken errors (approved by Becky, 2026-10-11)

## Why

Field test on TestFlight 5.22.2 (1), 2026-10-11, started from Messages, Michael sharing, Becky listening:
- The listener waited on "Getting the book" with no progress, the player appeared, Play was pressed, and about 0.4 s later the
  sharer's phone sent "session ending" and the session closed for everyone. The same happened with the roles swapped.
- Device log (listener): join 00:55:58, manifest 00:56:00, Play 00:56:05.53 → stall suspension (no piece yet) → 00:56:05.92 a
  messenger record from the sharer → immediate teardown. The only senders of "session ending" are the sharer's End and
  `failSharing` (three failed export/upload attempts of one piece). The sharer's exact error is not yet captured.
- Michael has low vision, uses Zoom, and usually has VoiceOver off. Failure reasons were VoiceOver announcements only, so he
  saw nothing.

## Decisions

1. **Small pieces.** Target about 10 to 15 minutes of audio per piece (hard cap still under 90 MB). Cut at chapter starts
   where possible: group short chapters into one piece up to the target; split long chapters (or books without chapters) into
   parts of about the target length. Pieces are invisible to users; chapters still come from the manifest.
2. **Send ahead.** The sharer sends the piece at the group's position first, then keeps two or three pieces ahead of the
   group's current position, then fills in the rest. A seek far ahead re-prioritises the piece there.
3. **Quick start.** The listener can play as soon as the piece at the current position has arrived. Progress is reported per
   piece, so with small pieces the percentage moves.
4. **Seamless joins.** The listener queues the next piece before the current one ends (AVQueuePlayer or equivalent), so
   playback continues across piece boundaries without an audible gap.
5. **Never end on a piece failure.** A failed export or upload is retried with back-off (and again when the app becomes active)
   without ending the session. Listeners that need that piece wait together ("Waiting for the book") until it arrives. Only
   the sharer's End, or the sharer leaving (8), ends the session. App interruptions do not count as failures.
6. **The sharer stays awake while sending.** During a sharing session with pieces still to send: idle timer disabled while
   BookPlayer is in front, and each export/upload wrapped in a background task, ended on every path.
7. **Visible messages (R41).** Every important message is shown as well as spoken. Failures and endings: a centred alert with a
   plain sentence and OK, which stays until dismissed (never a timed toast). Ongoing status (waiting, getting the book N
   percent, joined/left): persistent text in the status area next to the controls. Works with Zoom, Dynamic Type and 4.5:1
   contrast in every theme. VoiceOver users still hear each message exactly once.
8. **Setting: "Speak error messages"** (Settings → Listen Together), off by default. When on and VoiceOver is not running,
   errors and session endings are spoken with AVSpeechSynthesizer using the person's Spoken Content voice and rate
   (`prefersAssistiveTechnologySettings`). Apple does not expose Siri voices to apps directly; whether a Siri voice chosen in
   Spoken Content is used must be checked on device. Silent while VoiceOver runs (no duplicates). Works while locked; the book
   ducks for the sentence and does not pause.
9. **The sharer leaving.**
   - The sharer's End ends for everyone: "The person sharing ended Listen Together."
   - The sharer missing from the session (no longer an active participant, or no messages): listeners pause together and show
     and say "Waiting for the person sharing". If the sharer is back within 60 seconds, playback continues.
   - Not back after 60 s: the session ends for everyone with "The person sharing left. Listen Together ended." The temporary
     copy is deleted as usual.
10. **Leave button** per leave-button-a11y-guidance.md (listener "Leave Listen Together", sharer while preparing "Cancel
    Sharing"), and the R40 fixes to existing Listen Together buttons.
11. **Diagnostics.** Log the underlying AVFoundation/journal error for every failed piece, the export preset and output size,
    app state changes, and coordinator stall begin/end, so the next device test shows the cause.

## Standing rules (unchanged)

The two-finger scrub is always cancel/back only. End asks once, then ends. AirPods next/previous are ±30 s. PlayerManager.swift
and Shared/ are not modified. Strings go in Base and every lproj.

## Out of scope

Listeners keeping pieces after the session; streaming from a server; changing the "only while the session runs" rule.
