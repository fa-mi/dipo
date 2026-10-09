import XCTest
import SwiftData
@testable import DiPo

/// The debt screen: a credit-card balance is money owed, and a posted
/// recurring bill is not spending twice.
@MainActor
final class DebtCardTotalsTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func engine(cardOwed: Double = 0, cardMonthly: Double = 0) -> FinancialHealthEngine {
        var e = FinancialHealthEngine(monthlyIncome: 10_000_000, debts: [], monthlyExpenses: 0)
        e.cardOwed = cardOwed
        e.cardMonthly = cardMonthly
        return e
    }

    /// Fahmi's screen on 9 Oct: Tokopedia CC owed Rp 8.030.000, and the
    /// summary above it read "Total you owe Rp 0 — no active debts".
    func testACardBalanceIsMoneyOwed() {
        let e = engine(cardOwed: 8_030_000, cardMonthly: 401_500)
        XCTAssertEqual(e.totalDebt, 8_030_000)
        XCTAssertEqual(e.totalEffectiveMinimums, 401_500, "pay each month")
        XCTAssertEqual(e.dtiRatio, 4.015, accuracy: 0.001)
        XCTAssertTrue(e.hasAnyDebt)
        XCTAssertNotEqual(e.primaryAdvice, loc("debt.advice.no_active"))
    }

    func testNothingOwedIsStillHealthy() {
        let e = engine()
        XCTAssertEqual(e.totalDebt, 0)
        XCTAssertFalse(e.hasAnyDebt)
        XCTAssertEqual(e.primaryAdvice, loc("debt.advice.no_active"))
    }

    func testPostedRecurringBillsAndSavingsAreNotCountedAsSpendingAgain() {
        func tx(_ amount: Double, _ cat: TxCategory, notes: String = "",
                subtype: TxSubtype = .normal) -> TxRecord {
            let t = TxRecord(name: "x", date: .now, amount: amount, type: "tx.type.purchase", icon: "X",
                             iconBgHex: cat.iconBg, category: cat, currency: "IDR", notes: notes, subtype: subtype)
            container.mainContext.insert(t)
            return t
        }
        let rows = [tx(-2_100_000, .bills, notes: "tx.note.recurring_auto"),      // kos
                    tx(-1_000_000, .commitment, notes: "tx.note.recurring_auto"), // transfer to Mom
                    tx(-1_250_000, .health),                                      // dentist
                    tx(-1_545_000, .food),
                    tx(-300_000, .investment),
                    tx(-1_882_381, .debtPayment),
                    tx(-500_000, .other, subtype: .transfer)]
        XCTAssertEqual(FinancialHealthEngine.planSpending(rows, from: .distantPast, currency: "IDR"),
                       2_795_000, accuracy: 0.5)
    }

    func testStringsExist() {
        for key in ["debt.total_cards_note", "debt.advice.card_only", "debt.reduce_spending_plan"] {
            XCTAssertNotEqual(loc(key), key, "missing \(key)")
        }
    }
}
