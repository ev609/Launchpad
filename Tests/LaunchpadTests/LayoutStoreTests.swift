import XCTest
@testable import Launchpad

final class LayoutStoreTests: XCTestCase {
    private var directory: URL!
    private var store: LayoutStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchpadTests-\(UUID().uuidString)", isDirectory: true)
        store = LayoutStore(baseURL: directory)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        store = nil
        directory = nil
    }

    func testLayoutRoundTrip() throws {
        let app = AppEntry(name: "Test", path: "/Applications/Test.app", bundleID: "test.app")
        let folder = Folder(id: "folder", name: "Tools", apps: [app])
        let expected = Layout(pages: [Page(id: "page", items: [.folder(folder)])])

        store.save(expected)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.pages, expected.pages)
    }

    func testCorruptLayoutIsBackedUp() throws {
        let broken = Data("{ definitely not json".utf8)
        try broken.write(to: store.fileURL)

        XCTAssertNil(store.load())
        XCTAssertEqual(try Data(contentsOf: store.fileURL.appendingPathExtension("corrupt")), broken)
    }

    func testResetRemovesSavedLayout() {
        store.save(.empty)
        XCTAssertNotNil(store.load())

        store.reset()

        XCTAssertNil(store.load())
    }

    func testFlushPersistsOnlyLatestQueuedLayout() throws {
        let first = Layout(pages: [Page(id: "first", items: [])])
        let latest = Layout(pages: [Page(id: "latest", items: [])])

        store.save(first)
        store.save(latest)
        store.flush()

        XCTAssertEqual(try XCTUnwrap(store.load()), latest)
    }

    func testValidJournalIsRecoveredOnLoad() throws {
        let old = Layout(pages: [Page(id: "old", items: [])])
        let recovered = Layout(pages: [Page(id: "recovered", items: [])])
        try JSONEncoder().encode(old).write(to: store.fileURL)
        try JSONEncoder().encode(recovered).write(to: store.journalURL)

        XCTAssertEqual(store.load(), recovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.journalURL.path))
        XCTAssertEqual(
            try JSONDecoder().decode(Layout.self, from: Data(contentsOf: store.fileURL)),
            recovered)
    }

    func testCorruptJournalDoesNotReplaceValidLayout() throws {
        let expected = Layout(pages: [Page(id: "valid", items: [])])
        let broken = Data("not json".utf8)
        try JSONEncoder().encode(expected).write(to: store.fileURL)
        try broken.write(to: store.journalURL)

        XCTAssertEqual(store.load(), expected)
        XCTAssertEqual(
            try Data(contentsOf: store.journalURL.appendingPathExtension("corrupt")),
            broken)
    }
}
