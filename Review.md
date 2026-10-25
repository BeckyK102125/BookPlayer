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
