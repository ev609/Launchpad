import XCTest
@testable import Launchpad

final class AppSettingsTests: XCTestCase {
    func testCustomDirectoriesAndHiddenAppsPersist() {
        let suite = "LaunchpadTests.Settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.addCustomDirectory("/tmp/Apps/../Apps"))
        XCTAssertFalse(settings.addCustomDirectory("/tmp/Apps"))
        settings.setAppHidden("example.app", hidden: true)

        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.customAppDirectories, ["/tmp/Apps"])
        XCTAssertEqual(restored.hiddenAppIDs, Set(["example.app"]))
    }

    func testNavigationStatePersistsAndCanBeCleared() {
        let suite = "LaunchpadTests.Navigation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let state = LaunchpadNavigationState(pageID: "page-2", itemID: "folder:tools",
                                             folderID: "tools", folderAppID: "editor")

        settings.saveNavigationState(state)
        XCTAssertEqual(AppSettings(defaults: defaults).navigationState, state)

        settings.saveNavigationState(LaunchpadNavigationState())
        XCTAssertEqual(AppSettings(defaults: defaults).navigationState,
                       LaunchpadNavigationState())
    }
}
