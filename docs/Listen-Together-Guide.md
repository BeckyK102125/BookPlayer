# Listen Together: User Guide

Listen Together lets you listen to an audiobook with other people, at the same time and in sync. You can start it from Messages, with no call needed, or on a FaceTime call. Only the person sharing needs the book. People who already have the book play their own copy. Everyone else can get a temporary copy for the session, unless the person sharing chose to listen only with people who have the book.

## Listening only: nobody gets a copy

Listen Together is for listening together, at the same time. It is not a way to give anyone a copy of a book.

- People who join can hear the book **only while the session is happening**.
- The book is saved on their iPhone for this session only. It is never added to their library, and they cannot save, export, or keep it.
- When the session ends, what was downloaded is deleted. If BookPlayer closes unexpectedly, it is deleted the next time BookPlayer opens.
- To listen again later, they need to join another session, or get the book themselves.
- If you already have the book, nothing is downloaded. BookPlayer plays your copy, and your own place in the book, bookmarks and last played are not changed.

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

## Using your own copy

BookPlayer looks for the book in your library when you get an invitation. It matches by title and author, length and file layout, and checks the sound of the first file. If it finds it, the invitation says "You have this book, so BookPlayer plays your copy." If your copy is a different recording or edition, it will not match. Books streamed from a server do not match either: only books saved on your iPhone.

## When someone doesn't have the book

This is a setting for the person sharing: **Settings, Playback, Listen Together**, "When someone doesn't have the book". It applies to the next session you share. People who already have the book always play their own copy, whichever option you choose.

- **Send it for this session** (the default). People who don't have the book get a temporary copy. It is deleted when the session ends.
- **Only people who have the book can join.** Nothing is sent. People who don't have the book are told they need their own copy, and they cannot join.

## Two ways to start

- **From Messages (no call needed).** If you are not on a FaceTime call, choosing Listen Together opens the sharing screen from Apple. Choose the people, then send the invitation in Messages. Discord cannot start Listen Together, but you can talk on Discord while it plays. Magic Tap: should play and pause; on a Discord call, use the Play or Pause button until this is confirmed.
- **On a FaceTime call.** If you are already on a FaceTime call, the invitation goes to everyone on the call. You can also choose FaceTime on the sharing screen. Magic Tap: ends the call. Do not use it.

## Important for VoiceOver users: Magic Tap on a FaceTime call

**If your Listen Together session is on a FaceTime call, do not use Magic Tap.** During a FaceTime call, Magic Tap (two-finger double tap) ends the call, and Listen Together ends with it. iPhone handles this before BookPlayer can, so BookPlayer cannot change it. Use the **Play** or **Pause** button on the screen instead.

If you are not on a FaceTime call, for example you started from Messages, Magic Tap should play and pause the shared book. To check, ask yourself: am I on a FaceTime call right now? A Discord voice channel is not a FaceTime call. Whether Discord itself reacts to Magic Tap is still being checked, so on a Discord call use the Play or Pause button until that is confirmed.

## What you need

- iPhone with iOS 18 or later, for everyone taking part.
- BookPlayer with Listen Together, for everyone taking part.
- Either Messages (or another way to reach people on the sharing screen from Apple), or a FaceTime call with the people you want to listen with.

People listening do not need their own copy of the book, unless the person sharing chose "Only people who have the book can join".

## Share a book

1. Open BookPlayer and open the book you want to share.
2. In the player, choose **More**, then **Listen Together**.
3. The first time you share on this iPhone, a note says "People who join can only listen. If they don't have the book, it is saved on their device for this session only and deleted when it ends. It is never added to their library." If you chose "Only people who have the book can join", it says instead "People who join can only listen. Only people who already have this book can join. Nothing is sent." Choose **Share** to continue. Choose **Cancel**, or use the two-finger scrub, to stop without sharing; the note then appears again next time. After you choose Share, the note is not shown again on that iPhone.
4. If you are not on a FaceTime call, the sharing screen from Apple opens. Choose the people and send the invitation in Messages.
5. To stop, choose **Cancel** on the sharing screen or use the two-finger scrub. VoiceOver says "Listen Together was not started".
6. If you are on a FaceTime call, no sharing screen opens. iPhone asks you to confirm sharing with everyone on the call.
7. BookPlayer prepares the book. You may hear "Preparing" while this happens.
8. A status line appears near the top of the player. With VoiceOver it reads, for example, "Listen Together, 2 people, sharing". If you close the player, a **Listen Together** row stays above the tab bar. Choose it to return to the player.
9. When the session has started after the sharing screen, VoiceOver says "Listen Together started".
10. Wait until someone has joined and you hear the book playing before you lock the phone.

If the sharing screen cannot be opened, BookPlayer says "Couldn't open sharing" and suggests starting a FaceTime call instead.

If you chose "Only people who have the book can join", and someone does not have it, you hear "Someone couldn't join because they don't have the book." (once, even if several people couldn't join within a few seconds). They hear that they need their own copy. You do not see who. In this mode "Someone joined" is said a few seconds after someone joins, so that people who can't join are never announced as joining.

After you send the invitation, BookPlayer waits up to 20 seconds for Listen Together to start. If it has not started by then, VoiceOver says "Listen Together didn't start. Try again." and Listen Together is back in the More menu. If it starts a little later anyway, VoiceOver says "Listen Together started".

## Join a book someone is sharing

1. If the invitation came in Messages, open it there. BookPlayer opens. If you are on a FaceTime call with the person sharing, the invitation reaches you without Messages.
2. VoiceOver says, for example, "Listen Together invitation: Moby Dick by Herman Melville".
3. An invitation appears on top of whatever screen you are on. The book title is the heading.
4. The invitation says: "You can only listen. The book is saved on your iPhone for this session only and deleted when it ends."
   If you have the book, the message says instead that you have it and BookPlayer plays your copy. Nothing is downloaded, and after Join you go straight to the player and hear "Joined. Playing your copy."
   If the person sharing only listens with people who have the book and you don't, there is no invitation: you hear "You need your own copy", and the invitation is declined once that message is on screen. Choose OK (or use the two-finger scrub); either only closes the message. If BookPlayer isn't open at that moment, the message appears when you open it within a minute (and, only if you have already allowed BookPlayer notifications, a notification says so). After that, or if the person sharing has stopped, the message is dropped without being shown. If BookPlayer couldn't check your library in time, the message says "Couldn't check your library" instead: ask the person sharing to send the book.
5. Choose **Join** to listen, or **Not Now** to decline.
6. If you don't have the book: after you join, you hear "Getting the book" while the first part of the book downloads. This usually takes less than a minute.
7. Playback starts in sync with everyone else.
8. To leave the Listen Together screen without ending it, use the two-finger scrub. You go back to your library and the book keeps playing for everyone. A **Listen Together** row stays just above the tab bar. VoiceOver reads it, for example, as "Listen Together, playing, Moby Dick". Choose it to come back to the player.

If your copy was moved or deleted between the invitation and Join, BookPlayer gets the book from the person sharing instead (or, if they only listen with people who have the book, tells you "Your copy can't be used" and you don't join).

Your own book is paused when you join. While you listen together your own mini player is hidden, so you cannot start your own book by accident.

If the invitation cannot be shown straight away (for example BookPlayer is still opening from Messages), BookPlayer keeps trying for about 10 seconds. You hear the invitation announcement either way.

## During the session

Closing the Listen Together screen does not end the session. Use the two-finger scrub to close it and the **Listen Together** row to open it again.

While you listen together, BookPlayer hides your own mini player. If you choose one of your own books (for example by double-tapping it in your library), BookPlayer first asks "Leave Listen Together to play this book?":

- The question goes on: "You will leave Listen Together on this iPhone. The others keep listening."
- **Leave** ends Listen Together on your iPhone (the others keep listening), then plays your book. VoiceOver says, for example, "You left Listen Together. Playing Moby Dick." and lands on the book's title in the player.
- **Cancel**, or the two-finger scrub, keeps you in Listen Together. Your book does not play.

When you leave to play your own book, it starts from your own place in the book, which Listen Together did not change (also when you listened together with your own copy).

If BookPlayer cannot ask (for example Siri, a widget or CarPlay while the phone is locked), your own book does not start, and Listen Together carries on. You will hear "You're in Listen Together. Unlock to play your own book." when BookPlayer can speak. If you have already allowed notifications for BookPlayer, a notification also says "Your book did not start" (at most once every 30 seconds); BookPlayer never asks for notification permission for this. Two books never play at the same time.

Anyone can control playback, and it changes for everyone:

- Play and pause, with the Play or Pause button on the screen. On a FaceTime call, do not use Magic Tap. If you are not on a FaceTime call, Magic Tap should play and pause. On a Discord call, use the Play or Pause button until this is confirmed.
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

If you don't have the book: if a listener's next part of the book has not finished downloading, everyone waits until it arrives. The listener hears "Waiting for the book to download". Pressing Play or Pause on that iPhone while it waits does not stop the others; it says "Waiting for the book to download" again. Download progress is announced at 25, 50, 75 and 100 percent.

## With the screen locked

While you are listening to someone else's book, the lock screen, Control Center, AirPods and headset buttons control the shared book, and the book changes for everyone:

- **Play** and **Pause** play and pause the shared book.
- **Skip forward** and **Skip back** move 30 seconds. VoiceOver reads them as 30 second skips, whatever your own skip setting is.
- **Next** and **Previous** (for example an AirPods double or triple press) also move 30 seconds forward or back. They do not change chapters.
- The **position control** moves through the whole book. The time VoiceOver reads is the time in the whole book, so it can be several hours.
- **Magic Tap** should play and pause the shared book when you are not on a FaceTime call; on a Discord call, use the Play or Pause button until this is confirmed. On a FaceTime call it ends the call: see "Magic Tap on a FaceTime call". Before the book has arrived, Magic Tap says "Waiting for the book. Play is not available yet.", on the lock screen and in BookPlayer.

With the screen locked, you may not hear spoken messages about what other people did. This is still being checked. The sound and the lock screen show what happened.

The lock screen shows the shared book: the chapter title, then the book title and author, the time in the book and the whole book's length. It shows the book as paused while you wait for the next part of the book to download.

Before you lock the phone, wait until you hear the book playing. With your own copy this is quick.

If a call, Siri or another app (possibly Discord) interrupts the book on a listener's iPhone, the book pauses for everyone. It does not start again by itself: press Play on the lock screen.

When the session ends, the lock screen, Control Center and AirPods control your own book again. Pressing Play then starts your own book.

## End the session

- Choose **End Listen Together** in the status line on the player. BookPlayer asks you to confirm. The two-finger scrub never ends Listen Together: it only closes the screen.
- The Listen Together row only opens the player; it cannot end the session.
- If the session is on a FaceTime call, ending the call ends the session.
- VoiceOver says "Listen Together ended".

## What happens to the shared book

The listeners' temporary copy of the book (the downloaded pieces, if they don't have the book) is deleted when the session ends. If the app closes unexpectedly, it is deleted the next time BookPlayer opens. Nothing is added to the listeners' libraries.

Your own copy is never deleted or moved by Listen Together, and its place, bookmarks and last played are not changed. Ending the session as a listener with your own copy says "Leaves Listen Together. Your own copy is kept." as its hint.

## Known limitations

- **Streamed books cannot be shared.** Download them first. See "Before you start".
- Discord and other calling apps cannot start Listen Together. Start from Messages and talk on Discord while it plays.
- On a FaceTime call, Magic Tap ends the call instead of pausing. See "Magic Tap on a FaceTime call".
- After you send the invitation, BookPlayer waits up to 20 seconds for Listen Together to start (see "Share a book"). With the screen locked, you may not hear whether it started.
- The sleep timer controls your own book, not the shared one.
- During a listener session, your own book cannot be started from Siri, a widget or CarPlay while the phone is locked (BookPlayer cannot ask first). You hear "You're in Listen Together. Unlock to play your own book." when BookPlayer can speak. Unlock and choose the book in BookPlayer, then choose Leave.
- Invitations from other people are ignored while your own sharing screen is open or BookPlayer is waiting (up to 20 seconds) for your own share to start.
- CarPlay: during a listener session the standard Now Playing play, pause and skip buttons reach the shared book, but CarPlay's chapter buttons still control your own book. Connecting CarPlay may switch the lock screen to your own book.
- If the person sharing leaves the call but the call continues, listeners may keep waiting. Ending the session or the call stops it for everyone.
- Books streamed from a server, and different editions or recordings of the same book, are not matched. In "Only people who have the book can join" mode they cannot join; in "Send it for this session" mode they receive a temporary copy.
- With "Send it for this session", the person sharing still sends the pieces even if everyone so far has their own copy, so anyone who joins later without one can listen. People with their own copy never download them.
- Speeds other than 0.75, 1, 1.25, 1.5, 1.75 and 2 times are not shown in the speed list.
