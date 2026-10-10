@testable import BookPlayer
import MediaPlayer
import XCTest

@MainActor
final class ListenTogetherNowPlayingTests: XCTestCase {
  private let chapters = [
    SharedChapter(title: "Loomings", start: 0, duration: 100),
    SharedChapter(title: "The Carpet-Bag", start: 100, duration: 200),
  ]

  private func state(
    bookTime: TimeInterval = 150, rate: Float = 1.5, isPlaying: Bool = true, isWaiting: Bool = false,
    chapters: [SharedChapter]? = nil, author: String = "Herman Melville"
  ) -> ListenTogetherNowPlayingState {
    ListenTogetherNowPlayingState(
      title: "Moby Dick", author: author, chapters: chapters ?? self.chapters, duration: 300,
      bookTime: bookTime, rate: rate, isPlaying: isPlaying, isWaitingForPiece: isWaiting)
  }

  func testPlayingFields() {
    let playing = state()
    let info = ListenTogetherNowPlaying.info(for: playing)
    XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "The Carpet-Bag")
    XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Moby Dick")
    XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Herman Melville")
    XCTAssertEqual(info[MPNowPlayingInfoPropertyChapterNumber] as? Int, 2)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyChapterCount] as? Int, 2)
    XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 300)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 150)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyMediaType] as? UInt, MPNowPlayingInfoMediaType.audio.rawValue)
    XCTAssertNil(info[MPMediaItemPropertyArtwork])
    XCTAssertEqual(ListenTogetherNowPlaying.playbackState(for: playing), .playing)
  }

  func testPausedHasRateZero() {
    let paused = state(isPlaying: false)
    XCTAssertEqual(ListenTogetherNowPlaying.info(for: paused)[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
    XCTAssertEqual(ListenTogetherNowPlaying.playbackState(for: paused), .paused)
  }

  func testWaitingForAPieceShowsPaused() {
    let waiting = state(isPlaying: true, isWaiting: true)
    XCTAssertEqual(ListenTogetherNowPlaying.info(for: waiting)[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
    XCTAssertEqual(ListenTogetherNowPlaying.playbackState(for: waiting), .paused)
  }

  func testWithoutChaptersTheBookTitleAndAuthorAreUsed() {
    let info = ListenTogetherNowPlaying.info(for: state(chapters: []))
    XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Moby Dick")
    XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Herman Melville")
    XCTAssertNil(info[MPNowPlayingInfoPropertyChapterNumber])
    let noAuthor = ListenTogetherNowPlaying.info(for: state(chapters: [], author: ""))
    XCTAssertNil(noAuthor[MPMediaItemPropertyArtist])
    XCTAssertNil(noAuthor[MPMediaItemPropertyAlbumTitle])
  }

  func testPublishOnlyOnRealChanges() {
    let t0 = Date(timeIntervalSince1970: 1000)
    let playing = state(bookTime: 150, rate: 1)
    XCTAssertTrue(ListenTogetherNowPlaying.shouldPublish(playing, previous: nil, publishedAt: nil, now: t0))
    // Ticks that follow the extrapolated time: no publish.
    XCTAssertFalse(ListenTogetherNowPlaying.shouldPublish(
      state(bookTime: 155, rate: 1), previous: playing, publishedAt: t0, now: t0 + 5))
    // A seek: publish.
    XCTAssertTrue(ListenTogetherNowPlaying.shouldPublish(
      state(bookTime: 185, rate: 1), previous: playing, publishedAt: t0, now: t0 + 5))
    // Pause, wait, speed and chapter changes: publish.
    XCTAssertTrue(ListenTogetherNowPlaying.shouldPublish(
      state(bookTime: 150, rate: 1, isPlaying: false), previous: playing, publishedAt: t0, now: t0))
    XCTAssertTrue(ListenTogetherNowPlaying.shouldPublish(
      state(bookTime: 150, rate: 1, isWaiting: true), previous: playing, publishedAt: t0, now: t0))
    XCTAssertTrue(ListenTogetherNowPlaying.shouldPublish(
      state(bookTime: 150, rate: 1.5), previous: playing, publishedAt: t0, now: t0))
    XCTAssertFalse(ListenTogetherNowPlaying.shouldPublish(
      state(bookTime: 99, rate: 1), previous: state(bookTime: 99, rate: 1), publishedAt: t0, now: t0))
    XCTAssertTrue(ListenTogetherNowPlaying.shouldPublish(
      state(bookTime: 99.5, rate: 1, chapters: chapters), previous: state(bookTime: 100.5, rate: 1),
      publishedAt: t0, now: t0))
    // A modest refresh while playing.
    XCTAssertTrue(ListenTogetherNowPlaying.shouldPublish(
      state(bookTime: 165, rate: 1), previous: playing, publishedAt: t0, now: t0 + 15))
    // Paused: only a position change publishes.
    let paused = state(bookTime: 150, isPlaying: false)
    XCTAssertFalse(ListenTogetherNowPlaying.shouldPublish(paused, previous: paused, publishedAt: t0, now: t0 + 60))
    XCTAssertTrue(ListenTogetherNowPlaying.shouldPublish(
      state(bookTime: 150.4, isPlaying: false), previous: paused, publishedAt: t0, now: t0 + 1))
  }

  func testPublisherSendsOnlyWhileActive() {
    let sink = FakeNowPlayingSink()
    let publisher = ListenTogetherNowPlayingPublisher(sink: sink, now: { Date(timeIntervalSince1970: 0) })
    publisher.update(state())
    XCTAssertTrue(sink.published.isEmpty, "inactive")
    publisher.start(gettingBookTitle: "Moby Dick")
    XCTAssertEqual(sink.published.last?.info?[MPMediaItemPropertyTitle] as? String, "Moby Dick")
    XCTAssertEqual(sink.published.last?.state, .paused)
    publisher.update(state())
    XCTAssertEqual(sink.published.last?.state, .playing)
    let count = sink.published.count
    publisher.update(state())
    XCTAssertEqual(sink.published.count, count, "unchanged: not published again")
    publisher.stop()
    publisher.update(state(isPlaying: false))
    XCTAssertEqual(sink.published.count, count)
  }
}
