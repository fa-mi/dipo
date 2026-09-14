import XCTest
@testable import DiPo

// Every case here is a real receipt that produced wrong data on Fahmi's phone.
// They are written from the OCR text those screens actually yield, because the
// defects were never in the arithmetic — they were in deciding which line on a
// payment slip is the shop.
final class ReceiptParsingTests: XCTestCase {

    // MARK: Merchant vs the bank

    /// A BCA QRIS slip carries "BCA" as a watermark repeated across the whole
    /// image, so the old top-six-lines heuristic picked the bank.
    func testPayeeLabelBeatsTheBankWatermark() {
        let text = """
        IDR 52,000.00
        BCA
        Payment to
        JOURDAN LAUNDRY EXPERT
        Acquirer
        BCA
        RRN
        367109609
        Total Payment IDR 52,000.00
        """
        let r = ReceiptParser.parse(rawText: text, fallbackCurrency: "IDR")
        XCTAssertEqual(r.merchantName, "JOURDAN LAUNDRY EXPERT")
        XCTAssertEqual(r.issuer.uppercased(), "BCA")
    }

    /// The issuer is read from the slip rather than matched against a fixed
    /// list, so a bank nobody hardcoded still gets excluded.
    func testBankOutsideAnyHardcodedListIsStillExcluded() {
        let text = """
        IDR 75,000.00
        Payment to
        WARUNG BU SRI
        Acquirer
        Bank Sinarmas
        RRN 881
        Total 75,000
        """
        let r = ReceiptParser.parse(rawText: text, fallbackCurrency: "IDR")
        XCTAssertEqual(r.merchantName, "WARUNG BU SRI")
    }

    /// The mirror risk of excluding bank names: a shop whose name contains one.
    func testShopNamedAfterABankSurvives() {
        let text = """
        IDR 30,000.00
        Payment to
        TOKO MANDIRI JAYA
        Acquirer
        BCA
        Total 30,000
        """
        let r = ReceiptParser.parse(rawText: text, fallbackCurrency: "IDR")
        XCTAssertEqual(r.merchantName, "TOKO MANDIRI JAYA")
    }

    /// Mobile banking apps are branded separately from their bank. "Qita by
    /// BRI" launched after this parser was written and was read as the shop.
    func testMobileBankingAppNameIsNotTheMerchant() {
        let text = """
        Qita
        Rp15.000
        13 Sep 2026, 10:22:50 WIB
        Detail Transaksi
        BRI - 0319 **** **** 507
        COTR CALF 99 QR
        Total Rp15.000
        """
        let r = ReceiptParser.parse(rawText: text, fallbackCurrency: "IDR")
        XCTAssertNotEqual(r.merchantName.lowercased(), "qita")
        XCTAssertEqual(r.merchantName, "COTR CALF 99 QR")
    }

    /// Every banking app leads with one, and it is the first wordy line once
    /// the app name and the bank are excluded.
    func testStatusBannerIsNotTheMerchant() {
        let text = """
        Livin' by Mandiri
        Transaksi Berhasil
        Rp 45.000
        Mandiri 900-00-1234
        WARUNG PADANG SEDERHANA
        Total Rp 45.000
        """
        let r = ReceiptParser.parse(rawText: text, fallbackCurrency: "IDR")
        XCTAssertEqual(r.merchantName, "WARUNG PADANG SEDERHANA")
    }

    /// A plain till receipt has no payment rails on it at all — the first pass
    /// must not break the case that always worked.
    func testPlainTillReceiptStillReadsItsHeader() {
        let text = """
        INDOMARET
        Jl. Sudirman 12
        Aqua 600ml Rp 4.000
        TOTAL Rp 4.000
        """
        let r = ReceiptParser.parse(rawText: text, fallbackCurrency: "IDR")
        // Canonical Title Case, deliberately: a chain is folded to one name so
        // every branch lands in one place in the user's history.
        XCTAssertEqual(r.merchantName, "Indomaret")
        XCTAssertTrue(r.issuer.isEmpty)
    }

    // MARK: Dates

    /// "12 Sep 2026" matched none of the numeric patterns and fell through to
    /// the fallback, which is TODAY — a wrong answer that looks like a real one.
    func testSpelledOutMonthIsNotSilentlyToday() {
        let text = "QRIS Payment Successful\n12 Sep 2026 20:41:20\nIDR 52,000.00\nTotal 52,000"
        let r = ReceiptParser.parse(rawText: text, fallbackCurrency: "IDR")
        let c = Calendar.current.dateComponents([.year, .month, .day], from: r.date)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 9)
        XCTAssertEqual(c.day, 12)
    }

    /// The numeric patterns need `en_US_POSIX`, and that locale cannot read
    /// these month names at all — which is why they are matched by lookup.
    func testIndonesianMonthNamesParse() {
        let cal = Calendar.current
        let now = Date()
        // Pick a month comfortably in the past so the future-date guard, which
        // is correct behaviour, does not reject the fixture.
        let past = cal.date(byAdding: .month, value: -3, to: now)!
        let y = cal.component(.year, from: past)

        for (word, month) in [("Mei", 5), ("Agu", 8), ("Okt", 10), ("Des", 12), ("Nopember", 11)] {
            guard let expected = cal.date(from: DateComponents(year: y, month: month, day: 4)),
                  expected <= now else { continue }
            let text = "Transaksi 4 \(word) \(y)\nTotal Rp 10.000"
            let r = ReceiptParser.parse(rawText: text, fallbackCurrency: "IDR")
            XCTAssertEqual(cal.component(.month, from: r.date), month,
                           "\(word) should resolve to month \(month)")
        }
    }

    func testFutureDateIsRejected() {
        let cal = Calendar.current
        let next = cal.date(byAdding: .year, value: 1, to: Date())!
        let y = cal.component(.year, from: next)
        let text = "1 Des \(y)\nTotal Rp 10.000"
        let r = ReceiptParser.parse(rawText: text, fallbackCurrency: "IDR")
        XCTAssertLessThanOrEqual(r.date, Date().addingTimeInterval(86_400))
    }

    // MARK: Is it a receipt at all

    /// Back Tap fires on whatever is on screen. These two produced a merchant,
    /// a category and an amount that were one tap from being saved.
    func testHomeScreenIsRejected() {
        let text = """
        11:52am South Jakarta
        Dzuhur 11:52am
        Ashar 3:06pm
        Track prayers
        livin by mandiri
        my BCA
        """
        XCTAssertFalse(ReceiptParser.looksLikeReceipt(text))
    }

    func testTheAppsOwnCardScreenIsRejected() {
        let text = """
        Fahmi Aquinas BRI
        Balance
        Expires 11/29
        SeaBank IDR
        """
        XCTAssertFalse(ReceiptParser.looksLikeReceipt(text))
    }

    /// A currency word with no digits beside it is not a price — this is the
    /// distinction that rejects a card list showing "IDR".
    func testCurrencyLabelWithoutDigitsIsNotAPrice() {
        XCTAssertFalse(ReceiptParser.looksLikeReceipt("SeaBank\nIDR\nFahmi Aquinas\nIDR"))
    }

    func testRealReceiptsAreAccepted() {
        XCTAssertTrue(ReceiptParser.looksLikeReceipt(
            "BCA\nQRIS Payment Successful\nIDR 52,000.00\nTotal Payment IDR 52,000.00"))
        XCTAssertTrue(ReceiptParser.looksLikeReceipt(
            "INDOMARET\nAqua Rp 4.000\nTOTAL Rp 4.000"))
        XCTAssertTrue(ReceiptParser.looksLikeReceipt(
            "WARUNG BU SRI\nNasi Rp 15.000\nTotal Rp 15.000"))
    }

    // MARK: Confidence

    /// A missing date does not lower the reading, it substitutes today. With
    /// the other three fields found, the total reached exactly the 0.85 "high
    /// confidence" threshold and badged a wrong date as accurate.
    func testFailedDateCannotEarnHighConfidence() {
        let text = "INDOMARET\nAqua Rp 4.000\nTOTAL Rp 4.000"   // no date anywhere
        let r = ReceiptParser.parse(rawText: text, fallbackCurrency: "IDR")
        XCTAssertLessThan(r.confidence, 0.85)
    }
}
