# Listen Together: User Guide

Listen Together lets you listen to an audiobook with other people, at the same time and in sync. You can start it from Messages, with no call needed, or on a FaceTime call. Only the person sharing needs the book. Everyone else hears it without having their own copy.

## Listening only: nobody gets a copy

Listen Together is for listening together, at the same time. It is not a way to give anyone a copy of a book.

- People who join can hear the book **only while the session is happening**.
- The book is never added to their library, and they cannot save, export, or keep it.
- When the session ends, the part of the book on their iPhone is deleted. If BookPlayer closes unexpectedly, it is deleted the next time BookPlayer opens.
- To listen again later, they need to join another session, or get the book themselves.

## Before you start: books you can and cannot share

**You can share an audiobook only if the whole book is saved on your iPhone.**

You can share:

- Books you imported from the Files app, AirDrop, or the share sheet.
- Single-file audiobooks, such as `.m4b` and `.m4a` files.
- Audiobooks made of several files, such as a folder of MP3 chapters.
- Books from a server (AudiobookShelf or Jellyfin) or from BookPlayer cloud sync **after you have downloaded them** to your iPhone.

You cannot share, in this version:

- **Books you stream.** If a book plays from AudiobookShelf, Jellyfin, or BookPlayer cloud sync without being downloaded, it is streamed. A streamed book is not saved on your iPhone, so there is nothing to send. **Download the book first, then share it.**
- Video files.

If a book cannot be shared, the Listen Together option does not appear in that book's More menu.

## Two ways to start

- **From Messages (no call needed).** If you are not on a FaceTime call, choosing Listen Together opens Apple's sharing sheet. Choose the people, then send the invitation in Messages. You can talk on another app, such as Discord, while you listen. Discord cannot carry SharePlay itself, but it can run alongside a session started from Messages.
- **On a FaceTime call.** If you are already on a FaceTime call, the invitation goes to everyone on the call. You can also choose FaceTime in the sharing sheet.

## Important for VoiceOver users: Magic Tap on a FaceTime call

**If your Listen Together session is on a FaceTime call, do not use Magic Tap.** During a FaceTime call, Magic Tap (two-finger double tap) ends the call, and Listen Together ends with it. iPhone handles this before BookPlayer can, so BookPlayer cannot change it. Use the **Play** or **Pause** button on the screen instead.

If you are not on a FaceTime call, for example you started from Messages, Magic Tap plays and pauses the shared book. To check, ask yourself: am I on a FaceTime call right now? A Discord voice channel is not a FaceTime call. Whether Discord itself reacts to Magic Tap is still being checked, so on a Discord call use the Play or Pause button until that is confirmed.

## What you need

- iPhone with iOS 18 or later, for everyone taking part.
- BookPlayer with Listen Together, for everyone taking part.
- Either Messages (or a contact you can reach through Apple's sharing sheet), or a FaceTime call with the people you want to listen with.

People listening do not need their own copy of the book.

## Share a book

1. Open BookPlayer and open the book you want to share.
2. In the player, choose **More**, then **Listen Together**.
3. The first time you share on this iPhone, a note says "People who join can only listen. They do not get a copy of the book. What they download is deleted when the session ends." Choose **Share** to continue. Choose **Cancel**, or use the two-finger scrub, to stop without sharing; the note then appears again next time. After you choose Share, the note is not shown again on that iPhone.
4. If you are not on a FaceTime call, Apple's sharing sheet opens. Choose the people, then send the invitation in Messages. To stop without sharing, choose **Cancel** in the sheet or use the two-finger scrub; VoiceOver then says "Listen Together was not started". If you are on a FaceTime call, there is no sheet: the invitation goes to everyone on the call.
5. BookPlayer prepares the book. You hear "Preparing" while this happens.
6. A status line appears near the top of the player. With VoiceOver it reads, for example, "Listen Together, 2 people, sharing". If you close the player, a **Listen Together** row stays above the tab bar. Choose it to return to the player.
7. Wait until someone has joined and you hear the book playing before you lock the phone.

If the sharing sheet cannot be opened, BookPlayer says "Couldn't open sharing" and suggests starting a FaceTime call instead.

## Join a book someone is sharing

1. If the invitation came in Messages, open it there. BookPlayer opens. If you are on a FaceTime call with the person sharing, the invitation reaches you without Messages.
2. VoiceOver says, for example, "Listen Together invitation: Moby Dick by Herman Melville".
3. An invitation appears on top of whatever screen you are on. The book title is the heading.
4. The invitation says: "You can only listen. The book is not saved on your device."
5. Choose **Join** to listen, or **Not Now** to decline.
6. After you join, you hear "Getting the book" while the first part of the book downloads. This usually takes less than a minute.
7. Playback starts in sync with everyone else.
8. To leave the Listen Together screen without ending it, use the two-finger scrub. You go back to your library and the book keeps playing for everyone. A **Listen Together** row stays just above the tab bar. VoiceOver reads it, for example, as "Listen Together, playing, Moby Dick". Choose it to come back to the player.

Your own book is paused when you join. While you listen together your own mini player is hidden, so you cannot start your own book by accident.

## During the session

Closing the Listen Together screen does not end the session. Use the two-finger scrub to close it and the **Listen Together** row to open it again.

While you listen together, BookPlayer hides your own mini player. If you start your own book, pause it from the lock screen or Control Center.

Anyone can control playback, and it changes for everyone:

- Play and pause, with the Play or Pause button on the screen. On a FaceTime call, do not use Magic Tap. Otherwise Magic Tap plays and pauses.
- Skip back or forward 30 seconds.
- Move through the book with the position control. Swipe up or down to move 30 seconds.
- Choose a chapter.
- Change the speed.

When someone else does one of these things, VoiceOver tells you, for example:

- "Another listener paused"
- "Another listener skipped forward 30 seconds"
- "Another listener moved to chapter Loomings"
- "Speed changed to 1.5 times by another listener"

Your own actions are not announced back to you.

If a listener's next part of the book has not finished downloading, everyone waits until it arrives. The listener hears "Waiting for the book to download". Download progress is announced at 25, 50, 75 and 100 percent.

## With the screen locked

While you are listening to someone else's book, the lock screen, Control Center, AirPods and headset buttons control the shared book, and the book changes for everyone:

- **Play** and **Pause** play and pause the shared book.
- **Skip forward** and **Skip back** move 30 seconds. VoiceOver reads them as 30 second skips, whatever your own skip setting is.
- **Next** and **Previous** (for example an AirPods double or triple press) also move 30 seconds forward or back. They do not change chapters.
- The **position control** moves through the whole book. The time VoiceOver reads is the time in the whole book, so it can be several hours.
- **Magic Tap** plays and pauses the shared book when you are not on a FaceTime call. On a FaceTime call it ends the call: see "Magic Tap on a FaceTime call". Before the book has arrived, Magic Tap says "Not available yet".

With the screen locked, you may not hear spoken messages about what other people did. This is still being checked. The sound and the lock screen show what happened.

The lock screen shows the shared book: the chapter title, then the book title and author, the time in the book and the whole book's length. It shows the book as paused while you wait for the next part of the book to download.

Before you lock the phone, wait until you hear the book playing.

If a call, Siri or another app (possibly Discord) interrupts the book on a listener's iPhone, the book pauses for everyone. It does not start again by itself: press Play on the lock screen.

If you start your own book during the session, the lock screen switches to your own book.

When the session ends, the lock screen, Control Center and AirPods control your own book again. Pressing Play then starts your own book.

## End the session

- Choose **End Listen Together** in the status line on the player. BookPlayer asks you to confirm. The two-finger scrub never ends Listen Together: it only closes the screen.
- The Listen Together row only opens the player; it cannot end the session.
- If the session is on a FaceTime call, ending the call ends the session.
- VoiceOver says "Listen Together ended".

## What happens to the shared book

The listeners' copy of the book is temporary. It is deleted when the session ends. If the app closes unexpectedly, it is deleted the next time BookPlayer opens. Nothing is added to the listeners' libraries.

## Known limitations

- **Streamed books cannot be shared.** Download them first. See "Before you start".
- Discord and other calling apps cannot carry SharePlay themselves. Start from Messages and talk on Discord alongside it.
- On a FaceTime call, Magic Tap ends the call instead of pausing. See "Magic Tap on a FaceTime call".
- After you send the invitation from the sharing sheet, BookPlayer waits a few seconds for the session to start. If it does not, you hear "Listen Together was not started"; choose Listen Together again.
- The sleep timer controls your own book, not the shared one.
- CarPlay: during a listener session the standard Now Playing play, pause and skip buttons reach the shared book, but CarPlay's chapter buttons still control your own book. Connecting CarPlay may switch the lock screen to your own book.
- If the person sharing leaves the call but the call continues, listeners may keep waiting. Ending the session or the call stops it for everyone.
- Speeds other than 0.75, 1, 1.25, 1.5, 1.75 and 2 times are not shown in the speed list.
