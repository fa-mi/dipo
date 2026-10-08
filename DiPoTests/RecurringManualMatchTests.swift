import XCTest
import SwiftData
@testable import DiPo

/// A bill that falls due when the same amount was already paid by hand is
/// asked about, never recorded twice and never silently skipped.
@MainActor
final class RecurringManualMatchTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private let cal = Calendar.current

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    // MARK: Helpers

    private func makeCard() -> BankCard {
        let c = BankCard(holderName: "BRI", cardNumber: "5221840000000969",
                         balance: 0, expireDate: "11/29",
                         gradientStart: "#000000", gradientEnd: "#111111",
                         sortOrder: 0, currency: "IDR")
        context.insert(c)
        return c
    }

    /// "transfer mom", Rp 1 jt on the 1st, charged up to last month — so this
    /// month's charge (the 1st has always arrived) is the one the engine posts.
    private func makePlan(on card: BankCard) -> RecurringExpense {
        let e = RecurringExpense(label: "transfer mom", amount: 1_000_000, dayOfMonth: 1,
                                 category: .commitment, currency: "IDR", cardID: card.id)
        e.createdAt = cal.date(byAdding: .month, value: -3, to: .now)!
        let last = cal.date(byAdding: .month, value: -1, to: .now)!
        e.lastChargedMonth = cal.component(.month, from: last)
        e.lastChargedYear = cal.component(.year, from: last)
        context.insert(e)
        return e
    }

    private var due: Date {
        RecurringDateEngine.dueDate(dayOfMonth: 1, month: cal.component(.month, from: .now),
                                    year: cal.component(.year, from: .now))
    }

    @discardableResult
    private func spend(_ name: String, _ amount: Double, _ category: TxCategory, on card: BankCard,
                       daysBeforeDue: Int) -> TxRecord {
        let date = cal.date(byAdding: .hour, value: 12,
                            to: cal.date(byAdding: .day, value: -daysBeforeDue, to: due)!)!
        let t = TxRecord(name: name, date: date, amount: amount, type: "tx.type.purchase", icon: "X",
                         iconBgHex: "#000000", category: category, currency: "IDR")
        context.insert(t)
        card.transactions.append(t)
        return t
    }

    private func autoCharges(_ card: BankCard) -> [TxRecord] {
        card.transactions.filter { $0.notes == "tx.note.recurring_auto" }
    }
    private var queue: [PendingTransaction] {
        (try? context.fetch(FetchDescriptor<PendingTransaction>())) ?? []
    }

    // MARK: Engine

    /// The real case: "tf ke ibuk" Rp 1 jt by hand on the 26th, the monthly
    /// "transfer mom" due on the 1st. Both turned out to be real — so DiPo
    /// asks instead of choosing.
    func testAHandEntryOfTheSameAmountHoldsTheBillForReview() throws {
        let card = makeCard()
        let plan = makePlan(on: card)
        let manual = spend("tf ke ibuk", -1_000_000, .other, on: card, daysBeforeDue: 5)
        try context.save()

        RecurringExpenseEngine.processIfNeeded(context: context)

        XCTAssertTrue(autoCharges(card).isEmpty, "not recorded while the question is open")
        XCTAssertEqual(queue.count, 1)
        let held = try XCTUnwrap(queue.first)
        XCTAssertEqual(held.source, .recurring)
        XCTAssertEqual(held.rawText, manual.id.uuidString)
        XCTAssertEqual(held.amount, -1_000_000, accuracy: 0.5)
        XCTAssertEqual(held.cardID, card.id)
        XCTAssertEqual(held.date, due)
        XCTAssertEqual(plan.lastChargedMonth, cal.component(.month, from: .now), "the month is settled")

        // Asked once: running again does not ask again.
        RecurringExpenseEngine.processIfNeeded(context: context)
        XCTAssertEqual(queue.count, 1)
    }

    /// "A separate payment": submitting records it as the bill's own charge.
    func testSubmittingAHeldBillRecordsItAsTheBillsCharge() throws {
        let card = makeCard()
        _ = makePlan(on: card)
        spend("tf ke ibuk", -1_000_000, .other, on: card, daysBeforeDue: 5)
        try context.save()
        RecurringExpenseEngine.processIfNeeded(context: context)

        let held = try XCTUnwrap(queue.first)
        XCTAssertTrue(PendingInbox.commit(held, cards: [card], context: context))
        let charges = autoCharges(card)
        XCTAssertEqual(charges.count, 1)
        XCTAssertEqual(charges.first?.name, "transfer mom")
        XCTAssertEqual(charges.first?.amount ?? 0, -1_000_000, accuracy: 0.5)
        XCTAssertTrue(queue.isEmpty)
    }

    /// A lunch of the same amount is not the bill: recorded as usual.
    func testADayToDayRowOfTheSameAmountDoesNotHold() throws {
        let card = makeCard()
        _ = makePlan(on: card)
        spend("Makan keluarga", -1_000_000, .food, on: card, daysBeforeDue: 2)
        try context.save()

        RecurringExpenseEngine.processIfNeeded(context: context)

        XCTAssertEqual(autoCharges(card).count, 1)
        XCTAssertTrue(queue.isEmpty)
    }

    func testADifferentAmountOrAnOldRowDoesNotHold() throws {
        let card = makeCard()
        _ = makePlan(on: card)
        spend("tf ke ibuk", -750_000, .other, on: card, daysBeforeDue: 3)     // another amount
        spend("tf ke ibuk", -1_000_000, .other, on: card, daysBeforeDue: 40)  // last month's
        try context.save()

        RecurringExpenseEngine.processIfNeeded(context: context)

        XCTAssertEqual(autoCharges(card).count, 1)
        XCTAssertTrue(queue.isEmpty)
    }

    func testTheHoldNoteNamesTheMatchedRow() throws {
        let card = makeCard()
        _ = makePlan(on: card)
        spend("tf ke ibuk", -1_000_000, .other, on: card, daysBeforeDue: 5)
        try context.save()
        RecurringExpenseEngine.processIfNeeded(context: context)

        let held = try XCTUnwrap(queue.first)
        XCTAssertTrue(RecurringManualMatch.holdNote(for: held, context: context).contains("tf ke ibuk"))
    }

    // MARK: Rules

    func testWindowStartsAWeekEarlyButNeverAtTheLastCharge() {
        let due = cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let monthStart = due
        let start = RecurringManualMatch.windowStart(due: due, periodStart: monthStart, previousCharge: nil)
        XCTAssertEqual(start, cal.date(byAdding: .day, value: -7, to: due))

        let payPeriod = cal.date(from: DateComponents(year: 2026, month: 9, day: 25))!
        XCTAssertEqual(RecurringManualMatch.windowStart(due: due, periodStart: payPeriod, previousCharge: nil),
                       payPeriod, "the pay period opened earlier still")

        let lastCharge = cal.date(from: DateComponents(year: 2026, month: 9, day: 28))!
        XCTAssertGreaterThan(RecurringManualMatch.windowStart(due: due, periodStart: payPeriod,
                                                              previousCharge: lastCharge), lastCharge)
    }

    func testCategoryOrSharedWordDecidesWhetherARowCouldBeTheBill() {
        func row(_ name: String, _ c: TxCategory) -> TxRecord {
            let t = TxRecord(name: name, date: .now, amount: -55_000, type: "tx.type.purchase", icon: "X",
                             iconBgHex: "#000000", category: c, currency: "IDR")
            context.insert(t)
            return t
        }
        XCTAssertTrue(RecurringManualMatch.couldBe(row("tf ke ibuk", .other), planLabel: "transfer mom",
                                                   planCategory: .commitment))
        XCTAssertTrue(RecurringManualMatch.couldBe(row("Kos Oktober", .bills), planLabel: "kos",
                                                   planCategory: .bills))
        XCTAssertTrue(RecurringManualMatch.couldBe(row("parkir", .transport), planLabel: "parkir motor kantor",
                                                   planCategory: .bills), "shares a word")
        XCTAssertFalse(RecurringManualMatch.couldBe(row("Makan siang", .food), planLabel: "parkir motor kantor",
                                                    planCategory: .bills))
    }

    /// The after-the-fact check now uses the same rule, so the pair that
    /// prompted this — "Other" by hand, "Commitment" recorded — is found.
    func testDuplicateReviewFindsAnOtherCategoryTwin() {
        let mom = RecurringExpense(label: "transfer mom", amount: 1_000_000, dayOfMonth: 1, currency: "IDR")
        func row(_ name: String, _ day: Date, _ c: TxCategory, notes: String = "") -> TxRecord {
            let t = TxRecord(name: name, date: day, amount: -1_000_000, type: "tx.type.purchase", icon: "X",
                             iconBgHex: "#000000", category: c, currency: "IDR", notes: notes)
            context.insert(t)
            return t
        }
        let d = { (m: Int, day: Int) in self.cal.date(from: DateComponents(year: 2026, month: m, day: day, hour: 12))! }
        let recorded = row("transfer mom", d(10, 1), .commitment, notes: "tx.note.recurring_auto")
        let manual = row("tf ke ibuk", d(9, 26), .other)
        let pairs = RecurringDuplicates.find(transactions: [recorded, manual], recurrings: [mom], payDay: 25,
                                             salaryDates: [d(8, 25), d(9, 25)], currency: "IDR")
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.twin.id, manual.id)
    }
}
