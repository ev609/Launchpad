import XCTest
@testable import Launchpad

final class AppScannerTests: XCTestCase {
    func testDirectoryWatcherCollapsesNestedRoots() {
        XCTAssertEqual(
            AppDirectoryWatcher.minimalRoots([
                "/Applications/Utilities",
                "/Applications",
                "/Applications",
                "/System/Applications/Utilities",
                "/System/Applications",
                "/Users/test/Applications",
            ]),
            ["/Applications", "/System/Applications", "/Users/test/Applications"]
        )
    }

    func testDirectoryWatcherUsesExistingParentForMissingRoot() {
        let existing = Set(["/", "/Users", "/Users/test"])
        XCTAssertEqual(
            AppDirectoryWatcher.watchRoots(
                for: ["/Applications", "/Users/test/Applications"],
                directoryExists: { existing.contains($0) }),
            ["/", "/Users/test"]
        )
    }

    func testDirectoryWatcherRecognizesEventsThatRequireRestart() {
        XCTAssertTrue(AppDirectoryWatcher.requiresStreamRestart(
            FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)))
        XCTAssertTrue(AppDirectoryWatcher.requiresStreamRestart(
            FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)))
        XCTAssertFalse(AppDirectoryWatcher.requiresStreamRestart(
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)))
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func makeApp(_ relativePath: String, id: String) throws -> URL {
        let url = directory.appendingPathComponent(relativePath)
        let contents = url.appendingPathComponent("Contents")
        let executables = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": id, "CFBundleExecutable": "Test", "CFBundleName": id,
                     "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executables.appendingPathComponent("Test"))
        return url
    }

    func testScanFindsChangesInsideExistingSubdirectory() throws {
        let first = try makeApp("Tools/First.app", id: "first")
        XCTAssertEqual(AppScanner.scanResult(paths: [directory.path]).apps.map(\.id), ["first"])
        _ = try makeApp("Tools/Second.app", id: "second")
        XCTAssertEqual(Set(AppScanner.scanResult(paths: [directory.path]).apps.map(\.id)), ["first", "second"])
        try FileManager.default.removeItem(at: first)
        XCTAssertEqual(AppScanner.scanResult(paths: [directory.path]).apps.map(\.id), ["second"])
    }

    func testUnavailableRootIsReportedSeparatelyFromEmptyDirectory() {
        XCTAssertTrue(AppScanner.scanResult(paths: [directory.path]).unavailablePaths.isEmpty)
        let missing = directory.appendingPathComponent("Unavailable").path
        let result = AppScanner.scanResult(paths: [missing])
        XCTAssertTrue(result.apps.isEmpty)
        XCTAssertEqual(result.unavailablePaths, [missing])
    }

    func testSecondCopyWithSameBundleIDGetsOwnIDAndHelpersAreSkipped() throws {
        _ = try makeApp("First.app", id: "same")
        let second = try makeApp("Second.app", id: "same")
        _ = try makeApp("First.app/Contents/Helper.app", id: "helper")
        let result = AppScanner.scanResult(paths: [directory.path])
        XCTAssertEqual(result.apps.map(\.id), ["same", "same@" + second.path])
        XCTAssertEqual(result.apps.filter(\.isPrimaryCopy).map(\.name), ["First"])
    }

    func testSymlinkToSameBundleIsNotACopy() throws {
        let app = try makeApp("Real.app", id: "real")
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("Alias.app"), withDestinationURL: app)
        XCTAssertEqual(AppScanner.scanResult(paths: [directory.path]).apps.count, 1)
    }

    func testSecondCopyWithSameNameShowsFolder() {
        let entry = AppEntry(name: "Xcode", path: "/Users/me/Applications/Xcode.app", bundleID: "x")
        let copy = AppScanner.secondaryCopy(entry, primaryName: "Xcode")
        XCTAssertEqual(copy.id, "x@/Users/me/Applications/Xcode.app")
        XCTAssertTrue(copy.name.hasPrefix("Xcode ("))
        XCTAssertFalse(copy.isPrimaryCopy)
    }

    func testOnlyTrailingAppExtensionIsStripped() {
        XCTAssertEqual(AppScanner.strippingAppExtension("Safari.app"), "Safari")
        XCTAssertEqual(AppScanner.strippingAppExtension("My.app Helper"), "My.app Helper")
    }
}
