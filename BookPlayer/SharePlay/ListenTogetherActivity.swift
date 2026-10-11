import Foundation
import GroupActivities

struct ListenTogetherActivity: GroupActivity {
  let shareID: UUID
  let title: String
  let author: String
  /// Lets an invited listener find their own copy before the invitation is shown (addendum 2). The
  /// manifest only arrives after joining, so the invitation carries it. Optional for older shares.
  var fingerprint: BookFingerprint? = nil
  /// The sharer chose "Only people who have the book can join" for this share. Optional for older
  /// shares (nil means the book is sent).
  var ownersOnly: Bool? = nil

  var isOwnersOnly: Bool { ownersOnly == true }

  var metadata: GroupActivityMetadata {
    var metadata = GroupActivityMetadata()
    metadata.title = String.localizedStringWithFormat("listen_together_activity_title".localized, title)
    metadata.subtitle = author
    metadata.type = .listenTogether
    return metadata
  }
}
