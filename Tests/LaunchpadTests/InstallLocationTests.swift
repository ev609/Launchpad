import XCTest
@testable import Launchpad

final class InstallLocationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallLocationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    func testDevelopmentBuildIsNotAppBundle() {
        XCTAssertEqual(InstallLocation.problem(bundlePath: "/Users/me/Launchpad/.build/debug"),
                       .notAppBundle)
    }

    func testTranslocatedCopyIsRejected() {
        let path = "/private/var/folders/xy/T/AppTranslocation/1234-ABCD/d/Launchpad.app"
        XCTAssertEqual(InstallLocation.problem(bundlePath: path), .translocated)
    }

    func testWritableFolderIsAccepted() throws {
        let app = directory.appendingPathComponent("Launchpad.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertNil(InstallLocation.problem(bundlePath: app.path))
    }

    func testReadOnlyParentBlocksUpdatesOnly() throws {
        let app = directory.appendingPathComponent("Launchpad.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        XCTAssertEqual(InstallLocation.problem(bundlePath: app.path), .parentNotWritable)
    }
}
