import XCTest
import SwiftData
@testable import DiPo

/// "Mom paid back Rp 5 jt and I used it for kos — does the budget see it?"
/// Not unless the person says so, row by row.
@MainActor
final class ExtraFundsTests: XCTestCase {

    private var container: ModelContainer!
    private var saved: [String] = []

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        saved = SmartBudgetManager.shared.extraFundTxIDs
        SmartBudgetManager.shared.extraFundTxIDs = []
    }

    override func tearDown() {
        SmartBudgetManager.shared.extraFundTxIDs = saved
        super.tearDown()
    }

    private func day(_ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: m, day: d, hour: 10))!
    }

    private func tx(_ name: String, _ amount: Double, on date: Date, _ cat: TxCategory = .other,
                    subtype: TxSubtype = .normal, icon: String = "X", notes: String = "") -> TxRecord {
        let t = TxRecord(name: name, date: date, amount: amount,
                         type: amount < 0 ? "tx.type.purchase" : "tx.type.income", icon: icon,
                         iconBgHex: cat.iconBg, category: cat, currency: "IDR", notes: notes, subtype: subtype)
        container.mainContext.insert(t)
        return t
    }

    func testOnlyNonIncomeMoneyInCanBeAdded() {
        let repaid = tx("Repaid by Mom", 5_000_000, on: day(10, 4), .incomeOther, subtype: .transfer,
                        notes: "tx.note.receivable_repaid")
        XCTAssertTrue(ExtraFunds.canFlag(repaid))
        XCTAssertFalse(ExtraFunds.canFlag(tx("Gaji", 10_000_000, on: day(9, 25), .salary)),
                       "income already counts")
        XCTAssertFalse(ExtraFunds.canFlag(tx("From BCA", 2_600_000, on: day(10, 8), subtype: .transfer, icon: "⇄")),
                       "the person's own money moving between cards")
        XCTAssertFalse(ExtraFunds.canFlag(tx("Kos", -2_100_000, on: day(10, 8), .commitment)))
    }

    func testOffByDefaultAndCountedOnlyInsideTheWindow() {
        let repaid = tx("Repaid by Mom", 5_000_000, on: day(10, 4), .incomeOther, subtype: .transfer)
        let gift = tx("Angpao", 300_000, on: day(9, 20), .incomeOther, subtype: .transfer)
        let all = [repaid, gift]
        XCTAssertEqual(ExtraFunds.total(in: all, from: day(9, 25), currency: "IDR"), 0, "nothing unless asked")

        ExtraFunds.set(repaid, true)
        ExtraFunds.set(gift, true)
        XCTAssertTrue(ExtraFunds.isFlagged(repaid))
        XCTAssertEqual(ExtraFunds.total(in: all, from: day(9, 25), currency: "IDR"), 5_000_000,
                       "the gift fell in the period before")
        XCTAssertEqual(ExtraFunds.total(in: all, from: day(9, 25), to: day(10, 1), currency: "IDR"), 0)

        ExtraFunds.set(repaid, false)
        XCTAssertFalse(ExtraFunds.isFlagged(repaid))
        XCTAssertEqual(ExtraFunds.total(in: all, from: day(9, 25), currency: "IDR"), 0)
    }

    func testARowThatStopsQualifyingStopsCounting() {
        let back = tx("dari ibu", 5_000_000, on: day(10, 4), .incomeOther, subtype: .transfer)
        ExtraFunds.set(back, true)
        back.txSubtype = .normal      // turned back into income
        XCTAssertEqual(ExtraFunds.total(in: [back], from: day(9, 25), currency: "IDR"), 0,
                       "income already counts — never twice")
    }

    /// Living Rp 11 jt on Rp 10 jt of pay reads as over; with the Rp 5 jt
    /// repayment added to the budget it is Rp 4 jt under.
    func testLivingIsMeasuredAgainstIncomePlusWhatWasAdded() {
        var book = PeriodCashBook(start: 0, income: 10_000_000, otherIn: [], spent: 11_000_000,
                                  otherOut: [], ownMoves: 0)
        XCTAssertEqual(book.livingNet, -1_000_000)
        book.extraFunds = 5_000_000
        XCTAssertEqual(book.livingNet, 4_000_000)
        XCTAssertEqual(book.net, -1_000_000, "income itself is unchanged")
    }

    func testStringsExist() {
        for key in ["tx.extra.toggle", "tx.extra.off_hint", "tx.extra.on_hint",
                    "budget.extra_included", "home.extra_note", "stats.extra_included"] {
            XCTAssertNotEqual(loc(key), key, "missing \(key)")
        }
    }
}
