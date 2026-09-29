import XCTest
@testable import DiPo

/// Every amount field reads text through NumberInput. These are the numbers
/// people actually type or paste: rupiah with dot grouping, a decimal comma,
/// a rate with three decimals, an amount copied with its "Rp".
final class NumberInputTests: XCTestCase {

    /// The bug this replaced: `Double("25.000")` is 25, and
    /// `Double("1.000.000")` is nil, so those saved Rp25 and nothing.
    func testRupiahGroupingIsThousands() {
        XCTAssertEqual(NumberInput.amount("25.000"), 25_000)
        XCTAssertEqual(NumberInput.amount("1.000.000"), 1_000_000)
        XCTAssertEqual(NumberInput.amount("150.000"), 150_000)
        XCTAssertEqual(NumberInput.amount("25000"), 25_000)
    }

    func testDecimalsEitherWay() {
        XCTAssertEqual(NumberInput.amount("25,5"), 25.5, accuracy: 1e-12)
        XCTAssertEqual(NumberInput.amount("12.43"), 12.43, accuracy: 1e-12)
        XCTAssertEqual(NumberInput.amount("1.234.567,89"), 1_234_567.89, accuracy: 1e-6)
        XCTAssertEqual(NumberInput.amount("1,234,567.89"), 1_234_567.89, accuracy: 1e-6)
        XCTAssertEqual(NumberInput.amount("0.125"), 0.125, accuracy: 1e-12)
    }

    func testCopiedCurrencyMarkersAreIgnored() {
        XCTAssertEqual(NumberInput.amount("Rp 25.000"), 25_000)
        XCTAssertEqual(NumberInput.amount("Rp.25.000"), 25_000)
        XCTAssertEqual(NumberInput.amount("IDR 1.500.000"), 1_500_000)
        XCTAssertEqual(NumberInput.amount("$12.43"), 12.43, accuracy: 1e-12)
    }

    func testUnreadableIsZero() {
        XCTAssertEqual(NumberInput.amount(""), 0)
        XCTAssertEqual(NumberInput.amount("abc"), 0)
        XCTAssertEqual(NumberInput.amount("-25.000"), 0)
        XCTAssertFalse(NumberInput.isNumber(""))
        XCTAssertFalse(NumberInput.isNumber("Rp"))
        XCTAssertTrue(NumberInput.isNumber("0"))
    }

    /// A rate is never grouped: 1.875% stays 1.875, not 1875.
    func testRatesAreDecimals() {
        XCTAssertEqual(NumberInput.decimal("1.875"), 1.875, accuracy: 1e-12)
        XCTAssertEqual(NumberInput.decimal("1,875"), 1.875, accuracy: 1e-12)
        XCTAssertEqual(NumberInput.decimal("24"), 24)
        XCTAssertEqual(NumberInput.decimal("2.5%"), 2.5, accuracy: 1e-12)
        XCTAssertEqual(NumberInput.decimal(""), 0)
    }

    /// What a form writes back when editing must read back the same, in both
    /// readers — including the amounts `String(v)` used to write as
    /// "1234.567", which the amount reader takes as grouping.
    func testWrittenValuesReadBack() {
        for v in [25_000, 1_234.567, 0.5, 12.43, 1.875, 99_999_999, 0.00001] {
            let t = NumberInput.text(v)
            XCTAssertFalse(t.contains("e"), t)
            XCTAssertEqual(NumberInput.amount(t), v, accuracy: 1e-9, t)
            XCTAssertEqual(NumberInput.decimal(t), v, accuracy: 1e-9, t)
        }
    }

    /// The echo under an amount field shows exactly what will be saved.
    @MainActor
    func testPreviewMatchesTheSavedValue() {
        XCTAssertEqual(AmountInputHelper.preview("25.000", currency: "IDR"),
                       CurrencyManager.shared.formatted(25_000, currency: "IDR"))
        XCTAssertNil(AmountInputHelper.preview("", currency: "IDR"))
    }
}
