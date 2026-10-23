import XCTest
import SwiftData
@testable import DiPo

/// The first days of a pay period, and a card bill paid on one of them.
///
/// On Fahmi's payday Statistics projected one Rp 225.000 day across all 33:
/// "Rp 0 left over each day", "Balance may run out before payday", payday at
/// −Rp 2.072.887 and Rp 1.575.000 a week. Beside it, "1020% more than last
/// time": a Rp 1,5 jt card bill plus the day's spending, set against the
/// previous period's first day of Rp 154.000.
@MainActor
final class EarlyPeriodTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private let idr: (TxRecord) -> Double = { $0.amount }

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func day(_ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))!
    }

    private func row(_ name: String, _ amount: Double, _ date: Date, _ cat: TxCategory = .other,
                     subtype: TxSubtype = .normal) -> TxRecord {
        let t = TxRecord(name: name, date: date, amount: amount,
                         type: amount < 0 ? "tx.type.purchase" : "tx.type.income", icon: "X",
                         iconBgHex: cat.iconBg, category: cat, currency: "IDR", notes: "", subtype: subtype)
        context.insert(t)
        return t
    }

    // MARK: The rate the days still to come are projected at

    func testOneDayDecidesASeventhOfTheRateNotAllOfIt() {
        let rate = StatisticsView.dailyRate(variable: 225_000, elapsed: 1, priorDaily: 150_000)
        XCTAssertEqual(rate ?? 0, (225_000 + 150_000 * 6) / 7, accuracy: 0.5)
    }

    func testFromTheSeventhDayThePeriodStandsOnItsOwnDays() {
        XCTAssertEqual(StatisticsView.dailyRate(variable: 1_400_000, elapsed: 7, priorDaily: 50_000) ?? 0,
                       200_000, accuracy: 0.5)
        XCTAssertEqual(StatisticsView.dailyRate(variable: 1_400_000, elapsed: 7, priorDaily: nil) ?? 0,
                       200_000, accuracy: 0.5)
    }

    func testAFirstWeekWithNothingBeforeItIsTooEarlyToProject() {
        XCTAssertNil(StatisticsView.dailyRate(variable: 225_000, elapsed: 3, priorDaily: nil))
        XCTAssertNil(StatisticsView.projection(variable: 225_000, fixed: 0, upcoming: 0,
                                               progress: (elapsed: 3, total: 33)))
        XCTAssertNil(StatisticsView.dailyRate(variable: 0, elapsed: 0, priorDaily: 150_000))
    }

    /// Payday as it happened: Rp 225.000 of day-to-day spending, the Rp 1,5 jt
    /// card bill (fixed, counted once) and Rp 3.987.887 of monthly plans still
    /// to come. Straight-lined from one day that was Rp 12.912.887.
    func testPaydayIsProjectedFromLastPeriodsPaceNotFromOneDay() throws {
        let p = try XCTUnwrap(StatisticsView.projection(variable: 225_000, fixed: 1_500_000, upcoming: 3_987_887,
                                                        progress: (elapsed: 1, total: 33), priorDaily: 150_000))
        let rate = (225_000.0 + 150_000 * 6) / 7
        XCTAssertEqual(p, 225_000 + rate * 32 + 1_500_000 + 3_987_887, accuracy: 0.5)
        XCTAssertLessThan(p - 1_500_000, 10_000_000, "living costs stay inside a Rp 10 jt salary")
    }

    func testFromTheSecondWeekTheProjectionIsTheStraightLineItWas() throws {
        let p = try XCTUnwrap(StatisticsView.projection(variable: 2_400_000, fixed: 4_300_000, upcoming: 2_265_000,
                                                        progress: (elapsed: 12, total: 28), priorDaily: 999_999))
        XCTAssertEqual(p, 2_400_000 / 12 * 28 + 4_300_000 + 2_265_000, accuracy: 0.5)
    }

    // MARK: The period before, for the first week

    func testThePriorPeriodRatesItsDayToDaySpendingOverItsOwnDays() throws {
        var rows: [TxRecord] = []
        for d in 0..<28 {
            rows.append(row("Makan", -150_000, Calendar.current.date(byAdding: .day, value: d, to: day(9, 25))!, .food))
        }
        rows.append(row("kos", -2_100_000, day(10, 8), .bills))      // a fixed charge, not a day's spending
        rows.append(row("Payday", -225_000, day(10, 23, 9), .food))   // the new period, outside the window
        let rhythm = SpendingRhythm(history: rows) { $0.amount }
        let prior = try XCTUnwrap(StatisticsView.priorPeriod(rows, from: day(9, 25, 0), to: day(10, 23, 0),
                                                            rhythm: rhythm, convert: idr))
        XCTAssertEqual(prior.days, 28)
        XCTAssertEqual(prior.dailyRate, 150_000, accuracy: 0.5)
        XCTAssertEqual(StatisticsView.median(prior.figures.dailyTotals + [225_000]), 150_000, accuracy: 0.5,
                       "payday's typical day leans on the 28 before it")
    }

    func testNoPriorPeriodWhenNothingWasSpentInIt() {
        let rows = [row("Gaji", 10_000_000, day(9, 25, 0), .salary)]
        let rhythm = SpendingRhythm(history: rows) { $0.amount }
        XCTAssertNil(StatisticsView.priorPeriod(rows, from: day(9, 25, 0), to: day(10, 23, 0),
                                                rhythm: rhythm, convert: idr))
    }

    func testMedianOfDays() {
        XCTAssertEqual(StatisticsView.median([]), 0)
        XCTAssertEqual(StatisticsView.median([225_000]), 225_000)
        XCTAssertEqual(StatisticsView.median([300, 100, 200]), 200)
        XCTAssertEqual(StatisticsView.median([100, 400, 200, 300]), 250)
    }

    // MARK: Living costs and the comparison

    func testLivingCostsLeaveOutDebtPaidMoneyPutAwayAndTransfers() {
        let rows = [row("Makan", -145_000, day(10, 23, 9), .food),
                    row("Perabotan", -50_000, day(10, 23, 21), .shopping),
                    row("Bensin", -30_000, day(10, 23, 7), .transport),
                    row("Tokopedia CC bill payment", -1_500_000, day(10, 23, 8), .debtPayment),
                    row("Reksa dana", -300_000, day(10, 23, 10), .investment),
                    row("Transfer to BCA", -2_100_000, day(10, 23, 7), subtype: .transfer),
                    row("Refund perabotan", 20_000, day(10, 23, 22), .shopping, subtype: .refund)]
        XCTAssertEqual(StatisticsView.expenses(rows, convert: idr), 2_005_000, accuracy: 0.5)
        XCTAssertEqual(StatisticsView.living(rows, convert: idr), 205_000, accuracy: 0.5)
    }

    func testLivingTotalIsNilWhenNothingWasSpent() {
        let salary = [row("Gaji", 10_000_000, day(10, 23, 0), .salary)]
        XCTAssertNil(StatisticsView.livingTotal(salary, from: day(10, 1, 0), to: day(11, 1, 0), convert: idr))
        let withCoffee = salary + [row("Kopi", -20_000, day(10, 24), .food)]
        XCTAssertEqual(StatisticsView.livingTotal(withCoffee, from: day(10, 1, 0), to: day(11, 1, 0),
                                                  convert: idr) ?? 0, 20_000, accuracy: 0.5)
    }

    func testTheFirstWeekHasNoComparison() {
        XCTAssertNil(StatisticsView.livingChange(225_000, previous: 154_000, elapsed: 1))
        XCTAssertNil(StatisticsView.livingChange(900_000, previous: 700_000, elapsed: 6))
        XCTAssertEqual(StatisticsView.livingChange(990_000, previous: 900_000, elapsed: 7) ?? 0, 10, accuracy: 0.001)
    }

    func testAFinishedPeriodComparesWholeToWhole() {
        XCTAssertEqual(StatisticsView.livingChange(8_000_000, previous: 10_000_000, elapsed: nil) ?? 0,
                       -20, accuracy: 0.001)
        XCTAssertNil(StatisticsView.livingChange(8_000_000, previous: 0, elapsed: nil))
        XCTAssertNil(StatisticsView.livingChange(8_000_000, previous: nil, elapsed: 20))
    }
}
