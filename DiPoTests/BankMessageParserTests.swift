import XCTest
@testable import DiPo

/// The parser turns a bank's words into money. It is allowed to be wrong — the
/// review queue exists for that — but it is not allowed to be wrong about the
/// AMOUNT without saying so, and it is not allowed to invent one.
///
/// These are the shapes Indonesian banks and wallets actually write in. Real
/// messages from Fahmi's own banks should be added here as they turn up; that
/// is the only way this stays honest as the banks change their formats.
final class BankMessageParserTests: XCTestCase {

    // MARK: Amounts

    func testIndonesianSeparators() {
        XCTAssertEqual(BankMessageParser.firstAmount(in: "Rp50.000,00"), 50_000)
        XCTAssertEqual(BankMessageParser.firstAmount(in: "Rp1.234.567"), 1_234_567)
        XCTAssertEqual(BankMessageParser.firstAmount(in: "Rp15.000,50"), 15_000.50)
    }

    /// The same banks also send the other convention, sometimes in the same app.
    func testEnglishSeparators() {
        XCTAssertEqual(BankMessageParser.firstAmount(in: "Rp 50,000.00"), 50_000)
        XCTAssertEqual(BankMessageParser.firstAmount(in: "IDR 1,234,567"), 1_234_567)
    }

    func testLooseSpacingAndPrefixes() {
        XCTAssertEqual(BankMessageParser.firstAmount(in: "Rp. 250000.00"), 250_000)
        XCTAssertEqual(BankMessageParser.firstAmount(in: "idr250000"), 250_000)
    }

    /// No amount means no row. A queue full of blanks is worse than a skip.
    func testRefusesAMessageWithNoAmount() {
        XCTAssertNil(BankMessageParser.parse("BCA: Kode OTP Anda 449120. RAHASIA."))
    }

    // MARK: Whole messages

    func testQrisPurchase() throws {
        let parsed = try XCTUnwrap(
            BankMessageParser.parse("BCA: 27/09 DB Rp50.000,00 QRIS WARKOP PAK BUDI"))
        XCTAssertEqual(parsed.amount, -50_000, "DB is money out.")
        XCTAssertEqual(parsed.currency, "IDR")
        XCTAssertTrue(parsed.merchant.contains("WARKOP"), "Got: \(parsed.merchant)")
        XCTAssertEqual(parsed.issuerHint, "bca")
    }

    func testTransferOutWithMaskedAccount() throws {
        let parsed = try XCTUnwrap(BankMessageParser.parse(
            "Trx Rek. xxxx0969: Transfer IBNK ke BUDI SANTOSO Rp. 250000.00 27/09/26 21:22:13"))
        XCTAssertEqual(parsed.amount, -250_000)
        XCTAssertEqual(parsed.accountTail, "0969")
        XCTAssertTrue(parsed.merchant.contains("BUDI"), "Got: \(parsed.merchant)")
    }

    func testCreditIsIncome() throws {
        let parsed = try XCTUnwrap(BankMessageParser.parse(
            "BCA: 27/09 CR Rp10.000.000,00 TRANSFER DARI PT SUMBER REJEKI"))
        XCTAssertEqual(parsed.amount, 10_000_000, "CR is money in.")
    }

    func testWalletPayment() throws {
        let parsed = try XCTUnwrap(BankMessageParser.parse(
            "DANA: Pembayaran Rp15.000 berhasil di Tokopedia"))
        XCTAssertEqual(parsed.amount, -15_000)
        XCTAssertEqual(parsed.issuerHint, "dana")
        XCTAssertTrue(parsed.merchant.lowercased().contains("tokopedia"), "Got: \(parsed.merchant)")
    }

    /// "cr" must not fire inside an ordinary word, or half the purchases in the
    /// queue arrive as income.
    func testDirectionWordsAreWholeWordsOnly() throws {
        let parsed = try XCTUnwrap(BankMessageParser.parse(
            "BCA: Pembayaran Rp75.000 di CREATIVE DBEST STORE"))
        XCTAssertEqual(parsed.amount, -75_000)
    }

    // MARK: Dates

    func testReadsTheDateFromTheMessage() throws {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 27))!
        let parsed = try XCTUnwrap(BankMessageParser.parse(
            "BCA: 25/09 DB Rp20.000 QRIS KOPI", now: now))
        let comps = Calendar.current.dateComponents([.day, .month, .year], from: parsed.date)
        XCTAssertEqual(comps.day, 25)
        XCTAssertEqual(comps.month, 9)
        XCTAssertEqual(comps.year, 2026)
    }

    /// Without a year in the text, a date ahead of today belongs to last year —
    /// a message cannot describe next week.
    func testADateAheadOfTodayRollsBackAYear() throws {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        let parsed = try XCTUnwrap(BankMessageParser.parse(
            "BCA: 28/12 DB Rp20.000 QRIS KOPI", now: now))
        XCTAssertEqual(Calendar.current.component(.year, from: parsed.date), 2025)
    }
}
