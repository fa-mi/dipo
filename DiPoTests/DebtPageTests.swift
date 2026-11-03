import XCTest
import SwiftUI
@testable import DiPo

/// The Debts page says which debt to pay first and when each is due, with one
/// green button. A late debt goes first; red only for late, orange while a due
/// date is close.
@MainActor
final class DebtPageTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func debt(_ name: String, balance: Double = 1_000_000, rate: Double = 0, due: Int = 10) -> DebtRecord {
        DebtRecord(name: name, type: "loan", totalAmount: 2_000_000, currentBalance: balance,
                   minimumPayment: 100_000, annualInterestRate: rate, dueDayOfMonth: due, currency: "IDR")
    }

    // MARK: When a debt is due

    func testDueAgainstToday() {
        let of = { (due: Int, today: Int) in
            DebtDue.of(dueDay: due, today: today, daysInMonth: 30, paidThisMonth: false)
        }
        XCTAssertEqual(of(10, 10), .today)
        XCTAssertEqual(of(11, 10), .soon(1))
        XCTAssertEqual(of(13, 10), .soon(3))
        XCTAssertEqual(of(14, 10), .later(14), "past the soon window it is just its day")
        XCTAssertEqual(of(5, 10), .overdue(5))
        XCTAssertEqual(of(4, 10), .later(4), "past the late window it is not called late")
    }

    func testAPaymentThisMonthMeansPaid() {
        XCTAssertEqual(DebtDue.of(dueDay: 5, today: 8, daysInMonth: 30, paidThisMonth: true), .paid)
        XCTAssertEqual(DebtDue.of(dueDay: 20, today: 8, daysInMonth: 30, paidThisMonth: true), .paid)
    }

    func testADueDayPastTheMonthsEndFallsOnItsLastDay() {
        XCTAssertEqual(DebtDue.of(dueDay: 31, today: 30, daysInMonth: 30, paidThisMonth: false), .today)
        XCTAssertEqual(DebtDue.of(dueDay: 31, today: 27, daysInMonth: 28, paidThisMonth: false), .soon(1))
    }

    func testRedOnlyWhenLateOrangeWhenClose() {
        XCTAssertEqual(DebtDue.overdue(2).color, AppTheme.red)
        XCTAssertEqual(DebtDue.today.color, AppTheme.orange)
        XCTAssertEqual(DebtDue.soon(2).color, AppTheme.orange)
        XCTAssertEqual(DebtDue.later(20).color, AppTheme.textSecondary)
        XCTAssertEqual(DebtDue.paid.color, AppTheme.textSecondary)
    }

    func testDueInWords() {
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(DebtDue.soon(1).text, "Jatuh tempo besok")
            XCTAssertEqual(DebtDue.soon(3).text, "Jatuh tempo 3 hari lagi")
            XCTAssertEqual(DebtDue.overdue(4).text, "Lewat 4 hari")
            XCTAssertEqual(DebtDue.later(20).text, "jatuh tempo tgl 20")
            XCTAssertEqual(DebtDue.paid.text, "Sudah dibayar bulan ini")
        }
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(DebtDue.later(1).text, "due on day 1", "not \"due 1th\"")
        }
    }

    // MARK: Which to pay first

    func testALateDebtGoesFirstTheLatestOfThem() {
        let due: [String: DebtDue] = ["kur": .later(20), "pinjol": .soon(2), "pakde": .overdue(4), "arisan": .overdue(1)]
        XCTAssertEqual(DebtPayFirst.pick(["kur", "pinjol", "pakde", "arisan"], due: { due[$0]! }), "pakde")
    }

    func testOtherwiseTheChosenOrderSkippingWhatIsPaid() {
        let due: [String: DebtDue] = ["pinjol": .paid, "paylater": .soon(1), "kur": .later(20)]
        XCTAssertEqual(DebtPayFirst.pick(["pinjol", "paylater", "kur"], due: { due[$0]! }), "paylater")
        XCTAssertEqual(DebtPayFirst.pick(["kur", "paylater"], due: { due[$0]! }), "kur")
    }

    func testAllPaidStillShowsTheFirstAndNothingGivesNothing() {
        XCTAssertEqual(DebtPayFirst.pick(["a", "b"], due: { _ in .paid }), "a")
        XCTAssertNil(DebtPayFirst.pick([String](), due: { _ in .paid }))
    }

    func testWhyThisOne() {
        LanguageManager.shared.withLanguage(.indonesian) {
            let pinjol = debt("Pinjol", rate: 24)
            XCTAssertEqual(DebtPayFirst.reason(pinjol, due: .soon(2), byInterest: true, count: 3),
                           "Bunganya paling tinggi, 24% per tahun.")
            XCTAssertEqual(DebtPayFirst.reason(pinjol, due: .soon(2), byInterest: false, count: 3),
                           "Sisanya paling kecil, jadi paling cepat lunas.")
            XCTAssertEqual(DebtPayFirst.reason(pinjol, due: .overdue(3), byInterest: true, count: 3),
                           "Sudah lewat jatuh tempo. Bayar ini sebelum yang lain.")
            XCTAssertNil(DebtPayFirst.reason(pinjol, due: .soon(2), byInterest: true, count: 1),
                         "the only debt needs no reason")
            XCTAssertNil(DebtPayFirst.reason(debt("Pak De"), due: .soon(2), byInterest: true, count: 3),
                         "no interest, no interest reason")
        }
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(DebtPayFirst.reason(debt("Card", rate: 24.5), due: .later(9), byInterest: true, count: 2),
                           "It has the highest interest, 24.5% a year.")
        }
    }

    func testRateInWords() {
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(DebtRow.rateText(debt("KUR", rate: 6)), "Bunga 6%/thn")
            XCTAssertEqual(DebtRow.rateText(debt("Pak De")), "Tanpa bunga")
        }
    }

    // MARK: The verdict

    func testVerdictRedOnlyWhenTheMonthCannotCarryIt() {
        XCTAssertEqual(DebtTotalHeader.verdictColor(.heavy), AppTheme.red)
        XCTAssertEqual(DebtTotalHeader.verdictColor(.tight), AppTheme.orange)
        XCTAssertEqual(DebtTotalHeader.verdictColor(.safe), AppTheme.textSecondary, "fine is not green")
        XCTAssertEqual(DebtTotalHeader.verdictColor(nil), AppTheme.textSecondary)
    }

    // MARK: The minimal rules, read from the sources

    /// One green button on the page: the pay-first box's.
    func testOneGreenButton() throws {
        let page = try String(contentsOf: root.appendingPathComponent("DiPo/DebtPage.swift"), encoding: .utf8)
        XCTAssertEqual(page.components(separatedBy: "AppTheme.accentFill").count - 1, 1,
                       "only the pay-first box is green")
        let view = try String(contentsOf: root.appendingPathComponent("DebtView.swift"), encoding: .utf8)
        XCTAssertFalse(view.contains("accentFill"), "the page itself adds no green")
    }

    /// No washes, borders or icon tiles behind the page's rows and header.
    func testNoWashesBordersOrTiles() throws {
        let page = try String(contentsOf: root.appendingPathComponent("DiPo/DebtPage.swift"), encoding: .utf8)
            .components(separatedBy: "\n").map { $0.components(separatedBy: "//").first ?? $0 }
        let found = page.filter { line in
            (line.contains(".background(") && line.contains(".opacity("))
                || (line.contains(".overlay(") && line.contains(".stroke("))
                || line.contains("Circle().fill(")
        }
        XCTAssertTrue(found.isEmpty, found.joined(separator: "\n"))
    }

    func testNewStringsInBothLanguages() {
        let keys = ["debt.other_debts", "debt.left_label", "debt.pay_amount", "debt.no_interest",
                    "debt.paid_this_month", "debt.due_tomorrow", "debt.why_late", "debt.why_interest",
                    "debt.why_smallest", "debt.simulate_row", "debt.owed_back.nav", "debt.owed_back.clears",
                    "cc.of_limit"]
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                for k in keys { XCTAssertNotEqual(loc(k), k, "\(k) in \(lang)") }
            }
        }
    }
}
