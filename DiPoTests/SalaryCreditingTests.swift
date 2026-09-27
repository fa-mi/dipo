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
        _ = makeSchedule(card: card, day: today - 1, createdDaysAgo: 2)

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
        _ = makeSchedule(card: bank, day: today - 1, createdDaysAgo: 2)
        _ = makeSchedule(card: wallet, day: today - 1, createdDaysAgo: 2)

        SalaryCreditEngine.processIfNeeded(context: context)

        XCTAssertEqual(bank.transactions.count, 1)
        XCTAssertEqual(wallet.transactions.count, 1, "The second card was left empty by the old stamp.")
    }

    /// Running again must not pay twice.
    func testDoesNotCreditTwice() throws {
        let today = cal.component(.day, from: Date())
        try XCTSkipIf(today < 3, "Needs a day that can have a payday behind it.")
        let card = makeCard()
        _ = makeSchedule(card: card, day: today - 1, createdDaysAgo: 2)

        SalaryCreditEngine.processIfNeeded(context: context)
        SalaryCreditEngine.processIfNeeded(context: context)

        XCTAssertEqual(salaryCount, 1)
    }

    /// Auto-record off means the schedule is for planning only.
    func testRespectsTheAutoRecordSwitch() throws {
        let today = cal.component(.day, from: Date())
        try XCTSkipIf(today < 3, "Needs a day that can have a payday behind it.")
        let card = makeCard()
        let schedule = makeSchedule(card: card, day: today - 1, createdDaysAgo: 2)
        schedule.autoRecord = false

        SalaryCreditEngine.processIfNeeded(context: context)

        XCTAssertEqual(salaryCount, 0)
    }
}
