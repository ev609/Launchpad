import Carbon.HIToolbox
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

    func testCustomHotkeyRequiresModifierExceptFunctionKeys() {
        XCTAssertNil(CustomHotkey.make(keyCode: UInt16(kVK_ANSI_L), modifierFlags: [], characters: "l"))
        XCTAssertNil(CustomHotkey.make(keyCode: UInt16(kVK_ANSI_L), modifierFlags: .shift, characters: "l"))
        let f5 = CustomHotkey.make(keyCode: UInt16(kVK_F5), modifierFlags: [], characters: nil)
        XCTAssertEqual(f5?.title, "F5")
        let combo = CustomHotkey.make(keyCode: UInt16(kVK_ANSI_L),
                                      modifierFlags: [.command, .shift], characters: "l")
        XCTAssertEqual(combo?.title, "⇧⌘L")
        XCTAssertEqual(combo?.modifiers, UInt32(cmdKey | shiftKey))
    }

    func testCustomHotkeyPersistsAndFallsBackWhenMissing() {
        let suite = "LaunchpadTests.Hotkey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customHotkey = CustomHotkey(keyCode: UInt32(kVK_ANSI_L),
                                             modifiers: UInt32(cmdKey), keyName: "L")
        settings.hotkey = .custom
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.effectiveHotkey?.title, "⌘L")

        restored.customHotkey = nil
        XCTAssertEqual(AppSettings(defaults: defaults).hotkey, .f4)
    }

    func testPinchGestureIsOnByDefaultAndPersists() {
        let suite = "LaunchpadTests.Pinch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.pinchGesture)
        settings.pinchGesture = false
        XCTAssertFalse(AppSettings(defaults: defaults).pinchGesture)
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
