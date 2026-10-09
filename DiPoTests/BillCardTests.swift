import XCTest
import SwiftData
@testable import DiPo

/// Cards the main card pays bills from, read with it as one pot: kos paid
/// from BCA with money moved over from BRI.
@MainActor
final class BillCardTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var savedMain: String?
    private var savedBills: [String] = []

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        savedMain = MainCard.id
        savedBills = SmartBudgetManager.shared.billCardIDs
        MainCard.id = nil
        SmartBudgetManager.shared.billCardIDs = []
    }

    override func tearDown() {
        MainCard.id = savedMain
        SmartBudgetManager.shared.billCardIDs = savedBills
        super.tearDown()
    }

    private func card(_ name: String, credit: Bool = false) -> BankCard {
        let c = BankCard(holderName: name, cardNumber: "5221845086220969", balance: 0,
                         expireDate: "11/29", gradientStart: "#000000", gradientEnd: "#111111",
                         sortOrder: 0, currency: "IDR")
        c.isCreditCard = credit
        context.insert(c)
        return c
    }

    private func tx(_ name: String, _ amount: Double, _ cat: TxCategory = .food,
                    subtype: TxSubtype = .normal, icon: String = "X", daysAgo: Double = 1) -> TxRecord {
        let t = TxRecord(name: name, date: .now.addingTimeInterval(-daysAgo * 86_400), amount: amount,
                         type: amount < 0 ? "tx.type.purchase" : "tx.type.income", icon: icon,
                         iconBgHex: cat.iconBg, category: cat, currency: "IDR", subtype: subtype)
        context.insert(t)
        return t
    }

    func testOnlyOtherDebitCardsCanBeBillCards() {
        let bri = card("BRI"), bca = card("BCA"), cc = card("CC", credit: true)
        MainCard.set(bri)
        MainCard.setBillCard(bca, true)
        MainCard.setBillCard(cc, true)
        MainCard.setBillCard(bri, true)
        let all = [bri, bca, cc]
        XCTAssertEqual(MainCard.billCards(in: all).map(\.id), [bca.id],
                       "a credit card reaches the budget through its bill; the main card is already in")
        XCTAssertEqual(MainCard.budgetCards(in: all).map(\.id), [bri.id, bca.id])
        XCTAssertTrue(MainCard.isBillCard(bca))

        MainCard.setBillCard(bca, false)
        XCTAssertEqual(MainCard.budgetCards(in: all).map(\.id), [bri.id], "just the main card, as before")
    }

    func testNoMainCardMeansNoPot() {
        let bri = card("BRI"), bca = card("BCA")
        SmartBudgetManager.shared.billCardIDs = [bca.id.uuidString]
        XCTAssertTrue(MainCard.billCards(in: [bri, bca]).isEmpty)
        XCTAssertNil(MainCard.potTransactions(in: [bri, bca]), "callers fall back to every card")
    }

    func testReconcileDropsBillCardsThatNoLongerFit() {
        let bri = card("BRI"), bca = card("BCA"), bni = card("BNI")
        MainCard.set(bri)
        MainCard.setBillCard(bca, true)
        MainCard.setBillCard(bni, true)

        MainCard.reconcile(cards: [bri, bca])
        XCTAssertEqual(SmartBudgetManager.shared.billCardIDs, [bca.id.uuidString], "a deleted card drops out")

        MainCard.set(bca)
        MainCard.reconcile(cards: [bri, bca])
        XCTAssertEqual(SmartBudgetManager.shared.billCardIDs, [], "the new main card is not its own bill card")
    }

    /// Salary on BRI, Rp 2.500.000 moved to BCA, kos Rp 2.100.000 paid from BCA.
    /// The kos is spending; the move is not; the Rp 400.000 moved over and not
    /// spent is still the person's money.
    func testSpendingOnABillCardCountsAndMovesBetweenThemDoNot() {
        let bri = card("BRI"), bca = card("BCA")
        bri.transactions = [tx("Gaji", 10_000_000, .salary),
                            tx("To BCA", -2_500_000, .other, subtype: .transfer, icon: "⇄"),
                            tx("Makan", -100_000, .food)]
        bca.transactions = [tx("From BRI", 2_500_000, .other, subtype: .transfer, icon: "⇄"),
                            tx("Kos", -2_100_000, .commitment)]
        MainCard.set(bri)
        MainCard.setBillCard(bca, true)

        let pot = MainCard.budgetTransactions(in: [bri, bca])
        let same: (TxRecord) -> Double = { $0.amount }
        XCTAssertEqual(StatisticsView.income(pot, convert: same), 10_000_000)
        XCTAssertEqual(StatisticsView.expenses(pot, convert: same), 2_200_000)
        XCTAssertEqual(SmartBudgetManager.shared.spent(in: .daily, transactions: pot, targetCurrency: "IDR",
                                                       periodStart: .distantPast),
                       2_200_000, accuracy: 0.5, "kos is a daily need of the main card's budget")

        let book = PeriodCashBook.build(pot, start: 0, convert: same)
        XCTAssertEqual(book.ownMoves, 0, "both legs are inside the pot")
        XCTAssertEqual(book.end, 7_800_000, "Rp 400.000 still on BCA is counted")

        // Without the bill card the kos is in no budget at all.
        MainCard.setBillCard(bca, false)
        XCTAssertEqual(StatisticsView.expenses(MainCard.budgetTransactions(in: [bri, bca]), convert: same),
                       100_000)
    }

    func testABillOnABillCardIsProjectedAndCommitted() {
        let bri = card("BRI"), bca = card("BCA")
        let kos = RecurringExpense(label: "Kos", amount: 2_100_000, dayOfMonth: 28,
                                   category: .commitment, currency: "IDR", cardID: bca.id)
        context.insert(kos)
        let end = Date.now.addingTimeInterval(40 * 86_400)
        XCTAssertEqual(StatisticsView.upcomingFixed(recurrings: [kos], cardIDs: [bri.id],
                                                    periodEnd: end, currency: "IDR"), 0)
        XCTAssertEqual(StatisticsView.upcomingFixed(recurrings: [kos], cardIDs: [bri.id, bca.id],
                                                    periodEnd: end, currency: "IDR"), 2_100_000)

        MainCard.set(bri)
        let pay = SalarySchedule(label: "Gaji", amount: 10_000_000, dayOfMonth: 25,
                                 currency: "IDR", cardID: bri.id)
        context.insert(pay)
        let alone = StatisticsView.dailyAllowance(cycleDays: 30, salarySchedules: [pay], recurringPlans: [kos],
                                                  mainCardID: bri.id, currency: "IDR")
        let withBills = StatisticsView.dailyAllowance(cycleDays: 30, salarySchedules: [pay], recurringPlans: [kos],
                                                      mainCardID: bri.id, billCardIDs: [bca.id], currency: "IDR")
        XCTAssertEqual(alone ?? 0, 10_000_000 / 30, accuracy: 0.5)
        XCTAssertEqual(withBills ?? 0, 7_900_000 / 30, accuracy: 0.5)
    }

    func testRollupBucketsCanBeReadOverSeveralCards() {
        let day = Calendar.current.startOfDay(for: .now)
        let facts = [TxFact(date: day, amount: -100, currency: "IDR", category: "Food & Drinks",
                            subtype: "normal", cardID: "A"),
                     TxFact(date: day, amount: -200, currency: "IDR", category: "Food & Drinks",
                            subtype: "normal", cardID: "B"),
                     TxFact(date: day, amount: -400, currency: "IDR", category: "Food & Drinks",
                            subtype: "normal", cardID: "C")]
        let buckets = RollupEngine.daily(from: facts)
        let window = RollupEngine.buckets(buckets, cardIDs: ["A", "B"], from: .distantPast)
        let totals = RollupEngine.totals(for: window, targetCurrency: "IDR", convert: { v, _, _ in v })
        XCTAssertEqual(totals.expenses, 300)
    }

    /// An edit keeps the transaction count, which is all the rollup used to
    /// look at — so a row made a loan stayed spending on Home until relaunch.
    func testRefreshPicksUpAnInPlaceEdit() throws {
        let bri = card("BRI")
        let loan = tx("hutang ke ibuk", -5_000_000, .commitment)
        bri.transactions = [tx("Makan", -100_000), loan]
        try context.save()
        let store = RollupStore.shared
        store.rebuild(context: context)

        loan.txSubtype = .transfer
        try context.save()
        store.refresh(loan, context: context)
        let edited = RollupEngine.totals(for: RollupEngine.buckets(store.buckets, cardID: bri.id.uuidString,
                                                                   from: .distantPast),
                                         targetCurrency: "IDR", convert: { v, _, _ in v })
        XCTAssertEqual(edited.expenses, 100_000)
        XCTAssertEqual(store.buckets.sorted { $0.dayStart < $1.dayStart },
                       store.rebuild(context: context).sorted { $0.dayStart < $1.dayStart })
    }

    func testBackupsCarryBillCardsAndOldOnesStillOpen() throws {
        let now = BackupSmartBudgetSettings(isEnabled: true, dailyRatio: 0.65, lifestyleRatio: 0.2,
                                            investDebtRatio: 0.15, budgetCardID: "BRI",
                                            billCardIDs: ["BCA"], extraFundTxIDs: ["T1"])
        let back = try JSONDecoder().decode(BackupSmartBudgetSettings.self, from: JSONEncoder().encode(now))
        XCTAssertEqual(back.billCardIDs, ["BCA"])
        XCTAssertEqual(back.extraFundTxIDs, ["T1"])

        let old = #"{"isEnabled":true,"dailyRatio":0.5,"lifestyleRatio":0.3,"investDebtRatio":0.2,"budgetCardID":"BRI"}"#
        let legacy = try JSONDecoder().decode(BackupSmartBudgetSettings.self, from: Data(old.utf8))
        XCTAssertNil(legacy.billCardIDs)
        XCTAssertNil(legacy.extraFundTxIDs)
    }

    func testStringsExist() {
        for key in ["budget.bill_cards_title", "budget.bill_cards_hint", "budget.bill_outside",
                    "budget.bill_outside_add", "stats.with_bill_cards"] {
            XCTAssertNotEqual(loc(key), key, "missing \(key)")
        }
    }
}
