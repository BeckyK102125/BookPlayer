import Foundation
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
