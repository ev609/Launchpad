import XCTest
@testable import Launchpad

final class ModelsTests: XCTestCase {
    func testStableApplicationIdentifierPrefersBundleIdentifier() {
        let app = AppEntry(name: "App", path: "/tmp/App.app", bundleID: "com.example.app")
        XCTAssertEqual(app.id, "com.example.app")
        XCTAssertEqual(LaunchpadItem.app(app).id, "app:com.example.app")
    }

    func testPathIsUsedWhenBundleIdentifierIsMissing() {
        let app = AppEntry(name: "App", path: "/tmp/App.app", bundleID: nil)
        XCTAssertEqual(app.id, "/tmp/App.app")
    }

    func testModelsCodableRoundTrip() throws {
        let apps = [
            AppEntry(name: "One", path: "/One.app", bundleID: "one"),
            AppEntry(name: "Two", path: "/Two.app", bundleID: "two"),
        ]
        let page = Page(id: "page", items: [.folder(Folder(id: "folder", name: "Folder", apps: apps))])
        let data = try JSONEncoder().encode(Layout(pages: [page]))
        let decoded = try JSONDecoder().decode(Layout.self, from: data)
        XCTAssertEqual(decoded.pages, [page])
    }

    func testLayoutNormalizationSplitsOverflowWithoutLosingItems() {
        let items = (0..<7).map { index in
            LaunchpadItem.app(AppEntry(name: "App \(index)",
                                       path: "/App\(index).app",
                                       bundleID: "app.\(index)"))
        }
        let pages = LayoutNormalizer.normalize([Page(id: "first", items: items)], itemsPerPage: 3)

        XCTAssertEqual(pages.map { $0.items.count }, [3, 3, 1])
        XCTAssertEqual(pages.flatMap(\.items), items)
        XCTAssertEqual(pages.first?.id, "first")
    }

    func testLayoutNormalizationKeepsOneEmptyPage() {
        let pages = LayoutNormalizer.normalize([], itemsPerPage: 30)
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages[0].items.isEmpty)
    }

    func testGridMetricsAdaptIconSizeToAvailableCells() {
        let spacious = GridMetrics(size: CGSize(width: 2560, height: 1440),
                                   columns: 7, rows: 5)
        let dense = GridMetrics(size: CGSize(width: 1280, height: 720),
                                columns: 10, rows: 8)

        XCTAssertEqual(spacious.iconSize, 88)
        XCTAssertGreaterThanOrEqual(dense.iconSize, 32)
        XCTAssertLessThan(dense.iconSize, spacious.iconSize)
        XCTAssertLessThanOrEqual(dense.iconSize, dense.cellH - 24)
    }
}
