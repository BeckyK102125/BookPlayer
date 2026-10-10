# Listen Together: User Guide

Listen Together lets you listen to an audiobook with other people on a FaceTime call, at the same time and in sync. Only the person sharing needs the book. Everyone else hears it without having their own copy.

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

## Important for VoiceOver users: do not use Magic Tap during the call

**During a FaceTime call, Magic Tap (two-finger double tap) ends the call.** Ending the call also ends Listen Together for everyone. iPhone handles this before BookPlayer can, so BookPlayer cannot change it.

To play or pause during Listen Together, use the **Play** or **Pause** button on the screen instead.

## What you need

- iPhone with iOS 18 or later, for everyone taking part.
- BookPlayer with Listen Together, for everyone taking part.
- A FaceTime call with the people you want to listen with.

People listening do not need their own copy of the book.

## Share a book

1. Start a FaceTime call with the people you want to listen with.
2. Open BookPlayer and open the book you want to share.
3. In the player, choose **More**, then **Listen Together**.
4. BookPlayer prepares the book and invites everyone on the call. You hear "Preparing" while this happens.
5. A status line appears near the top of the player. With VoiceOver it reads, for example, "Listen Together, 2 people, sharing".

If you are not on a FaceTime call, BookPlayer tells you to start one first. Nothing else happens.

## Join a book someone is sharing

1. When someone shares a book, VoiceOver says, for example, "Listen Together invitation: Moby Dick by Herman Melville".
2. An invitation appears on top of whatever screen you are on. The book title is the heading.
3. Choose **Join** to listen, or **Not Now** to decline.
4. After you join, you hear "Getting the book" while the first part of the book downloads. This usually takes less than a minute.
5. Playback starts in sync with everyone else.

Your own book is paused when you join.

The invitation also says: "You can listen only during this session. The book is not saved on your iPhone."

The first time you share a book, BookPlayer shows a short note: "People who join can listen only during the session. They don't get a copy." Choose **OK**. It is not shown again on that iPhone.

## During the session

Anyone can control playback, and it changes for everyone:

- Play and pause, with the Play or Pause button on the screen. Do not use Magic Tap during the FaceTime call: it ends the call.
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

While you are listening to someone else's book, the lock screen, Control Center, AirPods and headset buttons control the shared book, and everyone hears the change:

- **Play** and **Pause** play and pause the shared book.
- **Skip forward** and **Skip back** move 30 seconds. VoiceOver reads them as 30 second skips, whatever your own skip setting is.
- **Next** and **Previous** (for example an AirPods double or triple press) move to the next chapter, or back to the start of the chapter. Pressed again near the start of a chapter, Previous goes to the chapter before. If the book has no chapters, they move 30 seconds.
- The **position control** moves through the whole book. The time VoiceOver reads is the time in the whole book, so it can be several hours.

The lock screen shows the shared book: the chapter title, then the book title and author, the time in the book and the whole book's length. It shows the book as paused while you wait for the next part of the book to download.

Before you lock the phone, wait until you hear the book playing.

If you hear silence after a call or Siri interrupted the book, press Play on the lock screen.

When the session ends, the lock screen, Control Center and AirPods control your own book again. Pressing Play then starts your own book.

## End the session

- Choose **End Listen Together** in the status line. BookPlayer asks you to confirm.
- Ending the FaceTime call also ends the session.
- VoiceOver says "Listen Together ended".

## What happens to the shared book

The listeners' copy of the book is temporary. It is deleted when the session ends. If the app closes unexpectedly, it is deleted the next time BookPlayer opens. Nothing is added to the listeners' libraries.

## Known limitations

- **Streamed books cannot be shared.** Download them first. See "Before you start".
- Listen Together works during a FaceTime call. Starting it from Messages is not available yet. Discord and other calling apps cannot carry SharePlay.
- During the FaceTime call, Magic Tap ends the call instead of pausing. Use the Play or Pause button on the screen.
- The sleep timer and CarPlay control your own book, not the shared one.
- If the person sharing leaves the call but the call continues, listeners may keep waiting. Ending the session or the call stops it for everyone.
- Speeds other than 0.75, 1, 1.25, 1.5, 1.75 and 2 times are not shown in the speed list.
