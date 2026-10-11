@testable import BookPlayer
@testable import BookPlayerKit
import CryptoKit
import XCTest

/// Addendum 2 ("Both have the book"): the fingerprint, the matching rules, and the pure decisions
/// around them. No library, no session, no clock.
@MainActor
final class BookFingerprintTests: XCTestCase {
  private var folder: URL!

  override func setUp() async throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("FingerprintTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: folder)
  }

  private func file(_ start: TimeInterval, _ duration: TimeInterval, _ size: Int64) -> BookFingerprint.File {
    BookFingerprint.File(bookStart: start, duration: duration, byteSize: size)
  }

  private func shared(hash: String? = "abc", title: String = "The Hobbit", author: String = "J. R. R. Tolkien")
    -> BookFingerprint
  {
    BookFingerprint(
      title: title, author: author, duration: 600,
      files: [file(0, 300, 3_000_000), file(300, 300, 3_000_000)], sampleHash: hash)
  }

  // MARK: Normalising

  func testNormalizeFoldsCaseAndTrimsWhitespaceAndPunctuation() {
    XCTAssertEqual(BookFingerprint.normalize("  The Hobbit!  "), "the hobbit")
    XCTAssertEqual(BookFingerprint.normalize("\"THE   HOBBIT\"."), "the hobbit")
    XCTAssertEqual(BookFingerprint.normalize("Émile"), "emile")
    XCTAssertEqual(BookFingerprint.normalize(""), "")
  }

  func testFingerprintStoresNormalisedTitleAndAuthor() {
    let print = shared(title: " The Hobbit. ", author: "TOLKIEN")
    XCTAssertEqual(print.title, "the hobbit")
    XCTAssertEqual(print.author, "tolkien")
  }

  // MARK: Matching rules

  func testSameHashAndLayoutMatchesEvenWithDifferentTitles() {
    let candidate = BookFingerprint(
      title: "Renamed", author: "", duration: 601.5,
      files: [file(0, 301, 9_000_000), file(301, 299, 1)], sampleHash: "abc")
    XCTAssertTrue(BookFingerprintMatcher.matches(shared: shared(), candidate: candidate))
  }

  func testTitleAuthorAndSizesWithinOnePercentMatchWithoutHash() {
    let candidate = BookFingerprint(
      title: "the hobbit", author: "j. r. r. tolkien", duration: 599,
      files: [file(0, 299, 3_029_000), file(299, 300, 2_971_000)], sampleHash: "different")
    XCTAssertTrue(BookFingerprintMatcher.matches(shared: shared(), candidate: candidate))
  }

  func testSizeOffByMoreThanOnePercentDoesNotMatchWithoutHash() {
    let candidate = BookFingerprint(
      title: "The Hobbit", author: "J. R. R. Tolkien", duration: 600,
      files: [file(0, 300, 3_000_000), file(300, 300, 3_040_000)], sampleHash: nil)
    XCTAssertFalse(BookFingerprintMatcher.matches(shared: shared(), candidate: candidate))
  }

  func testTitleMatchButAuthorDiffersDoesNotMatchWithoutHash() {
    let candidate = BookFingerprint(
      title: "The Hobbit", author: "Someone Else", duration: 600,
      files: [file(0, 300, 3_000_000), file(300, 300, 3_000_000)], sampleHash: nil)
    XCTAssertFalse(BookFingerprintMatcher.matches(shared: shared(), candidate: candidate))
  }

  func testTotalDurationBeyondTwoSecondsDoesNotMatch() {
    let candidate = BookFingerprint(
      title: "The Hobbit", author: "J. R. R. Tolkien", duration: 602.5,
      files: [file(0, 300, 3_000_000), file(300, 300, 3_000_000)], sampleHash: "abc")
    XCTAssertFalse(BookFingerprintMatcher.matches(shared: shared(), candidate: candidate))
  }

  func testDifferentFileCountDoesNotMatch() {
    let candidate = BookFingerprint(
      title: "The Hobbit", author: "J. R. R. Tolkien", duration: 600,
      files: [file(0, 600, 6_000_000)], sampleHash: "abc")
    XCTAssertFalse(BookFingerprintMatcher.matches(shared: shared(), candidate: candidate))
  }

  func testOneFileDurationBeyondTwoSecondsDoesNotMatch() {
    // Same total, but the split between the files differs: a different edition.
    let candidate = BookFingerprint(
      title: "The Hobbit", author: "J. R. R. Tolkien", duration: 600,
      files: [file(0, 297, 3_000_000), file(297, 303, 3_000_000)], sampleHash: "abc")
    XCTAssertFalse(BookFingerprintMatcher.matches(shared: shared(), candidate: candidate))
  }

  func testMissingSharedHashFallsBackToTitleAuthorAndSizes() {
    let candidate = BookFingerprint(
      title: "The Hobbit", author: "J. R. R. Tolkien", duration: 600,
      files: [file(0, 300, 3_000_000), file(300, 300, 3_000_000)], sampleHash: nil)
    XCTAssertTrue(BookFingerprintMatcher.matches(shared: shared(hash: nil), candidate: candidate))
    let other = BookFingerprint(
      title: "Other", author: "J. R. R. Tolkien", duration: 600,
      files: [file(0, 300, 3_000_000), file(300, 300, 3_000_000)], sampleHash: nil)
    XCTAssertFalse(BookFingerprintMatcher.matches(shared: shared(hash: nil), candidate: other))
  }

  func testTieGoesToTheMostRecentlyPlayed() {
    let print = shared()
    let old = Date(timeIntervalSince1970: 1_000), recent = Date(timeIntervalSince1970: 2_000)
    let candidates: [(fingerprint: BookFingerprint, lastPlayed: Date?, value: String)] = [
      (print, nil, "never"), (print, old, "old"), (print, recent, "recent"),
      (shared(hash: "zzz", title: "Other"), Date(timeIntervalSince1970: 9_000), "no match"),
    ]
    XCTAssertEqual(BookFingerprintMatcher.bestMatch(shared: print, candidates: candidates), "recent")
    XCTAssertEqual(
      BookFingerprintMatcher.bestMatch(shared: print, candidates: [(print, nil, "a"), (print, nil, "b")]), "a")
    let none: [(fingerprint: BookFingerprint, lastPlayed: Date?, value: String)] = []
    XCTAssertNil(BookFingerprintMatcher.bestMatch(shared: print, candidates: none))
  }

  // MARK: Sample hash

  func testSampleHashReadsOnlyTheFirst64KB() throws {
    let start = Data((0..<BookFingerprint.sampleLength).map { UInt8($0 % 251) })
    let a = folder.appendingPathComponent("a.m4a"), b = folder.appendingPathComponent("b.m4a")
    try (start + Data(repeating: 1, count: 1_000)).write(to: a)
    try (start + Data(repeating: 2, count: 5_000)).write(to: b)
    let hashA = BookFingerprint.sampleHash(of: a)
    XCTAssertNotNil(hashA)
    XCTAssertEqual(hashA, BookFingerprint.sampleHash(of: b))
    XCTAssertEqual(hashA?.count, 64, "hex SHA-256")

    let c = folder.appendingPathComponent("c.m4a")
    var different = start
    different[10] ^= 0xFF
    try different.write(to: c)
    XCTAssertNotEqual(hashA, BookFingerprint.sampleHash(of: c))
  }

  func testSampleHashOfSmallOrMissingFile() async throws {
    let small = folder.appendingPathComponent("small.m4a")
    try Data([1, 2, 3]).write(to: small)
    let offMain = await BookFingerprint.sampleHashOffMain(of: small)
    XCTAssertEqual(offMain, BookFingerprint.sampleHash(of: small))
    XCTAssertNotNil(offMain)
    XCTAssertNil(BookFingerprint.sampleHash(of: folder.appendingPathComponent("missing.m4a")))
  }

  // MARK: Own copy on the shared timeline

  func testOwnFilesBecomePiecesAtTheSharersBookTimes() {
    let own = [
      SourceFile(url: folder.appendingPathComponent("1.mp3"), bookStart: 0, duration: 301, byteSize: 10),
      SourceFile(url: folder.appendingPathComponent("2.mp3"), bookStart: 301, duration: 299, byteSize: 20),
    ]
    let pieces = ListenTogetherOwnCopy.pieces(
      ownFiles: own, sharedFiles: [file(0, 300, 1), file(300, 300, 1)])
    XCTAssertEqual(pieces, [
      SharedPiece(index: 0, bookStart: 0, duration: 300, byteSize: 10),
      SharedPiece(index: 1, bookStart: 300, duration: 300, byteSize: 20),
    ])
    // Without the sharer's layout, the own layout is used.
    XCTAssertEqual(ListenTogetherOwnCopy.pieces(ownFiles: own, sharedFiles: []).map(\.bookStart), [0, 301])
  }

  func testOwnCopyIsStillAvailableOnlyWithTheSameFiles() throws {
    let url = folder.appendingPathComponent("own.m4a")
    try Data(repeating: 7, count: 100).write(to: url)
    let copy = ListenTogetherOwnCopy(
      relativePath: "own.m4a", files: [SourceFile(url: url, bookStart: 0, duration: 10, byteSize: 100)],
      chapters: [], duration: 10)
    XCTAssertTrue(copy.isStillAvailable())
    try Data(repeating: 7, count: 50).write(to: url)
    XCTAssertFalse(copy.isStillAvailable(), "the file changed since the invitation")
    try FileManager.default.removeItem(at: url)
    XCTAssertFalse(copy.isStillAvailable(), "the file was moved or deleted")
  }

  // MARK: Decisions

  func testInvitationKind() {
    XCTAssertEqual(ListenTogetherInvitationKind.decide(hasOwnCopy: true, ownersOnly: false), .ownCopy)
    XCTAssertEqual(ListenTogetherInvitationKind.decide(hasOwnCopy: true, ownersOnly: true), .ownCopy)
    XCTAssertEqual(ListenTogetherInvitationKind.decide(hasOwnCopy: false, ownersOnly: false), .sendCopy)
    XCTAssertEqual(ListenTogetherInvitationKind.decide(hasOwnCopy: false, ownersOnly: true), .needsOwnCopy)
  }

  func testJoinPlanRechecksTheCopy() {
    typealias S = SharePlaySessionService
    XCTAssertEqual(S.joinPlan(hadOwnCopy: true, isStillAvailable: true, ownersOnly: false), .ownCopy)
    XCTAssertEqual(S.joinPlan(hadOwnCopy: true, isStillAvailable: true, ownersOnly: true), .ownCopy)
    XCTAssertEqual(S.joinPlan(hadOwnCopy: true, isStillAvailable: false, ownersOnly: false), .download)
    XCTAssertEqual(S.joinPlan(hadOwnCopy: true, isStillAvailable: false, ownersOnly: true), .declineCopyUnusable)
    XCTAssertEqual(S.joinPlan(hadOwnCopy: false, isStillAvailable: false, ownersOnly: false), .download)
  }

  func testSharingModeDefaultsToSendingAndIsReadPerDevice() throws {
    let suite = "FingerprintTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(ListenTogetherSharingMode.current(in: defaults), .sendCopy)
    defaults.set(ListenTogetherSharingMode.ownersOnly.rawValue, forKey: ListenTogetherSharingMode.defaultsKey)
    XCTAssertEqual(ListenTogetherSharingMode.current(in: defaults), .ownersOnly)
    defaults.set("nonsense", forKey: ListenTogetherSharingMode.defaultsKey)
    XCTAssertEqual(ListenTogetherSharingMode.current(in: defaults), .sendCopy)
  }

  func testFirstShareNoteAndEndHintFollowTheMode() {
    XCTAssertEqual(ListenTogetherSharingMode.sendCopy.firstShareMessage, "listen_together_first_share_message".localized)
    XCTAssertEqual(
      ListenTogetherSharingMode.ownersOnly.firstShareMessage,
      "listen_together_first_share_message_owners_only".localized)
    let listening = ListenTogetherState.listening(participants: 2, downloaded: 1)
    XCTAssertEqual(ListenTogetherStatus.endHint(for: listening), "listen_together_end_hint_listener".localized)
    XCTAssertEqual(
      ListenTogetherStatus.endHint(for: listening, usesOwnCopy: true),
      "listen_together_end_hint_listener_own_copy".localized)
    // Complete from the start: no "getting the book" percent.
    XCTAssertEqual(ListenTogetherStatus.spokenText(for: listening), String.localizedStringWithFormat(
      "listen_together_status_listening".localized, 2))
  }

  func testNeedsCopyNoticeWording() {
    let notFound = ListenTogetherNeedsCopyNotice(bookTitle: "Dune", cause: .notFound)
    XCTAssertEqual(notFound.title, "listen_together_need_copy_title".localized)
    XCTAssertTrue(notFound.message.contains("Dune"))
    let unusable = ListenTogetherNeedsCopyNotice(bookTitle: "Dune", cause: .copyUnusable)
    XCTAssertEqual(unusable.title, "listen_together_copy_unusable_title".localized)
    XCTAssertTrue(unusable.message.contains("Dune"))
  }

  /// Fix round 1 (a11y I3): never dropped after 10 s; while the app isn't active the notice waits for
  /// the next activation.
  func testNeedsCopyAlertWaitsForTheAppToBeActive() {
    typealias C = MainCoordinator
    XCTAssertEqual(C.needsCopyPresentationStep(presented: true, attempt: 1, hasNotice: true, isActive: true), .shown)
    XCTAssertEqual(C.needsCopyPresentationStep(presented: false, attempt: 1, hasNotice: true, isActive: true), .retry)
    // Fix round 2 (M-a): active but nothing to present from keeps retrying; the notice's 60 s age limit
    // ends it, never a wait for an activation that may not come.
    XCTAssertEqual(
      C.needsCopyPresentationStep(presented: false, attempt: C.invitationMaxAttempts * 5, hasNotice: true, isActive: true),
      .retry)
    XCTAssertEqual(
      C.needsCopyPresentationStep(presented: false, attempt: 1, hasNotice: true, isActive: false), .waitForActive)
    XCTAssertEqual(
      C.needsCopyPresentationStep(presented: false, attempt: 3, hasNotice: false, isActive: true), .notNeeded)
  }

  func testCheckTimedOutNoticeDoesNotClaimTheBookIsMissing() {
    let notice = ListenTogetherNeedsCopyNotice(bookTitle: "Dune", cause: .checkTimedOut)
    XCTAssertEqual(notice.title, "listen_together_check_failed_title".localized)
    XCTAssertEqual(notice.message, String.localizedStringWithFormat(
      "listen_together_check_failed_message".localized, "Dune"))
    XCTAssertFalse(notice.message.contains("did not find"))
  }

  // MARK: Audio sample hash (fix round 1, code I1: the audio data, not the tags)

  private let audio = Data((0..<100_000).map { UInt8(($0 * 7 + $0 / 300) % 256) })

  private func sha(_ data: Data) -> String {
    SHA256.hash(data: data.prefix(BookFingerprint.sampleLength)).map { String(format: "%02x", $0) }.joined()
  }

  private func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
  private func be64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

  private func atom(_ type: String, _ payload: Data) -> Data {
    be32(UInt32(8 + payload.count)) + Data(type.utf8) + payload
  }

  private func largeAtom(_ type: String, _ payload: Data) -> Data {
    be32(1) + Data(type.utf8) + be64(UInt64(16 + payload.count)) + payload
  }

  private func write(_ data: Data, _ name: String) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  private var ftyp: Data { atom("ftyp", Data("M4B \0\0\0\0M4B isom".utf8)) }

  func testMP4HashCoversTheAudioNotTheTags() throws {
    let a = try write(ftyp + atom("moov", Data(repeating: 1, count: 70_000)) + atom("mdat", audio), "a.m4b")
    let b = try write(
      ftyp + atom("moov", Data(repeating: 2, count: 90_000)) + atom("free", Data(count: 100)) + atom("mdat", audio),
      "b.m4b")
    var other = audio
    other[10] ^= 0xFF
    let c = try write(ftyp + atom("moov", Data(repeating: 1, count: 70_000)) + atom("mdat", other), "c.m4b")
    XCTAssertEqual(BookFingerprint.sampleHash(of: a), sha(audio))
    XCTAssertEqual(BookFingerprint.sampleHash(of: a), BookFingerprint.sampleHash(of: b), "different tags, same audio")
    XCTAssertNotEqual(BookFingerprint.sampleHash(of: a), BookFingerprint.sampleHash(of: c))
  }

  func testMP4WithLargeSizeOrTrailingMoovStillHashesTheAudio() throws {
    let large = try write(ftyp + atom("moov", Data(count: 500)) + largeAtom("mdat", audio), "large.m4a")
    let trailing = try write(ftyp + atom("mdat", audio) + atom("moov", Data(count: 500)), "trailing.m4a")
    XCTAssertEqual(BookFingerprint.sampleHash(of: large), sha(audio))
    XCTAssertEqual(BookFingerprint.sampleHash(of: trailing), sha(audio))
  }

  func testBrokenMP4FallsBackToTheFileStart() throws {
    // An atom claiming more bytes than the file has: not parsed, the file start is hashed.
    let bytes = ftyp + be32(9_999_999) + Data("moov".utf8) + Data(repeating: 3, count: 1_000)
    let url = try write(bytes, "broken.m4a")
    XCTAssertEqual(BookFingerprint.sampleHash(of: url), sha(bytes))
  }

  private func id3(bodySize: Int, footer: Bool) -> Data {
    func synchsafe(_ value: Int) -> Data {
      Data([UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)])
    }
    var tag = Data("ID3".utf8) + Data([4, 0, footer ? 0x10 : 0]) + synchsafe(bodySize)
    tag += Data(repeating: 0x41, count: bodySize)
    if footer { tag += Data("3DI".utf8) + Data([4, 0, 0x10]) + synchsafe(bodySize) }
    return tag
  }

  func testID3TagWithAnInvalidSynchsafeSizeFallsBackToTheFileStart() throws {
    // 0x80 in a synchsafe byte is not allowed: not parsed, the file start is hashed.
    let bytes = Data("ID3".utf8) + Data([4, 0, 0, 0x00, 0x80, 0x10, 0x00]) + Data(repeating: 9, count: 2_000) + audio
    let url = try write(bytes, "invalid.mp3")
    XCTAssertEqual(BookFingerprint.sampleHash(of: url), sha(bytes))
  }

  func testMP4MdatRunningToTheEndOfTheFile() throws {
    // size == 0: the atom runs to the end of the file.
    let url = try write(ftyp + atom("moov", Data(count: 300)) + be32(0) + Data("mdat".utf8) + audio, "toend.m4a")
    XCTAssertEqual(BookFingerprint.sampleHash(of: url), sha(audio))
  }

  func testMP3HashSkipsTheID3Tag() throws {
    let frames = Data([0xFF, 0xFB, 0x90, 0x64]) + audio
    let small = try write(id3(bodySize: 5_000, footer: false) + frames, "small.mp3")
    let big = try write(id3(bodySize: 70_000, footer: true) + frames, "big.mp3")
    let bare = try write(frames, "bare.mp3")
    XCTAssertEqual(BookFingerprint.sampleHash(of: small), sha(frames))
    XCTAssertEqual(BookFingerprint.sampleHash(of: big), sha(frames), "cover art in the tag doesn't change it")
    XCTAssertEqual(BookFingerprint.sampleHash(of: bare), sha(frames))
  }

  // MARK: Wire format

  func testActivityAndManifestDecodeWithoutTheNewFields() throws {
    let id = UUID()
    let oldActivity = #"{"shareID":"\#(id.uuidString)","title":"T","author":"A"}"#
    let activity = try JSONDecoder().decode(ListenTogetherActivity.self, from: Data(oldActivity.utf8))
    XCTAssertNil(activity.fingerprint)
    XCTAssertFalse(activity.isOwnersOnly)

    let full = ListenTogetherActivity(shareID: id, title: "T", author: "A", fingerprint: shared(), ownersOnly: true)
    let decoded = try JSONDecoder().decode(ListenTogetherActivity.self, from: JSONEncoder().encode(full))
    XCTAssertEqual(decoded.fingerprint, shared())
    XCTAssertTrue(decoded.isOwnersOnly)

    let manifest = SharedBookManifest(
      shareID: id, title: "T", author: "A", duration: 1, chapters: [], pieces: [], fingerprint: shared())
    XCTAssertEqual(try JSONDecoder().decode(SharedBookManifest.self, from: JSONEncoder().encode(manifest)), manifest)
    let message = ListenTogetherMessage.declinedNoCopy
    XCTAssertEqual(try JSONDecoder().decode(ListenTogetherMessage.self, from: JSONEncoder().encode(message)), message)
  }
}
