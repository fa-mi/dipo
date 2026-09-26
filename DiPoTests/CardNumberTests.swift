import XCTest
@testable import DiPo

/// The middle digits of a card number are not stored. These pin that, because
/// the failure is silent: a card written with all sixteen digits looks exactly
/// like one written correctly until the backup file is opened somewhere else.
final class CardNumberTests: XCTestCase {

    func testMiddleDigitsAreDropped() {
        let stored = CardNumber.stored("4234 5678 1234 7890")
        XCTAssertEqual(stored, "423456••••••7890")
        XCTAssertEqual(stored.filter(\.isNumber).count, 10,
                       "Only the BIN and the last four may survive.")
        XCTAssertFalse(stored.contains("5678"), "The middle digits are still in the store.")
        XCTAssertFalse(stored.contains("1234"))
    }

    /// The card form validates by counting characters, so the trimmed value has
    /// to stay the same length or editing a saved card starts failing.
    func testLengthIsPreserved() {
        XCTAssertEqual(CardNumber.stored("4234567812347890").count, 16)
    }

    func testRunningItAgainChangesNothing() {
        let once = CardNumber.stored("4234567812347890")
        XCTAssertEqual(CardNumber.stored(once), once)
    }

    /// A digital wallet keeps its provider name in the same field.
    func testWalletIdentifierSurvives() {
        XCTAssertEqual(CardNumber.stored("gopay"), "gopay")
        XCTAssertEqual(CardNumber.stored(""), "")
    }

    /// Nothing to hide in a partial number, and blanking it would lose what
    /// little it says.
    func testShortNumbersPassThrough() {
        XCTAssertEqual(CardNumber.stored("1234"), "1234")
        XCTAssertEqual(CardNumber.stored("4234567890"), "4234567890")
    }

    func testDetectionOfUntrimmedValues() {
        XCTAssertTrue(CardNumber.holdsMiddleDigits("4234567812347890"))
        XCTAssertFalse(CardNumber.holdsMiddleDigits("423456••••••7890"))
        XCTAssertFalse(CardNumber.holdsMiddleDigits("gopay"))
    }

    /// The two things the app actually reads off a card number still work on
    /// the trimmed form — this is the whole reason the middle can go.
    func testWhatTheAppReadsStillWorks() {
        let stored = CardNumber.stored("4234567812347890")
        XCTAssertEqual(stored.suffix(4), "7890")
        XCTAssertEqual(stored.suffix(2), "90")
        XCTAssertEqual(String(stored.filter(\.isNumber).prefix(6)), "423456",
                       "Issuer detection reads the BIN through the mask.")
        XCTAssertEqual(BankIssuer.detect(from: CardNumber.stored("5221845678127890"))?.id, "bri",
                       "A seeded BIN must still resolve after the middle is dropped.")
    }
}
