import Foundation

/// Temporary files for Listen Together. Nothing here is part of the user's library.
struct ShareStorage {
  enum Role: String {
    case sharer
    case listener
  }

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
      let url = root
        .appendingPathComponent(role.rawValue, isDirectory: true)
        .appendingPathComponent(shareID.uuidString, isDirectory: true)
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Journal imports that never reached a share folder (a load that failed after the import ran).
  /// Emptied at every teardown as well as at launch (fix round 2, Minor 6).
  func removeIncoming() {
    try? FileManager.default.removeItem(at: root.appendingPathComponent("incoming", isDirectory: true))
  }

  /// Called at launch: no session can be active then, so anything left over is stale.
  func cleanAll() {
    try? FileManager.default.removeItem(at: root)
  }
}
