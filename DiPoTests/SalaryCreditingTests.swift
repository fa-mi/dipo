import XCTest
import SwiftData
@testable import DiPo

/// The salary engine writes real income transactions, so every rule about WHEN
/// it credits is a rule about the user's balance — and a miss is invisible:
/// nothing appears, and nothing says anything is wrong.
@MainActor
final class SalaryCreditingTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let cal = Calendar.current

    override func setUpWithError() throws {
        let schema = Schema([
            BankCard.self, TxRecord.self, SalarySchedule.self,
            DebtRecord.self, SavingsGoal.self, RecurringExpense.self,
            Receivable.self, CardInstallment.self,
            CardBudgetConfig.self, CycleIntent.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    private func makeCard() -> BankCard {
        let card = BankCard(holderName: "Test", cardNumber: "423456••••••7890",
                            balance: 0, expireDate: "12/30",
                            gradientStart: "#000000", gradientEnd: "#111111",
                            sortOrder: 0, currency: "IDR")
        context.insert(card)
        return card
    }

    private func makeSchedule(card: BankCard, day: Int, createdDaysAgo: Int) -> SalarySchedule {
        let schedule = SalarySchedule(label: "Main Job", amount: 100_000,
                                      dayOfMonth: day, currency: "IDR", cardID: card.id)
        schedule.autoRecord = true
        schedule.createdAt = cal.date(byAdding: .day, value: -createdDaysAgo, to: Date())!
        context.insert(schedule)
        return schedule
    }

    /// A payday that has already landed this month, and how many days ago to
    /// create the schedule so it predates that payday by one day.
    ///
    /// Yesterday is not always the day the money lands: the engine pays early
    /// when the day falls on a weekend or holiday (SalaryDateEngine.actualPayDate),
    /// so a Sunday payday lands on the Friday before. Building the case from
    /// "yesterday, created two days ago" put the real payday BEFORE creation on
    /// every Monday, and the engine rightly refused to back-date it.
    private func paydayBehindToday() throws -> (day: Int, createdDaysAgo: Int) {
        let today = cal.startOfDay(for: Date())
        let day = cal.component(.day, from: today) - 1
        let payDate = cal.startOfDay(for: SalaryDateEngine.actualPayDate(
            dayOfMonth: day,
            month: cal.component(.month, from: today),
            year: cal.component(.year, from: today)))
        // Early in a month that opens with holidays, the pay date walks forward.
        try XCTSkipIf(payDate > today, "This month's payday for day \(day) hasn't landed yet.")
        let landedDaysAgo = cal.dateComponents([.day], from: payDate, to: today).day ?? 0
        return (day, landedDaysAgo + 1)
    }

    private var salaryCount: Int {
        ((try? context.fetch(FetchDescriptor<TxRecord>())) ?? [])
            .filter { $0.notes == "tx.note.salary_auto" }.count
    }

    /// The bug this file exists for. A schedule set up before its payday used to
    /// be stamped "already credited this month" at creation, so when the day
    /// arrived the engine skipped it — and, because the stamp never expires for
    /// that month, it skipped it for good.
    func testCreditsAScheduleSetUpEarlierThisMonth() throws {
        let today = cal.component(.day, from: Date())
        // A payday that has already come round this month, with the schedule
        // created before it.
        try XCTSkipIf(today < 3, "Needs a day that can have a payday behind it.")
        let card = makeCard()
        let payday = try paydayBehindToday()
        _ = makeSchedule(card: card, day: payday.day, createdDaysAgo: payday.createdDaysAgo)

        SalaryCreditEngine.processIfNeeded(context: context)

        XCTAssertEqual(salaryCount, 1, "The payday passed after setup — it should be credited.")
        XCTAssertEqual(card.transactions.first?.amount, 100_000)
    }

    /// The rule the removed stamp was there to protect, which the engine already
    /// enforced on its own: nothing is invented for a payday that had already
    /// passed when the schedule was created.
    func testDoesNotBackPostAPaydayFromBeforeSetup() throws {
        let today = cal.component(.day, from: Date())
        try XCTSkipIf(today < 3, "Needs a day that can have a payday behind it.")
        let card = makeCard()
        _ = makeSchedule(card: card, day: today - 2, createdDaysAgo: 0)

        SalaryCreditEngine.processIfNeeded(context: context)

        XCTAssertEqual(salaryCount, 0, "That payday was before the schedule existed.")
    }

    /// Two schedules paying into two different cards both get their money — the
    /// case that surfaced the bug was a second salary into an e-wallet that
    /// stayed empty while the first one worked.
    func testTwoSchedulesOnDifferentCardsBothCredit() throws {
        let today = cal.component(.day, from: Date())
        try XCTSkipIf(today < 3, "Needs a day that can have a payday behind it.")
        let bank = makeCard()
        let wallet = makeCard()
        let payday = try paydayBehindToday()
        _ = makeSchedule(card: bank, day: payday.day, createdDaysAgo: payday.createdDaysAgo)
        _ = makeSchedule(card: wallet, day: payday.day, createdDaysAgo: payday.createdDaysAgo)

        SalaryCreditEngine.processIfNeeded(context: context)

        XCTAssertEqual(bank.transactions.count, 1)
        XCTAssertEqual(wallet.transactions.count, 1, "The second card was left empty by the old stamp.")
    }

    /// Running again must not pay twice.
    func testDoesNotCreditTwice() throws {
        let today = cal.component(.day, from: Date())
        try XCTSkipIf(today < 3, "Needs a day that can have a payday behind it.")
        let card = makeCard()
        let payday = try paydayBehindToday()
        _ = makeSchedule(card: card, day: payday.day, createdDaysAgo: payday.createdDaysAgo)

        SalaryCreditEngine.processIfNeeded(context: context)
        SalaryCreditEngine.processIfNeeded(context: context)

        XCTAssertEqual(salaryCount, 1)
    }

    /// Auto-record off means the schedule is for planning only.
    func testRespectsTheAutoRecordSwitch() throws {
        let today = cal.component(.day, from: Date())
        try XCTSkipIf(today < 3, "Needs a day that can have a payday behind it.")
        let card = makeCard()
        let payday = try paydayBehindToday()
        let schedule = makeSchedule(card: card, day: payday.day, createdDaysAgo: payday.createdDaysAgo)
        schedule.autoRecord = false

        SalaryCreditEngine.processIfNeeded(context: context)

        XCTAssertEqual(salaryCount, 0)
    }
}
