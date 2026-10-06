import XCTest
import SwiftData
@testable import DiPo

/// How DiPo's heavy computations scale with history. Fills an in-memory store
/// with one, three and five years of a busy rural household's ledger and times
/// each computation a screen runs, printing one `PERF|…` line per figure so CI
/// logs carry the numbers. Nothing here fails on a time: this is the baseline
/// later changes are compared against, not a gate.
///
/// What a busy household logs: 6–10 entries a day across a bank account, an
/// e-wallet and a credit card — market, transport, top-ups, a monthly salary,
/// bills, the odd transfer and card payment.
@MainActor
final class PerformanceTests: XCTestCase {

    private struct Ledger {
        let container: ModelContainer
        let cards: [BankCard]
        let salaries: [SalarySchedule]
        let debts: [DebtRecord]
        let goals: [SavingsGoal]
        let receivables: [Receivable]
        let recurrings: [RecurringExpense]
        let installments: [CardInstallment]
        @MainActor var context: ModelContext { container.mainContext }
        @MainActor var count: Int { cards.reduce(0) { $0 + $1.transactions.count } }
    }

    private func card(_ name: String, _ number: String, credit: Bool = false, order: Int) -> BankCard {
        let c = BankCard(holderName: name, cardNumber: number, balance: credit ? 0 : 2_000_000,
                         expireDate: "11/29", gradientStart: "#000000", gradientEnd: "#111111",
                         sortOrder: order, currency: "IDR")
        if credit {
            c.isCreditCard = true
            c.creditLimit = 20_000_000
            c.openingOwed = 5_000_000
        }
        return c
    }

    private func ledger(years: Int, perDay: Int) throws -> Ledger {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        let container = try ModelContainer(for: schema,
                                           configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let ctx = container.mainContext
        let bank = card("Bank", "5221845086220969", order: 0)
        let wallet = card("E-wallet", "081200000000", order: 1)
        let cc = card("CC", "4111111111111111", credit: true, order: 2)
        for c in [bank, wallet, cc] { ctx.insert(c) }

        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let days = years * 365
        let spend: [TxCategory] = [.food, .food, .food, .transport, .shopping, .bills, .health, .other]
        var rng = SystemRandomNumberGenerator()
        // Built up in plain arrays and handed to each card once: appending to
        // a model's relationship one row at a time is quadratic, and seeding
        // five years that way took five minutes of every CI run.
        var ledgers: [ObjectIdentifier: [TxRecord]] = [:]
        func post(_ tx: TxRecord, to card: BankCard) { ledgers[ObjectIdentifier(card), default: []].append(tx) }
        for d in 0..<days {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            if cal.component(.day, from: day) == 25 {
                post(TxRecord(name: "Gaji", date: day.addingTimeInterval(3_600), amount: 4_000_000,
                                                  type: "tx.type.income", icon: "banknote", iconBgHex: TxCategory.salary.iconBg,
                                                  category: .salary, currency: "IDR"), to: bank)
                post(TxRecord(name: "Top up", date: day.addingTimeInterval(7_200), amount: -500_000,
                                                  type: "tx.type.purchase", icon: "arrow", iconBgHex: TxCategory.other.iconBg,
                                                  category: .other, currency: "IDR", subtype: .transfer), to: bank)
                post(TxRecord(name: "CC bill", date: day.addingTimeInterval(7_300), amount: -600_000,
                                                  type: "tx.type.purchase", icon: "CC", iconBgHex: TxCategory.other.iconBg,
                                                  category: .other, currency: "IDR", notes: "tx.note.cc_payment",
                                                  subtype: .transfer), to: bank)
            }
            for i in 0..<perDay {
                let cat = spend[Int.random(in: 0..<spend.count, using: &rng)]
                let target = i % 5 == 0 ? wallet : (i % 7 == 0 ? cc : bank)
                post(TxRecord(
                    name: "Belanja \(i)", date: day.addingTimeInterval(Double(9 + i) * 3_600),
                    amount: -Double(Int.random(in: 5...150, using: &rng) * 1_000),
                    type: "tx.type.purchase", icon: "cart", iconBgHex: cat.iconBg,
                    category: cat, currency: "IDR"), to: target)
            }
        }

        for c in [bank, wallet, cc] { c.transactions = ledgers[ObjectIdentifier(c)] ?? [] }

        let salary = SalarySchedule(label: "Gaji", amount: 4_000_000, dayOfMonth: 25, currency: "IDR", cardID: bank.id)
        let debt = DebtRecord(name: "KUR", type: "loan", totalAmount: 20_000_000, currentBalance: 12_000_000,
                              minimumPayment: 900_000, annualInterestRate: 6, dueDayOfMonth: 10, currency: "IDR")
        let goal = SavingsGoal(name: "Lebaran", targetAmount: 3_000_000, currency: "IDR")
        let lent = Receivable(personName: "Adik", amount: 500_000, currency: "IDR")
        let rent = RecurringExpense(label: "Kontrakan", amount: 800_000, dayOfMonth: 1, currency: "IDR", cardID: bank.id)
        let inst = CardInstallment(cardID: cc.id, merchant: "HP", totalAmount: 2_400_000, tenorMonths: 12,
                                   startDate: today, currency: "IDR")
        ctx.insert(salary); ctx.insert(debt); ctx.insert(goal)
        ctx.insert(lent); ctx.insert(rent); ctx.insert(inst)
        try ctx.save()
        return Ledger(container: container, cards: [bank, wallet, cc], salaries: [salary], debts: [debt],
                      goals: [goal], receivables: [lent], recurrings: [rent], installments: [inst])
    }

    /// Milliseconds for `body`, the best of `runs` (the least disturbed by the runner).
    @discardableResult
    private func time<T>(_ scenario: String, _ metric: String, runs: Int = 3, _ body: () -> T) -> T {
        var best = Double.infinity
        var result: T!
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            result = body()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        print(String(format: "PERF|%@|%@|%.1f ms", scenario, metric, best))
        return result
    }

    private func run(years: Int, perDay: Int) throws {
        let insertStart = DispatchTime.now().uptimeNanoseconds
        let l = try ledger(years: years, perDay: perDay)
        let scenario = "\(years)y-\(perDay)pd-\(l.count)tx"
        print(String(format: "PERF|%@|seed+save|%.0f ms", scenario,
                     Double(DispatchTime.now().uptimeNanoseconds - insertStart) / 1_000_000))

        // The pattern ~15 screens still use: every transaction into memory.
        let all = time(scenario, "flatMap all transactions") { l.cards.flatMap(\.transactions) }
        time(scenario, "sort all by date (recent list)") { all.sorted { $0.date > $1.date }.count }

        // Home
        time(scenario, "Home net worth: goals+receivables") {
            l.goals.reduce(0.0) { $0 + $1.netWorthContribution(from: all) }
                + l.receivables.reduce(0.0) { $0 + $1.netWorthContribution(from: all) }
        }
        time(scenario, "Home total balance") {
            BankCard.totalBalanceAcrossCards(l.cards, preferredCurrency: "IDR")
        }
        time(scenario, "Rollup rebuild (daily buckets)") { RollupStore.shared.rebuild(context: l.context).count }
        // The everyday case: one transaction added, the rollup brought up to date.
        time(scenario, "Rollup after one new transaction", runs: 1) {
            l.cards[0].transactions.append(TxRecord(name: "Kopi", date: .now, amount: -15_000,
                                                    type: "tx.type.purchase", icon: "cup",
                                                    iconBgHex: TxCategory.food.iconBg, category: .food,
                                                    currency: "IDR"))
            return RollupStore.shared.rebuildIfStale(context: l.context, txCount: l.count).count
        }

        // Plan
        time(scenario, "Financial ladder gather+evaluate") {
            FinancialLadder.evaluate(.gather(cards: l.cards, debts: l.debts, holdings: [], goals: l.goals,
                                             salaries: l.salaries, currency: "IDR"))
        }
        time(scenario, "Obligation load (debts + cards)") {
            ObligationLoad.build(debts: l.debts, recurrings: l.recurrings, salaries: l.salaries, configs: [],
                                 cards: l.cards, installments: l.installments)
        }

        // Smart Budget pots over the current cycle, the transaction path.
        let cycle = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
        time(scenario, "Smart Budget spent x3 (tx scan)") {
            BudgetGroup.allCases.reduce(0.0) {
                $0 + SmartBudgetManager.shared.spent(in: $1, transactions: all, targetCurrency: "IDR",
                                                     periodStart: cycle)
            }
        }

        // Search: opening it (everything), then a word typed.
        let idr = { (t: TxRecord) in t.amount }
        time(scenario, "Search open (all, newest)") {
            SearchEngine.run(l.cards.flatMap(\.transactions), query: "", range: nil, category: nil,
                             sort: .newest, limit: SearchView.pageSize, convert: idr).count
        }
        time(scenario, "Search typed 'gaji'") {
            SearchEngine.run(l.cards.flatMap(\.transactions), query: "gaji", range: nil, category: nil,
                             sort: .newest, limit: SearchView.pageSize, convert: idr).count
        }

        // Statistics
        let month = all.filter { $0.date >= cycle }
        time(scenario, "Statistics month filter") { all.filter { $0.date >= cycle }.count }
        time(scenario, "Statistics other money out") {
            NonFlowMovements.rows(month, incoming: false, amount: { $0.amount }).count
        }

        // Home's pace warning: Statistics' projection for the running cycle.
        time(scenario, "Home projection (rhythm + figures)") {
            StatisticsView.projectedCycleSpend(card: l.cards[0], payDay: 25, recurrings: l.recurrings,
                                               currency: "IDR") ?? 0
        }
        // Smart Budget's duplicate check over twelve pay periods.
        time(scenario, "Duplicate bills (12 periods)") {
            RecurringDuplicates.find(transactions: l.cards[0].transactions, recurrings: l.recurrings,
                                     payDay: 25, salaryDates: StatPeriod.salaryDates(on: l.cards[0]),
                                     currency: "IDR",
                                     since: Calendar.current.date(byAdding: .month, value: -12, to: .now)!).count
        }

        // A full-history scan done once at launch.
        time(scenario, "Card payment reclassify (once)", runs: 1) {
            UserDefaults.standard.removeObject(forKey: "cardPaymentDebt.reclassified.v1")
            CardPaymentDebt.reclassifyPastPayments(cards: l.cards, context: l.context)
        }
        UserDefaults.standard.removeObject(forKey: "cardPaymentDebt.reclassified.v1")

        XCTAssertGreaterThan(l.count, years * 365 * perDay)
    }

    func testOneYear() throws { try run(years: 1, perDay: 6) }
    func testThreeYears() throws { try run(years: 3, perDay: 6) }
    func testFiveYearsBusy() throws { try run(years: 5, perDay: 10) }
}
