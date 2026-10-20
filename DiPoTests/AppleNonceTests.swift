import XCTest
@testable import DiPo

/// Sign in with Apple's nonce: Apple signs the SHA-256 into its token and
/// Firebase checks the raw value against it.
@MainActor
final class AppleNonceTests: XCTestCase {

    func testTheHashIsLowercaseHexSHA256() {
        // FIPS 180-2's "abc" vector.
        XCTAssertEqual(AppleNonce.sha256("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testEachRequestGetsItsOwnNonce() {
        let a = AppleNonce.make(), b = AppleNonce.make()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        XCTAssertTrue(a.allSatisfy(allowed.contains), a)
        XCTAssertEqual(AppleNonce.sha256(a).count, 64)
    }
}
