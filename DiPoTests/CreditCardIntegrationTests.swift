import XCTest
import SwiftData
@testable import DiPo

// Integration, not unit: everything here runs through a real SwiftData
// container, so relationships, cascade rules and the helper extensions are
// exercised together rather than in isolation.
//
// The defects this covers were all ones that unit tests would have missed,
// because each lived in the seam between two parts — a card and its
// instalments, a transaction and the balance it moves.
@MainActor
final class CreditCardIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema([
            BankCard.self, TxRecord.self, SalarySchedule.self,
            DebtRecord.self, SavingsGoal.self, RecurringExpense.self,
            Receivable.self, CardInstallment.self,
            CardBudgetConfig.self, CycleIntent.self
        ])
        // In memory: a test must not touch the real store, and must start from
        // nothing every time.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    // MARK: Helpers

    @discardableResult
    private func makeCreditCard(limit: Double, owed: Double) -> BankCard {
        let c = BankCard(holderName: "Tokopedia CC", cardNumber: "5221845086220969",
                         balance: 0, expireDate: "11/29",
                         gradientStart: "#000000", gradientEnd: "#111111",
                         sortOrder: 0, currency: "IDR")
        c.isCreditCard = true
        c.creditLimit = limit
        c.openingOwed = owed
        c.creditSince = .distantPast
        context.insert(c)
        return c
    }

    @discardableResult
    private func addInstallment(to card: BankCard, amount: Double, tenor: Int) -> CardInstallment {
        let i = CardInstallment(cardID: card.id, merchant: "Laptop",
                                totalAmount: amount, tenorMonths: tenor,
                                startDate: .now, flatRatePercent: 0, currency: "IDR")
        context.insert(i)
        return i
    }

    private func allInstallments() throws -> [CardInstallment] {
        try context.fetch(FetchDescriptor<CardInstallment>())
    }

    // MARK: The seam that was broken

    /// The Debt Tracker rendered the instalment list directly beneath a row
    /// that excluded those very instalments from what the card owed.
    func testInstalmentPrincipalCountsTowardWhatTheCardOwes() throws {
        let card = makeCreditCard(limit: 40_000_000, owed: 2_000_000)
        addInstallment(to: card, amount: 6_000_000, tenor: 12)
        try context.save()

        let inst = try allInstallments()
        XCTAssertEqual(inst.count, 1)
        XCTAssertEqual(card.owedBalance(), 2_000_000, accuracy: 1,
                       "logged transactions only — unchanged by instalments")
        XCTAssertEqual(card.totalOwed(inst), 8_000_000, accuracy: 1)
        XCTAssertEqual(card.availableCredit(inst), 32_000_000, accuracy: 1)
    }

    /// Two cards, one instalment: the other card must be untouched. This is
    /// the filter that a single-object unit test cannot prove.
    func testInstalmentsDoNotLeakBetweenCards() throws {
        let a = makeCreditCard(limit: 10_000_000, owed: 1_000_000)
        let b = makeCreditCard(limit: 10_000_000, owed: 1_000_000)
        addInstallment(to: a, amount: 5_000_000, tenor: 10)
        try context.save()

        let inst = try allInstallments()
        XCTAssertEqual(a.totalOwed(inst), 6_000_000, accuracy: 1)
        XCTAssertEqual(b.totalOwed(inst), 1_000_000, accuracy: 1,
                       "card B carries no instalment of its own")
    }

    /// Deleting an instalment has to return its locked principal to the limit.
    /// The edit/delete menu is new, so this is the first time that path runs.
    func testDeletingAnInstalmentReleasesItsLockedCredit() throws {
        let card = makeCreditCard(limit: 20_000_000, owed: 0)
        let inst = addInstallment(to: card, amount: 9_000_000, tenor: 9)
        try context.save()
        XCTAssertEqual(card.availableCredit(try allInstallments()), 11_000_000, accuracy: 1)

        context.delete(inst)
        try context.save()
        XCTAssertEqual(try allInstallments().count, 0)
        XCTAssertEqual(card.availableCredit(try allInstallments()), 20_000_000, accuracy: 1)
    }

    /// Editing in place rather than replacing: the id is referenced elsewhere,
    /// so a new object would orphan those references.
    func testEditingAnInstalmentKeepsItsIdentity() throws {
        let card = makeCreditCard(limit: 20_000_000, owed: 0)
        let inst = addInstallment(to: card, amount: 3_000_000, tenor: 3)
        try context.save()
        let originalID = inst.id

        inst.totalAmount = 6_000_000      // the typo being corrected
        inst.tenorMonths = 6
        try context.save()

        let fetched = try allInstallments()
        XCTAssertEqual(fetched.count, 1, "edit must not create a second row")
        XCTAssertEqual(fetched[0].id, originalID)
        XCTAssertEqual(card.totalOwed(fetched), 6_000_000, accuracy: 1)
    }

    /// A purchase logged on the card raises what is owed and shrinks the room
    /// left — the whole point of the flow that "Insufficient balance" blocked.
    func testLoggingAPurchaseMovesOwedAndAvailableTogether() throws {
        let card = makeCreditCard(limit: 10_000_000, owed: 0)
        try context.save()

        let tx = TxRecord(name: "koper dan tas", date: .now, amount: -2_286_300,
                          type: "Expense", icon: "bag.fill", iconBgHex: "#FF6B6B",
                          category: .shopping, currency: "IDR")
        card.transactions.append(tx)
        context.insert(tx)
        try context.save()

        let inst = try allInstallments()
        XCTAssertEqual(card.owedBalance(), 2_286_300, accuracy: 1)
        XCTAssertEqual(card.availableCredit(inst), 7_713_700, accuracy: 1)
        XCTAssertGreaterThan(card.availableCredit(inst), 0,
                             "a card with room left must never read as unaffordable")
    }

    /// Utilisation crosses the risk threshold only when instalments are
    /// counted — 20% blind versus 80% actual on the same card.
    func testUtilisationCrossesTheRiskThresholdOnlyWithInstalments() throws {
        let card = makeCreditCard(limit: 10_000_000, owed: 2_000_000)
        addInstallment(to: card, amount: 6_000_000, tenor: 12)
        try context.save()

        let inst = try allInstallments()
        XCTAssertLessThan(card.creditUtilization, 0.7, "the blind figure looks healthy")
        XCTAssertGreaterThan(card.utilisation(inst), 0.7, "the real one is not")
    }

    /// An inactive instalment stops locking credit without being deleted.
    func testInactiveInstalmentStopsLockingCredit() throws {
        let card = makeCreditCard(limit: 10_000_000, owed: 0)
        let inst = addInstallment(to: card, amount: 4_000_000, tenor: 8)
        try context.save()
        XCTAssertEqual(card.availableCredit(try allInstallments()), 6_000_000, accuracy: 1)

        inst.isActive = false
        try context.save()
        XCTAssertEqual(card.availableCredit(try allInstallments()), 10_000_000, accuracy: 1)
    }
}
