# SharePlay "Listen Together" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let people on a FaceTime call listen to a BookPlayer audiobook together, in sync, where only the sharer has the book; the sharer's app sends it in pieces under 100 MB and listeners' copies are deleted afterwards.

**Architecture:** A new `BookPlayer/BookPlayer/SharePlay/` feature folder in the app target. Timing is synced by `AVDelegatingPlaybackCoordinator` on an abstract "book time" timeline, so `PlayerManager.swift` is never modified: the sharer is driven through `PlayerManagerProtocol`, the listener through a separate `ListenerPlayer`. Files travel through `GroupSessionJournal`; small control messages through `GroupSessionMessenger`. All SharePlay framework calls sit behind a `ListenTogetherTransport` protocol so the session logic is unit-testable with a fake.

**Tech Stack:** Swift, SwiftUI, Combine, GroupActivities (iOS 17+ journal), AVFoundation (`AVDelegatingPlaybackCoordinator`, `AVAssetExportSession`), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-10-shareplay-listen-together-design.md`

## Global Constraints

- Deployment target is iOS 18.0 (already set). No availability checks needed for iOS 17 APIs.
- **Never modify `BookPlayer/Player/PlayerManager.swift`.** Drive it only through `PlayerManagerProtocol`.
- All new code in `BookPlayer/BookPlayer/SharePlay/` (app target `BookPlayer` only). Nothing in `Shared/`.
- Pieces must be **under 90 MB** (`ListenTogetherLimits.maxPieceBytes = 90_000_000`); the hard SharePlay limit is 100 MB.
- Listener files live only in `FileManager.default.temporaryDirectory/ListenTogether/`; deleted at session end and at next launch.
- Tests are **XCTest only** (project rule). New test files go in `BookPlayerTests/SharePlay/`.
- Every user-facing string uses `"key".localized`; new keys go in `BookPlayer/Base.lproj/Localizable.strings`.
- New SwiftUI text uses `bpFont(_:)` (Dynamic Type), never fixed sizes. Every control has an `accessibilityLabel`; stateful ones an `accessibilityValue`.
- `@MainActor` for services and view models; `[weak self]` in sinks; long-lived subscriptions in `disposeBag`.
- Announcements are queued (`.accessibilitySpeechQueueAnnouncement`), announce **remote** actions only, and download progress only at 25 percent steps.
- Do not commit `BuildConfiguration/Debug.xcconfig` (gitignored, may hold secrets).
- Builds use Xcode's default DerivedData: **never pass `-derivedDataPath`** (Becky's global rule).
- Branch: `shareplay-listen-together`. Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Echo loops:** applying a remote pause on the sharer makes `PlayerManager` publish `isPlaying = false`, which must not be reported back to the coordinator as a new local pause. Test: Task 6 `testRemotePauseIsNotEchoed`.
2. **Seek into a piece that hasn't arrived:** the listener must hold everyone (suspension) instead of playing silence or crashing. Test: Task 7 `testSeekToMissingPieceBeginsSuspension`.
3. **Late joiner:** someone who joins after the manifest was sent must still receive it and all pieces. Test: Task 9 `testManifestResentWhenParticipantsIncrease`.
4. **Book without local files** (streamed AudiobookShelf/Jellyfin/cloud-only) or video: "Listen Together" must not appear rather than fail mid-session. Test: Task 10 `testStreamedBookIsNotShareable`.
5. **Session ends mid-download or the app is killed:** temp files must not leak. Test: Task 2 `testCleanAllRemovesEverything` and Task 9 `testInvalidationDeletesListenerFiles`.

---

## File Structure

| File | Responsibility |
|---|---|
| `BookPlayer/BookPlayer/SharePlay/ListenTogetherModels.swift` | Codable value types: manifest, chapters, pieces, messages, remote actions, limits |
| `BookPlayer/BookPlayer/SharePlay/ListenTogetherActivity.swift` | The `GroupActivity` |
| `BookPlayer/BookPlayer/SharePlay/ShareStorage.swift` | Temporary folders and cleanup |
| `BookPlayer/BookPlayer/SharePlay/PiecePlanner.swift` | Pure: decides piece cut points from file sizes, durations and chapters |
| `BookPlayer/BookPlayer/SharePlay/BookSplitter.swift` | Exports planned pieces to files (AVFoundation) |
| `BookPlayer/BookPlayer/SharePlay/PieceTimeline.swift` | Pure: book time ↔ (piece, offset); which pieces arrived |
| `BookPlayer/BookPlayer/SharePlay/ListenTogetherPlaybackTarget.swift` | Protocol both sides implement + `LocalPlaybackEvent` |
| `BookPlayer/BookPlayer/SharePlay/SharerPlaybackTarget.swift` | Wraps `PlayerManagerProtocol`; detects local changes; echo suppression |
| `BookPlayer/BookPlayer/SharePlay/ListenerPlayer.swift` | Listener's own `AVPlayer`, audio session, route/interruption handling |
| `BookPlayer/BookPlayer/SharePlay/ListenTogetherCoordinatorBridge.swift` | `AVDelegatingPlaybackCoordinator` delegate |
| `BookPlayer/BookPlayer/SharePlay/ListenTogetherAnnouncer.swift` | Announcement text + queued posting + progress buckets |
| `BookPlayer/BookPlayer/SharePlay/ListenTogetherTransport.swift` | Transport protocol + `GroupSessionTransport` (real) |
| `BookPlayer/BookPlayer/SharePlay/SharePlaySessionService.swift` | State machine: start, join, send/receive pieces, end, cleanup |
| `BookPlayer/BookPlayer/SharePlay/Views/ListenTogetherBanner.swift` | Status banner + End button in the player |
| `BookPlayer/BookPlayer/SharePlay/Views/ListenerPlayerView.swift` | Listener's full screen player |
| `BookPlayer/BookPlayer/SharePlay/Views/ListenTogetherInvitationView.swift` | "Join Listen Together" prompt |
| Modify `BookPlayer/BookPlayer.entitlements`, `BookPlayer/BookPlayer-NoCarPlay.entitlements`, `BookPlayer/Info.plist` | Capability |
| Modify `BookPlayer/Player/ViewModels/PlayerViewModel.swift` (`setMoreAlert`, init) | "Listen Together" More-menu item |
| Modify `BookPlayer/Player/Views/PlayerView.swift` | Show banner |
| Modify `BookPlayer/Coordinators/MainCoordinator.swift`, `BookPlayer/MainView.swift` | Create/inject service, listener cover |
| Modify `BookPlayer/Base.lproj/Localizable.strings` | Strings |
| Tests in `BookPlayerTests/SharePlay/` | One file per unit above |
| Create `context.md`, `Notes.md` at repo root | Becky's project-memory convention |

---

### Task 0: Tooling, capability and a green baseline build

**Files:**
- Create: `/private/tmp/bp-tools/add_to_xcodeproj.py` (not committed)
- Modify: `BookPlayer/BookPlayer.entitlements`, `BookPlayer/BookPlayer-NoCarPlay.entitlements`, `BookPlayer/Info.plist`
- Create: `context.md`, `Notes.md`

**Interfaces:**
- Produces: the helper command `/private/tmp/bp-tools/venv/bin/python /private/tmp/bp-tools/add_to_xcodeproj.py <target> <group-path> <file>...` used by every later task to register new files (the project uses classic groups, objectVersion 54, so new files are NOT picked up automatically).

- [ ] **Step 1: Create the project-editing helper**

```bash
python3 -m venv /private/tmp/bp-tools/venv
/private/tmp/bp-tools/venv/bin/pip install --quiet pbxproj==4.2.1
```

`/private/tmp/bp-tools/add_to_xcodeproj.py`:
```python
#!/usr/bin/env python3
"""Usage: add_to_xcodeproj.py <target> <group/path/in/project> <file> [<file>...]
Adds files (repo-relative paths) to a group (created if missing) and to one target's build phase."""
import sys, os
from pbxproj import XcodeProject
from pbxproj.pbxextensions import FileOptions

target, group_path, files = sys.argv[1], sys.argv[2], sys.argv[3:]
project = XcodeProject.load('BookPlayer.xcodeproj/project.pbxproj')
parent = None
for name in group_path.split('/'):
    parent = project.get_or_create_group(name, parent=parent)
for f in files:
    existing = project.get_files_by_path(os.path.abspath(f)) or project.get_files_by_name(os.path.basename(f), parent=parent)
    if existing:
        print(f'skip (already in project): {f}')
        continue
    project.add_file(os.path.abspath(f), parent=parent, target_name=target, force=False,
                     file_options=FileOptions(create_build_files=True))
    print(f'added: {f}')
project.save()
```

Note: `get_or_create_group` matches by group *name*. Before first use, run
`grep -n "path = BookPlayer;\|name = BookPlayer;" BookPlayer.xcodeproj/project.pbxproj | head` and confirm the
app source group is named `BookPlayer`; if the top group has two `BookPlayer` groups (outer folder and nested app
folder), pass `BookPlayer/BookPlayer/SharePlay` and check the result in Step 6.

- [ ] **Step 2: Add the Group Activities capability**

In both `BookPlayer/BookPlayer.entitlements` and `BookPlayer/BookPlayer-NoCarPlay.entitlements`, add inside `<dict>`:
```xml
	<key>com.apple.developer.group-session</key>
	<true/>
```
In `BookPlayer/Info.plist`, add inside the top `<dict>` (next to `UIBackgroundModes`):
```xml
	<key>NSSupportsGroupActivities</key>
	<true/>
```

- [ ] **Step 3: Local build config (not committed)**

```bash
[ -f BuildConfiguration/Debug.xcconfig ] || cp BuildConfiguration/Debug.template.xcconfig BuildConfiguration/Debug.xcconfig
git status --short BuildConfiguration   # must show nothing (Debug.xcconfig is gitignored)
```

- [ ] **Step 4: Baseline build and tests**

```bash
xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan "Unit Tests" \
  -only-testing:BookPlayerTests build-for-testing 2>&1 | tail -5
xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan "Unit Tests" \
  -only-testing:BookPlayerTests test-without-building 2>&1 | grep -E "Executed|FAIL|error:" | tail -5
```
Expected: `** TEST BUILD SUCCEEDED **`, then `Executed N tests, with 0 failures`. Record N in `Notes.md`. If any test fails on the untouched branch, record which ones as pre-existing and do not fix them.

- [ ] **Step 5: Create `context.md` and `Notes.md`**

`context.md` (rewrite in place over time, ≤150 lines): date, goal (this plan), branch `shareplay-listen-together` from upstream `develop` eb19a92f, fork `BeckyK102125/BookPlayer` (origin) and `TortugaPower/BookPlayer` (upstream), baseline test count, next step = Task 1, decisions waiting on Becky (push to GitHub: not yet; signing team and bundle ID for device testing).
`Notes.md` (append-only): a dated entry for the fork, spec, plan and baseline results.

- [ ] **Step 6: Commit**

```bash
git add BookPlayer/BookPlayer.entitlements BookPlayer/BookPlayer-NoCarPlay.entitlements BookPlayer/Info.plist context.md Notes.md docs/superpowers
git commit -m "SharePlay: add Group Activities capability, plan and project notes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 1: Models and the GroupActivity

**Files:**
- Create: `BookPlayer/BookPlayer/SharePlay/ListenTogetherModels.swift`, `BookPlayer/BookPlayer/SharePlay/ListenTogetherActivity.swift`
- Test: `BookPlayerTests/SharePlay/ListenTogetherModelsTests.swift`

**Interfaces:**
- Produces: `ListenTogetherLimits.maxPieceBytes: Int64`, `SharedChapter`, `SharedPiece`, `SharedBookManifest`, `RemoteAction`, `ListenTogetherMessage`, `ListenTogetherActivity(shareID:title:author:)`.

- [ ] **Step 1: Write the failing test**

```swift
@testable import BookPlayer
import XCTest

final class ListenTogetherModelsTests: XCTestCase {
  private func sampleManifest() -> SharedBookManifest {
    SharedBookManifest(
      shareID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      title: "Moby Dick", author: "Herman Melville", duration: 7200,
      chapters: [SharedChapter(title: "Loomings", start: 0, duration: 3600),
                 SharedChapter(title: "The Carpet-Bag", start: 3600, duration: 3600)],
      pieces: [SharedPiece(index: 0, bookStart: 0, duration: 3600, byteSize: 50_000_000),
               SharedPiece(index: 1, bookStart: 3600, duration: 3600, byteSize: 50_000_000)]
    )
  }

  func testMessagesRoundTrip() throws {
    let messages: [ListenTogetherMessage] = [
      .manifest(sampleManifest()),
      .pieceUploaded(index: 1, attachmentID: UUID(uuidString: "AAAAAAAA-2222-3333-4444-555555555555")!),
      .action(.paused), .action(.resumed), .action(.skipped(seconds: -30)),
      .action(.movedToChapter(title: "Loomings")), .action(.speedChanged(rate: 1.5)),
      .sessionEnding,
    ]
    for message in messages {
      let data = try JSONEncoder().encode(message)
      XCTAssertEqual(try JSONDecoder().decode(ListenTogetherMessage.self, from: data), message)
    }
  }

  func testChapterLookup() {
    let manifest = sampleManifest()
    XCTAssertEqual(manifest.chapter(at: 10)?.title, "Loomings")
    XCTAssertEqual(manifest.chapter(at: 3600)?.title, "The Carpet-Bag")
    XCTAssertNil(manifest.chapter(at: 9000))
  }

  func testPieceLimitIsUnderSharePlayLimit() {
    XCTAssertLessThan(ListenTogetherLimits.maxPieceBytes, 100_000_000)
  }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
mkdir -p BookPlayerTests/SharePlay BookPlayer/BookPlayer/SharePlay
# (create the test file above first)
/private/tmp/bp-tools/venv/bin/python /private/tmp/bp-tools/add_to_xcodeproj.py BookPlayerTests BookPlayerTests/SharePlay BookPlayerTests/SharePlay/ListenTogetherModelsTests.swift
xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan "Unit Tests" -only-testing:BookPlayerTests/ListenTogetherModelsTests test 2>&1 | grep -E "error:|Executed" | head
```
Expected: compile error `cannot find 'SharedBookManifest' in scope`.

- [ ] **Step 3: Implement**

`ListenTogetherModels.swift`:
```swift
import Foundation

enum ListenTogetherLimits {
  /// SharePlay journal attachments are capped at 100 MB; keep a margin.
  static let maxPieceBytes: Int64 = 90_000_000
}

struct SharedChapter: Codable, Equatable {
  let title: String
  let start: TimeInterval
  let duration: TimeInterval
  var end: TimeInterval { start + duration }
}

struct SharedPiece: Codable, Equatable {
  let index: Int
  /// Where this piece starts on the book timeline, in seconds.
  let bookStart: TimeInterval
  let duration: TimeInterval
  let byteSize: Int64
  var bookEnd: TimeInterval { bookStart + duration }
}

struct SharedBookManifest: Codable, Equatable {
  let shareID: UUID
  let title: String
  let author: String
  let duration: TimeInterval
  let chapters: [SharedChapter]
  var pieces: [SharedPiece]

  func chapter(at bookTime: TimeInterval) -> SharedChapter? {
    chapters.first { bookTime >= $0.start && bookTime < $0.end }
  }
}

enum RemoteAction: Codable, Equatable {
  case paused
  case resumed
  case skipped(seconds: Int)
  case movedToChapter(title: String)
  case speedChanged(rate: Float)
}

enum ListenTogetherMessage: Codable, Equatable {
  case manifest(SharedBookManifest)
  case pieceUploaded(index: Int, attachmentID: UUID)
  case action(RemoteAction)
  case sessionEnding
}
```

`ListenTogetherActivity.swift`:
```swift
import GroupActivities

struct ListenTogetherActivity: GroupActivity {
  let shareID: UUID
  let title: String
  let author: String

  var metadata: GroupActivityMetadata {
    var metadata = GroupActivityMetadata()
    metadata.title = String.localizedStringWithFormat("listen_together_activity_title".localized, title)
    metadata.subtitle = author
    metadata.type = .listenTogether
    return metadata
  }
}
```
Add to `BookPlayer/Base.lproj/Localizable.strings`:
```
"listen_together_activity_title" = "Listen to %@";
```
Register both source files:
```bash
/private/tmp/bp-tools/venv/bin/python /private/tmp/bp-tools/add_to_xcodeproj.py BookPlayer BookPlayer/BookPlayer/SharePlay BookPlayer/BookPlayer/SharePlay/ListenTogetherModels.swift BookPlayer/BookPlayer/SharePlay/ListenTogetherActivity.swift
```

- [ ] **Step 4: Run tests — expect PASS** (same command as Step 2; `Executed 3 tests, with 0 failures`).

- [ ] **Step 5: Commit** (`git add` the four files + strings + `BookPlayer.xcodeproj/project.pbxproj`; message `SharePlay: add Listen Together models and activity`).

---

### Task 2: Temporary storage and cleanup

**Files:**
- Create: `BookPlayer/BookPlayer/SharePlay/ShareStorage.swift`
- Test: `BookPlayerTests/SharePlay/ShareStorageTests.swift`

**Interfaces:**
- Produces: `struct ShareStorage { init(root: URL = ShareStorage.defaultRoot); func folder(for shareID: UUID, role: Role) throws -> URL; func remove(shareID: UUID); func cleanAll(); enum Role: String { case sharer, listener }; static var defaultRoot: URL }`.

- [ ] **Step 1: Write the failing test**

```swift
@testable import BookPlayer
import XCTest

final class ShareStorageTests: XCTestCase {
  private var root: URL!
  override func setUp() {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ShareStorageTests-\(UUID())")
  }
  override func tearDown() { try? FileManager.default.removeItem(at: root) }

  func testFolderIsCreatedPerShareAndRole() throws {
    let storage = ShareStorage(root: root)
    let id = UUID()
    let listener = try storage.folder(for: id, role: .listener)
    let sharer = try storage.folder(for: id, role: .sharer)
    XCTAssertNotEqual(listener, sharer)
    XCTAssertTrue(FileManager.default.fileExists(atPath: listener.path))
  }

  func testRemoveDeletesOnlyThatShare() throws {
    let storage = ShareStorage(root: root)
    let a = UUID(), b = UUID()
    let folderA = try storage.folder(for: a, role: .listener)
    let folderB = try storage.folder(for: b, role: .listener)
    try Data([1]).write(to: folderA.appendingPathComponent("piece-0.m4a"))
    storage.remove(shareID: a)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folderA.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: folderB.path))
  }

  func testCleanAllRemovesEverything() throws {
    let storage = ShareStorage(root: root)
    try Data([1]).write(to: try storage.folder(for: UUID(), role: .sharer).appendingPathComponent("x"))
    storage.cleanAll()
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }
}
```

- [ ] **Step 2: Register test file, run, expect compile failure** (`cannot find 'ShareStorage'`).

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Temporary files for Listen Together. Nothing here is part of the user's library.
struct ShareStorage {
  enum Role: String { case sharer, listener }

  static var defaultRoot: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ListenTogether", isDirectory: true)
  }

  let root: URL

  init(root: URL = ShareStorage.defaultRoot) {
    self.root = root
  }

  func folder(for shareID: UUID, role: Role) throws -> URL {
    let url = root
      .appendingPathComponent(role.rawValue, isDirectory: true)
      .appendingPathComponent(shareID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func remove(shareID: UUID) {
    for role in [Role.sharer, .listener] {
      let url = root.appendingPathComponent(role.rawValue).appendingPathComponent(shareID.uuidString)
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Called at launch: no session can be active then, so anything left over is stale.
  func cleanAll() {
    try? FileManager.default.removeItem(at: root)
  }
}
```

- [ ] **Step 4: Register source, run tests, expect PASS (3 tests).**
- [ ] **Step 5: Commit** (`SharePlay: add temporary share storage`).

---

### Task 3: Piece planning (pure logic)

**Files:**
- Create: `BookPlayer/BookPlayer/SharePlay/PiecePlanner.swift`
- Test: `BookPlayerTests/SharePlay/PiecePlannerTests.swift`

**Interfaces:**
- Consumes: `ListenTogetherLimits.maxPieceBytes`.
- Produces:
  - `struct SourceFile: Equatable { let url: URL; let bookStart: TimeInterval; let duration: TimeInterval; let byteSize: Int64 }`
  - `struct PlannedPiece: Equatable { let index: Int; let sourceIndex: Int; let sourceStart: TimeInterval; let duration: TimeInterval; let bookStart: TimeInterval; let isWholeFile: Bool; let estimatedBytes: Int64 }`
  - `enum PiecePlanner { static func plan(files: [SourceFile], chapterStarts: [TimeInterval], maxBytes: Int64 = ListenTogetherLimits.maxPieceBytes) -> [PlannedPiece] }`
  - `extension Array where Element == PlannedPiece { func uploadOrder(startingAt bookTime: TimeInterval) -> [PlannedPiece] }` — the piece containing `bookTime` first, then later pieces, then earlier ones.

- [ ] **Step 1: Write the failing tests**

```swift
@testable import BookPlayer
import XCTest

final class PiecePlannerTests: XCTestCase {
  private let url = URL(fileURLWithPath: "/tmp/book.m4b")

  func testSmallFileIsOneWholePiece() {
    let pieces = PiecePlanner.plan(
      files: [SourceFile(url: url, bookStart: 0, duration: 600, byteSize: 5_000_000)],
      chapterStarts: [0, 300])
    XCTAssertEqual(pieces.count, 1)
    XCTAssertTrue(pieces[0].isWholeFile)
    XCTAssertEqual(pieces[0].duration, 600)
  }

  func testLargeFileCutsOnChapterBoundaries() {
    // 10 h, 280 MB → ~7.8 KB/s; chapters every hour (~28 MB each) → pieces of 3 chapters (~84 MB).
    let pieces = PiecePlanner.plan(
      files: [SourceFile(url: url, bookStart: 0, duration: 36_000, byteSize: 280_000_000)],
      chapterStarts: stride(from: 0.0, to: 36_000, by: 3600).map { $0 })
    XCTAssertEqual(pieces.map(\.bookStart), [0, 10_800, 21_600, 32_400])
    XCTAssertTrue(pieces.allSatisfy { $0.estimatedBytes <= ListenTogetherLimits.maxPieceBytes })
    XCTAssertEqual(pieces.last.map { $0.bookStart + $0.duration }, 36_000)
  }

  func testChapterLargerThanLimitIsSplitEvenly() {
    // One 200 MB file with a single chapter → 3 equal pieces.
    let pieces = PiecePlanner.plan(
      files: [SourceFile(url: url, bookStart: 0, duration: 3000, byteSize: 200_000_000)],
      chapterStarts: [0])
    XCTAssertEqual(pieces.count, 3)
    XCTAssertEqual(pieces[1].bookStart, 1000, accuracy: 0.001)
    XCTAssertTrue(pieces.allSatisfy { $0.estimatedBytes <= ListenTogetherLimits.maxPieceBytes })
  }

  func testMultiFileBookKeepsBookTimeAndIndexes() {
    let a = URL(fileURLWithPath: "/tmp/01.mp3"), b = URL(fileURLWithPath: "/tmp/02.mp3")
    let pieces = PiecePlanner.plan(
      files: [SourceFile(url: a, bookStart: 0, duration: 1200, byteSize: 20_000_000),
              SourceFile(url: b, bookStart: 1200, duration: 1500, byteSize: 25_000_000)],
      chapterStarts: [0, 1200])
    XCTAssertEqual(pieces.map(\.index), [0, 1])
    XCTAssertEqual(pieces.map(\.sourceIndex), [0, 1])
    XCTAssertEqual(pieces[1].bookStart, 1200)
    XCTAssertEqual(pieces[1].sourceStart, 0)
  }

  func testUploadOrderStartsAtCurrentPiece() {
    let pieces = PiecePlanner.plan(
      files: [SourceFile(url: url, bookStart: 0, duration: 36_000, byteSize: 280_000_000)],
      chapterStarts: stride(from: 0.0, to: 36_000, by: 3600).map { $0 })
    XCTAssertEqual(pieces.uploadOrder(startingAt: 15_000).map(\.index), [1, 2, 3, 0])
  }
}
```

- [ ] **Step 2: Register, run, expect compile failure.**

- [ ] **Step 3: Implement**

```swift
import Foundation

struct SourceFile: Equatable {
  let url: URL
  let bookStart: TimeInterval
  let duration: TimeInterval
  let byteSize: Int64
}

struct PlannedPiece: Equatable {
  let index: Int
  let sourceIndex: Int
  /// Offset inside the source file, in seconds.
  let sourceStart: TimeInterval
  let duration: TimeInterval
  let bookStart: TimeInterval
  let isWholeFile: Bool
  let estimatedBytes: Int64
}

enum PiecePlanner {
  static func plan(
    files: [SourceFile],
    chapterStarts: [TimeInterval],
    maxBytes: Int64 = ListenTogetherLimits.maxPieceBytes
  ) -> [PlannedPiece] {
    var result: [PlannedPiece] = []
    for (sourceIndex, file) in files.enumerated() {
      guard file.duration > 0 else { continue }
      let bytesPerSecond = Double(file.byteSize) / file.duration

      if file.byteSize <= maxBytes {
        result.append(PlannedPiece(
          index: result.count, sourceIndex: sourceIndex, sourceStart: 0, duration: file.duration,
          bookStart: file.bookStart, isWholeFile: true, estimatedBytes: file.byteSize))
        continue
      }

      // Candidate cut points: chapter starts inside this file, in file-relative seconds.
      let fileEnd = file.bookStart + file.duration
      let cuts = chapterStarts
        .filter { $0 > file.bookStart && $0 < fileEnd }
        .map { $0 - file.bookStart }
        .sorted() + [file.duration]

      var pieceStart: TimeInterval = 0
      var lastGoodCut: TimeInterval?
      var segments: [(TimeInterval, TimeInterval)] = []

      func bytes(_ start: TimeInterval, _ end: TimeInterval) -> Double { (end - start) * bytesPerSecond }

      for cut in cuts {
        if bytes(pieceStart, cut) <= Double(maxBytes) {
          lastGoodCut = cut
          continue
        }
        if let good = lastGoodCut {
          segments.append((pieceStart, good))
          pieceStart = good
          lastGoodCut = nil
          if bytes(pieceStart, cut) <= Double(maxBytes) {
            lastGoodCut = cut
            continue
          }
        }
        // A single chapter span is too big: split it evenly.
        let parts = Int(ceil(bytes(pieceStart, cut) / Double(maxBytes)))
        let step = (cut - pieceStart) / Double(parts)
        for part in 0..<parts {
          let start = pieceStart + Double(part) * step
          segments.append((start, part == parts - 1 ? cut : start + step))
        }
        pieceStart = cut
        lastGoodCut = nil
      }
      if let good = lastGoodCut, good > pieceStart {
        segments.append((pieceStart, good))
      }

      for (start, end) in segments {
        result.append(PlannedPiece(
          index: result.count, sourceIndex: sourceIndex, sourceStart: start, duration: end - start,
          bookStart: file.bookStart + start, isWholeFile: false,
          estimatedBytes: Int64(bytes(start, end).rounded(.up))))
      }
    }
    return result
  }
}

extension Array where Element == PlannedPiece {
  func uploadOrder(startingAt bookTime: TimeInterval) -> [PlannedPiece] {
    guard let first = firstIndex(where: { bookTime >= $0.bookStart && bookTime < $0.bookStart + $0.duration })
    else { return self }
    return Array(self[first...] + self[..<first])
  }
}
```

- [ ] **Step 4: Run tests — expect PASS (5 tests).** If `testLargeFileCutsOnChapterBoundaries` fails on exact values, print `pieces` and check the arithmetic before changing the test: 3 chapters × 28 MB = 84 MB fits, 4 × 28 = 112 MB doesn't, so cuts at 0, 3 h, 6 h, 9 h are correct.
- [ ] **Step 5: Commit** (`SharePlay: plan book pieces under the SharePlay size limit`).

---

### Task 4: Book splitter (AVFoundation export)

**Files:**
- Create: `BookPlayer/BookPlayer/SharePlay/BookSplitter.swift`
- Test: `BookPlayerTests/SharePlay/BookSplitterTests.swift`, helper `BookPlayerTests/SharePlay/AudioFixture.swift`

**Interfaces:**
- Consumes: `SourceFile`, `PlannedPiece`, `PiecePlanner`, `SharedPiece`.
- Produces:
  - `enum BookSplitterError: Error, Equatable { case noLocalFile, exportFailed(index: Int), pieceTooLarge(index: Int) }`
  - `struct BookSplitter { func sourceFiles(for item: PlayableItem) throws -> [SourceFile]; func export(_ piece: PlannedPiece, from files: [SourceFile], to folder: URL) async throws -> (url: URL, shared: SharedPiece) }`
  - `static func isShareable(_ item: PlayableItem) -> Bool` (every chapter's local file exists and none is video).

- [ ] **Step 1: Test fixture that writes a real short AAC file**

`AudioFixture.swift`:
```swift
import AVFoundation

enum AudioFixture {
  /// Writes `seconds` of a quiet 440 Hz tone as AAC in an .m4a file.
  static func makeM4A(seconds: Double, at url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                   AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = AVAudioFrameCount(seconds * 44_100)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let samples = buffer.floatChannelData![0]
    for i in 0..<Int(frames) { samples[i] = 0.1 * sinf(Float(i) * 2 * .pi * 440 / 44_100) }
    try file.write(from: buffer)
  }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
@testable import BookPlayer
import AVFoundation
import XCTest

final class BookSplitterTests: XCTestCase {
  private var folder: URL!
  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("BookSplitterTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  override func tearDown() { try? FileManager.default.removeItem(at: folder) }

  func testExportsTimeRangeAsPlayableFile() async throws {
    let source = folder.appendingPathComponent("source.m4a")
    try AudioFixture.makeM4A(seconds: 20, at: source)
    let size = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as! Int64
    let file = SourceFile(url: source, bookStart: 100, duration: 20, byteSize: size)
    let piece = PlannedPiece(index: 1, sourceIndex: 0, sourceStart: 10, duration: 10, bookStart: 110,
                             isWholeFile: false, estimatedBytes: size / 2)

    let (url, shared) = try await BookSplitter().export(piece, from: [file], to: folder)

    let duration = try await AVURLAsset(url: url).load(.duration).seconds
    XCTAssertEqual(duration, 10, accuracy: 0.5)
    XCTAssertEqual(shared.index, 1)
    XCTAssertEqual(shared.bookStart, 110)
    XCTAssertLessThanOrEqual(shared.byteSize, ListenTogetherLimits.maxPieceBytes)
  }

  func testWholeFilePieceIsCopiedNotReencoded() async throws {
    let source = folder.appendingPathComponent("whole.m4a")
    try AudioFixture.makeM4A(seconds: 5, at: source)
    let size = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as! Int64
    let piece = PlannedPiece(index: 0, sourceIndex: 0, sourceStart: 0, duration: 5, bookStart: 0,
                             isWholeFile: true, estimatedBytes: size)
    let (url, shared) = try await BookSplitter().export(
      piece, from: [SourceFile(url: source, bookStart: 0, duration: 5, byteSize: size)], to: folder)
    XCTAssertEqual(shared.byteSize, size)
    XCTAssertNotEqual(url, source)
  }
}
```

- [ ] **Step 3: Register files, run, expect compile failure.**

- [ ] **Step 4: Implement**

```swift
import AVFoundation
import BookPlayerKit
import Foundation

enum BookSplitterError: Error, Equatable {
  case noLocalFile
  case exportFailed(index: Int)
  case pieceTooLarge(index: Int)
}

struct BookSplitter {
  static func isShareable(_ item: PlayableItem) -> Bool {
    !item.chapters.isEmpty && item.chapters.allSatisfy { chapter in
      !chapter.isVideo && FileManager.default.fileExists(atPath: chapter.fileURL.path)
    }
  }

  /// One entry per distinct audio file, in book order.
  func sourceFiles(for item: PlayableItem) throws -> [SourceFile] {
    var files: [SourceFile] = []
    for chapter in item.chapters.sorted(by: { $0.start < $1.start }) {
      let url = chapter.fileURL
      guard FileManager.default.fileExists(atPath: url.path) else { throw BookSplitterError.noLocalFile }
      if files.last?.url == url { continue }   // single-file books: many chapters, one file
      let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
      // chapterOffset is where this chapter begins inside its file, so the file starts at start - offset.
      let fileBookStart = chapter.start - chapter.chapterOffset
      let fileDuration = item.chapters.filter { $0.fileURL == url }.map(\.end).max()! - fileBookStart
      files.append(SourceFile(url: url, bookStart: fileBookStart, duration: fileDuration, byteSize: size))
    }
    return files
  }

  func export(_ piece: PlannedPiece, from files: [SourceFile], to folder: URL)
    async throws -> (url: URL, shared: SharedPiece)
  {
    let source = files[piece.sourceIndex]
    let output = folder.appendingPathComponent(String(format: "piece-%03d.%@", piece.index,
                                                      piece.isWholeFile ? source.url.pathExtension : "m4a"))
    try? FileManager.default.removeItem(at: output)

    if piece.isWholeFile {
      try FileManager.default.copyItem(at: source.url, to: output)
    } else {
      let asset = AVURLAsset(url: source.url)
      let passthroughOK = await AVAssetExportSession.compatibility(
        ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: .m4a)
      let preset = passthroughOK ? AVAssetExportPresetPassthrough : AVAssetExportPresetAppleM4A
      guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
        throw BookSplitterError.exportFailed(index: piece.index)
      }
      session.timeRange = CMTimeRange(
        start: CMTime(seconds: piece.sourceStart, preferredTimescale: 600),
        duration: CMTime(seconds: piece.duration, preferredTimescale: 600))
      do {
        try await session.export(to: output, as: .m4a)
      } catch {
        throw BookSplitterError.exportFailed(index: piece.index)
      }
    }

    let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
    guard size <= 100_000_000 else { throw BookSplitterError.pieceTooLarge(index: piece.index) }
    return (output, SharedPiece(index: piece.index, bookStart: piece.bookStart,
                                duration: piece.duration, byteSize: size))
  }
}
```
Verify the two iOS 18 export APIs exist with the installed SDK before relying on them:
```bash
grep -rn "func export(to\|static func compatibility(ofExportPreset" \
  "$(xcrun --sdk iphonesimulator --show-sdk-path)/System/Library/Frameworks/AVFoundation.framework" | head
```
If either is missing, use `exportAsynchronously` and `determineCompatibility(ofExportPreset:with:outputFileType:)` instead, wrapped in `withCheckedThrowingContinuation`.

- [ ] **Step 5: Run tests — expect PASS (2 tests).**
- [ ] **Step 6: Commit** (`SharePlay: split books into pieces without re-encoding`).

---

### Task 5: Piece timeline (pure logic)

**Files:**
- Create: `BookPlayer/BookPlayer/SharePlay/PieceTimeline.swift`
- Test: `BookPlayerTests/SharePlay/PieceTimelineTests.swift`

**Interfaces:**
- Consumes: `SharedPiece`.
- Produces: `struct PieceTimeline { init(pieces: [SharedPiece]); mutating func markArrived(index: Int, url: URL); func location(for bookTime: TimeInterval) -> (piece: SharedPiece, offset: TimeInterval)?; func url(forPiece index: Int) -> URL?; func isReady(at bookTime: TimeInterval) -> Bool; var arrivedFraction: Double; var totalDuration: TimeInterval }`.

- [ ] **Step 1: Failing tests**

```swift
@testable import BookPlayer
import XCTest

final class PieceTimelineTests: XCTestCase {
  private let pieces = [SharedPiece(index: 0, bookStart: 0, duration: 100, byteSize: 10),
                        SharedPiece(index: 1, bookStart: 100, duration: 50, byteSize: 30)]

  func testLocationMapsBookTimeToPieceAndOffset() {
    let timeline = PieceTimeline(pieces: pieces)
    XCTAssertEqual(timeline.location(for: 120)?.piece.index, 1)
    XCTAssertEqual(timeline.location(for: 120)?.offset ?? -1, 20, accuracy: 0.001)
    XCTAssertEqual(timeline.location(for: 0)?.piece.index, 0)
  }

  func testEndOfBookClampsToLastPiece() {
    XCTAssertEqual(PieceTimeline(pieces: pieces).location(for: 150)?.piece.index, 1)
    XCTAssertNil(PieceTimeline(pieces: pieces).location(for: -1))
  }

  func testReadinessAndFractionFollowArrivals() {
    var timeline = PieceTimeline(pieces: pieces)
    XCTAssertFalse(timeline.isReady(at: 10))
    timeline.markArrived(index: 0, url: URL(fileURLWithPath: "/tmp/p0.m4a"))
    XCTAssertTrue(timeline.isReady(at: 10))
    XCTAssertFalse(timeline.isReady(at: 110))
    XCTAssertEqual(timeline.arrivedFraction, 0.25, accuracy: 0.001)  // by bytes: 10 of 40
  }
}
```

- [ ] **Step 2: Register, run, expect compile failure.**

- [ ] **Step 3: Implement**

```swift
import Foundation

struct PieceTimeline {
  private(set) var pieces: [SharedPiece]
  private var arrived: [Int: URL] = [:]

  init(pieces: [SharedPiece]) {
    self.pieces = pieces.sorted { $0.bookStart < $1.bookStart }
  }

  var totalDuration: TimeInterval { pieces.last?.bookEnd ?? 0 }

  var arrivedFraction: Double {
    let total = pieces.reduce(Int64(0)) { $0 + $1.byteSize }
    guard total > 0 else { return 0 }
    let done = pieces.filter { arrived[$0.index] != nil }.reduce(Int64(0)) { $0 + $1.byteSize }
    return Double(done) / Double(total)
  }

  mutating func markArrived(index: Int, url: URL) { arrived[index] = url }

  func url(forPiece index: Int) -> URL? { arrived[index] }

  func location(for bookTime: TimeInterval) -> (piece: SharedPiece, offset: TimeInterval)? {
    guard bookTime >= 0, let last = pieces.last else { return nil }
    if let piece = pieces.first(where: { bookTime >= $0.bookStart && bookTime < $0.bookEnd }) {
      return (piece, bookTime - piece.bookStart)
    }
    return bookTime >= last.bookEnd ? (last, last.duration) : nil
  }

  func isReady(at bookTime: TimeInterval) -> Bool {
    guard let piece = location(for: bookTime)?.piece else { return false }
    return arrived[piece.index] != nil
  }
}
```

- [ ] **Step 4: Run — PASS (3 tests).**
- [ ] **Step 5: Commit** (`SharePlay: map book time to received pieces`).

---

### Task 6: Playback targets (protocol + sharer side)

**Files:**
- Create: `BookPlayer/BookPlayer/SharePlay/ListenTogetherPlaybackTarget.swift`, `BookPlayer/BookPlayer/SharePlay/SharerPlaybackTarget.swift`
- Test: `BookPlayerTests/SharePlay/SharerPlaybackTargetTests.swift`

**Interfaces:**
- Consumes: `PlayerManagerProtocol` (existing; `PlayerManagerProtocolMock` exists in `BookPlayer/Generated/AutoMockable.generated.swift`).
- Produces:
```swift
enum LocalPlaybackEvent: Equatable {
  case played(at: TimeInterval, rate: Float)
  case paused(at: TimeInterval)
  case seeked(to: TimeInterval, from: TimeInterval)
  case rateChanged(Float)
}
@MainActor protocol ListenTogetherPlaybackTarget: AnyObject {
  var bookTime: TimeInterval { get }
  var isPlaying: Bool { get }
  var rate: Float { get }
  var localEvents: AnyPublisher<LocalPlaybackEvent, Never> { get }
  func isReady(at bookTime: TimeInterval) -> Bool
  func applyPlay(at bookTime: TimeInterval, rate: Float)
  func applyPause(at bookTime: TimeInterval)
  func applySeek(to bookTime: TimeInterval)
}
@MainActor final class SharerPlaybackTarget: ListenTogetherPlaybackTarget {
  init(playerManager: PlayerManagerProtocol, seekCheckInterval: TimeInterval = 0.5)
  func checkForSeek(now: Date)   // internal, called by its timer; exposed for tests
}
```

Before writing tests, read `PlayerManagerProtocolMock` (search `class PlayerManagerProtocolMock` in the generated file) and note the names of its stub properties for `isPlaying`, `currentItem`, `currentSpeed`, `isPlayingPublisher()` and `currentSpeedPublisher()` (Sourcery names them like `underlyingIsPlaying`, `isPlayingPublisherReturnValue`, `playCallsCount`, `jumpToRecordBookmarkCallsCount`, `jumpToRecordBookmarkReceivedArguments`). Use those exact names below; adjust if they differ.

- [ ] **Step 1: Failing tests**

```swift
@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import XCTest

@MainActor
final class SharerPlaybackTargetTests: XCTestCase {
  private var mock: PlayerManagerProtocolMock!
  private var playing: CurrentValueSubject<Bool, Never>!
  private var speed: CurrentValueSubject<Float, Never>!
  private var events: [LocalPlaybackEvent] = []
  private var bag = Set<AnyCancellable>()

  override func setUp() async throws {
    mock = PlayerManagerProtocolMock()
    playing = CurrentValueSubject(false)
    speed = CurrentValueSubject(1)
    mock.isPlayingPublisherReturnValue = playing.eraseToAnyPublisher()
    mock.currentSpeedPublisherReturnValue = speed.eraseToAnyPublisher()
    mock.underlyingIsPlaying = false
    mock.underlyingCurrentSpeed = 1
    mock.currentItem = PlayableItemMock.stub(currentTime: 100, duration: 3600) // see note below
    events = []
  }

  private func makeTarget() -> SharerPlaybackTarget {
    let target = SharerPlaybackTarget(playerManager: mock, seekCheckInterval: 1000) // timer effectively off
    target.localEvents.sink { [weak self] in self?.events.append($0) }.store(in: &bag)
    return target
  }

  func testLocalPlayIsReported() {
    _ = makeTarget()
    playing.send(true)
    XCTAssertEqual(events, [.played(at: 100, rate: 1)])
  }

  func testRemotePauseIsNotEchoed() {
    let target = makeTarget()
    mock.underlyingIsPlaying = true
    target.applyPause(at: 100)
    playing.send(false)            // PlayerManager reacts to our own pause
    XCTAssertEqual(mock.pauseCallsCount, 1)
    XCTAssertTrue(events.isEmpty)
  }

  func testRemoteSeekJumpsWithoutBookmark() {
    let target = makeTarget()
    target.applySeek(to: 500)
    XCTAssertEqual(mock.jumpToRecordBookmarkReceivedArguments?.time, 500)
    XCTAssertEqual(mock.jumpToRecordBookmarkReceivedArguments?.recordBookmark, false)
  }

  func testRemotePlaySetsSpeedThenPlays() {
    let target = makeTarget()
    target.applyPlay(at: 100.2, rate: 1.5)
    XCTAssertEqual(mock.setSpeedReceivedNewValue, 1.5)
    XCTAssertEqual(mock.playCallsCount, 1)
    XCTAssertEqual(mock.jumpToRecordBookmarkCallsCount, 0) // within 0.5 s: no jump
  }

  func testLocalJumpIsDetectedAsSeek() {
    let target = makeTarget()
    let start = Date()
    target.checkForSeek(now: start)                 // baseline at 100, paused
    mock.currentItem?.currentTime = 900
    target.checkForSeek(now: start.addingTimeInterval(0.5))
    XCTAssertEqual(events, [.seeked(to: 900, from: 100)])
  }
}
```
Note: if `PlayableItemMock` has no `stub(currentTime:duration:)`, add a small factory to `BookPlayerTests/Mocks/PlayableItemMock.swift` that builds a `PlayableItem` with one chapter and the given times, following the existing initialiser in `Shared/CoreData/Lightweight-Models/PlayableItem.swift:51`.

- [ ] **Step 2: Register, run, expect compile failure.**

- [ ] **Step 3: Implement**

`ListenTogetherPlaybackTarget.swift`: the enum and protocol exactly as in Interfaces, plus `import Combine`.

`SharerPlaybackTarget.swift`:
```swift
import AVFoundation
import BookPlayerKit
import Combine
import Foundation

/// Drives the sharer's normal player through its protocol. PlayerManager itself is not modified.
@MainActor
final class SharerPlaybackTarget: ListenTogetherPlaybackTarget {
  private let playerManager: PlayerManagerProtocol
  private let subject = PassthroughSubject<LocalPlaybackEvent, Never>()
  private var disposeBag = Set<AnyCancellable>()
  private var seekTimer: Timer?

  /// State we just applied for a remote command; matching publisher output is our own echo.
  private var expectedIsPlaying: Bool?
  private var expectedRate: Float?
  private var lastSample: (time: TimeInterval, date: Date)?

  var localEvents: AnyPublisher<LocalPlaybackEvent, Never> { subject.eraseToAnyPublisher() }
  var bookTime: TimeInterval { playerManager.currentItem?.currentTime ?? 0 }
  var isPlaying: Bool { playerManager.isPlaying }
  var rate: Float { playerManager.currentSpeed }

  init(playerManager: PlayerManagerProtocol, seekCheckInterval: TimeInterval = 0.5) {
    self.playerManager = playerManager

    playerManager.isPlayingPublisher()
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] playing in self?.handleIsPlaying(playing) }
      .store(in: &disposeBag)

    playerManager.currentSpeedPublisher()
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] speed in self?.handleSpeed(speed) }
      .store(in: &disposeBag)

    seekTimer = Timer.scheduledTimer(withTimeInterval: seekCheckInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkForSeek(now: Date()) }
    }

    // Upstream PlayerManager keeps playing when headphones disconnect. During a session that would
    // leave everyone else listening while this phone plays out loud, so pause (reported as local).
    NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
          .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        if reason == .oldDeviceUnavailable, self?.isPlaying == true { self?.playerManager.pause() }
      }
      .store(in: &disposeBag)
  }

  deinit { seekTimer?.invalidate() }

  func isReady(at bookTime: TimeInterval) -> Bool { true }   // the sharer has the whole book

  func applyPlay(at bookTime: TimeInterval, rate: Float) {
    if abs(rate - playerManager.currentSpeed) > 0.001 {
      expectedRate = rate
      playerManager.setSpeed(rate)
    }
    if abs(bookTime - self.bookTime) > 0.5 {
      playerManager.jumpTo(bookTime, recordBookmark: false)
    }
    lastSample = (bookTime, Date())
    expectedIsPlaying = true
    playerManager.play()
  }

  func applyPause(at bookTime: TimeInterval) {
    expectedIsPlaying = false
    playerManager.pause()
    if abs(bookTime - self.bookTime) > 0.5 {
      playerManager.jumpTo(bookTime, recordBookmark: false)
    }
    lastSample = (bookTime, Date())
  }

  func applySeek(to bookTime: TimeInterval) {
    playerManager.jumpTo(bookTime, recordBookmark: false)
    lastSample = (bookTime, Date())
  }

  private func handleIsPlaying(_ playing: Bool) {
    if expectedIsPlaying == playing {
      expectedIsPlaying = nil
      return
    }
    expectedIsPlaying = nil
    lastSample = (bookTime, Date())
    subject.send(playing ? .played(at: bookTime, rate: rate) : .paused(at: bookTime))
  }

  private func handleSpeed(_ speed: Float) {
    if let expected = expectedRate, abs(expected - speed) < 0.001 {
      expectedRate = nil
      return
    }
    subject.send(.rateChanged(speed))
  }

  /// PlayerManager has no seek publisher, so compare where we are with where we should be.
  func checkForSeek(now: Date) {
    let current = bookTime
    defer { lastSample = (current, now) }
    guard let last = lastSample else { return }
    let elapsed = now.timeIntervalSince(last.date)
    let expected = last.time + (isPlaying ? elapsed * Double(rate) : 0)
    if abs(current - expected) > 2 {
      subject.send(.seeked(to: current, from: last.time))
    }
  }
}
```

- [ ] **Step 4: Run — PASS (5 tests).**
- [ ] **Step 5: Commit** (`SharePlay: drive the sharer's player through its protocol`).

---

### Task 7: Listener player

**Files:**
- Create: `BookPlayer/BookPlayer/SharePlay/ListenerPlayer.swift`
- Test: `BookPlayerTests/SharePlay/ListenerPlayerTests.swift`

**Interfaces:**
- Consumes: `PieceTimeline`, `SharedBookManifest`, `ListenTogetherPlaybackTarget`, `LocalPlaybackEvent`, `AudioFixture` (tests).
- Produces:
```swift
@MainActor final class ListenerPlayer: ObservableObject, ListenTogetherPlaybackTarget {
  @Published private(set) var bookTime: TimeInterval
  @Published private(set) var isPlaying: Bool
  @Published private(set) var rate: Float
  @Published private(set) var timeline: PieceTimeline
  let manifest: SharedBookManifest
  var onNeedsPiece: ((Int) -> Void)?      // asks the service/bridge to wait for a piece
  init(manifest: SharedBookManifest)
  func pieceArrived(index: Int, url: URL)
  // user-facing controls (emit LocalPlaybackEvent):
  func userTogglePlay(); func userSkip(by seconds: TimeInterval); func userJump(to bookTime: TimeInterval); func userSetRate(_ rate: Float)
  func stop()                               // tears down player and audio session
}
```

Behaviour:
- `applyPlay/applyPause/applySeek` (remote) never emit `localEvents`; `user*` methods apply locally then emit.
- Loading a piece: `AVPlayerItem(url:)` for `timeline.url(forPiece:)`, then `seek(to: offset)`; when a piece's item plays to end (`AVPlayerItem.didPlayToEndTimeNotification`), load the next piece at offset 0 if it has arrived, else call `onNeedsPiece(next)` and set `isPlaying = false` without emitting a local event.
- `isReady(at:)` = `timeline.isReady(at:)`.
- Time: a 0.5 s periodic observer sets `bookTime = piece.bookStart + item time`.
- Audio session: on first play set `.playback`, mode `.spokenAudio`, `setActive(true)`; on `stop()` `setActive(false, options: .notifyOthersOnDeactivation)`.
- Route change `.oldDeviceUnavailable` and interruption `.began`: `userTogglePlay()` if playing (so it is reported and pauses everyone).
- `rate`: `player.rate = rate` only while playing; store otherwise; `audioTimePitchAlgorithm = .timeDomain` (same as PlayerManager).

- [ ] **Step 1: Failing tests**

```swift
@testable import BookPlayer
import Combine
import XCTest

@MainActor
final class ListenerPlayerTests: XCTestCase {
  private var folder: URL!
  private var bag = Set<AnyCancellable>()

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("ListenerPlayerTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  override func tearDown() { try? FileManager.default.removeItem(at: folder) }

  private func manifest() -> SharedBookManifest {
    SharedBookManifest(shareID: UUID(), title: "T", author: "A", duration: 20,
                       chapters: [SharedChapter(title: "One", start: 0, duration: 20)],
                       pieces: [SharedPiece(index: 0, bookStart: 0, duration: 10, byteSize: 1),
                                SharedPiece(index: 1, bookStart: 10, duration: 10, byteSize: 1)])
  }

  func testSeekToMissingPieceBeginsSuspension() throws {
    let player = ListenerPlayer(manifest: manifest())
    var needed: [Int] = []
    player.onNeedsPiece = { needed.append($0) }
    let p0 = folder.appendingPathComponent("p0.m4a")
    try AudioFixture.makeM4A(seconds: 10, at: p0)
    player.pieceArrived(index: 0, url: p0)

    player.applySeek(to: 15)

    XCTAssertEqual(needed, [1])
    XCTAssertFalse(player.isReady(at: 15))
    XCTAssertTrue(player.isReady(at: 5))
  }

  func testRemoteCommandsDoNotEmitLocalEvents() throws {
    let player = ListenerPlayer(manifest: manifest())
    var events: [LocalPlaybackEvent] = []
    player.localEvents.sink { events.append($0) }.store(in: &bag)
    let p0 = folder.appendingPathComponent("p0.m4a")
    try AudioFixture.makeM4A(seconds: 10, at: p0)
    player.pieceArrived(index: 0, url: p0)

    player.applyPlay(at: 2, rate: 1)
    player.applyPause(at: 3)
    XCTAssertTrue(events.isEmpty)

    player.userSkip(by: 5)
    XCTAssertEqual(events.count, 1)
    if case let .seeked(to, _) = events[0] { XCTAssertEqual(to, 8, accuracy: 0.6) } else { XCTFail() }
    player.stop()
  }
}
```

- [ ] **Step 2: Register, run, expect compile failure.**

- [ ] **Step 3: Implement** `ListenerPlayer.swift` following the behaviour list above. Keep it under ~250 lines. Key pieces:

```swift
import AVFoundation
import Combine
import Foundation

@MainActor
final class ListenerPlayer: ObservableObject, ListenTogetherPlaybackTarget {
  @Published private(set) var bookTime: TimeInterval = 0
  @Published private(set) var isPlaying = false
  @Published private(set) var rate: Float = 1
  @Published private(set) var timeline: PieceTimeline
  let manifest: SharedBookManifest
  var onNeedsPiece: ((Int) -> Void)?

  private let player = AVPlayer()
  private var loadedPieceIndex: Int?
  private var timeObserver: Any?
  private var sessionConfigured = false
  private let subject = PassthroughSubject<LocalPlaybackEvent, Never>()
  private var disposeBag = Set<AnyCancellable>()

  var localEvents: AnyPublisher<LocalPlaybackEvent, Never> { subject.eraseToAnyPublisher() }

  init(manifest: SharedBookManifest) {
    self.manifest = manifest
    self.timeline = PieceTimeline(pieces: manifest.pieces)
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated {
        guard let self, let index = self.loadedPieceIndex,
              let piece = self.timeline.pieces.first(where: { $0.index == index }) else { return }
        self.bookTime = piece.bookStart + time.seconds
      }
    }
    NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
        self.advanceToNextPiece()
      }
      .store(in: &disposeBag)
    NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
          .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        if reason == .oldDeviceUnavailable, self?.isPlaying == true { self?.userTogglePlay() }
      }
      .store(in: &disposeBag)
    NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
          .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
        if type == .began, self?.isPlaying == true { self?.userTogglePlay() }
      }
      .store(in: &disposeBag)
  }

  func pieceArrived(index: Int, url: URL) {
    timeline.markArrived(index: index, url: url)
  }

  func isReady(at bookTime: TimeInterval) -> Bool { timeline.isReady(at: bookTime) }

  // MARK: Remote commands (never reported back)

  func applyPlay(at bookTime: TimeInterval, rate: Float) {
    self.rate = rate
    guard load(at: bookTime) else { return }
    activateSessionIfNeeded()
    player.playImmediately(atRate: rate)
    isPlaying = true
  }

  func applyPause(at bookTime: TimeInterval) {
    player.pause()
    isPlaying = false
    _ = load(at: bookTime)
  }

  func applySeek(to bookTime: TimeInterval) {
    let wasPlaying = isPlaying
    guard load(at: bookTime) else { player.pause(); isPlaying = false; return }
    if wasPlaying { player.playImmediately(atRate: rate) }
  }

  // MARK: Local user actions (reported)

  func userTogglePlay() {
    if isPlaying {
      applyPause(at: bookTime)
      subject.send(.paused(at: bookTime))
    } else {
      applyPlay(at: bookTime, rate: rate)
      subject.send(.played(at: bookTime, rate: rate))
    }
  }

  func userSkip(by seconds: TimeInterval) { userJump(to: bookTime + seconds) }

  func userJump(to target: TimeInterval) {
    let from = bookTime
    let clamped = min(max(0, target), manifest.duration)
    applySeek(to: clamped)
    subject.send(.seeked(to: clamped, from: from))
  }

  func userSetRate(_ newRate: Float) {
    rate = newRate
    if isPlaying { player.rate = newRate }
    subject.send(.rateChanged(newRate))
  }

  func stop() {
    player.pause()
    player.replaceCurrentItem(with: nil)
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    timeObserver = nil
    isPlaying = false
    if sessionConfigured {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  // MARK: Private

  /// Loads the piece containing `bookTime` and seeks inside it. Returns false if it hasn't arrived.
  @discardableResult
  private func load(at bookTime: TimeInterval) -> Bool {
    guard let (piece, offset) = timeline.location(for: bookTime) else { return false }
    self.bookTime = bookTime
    guard let url = timeline.url(forPiece: piece.index) else {
      onNeedsPiece?(piece.index)
      return false
    }
    if loadedPieceIndex != piece.index {
      let item = AVPlayerItem(url: url)
      item.audioTimePitchAlgorithm = .timeDomain
      player.replaceCurrentItem(with: item)
      loadedPieceIndex = piece.index
    }
    player.seek(to: CMTime(seconds: offset, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero)
    return true
  }

  private func advanceToNextPiece() {
    guard let index = loadedPieceIndex,
          let current = timeline.pieces.first(where: { $0.index == index }),
          current.bookEnd < manifest.duration - 0.1 else { isPlaying = false; return }
    if load(at: current.bookEnd), isPlaying { player.playImmediately(atRate: rate) } else { isPlaying = false }
  }

  private func activateSessionIfNeeded() {
    guard !sessionConfigured else { return }
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .spokenAudio)
    try? session.setActive(true)
    sessionConfigured = true
  }
}
```

- [ ] **Step 4: Run — PASS (2 tests).**
- [ ] **Step 5: Commit** (`SharePlay: add the listener's own player`).

---

### Task 8: Coordinator bridge

**Files:**
- Create: `BookPlayer/BookPlayer/SharePlay/ListenTogetherCoordinatorBridge.swift`
- Test: `BookPlayerTests/SharePlay/ListenTogetherCoordinatorBridgeTests.swift` with a `FakePlaybackTarget` inside the test file.

**Interfaces:**
- Consumes: `ListenTogetherPlaybackTarget`, `LocalPlaybackEvent`, `ListenTogetherActivity`.
- Produces:
```swift
@MainActor final class ListenTogetherCoordinatorBridge: NSObject {
  init(target: ListenTogetherPlaybackTarget, shareID: UUID)
  func coordinate(with session: GroupSession<ListenTogetherActivity>)
  func waitForPiece()      // begins a .stallRecovery suspension if not already suspended
  func pieceBecameAvailable()  // ends that suspension if the target is now ready
  // internal, called by the delegate methods and by tests:
  func handlePlay(itemTime: TimeInterval, rate: Float)
  func handlePause(itemTime: TimeInterval)
  func handleSeek(itemTime: TimeInterval)
  func handleBuffering() -> Bool  // true when ready
  func invalidate()
}
```

Verify the exact delegate signatures in the SDK before writing them:
```bash
grep -n "func playbackCoordinator\|class AVDelegatingPlaybackCoordinator\b\|func coordinateRateChange\|func coordinateSeek\|func transitionToItem\|func beginSuspension\|suspensionReasonsThatTriggerWaiting" \
  "$(xcrun --sdk iphonesimulator --show-sdk-path)/System/Library/Frameworks/AVFoundation.framework/Headers/AVPlaybackCoordinator.h"
```

- [ ] **Step 1: Failing tests**

```swift
@testable import BookPlayer
import Combine
import XCTest

@MainActor
private final class FakePlaybackTarget: ListenTogetherPlaybackTarget {
  var bookTime: TimeInterval = 0
  var isPlaying = false
  var rate: Float = 1
  var ready = true
  var log: [String] = []
  let subject = PassthroughSubject<LocalPlaybackEvent, Never>()
  var localEvents: AnyPublisher<LocalPlaybackEvent, Never> { subject.eraseToAnyPublisher() }
  func isReady(at bookTime: TimeInterval) -> Bool { ready }
  func applyPlay(at bookTime: TimeInterval, rate: Float) { log.append("play \(Int(bookTime)) \(rate)") }
  func applyPause(at bookTime: TimeInterval) { log.append("pause \(Int(bookTime))") }
  func applySeek(to bookTime: TimeInterval) { log.append("seek \(Int(bookTime))") }
}

@MainActor
final class ListenTogetherCoordinatorBridgeTests: XCTestCase {
  func testCommandsReachTarget() {
    let target = FakePlaybackTarget()
    let bridge = ListenTogetherCoordinatorBridge(target: target, shareID: UUID())
    bridge.handlePlay(itemTime: 42, rate: 1.25)
    bridge.handlePause(itemTime: 50)
    bridge.handleSeek(itemTime: 600)
    XCTAssertEqual(target.log, ["play 42 1.25", "pause 50", "seek 600"])
  }

  func testBufferingReportsReadiness() {
    let target = FakePlaybackTarget()
    let bridge = ListenTogetherCoordinatorBridge(target: target, shareID: UUID())
    target.ready = false
    XCTAssertFalse(bridge.handleBuffering())
    target.ready = true
    XCTAssertTrue(bridge.handleBuffering())
  }
}
```

- [ ] **Step 2: Register, run, expect compile failure.**

- [ ] **Step 3: Implement**

```swift
import AVFoundation
import Combine
import GroupActivities

@MainActor
final class ListenTogetherCoordinatorBridge: NSObject {
  private weak var target: ListenTogetherPlaybackTarget?
  private let itemIdentifier: String
  private var coordinator: AVDelegatingPlaybackCoordinator!
  private var stallSuspension: AVCoordinatedPlaybackSuspension?
  private var disposeBag = Set<AnyCancellable>()

  init(target: ListenTogetherPlaybackTarget, shareID: UUID) {
    self.target = target
    self.itemIdentifier = shareID.uuidString
    super.init()
    coordinator = AVDelegatingPlaybackCoordinator(playbackControlDelegate: self)
    coordinator.suspensionReasonsThatTriggerWaiting = [.stallRecovery]
    coordinator.transitionToItem(withIdentifier: itemIdentifier,
                                 proposingInitialTimingBasedOn: nil)

    target.localEvents
      .sink { [weak self] event in self?.report(event) }
      .store(in: &disposeBag)
  }

  func coordinate(with session: GroupSession<ListenTogetherActivity>) {
    coordinator.coordinateWithSession(session)
  }

  func waitForPiece() {
    guard stallSuspension == nil else { return }
    stallSuspension = coordinator.beginSuspension(for: .stallRecovery)
  }

  func pieceBecameAvailable() {
    guard let target, target.isReady(at: target.bookTime) else { return }
    stallSuspension?.end()
    stallSuspension = nil
  }

  func invalidate() {
    stallSuspension?.end()
    stallSuspension = nil
    disposeBag.removeAll()
    coordinator.transitionToItem(withIdentifier: nil, proposingInitialTimingBasedOn: nil)
  }

  // MARK: Command handling (main actor)

  func handlePlay(itemTime: TimeInterval, rate: Float) { target?.applyPlay(at: itemTime, rate: rate) }
  func handlePause(itemTime: TimeInterval) { target?.applyPause(at: itemTime) }
  func handleSeek(itemTime: TimeInterval) { target?.applySeek(to: itemTime) }
  func handleBuffering() -> Bool {
    guard let target else { return false }
    return target.isReady(at: target.bookTime)
  }

  // MARK: Local changes → coordinator

  private func report(_ event: LocalPlaybackEvent) {
    switch event {
    case .played(_, let rate): coordinator.coordinateRateChange(to: rate, options: [])
    case .paused: coordinator.coordinateRateChange(to: 0, options: [])
    case .seeked(let to, _):
      coordinator.coordinateSeek(to: CMTime(seconds: to, preferredTimescale: 600), options: [])
    case .rateChanged(let rate):
      if target?.isPlaying == true { coordinator.coordinateRateChange(to: rate, options: []) }
    }
  }
}

extension ListenTogetherCoordinatorBridge: AVPlaybackCoordinatorPlaybackControlDelegate {
  nonisolated func playbackCoordinator(
    _ coordinator: AVDelegatingPlaybackCoordinator,
    didIssue playCommand: AVDelegatingPlaybackCoordinatorPlayCommand,
    completionHandler: @escaping () -> Void
  ) {
    let time = playCommand.itemTime.seconds
    let rate = playCommand.rate
    let matches = playCommand.expectedCurrentItemIdentifier == nil
      || playCommand.expectedCurrentItemIdentifier == itemIdentifier
    Task { @MainActor in
      if matches { self.handlePlay(itemTime: time, rate: rate) }
      completionHandler()
    }
  }

  nonisolated func playbackCoordinator(
    _ coordinator: AVDelegatingPlaybackCoordinator,
    didIssue pauseCommand: AVDelegatingPlaybackCoordinatorPauseCommand,
    completionHandler: @escaping () -> Void
  ) {
    let time = pauseCommand.itemTime.seconds
    Task { @MainActor in
      self.handlePause(itemTime: time)
      completionHandler()
    }
  }

  nonisolated func playbackCoordinator(
    _ coordinator: AVDelegatingPlaybackCoordinator,
    didIssue seekCommand: AVDelegatingPlaybackCoordinatorSeekCommand,
    completionHandler: @escaping () -> Void
  ) {
    let time = seekCommand.itemTime.seconds
    Task { @MainActor in
      self.handleSeek(itemTime: time)
      completionHandler()
    }
  }

  nonisolated func playbackCoordinator(
    _ coordinator: AVDelegatingPlaybackCoordinator,
    didIssue bufferingCommand: AVDelegatingPlaybackCoordinatorBufferingCommand,
    completionHandler: @escaping () -> Void
  ) {
    Task { @MainActor in
      if !self.handleBuffering() { self.waitForPiece() }
      completionHandler()
    }
  }
}
```
`itemIdentifier` is a `let String` and is safe to read from the nonisolated methods; if the compiler objects, mark it `nonisolated let`. `playCommand.rate` and `hostClockTime`: the plan deliberately ignores `hostClockTime` (starting a few tens of milliseconds late is inaudible for spoken audio and keeps `PlayerManager` untouched); record this in `Notes.md`.

- [ ] **Step 4: Run — PASS (2 tests).**
- [ ] **Step 5: Commit** (`SharePlay: sync book time with AVDelegatingPlaybackCoordinator`).

---

### Task 9: Transport, session service and announcements

**Files:**
- Create: `BookPlayer/BookPlayer/SharePlay/ListenTogetherAnnouncer.swift`, `BookPlayer/BookPlayer/SharePlay/ListenTogetherTransport.swift`, `BookPlayer/BookPlayer/SharePlay/SharePlaySessionService.swift`
- Test: `BookPlayerTests/SharePlay/ListenTogetherAnnouncerTests.swift`, `BookPlayerTests/SharePlay/SharePlaySessionServiceTests.swift` (with `FakeTransport`)
- Modify: `BookPlayer/Base.lproj/Localizable.strings`

**Interfaces:**
- Consumes: everything above.
- Produces:
```swift
// Announcer
enum ListenTogetherAnnouncements {
  static func text(for action: RemoteAction) -> String
  static func joined() -> String; static func left() -> String; static func ended() -> String
  static func download(percent: Int) -> String
}
@MainActor final class ListenTogetherAnnouncer {
  init(post: @escaping (String) -> Void = ListenTogetherAnnouncer.postQueued)
  func announce(_ text: String)
  func announceDownload(fraction: Double)      // only at 25/50/75/100, once each
  static func postQueued(_ text: String)       // UIAccessibility.post(.announcement, NSAttributedString w/ .accessibilitySpeechQueueAnnouncement)
}

// Transport
enum TransportEvent: Equatable {
  case message(ListenTogetherMessage)
  case participantsChanged(count: Int)
  case attachmentReceived(id: UUID, url: URL)
  case invalidated
}
@MainActor protocol ListenTogetherTransport: AnyObject {
  var events: AsyncStream<TransportEvent> { get }
  func send(_ message: ListenTogetherMessage) async throws
  func upload(fileAt url: URL) async throws -> UUID   // returns attachment id
  func leave()
}
@MainActor final class GroupSessionTransport: ListenTogetherTransport {
  init(session: GroupSession<ListenTogetherActivity>, downloadFolder: URL)
}

// Service
enum ListenTogetherState: Equatable {
  case idle
  case needsFaceTime
  case preparing(title: String)
  case invitation(title: String, author: String)
  case sharing(participants: Int)
  case listening(participants: Int, downloaded: Double)
  case ended(reason: EndReason)
  enum EndReason: Equatable { case normal, sendFailed, unavailable }
}
@MainActor final class SharePlaySessionService: ObservableObject {
  @Published private(set) var state: ListenTogetherState
  @Published private(set) var listener: ListenerPlayer?
  init(playerManager: PlayerManagerProtocol,
       storage: ShareStorage = ShareStorage(),
       announcer: ListenTogetherAnnouncer = ListenTogetherAnnouncer(),
       transportFactory: @escaping (GroupSession<ListenTogetherActivity>, URL) -> ListenTogetherTransport
         = { GroupSessionTransport(session: $0, downloadFolder: $1) })
  func startObservingSessions()          // loops over ListenTogetherActivity.sessions()
  func canShare(_ item: PlayableItem?) -> Bool
  func startSharing(_ item: PlayableItem) async
  func joinInvitation()
  func declineInvitation()
  func end()
  // test seams:
  func beginListening(with transport: ListenTogetherTransport, shareID: UUID) async
  func beginSharing(with transport: ListenTogetherTransport, item: PlayableItem) async
}
```

Strings to add to `Base.lproj/Localizable.strings`:
```
"listen_together_title" = "Listen Together";
"listen_together_end_button" = "End Listen Together";
"listen_together_join_button" = "Join";
"listen_together_decline_button" = "Not Now";
"listen_together_invitation_message" = "Listen to %@ by %@ with the people on this FaceTime call.";
"listen_together_needs_facetime_title" = "Start a FaceTime call first";
"listen_together_needs_facetime_message" = "Listen Together works during a FaceTime call. Call the people you want to listen with, then choose Listen Together again.";
"listen_together_status_sharing" = "Listen Together, %d people, sharing";
"listen_together_status_listening" = "Listen Together, %d people, listening";
"listen_together_status_downloading" = "Listen Together, getting the book, %d percent";
"listen_together_status_preparing" = "Preparing %@ to share";
"listen_together_remote_paused" = "Another listener paused";
"listen_together_remote_resumed" = "Another listener resumed";
"listen_together_remote_skipped_forward" = "Another listener skipped forward %@";
"listen_together_remote_skipped_back" = "Another listener skipped back %@";
"listen_together_remote_chapter" = "Another listener moved to chapter %@";
"listen_together_remote_speed" = "Speed changed to %@ times by another listener";
"listen_together_joined" = "Someone joined Listen Together";
"listen_together_left" = "Someone left Listen Together";
"listen_together_ended" = "Listen Together ended";
"listen_together_download_progress" = "Book %d percent downloaded";
"listen_together_waiting_download" = "Waiting for the book to download";
"listen_together_send_failed" = "Couldn't send part of the book. Listen Together ended.";
```
Skip durations use `VoiceOverService.secondsToMinutes(_:)` (existing) so "30 seconds" / "1 minute" match the rest of the app.

- [ ] **Step 1: Announcer failing tests**

```swift
@testable import BookPlayer
import XCTest

@MainActor
final class ListenTogetherAnnouncerTests: XCTestCase {
  func testRemoteActionText() {
    XCTAssertEqual(ListenTogetherAnnouncements.text(for: .paused), "listen_together_remote_paused".localized)
    XCTAssertTrue(ListenTogetherAnnouncements.text(for: .movedToChapter(title: "Loomings")).contains("Loomings"))
    XCTAssertTrue(ListenTogetherAnnouncements.text(for: .speedChanged(rate: 1.5)).contains("1.5"))
  }

  func testDownloadAnnouncedOnlyAtQuarterSteps() {
    var posted: [String] = []
    let announcer = ListenTogetherAnnouncer(post: { posted.append($0) })
    for fraction in stride(from: 0.0, through: 1.0, by: 0.05) { announcer.announceDownload(fraction: fraction) }
    XCTAssertEqual(posted, [25, 50, 75, 100].map { ListenTogetherAnnouncements.download(percent: $0) })
  }
}
```

- [ ] **Step 2: Session service failing tests (with fake transport)**

```swift
@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

@MainActor
final class FakeTransport: ListenTogetherTransport {
  private var continuation: AsyncStream<TransportEvent>.Continuation!
  lazy var events: AsyncStream<TransportEvent> = AsyncStream { self.continuation = $0 }
  var sent: [ListenTogetherMessage] = []
  var uploads: [URL] = []
  var left = false
  var failUploads = false
  func emit(_ event: TransportEvent) { _ = events; continuation.yield(event) }
  func send(_ message: ListenTogetherMessage) async throws { sent.append(message) }
  func upload(fileAt url: URL) async throws -> UUID {
    if failUploads { throw URLError(.networkConnectionLost) }
    uploads.append(url); return UUID()
  }
  func leave() { left = true; continuation.finish() }
}

@MainActor
final class SharePlaySessionServiceTests: XCTestCase {
  private var root: URL!
  private var posted: [String] = []

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionTests-\(UUID())")
    posted = []
  }
  override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

  private func makeService() -> SharePlaySessionService {
    SharePlaySessionService(playerManager: PlayerManagerProtocolMock(),
                            storage: ShareStorage(root: root),
                            announcer: ListenTogetherAnnouncer(post: { [weak self] in self?.posted.append($0) }))
  }

  private func manifest(_ id: UUID) -> SharedBookManifest {
    SharedBookManifest(shareID: id, title: "T", author: "A", duration: 10,
                       chapters: [SharedChapter(title: "One", start: 0, duration: 10)],
                       pieces: [SharedPiece(index: 0, bookStart: 0, duration: 10, byteSize: 1)])
  }

  /// Gives the service's event loop a chance to run.
  private func settle() async { for _ in 0..<5 { await Task.yield() } }

  func testListenerReceivesManifestAndPieces() async throws {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    Task { await service.beginListening(with: transport, shareID: id) }
    await settle()
    transport.emit(.message(.manifest(manifest(id))))
    await settle()
    XCTAssertNotNil(service.listener)

    let attachment = UUID()
    let file = root.appendingPathComponent("incoming.m4a")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try AudioFixture.makeM4A(seconds: 10, at: file)
    transport.emit(.message(.pieceUploaded(index: 0, attachmentID: attachment)))
    transport.emit(.attachmentReceived(id: attachment, url: file))
    await settle()
    XCTAssertTrue(service.listener?.isReady(at: 1) == true)
    XCTAssertEqual(service.state, .listening(participants: 1, downloaded: 1))
  }

  func testRemoteActionIsAnnounced() async {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    Task { await service.beginListening(with: transport, shareID: id) }
    await settle()
    transport.emit(.message(.action(.paused)))
    await settle()
    XCTAssertEqual(posted.last, "listen_together_remote_paused".localized)
  }

  func testInvalidationDeletesListenerFiles() async throws {
    let service = makeService(), transport = FakeTransport(), id = UUID()
    let folder = try ShareStorage(root: root).folder(for: id, role: .listener)
    try Data([1]).write(to: folder.appendingPathComponent("piece-000.m4a"))
    Task { await service.beginListening(with: transport, shareID: id) }
    await settle()
    transport.emit(.invalidated)
    await settle()
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    XCTAssertEqual(service.state, .ended(reason: .normal))
    XCTAssertEqual(posted.last, ListenTogetherAnnouncements.ended())
  }

  func testManifestResentWhenParticipantsIncrease() async throws {
    let service = makeService(), transport = FakeTransport()
    let item = PlayableItemMock.stub(currentTime: 0, duration: 10)   // same factory as Task 6
    Task { await service.beginSharing(with: transport, item: item) }
    await settle()
    let before = transport.sent.filter { if case .manifest = $0 { return true } else { return false } }.count
    transport.emit(.participantsChanged(count: 3))
    await settle()
    let after = transport.sent.filter { if case .manifest = $0 { return true } else { return false } }.count
    XCTAssertEqual(after, before + 1)
    XCTAssertEqual(posted.last, ListenTogetherAnnouncements.joined())
  }

  func testUploadFailureEndsSessionWithMessage() async {
    let service = makeService(), transport = FakeTransport()
    transport.failUploads = true
    let item = PlayableItemMock.stub(currentTime: 0, duration: 10)
    await service.beginSharing(with: transport, item: item)
    await settle()
    XCTAssertEqual(service.state, .ended(reason: .sendFailed))
    XCTAssertTrue(transport.left)
  }
}
```
Note for `testManifestResentWhenParticipantsIncrease` and `testUploadFailureEndsSessionWithMessage`: the stub item's chapter file must exist for the splitter. Extend the Task 6 factory with an optional `fileURL` parameter and create the file with `AudioFixture.makeM4A(seconds: 10, at:)` in these tests, placing it under `DataManager.getProcessedFolderURL()` so `PlayableChapter.fileURL` resolves to it; remove it in `tearDown`.

- [ ] **Step 3: Register files, run, expect compile failures.**

- [ ] **Step 4: Implement the announcer**

```swift
import UIKit

enum ListenTogetherAnnouncements {
  static func text(for action: RemoteAction) -> String {
    switch action {
    case .paused: return "listen_together_remote_paused".localized
    case .resumed: return "listen_together_remote_resumed".localized
    case .skipped(let seconds):
      let amount = VoiceOverService.secondsToMinutes(Double(abs(seconds)))
      let key = seconds >= 0 ? "listen_together_remote_skipped_forward" : "listen_together_remote_skipped_back"
      return String.localizedStringWithFormat(key.localized, amount)
    case .movedToChapter(let title):
      return String.localizedStringWithFormat("listen_together_remote_chapter".localized, title)
    case .speedChanged(let rate):
      return String.localizedStringWithFormat("listen_together_remote_speed".localized,
                                              rate.formatted(.number.precision(.fractionLength(0...2))))
    }
  }
  static func joined() -> String { "listen_together_joined".localized }
  static func left() -> String { "listen_together_left".localized }
  static func ended() -> String { "listen_together_ended".localized }
  static func download(percent: Int) -> String {
    String.localizedStringWithFormat("listen_together_download_progress".localized, percent)
  }
}

@MainActor
final class ListenTogetherAnnouncer {
  private let post: (String) -> Void
  private var lastDownloadStep = 0

  init(post: @escaping (String) -> Void = ListenTogetherAnnouncer.postQueued) {
    self.post = post
  }

  func announce(_ text: String) { post(text) }

  func announceDownload(fraction: Double) {
    let step = Int((fraction * 4).rounded(.down)) * 25
    guard step > lastDownloadStep else { return }
    lastDownloadStep = step
    post(ListenTogetherAnnouncements.download(percent: step))
  }

  static func postQueued(_ text: String) {
    let queued = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
    UIAccessibility.post(notification: .announcement, argument: queued)
  }
}
```
If `VoiceOverService.secondsToMinutes` is not visible (it is `public static` in `BookPlayer/Services/VoiceOverService.swift`), check its access level; it is in the same app target so internal access is enough.

- [ ] **Step 5: Implement the transport**

`GroupSessionTransport` wraps `GroupSession`, `GroupSessionMessenger(session:)` and `GroupSessionJournal(session:)`. Verify journal API names first:
```bash
find "$(xcrun --sdk iphonesimulator --show-sdk-path)/System/Library/Frameworks/GroupActivities.framework" -name "*.swiftinterface" | head -1 | xargs grep -n "class GroupSessionJournal" -A60 | grep -n "func add\|var attachments\|func load\|struct Attachment\|func remove"
```
Then:
```swift
import GroupActivities
import UniformTypeIdentifiers

/// A received or sent audio piece. File-backed so 90 MB never sits in memory.
struct PieceTransfer: Transferable {
  let url: URL
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(contentType: .audio) { SentTransferredFile($0.url) } importing: { received in
      // The system deletes `received.file` after this returns, so move it somewhere we own.
      let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("ListenTogether-incoming-\(UUID().uuidString).\(received.file.pathExtension)")
      try FileManager.default.moveItem(at: received.file, to: destination)
      return PieceTransfer(url: destination)
    }
  }
}

@MainActor
final class GroupSessionTransport: ListenTogetherTransport {
  private let session: GroupSession<ListenTogetherActivity>
  private let messenger: GroupSessionMessenger
  private let journal: GroupSessionJournal
  private let downloadFolder: URL
  private var tasks: [Task<Void, Never>] = []
  private var seenAttachments = Set<UUID>()
  let events: AsyncStream<TransportEvent>
  private let continuation: AsyncStream<TransportEvent>.Continuation

  init(session: GroupSession<ListenTogetherActivity>, downloadFolder: URL) {
    self.session = session
    self.messenger = GroupSessionMessenger(session: session, deliveryMode: .reliable)
    self.journal = GroupSessionJournal(session: session)
    self.downloadFolder = downloadFolder
    (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)

    tasks.append(Task { [messenger, continuation] in
      for await (message, _) in messenger.messages(of: ListenTogetherMessage.self) {
        continuation.yield(.message(message))
      }
    })
    tasks.append(Task { [weak self] in
      guard let self else { return }
      for await participants in self.session.$activeParticipants.values {
        self.continuation.yield(.participantsChanged(count: participants.count))
      }
    })
    tasks.append(Task { [weak self] in
      guard let self else { return }
      for await state in self.session.$state.values {
        if case .invalidated = state { self.continuation.yield(.invalidated); self.continuation.finish() }
      }
    })
    tasks.append(Task { [weak self] in
      guard let self else { return }
      for await attachments in self.journal.attachments {
        for attachment in attachments where !self.seenAttachments.contains(attachment.id) {
          self.seenAttachments.insert(attachment.id)
          do {
            let piece = try await attachment.load(PieceTransfer.self)
            let destination = self.downloadFolder.appendingPathComponent(piece.url.lastPathComponent)
            try? FileManager.default.moveItem(at: piece.url, to: destination)
            self.continuation.yield(.attachmentReceived(id: attachment.id, url: destination))
          } catch {
            // Ignore our own uploads and transient failures; the sender's retry covers missing pieces.
          }
        }
      }
    })
  }

  func send(_ message: ListenTogetherMessage) async throws {
    try await messenger.send(message)
  }

  func upload(fileAt url: URL) async throws -> UUID {
    let attachment = try await journal.add(PieceTransfer(url: url))
    seenAttachments.insert(attachment.id)
    return attachment.id
  }

  func leave() {
    tasks.forEach { $0.cancel() }
    session.leave()
    continuation.finish()
  }
}
```

- [ ] **Step 6: Implement the session service**

Rules the implementation must follow (each is covered by a test above or in Task 10):

1. `startObservingSessions()` loops `for await session in ListenTogetherActivity.sessions()`. If `session.activity.shareID == pendingShareID` (this device started it), call `session.join()` and `beginSharing(with: transportFactory(session, sharerFolder), item:)`. Otherwise set `state = .invitation(title:author:)` and keep the session in `pendingInvitation`; `joinInvitation()` pauses the user's own book (`playerManager.pause()`), joins, and calls `beginListening(with: transportFactory(session, listenerFolder), shareID:)`. `declineInvitation()` calls `session.leave()` and returns to `.idle`.
2. `startSharing(_:)`: if `!GroupStateObserver().isEligibleForGroupSession`, set `.needsFaceTime` and stop. Otherwise set `pendingShareID`, `state = .preparing(title:)`, build `ListenTogetherActivity`, and `switch await activity.prepareForActivation() { case .activationPreferred: _ = try? await activity.activate(); case .activationDisabled: state = .ended(reason: .unavailable); case .cancelled: state = .idle; @unknown default: state = .idle }`.
3. `beginSharing`: create `SharerPlaybackTarget(playerManager:)` + bridge (bridge's `coordinate(with:)` is called by `startObservingSessions` for the real session; tests skip it); build the plan with `BookSplitter().sourceFiles(for:)` + `PiecePlanner.plan(files:chapterStarts:)`; send `.manifest` (pieces filled with `estimatedBytes` until exported, then resend after the first export with real sizes); export and upload in `uploadOrder(startingAt: item.currentTime)` order; after each upload send `.pieceUploaded(index:attachmentID:)`. Retry an upload twice; on the third failure announce `listen_together_send_failed`, send `.sessionEnding`, `transport.leave()`, `storage.remove(shareID:)`, `state = .ended(reason: .sendFailed)`.
4. Event loop (both roles), `for await event in transport.events`:
   - `.message(.manifest(m))` (listener): first time, create `ListenerPlayer(manifest: m)`, set `listener.onNeedsPiece = { [weak bridge, weak announcer] _ in bridge?.waitForPiece(); announcer?.announce("listen_together_waiting_download".localized) }` (announce once per wait, not per call), create the bridge with the listener as target; later times just keep the existing player.
   - `.message(.pieceUploaded(index, id))`: remember `id → index`; if the attachment already arrived, place it.
   - `.attachmentReceived(id, url)`: if `id` is known, move the file into the listener folder as `piece-NNN.<ext>`, call `listener.pieceArrived(index:url:)`, `bridge.pieceBecameAvailable()`, `announcer.announceDownload(fraction:)`, update `.listening(participants:downloaded:)`; otherwise hold it until its `pieceUploaded` arrives.
   - `.message(.action(a))`: `announcer.announce(ListenTogetherAnnouncements.text(for: a))`.
   - `.message(.sessionEnding)` or `.invalidated`: tear down (below) with `.normal`.
   - `.participantsChanged(n)`: compare with the previous count; more → announce `joined()` and, if sharing, resend the manifest and re-upload nothing (journal attachments reach late joiners automatically); fewer → announce `left()`. Update the count in `state`.
5. Local actions → messages: subscribe to the active target's `localEvents` and send `.action(...)`: `.played` → `.resumed`, `.paused` → `.paused`, `.seeked(to, from)` → `.movedToChapter(title)` when the chapter changed, else `.skipped(seconds: Int((to - from).rounded()))`, `.rateChanged(r)` → `.speedChanged(rate: r)`.
6. Teardown (`end()` and remote end): `bridge.invalidate()`, `listener?.stop()`, `listener = nil`, `transport.leave()`, `storage.remove(shareID:)`, announce `ended()`, `state = .ended(reason:)`. After 3 seconds return to `.idle` so the banner disappears.
7. `canShare(_:)`: `item != nil && BookSplitter.isShareable(item!)`.

- [ ] **Step 7: Run all SharePlay tests — PASS.**

```bash
xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan "Unit Tests" -only-testing:BookPlayerTests test 2>&1 | grep -E "error:|Executed|failed" | tail -8
```
Expected: total = baseline + new tests, 0 failures.

- [ ] **Step 8: Commit** (`SharePlay: session service, transport and VoiceOver announcements`).

---

### Task 10: UI — More menu, banner, invitation and listener screen (accessibility-reviewed)

**Files:**
- Create: `BookPlayer/BookPlayer/SharePlay/Views/ListenTogetherBanner.swift`, `.../Views/ListenerPlayerView.swift`, `.../Views/ListenTogetherInvitationView.swift`
- Modify: `BookPlayer/Player/ViewModels/PlayerViewModel.swift` (init + `setMoreAlert()` at line ~659), `BookPlayer/Player/Views/PlayerView.swift`, `BookPlayer/Coordinators/MainCoordinator.swift`, `BookPlayer/MainView.swift`, `BookPlayer/Utils/Extensions/Environment+BookPlayer.swift` (only if an environment key is used; prefer `.environmentObject`)
- Test: `BookPlayerTests/SharePlay/SharePlayMenuTests.swift`

**Interfaces:**
- Consumes: `SharePlaySessionService` (`state`, `listener`, `canShare`, `startSharing`, `joinInvitation`, `declineInvitation`, `end`), `ListenerPlayer`.
- Produces: `.environmentObject(sharePlayService)` injected by `MainCoordinator.start()`; `PlayerViewModel` gains an optional `sharePlayService: SharePlaySessionService?` init parameter (default `nil`, so existing call sites and tests compile unchanged).

- [ ] **Step 1: Accessibility consult before UI code.** Dispatch the `accessibility-agents:mobile-accessibility` agent with the spec's Accessibility section and this task's view list; ask for the SwiftUI labels, traits, heading, Magic Tap, focus and adjustable-action pattern for each view. Fold its answers into Steps 3–6. Record the consult in `Notes.md`.

- [ ] **Step 2: Failing tests for the menu**

```swift
@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

@MainActor
final class SharePlayMenuTests: XCTestCase {
  func testStreamedBookIsNotShareable() {
    // A chapter whose local file doesn't exist (as for streamed AudiobookShelf/Jellyfin/cloud books).
    let item = PlayableItemMock.stub(currentTime: 0, duration: 10)  // no file created
    let service = SharePlaySessionService(playerManager: PlayerManagerProtocolMock())
    XCTAssertFalse(service.canShare(item))
  }

  func testMoreMenuOffersListenTogetherOnlyWhenShareable() {
    // Build PlayerViewModel the same way existing tests do (see BookPlayerTests/ViewModels), passing a
    // service whose canShare returns false, call setMoreAlert(), and assert no action titled
    // "listen_together_title".localized; then with a shareable item assert exactly one.
  }
}
```
Replace the body of the second test with real setup copied from the closest existing `PlayerViewModel` construction in `BookPlayerTests` (search `PlayerViewModel(`). If none exists, construct it with `LibraryServiceProtocolMock`, `PlaybackServiceProtocolMock`, `PlayerManagerProtocolMock` and `SyncServiceProtocolMock` from the generated mocks (check exact names in `AutoMockable.generated.swift`).

- [ ] **Step 3: More menu item** — in `PlayerViewModel.setMoreAlert()`, after the existing actions and before `currentAlertOrigin = .more`:
```swift
    if let sharePlayService, sharePlayService.canShare(playerManager.currentItem),
       let item = playerManager.currentItem {
      actions.append(
        BPActionItem(
          title: "listen_together_title".localized,
          handler: { [weak sharePlayService] in
            Task { await sharePlayService?.startSharing(item) }
          }
        )
      )
    }
```
Pass the service from `MainView` where `PlayerViewModel(...)` is built (`MainView.swift` ~line 106) via `@EnvironmentObject var sharePlayService: SharePlaySessionService`.

- [ ] **Step 4: Banner** (`ListenTogetherBanner`): shown at the top of `PlayerView` when `state` is `.preparing`, `.sharing` or `.listening`. One combined element: `.accessibilityElement(children: .combine)` on the text with label from the matching `listen_together_status_*` string; a separate `Button("listen_together_end_button".localized)` with `bpFont(.body)`, minimum 44×44 pt. SF Symbol `shareplay` marked `.accessibilityHidden(true)`. Text uses `bpFont(.subheadline)` and `.fixedSize(horizontal: false, vertical: true)` so it wraps instead of truncating. When `.needsFaceTime`, show an alert (`listen_together_needs_facetime_title` / `_message`) with an OK button. When `.ended(.sendFailed)`, show the `listen_together_send_failed` text in the banner for 3 seconds.

- [ ] **Step 5: Invitation** (`ListenTogetherInvitationView`): a sheet presented from `MainView` when `state` is `.invitation`. Title as a heading (`.accessibilityAddTraits(.isHeader)`), message from `listen_together_invitation_message`, buttons Join and Not Now. VoiceOver focus goes to the heading when presented (`@AccessibilityFocusState`).

- [ ] **Step 6: Listener screen** (`ListenerPlayerView`): `.fullScreenCover` from `MainView` while `sharePlayService.listener != nil`. Contents, all `bpFont`:
  - Book title (`.accessibilityAddTraits(.isHeader)`, receives initial accessibility focus), author, current chapter from `manifest.chapter(at:)`.
  - Elapsed and remaining time as one element: label "Elapsed 12 minutes, remaining 3 hours 2 minutes" built with `VoiceOverService.secondsToMinutes`.
  - Position slider with `.accessibilityAdjustableAction` stepping by 30 seconds (`userSkip(by: ±30)`), value = elapsed.
  - Buttons: skip back 30 s, play/pause (label toggles "Play"/"Pause"; identifier `listenTogether.playPause`), skip forward 30 s, chapters (sheet listing `manifest.chapters`, each a Button calling `userJump(to: chapter.start)`), speed (Menu with 0.75, 1, 1.25, 1.5, 1.75, 2 calling `userSetRate`; value "1.5 times").
  - `.accessibilityAction(.magicTap) { listener.userTogglePlay() }`.
  - `ListenTogetherBanner` at the top with the End button.
  - Reduce Motion: no animated transitions when `accessibilityReduceMotion` is on.
  - On disappear (session ended), focus returns to the previous screen and `ListenTogetherAnnouncements.ended()` has already been posted by the service.

- [ ] **Step 7: Wire the service** in `MainCoordinator`: add `let sharePlayService: SharePlaySessionService` created in `init` with `SharePlaySessionService(playerManager: playerManager)`; in `start()` call `ShareStorage().cleanAll()` then `sharePlayService.startObservingSessions()`; add `.environmentObject(sharePlayService)` beside the existing `.environmentObject(playerManager)`. In `MainView`, add the invitation `.sheet` and listener `.fullScreenCover` (register/unregister in `listState.coversOnScreen` like the player cover does, adding a `.listenTogether` case to that set's element type if it is an enum).

- [ ] **Step 8: Register new files, build, run all tests.** Expected: build succeeds with no new warnings in SharePlay files; all tests pass.

- [ ] **Step 9: Accessibility review of the finished views.** Dispatch `accessibility-agents:mobile-accessibility` again on the three view files and the `PlayerViewModel` change; fix every issue it raises at error level; record the result in `Notes.md`.

- [ ] **Step 10: Commit** (`SharePlay: accessible Listen Together UI`).

---

### Task 11: Verification, notes and hand-off

- [ ] **Step 1: Full test run** (command from Task 9 Step 7). Record executed count and failures in `Notes.md` and `context.md`.
- [ ] **Step 2: Release-style build for the simulator**
```bash
xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer -configuration Release -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`. (Release reads `Release.xcconfig` placeholders; a missing-config crash at launch is irrelevant for a build-only check.)
- [ ] **Step 3: Confirm `PlayerManager.swift` is untouched:** `git diff develop --stat -- BookPlayer/Player/PlayerManager.swift` prints nothing.
- [ ] **Step 4: Update `context.md`** (current state, tests, what Becky must do for device testing: choose a bundle ID and team in `Debug.xcconfig`, enable the Group Activities capability for that ID in the developer portal, install on two devices, FaceTime call, run the spec's device acceptance list) **and append to `Notes.md`**.
- [ ] **Step 5: Commit** (`SharePlay: verification notes`). Do not push; ask Becky.
- [ ] **Step 6: Clean temporary files**: `rm -rf /private/tmp/bp-src` (the earlier read-only clone). Keep `/private/tmp/bp-tools` until the branch is merged or abandoned.
