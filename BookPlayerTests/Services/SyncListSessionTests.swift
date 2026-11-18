//
//  SyncListSessionTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation
import SwiftData
import XCTest

@testable import BookPlayer
@testable import BookPlayerKit

/// BP-20261112-04: a list refresh's answer is applied only if no logout or lapse happened while it
/// was on its way, so a former account's listing can't change the library of the next one.
/// Main actor: the tests use the main-queue view context (see LibraryServiceTests).
@MainActor
final class SyncListSessionTests: XCTestCase {
  /// Holds the root listing until the test releases it
  private final class HeldListingClient: NetworkClientMock, @unchecked Sendable {
    private let lock = NSLock()
    private var _content = [[String: Any]]()
    private var _gate: CheckedContinuation<Void, Never>?

    var isHoldingListing: Bool { lock.withLock { _gate != nil } }

    init() {
      super.init(mockedResponse: Empty())
    }

    func setContent(_ content: [[String: Any]]) {
      lock.withLock { _content = content }
    }

    func releaseListing() {
      let gate = lock.withLock {
        let gate = _gate
        _gate = nil
        return gate
      }
      gate?.resume()
    }

    override func request<T: Decodable>(
      path: String,
      method: HTTPMethod,
      parameters: [String: Any]?
    ) async throws -> T {
      var object: Any = [String: Any]()
      if path == "/v1/library", method == .get {
        await withCheckedContinuation { continuation in
          lock.withLock { _gate = continuation }
        }
        object = ["content": lock.withLock { _content }]
      }
      return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
  }

  private var defaults: UserDefaults!
  private var defaultsSuite = ""
  private var tasksDataManager: TasksDataManager!
  private var dataManager: DataManager!
  private var libraryService: LibraryService!
  private var queue: SyncQueueService!
  private var client: HeldListingClient!
  private var sync: SyncService!

  override func setUpWithError() throws {
    defaultsSuite = "SyncListSessionTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: defaultsSuite)

    let schema = Schema([
      UploadTaskModel.self,
      UpdateTaskModel.self,
      MoveTaskModel.self,
      DeleteTaskModel.self,
      DeleteBookmarkTaskModel.self,
      SetBookmarkTaskModel.self,
      RenameFolderTaskModel.self,
      ArtworkUploadTaskModel.self,
      MatchUuidsTaskModel.self,
      UploadExternalResourceTaskModel.self,
      ExternalResourceToDownloadTaskModel.self,
      DeleteExternalResourceTaskModel.self,
      SyncQueueContainer.self,
      QueuedTaskReferenceModel.self,
      ExternalUpdateTaskModel.self,
      UploadFileTaskModel.self,
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    tasksDataManager = TasksDataManager(container: try ModelContainer(for: schema, configurations: config))

    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    dataManager = DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null"))
    libraryService = LibraryService()
    libraryService.setup(dataManager: dataManager, audioMetadataService: AudioMetadataService())
    _ = libraryService.getLibrary()

    client = HeldListingClient()
    queue = SyncQueueService(maxConcurrentTasks: 1)
    queue.taskContainer = SyncQueueRepository(tasksDataManager: tasksDataManager)
    queue.tasksDataManager = tasksDataManager
    queue.dataManager = dataManager
    queue.libraryService = libraryService
    queue.accessPolicy = [.uploadFile: true, .externalUpdate: true]
    queue.networkClient = client

    sync = SyncService()
    sync.setup(
      isActive: true,
      libraryService: libraryService,
      accountService: AccountServiceMock(account: nil),
      syncQueueService: queue,
      client: client,
      runsMissingItemsPass: false,
      userDefaults: defaults
    )
    queue.setServerLanesEnabled(false)
  }

  override func tearDown() {
    client.releaseListing()
    defaults.removePersistentDomain(forName: defaultsSuite)
    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    sync = nil
    queue = nil
    tasksDataManager = nil
    super.tearDown()
  }

  func testAListingThatArrivesAfterLogoutChangesNothing() async throws {
    let local = rootBook("Local")
    client.setContent([SyncResponseFixtures.itemJSON(relativePath: "Remote.m4b")])

    let refresh = Task { try await sync.syncListContents(at: nil) }
    try await waitUntil { client.isHoldingListing }
    await sync.logout()
    client.releaseListing()
    try await refresh.value

    let remoteExists = await libraryService.itemExists(for: "Remote.m4b")
    let localExists = await libraryService.itemExists(for: local.relativePath)
    XCTAssertFalse(remoteExists, "the former account's item must not be added")
    XCTAssertTrue(localExists, "nothing may be removed for the former account")
  }

  /// The same refresh with no logout is applied in full
  func testAListingInTheSameSessionIsApplied() async throws {
    let local = rootBook("Local")
    client.setContent([SyncResponseFixtures.itemJSON(relativePath: "Remote.m4b")])

    let refresh = Task { try await sync.syncListContents(at: nil) }
    try await waitUntil { client.isHoldingListing }
    client.releaseListing()
    try await refresh.value

    let remoteExists = await libraryService.itemExists(for: "Remote.m4b")
    let localExists = await libraryService.itemExists(for: local.relativePath)
    XCTAssertTrue(remoteExists)
    XCTAssertFalse(localExists)
  }

  // MARK: - Helpers

  /// A book at the library root
  private func rootBook(_ title: String) -> Book {
    let book = StubFactory.book(dataManager: dataManager, title: title, duration: 100)
    libraryService.getLibraryReference().addToItems(book)
    dataManager.saveContext()
    return book
  }

  private func waitUntil(timeout: TimeInterval = 3, _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("timed out")
  }
}
