import XCTest
import SwiftData
@testable import DiPo

/// The debt screen: a credit-card balance is money owed.
@MainActor
final class DebtCardTotalsTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func engine(cardOwed: Double = 0, cardMonthly: Double = 0) -> FinancialHealthEngine {
        var e = FinancialHealthEngine(monthlyIncome: 10_000_000, debts: [])
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
        let reading = DebtAffordability(monthlyIncome: 10_000_000, monthlySpending: 6_000_000,
                                        monthlyPayments: e.totalEffectiveMinimums, hasDebt: e.hasAnyDebt)
        XCTAssertNotEqual(reading.title(), loc("debt.advice.no_active"))
    }

    func testNothingOwedIsStillHealthy() {
        let e = engine()
        XCTAssertEqual(e.totalDebt, 0)
        XCTAssertFalse(e.hasAnyDebt)
        let reading = DebtAffordability(monthlyIncome: 10_000_000, monthlySpending: 6_000_000,
                                        monthlyPayments: 0, hasDebt: e.hasAnyDebt)
        XCTAssertNil(reading.verdict)
        XCTAssertEqual(reading.title(), loc("debt.advice.no_active"))
        XCTAssertNil(reading.detail(currency: "IDR"))
    }

    func testStringsExist() {
        for key in ["debt.total_cards_note", "debt.first.why_card", "debt.first.card_recent",
                    "debt.afford.nopay_body"] {
            XCTAssertNotEqual(loc(key), key, "missing \(key)")
        }
    }
}
