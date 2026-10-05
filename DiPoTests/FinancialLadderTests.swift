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

    func testATokenAmountIsNotRegularInvesting() {
        var i = household()                                               // Rp 4 jt income
        i.cash = 6_000_000
        i.investedMonthly = 100_000                                       // 2,5%
        XCTAssertFalse(FinancialLadder.evaluate(i).rung(.investing).done)
        i.portfolioValue = 2_000_000                                      // holds something: aim 5%
        XCTAssertFalse(FinancialLadder.evaluate(i).rung(.investing).done)
        XCTAssertEqual(FinancialLadder.evaluate(i).rung(.investing).progress, 0.5, accuracy: 0.001)
        i.investedMonthly = 200_000
        XCTAssertTrue(FinancialLadder.evaluate(i).rung(.investing).done)
    }

    func testOneBigMonthDoesNotMakeEveryMonthADeficit() {
        // Rp 3 jt, Rp 25 jt (the month of the motorbike), Rp 3,5 jt.
        XCTAssertEqual(FinancialLadder.median([3_000_000, 25_000_000, 3_500_000]), 3_500_000)
        XCTAssertEqual(FinancialLadder.median([3_000_000, 4_000_000]), 3_500_000)
        XCTAssertEqual(FinancialLadder.median([]), 0)
    }

    func testMonthTotalsUseCompleteMonthsSinceLoggingBegan() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        func d(_ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: day, hour: 12))! }
        let items: [(date: Date, amount: Double)] = [
            (d(7, 20), 1_000_000),                       // July: logging began on the 15th
            (d(8, 5), 2_000_000), (d(8, 20), 1_000_000),  // August: 3 jt
            (d(9, 10), 4_000_000),                        // September: 4 jt
            (d(10, 2), 9_000_000),                        // October: still running, left out
        ]
        let totals = FinancialLadder.completeMonthTotals(items, count: 3, firstActivity: d(7, 15),
                                                         now: d(10, 5), cal: cal)
        XCTAssertEqual(totals, [3_000_000, 4_000_000])
    }

    func testOnlyAnOlderCardBalanceIsCarried() {
        // Rp 9,4 jt owed, all of it charged this month and last: the open bill.
        XCTAssertEqual(FinancialLadder.carriedOver(owed: 9_443_509, recentCharges: 9_500_000), 0)
        // Rp 2 jt of it predates last month: carried, and charged interest.
        XCTAssertEqual(FinancialLadder.carriedOver(owed: 9_443_509, recentCharges: 7_443_509), 2_000_000,
                       accuracy: 0.01)
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
