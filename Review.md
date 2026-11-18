# Claude (Swift Reviewer): develop full audit — November 17, 2026

Branch: develop.
Full commit reviewed: f60e6393a1c5793750caa7af66b9013be284d41a.
Checkout read: /Users/becky/Developer/Swift/BookPlayer.
Mode: full audit before TestFlight build 7. Round prefix: SR7 (SR6-01 was the last Swift Reviewer finding).

Scope: every Swift file in BookPlayer/SharePlay/ and BookPlayer/Settings/ListenTogether/, the code they touch (PlayerManager, AppDelegate, AppServices, MainCoordinator, MainView, the App Intents and PlayMediaIntentHandler), and the 13 upstream TortugaPower commits merged in aa1d5632, the merge itself, and f60e6393. Four reviewer agents each read one area line by line. I merged their findings, removed duplicates and checked the key lines of SR7-01 to SR7-05, SR7-03's listener side and SR7-15 myself. Nothing was built or run. No simulator, no Thread Sanitizer. Lenses: accessibility, concurrency, crash and leak risks, runtime paths.

Build settings: SWIFT_VERSION is 5.0 in all 27 build configurations and there is no strict-concurrency setting, so Swift 6 Complete checking is not in place. Reported as found, not proposed to change here.

All findings are filed in Start Testing as "SR7-NN: ... - Claude".

## Verdict for TestFlight build 7

Not ready yet. Two findings must be fixed first, and one needs a decision first:

- SR7-01 (High, Safe Alone): a sharer who plays another book from the library while sharing controls the whole group's playback. A sharer browsing their library mid-session is ordinary use, so testers will hit it.
- SR7-02 (High, Safe Alone): on iPad or Mac, opening a second window deletes the running session's book files. It's small to fix. If no tester uses an iPad or Mac, it could wait one build, but I'd fix it now.
- SR7-05 (Medium, Needs Becky): build 7 will ship with Hardcover sign-in broken, because no client id is set in the local xcconfigs and upstream removed the API key field. Either add a client id before archiving, or accept that Hardcover can't be connected in build 7 and tell testers.

I'd also fix SR7-03 and SR7-04 in build 7 if Becky can decide the wording now. Together they're the most likely reason dd0bde92 looked like a broken share. Everything else can follow in later builds. The merge itself is clean: no Listen Together change was lost and nothing in it breaks SharePlay. The upstream items are SR7-05, SR7-10, SR7-13 and SR7-15.

## Findings

### SR7-01 — High: A sharer playing another book plays, pauses and changes speed for the whole group

Where: [SharerPlaybackTarget.swift:366](<BookPlayer/SharePlay/SharerPlaybackTarget.swift:366>) (handleIsPlaying), 384 (handleSpeed), 288 (applyPause), 327 (applyRate). The playback gate allows it: [MainCoordinator+ListenTogether.swift:579](<BookPlayer/SharePlay/MainCoordinator+ListenTogether.swift:579>).

Failure scenario: while sharing, the sharer plays a different book from the library. handleIsPlaying has no holdsSharedBook check, so it sends `.played`. The bridge (ListenTogetherCoordinatorBridge.swift:325) then calls coordinateRateChange, and every listener starts the shared book and hears it resumed. When the sharer pauses their other book, the group pauses. It works in reverse too. A listener's Pause reaches applyPause, which calls `playerManager.pause()` without a holdsOtherBook check, so it pauses the sharer's other book. A listener's speed change sets the speed of that book. Seeks and asserts already have guards for this case; these paths don't.

Fix direction: ignore PlayerManager's play, pause and speed events unless holdsSharedBook, and skip pause and setSpeed in applyPause and applyRate while holdsOtherBook.
How to prove it's fixed: in SharerPlaybackTargetTests, with sharedItemUUID "A" and a mock whose current item is "B", toggling playing or speed sends nothing and applyPause/applyRate leave the mock alone. Then check with two phones.
Safe Alone.

### SR7-02 — High: Opening a second window deletes a running Listen Together session's files

Where: [MainCoordinator.swift:98](<BookPlayer/Coordinators/MainCoordinator.swift:98>) and 119-124. Info.plist:422 turns on multiple scenes, SceneDelegate makes one coordinator chain per scene, and [ShareStorage.swift:43](<BookPlayer/SharePlay/ShareStorage.swift:43>) holds the cleanup.

Failure scenario: during a listener session on iPad or Mac, the user opens a second BookPlayer window. The new window's MainCoordinator creates a second SharePlaySessionService, and its start() runs `ShareStorage().cleanAll()`, which deletes tmp/ListenTogether, including the pieces of the book that's playing. It also moves the remote commands, playback gate, intent routing and sharing-sheet presenter to the new, idle service, so lock-screen controls and Siri stop reaching the session.

Fix direction: one SharePlaySessionService per process (in AppServices), with the launch cleanup run once. Scene coordinators only present UI.
How to prove it's fixed: a unit test that starts two coordinators and checks an active share's files are still there. Then a check on the Pro with an iPad simulator and a second window.
Safe Alone. **Unverified:** whether GroupActivities delivers the session to both windows.

### SR7-03 — Medium: A piece that always fails is retried forever, with the screen kept awake

Where: [SharePlaySessionService+Session.swift:132](<BookPlayer/SharePlay/SharePlaySessionService+Session.swift:132>) (runSendLoop) and 277 (failure). The listener side is at 729-750 (listenerPieceFailed has no limit outside own-copy mode).

Failure scenario: the shared book is deleted or moved during the share, the disk is full, the file is damaged, or a piece is too large. failure() returns `.failed` for every error that isn't an interruption, and the loop has no attempt limit. So for the rest of the session the piece is exported again every 30 s (re-encoded, for MP3) and up to 25 MB is uploaded again. setKeepingScreenAwake(true) is set again before every try and only released when every piece is sent, so the screen never locks. The sharer hears "Trying again" once, or nothing if nobody has joined yet. The listener waits on "Waiting for the book" for good. The listener side also reloads an undecodable piece every 30 s, forever.

Judgement on the design point: this is a defect, not just a policy choice. A permanent failure can't recover, and the cost (battery, data, a screen that never locks) has no end and no explanation.
Fix direction: sort out permanent failures and never retry them. Limit the others to N tries or about 5 minutes, release the idle timer while waiting, and end with one clear message to both sides.
How to prove it's fixed: a test in ListenTogetherReliableSendingTests with an exporter that always throws, using a fake clock. Attempts stop at the limit, the idle timer is released and the final message is delivered. The same test for repeated piece failures on a listener.
Needs Becky (new outcome and wording; this answers the open question in context.md).

### SR7-04 — Medium: A sharer isn't clearly told someone was turned away for not having the book (dd0bde92)

Where:
- [SharePlaySessionService+Session.swift:1033](<BookPlayer/SharePlay/SharePlaySessionService+Session.swift:1033>): the turned-away line is a raw announcement.
- ListenTogetherMessages.swift:12-54: there's no message case for it.
- ListenTogetherStatusRow.swift:117-143 and MainView.swift:199-205: the mini player and the row ignore it.
- SharePlaySessionService.swift:1063-1081 and ListenTogetherTransport.swift:412-431: the decline is only sent once the invitee's alert is on screen. It's abandoned silently after 60 s in the background, or 3 s without joining.
- SettingsPlaybackSectionView.swift:34-40: the choice is only an accessibility value.
- SharePlaySessionService.swift:872: the mode note is shown once per device, ever.

Failure scenario: the sharer's phone is set to "Only people who have the book can join", and they share with someone who doesn't have it. At best a sighted sharer sees a second banner line, and only with the player open. The message isn't spoken by Speak error messages, isn't sent as a notification when the app is in the background, and never names the setting. On the paths where the decline is abandoned, the sharer gets nothing, and the mini player keeps saying it's waiting for people. The Settings row doesn't show the current choice on screen, and the footer doesn't say that having the book means having the same recording.

Fix direction: send the decline through messages.deliver, show it in the sharer's mini player and row value, and name Settings, Playback, Listen Together in it. Show the row's value on screen and mention "the same recording" in the footer.
How to prove it's fixed: unit tests for the message and the accessory value. Then an owners-only share between two phones, with the player closed and VoiceOver off. Voice Control "Tap Listen Together" must still work.
Needs Becky (wording and speech).

### SR7-05 — Medium: Hardcover can't be connected in fork builds (upstream 1f02c029)

Where: [HardcoverOAuth.swift:22](<BookPlayer/Hardcover/Network/HardcoverOAuth.swift:22>) (`?? ""`), with the client id sent at 130 and 206. The local Debug.xcconfig and Release.xcconfig have no BP_HARDCOVER_CLIENT_ID value; only Xcode Cloud fills it in, and the fork archives locally.

Failure scenario: a tester chooses Settings, Integrations, Hardcover, Sign In. Hardcover shows an error page, and closing it gives a generic failure alert. The API key field is gone, so there's no other way to connect. Keys saved earlier keep working.

Fix direction: get a client id (the fork's own Hardcover app, or upstream's public one) into the local xcconfigs, and fail early with a clear message when it's empty.
How to prove it's fixed: Sign In shows Hardcover's login form and comes back signed in.
Needs Becky.

### SR7-06 — Medium: Joining closes open sheets and discards Transfer from Computer files or unsaved edits

Where: [MainCoordinator+ListenTogether.swift:195](<BookPlayer/SharePlay/MainCoordinator+ListenTogether.swift:195>), ListenTogetherPresentation.swift:171, TransferViewModel.swift:194-201.

Failure scenario: an invitation arrives while Transfer from Computer is receiving files, or while item details are being edited. Join closes every sheet without asking and without an announcement. The received files are wiped and unsaved edits are lost.

Fix direction: ask first, or have Join finish the transfer (hand it to import) or keep the edits.
How to prove it's fixed: receive a file, then accept an invitation. The file reaches the import prompt, or a question is asked.
Needs Becky. **Unverified:** whether onDismiss always runs when a SwiftUI sheet is closed through UIKit.

### SR7-07 — Medium: A sleep timer ending during a listener session can silence the listener

Where: PlayerManager.swift:1969 (the timer ends and calls pause), 1629-1638 and 923-933 (deactivation 0.1 s later), and [ListenerPlayer.swift:1022](<BookPlayer/SharePlay/ListenerPlayer.swift:1022>) (the cached sessionConfigured flag).

Failure scenario: a timer set before joining, or set by Siri during the session, runs out while a transfer listener is playing. PlayerManager pauses the user's own paused book and then deactivates the shared audio session under the listener's audio. The listener goes quiet while the group still shows playing. The timer never stops the shared book.

Fix direction: decide what the timer should do in a session, handle it in SharePlay, and stop trusting the cached flag.
How to prove it's fixed: on a device, set a 1-minute timer, join and let it run out.
Needs Becky. **Unverified.**

### SR7-08 — Medium: The listener player doesn't recover from a media services reset

Where: [ListenerPlayer.swift:182](<BookPlayer/SharePlay/ListenerPlayer.swift:182>)-262: there's no mediaServicesWereReset observer.

Failure scenario: after a reset, the listener's dead player reloads failing items every 30 s while the group stalls. An own-copy listener reaches the failure limit and leaves with a "can't be played" alert, though the file is fine.

Fix direction: observe the reset, rebuild the player, and reload at the saved position.
How to prove it's fixed: a unit test that posts the notification. Then on a device, Settings, Developer, Reset Media Services during a session.
Safe Alone. **Unverified.**

### SR7-09 — Medium: Smart Rewind on the sharer seeks the whole group back after each group Play

Where: [SharerPlaybackTarget.swift:283](<BookPlayer/SharePlay/SharerPlaybackTarget.swift:283>), PlayerManager.swift:1458 and 1461, SharerPlaybackTarget.swift:407.

Failure scenario: with Smart Rewind on, a listener pauses for a few seconds and resumes. The sharer rewinds about 2 s, the backward jump is sent as a group seek, and everyone hears "skipped back 2 seconds". The auto sleep timer can also start.

Fix direction: a play call for group commands that skips smart rewind and the auto timer.
How to prove it's fixed: on two phones, there's no second seek and no announcement.
Needs Becky (PlayerManager). **Unverified.**

### SR7-10 — Medium: VoiceOver focus is lost after Hardcover sign-in or log-out (upstream)

Where: [HardcoverSettingsView.swift:32](<BookPlayer/Hardcover/Settings Page/HardcoverSettingsView.swift:32>) and 60, HardcoverSettingsViewModel.swift:38 and 55.

Failure scenario: the whole form swaps, the focused button disappears, and nothing is announced. When offline, the Account section is an empty header.

Fix direction: announce the result and move focus to a named element.
How to prove it's fixed: a VoiceOver walk-through of sign-in and log-out.
Needs Becky.

### SR7-11 — Medium: In journal mode the sharer keeps a full temporary copy of the book until the session ends

Where: [SharePlaySessionService+Session.swift:146](<BookPlayer/SharePlay/SharePlaySessionService+Session.swift:146>), BookSplitter.swift:73.

Failure scenario: sharing a 1 GB multi-file book adds about 1 GB to tmp for the whole session. On a nearly full phone, that leads to export failures, which then loop forever (SR7-03).

Fix direction: delete each exported piece after its upload succeeds.
How to prove it's fixed: a test that the folder holds no uploaded pieces, plus a device check that late joiners still get their pieces.
Safe Alone. **Unverified:** whether GroupSessionJournal reads the data after add returns.

### SR7-12 — Low: A listener's request for a needed piece waits behind a running retry back-off

Where: [SharePlaySessionService+Session.swift:184](<BookPlayer/SharePlay/SharePlaySessionService+Session.swift:184>)-207.

Failure scenario: the piece the group is stalled on is moved to the front, but the loop isn't woken, so the group waits up to 30 s.

Fix direction: call `retryWaiter.wake()` after request.
How to prove it's fixed: a fake-clock test.
Safe Alone.

### SR7-13 — Low: Listen Together moves a listener's Hardcover progress and status forward permanently

Where: SharePlaySessionService+Session.swift:470 and 840, reaching HardcoverService.swift:511-530 and 640.

Failure scenario: a listener at 20% of their own copy joins a group at 80%. Hardcover jumps to 80%, and to Read if the group finishes. Hardcover never moves backwards, so going back to their earlier place doesn't undo it.

Fix direction: decide whether Listen Together syncs to Hardcover; if not, skip it during own-copy sessions.
How to prove it's fixed: a unit test.
Needs Becky.

### SR7-14 — Low: Handing Now Playing back calls pause(), which can cut off the user's own book right after Leave

Where: [ListenTogetherRemoteCommands.swift:295](<BookPlayer/SharePlay/ListenTogetherRemoteCommands.swift:295>)-306.

Failure scenario: Leave runs teardown, which calls pause() and arms a delayed session deactivation. If the user's own loaded book starts within 100 ms, it's cut off.

Fix direction: publish the Now Playing info without calling pause().
How to prove it's fixed: on a device, Leave for the loaded book and confirm playback continues.
Safe Alone, unless it needs a PlayerManagerProtocol change. **Unverified.**

### SR7-15 — Low: Two more source files are over 700 lines

MainCoordinator+ListenTogether.swift has 787 lines. HardcoverService.swift has 989 (upstream; split it only if the fork will carry the split). Already known: SharePlaySessionService.swift (1729), SharePlaySessionService+Session.swift (1785) and ListenerPlayer.swift (1033).
Safe Alone.

## Checked and sound

- Messages from the other device are untrusted, and they're validated: ChunkFrame.decode checks magic, version, counts, index and size, and ChunkGaps clamps its ranges. There are no force unwraps or `try!` on decoded data.
- The core types are `@MainActor`. Every `assumeIsolated` call runs on the main queue and has a reason. ChunkFileWriter's `@unchecked Sendable` has a safety comment and is correct. The retry waiter can't hang at teardown.
- ListenerPlayer's KVO and time observer are balanced. Sinks use `[weak self]` and are stored. Remote-command targets are added once. Background tasks end on every path. Own-copy progress uses the main context and snapshots.
- Localization is complete: every Listen Together key is in Base. The iOS 27 result-builder hazard (hotlist 15) doesn't apply.
- Upstream merge: only project.pbxproj needed hand resolution, and both sides were kept. Listen Together references are identical before and after. The HardcoverOAuthSession refresh is single-flight. Tokens stay in the Keychain and go only to Hardcover. The out-of-space restore and the legacy artwork restore are safe.

## Earlier findings

- SR6-01 is still open on develop. Its fix, 050d480f, is only on fix/sr6-01-rejoin-other-audio.
- BP-20261112-03 to -22 were not rechecked in this round and remain open in Start Testing.

# Codex (Astra Medium): develop audit finding recheck — November 12, 2026

## Reviewed snapshot and result

Branch: develop.
Full commit reviewed: 90463774e1abcfe163535f95bdec575ff236abb1.
Checkout read: /Users/becky/Developer/Swift/BookPlayer.
Baseline: the October 23 review of 8cb2972534af4ba7a4bd112410d280748270319a, retained unchanged below.

Two of the 22 prior numbered findings are addressed in source: R01 and R02. Twenty remain outstanding: R03–R22, comprising eight P1 and twelve P2 findings. Each is revalidated below with a new review-specific ID; the suffix preserves the previous R number. No implementation repair was performed in this review.

Three GPT-6 Astra reviewers using Medium reasoning rechecked the source and relevant callers in data/sync/import, playback/UI/accessibility, and accounts/network/integrations. The coordinating review checked the intervening diff and reconciliation evidence. Swift Concurrency Pro, SwiftUI Pro, Swift Testing Pro and the Superpowers parallel review/verification workflows informed the review. The configured Superpowers symlink was broken; the installed cached skill package was used instead.

This is the current local develop snapshot, not a claim about un-fetched remote branches. Tracked source was clean; the existing untracked .nova/ directory was left alone. No builds, automated tests, Thread Sanitizer, Simulator, phone or assistive-technology runs occurred. Fixed means the reported source defect is addressed, not that fresh device acceptance has passed. The checks below describe future verification, not tests run today.

## Findings addressed in current source

- R01, Siri playback routing: PlayMediaIntentHandler.swift:133–145 now routes through listenTogetherAllowsStart before loading and returns failure when the loader declines. Its helper at 154–160 uses ListenTogetherIntentRouting. This was introduced by d55292ea. Actual Siri requests as sharer/listener, another-book refusal and declined loading still need device acceptance with Becky.
- R02, video playback surface: PlayerView.swift:48–52 refreshes video state and 200–215 restores VideoArtworkView for video items, also in d55292ea. Show Video, portrait/side-by-side layout, full-screen and Picture in Picture still need device acceptance with Becky.
- Earlier A01, foreign-item completion: PlayerManager.swift:1832–1839 retains the owned-item identity guard. Earlier A08, activation crash: 1420–1443 retains recoverable reporting and return. Earlier A17, the six App Intent routes, still uses ListenTogetherIntentRouting. These earlier fixes have not been promoted back into the open list.
- Earlier A03, upload rejection: NetworkClient.swift:146–154 checks artwork HTTP status; PartUploadTransport.swift:113–114 passes multipart status and FileUploadOperation.swift:599–605 restricts success to 2xx. Earlier A14, lost Hardcover ID: HardcoverService.swift:351–352 still saves the returned ID. R16’s independent ordering defect remains.
- The October 23 unnumbered transfer-cover concern is addressed by ListenTogetherPresentation.isCovered at 113–119, which includes every cover except Listen Together itself. MainView.swift:199–206 and ListenTogetherStatusRow.swift:150–163 now derive the sharer accessory from live interruption/wait/retry state. Source repairs do not certify presentation, focus, Zoom or VoiceOver behavior.

## Outstanding findings, ranked by severity

P1 denotes high-priority data integrity, crash or playback ownership risk. P2 denotes consequential functional/state/accessibility defects. Safe Alone permits isolated repair and fixture verification; any stated device acceptance still needs Becky. Needs Becky also marks the existing permission boundary on PlayerManager.swift. These labels do not change item assignments or approve release.

### BP-20261112-03 — P1: A failed backup move is followed by permanent deletion

Status: outstanding; revalidates R03 from October 23.

Location: [Shared/Services/LibraryService+Sync.swift:727](</Users/becky/Developer/Swift/BookPlayer/Shared/Services/LibraryService+Sync.swift:727>).

createBackup suppresses move errors, while removeItems deep-deletes every original at line 666. If Backup already contains the same relative path, moving the current file fails and LibraryService.swift:1435 still deletes that current original. The older backup may contain different audio. Directory or storage errors have the same destructive continuation.

Recommended correction: Return backup success or failure, use collision-safe destinations, and permit destructive deletion only after confirming a recoverable backup of that specific item.

How to prove it is fixed: Use disposable files to inject an existing backup-name collision and directory/write failures. Confirm the exact original remains unless its own recoverable backup has been verified.

Classification: Safe Alone.

### BP-20261112-04 — P1: A former account’s list response can reconcile after logout

Status: outstanding; revalidates R04 from October 23.

Location: [Shared/Services/Sync/SyncService.swift:361](</Users/becky/Developer/Swift/BookPlayer/Shared/Services/Sync/SyncService.swift:361>).

syncListContents waits for teardown before fetching, but captures no account/session generation and performs no check after fetchContents returns at 361–363. Logout at 763–778 can occur during that await. A delayed account A response then updates, inserts and removes local items through 440–445 after logout or login to B. Initial sync now guards its initial fetch result at 410–411, but that partial repair does not protect this ordinary refresh or the individual awaited reconciliation mutations.

Recommended correction: Carry a session generation through fetching and reconciliation, invalidate it on logout, and validate it before applying mutations. Exercise a delayed A response after switching to B.

How to prove it is fixed: Hold account A’s response, log out and switch to B, then release it. Assert no A metadata, insertion, removal or timestamp effects. Repeat with barriers between reconciliation mutations; use mocked accounts. Live account acceptance needs Becky.

Classification: Safe Alone.

### BP-20261112-05 — P1: Logout can miss a sync operation that has not yet entered its queue

Status: outstanding; revalidates R05 from October 23.

Location: [Shared/Services/SyncQueue/SyncQueueService.swift:432](</Users/becky/Developer/Swift/BookPlayer/Shared/Services/SyncQueue/SyncQueueService.swift:432>).

enqueueNextTask checks whether server work is enabled at 338–349, then suspends on task lookup at 353 and again on MainActor publication at 432–434. Logout cancels only operations already in operationQueue at 255. If it runs in either gap, the captured operation is added afterward at 436 and was never cancelled. LibraryItemSyncOperation.main at 86–101 checks cancellation flags, not a session generation, and requests use the current token. Following a rapid account switch, a former account’s queued mutation can execute under the next account.

Recommended correction: Serialize queue admission with logout invalidation and give each operation a captured account generation checked before execution and completion effects. A Boolean check before another suspension is insufficient.

How to prove it is fixed: Place deterministic barriers at task lookup and MainActor publication, log out/switch accounts, then release admission. Assert zero stale network requests and completion mutations under the new account.

Classification: Safe Alone.

### BP-20261112-06 — P1: Import workers use main-context Core Data objects off their queue

Status: outstanding; revalidates R06 from October 23.

Location: [BookPlayer/Import/Models/ImportOperation.swift:179](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Import/Models/ImportOperation.swift:179>).

ImportManager enqueues these operations on OperationQueue at 100–101. hasExistingBook calls LibraryService.findBooks, whose fetch directly uses the main viewContext at LibraryService.swift:1674–1676, then dereferences the returned Book on the import worker. CoreDataStack.swift:17–18 confirms context ownership. Concurrent library changes can race this queue-confinement violation and cause a crash.

Recommended correction: Perform the fetch and URL extraction on the owning context, returning a value snapshot. Protecting only the fetch while returning a managed object for worker access does not fix ownership.

How to prove it is fixed: Import on the worker queue with Core Data concurrency debugging and disposable data while modifying library records. Verify lookup runs on its context and workers receive only value snapshots; run targeted concurrency checks.

Classification: Safe Alone.

### BP-20261112-07 — P1: Failed ZIP extraction deletes its input archive

Status: outstanding; revalidates R07 from October 23.

Location: [BookPlayer/Import/Models/ImportOperation.swift:124](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Import/Models/ImportOperation.swift:124>).

The unzip completion removes the source before checking success at 124–129. A corrupt archive or failed extraction is discarded and the operation advances without preserving the input for retry. Unlike ordinary file-import cleanup, this path also lacks the isAppManagedSource restriction, so a writable external input can be removed.

Recommended correction: Preserve archives on failure, surface extraction errors, and remove only app-owned inputs after successful processing.

How to prove it is fixed: Exercise corrupt ZIPs, extraction failure, a writable external source and owned staging. Failure must retain retryable input and report the error; successful cleanup must respect ownership, including finish() staging cleanup.

Classification: Safe Alone.

### BP-20261112-08 — P1: Queued chapter installation can resurrect obsolete playback

Status: outstanding; revalidates R08 from October 23.

Location: [BookPlayer/Player/PlayerManager.swift:697](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Player/PlayerManager.swift:697>).

The load task has cancellation checks, but then escapes into an OperationQueue block and an independent main-queue closure at 697–724. The operation captures playerItem at 706, clears the active player off main at 717 and later installs the captured item at 724 without cancellation, generation or identity checks. A load of B or Stop between these steps cannot retract A’s queued installation. The subsequent initialization at 740–745 can combine stale audio/metadata with the latest currentItem. Stop cancels Swift tasks at 1693–1694, not these queued closures.

Recommended correction: Install the item on the playback owner’s actor with an exact load generation and item/chapter check. Invalidate pending installations when stopping or replacing a book; cancelling only the parent Swift task is insufficient.

How to prove it is fixed: Existing context.md requires Becky before editing PlayerManager.swift. Once authorized, hold an A installation, Stop or load B, then release A. Assert no stale item, metadata or readiness publication; run targeted Thread Sanitizer and device playback acceptance.

Classification: Needs Becky.

### BP-20261112-09 — P1: Raw player-status callbacks mutate shared state without isolation

Status: outstanding; revalidates R09 from October 23.

Location: [BookPlayer/Player/PlayerManager.swift:1549](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Player/PlayerManager.swift:1549>).

The KVO handler checks only the status key path and AVPlayerItem type, then directly mutates observer/queued flags, starts reloads and clears playerItem at 1554–1615. It neither moves the whole transition onto the playback owner’s executor nor checks that the observed object is still owned. The file acknowledges the lack of guaranteed main-thread delivery at 609–620. These writes can race load/stop; a delayed callback can affect a replacement item. The external-stream retry at 1572–1581 uses the same unsafe path. The A01 end-of-item identity fix protects a different notification.

Recommended correction: Confine the entire status transition to one actor and revalidate the observed item and load generation there. Review observer registration/removal under the same ownership boundary.

How to prove it is fixed: Existing context.md requires Becky before editing PlayerManager.swift. Once authorized, inject delayed replaced/foreign-item status callbacks and assert no changes to the current item. Verify all status transitions and observer changes share one owner; run targeted Thread Sanitizer.

Classification: Needs Becky.

### BP-20261112-10 — P1: Watch playback can resume after Pause or Stop during activation

Status: outstanding; revalidates R10 from October 23.

Location: [BookPlayerWatch/LocalPlayback/Player/PlayerManager.swift:872](</Users/becky/Developer/Swift/BookPlayer/BookPlayerWatch/LocalPlayback/Player/PlayerManager.swift:872>).

The play task checks cancellation at 859 and then awaits audio-session activation at 872. Pause and Stop cancel it at 1058 and 1098, but no check follows activation: completion proceeds to bookmark work and playImmediately at 908 with the captured old book. The catch at 873–875 also reports activation failure and continues, including when cancellation throws.

Recommended correction: Return on activation failure and check cancellation plus the current playback generation/item after the await before changing playback or bookmarks. Exercise delayed activation followed by Pause, Stop and a different-book load.

How to prove it is fixed: Delay Watch audio activation and issue Pause, Stop and replacement load; also fail activation. Assert no stale playback or bookmark effects. Real Watch playback acceptance needs Becky.

Classification: Safe Alone.

### BP-20261112-11 — P2: Database backup can accept a stale or inconsistent SQLite snapshot

Status: outstanding; revalidates R11 from October 23.

Location: [Shared/Services/DatabaseBackupService.swift:159](</Users/becky/Developer/Swift/BookPlayer/Shared/Services/DatabaseBackupService.swift:159>).

The live SQLite database and WAL/SHM are copied separately at 159–175. Sidecar-copy errors are suppressed and success is returned. Missing committed WAL content can leave a readable but stale database, so opening it does not prove backup completeness. A checkpoint between copies also prevents a guaranteed coherent snapshot. Previous backups are then eligible for pruning.

Recommended correction: Use a supported consistent database snapshot operation, fail on required-copy errors, and retain prior backups until the new snapshot is validated.

How to prove it is fixed: Back up a disposable database during writes/checkpoints and inject WAL-copy failure. Restore and check committed sentinel records and consistency; failed backup must preserve prior backups.

Classification: Safe Alone.

### BP-20261112-12 — P2: An empty remote folder never clears its local contents

Status: outstanding; revalidates R12 from October 23.

Location: [Shared/Services/Sync/SyncService.swift:421](</Users/becky/Developer/Swift/BookPlayer/Shared/Services/Sync/SyncService.swift:421>).

processContentsResponse returns immediately when content is empty, including when canDelete is true. Deleting the last remote child therefore skips removal of all local entries, while syncListContents still advances its timestamp at 365–368. The library can retain deleted books indefinitely.

Recommended correction: Process a successful authoritative empty listing as an empty identifier set for reconciliation, distinct from a fetch or decoding failure.

How to prove it is fixed: Return an authoritative successful empty listing and verify eligible local records are reconciled away. A failed or undecodable response must never delete them.

Classification: Safe Alone.

### BP-20261112-13 — P2: Chapter refresh loses server identity and writes chapters to other books

Status: outstanding; revalidates R13 from October 23.

Location: [Shared/Services/LibraryService.swift:3334](</Users/becky/Developer/Swift/BookPlayer/Shared/Services/LibraryService.swift:3334>).

Providers group requests by server but merge their answers into a dictionary keyed only by providerId (MediaServerChapterProviding.swift:74–79). Ingest at 3334–3350 fetches every resource matching providerName and providerId, without hostId or an originating-resource restriction. Server A’s book can therefore populate a different book on server B with the same ID, even outside the refreshed folder. Both servers need not participate in that refresh. storeChaptersIfEmpty makes the incorrect result persistent.

Recommended correction: Preserve provider, resolved host and item identity throughout request results and ingest, and restrict writes to the originating resources. Cover overlapping IDs on two configured servers.

How to prove it is fixed: Configure two fixture servers with identical provider IDs but distinct chapters, including a B resource outside the refreshed folder. Refresh A and verify only the correctly identified A resources change.

Classification: Safe Alone.

### BP-20261112-14 — P2: Download ownership is assigned after an await

Status: outstanding; revalidates R14 from October 23.

Location: [BookPlayer/Services/SingleFileDownloadService.swift:91](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Services/SingleFileDownloadService.swift:91>).

Two handleDownload calls can both observe currentTask == nil before networkClient.download returns. That function really suspends on session.allTasks (NetworkClient.swift:116). Both downloads start and the later assignment overwrites ownership at 104. Completion uses currentTask.folderName at 143 rather than metadata belonging to the completed task, so one download can enter the other destination. Delegate callbacks also read state written from MainActor without a single isolation boundary.

Recommended correction: Reserve the queue item before awaiting, isolate all queue state, and bind destination metadata to the actual URLSessionTask identity.

How to prove it is fixed: Suspend download creation, issue two starts and release completions in reverse order. Verify one queue owner and correct per-task destinations; run targeted race checks. Actual device import acceptance needs Becky.

Classification: Safe Alone.

### BP-20261112-15 — P2: Login failure leaves backend and local account identities inconsistent

Status: outstanding; revalidates R15 from October 23.

Location: [Shared/Services/Account/AccountService.swift:472](</Users/becky/Developer/Swift/BookPlayer/Shared/Services/Account/AccountService.swift:472>).

Apple login stores the new backend token before awaiting throwing RevenueCat login at 479. Failure leaves that token active while local account identity remains old or anonymous. Passkey login at 500–504 and transferred credentials at 526–528 use the same ordering. Subsequent requests can use the newly stored token despite the failed-login result. Pending login also has no logout-generation invalidation.

Recommended correction: Stage identity changes or roll back credentials on failure, and reject stale completions after logout so backend, RevenueCat and local identity commit coherently.

How to prove it is fixed: Inject RevenueCat failure for Apple, passkey and transferred-credential login. Verify token, account and subscription identities remain coherent. Suspend login, log out and resume; reject stale identity restoration. Real account acceptance needs Becky.

Classification: Safe Alone.

### BP-20261112-16 — P2: Hardcover status tasks can commit in reverse order

Status: outstanding; revalidates R16 from October 23.

Location: [BookPlayer/Hardcover/Network/HardcoverService.swift:341](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Hardcover/Network/HardcoverService.swift:341>).

Progress and finish subscriptions launch independent tasks at 280 and 293. updateHardcoverStatus captures the current association/status at 334, then awaits the mutation and unconditionally stores the captured record with its requested status at 350–354. A reading update that completes after a read update can move the local status backward; server requests can also arrive out of order. An association changed while awaiting can likewise be overwritten.

Recommended correction: Serialize/coalesce changes per book and validate association/generation before committing. Preserve the newest intended status. The separate old missing-userBookID issue is fixed at 351–352.

How to prove it is fixed: Reverse reading/read request completion and change the book association during suspension. Assert the newest intended status and current association survive. Real Hardcover acceptance needs Becky.

Classification: Safe Alone.

### BP-20261112-17 — P2: Cancelled AudiobookShelf search can show an error or stale results

Status: outstanding; revalidates R17 from October 23.

Location: [BookPlayer/AudiobookShelf/Library Screen/AudiobookShelfLibraryViewModel.swift:529](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/AudiobookShelf/Library Screen/AudiobookShelfLibraryViewModel.swift:529>).

Query changes cancel the previous search, but the catch handles only CancellationError. IntegrationURLSessionClient directly forwards URLSession errors, including URLError.cancelled, into the general error branch at 545–546; IntegrationLibraryView.swift:69 presents it. There is also no query/generation check after the await before replacing results at 541–542. Normal rapid typing can therefore produce a cancellation alert or obsolete results.

Recommended correction: Suppress both cancellation forms and validate the current query/task generation before publishing results or errors.

How to prove it is fixed: Rapidly change queries with reversed delayed responses and both CancellationError and URLError.cancelled. Assert no cancellation alert or obsolete results. Search and VoiceOver acceptance needs Becky.

Classification: Safe Alone.

### BP-20261112-18 — P2: An old fetch clears the replacement task’s handle

Status: outstanding; revalidates R18 from October 23.

Location: [BookPlayer/Jellyfin/Library Screen/JellyfinLibraryViewModel.swift:346](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Jellyfin/Library Screen/JellyfinLibraryViewModel.swift:346>).

Unconditional defer cleanup sets fetchTask to nil when an old task exits, even if another task has replaced it. The same pattern occurs at Jellyfin lines 282 and 318 and AudiobookShelf lines 392, 472 and 532. A’s cleanup can erase B’s ownership, defeating cancellation and fetchMore guards and allowing overlapping page requests or duplicate appends. Jellyfin’s new response guards do not fix handle ownership.

Recommended correction: Clear the handle only if the finishing operation still owns the active generation; keep pagination admission serialized.

How to prove it is fixed: Suspend A, replace it with B, then finish A. B must retain its active handle and remain cancellable, and a third page request must not overlap or append duplicate results.

Classification: Safe Alone.

### BP-20261112-19 — P2: Late bookmark loading can replace the new book’s list

Status: outstanding; revalidates R19 from October 23.

Location: [BookPlayer/Player/Views/Bookmarks/BookmarksViewModel.swift:108](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Player/Views/Bookmarks/BookmarksViewModel.swift:108>).

An independent request for A awaits syncBookmarksList and assigns userBookmarks at 115–116 without checking the current book or generation. Switching to B while A is pending lets A replace B’s displayed list. Selecting a stale bookmark calls jumpTo on the current player at 88, so B moves to A’s timestamp. The merged persistent side panel makes book changes while the list is mounted especially relevant.

Recommended correction: Invalidate superseded requests and check current book identity at publication and action time.

How to prove it is fixed: Request bookmarks for A then B, resolve B before A, and verify only B remains displayed. Attempt a stale A selection and ensure B is not sought or mutated. Mounted-panel device acceptance needs Becky.

Classification: Safe Alone.

### BP-20261112-20 — P2: Playback sliders and speed buttons lack meaningful accessible names

Status: outstanding; revalidates R20 from October 23.

Location: [BookPlayer/Player/Views/Controls/PlayerControlsSpeedSectionView.swift:51](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Player/Views/Controls/PlayerControlsSpeedSectionView.swift:51>).

The speed slider at 51–55 supplies a value without a function name; the adjacent text is not associated with it. Decrease/increase buttons explicitly use emoji labels at 94 and 119. ListeningProgressView.swift:27–39 and SlickSlider.swift:82–114 also supply no explicit seek-function label. Screen-reader users receive insufficient purpose information. Actual announcements were not exercised.

Recommended correction: Provide localized Playback speed and Playback position names, meaningful increase/decrease labels, and appropriate speed/time values. Verify adjustment and announcement with VoiceOver and Braille.

How to prove it is fixed: Verify explicit localized seek/speed names and meaningful increase/decrease labels in source, then check actual VoiceOver/Braille names, values and adjustment on device.

Classification: Needs Becky.

### BP-20261112-21 — P2: Button-free mode lacks accessible equivalents for its gestures

Status: outstanding; revalidates R21 from October 23.

Location: [BookPlayer/Player/Views/ButtonFree/ButtonFreeView.swift:64](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Player/Views/ButtonFree/ButtonFreeView.swift:64>).

Play/pause and directional functions are attached to raw container tap/drag gestures at 64–74. The only explicit accessibility action is Escape at 89–91; rewind, forward and bookmark creation have no named actions or equivalent keyboard-operable controls within this mode. VoiceOver directional navigation competes with those gestures.

Recommended correction: Expose named accessibility actions and operable alternatives while retaining gestures, and announce results. Validate VoiceOver, Switch Control and keyboard use.

How to prove it is fixed: Operate play/pause, rewind, forward and bookmark using VoiceOver actions, Switch Control and keyboard. Every command must be available and its result announced without relying on raw directional gestures.

Classification: Needs Becky.

### BP-20261112-22 — P2: Share extension silently drops files with duplicate names or copy failures

Status: outstanding; revalidates R22 from October 23.

Location: [BookPlayerShareExtension/ShareViewController.swift:199](</Users/becky/Developer/Swift/BookPlayer/BookPlayerShareExtension/ShareViewController.swift:199>).

Every selected URL is copied to sharedFolder using only lastPathComponent, with try? suppressing errors at 200. Two different files named chapter.mp3, or an existing pending shared file with that name, collide: the later copy fails, yet the extension advances and completes the request successfully at 190–193. Permission/storage errors are also silently treated as completion.

Recommended correction: Allocate collision-safe staging names, retain each selected file’s identity, and surface copy failures before completing the extension request. Do not silently replace or omit a selected input.

How to prove it is fixed: Use duplicate basenames, a preexisting staged filename and injected copy failures. Preserve every selected input or show an actionable failure before completion. Real share-sheet acceptance needs Becky.

Classification: Safe Alone.

## Existing device report and acceptance gaps

Start Testing already contains an open November 2 report: “Listen Together: sharing a book only the sharer has didn't work (TestFlight 5.22.2 (6))”, item dd0bde92-7e20-402d-b5ab-00fa8f984a0f. It reports successful own-copy listening but failure when only the sharer has the book; the failure stage is still unknown. This is an existing user report, not a new source-confirmed finding or proof of a particular cause. It was left unchanged and was not duplicated. Classification: Needs Becky. Reproduce with both phones, recording invitation, join, transfer and playback stages and VoiceOver status.

Session-ending, interruption recovery, own-copy chapter-boundary saving, late joining and disappearance grace behavior still need the relevant two-device acceptance. The October 28 automatic-rejoin change is present; this audit did not execute it. The historical passing test counts below and in Notes.md are not fresh evidence for this recheck.

The project still specifies Swift 5.0 in BookPlayer.xcodeproj/project.pbxproj (for example line 6190), with no explicit SWIFT_STRICT_CONCURRENCY setting found. Swift 6 language mode and Complete concurrency checking are not established. No build settings or source were changed; a separate migration remains necessary. Accessibility conformance and zero concurrency warnings are not claimed.

## Tracking and preservation

The outstanding findings are filed in Start Testing under Techopolis, LLC / BookPlayer - Listen together with their BP-20261112 IDs, verification steps and Safe Alone/Needs Becky classification. The project was searched first; its one existing temporary-copy report was not a duplicate of these findings. No existing status, assignment or comment was changed.

The prior review follows verbatim. Its status statements refer to its own October 23 snapshot.

# BookPlayer fork audit — October 23, 2026

## Scope and evidence

Branch: listen-together-6.0. Audited HEAD: 8cb2972534af4ba7a4bd112410d280748270319a. Tracked source was clean at audit start and at report preparation. The existing untracked review.md is replaced by this report, as requested. This is the only file written. No source edits, builds, tests, commits, device actions or Simulator actions were performed.

Three GPT-6 Astra reviewers with Medium reasoning examined UI/merge integration, SharePlay/playback, and data/persistence. The primary reviewer examined accounts, networking, integrations, extension imports and cross-checked the findings. Applied SwiftUI Pro, Swift Concurrency Pro, Swift Testing Pro and the parallel review workflow.

The merge was compared with both parents: first parent feb5066935121233c1767d75fc614d2844213563 and merged upstream develop a8e2cac72e312c4136dbd26d6822d565f4821660. References below point to current HEAD lines, not the old report. “Inherited” means present in the merged upstream or earlier baseline, not newly caused by Listen Together. No remote references were fetched.

Inventory: 620 production Swift files and approximately 96,224 lines across app, shared services, Watch, widgets and share extension. Coverage was a cross-feature source audit with targeted causal traces, not an exhaustive proof about every line or device configuration. Findings are source-confirmed failure paths; no runtime reproduction is claimed.

## Ranked findings: 22 total

P1 means high-priority playback integrity, crash or data-safety risk. P2 means a consequential functional, state or accessibility defect. There are 10 P1 findings and 12 P2 findings. Recommended repairs below were not implemented.

### R01 — P1: New Siri playback handler can split the shared session across two books

Location: [BookPlayer/Services/PlayMediaIntentHandler.swift:133](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Services/PlayMediaIntentHandler.swift:133>).

Provenance: Merge integration regression; 698698a3.

The newly installed INPlayMediaIntent handler calls loadAndKeepAlive directly, bypassing ListenTogetherIntentRouting. While sharing book A, a Siri suggestion or PlayMedia request for B therefore loads and plays B locally. The session still retains A’s path, UUID and manifest (SharePlaySessionService+Session.swift:40–49). SharerPlaybackTarget.handleIsPlaying at 366–381 emits the new play transition without checking holdsSharedBook, and the bridge coordinates it to listeners still holding A. The books can diverge within the same session. For a background listener, the ordinary start gate can instead refuse loading, but this handler ignores the returned Boolean and reports success at line 138.

Recommended correction: Apply the same startBook routing as the six App Intents before loading, preserve the sharer restriction, and return failure when the loader declines. Verify the real INPlayMedia entry point as both sharer and listener; router-only tests do not exercise this handler.

### R02 — P1: The merge removes the reachable video playback surface

Location: [BookPlayer/Player/Views/PlayerView.swift:201](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Player/Views/PlayerView.swift:201>).

Provenance: Merge regression; 698698a3 compared with its first parent.

The adaptive player now unconditionally constructs ArtworkView. Before the merge it selected VideoArtworkView when isVideoItem was true and refreshed video state on appearance. Video settings and the video view remain, but there are no remaining VideoArtworkView instantiations in the app. Enabling Show Video and loading video can therefore no longer display its video surface, full-screen control or hosted Picture in Picture entry.

Recommended correction: Restore the conditional video surface and appearance refresh within the adaptive layout. Check portrait, side-by-side, full-screen and Picture in Picture paths with video enabled.

### R03 — P1: A failed backup move is followed by permanent deletion

Location: [Shared/Services/LibraryService+Sync.swift:727](</Users/becky/Developer/Swift/BookPlayer/Shared/Services/LibraryService+Sync.swift:727>).

Provenance: Inherited from merged upstream; previous A02 remains.

createBackup suppresses move errors, while removeItems deep-deletes every original at line 666. If Backup already contains the same relative path, moving the current file fails and LibraryService.swift:1435 still deletes that current original. The older backup may contain different audio. Directory or storage errors have the same destructive continuation.

Recommended correction: Return backup success or failure, use collision-safe destinations, and permit destructive deletion only after confirming a recoverable backup of that specific item.

### R04 — P1: A former account’s list response can reconcile after logout

Location: [Shared/Services/Sync/SyncService.swift:361](</Users/becky/Developer/Swift/BookPlayer/Shared/Services/Sync/SyncService.swift:361>).

Provenance: Inherited from merged upstream; previous A04 remains in ordinary list refresh.

syncListContents waits for teardown before fetching, but captures no account/session generation and performs no check after fetchContents returns at 361–363. Logout at 763–778 can occur during that await. A delayed account A response then updates, inserts and removes local items through 440–445 after logout or login to B. Initial sync now guards its initial fetch result at 410–411, but that partial repair does not protect this ordinary refresh or the individual awaited reconciliation mutations.

Recommended correction: Carry a session generation through fetching and reconciliation, invalidate it on logout, and validate it before applying mutations. Exercise a delayed A response after switching to B.

### R05 — P1: Logout can miss a sync operation that has not yet entered its queue

Location: [Shared/Services/SyncQueue/SyncQueueService.swift:432](</Users/becky/Developer/Swift/BookPlayer/Shared/Services/SyncQueue/SyncQueueService.swift:432>).

Provenance: Newly identified in the merged upstream queue implementation.

enqueueNextTask checks whether server work is enabled at 338–349, then suspends on task lookup at 353 and again on MainActor publication at 432–434. Logout cancels only operations already in operationQueue at 255. If it runs in either gap, the captured operation is added afterward at 436 and was never cancelled. LibraryItemSyncOperation.main at 86–101 checks cancellation flags, not a session generation, and requests use the current token. Following a rapid account switch, a former account’s queued mutation can execute under the next account.

Recommended correction: Serialize queue admission with logout invalidation and give each operation a captured account generation checked before execution and completion effects. A Boolean check before another suspension is insufficient.

### R06 — P1: Import workers use main-context Core Data objects off their queue

Location: [BookPlayer/Import/Models/ImportOperation.swift:179](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Import/Models/ImportOperation.swift:179>).

Provenance: Inherited from merged upstream; previous A05 remains.

ImportManager enqueues these operations on OperationQueue at 100–101. hasExistingBook calls LibraryService.findBooks, whose fetch directly uses the main viewContext at LibraryService.swift:1674–1676, then dereferences the returned Book on the import worker. CoreDataStack.swift:17–18 confirms context ownership. Concurrent library changes can race this queue-confinement violation and cause a crash.

Recommended correction: Perform the fetch and URL extraction on the owning context, returning a value snapshot. Protecting only the fetch while returning a managed object for worker access does not fix ownership.

### R07 — P1: Failed ZIP extraction deletes its input archive

Location: [BookPlayer/Import/Models/ImportOperation.swift:124](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Import/Models/ImportOperation.swift:124>).

Provenance: Inherited from merged upstream; previous A06 remains.

The unzip completion removes the source before checking success at 124–129. A corrupt archive or failed extraction is discarded and the operation advances without preserving the input for retry. Unlike ordinary file-import cleanup, this path also lacks the isAppManagedSource restriction, so a writable external input can be removed.

Recommended correction: Preserve archives on failure, surface extraction errors, and remove only app-owned inputs after successful processing.

### R08 — P1: Queued chapter installation can resurrect obsolete playback

Location: [BookPlayer/Player/PlayerManager.swift:697](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Player/PlayerManager.swift:697>).

Provenance: Inherited implementation remains after the merge; previous A07 remains.

The load task has cancellation checks, but then escapes into an OperationQueue block and an independent main-queue closure at 697–724. The operation captures playerItem at 706, clears the active player off main at 717 and later installs the captured item at 724 without cancellation, generation or identity checks. A load of B or Stop between these steps cannot retract A’s queued installation. The subsequent initialization at 740–745 can combine stale audio/metadata with the latest currentItem. Stop cancels Swift tasks at 1693–1694, not these queued closures.

Recommended correction: Install the item on the playback owner’s actor with an exact load generation and item/chapter check. Invalidate pending installations when stopping or replacing a book; cancelling only the parent Swift task is insufficient.

### R09 — P1: Raw player-status callbacks mutate shared state without isolation

Location: [BookPlayer/Player/PlayerManager.swift:1549](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Player/PlayerManager.swift:1549>).

Provenance: Inherited design, expanded by the merged external-stream retry path.

The KVO handler checks only the status key path and AVPlayerItem type, then directly mutates observer/queued flags, starts reloads and clears playerItem at 1554–1615. It neither moves the whole transition onto the playback owner’s executor nor checks that the observed object is still owned. The file acknowledges the lack of guaranteed main-thread delivery at 609–620. These writes can race load/stop; a delayed callback can affect a replacement item. The external-stream retry at 1572–1581 uses the same unsafe path. The A01 end-of-item identity fix protects a different notification.

Recommended correction: Confine the entire status transition to one actor and revalidate the observed item and load generation there. Review observer registration/removal under the same ownership boundary.

### R10 — P1: Watch playback can resume after Pause or Stop during activation

Location: [BookPlayerWatch/LocalPlayback/Player/PlayerManager.swift:872](</Users/becky/Developer/Swift/BookPlayer/BookPlayerWatch/LocalPlayback/Player/PlayerManager.swift:872>).

Provenance: Inherited baseline defect, predating this merge.

The play task checks cancellation at 859 and then awaits audio-session activation at 872. Pause and Stop cancel it at 1058 and 1098, but no check follows activation: completion proceeds to bookmark work and playImmediately at 908 with the captured old book. The catch at 873–875 also reports activation failure and continues, including when cancellation throws.

Recommended correction: Return on activation failure and check cancellation plus the current playback generation/item after the await before changing playback or bookmarks. Exercise delayed activation followed by Pause, Stop and a different-book load.

### R11 — P2: Database backup can accept a stale or inconsistent SQLite snapshot

Location: [Shared/Services/DatabaseBackupService.swift:159](</Users/becky/Developer/Swift/BookPlayer/Shared/Services/DatabaseBackupService.swift:159>).

Provenance: Inherited from merged upstream; previous A09 remains.

The live SQLite database and WAL/SHM are copied separately at 159–175. Sidecar-copy errors are suppressed and success is returned. Missing committed WAL content can leave a readable but stale database, so opening it does not prove backup completeness. A checkpoint between copies also prevents a guaranteed coherent snapshot. Previous backups are then eligible for pruning.

Recommended correction: Use a supported consistent database snapshot operation, fail on required-copy errors, and retain prior backups until the new snapshot is validated.

### R12 — P2: An empty remote folder never clears its local contents

Location: [Shared/Services/Sync/SyncService.swift:421](</Users/becky/Developer/Swift/BookPlayer/Shared/Services/Sync/SyncService.swift:421>).

Provenance: Inherited from merged upstream; previous A10 remains.

processContentsResponse returns immediately when content is empty, including when canDelete is true. Deleting the last remote child therefore skips removal of all local entries, while syncListContents still advances its timestamp at 365–368. The library can retain deleted books indefinitely.

Recommended correction: Process a successful authoritative empty listing as an empty identifier set for reconciliation, distinct from a fetch or decoding failure.

### R13 — P2: Chapter refresh loses server identity and writes chapters to other books

Location: [Shared/Services/LibraryService.swift:3334](</Users/becky/Developer/Swift/BookPlayer/Shared/Services/LibraryService.swift:3334>).

Provenance: Newly identified in merged upstream media-server chapter refresh.

Providers group requests by server but merge their answers into a dictionary keyed only by providerId (MediaServerChapterProviding.swift:74–79). Ingest at 3334–3350 fetches every resource matching providerName and providerId, without hostId or an originating-resource restriction. Server A’s book can therefore populate a different book on server B with the same ID, even outside the refreshed folder. Both servers need not participate in that refresh. storeChaptersIfEmpty makes the incorrect result persistent.

Recommended correction: Preserve provider, resolved host and item identity throughout request results and ingest, and restrict writes to the originating resources. Cover overlapping IDs on two configured servers.

### R14 — P2: Download ownership is assigned after an await

Location: [BookPlayer/Services/SingleFileDownloadService.swift:91](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Services/SingleFileDownloadService.swift:91>).

Provenance: Inherited from merged upstream; previous A11 remains.

Two handleDownload calls can both observe currentTask == nil before networkClient.download returns. That function really suspends on session.allTasks (NetworkClient.swift:116). Both downloads start and the later assignment overwrites ownership at 104. Completion uses currentTask.folderName at 143 rather than metadata belonging to the completed task, so one download can enter the other destination. Delegate callbacks also read state written from MainActor without a single isolation boundary.

Recommended correction: Reserve the queue item before awaiting, isolate all queue state, and bind destination metadata to the actual URLSessionTask identity.

### R15 — P2: Login failure leaves backend and local account identities inconsistent

Location: [Shared/Services/Account/AccountService.swift:472](</Users/becky/Developer/Swift/BookPlayer/Shared/Services/Account/AccountService.swift:472>).

Provenance: Inherited from merged upstream; previous A12 remains.

Apple login stores the new backend token before awaiting throwing RevenueCat login at 479. Failure leaves that token active while local account identity remains old or anonymous. Passkey login at 500–504 and transferred credentials at 526–528 use the same ordering. Subsequent requests can use the newly stored token despite the failed-login result. Pending login also has no logout-generation invalidation.

Recommended correction: Stage identity changes or roll back credentials on failure, and reject stale completions after logout so backend, RevenueCat and local identity commit coherently.

### R16 — P2: Hardcover status tasks can commit in reverse order

Location: [BookPlayer/Hardcover/Network/HardcoverService.swift:341](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Hardcover/Network/HardcoverService.swift:341>).

Provenance: Inherited from merged upstream; previous A13 remains.

Progress and finish subscriptions launch independent tasks at 280 and 293. updateHardcoverStatus captures the current association/status at 334, then awaits the mutation and unconditionally stores the captured record with its requested status at 350–354. A reading update that completes after a read update can move the local status backward; server requests can also arrive out of order. An association changed while awaiting can likewise be overwritten.

Recommended correction: Serialize/coalesce changes per book and validate association/generation before committing. Preserve the newest intended status. The separate old missing-userBookID issue is fixed at 351–352.

### R17 — P2: Cancelled AudiobookShelf search can show an error or stale results

Location: [BookPlayer/AudiobookShelf/Library Screen/AudiobookShelfLibraryViewModel.swift:529](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/AudiobookShelf/Library Screen/AudiobookShelfLibraryViewModel.swift:529>).

Provenance: Inherited from merged upstream; previous A15 remains.

Query changes cancel the previous search, but the catch handles only CancellationError. IntegrationURLSessionClient directly forwards URLSession errors, including URLError.cancelled, into the general error branch at 545–546; IntegrationLibraryView.swift:69 presents it. There is also no query/generation check after the await before replacing results at 541–542. Normal rapid typing can therefore produce a cancellation alert or obsolete results.

Recommended correction: Suppress both cancellation forms and validate the current query/task generation before publishing results or errors.

### R18 — P2: An old fetch clears the replacement task’s handle

Location: [BookPlayer/Jellyfin/Library Screen/JellyfinLibraryViewModel.swift:346](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Jellyfin/Library Screen/JellyfinLibraryViewModel.swift:346>).

Provenance: Inherited from merged upstream; previous A16 remains.

Unconditional defer cleanup sets fetchTask to nil when an old task exits, even if another task has replaced it. The same pattern occurs at Jellyfin lines 282 and 318 and AudiobookShelf lines 392, 472 and 532. A’s cleanup can erase B’s ownership, defeating cancellation and fetchMore guards and allowing overlapping page requests or duplicate appends. Jellyfin’s new response guards do not fix handle ownership.

Recommended correction: Clear the handle only if the finishing operation still owns the active generation; keep pagination admission serialized.

### R19 — P2: Late bookmark loading can replace the new book’s list

Location: [BookPlayer/Player/Views/Bookmarks/BookmarksViewModel.swift:108](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Player/Views/Bookmarks/BookmarksViewModel.swift:108>).

Provenance: Inherited from merged upstream; previous A18 remains.

An independent request for A awaits syncBookmarksList and assigns userBookmarks at 115–116 without checking the current book or generation. Switching to B while A is pending lets A replace B’s displayed list. Selecting a stale bookmark calls jumpTo on the current player at 88, so B moves to A’s timestamp. The merged persistent side panel makes book changes while the list is mounted especially relevant.

Recommended correction: Invalidate superseded requests and check current book identity at publication and action time.

### R20 — P2: Playback sliders and speed buttons lack meaningful accessible names

Location: [BookPlayer/Player/Views/Controls/PlayerControlsSpeedSectionView.swift:51](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Player/Views/Controls/PlayerControlsSpeedSectionView.swift:51>).

Provenance: Inherited from merged upstream; previous A19 remains.

The speed slider at 51–55 supplies a value without a function name; the adjacent text is not associated with it. Decrease/increase buttons explicitly use emoji labels at 94 and 119. ListeningProgressView.swift:27–39 and SlickSlider.swift:82–114 also supply no explicit seek-function label. Screen-reader users receive insufficient purpose information. Actual announcements were not exercised.

Recommended correction: Provide localized Playback speed and Playback position names, meaningful increase/decrease labels, and appropriate speed/time values. Verify adjustment and announcement with VoiceOver and Braille.

### R21 — P2: Button-free mode lacks accessible equivalents for its gestures

Location: [BookPlayer/Player/Views/ButtonFree/ButtonFreeView.swift:64](</Users/becky/Developer/Swift/BookPlayer/BookPlayer/Player/Views/ButtonFree/ButtonFreeView.swift:64>).

Provenance: Inherited from merged upstream; previous A20 remains.

Play/pause and directional functions are attached to raw container tap/drag gestures at 64–74. The only explicit accessibility action is Escape at 89–91; rewind, forward and bookmark creation have no named actions or equivalent keyboard-operable controls within this mode. VoiceOver directional navigation competes with those gestures.

Recommended correction: Expose named accessibility actions and operable alternatives while retaining gestures, and announce results. Validate VoiceOver, Switch Control and keyboard use.

### R22 — P2: Share extension silently drops files with duplicate names or copy failures

Location: [BookPlayerShareExtension/ShareViewController.swift:199](</Users/becky/Developer/Swift/BookPlayer/BookPlayerShareExtension/ShareViewController.swift:199>).

Provenance: Newly identified inherited baseline defect; unchanged by the merge.

Every selected URL is copied to sharedFolder using only lastPathComponent, with try? suppressing errors at 200. Two different files named chapter.mp3, or an existing pending shared file with that name, collide: the later copy fails, yet the extension advances and completes the request successfully at 190–193. Permission/storage errors are also silently treated as completion.

Recommended correction: Allocate collision-safe staging names, retain each selected file’s identity, and surface copy failures before completing the extension request. Do not silently replace or omit a selected input.

## Requested commit verdicts

### Merge 698698a3

Confirmed regressions are the video surface removal (R02) and new INPlayMedia handler bypass (R01). The ordinary PlayerLoaderService start gate survives at lines 93–95, but it governs listener confirmation and does not replace the explicit sharer policy in ListenTogetherIntentRouting. MainView, MiniPlayerAccessoryView, the adaptive PlayerView, PlayerLoaderService and SettingsView were compared with the merge parents. No additional concrete Settings split-view regression was established.

Mini-player rewind and play/pause use the same normal-player calls as the full sharer controls; no distinct control-policy bypass was established there. The following UI concerns need acceptance checks rather than being counted as confirmed runtime failures:

- Transfer-sheet arbitration: ListenTogetherPresentation.swift:120–124 recognizes player and mediaServers covers but omits the newly tracked transferFromComputer cover. MainView.swift:78–98 clears that cover on dismissal. Joining while transfer is open can request listener presentation during dismissal. The missing blocker is source-confirmed; whether the system drops or recovers that presentation requires an actual run.
- Sharer status detail: MainView.swift:72–75 intentionally passes the constant sharerAccessoryValue. The former detailed row could show interruption, waiting-for-listeners, retry and pause reasons (ListenTogetherStatusRow.swift:119–138). Confirm that the simplified visible and spoken accessory status meets the persistent-status requirement, especially after closing the full player. This is an explicit design choice in current context, not silently classified here as an accidental code defect.
- Listener accessory text is capped at xxxLarge in MainView.swift:71. Verify its readability with Zoom and accessibility text sizes, full VoiceOver value, focus restoration after covers, and controls in narrow and side-by-side layouts. No contrast ratio or layout clipping failure was measured.

### Timer seams 3adbca24

The two edited scheduling seams now explicitly accept MainActor callbacks and execute them in MainActor tasks: ListenTogetherCoordinatorBridge.swift:51 and ListenerPlayer.swift:151. Their delayed readiness, buffering and rejoin callbacks retain invalidated/stopped/generation guards. No new behavioral defect was established in those edits.

This does not establish project-wide strict-concurrency correctness. A separate keepalive seam still uses an unannotated closure with DispatchQueue.main.asyncAfter at ListenTogetherCoordinatorBridge.swift:414–415, and the production adapter at SharePlaySessionService+Session.swift:529–533 has unannotated callback types. Compiler diagnostics were not run, so these are review follow-ups, not claimed build failures.

### Fix round four 22a100f3

- A01 is addressed in source: PlayerManager.swift:1832–1839 rejects end-of-item notifications for foreign or replaced items. This does not protect the separate KVO path in R09.
- A08 is addressed in source: PlayerManager.swift:1420–1443 reports activation failure and returns in all builds instead of calling fatalError. Recovery remains an explicit retry behavior.
- A17 remains addressed for the six App Intents that call ListenTogetherIntentRouting. The upstream-added INPlayMedia entry point is a separate integration gap, R01.
- Late joiners receive the sharer interruption state after manifest/map at SharePlaySessionService+Session.swift:1129–1142; lines 1013–1018 also accept the not-resumed state without requiring an earlier interruption message.

Source tests cover foreign-item completion, routing branches and interruption replay in PlayerManagerTests, ListenTogetherRemoteCommandsTests, ListenTogetherSessionEndTests and ListenTogetherMessagesTests. They do not prove real Siri invocation, GroupActivities delivery or assistive-technology behavior. Historical test counts in context.md were not rerun or independently certified by this audit.

## Earlier finding reconciliation

- Still open, revalidated here: old A02 → R03; A04 → R04; A05 → R06; A06 → R07; A07 → R08; A09 → R11; A10 → R12; A11 → R14; A12 → R15; A13 → R16; A15 → R17; A16 → R18; A18 → R19; A19 → R20; A20 → R21.
- Old A03 is addressed by current upload paths: NetworkClient.swift:146–154 validates artwork PUT status; the new PartUploadTransport passes response status and FileUploadOperation.swift:599–606 classifies multipart success. The old unfiltered single-upload completion path is no longer the active audio upload path.
- Old A14 is addressed: HardcoverService.swift:351–352 saves the returned userBookID. The independent ordering issue remains R16.
- Old A01 and A08 are addressed as described above. Old A17’s targeted intents are repaired, with the new entry-point regression recorded separately.
- Earlier SharePlay interruption/readiness/progress/rejoin/failure-attribution issues were not automatically carried forward. Current teardown invalidates the bridge before listener stop and own-copy restoration (SharePlaySessionService.swift:1377–1388); listener seek/delay paths use stale-work guards. No new confirmed own-copy or session-ending defect was established in the inspected paths.

## Coverage and acceptance gaps

- Playback and SharePlay: session start/end, late joiners, remote command ownership, interruptions, queue/readiness/failure paths, own-copy saving/restoration, normal/Watch playback and cancellation. Needed runtime evidence: last deliberate listener leave, sharer End for all, disappearance grace expiry, call/Siri/headphone interruptions, chapter-boundary own-copy progress and delayed Watch activation.
- UI and accessibility: main tab accessory, player adaptive layout/video integration, Settings split view, bookmarks, sliders, button-free mode and selected navigation/focus paths. Needed evidence: VoiceOver/Braille, Zoom, Dynamic Type, keyboard, Switch Control, measured contrast and cover presentation on supported devices. This is not a WCAG conformance certification.
- Data: import staging/ZIPs, duplicate detection, Core Data ownership, deletion, SQLite backup/restore, Core Data and SwiftData migrations, sync queue admission/execution and remote reconciliation. Needed evidence: failed backups, corrupt archives, account-switch response delays and queue admission interleavings. No additional migration-specific defect was established.
- Networking and integrations: uploads/downloads, account identity commit, Jellyfin/AudiobookShelf search/pagination, external stream/chapter lookup, Hardcover tracking and share-extension copy behavior. Needed evidence: reversed request completion, matching item IDs across servers and duplicate file names in extension input.
- System surfaces: App Intents, INPlayMedia, widget playback entry, selected Watch paths, video/PiP reachability and import extension. CarPlay, every widget variant and every integration/auth screen were not exhaustively exercised or inspected.

## Project standards requiring a separate implementation pass

The project file explicitly sets SWIFT_VERSION = 5.0 (for example BookPlayer.xcodeproj/project.pbxproj:6190), and no explicit SWIFT_STRICT_CONCURRENCY or default-actor-isolation setting was found there. Swift 6 language mode with Complete checking is not established. Plan that migration separately, then resolve diagnostics through ownership and isolation rather than suppressions. No settings were changed and no zero-warning build is claimed.

Several production files exceed the requested 700-line limit, including normal PlayerManager (1,994), Watch PlayerManager (1,380), SharePlaySessionService (1,729), its Session extension (1,785) and ListenerPlayer (1,035). They were not split during this read-only audit. Dead-code removal was also not attempted; the unreachable video surface is reported as a lost feature to restore, not presumed disposable code.

Prioritize R01–R10 before release because they affect playback integrity, crashes or data safety. Preserve the source/runtime evidence distinction when evaluating the remaining findings and the specified multi-device acceptance checks.
