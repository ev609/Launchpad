import AppKit
import XCTest
@testable import Launchpad

final class AppDeletionTests: XCTestCase {
    private var directory: URL!
    private var store: LayoutStore!
    private var suite: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDeletionTests-\(UUID().uuidString)", isDirectory: true)
        store = LayoutStore(baseURL: directory)
        suite = "AppDeletionTests.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        store.flush()
        try FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    @MainActor
    private func model(trash: @escaping (URL) async throws -> Void) -> (LaunchpadModel, AppEntry) {
        let app = AppEntry(name: "Fixture", path: directory.appendingPathComponent("Fixture.app").path,
                           bundleID: "test.deletion.fixture")
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        let model = LaunchpadModel(layoutStore: store, settings: settings,
                                   scanApps: { [app] }, trashApp: trash)
        model.load()
        model.pages = [Page(items: [.app(app)])]
        model.searchText = "Fixture"
        return (model, app)
    }

    @MainActor
    func testConfirmedSuccessRemovesApplicationFromLayoutAndSearch() async {
        var requestedURL: URL?
        let (model, app) = model { requestedURL = $0 }
        let deleted = await model.deleteApp(app)
        XCTAssertTrue(deleted)
        XCTAssertEqual(requestedURL?.path, app.path)
        XCTAssertFalse(model.pages.flatMap(\.items).flatMap(\.containedApps).contains(app))
        XCTAssertTrue(model.allApps.isEmpty)
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertNil(model.operationError)
    }

    @MainActor
    func testPermissionFailurePreservesApplicationAndReportsError() async {
        let (model, app) = model { _ in throw CocoaError(.fileWriteNoPermission) }
        let pages = model.pages
        let deleted = await model.deleteApp(app)
        XCTAssertFalse(deleted)
        XCTAssertEqual(model.pages, pages)
        XCTAssertEqual(model.allApps, [app])
        XCTAssertEqual(model.searchResults, [app])
        XCTAssertNotNil(model.operationError)
    }

    @MainActor
    func testCancellationPreservesApplicationWithoutError() async {
        let (model, app) = model { _ in throw CocoaError(.userCancelled) }
        let pages = model.pages
        let deleted = await model.deleteApp(app)
        XCTAssertFalse(deleted)
        XCTAssertEqual(model.pages, pages)
        XCTAssertEqual(model.allApps, [app])
        XCTAssertNil(model.operationError)
    }

    @MainActor
    func testSystemApplicationNeverReachesTrashOperation() async {
        var called = false
        let (model, _) = model { _ in called = true }
        let system = AppEntry(name: "Protected", path: "/System/Applications/Protected.app",
                              bundleID: "test.protected")
        let deleted = await model.deleteApp(system)
        XCTAssertFalse(deleted)
        XCTAssertFalse(called)
    }

    @MainActor
    func testWorkspaceTrashWithTemporaryFixture() async throws {
        let fixture = directory.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let marker = Data("Disposable deletion test fixture".utf8)
        try marker.write(to: fixture.appendingPathComponent("marker"))
        var destination: URL?
        defer {
            if let destination { try? FileManager.default.removeItem(at: destination) }
        }
        let (model, app) = model { url in
            let moved = try await NSWorkspace.shared.recycle([url])
            destination = moved[url]
            guard destination != nil else { throw CocoaError(.fileWriteUnknown) }
        }
        let deleted = await model.deleteApp(app)
        XCTAssertTrue(deleted, model.operationError ?? "No reported error")
        let trashed = try XCTUnwrap(destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path))
        XCTAssertEqual(try Data(contentsOf: trashed.appendingPathComponent("marker")), marker)
    }

    @MainActor
    func testPermissionDenialDelegatesExactURLToFinder() async throws {
        let url = directory.appendingPathComponent("Fixture.app")
        var requested: URL?
        try await AppTrashService.trash(url,
            recycle: { _ in throw CocoaError(.fileWriteNoPermission) },
            finderTrash: { requested = $0 })
        XCTAssertEqual(requested, url)
    }

    @MainActor
    func testCancellationDoesNotAttemptFinderFallback() async {
        var called = false
        do {
            try await AppTrashService.trash(directory.appendingPathComponent("Fixture.app"),
                recycle: { _ in throw CocoaError(.userCancelled) },
                finderTrash: { _ in called = true })
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual((error as NSError).code, NSUserCancelledError)
        }
        XCTAssertFalse(called)
    }

    @MainActor
    func testOtherFailuresDoNotAttemptFinderFallback() async {
        var called = false
        do {
            try await AppTrashService.trash(directory.appendingPathComponent("Fixture.app"),
                recycle: { _ in throw CocoaError(.fileNoSuchFile) },
                finderTrash: { _ in called = true })
            XCTFail("Expected missing-file error")
        } catch {
            XCTAssertEqual((error as NSError).code, NSFileNoSuchFileError)
        }
        XCTAssertFalse(called)
    }

    func testUnderlyingPOSIXPermissionFailureIsRecognized() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain,
                                                                    code: Int(EACCES))])
        XCTAssertTrue(AppTrashService.isPermissionError(error))
    }

    func testFinderCancellationAndAutomationDenialAreExplained() {
        let cancelled = AppTrashService.finderError("Finder: User canceled. (-128)") as NSError
        XCTAssertEqual(cancelled.domain, NSCocoaErrorDomain)
        XCTAssertEqual(cancelled.code, NSUserCancelledError)
        let denied = AppTrashService.finderError("Not authorized to send Apple events. (-1743)")
        XCTAssertTrue(denied.localizedDescription.contains("Автоматизация"))
    }

    @MainActor
    func testFinderFallbackWithTemporaryFixtureAndLiteralPath() async throws {
        let fixture = directory.appendingPathComponent("Finder '\" $() `literal` \(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let marker = Data("Disposable Finder deletion fixture".utf8)
        try marker.write(to: fixture.appendingPathComponent("marker"))
        var destination: URL?
        defer {
            if let destination { try? FileManager.default.removeItem(at: destination) }
        }
        try await AppTrashService.trash(fixture,
            recycle: { _ in throw CocoaError(.fileWriteNoPermission) },
            finderTrash: { destination = try await AppTrashService.trashUsingFinder($0) })
        let trashed = try XCTUnwrap(destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path))
        XCTAssertEqual(try Data(contentsOf: trashed.appendingPathComponent("marker")), marker)
    }
}
