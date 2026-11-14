import CryptoKit
import XCTest
@testable import Launchpad

final class UpdaterTests: XCTestCase {
    func testDisplayVersionSeparatesReleaseBuildAndDate() {
        XCTAssertEqual(
            Updater.formattedDisplayVersion(version: "0.2.2", build: "20260919.035939",
                                            dateText: "2026-09-19 08:59:39 +05:00"),
            "0.2.2 · build 20260919.035939 · 2026-09-19 08:59:39 +05:00"
        )
    }

    func testNumericVersionComparison() {
        XCTAssertTrue(Updater.isNewer("0.2.3", than: "0.2.2"))
        XCTAssertTrue(Updater.isNewer("1.0", than: "0.9.99"))
        XCTAssertTrue(Updater.isNewer("1.0.1", than: "1"))
        XCTAssertFalse(Updater.isNewer("0.2.2", than: "0.2.2"))
        XCTAssertFalse(Updater.isNewer("0.2.1", than: "0.2.2"))
    }

    func testEd25519SignatureVerification() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let archive = Data("signed release archive".utf8)
        let signature = try privateKey.signature(for: archive)
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()

        XCTAssertTrue(Updater.isValidSignature(archive: archive,
                                               signature: signature,
                                               publicKeyBase64: publicKey))
        XCTAssertFalse(Updater.isValidSignature(archive: Data("tampered".utf8),
                                                signature: signature,
                                                publicKeyBase64: publicKey))
    }

    func testPublicKeyListSupportsRotation() {
        XCTAssertEqual(Updater.publicKeys(from: "old, new"), ["old", "new"])
        XCTAssertEqual(Updater.publicKeys(from: ["old", " new "]), ["old", "new"])
        XCTAssertEqual(Updater.publicKeys(from: "single"), ["single"])
        XCTAssertEqual(Updater.publicKeys(from: nil), [])
    }

    func testInvalidPublicKeyIsRejected() {
        XCTAssertFalse(Updater.isValidSignature(archive: Data(),
                                                signature: Data(repeating: 0, count: 64),
                                                publicKeyBase64: "not-base64"))
    }
    func testReleaseParsingDistinguishesNoUpdateFromInvalidRelease() throws {
        let current = Data(#"{"tag_name":"v1.0","assets":[]}"#.utf8)
        XCTAssertNil(try Updater.parseRelease(current, currentVersion: "1.0"))
        XCTAssertThrowsError(try Updater.parseRelease(current, currentVersion: "0.9"))
        XCTAssertThrowsError(try Updater.parseRelease(Data("broken".utf8), currentVersion: "0.9"))
        let valid = Data(#"{"tag_name":"v1.1","assets":[{"name":"Launchpad.zip","browser_download_url":"https://example.com/app.zip"},{"name":"Launchpad.zip.sig","browser_download_url":"https://example.com/app.sig"}]}"#.utf8)
        XCTAssertEqual(try Updater.parseRelease(valid, currentVersion: "1.0")?.version, "1.1")
    }

}
