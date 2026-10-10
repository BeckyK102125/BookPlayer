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
