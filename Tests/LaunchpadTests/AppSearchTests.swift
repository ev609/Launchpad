import XCTest
@testable import Launchpad

final class AppSearchTests: XCTestCase {
    private func app(_ name: String) -> AppEntry {
        AppEntry(name: name, path: "/\(name).app", bundleID: name)
    }

    func testExactAndPrefixMatchesPrecedeSubstring() {
        let apps = [app("My Safari"), app("Safari Technology Preview"), app("Safari")]
        XCTAssertEqual(AppSearch.results(for: "safari", in: apps).map(\.name),
                       ["Safari", "Safari Technology Preview", "My Safari"])
    }

    func testAbbreviationsWordsAndDiacritics() {
        let apps = [app("Google Chrome"), app("Visual Studio Code"), app("Café")]
        XCTAssertEqual(AppSearch.results(for: "gc", in: apps).first?.name, "Google Chrome")
        XCTAssertEqual(AppSearch.results(for: "vsc", in: apps).first?.name, "Visual Studio Code")
        XCTAssertEqual(AppSearch.results(for: "studio vis", in: apps).first?.name, "Visual Studio Code")
        XCTAssertEqual(AppSearch.results(for: "  CAFE\n", in: apps).first?.name, "Café")
    }

    func testWrongKeyboardLayoutInBothDirections() {
        let apps = [app("Safari"), app("Заметки")]
        XCTAssertEqual(AppSearch.results(for: "ыафкш", in: apps).first?.name, "Safari")
        XCTAssertEqual(AppSearch.results(for: "pfvtnrb", in: apps).first?.name, "Заметки")
    }

    func testEmptyAndUnmatchedQueriesReturnNoResults() {
        XCTAssertTrue(AppSearch.results(for: " \n", in: [app("Safari")]).isEmpty)
        XCTAssertTrue(AppSearch.results(for: "zzzz", in: [app("Safari")]).isEmpty)
    }

    func testFiveHundredAppsKeepExactMatchFirst() {
        let apps = (0..<500).map { app("Application \($0)") }
        XCTAssertEqual(AppSearch.results(for: "Application 49", in: apps).first?.name, "Application 49")
    }
}
