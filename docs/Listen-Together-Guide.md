# Listen Together: User Guide

Listen Together lets you listen to an audiobook with other people, at the same time and in sync. You can start it from Messages, with no call needed, or on a FaceTime call. Only the person sharing needs the book. People who already have the book play their own copy. Everyone else can get a temporary copy for the session, unless the person sharing chose to listen only with people who have the book.

## Listening only: nobody gets a copy

Listen Together is for listening together, at the same time. It is not a way to give anyone a copy of a book.

- People who join can hear the book **only while the session is happening**.
- The book is saved on their iPhone for this session only. It is never added to their library, and they cannot save, export, or keep it.
- When the session ends, what was downloaded is deleted. If BookPlayer closes unexpectedly, it is deleted the next time BookPlayer opens.
- To listen again later, they need to join another session, or get the book themselves.
- If you already have the book, nothing is downloaded. BookPlayer plays your copy and saves the place you reach together to your library. Your place in the book moves to where the group is. If it moves by more than 30 seconds, your old place is first saved as a bookmark called "Your place before Listen Together", so you can go back to it (only once for each session you join). Your other bookmarks are unchanged.

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
8. A status line appears near the top of the player. With VoiceOver it reads, for example, "Listen Together, 2 people, sharing". Until someone joins it says "Listen Together, sharing, waiting for people to join", and the Listen Together row says "sharing, waiting for people to join". Nothing is announced for this: it is the normal wait. If you close the player, a **Listen Together** row stays above the tab bar. Choose it to return to the player.
9. When the session has started after the sharing screen, VoiceOver says "Listen Together started".
10. Listen Together starts where you are in the book: your saved place, also if the book isn't open in the player. Your place is never moved back by someone joining. Each time someone joins, BookPlayer keeps you where you are until that person's iPhone reports that it has reached your place, and brings them to you if it hasn't. If the session ends before then, your saved place is kept. (People on an older BookPlayer build never report it, so your place stays protected for the whole session; their skips then may be undone.)
11. Wait until someone has joined and you hear the book playing before you lock the phone.
12. BookPlayer starts sending the book only once someone has joined.
13. While the book is still being sent, your iPhone does not lock by itself if BookPlayer is on screen. Keep BookPlayer open while the book is sent if you can: it is sent in small parts, starting where you are listening. If you switch to another app or lock the phone, the sending can pause; listeners who are waiting for the book keep waiting and see "Waiting for the book"; others may see "Can't reach the person sharing. The book keeps playing.". Listen Together does not end because of it, and the sending carries on when you come back to BookPlayer.

If a part of the book can't be sent (for example the network drops), BookPlayer tries again by itself, a little later each time, and again as soon as you return to BookPlayer. Listen Together does not end because of it; listeners who need that part wait until it arrives. While nobody has joined yet, it tries again quietly and shows nothing. Once someone has joined, while it tries again, the status line on your player says "Couldn't send part of the book. Trying again." until the part has been sent, and the Listen Together row above the tab bar says "couldn't send part of the book, trying again". VoiceOver says it once each time this starts.

If SharePlay doesn't accept the parts of the book the usual way, on your iPhone or on a listener's, BookPlayer switches by itself to a slower way of sending them, for the rest of that session. Before it switches you may see "Couldn't send part of the book. Trying again." once, or listeners may wait a little longer for the book. Nothing else changes on screen, but listeners may wait longer for each part to arrive (the percentage still goes up with every part).

If BookPlayer can't read the book's files at all, nothing can be sent. A message says "Couldn't prepare the book for sharing. Listen Together ended." Choose OK. Listeners see "The person sharing couldn't prepare the book. Listen Together ended."

If the call or the connection ends without anyone choosing End, the person sharing sees "Listen Together ended because the call or connection ended." and listeners see "Listen Together ended because the connection to the person sharing was lost." Each is a message with OK.

While BookPlayer is still preparing, the button in the status line is **Cancel Sharing**. It stops at once; nothing has been sent and nobody has joined.

If the sharing screen cannot be opened, BookPlayer says "Couldn't open sharing" and suggests starting a FaceTime call instead.

If you chose "Only people who have the book can join", and someone does not have it, you hear "Someone couldn't join because they don't have the book." (once, even if several people couldn't join within a few seconds). The same sentence also stays on screen under the status line until the number of people changes or Listen Together ends. They hear that they need their own copy. You do not see who. In this mode "Someone joined" is said a few seconds after someone joins, so that people who can't join are never announced as joining.

After you send the invitation, BookPlayer waits up to 20 seconds for Listen Together to start. This is also the case if the sharing screen closes without saying whether it sent (for example you switched to Messages). If it has not started by then, a message says "Listen Together didn't start. Try again." Choose OK. Listen Together is back in the More menu. If it starts a little later anyway, VoiceOver says "Listen Together started".

If you are on a FaceTime call that is still ringing, or iPhone still shows an earlier SharePlay conversation, starting on the call can fail. BookPlayer then opens the sharing screen from Apple instead, so you can send the invitation in Messages.

If Listen Together isn't available at all, a message says "Listen Together isn't available right now." Choose OK.

## Join a book someone is sharing

1. If the invitation came in Messages, open it there. BookPlayer opens. If you are on a FaceTime call with the person sharing, the invitation reaches you without Messages.
2. VoiceOver says, for example, "Listen Together invitation: Moby Dick by Herman Melville".
3. An invitation appears on top of whatever screen you are on. The book title is the heading.
4. The invitation says: "You can only listen. The book is saved on your iPhone for this session only and deleted when it ends."
   If you have the book, the message says instead that you have it and BookPlayer plays your copy. Nothing is downloaded, and after Join you go straight to the player and hear "Joined. Playing your copy." once your iPhone has found the group's place.
   If the person sharing only listens with people who have the book and you don't, there is no invitation: you hear "You need your own copy", and the invitation is declined once that message is on screen. Choose OK (or use the two-finger scrub); either only closes the message. If BookPlayer isn't open at that moment, the message appears when you open it within a minute (and, only if you have already allowed BookPlayer notifications, a notification says so). After that, or if the person sharing has stopped, the message is dropped without being shown. If BookPlayer couldn't check your library in time, the message says "Couldn't check your library" instead: ask the person sharing to send the book.
5. Choose **Join** to listen, or **Not Now** to decline.
6. If you don't have the book: after you join, you hear "Getting the book" while the first part of the book downloads. The book comes in small parts (about 12 minutes each), starting with the part everyone is listening to, so playback can start as soon as that part is here, usually within seconds. The percentage on the status line goes up with every part. Under the status line is a **Leave Listen Together** button, if you want to stop waiting (see "End the session").
7. Playback starts in sync with everyone else, where the person sharing is in the book. For a moment after joining, the status line says "Finding the group's place", and the same words appear just under the Play button, while your iPhone finds out where the group is. Until then no time or chapter is shown: the times show "--:--", and with VoiceOver the position reads "Finding the group's place", so the start of the book is never shown by mistake. The lock screen shows no position yet either. In the player, Play, Pause, the skips, the position control, speed, chapters and Magic Tap do nothing until then, so you can't move everyone back to the beginning by accident; pressing a button or using Magic Tap says "Finding the group's place" with VoiceOver, at most once every 3 seconds, and the Play button reads it as its value (swiping the position says nothing more, because its value already says it). On the lock screen, AirPods and Control Center, presses do nothing and nothing is said. When the place is found, playback follows the group; if you had pressed something and the group is paused, VoiceOver says "Ready. Play works now." If it takes longer than about 12 seconds, a second line says "If this doesn't change, choose Leave Listen Together and join again." It takes the place of the download percentage on that line. VoiceOver says it once, when it is the message on screen (if "Waiting for the person sharing" or "Waiting for the book" is shown instead, it is said when that ends). Meanwhile your iPhone keeps asking by itself, less often after that line appears.
8. To leave the Listen Together screen without ending it, choose **Done** at the top right of the screen, or use the two-finger scrub. Done is also on "Getting the book". You go back to your library and the book keeps playing for everyone. A **Listen Together** row stays just above the tab bar. VoiceOver reads it, for example, as "Listen Together, playing, Moby Dick". Choose it to come back to the player.

If your copy can't be played during the session (for example you deleted or moved it), BookPlayer tries it again a few times. If it still can't be played, you leave Listen Together on your iPhone only and a message says "Your copy of this book can't be played right now. You left Listen Together." Choose OK. The others keep listening; if you were the last listener, Listen Together ends for the person sharing too.

If your copy was moved or deleted between the invitation and Join, BookPlayer gets the book from the person sharing instead (or, if they only listen with people who have the book, tells you "Your copy can't be used" and you don't join).

Your own book is paused when you join. While you listen together your own mini player is hidden, so you cannot start your own book by accident.

If the invitation cannot be shown straight away (for example BookPlayer is still opening from Messages), BookPlayer keeps trying for about 10 seconds. You hear the invitation announcement either way.

## During the session

Closing the Listen Together screen does not end the session. Choose **Done** (or use the two-finger scrub) to close it and the **Listen Together** row to open it again.

While you listen together, BookPlayer hides your own mini player. If you choose one of your own books (for example by double-tapping it in your library), BookPlayer first asks "Leave Listen Together to play this book?":

- The question goes on: "You will leave Listen Together on this iPhone. The others keep listening. SharePlay stays on until you close it in Control Center." If you are the last listener it says instead: "You will leave Listen Together on this iPhone. You are the last listener, so Listen Together ends for everyone."
- **Leave** ends Listen Together on your iPhone (the others keep listening, or, if you were the last listener, it ends for everyone), then plays your book. VoiceOver says, for example, "You left Listen Together. Playing Moby Dick." and lands on the book's title in the player.
- **Cancel**, or the two-finger scrub, keeps you in Listen Together. Your book does not play.

When you leave to play your own copy of the shared book, it resumes at the place you reached together. A different book keeps its own saved place.

**Siri and Shortcuts:** if you ask Siri to play one of your own books (or your last book), you leave Listen Together first ("You left Listen Together. Playing Moby Dick.") and your book plays. Siri's Pause and skip forward or back act on the shared book for everyone, like the lock screen; your own book's place never changes. Siri can't add a bookmark while you listen to someone else's book, and says so. If you are sharing, Siri's Pause, skips and bookmarks act on the shared book as usual, but asking for another book says "You're sharing a book. End Listen Together first to play another book."

If BookPlayer cannot ask (for example a widget or CarPlay while the phone is locked), your own book does not start, and Listen Together carries on. You will hear "You're in Listen Together. Unlock to play your own book." when BookPlayer can speak. If you have already allowed notifications for BookPlayer, a notification also says "Your book did not start" (at most once every 30 seconds); BookPlayer never asks for notification permission for this. Two books never play at the same time.

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

If you don't have the book: if a listener's next part of the book has not finished downloading, everyone waits until it arrives. On that iPhone the status line says "Waiting for the book", and the same words appear just under the Play button, so you can see why Play does nothing. VoiceOver says "Waiting for the book" once, and the Play button reads it as its value. Pressing Play or Pause on that iPhone while it waits does not stop the others; it says "Waiting for the book" again. Download progress is announced at 25, 50, 75 and 100 percent.

When someone else pauses, the status line says "Paused by another listener" (or "Paused by the person sharing", and VoiceOver says "The person sharing paused") until someone plays again.

### When someone leaves

If someone leaves Listen Together while the book is playing and other listeners are still there, the book pauses for everyone, so nobody misses anything. This happens when a listener chooses Leave, and when a listener's iPhone loses its connection. When the last listener leaves, Listen Together ends instead: see "When everyone has left" below.

- The status line says "Paused. Someone left Listen Together." (or "Paused. Someone lost their connection to Listen Together." when their iPhone dropped out; with more people, for example "Paused. 2 people left Listen Together."). Under it, the usual status still shows how many people are left, or, for the person sharing, "Someone couldn't join because they don't have the book." when that applies.
- The same sentence also appears just under the Play button, on every iPhone. If you are sharing, the Play button also reads it as its value. The Listen Together row says, for example, "paused, someone left, Moby Dick".
- VoiceOver says the sentence once on each iPhone that has BookPlayer open. If BookPlayer is in the background or the phone is locked, a notification says it instead (see below). You do not also hear "Someone left Listen Together" or "Another listener paused" for it.
- If you are sharing and "Speak error messages" is on, BookPlayer also reads the sentence aloud once.
- If someone else leaves while the book is still paused, VoiceOver only says "Someone left Listen Together", and the status keeps the first sentence.
- Anyone can carry on: press Play (on the screen, the lock screen, Control Center or AirPods). It plays for everyone and the message goes away.
- If the book was already paused, nothing more happens: VoiceOver says "Someone left Listen Together".
- If the person sharing leaves, this does not apply: everyone waits for them as described in "End the session".

If BookPlayer is in the background or the phone is locked (for example while you talk on Discord), whether you are sharing or listening, you hear the book stop. If you have allowed notifications for BookPlayer, a notification says "Paused. Someone left Listen Together.", and VoiceOver reads it on the lock screen. Allowing notifications for BookPlayer is what makes this audible on the lock screen; BookPlayer never asks for that permission. Without notifications, VoiceOver says it when you return to BookPlayer, if the book is still paused. You can press Play on the lock screen or your AirPods to carry on for everyone without unlocking. Once the book plays again, or Listen Together ends, the notification is removed, so it never tells you about a pause that is over.

If everyone else disappears at the same moment, the most likely cause is your own connection, so the person sharing sees "Paused. 2 people left Listen Together." rather than that they lost their connection. Nobody is left listening then, so the one-minute wait in the next section applies too.

### When everyone has left

Listen Together does not stay on with nobody listening.

- When the last listener chooses Leave (this includes leaving to play their own book, and a listener whose own copy can't be played), Listen Together ends for everyone at once, the same way as End.
- When the last listener disappears without choosing Leave (their iPhone lost its connection, or they used the system's own SharePlay controls), they may come back. The book pauses as described in "When someone leaves", and under the pause the status line says "If nobody is back within a minute, Listen Together ends." VoiceOver and the notification say that sentence too, and the Listen Together row says "paused, waiting a minute for listeners to come back". If their leaving message arrives late, it ends at once. If they are back within a minute, nothing ends: the book stays paused until someone presses Play. If nobody is back, Listen Together ends for everyone. If the book was already paused, VoiceOver says "Someone left Listen Together" and the same one-minute wait follows. If iOS stops BookPlayer from running in the background during that minute, Listen Together ends at that moment instead. A new listener already joining at that moment gets time to finish joining (a few seconds); if they leave, decline or don't finish, the session ends.
- When it ends, the book of the person sharing pauses too, so you hear that it ended even with the phone locked.
- Either way, the person sharing gets one message in the middle of the screen: "Listen Together ended because everyone left." It stays until you choose OK (the two-finger scrub also closes it). VoiceOver reads it once, and "Speak error messages" reads it when that setting is on. If BookPlayer is in the background or the phone is locked, the same rules as for other endings apply (see the end of "End the session").
- This only happens after at least one person has joined. While you are sharing and waiting for the first person to join, Listen Together stays on.
- The shared activity ends for everyone. Your FaceTime call or Messages conversation can continue.

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

If a call, Siri, an alarm or another app (possibly Discord) interrupts the book on a listener's iPhone, only that iPhone stops. The others keep listening and hear nothing about it.

- **While it lasts:** the status line says "Listen Together will continue when the interruption ends.", the same words appear just under the Play button and are the Play button's value, and the Listen Together row says "stopped by an interruption". VoiceOver says it once while BookPlayer is in front; it says nothing from the background, so it doesn't talk over your call.
- **When it ends:** the book carries on there by itself, at the place the group has reached by then (not where it stopped). For a moment the status says "Rejoining the others." until the group's place has arrived. If the book was paused for everyone meanwhile, it stays paused.
- **If iOS says the book should not start again by itself** (for example another app is still playing), or the group's place doesn't arrive within a few seconds, the status line says "Stopped on this iPhone. Press Play to rejoin the others." and the row says "stopped on this iPhone, press Play to rejoin". If BookPlayer is in the background or the phone is locked, a notification says it instead (only if you have allowed notifications for BookPlayer); otherwise VoiceOver says it when you return to BookPlayer, if your iPhone is still stopped.
- **Press Play** (on the screen, the lock screen or AirPods) to join the group where it is now. Play works as soon as iOS lets the sound start; until then pressing it says the status again. If the group turns out to be paused, Play starts it for everyone, as any Play does.
- **Pause** during the interruption keeps the book stopped on your iPhone until you press Play (the status changes without being announced, because you did it). Pause while "Rejoining the others." is shown pauses the book for everyone.
- **The skips and speed do nothing** while your iPhone is stopped or rejoining, so they never move the others; pressing them says the status again.

If you take out your headphones (or they disconnect) while listening, the book stops on your iPhone only, never through the speaker unless you ask: the status line says "Stopped on this iPhone. Press Play to rejoin the others." Press Play to join the group where it is now.

If the person sharing is interrupted (a call, Siri, an alarm or another app), the book pauses for everyone and stays paused until the interruption ends:

- **Listeners** see "The person sharing has an interruption. Listen Together will continue when it ends." in the status line, under the Play button and as Play's value; the row says "paused, the person sharing has an interruption". VoiceOver says it once (if BookPlayer is in the background, a notification says it instead, only if you allowed notifications). Play, the skips and speed do nothing meanwhile; pressing them says the sentence again, at most every 3 seconds.
- **The person sharing** sees "Paused for your interruption. Listen Together will continue when it ends." (nothing is said over the call).
- **When it ends**, the book plays again for everyone by itself if it was playing and iOS allows it. Otherwise the person sharing sees "Press Play to continue Listen Together." (a notification when away, if allowed), and listeners see "Paused. Waiting for the person sharing to press Play." Once the person sharing presses Play, everyone listens again.

When the session ends, the lock screen, Control Center and AirPods control your own book again. Pressing Play then starts your own book.

## End the session

- **If you are sharing:** choose **End Listen Together** in the status line on the player. BookPlayer asks "End Listen Together?": "It ends for everyone." Choose **End**, or **Cancel** (the two-finger scrub is Cancel). Listen Together ends for everyone and VoiceOver says "Listen Together ended". This ends the shared activity for everyone; your call or conversation can continue.
- **If you are listening:** choose **Leave Listen Together** (in the status line on the player, or under the status on "Getting the book"). BookPlayer asks "Leave Listen Together?": "You will leave Listen Together on this iPhone. The others keep listening. The book is deleted from this iPhone. SharePlay stays on until you close it in Control Center." (see "Close SharePlay completely"). If you are the last listener, it says instead: "You will leave Listen Together on this iPhone. You are the last listener, so Listen Together ends for everyone. The book is deleted from this iPhone." The Leave button's hint says whether the others keep listening. Right after joining, before BookPlayer knows who else is there, the question only says that you leave on this iPhone and what happens to the book. Choose **Leave**, or **Cancel** (the two-finger scrub is Cancel). After Leave the Listen Together screen closes, VoiceOver moves to your own mini player if it is shown, and says "You left Listen Together." If you listened with your own copy, the question says your copy stays in your library instead of that the book is deleted.
- **Done** and the two-finger scrub never end or leave Listen Together: they only close the screen.
- The Listen Together row only opens the player; it cannot end the session.
- If the session is on a FaceTime call, ending the call ends the session.

When the person sharing ends Listen Together, every listener gets one message: "The person sharing ended Listen Together." First the player closes, the Listen Together row goes away and the temporary copy is deleted; then the message appears in the middle of the screen and stays until you choose OK (the two-finger scrub also closes it). VoiceOver reads it once. Afterwards nothing of that session is left, and VoiceOver moves to your own mini player if it is shown. To listen together again, the person sharing sends a new invitation.

If the person sharing closes BookPlayer while it is running (for example swipes it away in the app switcher during the session), Listen Together ends for everyone at once, and listeners see "Listen Together ended because the connection to the person sharing was lost." A listener who closes BookPlayer this way only leaves; the others keep listening (if it was the last listener, the person sharing waits a minute for them, see "When everyone has left").

If the person sharing leaves Listen Together in another way (they are no longer in the session, for example their iPhone lost its connection), everyone pauses and waits. The status line says "Waiting for the person sharing" and "If they are not back within a minute, Listen Together ends." Play does nothing while you wait (it says why). If they are back within a minute, the book carries on and VoiceOver says "The person sharing is back." If not, Listen Together ends for everyone with one message, "The person sharing left. Listen Together ended.", the same way as above.

If the person sharing is still in the session but their iPhone has gone quiet (for example they switched to another app or locked the phone while the book was still being sent), listeners may see "Can't reach the person sharing. The book keeps playing." Nothing is announced or spoken for this, because the book goes on. This never ends Listen Together.

### Close SharePlay completely

After you leave Listen Together while others are still listening, iOS keeps SharePlay open in your call or Messages conversation (you may see it at the top of the screen or in the Dynamic Island, with a way to join again). BookPlayer can't close it. To close it:

1. Open Control Center. With VoiceOver: [to be checked on iOS 18 and iOS 26: select the status bar, then swipe down with three fingers].
2. At the top, choose [to be checked: the name VoiceOver reads, for example "SharePlay" or the call's name].
3. Choose [to be checked: for example "End SharePlay"]. If iOS asks, choose [to be checked: "End Only for Me"] to close it only on your iPhone.

Ending the FaceTime call also closes it. After End by the person sharing, or after Listen Together ended because everyone left, the shared activity is over for everyone, but iOS may still show SharePlay in the call or conversation. To close it, follow the steps above.

### After sharing ends

The sharer's End action ends the shared activity for everyone, including when the end message cannot be delivered. The session also ends automatically when the last listener leaves. Ending an activity does not end your FaceTime call or Messages conversation.

If BookPlayer is in the background when Listen Together ends for one of these reasons (or, for the person sharing, because everyone left) and you have allowed notifications, a notification says why. With VoiceOver off, the same message also appears in BookPlayer when you return to it. With the phone locked or VoiceOver on, the notification is the one message. Without notification permission (BookPlayer never asks for it), the message appears when you next open BookPlayer, unless a new invitation or session comes first. If only Control Center, Siri or a call banner is over BookPlayer, the message appears as soon as it closes.

## Messages you can see and hear

Every problem and every ending caused by someone else is shown on screen as well as spoken, so you don't need VoiceOver to know what happened:

- Endings and failures appear as a message in the middle of the screen, with OK. It stays until you close it.
- Ongoing things (finding the group's place, getting the book, waiting for the book, waiting for the person sharing, can't reach the person sharing, trying to send part of the book again, paused because someone left, waiting a minute for listeners to come back, paused by another listener, and your iPhone stopped by an interruption or by taking out your headphones) appear in the status line next to the controls, and stay until they change.
- With VoiceOver, each message is read once.

**Speak error messages.** In **Settings, Playback, Listen Together**, under "Messages", turn on **Speak error messages** to have BookPlayer read Listen Together problems aloud, for example when the person sharing ends Listen Together. It is off by default. It uses the voice and speed set in **Settings, Accessibility, Spoken Content**. It stays quiet while VoiceOver is on, because VoiceOver already reads these messages, and it never speaks during a phone or FaceTime call. It also works with the screen locked; the book keeps playing while the sentence is read. When it is on, **Hear a Sample** reads a short sentence so you can check the voice and volume.

After Listen Together has ended, the same invitation can't be used to join again until BookPlayer is restarted. The person sharing can start Listen Together again with a new invitation.

## What happens to the shared book

The listeners' temporary copy of the book (the downloaded pieces, if they don't have the book) is deleted when the session ends. If the app closes unexpectedly, it is deleted the next time BookPlayer opens. Nothing is added to the listeners' libraries.

Your own copy is never deleted or moved by Listen Together. Its listening position and last-played date are updated as you listen (at most once a second), with a final save when you leave or the session ends. If the group's place is more than 30 seconds from your own when you join, your earlier place is kept as a bookmark, "Your place before Listen Together". Your other bookmarks are unchanged. If you finish the book together, it is marked as finished. If you delete, move or convert your copy during the session, BookPlayer does not put it back in the player afterwards. Leaving as a listener with your own copy says "The others keep listening. Your copy stays in your library." as its hint.

## Known limitations

- **Streamed books cannot be shared.** Download them first. See "Before you start".
- Discord and other calling apps cannot start Listen Together. Start from Messages and talk on Discord while it plays.
- On a FaceTime call, Magic Tap ends the call instead of pausing. See "Magic Tap on a FaceTime call".
- After you send the invitation, BookPlayer waits up to 20 seconds for Listen Together to start (see "Share a book"). With the screen locked, you may not hear whether it started.
- The sleep timer controls your own book, not the shared one.
- During a listener session, your own book cannot be started from a widget or CarPlay while the phone is locked (BookPlayer cannot ask first; Siri leaves Listen Together instead). You hear "You're in Listen Together. Unlock to play your own book." when BookPlayer can speak. Unlock and choose the book in BookPlayer, then choose Leave.
- Invitations from other people are ignored while your own sharing screen is open or BookPlayer is waiting (up to 20 seconds) for your own share to start.
- CarPlay: during a listener session the standard Now Playing play, pause and skip buttons reach the shared book, but CarPlay's chapter buttons still control your own book. Connecting CarPlay may switch the lock screen to your own book.
- If the person sharing leaves, listeners wait for up to a minute and then Listen Together ends (see "End the session").
- When BookPlayer has switched to the slower way of sending the book (see "Share a book"), anyone who joins later gets the parts from the iPhone of the person sharing, so that iPhone needs to stay in the session, with BookPlayer open while parts are being sent, for them to get the book.
- Speak error messages: whether a Siri voice chosen in Spoken Content is used is still being checked. If it is not, the standard voice for your language is used.
- Books streamed from a server, and different editions or recordings of the same book, are not matched. In "Only people who have the book can join" mode they cannot join; in "Send it for this session" mode they receive a temporary copy.
- With "Send it for this session", the person sharing still sends the pieces even if everyone so far has their own copy, so anyone who joins later without one can listen. People with their own copy never download them.
- Speeds other than 0.75, 1, 1.25, 1.5, 1.75 and 2 times are not shown in the speed list.
