import XCTest
import SwiftData
@testable import DiPo

/// What paid for the period, walked in date order: income first, then money
/// in that isn't income — only once it has arrived — then the balance carried
/// in.
@MainActor
final class CoverTimelineTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func at(_ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
    }

    private func tx(_ name: String, _ amount: Double, _ date: Date, _ cat: TxCategory = .other,
                    subtype: TxSubtype = .normal, icon: String = "X", notes: String = "") -> TxRecord {
        let t = TxRecord(name: name, date: date, amount: amount,
                         type: amount < 0 ? "tx.type.purchase" : "tx.type.income", icon: icon,
                         iconBgHex: cat.iconBg, category: cat, currency: "IDR", notes: notes, subtype: subtype)
        container.mainContext.insert(t)
        return t
    }

    /// Fahmi's period: Mom's Rp 5 jt arrived on 4 Oct, the salary was used up
    /// on 8 Oct paying the card. The repayment was there in time, so it is
    /// named — with the part it actually paid, not its full Rp 5 jt.
    func testMomsRepaymentPaidWhatTheSalaryCouldNot() {
        let rows = [tx("Main Salary", 10_000_000, at(9, 25, 0), .salary),
                    tx("Belanja", -4_500_000, at(9, 26)),
                    tx("Repaid by Mom", 5_000_000, at(10, 4, 18, 38), .incomeOther, subtype: .transfer,
                       notes: "tx.note.receivable_repaid"),
                    tx("Tokopedia CC bill payment", -2_000_000, at(10, 4, 18, 40), .debtPayment),
                    tx("kos", -2_100_000, at(10, 8, 0), .bills),
                    tx("Tokopedia CC bill payment", -1_882_381, at(10, 8, 19, 8), .debtPayment)]
        let c = CoverTimeline.walk(rows, start: -75_485, convert: { $0.amount })
        XCTAssertEqual(c.incomeRanOutOn, at(10, 8, 19, 8))
        XCTAssertEqual(c.coveredBy, [.init(label: "Repaid by Mom", amount: 482_381)])
        XCTAssertEqual(c.fromSavings, 0, "the period opened below zero; nothing carried in to draw on")
        XCTAssertEqual(c.uncovered, 0)
        XCTAssertTrue(c.isHelped)
    }

    /// The case the totals got wrong: the salary ran out on the 5th and a gift
    /// came on the 20th. Days 5 to 20 ran on the balance carried in; the gift
    /// only pays for what came after it.
    func testMoneyArrivingLaterDoesNotPayForWhatCameBefore() {
        let rows = [tx("Gaji", 1_000_000, at(10, 1), .salary),
                    tx("Belanja", -1_500_000, at(10, 5), .shopping),
                    tx("Angpao", 1_000_000, at(10, 20), .gift, subtype: .transfer),
                    tx("Makan", -300_000, at(10, 21), .food)]
        let c = CoverTimeline.walk(rows, start: 2_000_000, convert: { $0.amount })
        XCTAssertEqual(c.incomeRanOutOn, at(10, 5))
        XCTAssertEqual(c.fromSavings, 500_000, "the overspend before the gift came out of the balance")
        XCTAssertEqual(c.coveredBy, [.init(label: "Angpao", amount: 300_000)])

        // The book says so too: half by the gift, the rest from the balance.
        let book = PeriodCashBook.build(rows, start: 2_000_000, convert: { $0.amount })
        XCTAssertEqual(book.overspend(deficit: 800_000), .partly(label: "Angpao", amount: 300_000))
    }

    func testIncomeCoveringEverythingNeedsNoExplanation() {
        let rows = [tx("Gaji", 5_000_000, at(10, 1), .salary),
                    tx("Repaid by Dad", 2_500_000, at(10, 2), .incomeOther, subtype: .transfer),
                    tx("Belanja", -4_000_000, at(10, 3), .shopping)]
        let c = CoverTimeline.walk(rows, start: 0, convert: { $0.amount })
        XCTAssertNil(c.incomeRanOutOn)
        XCTAssertTrue(c.coveredBy.isEmpty, "the repayment is untouched while the salary lasts")
        XCTAssertFalse(c.isHelped)
    }

    func testWhatNothingCoversIsTheBalanceGoingBelowZero() {
        let rows = [tx("Gaji", 100_000, at(10, 1), .salary), tx("Belanja", -300_000, at(10, 2))]
        let c = CoverTimeline.walk(rows, start: 50_000, convert: { $0.amount })
        XCTAssertEqual(c.fromSavings, 50_000)
        XCTAssertEqual(c.uncovered, 150_000)
    }

    /// A salary and a bill posted at the same midnight: the salary pays it.
    func testMoneyInComesFirstOnTheSameInstant() {
        let midnight = at(10, 1, 0)
        let rows = [tx("Tagihan", -1_000_000, midnight, .bills), tx("Gaji", 1_000_000, midnight, .salary)]
        let c = CoverTimeline.walk(rows, start: 0, convert: { $0.amount })
        XCTAssertFalse(c.isHelped)
    }

    /// Moves between own accounts and money lent out are not spending; a
    /// refund gives back what was spent.
    func testOwnMovesAreIgnoredAndRefundsPayLikeIncome() {
        let rows = [tx("Gaji", 1_000_000, at(10, 1), .salary),
                    tx("Transfer to OVO", -900_000, at(10, 2), subtype: .transfer, icon: "⇄"),
                    tx("Transfer from BCA", 500_000, at(10, 3), subtype: .transfer, icon: "⇄"),
                    tx("Lent to Cipa", -300_000, at(10, 3), subtype: .transfer, notes: "tx.note.receivable_lent"),
                    tx("Sepatu", -1_200_000, at(10, 4), .shopping),
                    tx("Sepatu refund", 200_000, at(10, 5), .shopping, subtype: .refund),
                    tx("Kaos", -200_000, at(10, 6), .shopping)]
        let c = CoverTimeline.walk(rows, start: 1_000_000, convert: { $0.amount })
        XCTAssertTrue(c.coveredBy.isEmpty, "a move from BCA is not money from someone else")
        XCTAssertEqual(c.fromSavings, 200_000, "the shoes passed the salary; the refund then paid the T-shirt")
        XCTAssertEqual(c.incomeRanOutOn, at(10, 4))
    }

    /// Two sources: drawn in the order they arrived, both named with what they paid.
    func testSourcesAreDrawnInTheOrderTheyArrived() {
        let rows = [tx("Gaji", 1_000_000, at(10, 1), .salary),
                    tx("Repaid by Mom", 300_000, at(10, 2), subtype: .transfer),
                    tx("Repaid by Dad", 1_000_000, at(10, 3), subtype: .transfer),
                    tx("Belanja", -1_800_000, at(10, 4), .shopping)]
        let c = CoverTimeline.walk(rows, start: 0, convert: { $0.amount })
        XCTAssertEqual(c.coveredBy, [.init(label: "Repaid by Mom", amount: 300_000),
                                     .init(label: "Repaid by Dad", amount: 500_000)])
        XCTAssertEqual(c.topSource?.label, "Repaid by Dad")
    }

    func testStringsExist() {
        for key in ["stats.over_partly", "stats.cover_ran_out", "stats.cover_no_income",
                    "stats.cover_source", "stats.cover_savings", "stats.cover_short", "home.over_partly"] {
            XCTAssertNotEqual(loc(key), key, "missing \(key)")
        }
    }
}
