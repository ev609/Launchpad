import XCTest
import SQLite3
@testable import Launchpad

final class InteractionTests: XCTestCase {
    func testImporterPreservesPageAndFolderOrdering() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE items (type INTEGER, parent_id INTEGER, ordering INTEGER);
        CREATE TABLE apps (item_id INTEGER, bundleid TEXT);
        CREATE TABLE groups (item_id INTEGER, title TEXT);
        INSERT INTO items (rowid,type,parent_id,ordering) VALUES
        (1,1,0,0),(2,3,1,0),(3,4,2,0),(4,2,2,1),(5,4,4,0),(6,4,4,1),(7,4,4,2);
        INSERT INTO apps VALUES (3,'A'),(5,'b'),(6,'c'),(7,'missing');
        INSERT INTO groups VALUES (4,'Tools');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let apps = ["a", "b", "c"].map { AppEntry(name: $0, path: "/\($0).app", bundleID: $0) }
        let layout = try XCTUnwrap(LaunchpadImporter.importLayout(dbURL: url, installed: apps))
        XCTAssertEqual(layout.pages.count, 1)
        XCTAssertEqual(layout.pages[0].items[0], .app(apps[0]))
        guard case .folder(let folder) = layout.pages[0].items[1] else { return XCTFail("Missing folder") }
        XCTAssertEqual(folder.name, "Tools")
        XCTAssertEqual(folder.apps, Array(apps[1...]))
    }

    func testMissingImporterDatabaseDoesNotCreateFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).db")
        XCTAssertNil(LaunchpadImporter.importLayout(dbURL: url, installed: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func touches(radius: Float, center: Float = 0.5) -> [MTTouch] {
        (0..<3).map { index in
            var touch = MTTouch()
            let angle = Float(index) * 2 * .pi / 3
            touch.normalized.pos = MTPoint(x: center + radius * cos(angle), y: 0.5 + radius * sin(angle))
            return touch
        }
    }

    func testPinchInAndOutRecognition() async {
        let inward = expectation(description: "pinch in")
        let outward = expectation(description: "pinch out")
        let first = MultitouchManager()
        first.onPinchIn = { inward.fulfill() }
        for radius: Float in [0.35, 0.15] {
            var frame = touches(radius: radius)
            frame.withUnsafeMutableBufferPointer { first.handle(touches: $0.baseAddress, count: $0.count) }
        }
        let second = MultitouchManager()
        second.onPinchOut = { outward.fulfill() }
        for radius: Float in [0.1, 0.35] {
            var frame = touches(radius: radius)
            frame.withUnsafeMutableBufferPointer { second.handle(touches: $0.baseAddress, count: $0.count) }
        }
        await fulfillment(of: [inward, outward], timeout: 1)
        withExtendedLifetime((first, second)) {}
    }

    func testThreeFingerSwipeDoesNotTriggerPinch() async {
        let noPinch = expectation(description: "no pinch")
        noPinch.isInverted = true
        let manager = MultitouchManager()
        manager.onPinchIn = { noPinch.fulfill() }
        manager.onPinchOut = { noPinch.fulfill() }
        for center: Float in [0.3, 0.4, 0.5, 0.6] {
            var frame = touches(radius: 0.3, center: center)
            frame.withUnsafeMutableBufferPointer { manager.handle(touches: $0.baseAddress, count: $0.count) }
        }
        await fulfillment(of: [noPinch], timeout: 0.05)
        withExtendedLifetime(manager) {}
    }
}
