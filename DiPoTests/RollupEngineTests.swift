import XCTest
@testable import DiPo

/// The rollup exists to make screens fast at scale WITHOUT changing a single
/// number they show. So these tests pin the engine to the exact conventions the
/// app already uses — `StatisticsView.filteredIncome/filteredExpenses`,
/// `SmartBudgetManager.spent(in:)`, and `categoryBreakdown` — because a rollup
/// that is fast but disagrees with the ledger by a rupiah is worse than the lag
/// it replaces.
final class RollupEngineTests: XCTestCase {

    // A fixed calendar so day/month bucketing never depends on the machine's
    // timezone. Jakarta (UTC+7) is the app's home zone.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// A deterministic FX stub: 1 USD = 16,000 IDR, identity otherwise.
    private func convert(_ amount: Double, _ from: String, _ to: String) -> Double {
        if from == to { return amount }
        if from == "USD" && to == "IDR" { return amount * 16_000 }
        if from == "IDR" && to == "USD" { return amount / 16_000 }
        return amount
    }

    private func totalsIDR(_ buckets: [DailyBucket]) -> RollupTotals {
        RollupEngine.totals(for: buckets, targetCurrency: "IDR", convert: convert)
    }

    // MARK: Bucketing

    func testSameDayFactsFoldIntoOneBucket() {
        let facts = [
            TxFact(date: date(2026, 9, 10, 8), amount: -15_000, currency: "IDR", category: "food", subtype: "normal"),
            TxFact(date: date(2026, 9, 10, 21), amount: -40_000, currency: "IDR", category: "food", subtype: "normal"),
        ]
        let buckets = RollupEngine.daily(from: facts, calendar: cal)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].txCount, 2)
        XCTAssertEqual(totalsIDR(buckets).expenses, 55_000, accuracy: 0.001)
    }

    func testDifferentDaysAreSeparateBucketsSortedAscending() {
        let facts = [
            TxFact(date: date(2026, 9, 12), amount: -1_000, currency: "IDR", category: "food", subtype: "normal"),
            TxFact(date: date(2026, 9, 10), amount: -2_000, currency: "IDR", category: "food", subtype: "normal"),
        ]
        let buckets = RollupEngine.daily(from: facts, calendar: cal)
        XCTAssertEqual(buckets.count, 2)
        XCTAssertLessThan(buckets[0].dayStart, buckets[1].dayStart)   // sorted ascending
    }

    // MARK: Spend / income conventions

    func testNormalSpendAndIncomeMatchAppModel() {
        let facts = [
            TxFact(date: date(2026, 9, 1), amount: 10_000_000, currency: "IDR", category: "salary", subtype: "normal"),
            TxFact(date: date(2026, 9, 2), amount: -250_000, currency: "IDR", category: "food", subtype: "normal"),
        ]
        let t = totalsIDR(RollupEngine.daily(from: facts, calendar: cal))
        XCTAssertEqual(t.income, 10_000_000, accuracy: 0.001)
        XCTAssertEqual(t.expenses, 250_000, accuracy: 0.001)
    }

    /// filteredExpenses/spent SUBTRACT a refund; filteredIncome ignores it.
    func testRefundSubtractsFromExpenseAndIsNotIncome() {
        let facts = [
            TxFact(date: date(2026, 9, 2), amount: -300_000, currency: "IDR", category: "shopping", subtype: "normal"),
            TxFact(date: date(2026, 9, 3), amount: 100_000, currency: "IDR", category: "shopping", subtype: "refund"),
        ]
        let t = totalsIDR(RollupEngine.daily(from: facts, calendar: cal))
        XCTAssertEqual(t.expenses, 200_000, accuracy: 0.001)   // 300k − 100k refund
        XCTAssertEqual(t.income, 0, accuracy: 0.001)           // refund is never income
        XCTAssertEqual(t.expenseByCategory["shopping"] ?? 0, 200_000, accuracy: 0.001)
    }

    /// Transfers move the balance but are neither income nor expense.
    func testTransfersOnlyAffectTransferNet() {
        let facts = [
            TxFact(date: date(2026, 9, 4), amount: -500_000, currency: "IDR", category: "other", subtype: "transfer"),
            TxFact(date: date(2026, 9, 4), amount: 500_000, currency: "IDR", category: "other", subtype: "transfer"),
        ]
        let t = totalsIDR(RollupEngine.daily(from: facts, calendar: cal))
        XCTAssertEqual(t.income, 0, accuracy: 0.001)
        XCTAssertEqual(t.expenses, 0, accuracy: 0.001)
        XCTAssertEqual(t.transferNet, 0, accuracy: 0.001)       // −500k + 500k
        XCTAssertEqual(t.txCount, 2)                            // still counted
        XCTAssertTrue(t.expenseByCategory.isEmpty)
    }

    // MARK: Multi-currency (the reason buckets are per-currency)

    func testMultiCurrencyConvertsPerCurrencyAtReadTime() {
        let facts = [
            TxFact(date: date(2026, 9, 5), amount: -50_000, currency: "IDR", category: "food", subtype: "normal"),
            TxFact(date: date(2026, 9, 5), amount: -10, currency: "USD", category: "food", subtype: "normal"),
        ]
        let t = totalsIDR(RollupEngine.daily(from: facts, calendar: cal))
        // 50,000 IDR + (10 USD × 16,000) = 210,000 IDR
        XCTAssertEqual(t.expenses, 210_000, accuracy: 0.001)
        XCTAssertEqual(t.expenseByCategory["food"] ?? 0, 210_000, accuracy: 0.001)
    }

    /// Legacy rows stored an empty currency; every reader treats "" as the
    /// target currency (no conversion). The engine must preserve that.
    func testEmptyCurrencyIsTreatedAsTargetCurrency() {
        let facts = [
            TxFact(date: date(2026, 9, 6), amount: -75_000, currency: "", category: "food", subtype: "normal"),
        ]
        let t = totalsIDR(RollupEngine.daily(from: facts, calendar: cal))
        XCTAssertEqual(t.expenses, 75_000, accuracy: 0.001)
    }

    // MARK: Category breakdown

    func testCategoryBreakdownSeparatesExpenseAndIncome() {
        let facts = [
            TxFact(date: date(2026, 9, 7), amount: -120_000, currency: "IDR", category: "food", subtype: "normal"),
            TxFact(date: date(2026, 9, 7), amount: -80_000, currency: "IDR", category: "transport", subtype: "normal"),
            TxFact(date: date(2026, 9, 7), amount: 5_000_000, currency: "IDR", category: "salary", subtype: "normal"),
        ]
        let t = totalsIDR(RollupEngine.daily(from: facts, calendar: cal))
        XCTAssertEqual(t.expenseByCategory["food"] ?? 0, 120_000, accuracy: 0.001)
        XCTAssertEqual(t.expenseByCategory["transport"] ?? 0, 80_000, accuracy: 0.001)
        XCTAssertNil(t.expenseByCategory["salary"])              // income, not spend
        XCTAssertEqual(t.incomeByCategory["salary"] ?? 0, 5_000_000, accuracy: 0.001)
    }

    // MARK: Range selection (arbitrary windows = the point of daily grain)

    func testBucketsInRangeIsInclusiveOfBothEnds() {
        let facts = (10...20).map { d in
            TxFact(date: date(2026, 9, d), amount: -1_000, currency: "IDR", category: "food", subtype: "normal")
        }
        let all = RollupEngine.daily(from: facts, calendar: cal)
        let window = RollupEngine.buckets(all, in: date(2026, 9, 12, 0)...date(2026, 9, 15, 23))
        // Days 12,13,14,15 — start-of-day inclusive on both ends.
        XCTAssertEqual(window.count, 4)
        XCTAssertEqual(totalsIDR(window).expenses, 4_000, accuracy: 0.001)
    }

    // MARK: Month grouping (the Firestore backup grain)

    func testGroupByMonthSplitsAcrossAPayCycleBoundary() {
        // A pay cycle for salary-day 25 runs ~24 Jul → 24 Aug. Two spends that
        // sit in the SAME cycle land in DIFFERENT month buckets — exactly why a
        // monthly rollup can't answer a cycle query, and daily can.
        let facts = [
            TxFact(date: date(2026, 7, 28), amount: -30_000, currency: "IDR", category: "food", subtype: "normal"),
            TxFact(date: date(2026, 8, 2), amount: -40_000, currency: "IDR", category: "food", subtype: "normal"),
        ]
        let grouped = RollupEngine.groupByMonth(RollupEngine.daily(from: facts, calendar: cal), calendar: cal)
        XCTAssertEqual(Set(grouped.keys), ["2026-07", "2026-08"])
        XCTAssertEqual(totalsIDR(grouped["2026-07"]!).expenses, 30_000, accuracy: 0.001)
        XCTAssertEqual(totalsIDR(grouped["2026-08"]!).expenses, 40_000, accuracy: 0.001)
    }

    func testMonthKeyIsZeroPaddedAndLocaleIndependent() {
        XCTAssertEqual(RollupEngine.monthKey(for: date(2026, 1, 5), calendar: cal), "2026-01")
        XCTAssertEqual(RollupEngine.monthKey(for: date(2026, 12, 31), calendar: cal), "2026-12")
    }

    // MARK: Gross vs net (HomeView month-flow convention)

    /// HomeView.recomputeMonthFlow counts ANY amount >= 0 as income (a refund's
    /// positive included) and ANY amount < 0 as expense; transfers excluded.
    /// That differs from the refund-netted, normal-only convention — the rollup
    /// carries both so it can match either screen.
    func testGrossInflowIncludesRefundsAndGrossExpenseSumsOutflows() {
        let facts = [
            TxFact(date: date(2026, 9, 2), amount: 5_000_000, currency: "IDR", category: "salary", subtype: "normal", cardID: "A"),
            TxFact(date: date(2026, 9, 3), amount: 100_000, currency: "IDR", category: "shopping", subtype: "refund", cardID: "A"),
            TxFact(date: date(2026, 9, 4), amount: -250_000, currency: "IDR", category: "food", subtype: "normal", cardID: "A"),
            TxFact(date: date(2026, 9, 4), amount: -500_000, currency: "IDR", category: "other", subtype: "transfer", cardID: "A"),
        ]
        let t = totalsIDR(RollupEngine.daily(from: facts, calendar: cal))
        // Home month-flow figures:
        XCTAssertEqual(t.grossInflow, 5_100_000, accuracy: 0.001)   // salary + refund positive
        XCTAssertEqual(t.grossExpense, 250_000, accuracy: 0.001)    // food only; transfer excluded
        // Canonical figures still available and distinct:
        XCTAssertEqual(t.income, 5_000_000, accuracy: 0.001)        // normal-only (no refund)
        XCTAssertEqual(t.expenses, 150_000, accuracy: 0.001)        // 250k − 100k refund
    }

    // MARK: Card dimension (screens are per-card)

    func testBucketsAreScopedPerCard() {
        let facts = [
            TxFact(date: date(2026, 9, 8), amount: -100_000, currency: "IDR", category: "food", subtype: "normal", cardID: "A"),
            TxFact(date: date(2026, 9, 8), amount: -20_000, currency: "IDR", category: "food", subtype: "normal", cardID: "B"),
        ]
        let all = RollupEngine.daily(from: facts, calendar: cal)
        XCTAssertEqual(all.count, 2)   // one bucket per (card, day)

        let range = date(2026, 9, 1, 0)...date(2026, 9, 30, 23)
        let a = RollupEngine.buckets(all, cardID: "A", in: range)
        let b = RollupEngine.buckets(all, cardID: "B", in: range)
        XCTAssertEqual(totalsIDR(a).expenses, 100_000, accuracy: 0.001)
        XCTAssertEqual(totalsIDR(b).expenses, 20_000, accuracy: 0.001)
        // No card filter = all cards combined.
        XCTAssertEqual(totalsIDR(RollupEngine.buckets(all, in: range)).expenses, 120_000, accuracy: 0.001)
    }

    /// `from:` is the window SmartBudgetManager.spent uses: `date >= monthStart`
    /// with NO upper bound, so whole-day buckets reproduce it exactly.
    func testFromStartHasNoUpperBoundAndScopesToCard() {
        let facts = [
            TxFact(date: date(2026, 8, 31), amount: -9_000, currency: "IDR", category: "food", subtype: "normal", cardID: "A"),   // before start
            TxFact(date: date(2026, 9, 1), amount: -30_000, currency: "IDR", category: "food", subtype: "normal", cardID: "A"),   // on start
            TxFact(date: date(2026, 9, 20), amount: -50_000, currency: "IDR", category: "food", subtype: "normal", cardID: "A"),  // later, no upper bound
            TxFact(date: date(2026, 9, 20), amount: -70_000, currency: "IDR", category: "food", subtype: "normal", cardID: "B"),  // other card
        ]
        let all = RollupEngine.daily(from: facts, calendar: cal)
        let win = RollupEngine.buckets(all, cardID: "A", from: date(2026, 9, 1, 0))
        XCTAssertEqual(totalsIDR(win).expenses, 80_000, accuracy: 0.001)   // 30k + 50k, not the 9k before start, not B's 70k
    }
}
