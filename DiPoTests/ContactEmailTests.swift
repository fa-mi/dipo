import XCTest
@testable import DiPo

/// The email typed in Profile outlives signing out: it is kept on the server
/// and brought back, ahead of Apple's relay address, after the next sign-in.
@MainActor
final class ContactEmailTests: XCTestCase {

    /// The same shape firestore.rules accepts, so what Profile takes the server keeps.
    func testWhatCountsAsAnAddress() {
        for good in ["fahmi@example.com", "a.b+c@sub.domain.co.id", "x@y.io"] {
            XCTAssertTrue(ContactEmail.isValid(good), good)
        }
        for bad in ["", "fahmi", "fahmi@", "@example.com", "fahmi@example", "fa hmi@example.com",
                    "a@b@c.com", "fahmi@example.com ", String(repeating: "x", count: 250) + "@b.co"] {
            XCTAssertFalse(ContactEmail.isValid(bad), bad)
        }
    }

    func testApplesRelayIsRecognised() {
        XCTAssertTrue(ContactEmail.isRelay("abc123@privaterelay.appleid.com"))
        XCTAssertTrue(ContactEmail.isRelay("ABC@PrivateRelay.AppleID.com"))
        XCTAssertFalse(ContactEmail.isRelay("fahmi@gmail.com"))
    }

    /// After signing out the phone has nothing, so the server's address comes
    /// back. Apple's relay gives way to an address the user typed; anything
    /// else on the phone was typed here and stays.
    func testWhichAddressIsShown() {
        XCTAssertEqual(ContactEmail.preferred(local: nil, server: "fahmi@example.com"), "fahmi@example.com")
        XCTAssertEqual(ContactEmail.preferred(local: "", server: "fahmi@example.com"), "fahmi@example.com")
        XCTAssertEqual(ContactEmail.preferred(local: "x1@privaterelay.appleid.com", server: "fahmi@example.com"), "fahmi@example.com")
        XCTAssertEqual(ContactEmail.preferred(local: "new@example.com", server: "old@example.com"), "new@example.com")
        XCTAssertEqual(ContactEmail.preferred(local: "fahmi@example.com", server: nil), "fahmi@example.com")
        // A relay on the server never replaces one typed on the phone.
        XCTAssertEqual(ContactEmail.preferred(local: "fahmi@example.com", server: "x1@privaterelay.appleid.com"), "fahmi@example.com")
        // A server value that isn't an address is ignored.
        XCTAssertNil(ContactEmail.preferred(local: nil, server: "not an email"))
        XCTAssertNil(ContactEmail.preferred(local: nil, server: nil))
    }
}
