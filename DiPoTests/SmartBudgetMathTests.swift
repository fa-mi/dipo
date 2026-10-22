import XCTest
import SwiftData
@testable import DiPo

/// Smart Budget's arithmetic, pinned on what a check in October 2026 found
/// wrong: the screen and Home sizing one budget from two incomes, a purchase
/// backdated to last month warned against this month's limit, paying a debt
/// down called a spending spike, and a goal tip whose "weeks sooner" assumed
/// every goal was exactly a year away.
@MainActor
final class SmartBudgetMathTests: XCTestCase {

    private let cal = Calendar.current
    private let sb = SmartBudgetManager.shared
    private var saved: (enabled: Bool, daily: Double, lifestyle: Double, invest: Double,
                        card: String?, bills: [String], extra: [String])!
    private var savedUser: String?
    private var savedPlan: PremiumPlan = .free
    private var savedDismissed: [String]?

    override func setUp() {
        super.setUp()
        saved = (sb.isEnabled, sb.dailyRatio, sb.lifestyleRatio, sb.investDebtRatio,
                 sb.budgetCardID, sb.billCardIDs, sb.extraFundTxIDs)
        savedUser = UserSession.shared.userID
        savedPlan = PremiumManager.shared.plan
        savedDismissed = UserDefaults.standard.stringArray(forKey: "sb_dismissed_insights")
        UserDefaults.standard.removeObject(forKey: "sb_dismissed_insights")
        sb.budgetCardID = nil
        sb.billCardIDs = []
        sb.extraFundTxIDs = []
    }

    override func tearDown() {
        sb.isEnabled = saved.enabled
        sb.dailyRatio = saved.daily
        sb.lifestyleRatio = saved.lifestyle
        sb.investDebtRatio = saved.invest
        sb.budgetCardID = saved.card
        sb.billCardIDs = saved.bills
        sb.extraFundTxIDs = saved.extra
        UserSession.shared.userID = savedUser
        PremiumManager.shared.plan = savedPlan
        UserDefaults.standard.set(savedDismissed, forKey: "sb_dismissed_insights")
        super.tearDown()
    }

    /// Smart Budget on, for a signed-in Royal user, at 50/30/20.
    private func royal() {
        UserSession.shared.userID = "smart-budget-math-test"
        PremiumManager.shared.plan = .royal
        sb.isEnabled = true
        sb.dailyRatio = 0.50
        sb.lifestyleRatio = 0.30
        sb.investDebtRatio = 0.20
    }

    private func tx(_ amount: Double, _ cat: TxCategory, _ date: Date, currency: String = "IDR",
                    subtype: TxSubtype = .normal) -> TxRecord {
        TxRecord(name: cat.rawValue, date: date, amount: amount, type: "tx.type.purchase", icon: "X",
                 iconBgHex: cat.iconBg, category: cat, currency: currency, subtype: subtype)
    }

    private func card(_ name: String) -> BankCard {
        BankCard(holderName: name, cardNumber: "5221845086220969", balance: 0, expireDate: "11/29",
                 gradientStart: "#000000", gradientEnd: "#111111", sortOrder: 0, currency: "IDR")
    }

    private func idr(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: "IDR") }

    /// A period that started ten days ago and runs thirty.
    private var period: (start: Date, end: Date) {
        let start = cal.date(byAdding: .day, value: -10, to: cal.startOfDay(for: .now))!
        return (start, cal.date(byAdding: .day, value: 30, to: start)!)
    }

    // MARK: One income for one budget

    /// A salary saved before cards were linked has no card. Home counted it;
    /// the Smart Budget screen read only schedules linked by id, so it sized
    /// the same budget from whatever income had been logged instead.
    func testASalaryWithNoCardSizesTheBudgetEverywhere() {
        let bri = card("BRI")
        MainCard.set(bri)
        let salary = SalarySchedule(label: "Gaji", amount: 5_000_000, dayOfMonth: 25, currency: "IDR", cardID: nil)
        let logged = [tx(250_000, .freelance, period.start.addingTimeInterval(86_400))]
        let income = MainCard.budgetIncome(schedules: [salary], transactions: logged,
                                           from: period.start, to: period.end, currency: "IDR")
        XCTAssertEqual(income.amount, 5_000_000, accuracy: 0.5)
        XCTAssertTrue(income.fromSchedule)

        // Paid into another account only: still the income, as Home reads it.
        let elsewhere = SalarySchedule(label: "Gaji", amount: 4_000_000, dayOfMonth: 25, currency: "IDR",
                                       cardID: UUID())
        XCTAssertEqual(MainCard.budgetIncome(schedules: [elsewhere], transactions: logged, from: period.start,
                                             currency: "IDR").amount, 4_000_000, accuracy: 0.5)
    }

    /// No salary: what came in during the period. Refunds and transfers are
    /// not income, and neither is anything outside the period.
    func testWithoutASalaryItIsTheIncomeLoggedThisPeriod() {
        let p = period
        let rows = [tx(1_500_000, .business, p.start.addingTimeInterval(3_600)),
                    tx(700_000, .freelance, p.start.addingTimeInterval(5 * 86_400)),
                    tx(200_000, .shopping, p.start.addingTimeInterval(86_400), subtype: .refund),
                    tx(900_000, .other, p.start.addingTimeInterval(86_400), subtype: .transfer),
                    tx(3_000_000, .business, p.start.addingTimeInterval(-86_400)),
                    tx(3_000_000, .business, p.end.addingTimeInterval(3_600))]
        let income = MainCard.budgetIncome(schedules: [], transactions: rows, from: p.start, to: p.end,
                                           currency: "IDR")
        XCTAssertEqual(income.amount, 2_200_000, accuracy: 0.5)
        XCTAssertFalse(income.fromSchedule)
    }

    // MARK: The warning when adding a purchase

    func testOnlyAPurchaseInThisPeriodCanTakeItOverTheLimit() throws {
        royal()
        let p = period
        // Needs: 50% of Rp 5 jt is Rp 2,5 jt; Rp 2,4 jt is already spent.
        let spent = [tx(-2_400_000, .food, p.start.addingTimeInterval(86_400))]
        func check(_ date: Date) -> BudgetAlert? {
            sb.wouldExceed(category: .food, amount: 300_000, currency: "IDR", date: date,
                           transactions: spent, income: 5_000_000, periodStart: p.start, periodEnd: p.end)
        }
        let today = try XCTUnwrap(check(.now))
        XCTAssertTrue(today.isExceeded)
        XCTAssertEqual(today.over, 200_000, accuracy: 0.5)
        XCTAssertNil(check(p.start.addingTimeInterval(-3 * 86_400)), "backdated to last period")
        XCTAssertNil(check(p.end.addingTimeInterval(86_400)), "dated after this period")
    }

    /// "Almost at your limit" says what is left once this is saved, in the
    /// card's own currency.
    func testTheNearlyThereWarningCountsThisPurchase() throws {
        royal()
        let p = period
        let spent = [tx(-1_600, .food, p.start.addingTimeInterval(86_400), currency: "USD")]
        let alert = try XCTUnwrap(sb.wouldExceed(category: .food, amount: 700, currency: "USD", date: .now,
                                                 transactions: spent, income: 5_000,
                                                 periodStart: p.start, periodEnd: p.end))
        XCTAssertFalse(alert.isExceeded)
        XCTAssertEqual(alert.leftAfter, 200, accuracy: 0.01, "2.500 limit − 1.600 − 700, not the 900 before it")
        XCTAssertEqual(alert.currency, "USD")
    }

    // MARK: What DiPo says

    /// Paying a debt down faster than last period is not a spending spike.
    func testPayingMoreDebtIsNotASpendingSpike() {
        royal()
        let p = period
        let previous = cal.date(byAdding: .month, value: -1, to: p.start)!.addingTimeInterval(86_400)
        func insights(_ cat: TxCategory) -> [SmartInsight] {
            sb.evaluateAll(allTransactions: [tx(-600_000, cat, previous),
                                             tx(-2_000_000, cat, Date().addingTimeInterval(-86_400))],
                           income: 50_000_000, targetCurrency: "IDR",
                           periodStart: p.start, periodEnd: p.end)
        }
        let spike = { (cat: TxCategory) in String(format: loc("insight.cat_up_title"), cat.displayLabel, self.idr(1_400_000)) }
        XCTAssertTrue(insights(.food).contains { $0.title == spike(.food) }, "the check still works on spending")
        XCTAssertFalse(insights(.debtPayment).contains { $0.title == spike(.debtPayment) })
        XCTAssertFalse(insights(.investment).contains { $0.title == spike(.investment) })
    }

    func testAnUnusualMonthOfDebtPaymentsIsNotAnAnomaly() {
        royal()
        let p = period
        func rows(_ cat: TxCategory) -> [TxRecord] {
            (1...6).map { tx(-500_000, cat, cal.date(byAdding: .month, value: -$0, to: p.start)!.addingTimeInterval(86_400)) }
                + [tx(-3_000_000, cat, Date().addingTimeInterval(-86_400))]
        }
        let label = { (cat: TxCategory) in String(format: loc("insight.spike_title"), cat.displayLabel) }
        XCTAssertTrue(sb.spendingAnomalies(allTransactions: rows(.food), periodStart: p.start)
            .contains { $0.title == label(.food) })
        XCTAssertTrue(sb.spendingAnomalies(allTransactions: rows(.debtPayment), periodStart: p.start).isEmpty)
    }

    /// Debt payments past 70% of income: said as the share of income they
    /// took, not as a percentage above the 70%.
    func testHeavyDebtPaymentsAreSaidAsAShareOfIncome() throws {
        royal()
        let p = period
        let first = try XCTUnwrap(sb.evaluateAll(allTransactions: [tx(-4_000_000, .debtPayment, Date().addingTimeInterval(-86_400))],
                                                 income: 5_000_000, targetCurrency: "IDR",
                                                 periodStart: p.start, periodEnd: p.end).first)
        XCTAssertEqual(first.body, String(format: loc("insight.debt_high_body"), 80))
    }

    // MARK: The goal tip

    /// Rp 300.000 more a month on a Rp 10 jt goal already getting Rp 500.000:
    /// 20 months becomes 12½, so 7½ months sooner. The old formula said a week.
    func testSoonerIsTheTimeSavedAtTheCurrentPace() {
        XCTAssertEqual(SmartBudgetManager.goalSooner(remaining: 10_000_000, pace: 500_000, extra: 300_000), .months(8))
        XCTAssertEqual(SmartBudgetManager.goalSooner(remaining: 10_000_000, pace: 2_000_000, extra: 300_000), .weeks(3))
        XCTAssertNil(SmartBudgetManager.goalSooner(remaining: 1_000_000, pace: 500_000, extra: 50_000),
                     "under two weeks is not worth saying")
    }

    /// Nothing going in, or so little it would take decades: say how long the
    /// extra alone takes rather than "sooner" than never.
    func testWithNoPaceItSaysHowLongTheExtraTakes() {
        XCTAssertEqual(SmartBudgetManager.goalSooner(remaining: 10_000_000, pace: 0, extra: 300_000), .reachedIn(months: 34))
        XCTAssertEqual(SmartBudgetManager.goalSooner(remaining: 10_000_000, pace: 10_000, extra: 300_000), .reachedIn(months: 34))
        XCTAssertNil(SmartBudgetManager.goalSooner(remaining: 50_000_000, pace: 0, extra: 300_000), "over five years")
    }

    func testTheGoalTipQuotesTheMonthsItSaves() throws {
        royal()
        let p = period
        let motor = SavingsGoal(name: "Motor", targetAmount: 12_000_000, savedAmount: 2_000_000,
                                currency: "IDR", monthlyContribution: 500_000)
        let tip = try XCTUnwrap(sb.goalLinkedInsight(allTransactions: [tx(-2_000_000, .shopping, Date().addingTimeInterval(-86_400))],
                                                     income: 10_000_000, goals: [motor],
                                                     targetCurrency: "IDR", periodStart: p.start))
        XCTAssertEqual(tip.body, String(format: loc("insight.goal_linked_body_months"), idr(300_000), "Motor", 8))
    }

    // MARK: Wants running ahead

    func testWantsPaceIsSaidAsTheAmountItWouldGoOver() throws {
        // Rp 2,1 jt of a Rp 3 jt limit 45% of the way through: heading for
        // Rp 4.666.667, about Rp 1,67 jt over.
        let over = try XCTUnwrap(SmartBudgetManager.wantsOverspill(spent: 2_100_000, limit: 3_000_000, progress: 0.45))
        XCTAssertEqual(over, 2_100_000 / 0.45 - 3_000_000, accuracy: 1)
        XCTAssertNil(SmartBudgetManager.wantsOverspill(spent: 2_100_000, limit: 3_000_000, progress: 0.30), "too early to say")
        XCTAssertNil(SmartBudgetManager.wantsOverspill(spent: 2_100_000, limit: 3_000_000, progress: 0.90), "too late to change")
        XCTAssertNil(SmartBudgetManager.wantsOverspill(spent: 1_800_000, limit: 3_000_000, progress: 0.45), "not far ahead")
        XCTAssertNil(SmartBudgetManager.wantsOverspill(spent: 3_100_000, limit: 3_000_000, progress: 0.45), "already over")
        XCTAssertNil(SmartBudgetManager.wantsOverspill(spent: 100, limit: 0, progress: 0.45))
    }

    // MARK: Credit-card purchases

    /// Groceries bought on a credit card count in Needs where they were made,
    /// and paying the card from the main card doesn't count them again. The
    /// budget used to read the main card alone, so they counted nowhere.
    func testCreditCardPurchasesCountOnceWhereTheyAreMade() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        let container = try ModelContainer(for: schema,
                                           configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        let bri = card("BRI")
        let visa = card("Visa")
        visa.isCreditCard = true
        context.insert(bri)
        context.insert(visa)
        MainCard.set(bri)
        let p = period
        let day = p.start.addingTimeInterval(86_400)
        func add(_ row: TxRecord, to card: BankCard) {
            context.insert(row)
            card.transactions.append(row)
        }
        // Rp 900.000 of groceries on the card, Rp 100.000 of it refunded.
        add(tx(-900_000, .food, day), to: visa)
        add(tx(100_000, .food, day, subtype: .refund), to: visa)
        // The bill paid from BRI: a transfer out of BRI, a transfer into the card.
        add(tx(-800_000, .other, day.addingTimeInterval(3_600), subtype: .transfer), to: bri)
        add(tx(800_000, .other, day.addingTimeInterval(3_600), subtype: .transfer), to: visa)

        let cards = [bri, visa]
        let spending = MainCard.budgetSpendingTransactions(in: cards)
        XCTAssertEqual(sb.spent(in: .daily, transactions: spending, targetCurrency: "IDR", periodStart: p.start),
                       800_000, accuracy: 0.5)
        XCTAssertEqual(MainCard.creditCardSpending(in: cards).count, 2, "the payment arriving is not spending")
        XCTAssertTrue(MainCard.budgetSpendingCardIDs(in: cards).contains(visa.id.uuidString))
        XCTAssertEqual(MainCard.budgetIncome(schedules: [], transactions: spending, from: p.start,
                                             currency: "IDR").amount, 0, "a refund on the card is not income")
        // The pot alone, what Statistics reads as cash, holds no groceries.
        XCTAssertEqual(sb.spent(in: .daily, transactions: MainCard.budgetTransactions(in: cards),
                                targetCurrency: "IDR", periodStart: p.start), 0)
        withExtendedLifetime(container) {}
    }

    // MARK: What goes where

    /// Every category offered for a purchase belongs to one group; money-in
    /// categories to none. Bonus sat in Savings & debt, so "What goes where"
    /// told people their bonus was a debt payment.
    func testEveryExpenseCategoryHasOneGroupAndIncomeHasNone() {
        let expenses: [TxCategory] = [.shopping, .food, .travel, .bills, .transport, .health,
                                      .commitment, .investment, .debtPayment, .other]
        for cat in expenses { XCTAssertNotNil(sb.group(for: cat), cat.rawValue) }
        for cat in [TxCategory.salary, .freelance, .business, .bonus, .gift, .incomeOther] {
            XCTAssertNil(sb.group(for: cat), cat.rawValue)
        }
        XCTAssertEqual(SmartBudgetManager.investDebtCategories, [.investment, .debtPayment])
        XCTAssertFalse(SmartBudgetManager.spendingCategories.contains(.debtPayment))
        XCTAssertFalse(SmartBudgetManager.spendingCategories.contains(.investment))
    }
}
