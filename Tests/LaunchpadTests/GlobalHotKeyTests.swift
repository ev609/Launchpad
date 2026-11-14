import Carbon.HIToolbox
import XCTest
@testable import Launchpad

final class GlobalHotKeyTests: XCTestCase {
    func testReleaseAndRepeatedRegistration() async throws {
        try await MainActor.run {
            let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
            weak var released: GlobalHotKey?
            for _ in 0..<20 {
                var key = GlobalHotKey(keyCode: UInt32(kVK_F19), modifiers: modifiers, id: 0x54455354, callback: {})
                XCTAssertNotNil(key, "Не удалось зарегистрировать тестовое сочетание")
                guard key != nil else { return }
                released = key
                key = nil
                XCTAssertNil(released, "Статический реестр не должен удерживать горячую клавишу")
            }
            let key = try XCTUnwrap(GlobalHotKey(keyCode: UInt32(kVK_F19), modifiers: modifiers,
                                                id: 0x54455354, callback: {}))
            key.unregister()
            let replacement = GlobalHotKey(keyCode: UInt32(kVK_F19), modifiers: modifiers,
                                           id: 0x54455354, callback: {})
            XCTAssertNotNil(replacement)
            key.unregister() // Старый экземпляр не должен отключать новый.
            replacement?.unregister()
        }
    }
}
