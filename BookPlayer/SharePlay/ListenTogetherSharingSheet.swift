import Foundation

/// How Listen Together starts when the sharer chooses it.
enum ListenTogetherStartRoute: Equatable {
  /// On a FaceTime call: `prepareForActivation()` and `activate()`.
  case activate
  /// Not on a call: Apple's sharing sheet (Messages, contacts, or FaceTime from the sheet).
  case sharingSheet
  /// Not on a call and the sheet can't be shown: the "Couldn't open sharing" alert.
  case needsFaceTime
}

/// How Apple's sharing sheet (`GroupActivitySharingController`) finished.
enum ListenTogetherSharingSheetOutcome: Equatable {
  /// The person chose people and sent the invitation. The session should arrive shortly.
  case sent
  /// The person closed the sheet without sending.
  case cancelled
  /// The controller could not be created or presented.
  case unavailable
}

/// Shows Apple's sharing sheet for a Listen Together activity. MainCoordinator presents it from the
/// topmost screen; tests use a fake.
@MainActor
protocol ListenTogetherSharingSheetPresenting: AnyObject {
  /// False when there is nowhere to present the sheet (no window yet).
  var canPresentSharingSheet: Bool { get }
  /// Presents the sheet silently and returns once it has finished.
  func presentSharingSheet(for activity: ListenTogetherActivity) async -> ListenTogetherSharingSheetOutcome
}
