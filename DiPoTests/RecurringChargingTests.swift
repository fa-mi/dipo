import XCTest
import SwiftData
@testable import DiPo

// The recurring engine writes real debit transactions, so every rule about
// WHEN it charges is a rule about the user's balance. These run the engine
// against an in-memory store.
@MainActor
final class RecurringChargingTests: XCTestCase {

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

    // MARK: Helpers

    private func makeCard() -> BankCard {
        let c = BankCard(holderName: "BCA", cardNumber: "4111111111111111",
                         balance: 10_000_000, expireDate: "11/29",
                         gradientStart: "#000000", gradientEnd: "#111111",
                         sortOrder: 0, currency: "IDR")
        context.insert(c)
        return c
    }

    private func makeBill(on card: BankCard, day: Int, createdMonthsAgo: Int,
                          lastChargedMonthsAgo: Int?) -> RecurringExpense {
        let e = RecurringExpense(label: "Kos", amount: 1_500_000, dayOfMonth: day,
                                 category: .bills, currency: "IDR", cardID: card.id)
        e.createdAt = cal.date(byAdding: .month, value: -createdMonthsAgo, to: .now)!
        if let n = lastChargedMonthsAgo {
            let d = cal.date(byAdding: .month, value: -n, to: .now)!
            e.lastChargedMonth = cal.component(.month, from: d)
            e.lastChargedYear  = cal.component(.year, from: d)
        }
        context.insert(e)
        return e
    }

    private func autoCharges(_ card: BankCard) -> Int {
        card.transactions.filter { $0.notes == "tx.note.recurring_auto" }.count
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: Engine

    /// The defect: resuming a bill paused for months posted every paused month
    /// at once, back-dated, straight off the balance.
    func testResumingAPausedBillDoesNotChargeThePausedMonths() throws {
        let card = makeCard()
        // Day 1, so this month's due date is always today or already past.
        let bill = makeBill(on: card, day: 1, createdMonthsAgo: 6, lastChargedMonthsAgo: 4)
        bill.isActive = false
        try context.save()

        RecurringExpenseEngine.processIfNeeded(context: context)
        XCTAssertEqual(autoCharges(card), 0, "A paused bill is never charged")

        bill.markCaughtUp()
        bill.isActive = true
        RecurringExpenseEngine.processIfNeeded(context: context)

        // Only a due date of TODAY survives the resume; one that passed while
        // paused does not.
        let dueToday = cal.component(.day, from: .now) == 1
        XCTAssertEqual(autoCharges(card), dueToday ? 1 : 0,
                       "Resuming must not back-charge the months the bill was paused")
    }

    /// The catch-up itself is right and must survive the fix: an app that was
    /// simply not opened still records every month that fell due.
    func testAnActiveBillStillCatchesUpMonthsTheAppWasNotOpened() throws {
        let card = makeCard()
        _ = makeBill(on: card, day: 1, createdMonthsAgo: 6, lastChargedMonthsAgo: 3)
        try context.save()

        RecurringExpenseEngine.processIfNeeded(context: context)

        // Two months ago, last month, and this month (day 1 has always arrived).
        XCTAssertEqual(autoCharges(card), 3)
    }

    func testTurningAutoRecordBackOnDoesNotBackCharge() throws {
        let card = makeCard()
        let bill = makeBill(on: card, day: 1, createdMonthsAgo: 6, lastChargedMonthsAgo: 5)
        bill.autoRecord = false
        try context.save()
        RecurringExpenseEngine.processIfNeeded(context: context)
        XCTAssertEqual(autoCharges(card), 0)

        bill.markCaughtUp()
        bill.autoRecord = true
        RecurringExpenseEngine.processIfNeeded(context: context)

        let dueToday = cal.component(.day, from: .now) == 1
        XCTAssertEqual(autoCharges(card), dueToday ? 1 : 0)
    }

    // MARK: markCaughtUp

    func testDueDateLaterThisMonthIsStillCharged() {
        let bill = RecurringExpense(label: "Netflix", amount: 186_000, dayOfMonth: 20)
        bill.markCaughtUp(now: date(2026, 9, 14))
        XCTAssertEqual(bill.lastChargedMonth, 8)
        XCTAssertEqual(bill.lastChargedYear, 2026)
    }

    func testDueDateThatPassedWhilePausedIsSkipped() {
        let bill = RecurringExpense(label: "Netflix", amount: 186_000, dayOfMonth: 10)
        bill.markCaughtUp(now: date(2026, 9, 14))
        XCTAssertEqual(bill.lastChargedMonth, 9)
        XCTAssertEqual(bill.lastChargedYear, 2026)
    }

    func testDueTodayIsStillCharged() {
        let bill = RecurringExpense(label: "Netflix", amount: 186_000, dayOfMonth: 14)
        bill.markCaughtUp(now: date(2026, 9, 14))
        XCTAssertEqual(bill.lastChargedMonth, 8)
    }

    func testJanuaryWrapsToDecemberOfThePreviousYear() {
        let bill = RecurringExpense(label: "Kos", amount: 1_500_000, dayOfMonth: 25)
        bill.markCaughtUp(now: date(2027, 1, 5))
        XCTAssertEqual(bill.lastChargedMonth, 12)
        XCTAssertEqual(bill.lastChargedYear, 2026)
    }

    /// Resuming after this month was already charged must not re-open it.
    func testTheStampNeverMovesBackwards() {
        let bill = RecurringExpense(label: "Kos", amount: 1_500_000, dayOfMonth: 20)
        bill.lastChargedMonth = 9
        bill.lastChargedYear = 2026
        bill.markCaughtUp(now: date(2026, 9, 14))
        XCTAssertEqual(bill.lastChargedMonth, 9)
    }
}
