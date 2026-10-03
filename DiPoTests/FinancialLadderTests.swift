import XCTest
@testable import DiPo

/// The financial ladder: which step a user is on, read from their own figures.
@MainActor
final class FinancialLadderTests: XCTestCase {

    /// A typical ultra-micro household: Rp 4 jt a month, Rp 2,4 jt of it on
    /// daily needs, Rp 3 jt in the account, a little gold.
    private func household() -> LadderInputs {
        var i = LadderInputs()
        i.monthlyIncome = 4_000_000
        i.monthlyConsumption = 3_200_000
        i.monthlyEssentials = 2_400_000
        i.cash = 3_000_000
        i.liquidHoldings = 1_320_000
        return i
    }

    func testEmergencyFundIsTheStepForAHouseholdWithASmallBuffer() {
        let r = FinancialLadder.evaluate(household())
        XCTAssertEqual(r.current, .emergency)
        XCTAssertEqual(r.emergencyMonths, 1.8, accuracy: 0.001)            // 4,32 jt / 2,4 jt
        XCTAssertEqual(r.emergencyTarget, 7_200_000, accuracy: 0.01)
        XCTAssertEqual(r.emergencyGap, 2_880_000, accuracy: 0.01)
        XCTAssertEqual(r.rung(.emergency).progress, 0.6, accuracy: 0.001)
        XCTAssertEqual(r.doneCount, 2)
    }

    func testCostlyDebtComesBeforeTheBuffer() {
        var i = household()
        i.costlyDebt = .init(name: "Paylater", annualRate: 36, balance: 1_500_000)
        XCTAssertEqual(FinancialLadder.evaluate(i).current, .debt)
    }

    func testOverspendingIsTheFirstStepAndNoIncomeIsNotDone() {
        var i = household()
        i.monthlyConsumption = 4_500_000
        XCTAssertEqual(FinancialLadder.evaluate(i).current, .spending)
        i.monthlyIncome = 0
        let r = FinancialLadder.evaluate(i)
        XCTAssertFalse(r.rung(.spending).done)
        XCTAssertEqual(r.rung(.spending).progress, 0)
    }

    func testFullBufferMovesOnToInvestingThenFuture() {
        var i = household()
        i.cash = 6_000_000
        XCTAssertEqual(FinancialLadder.evaluate(i).current, .investing)
        i.investedMonthly = 400_000                                       // 10% of income
        XCTAssertEqual(FinancialLadder.evaluate(i).current, .future)
        i.pensionValue = 48_126_522
        let r = FinancialLadder.evaluate(i)
        XCTAssertNil(r.current)
        XCTAssertEqual(r.doneCount, 5)
    }

    func testSmallButRegularInvestingCountsWhenThereIsAPortfolio() {
        var i = household()
        i.cash = 6_000_000
        i.investedMonthly = 100_000
        XCTAssertFalse(FinancialLadder.evaluate(i).rung(.investing).done)
        i.portfolioValue = 2_000_000
        XCTAssertTrue(FinancialLadder.evaluate(i).rung(.investing).done)
    }

    func testThinLoggingStillSizesTheBufferFromHalfOfSpending() {
        var i = household()
        i.monthlyEssentials = 200_000                                     // barely logged
        let r = FinancialLadder.evaluate(i)
        XCTAssertEqual(r.emergencyTarget, 3_200_000 * 0.5 * 3, accuracy: 0.01)
    }

    func testCopyUsesTheUsersFigures() {
        let r = FinancialLadder.evaluate(household())
        let line = LadderCopy.detail(.emergency, r, currency: "IDR")
        XCTAssertTrue(line.contains(LadderCopy.months(1.8)), line)
        XCTAssertNotEqual(LadderCopy.cardSubtitle(r), "ladder.card_step")
        for s in LadderStep.allCases {
            XCTAssertNotEqual(s.title, "ladder.step.\(s)")
            XCTAssertFalse(s.why.hasPrefix("ladder."), "\(s) has no explanation")
            XCTAssertFalse(LadderCopy.detail(s, r, currency: "IDR").hasPrefix("ladder."), "\(s)")
        }
    }
}
