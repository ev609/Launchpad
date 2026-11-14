import XCTest
@testable import Launchpad

final class AppLauncherTests: XCTestCase {
    func testMissingApplicationReportsFailure() async {
        let done = expectation(description: "launch failed")
        let closes = expectation(description: "launcher closes immediately")
        let reopens = expectation(description: "launcher reopens after failure")
        let center = NotificationCenter.default
        let closeObserver = center.addObserver(forName: .launchpadShouldClose,
                                               object: nil, queue: .main) { _ in
            closes.fulfill()
        }
        let showObserver = center.addObserver(forName: .launchpadShouldShow,
                                              object: nil, queue: .main) { _ in
            reopens.fulfill()
        }
        defer {
            center.removeObserver(closeObserver)
            center.removeObserver(showObserver)
        }
        let app = AppEntry(name: "Missing", path: "/tmp/LaunchpadMissing-\(UUID().uuidString).app", bundleID: nil)
        await MainActor.run {
            AppLauncher.launch(app) { error in
                XCTAssertNotNil(error)
                XCTAssertTrue(Thread.isMainThread)
                done.fulfill()
            }
        }
        await fulfillment(of: [closes, reopens, done], timeout: 5)
    }
}
