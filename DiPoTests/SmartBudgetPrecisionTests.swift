import XCTest
@testable import DiPo

/// Smart Budget's figures, pinned on the cases that were wrong: a pay cycle
/// ended on the 25th when the salary lands on the 23rd, a 15% target read as
/// a red "over the limit", a Netlify charge called a Gold-invest duplicate,
/// debt payments counted as living costs.
@MainActor
final class SmartBudgetPrecisionTests: XCTestCase {

    private let cal = Calendar.current

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func start(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.startOfDay(for: day(y, m, d)) }

    private func tx(_ name: String, _ date: Date, _ amount: Double, _ cat: TxCategory,
                    notes: String = "", subtype: TxSubtype = .normal) -> TxRecord {
        TxRecord(name: name, date: date, amount: amount, type: "tx.type.purchase", icon: "circle",
                 iconBgHex: cat.iconBg, category: cat, currency: "IDR", notes: notes, subtype: subtype)
    }

    private func ago(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86_400) }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "recurringDuplicates.notDuplicates")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "recurringDuplicates.notDuplicates")
        super.tearDown()
    }

    // MARK: The pay cycle

    /// Payday the 25th; 25 Oct 2026 is a Sunday, so the salary lands Friday
    /// the 23rd. On 6 Oct the period is 25 Sep – 22 Oct: day 12 of 28, 17 days
    /// left counting today. "Start plus one month" said the 25th.
    func testCycleEndsAtTheRealNextPayday() {
        let now = day(2026, 10, 6)
        let c = StatPeriod.cycle(payDay: 25, salaryDates: [start(2026, 9, 25)], now: now)
        XCTAssertEqual(c.start, start(2026, 9, 25))
        XCTAssertEqual(c.end, start(2026, 10, 23))
        let d = StatPeriod.cycleDay(c, now: now)
        XCTAssertEqual(d.day, 12)
        XCTAssertEqual(d.of, 28)
        XCTAssertEqual(StatPeriod.daysLeft(in: c, now: now), 17)
    }

    /// A salary that landed a day early opens the new period that day.
    func testEarlySalaryOpensTheNewCycle() {
        let now = day(2026, 10, 22, 10)
        let c = StatPeriod.cycle(payDay: 25, salaryDates: [start(2026, 9, 25), day(2026, 10, 22, 8)], now: now)
        XCTAssertEqual(c.start, start(2026, 10, 22))
        XCTAssertEqual(c.end, start(2026, 11, 25))
    }

    /// Payday the 1st, paid on the 30th: the next payday still counts from
    /// October, not from the September the salary happened to land in.
    func testSnappedStartDoesNotShiftTheNextPayday() {
        let now = day(2026, 10, 5)
        let c = StatPeriod.cycle(payDay: 1, salaryDates: [day(2026, 9, 30, 9)], now: now)
        XCTAssertEqual(c.start, start(2026, 9, 30))
        XCTAssertGreaterThan(c.end, now, "the period must end after today")
        XCTAssertEqual(cal.component(.month, from: c.end), 11)
    }

    // MARK: Percentages

    func testPercentagesRoundRatherThanTruncate() {
        XCTAssertEqual(BudgetGroup.pct(1 - 0.65 - 0.15), 20)
        XCTAssertEqual(BudgetGroup.pct(0.19999999999999998), 20)
        XCTAssertEqual(BudgetGroup.pct(2_000_000, of: 10_000_000), 20)
        XCTAssertEqual(BudgetGroup.pct(5_558_500, of: 10_000_000), 56)
        XCTAssertEqual(BudgetGroup.pct(1, of: 0), 0)
    }

    /// Needs and Wants have limits; Savings & debt has a target.
    func testOnlyNeedsAndWantsAreLimits() {
        XCTAssertTrue(BudgetGroup.daily.isCeiling)
        XCTAssertTrue(BudgetGroup.lifestyle.isCeiling)
        XCTAssertFalse(BudgetGroup.investDebt.isCeiling)
    }

    /// Rp 2 jt to a card is 20% of a Rp 10 jt pay: the 15% target is reached,
    /// said in green — not "Great savings rate, above the 20% goal".
    func testSetAsideIsJudgedAgainstTheUsersOwnTarget() {
        let i = SmartBudgetManager.shared.setAsideInsight(setAside: 2_000_000, income: 10_000_000,
                                                          target: 0.15, currency: "IDR")
        XCTAssertEqual(i.title, String(format: loc("insight.setaside_met_title"), BudgetGroup.investDebt.label, 20))
        XCTAssertEqual(i.color, AppTheme.accent)
        let short = SmartBudgetManager.shared.setAsideInsight(setAside: 1_000_000, income: 10_000_000,
                                                              target: 0.15, currency: "IDR")
        XCTAssertEqual(short.title, String(format: loc("insight.setaside_title"), BudgetGroup.investDebt.label, 10))
    }

    /// A refund gives its amount back to the group, as in Statistics.
    func testGroupSpendNetsRefunds() {
        let rows = [tx("Sepatu", ago(3), -500_000, .shopping),
                    tx("Refund sepatu", ago(1), 200_000, .shopping, subtype: .refund),
                    tx("Pindah", ago(1), -300_000, .shopping, subtype: .transfer)]
        let wants = BudgetGroupMath.rows(.lifestyle, in: rows, from: ago(10))
        XCTAssertEqual(wants.count, 2, "the transfer is not spending")
        XCTAssertEqual(BudgetGroupMath.spent(wants, currency: "IDR"), 300_000, accuracy: 0.5)
    }

    // MARK: Projection

    func testProjectionRatesDayToDayAndCountsFixedOnce() {
        let p = StatisticsView.projection(variable: 2_400_000, fixed: 4_300_000, upcoming: 2_265_000,
                                          progress: (elapsed: 12, total: 28))
        XCTAssertEqual(p ?? 0, 2_400_000 / 12 * 28 + 4_300_000 + 2_265_000, accuracy: 0.5)
        XCTAssertNil(StatisticsView.projection(variable: 1, fixed: 0, upcoming: 0, progress: (elapsed: 0, total: 28)))
    }

    // MARK: Duplicates

    /// The real case: two Netlify charges of Rp 200.000 in two different pay
    /// periods, and Gold invest recorded once. Nothing is a duplicate — the
    /// old check reported "Possible duplicate: Gold invest".
    func testSameAmountInOtherPeriodsOrOtherBillsIsNotADuplicate() {
        let gold = RecurringExpense(label: "Gold invest", amount: 200_000, dayOfMonth: 28, currency: "IDR")
        let netlify = RecurringExpense(label: "Netlify", amount: 200_000, dayOfMonth: 13, category: .bills, currency: "IDR")
        let txs = [tx("netlify", day(2026, 8, 15), -200_000, .bills),
                   tx("Netlify", day(2026, 9, 13, 0), -200_000, .bills, notes: "tx.note.recurring_auto"),
                   tx("Gold invest", day(2026, 9, 28, 0), -200_000, .commitment, notes: "tx.note.recurring_auto")]
        let pairs = RecurringDuplicates.find(transactions: txs, recurrings: [gold, netlify], payDay: 25,
                                             salaryDates: [day(2026, 8, 25, 0), day(2026, 9, 25, 0)],
                                             currency: "IDR")
        XCTAssertTrue(pairs.isEmpty, "\(pairs.map(\.planLabel))")
    }

    /// DiPo recorded "transfer mom" and the same Rp 1 jt was entered by hand
    /// in the same pay period: one pair, both rows named.
    func testRecordedBillAndHandEntryInOnePeriodArePaired() {
        let mom = RecurringExpense(label: "transfer mom", amount: 1_000_000, dayOfMonth: 1, currency: "IDR")
        let recorded = tx("transfer mom", day(2026, 10, 1, 0), -1_000_000, .commitment, notes: "tx.note.recurring_auto")
        let manual = tx("Tranfer ibu", day(2026, 9, 27), -1_000_000, .commitment)
        let lastMonth = tx("Tranfer ibu", day(2026, 8, 28), -1_000_000, .commitment)
        let pairs = RecurringDuplicates.find(transactions: [recorded, manual, lastMonth], recurrings: [mom],
                                             payDay: 25, salaryDates: [day(2026, 8, 25, 0), day(2026, 9, 25, 0)],
                                             currency: "IDR")
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.recorded.id, recorded.id)
        XCTAssertEqual(pairs.first?.twin.id, manual.id)
        XCTAssertEqual(pairs.first?.amount ?? 0, 1_000_000, accuracy: 0.5)

        // "Both are real" is remembered.
        RecurringDuplicates.markBothReal(pairs[0])
        XCTAssertTrue(RecurringDuplicates.find(transactions: [recorded, manual, lastMonth], recurrings: [mom],
                                               payDay: 25, salaryDates: [day(2026, 9, 25, 0)],
                                               currency: "IDR").isEmpty)
    }

    // MARK: Recommendation

    private func analyze(_ txs: [TxRecord], goals: [SavingsGoal] = [], cycle: RecoCycleSnapshot? = nil,
                         recurringMonthly: Double = 0, labels: [String] = [],
                         duplicates: [RecurringDuplicatePair] = [],
                         carried: Double = 0) -> SmartRecommendation {
        SmartRecommendationEngine.analyze(transactions: txs, monthlyIncome: 10_000_000, goals: goals, debts: [],
                                          currency: "IDR", currentCycle: cycle,
                                          recurringMonthly: recurringMonthly, recurringLabels: labels,
                                          duplicates: duplicates, creditCardCarried: carried)
    }

    /// Paying a debt is not living cost: Rp 12 jt of food and Rp 3 jt to a
    /// card against a Rp 10 jt salary is a Rp 2 jt leak, not Rp 5 jt.
    func testDebtPaymentsAreNotPartOfTheLeak() {
        let r = analyze([tx("Makan", ago(10), -12_000_000, .food),
                         tx("Bayar CC", ago(5), -3_000_000, .debtPayment)])
        XCTAssertTrue(r.isDeficit)
        XCTAssertEqual(r.deficitAmount, 2_000_000, accuracy: 1)
    }

    /// "Automate Rp 1 jt to goals" does not sit under "stop the leak first".
    func testGoalFundingCardWaitsUntilTheLeakCloses() {
        let goal = SavingsGoal(name: "Mecca", targetAmount: 150_000_000, currency: "IDR",
                               monthlyContribution: 1_000_000)
        let deficit = analyze([tx("Makan", ago(10), -12_000_000, .food)], goals: [goal])
        XCTAssertFalse(deficit.topItems.contains { $0.icon == "calendar.badge.clock" })
        let tight = analyze([tx("Makan", ago(10), -9_500_000, .food)], goals: [goal])
        XCTAssertTrue(tight.topItems.contains { $0.icon == "calendar.badge.clock" })
    }

    /// "avg X% of income" is the average of the past periods, not this
    /// period's projection.
    func testLifestyleReasonQuotesTheAverage() {
        let txs = [tx("Belanja", ago(20), -5_000_000, .shopping), tx("Makan", ago(5), -1_000_000, .food)]
        let cycle = RecoCycleSnapshot(daily: 1_000_000, lifestyle: 1_000_000, investDebt: 0, savingsDeposits: 0,
                                      income: 10_000_000, elapsedFraction: 0.5)
        let r = analyze(txs, cycle: cycle)
        XCTAssertTrue(r.reasons.contains(String(format: loc("reco.why.lifestyle"), 50)), "\(r.reasons)")
    }

    /// A measured fact is quoted to the rupiah thousand, and its percentage
    /// is of that same figure — not "Rp 5.500.000 (56%)".
    func testFixedCostsAreQuotedPrecisely() {
        let r = analyze([tx("Kos & tagihan", ago(10), -5_558_500, .commitment)],
                        recurringMonthly: 3_932_500, labels: ["kos"])
        let cm = CurrencyManager.shared
        let expected = String(format: loc("reco.why.fixed_combined"),
                              cm.formatted(5_559_000, currency: "IDR"), 56, "kos",
                              cm.formatted(3_933_000, currency: "IDR"))
        XCTAssertTrue(r.reasons.contains(expected), "\(r.reasons)")
    }

    /// A card balance carried from earlier months is costly debt: the plan
    /// routes money to paying it before anything is invested.
    func testCarriedCardBalanceSteersThePlanToDebt() {
        let txs = [tx("Makan", ago(5), -3_000_000, .food)]
        XCTAssertEqual(analyze(txs, carried: 5_000_000).recommendedRatios.investDebt, 0.30, accuracy: 0.001)
        XCTAssertNotEqual(analyze(txs).recommendedRatios.investDebt, 0.30, accuracy: 0.001)
    }

    /// A suspected duplicate opens the review.
    func testDuplicateItemOpensTheReview() {
        let recorded = tx("transfer mom", ago(5), -1_000_000, .commitment, notes: "tx.note.recurring_auto")
        let manual = tx("Tranfer ibu", ago(8), -1_000_000, .commitment)
        let pair = RecurringDuplicatePair(planLabel: "transfer mom", recorded: recorded, twin: manual,
                                          amount: 1_000_000, periodStart: ago(10))
        let r = analyze([recorded, manual, tx("Makan", ago(3), -2_000_000, .food)], duplicates: [pair])
        XCTAssertTrue(r.topItems.contains { $0.action == .reviewDuplicates })
    }
}
