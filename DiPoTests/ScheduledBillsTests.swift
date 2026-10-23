import XCTest
import SwiftData
@testable import DiPo

/// Smart Budget takes monthly expenses still to come out of what each group
/// has left. Fahmi on payday, 23 Oct 2026: Needs read "Rp 0 spent" and Rp
/// 196.970 a day for 33 days, with kos, the transfer home and subscriptions —
/// Rp 3,9 jt — due before the salary of 25 Nov.
@MainActor
final class ScheduledBillsTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private let cal = Calendar.current

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func day(_ m: Int, _ d: Int, hour: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: hour))!
    }

    /// Payday Friday 23 Oct (the 25th is a Sunday) to the next one, 25 Nov.
    private var periodStart: Date { day(10, 23) }
    private var periodEnd: Date { day(11, 25) }

    private func bank(_ name: String) -> BankCard {
        let c = BankCard(holderName: name, cardNumber: "4111111111111111", balance: 0, expireDate: "11/29",
                         gradientStart: "#000000", gradientEnd: "#111111", sortOrder: 0, currency: "IDR")
        context.insert(c)
        return c
    }

    @discardableResult
    private func plan(_ label: String, _ amount: Double, day dayOfMonth: Int, _ category: TxCategory,
                      on card: BankCard, charged month: Int = 9, currency: String = "IDR",
                      autoRecord: Bool = true) -> RecurringExpense {
        let e = RecurringExpense(label: label, amount: amount, dayOfMonth: dayOfMonth, category: category,
                                 currency: currency, cardID: card.id)
        e.createdAt = day(6, 1)
        e.lastChargedMonth = month
        e.lastChargedYear = 2026
        e.autoRecord = autoRecord
        context.insert(e)
        return e
    }

    private func spend(_ amount: Double, _ name: String, _ category: TxCategory, on card: BankCard, at date: Date) {
        let t = TxRecord(name: name, date: date, amount: -amount, type: "tx.type.purchase", icon: "X",
                         iconBgHex: category.iconBg, category: category, currency: "IDR")
        context.insert(t)
        card.transactions.append(t)
    }

    private func upcoming(_ plans: [RecurringExpense], cards: [BankCard], now: Date) -> [ScheduledBill] {
        ScheduledBills.upcoming(plans: plans, cards: cards, cardIDs: [cards[0].id.uuidString],
                                periodStart: periodStart, periodEnd: periodEnd, currency: "IDR", now: now)
    }

    // MARK: What is still to come

    func testEveryBillDueBeforePaydayIsListedOnceInDateOrder() {
        let bri = bank("BRI")
        let plans = [
            plan("kos", 2_100_000, day: 8, .bills, on: bri, charged: 10),
            plan("transfer mom", 1_000_000, day: 1, .commitment, on: bri, charged: 10),
            plan("parkir motor kantor", 55_000, day: 25, .bills, on: bri),
            plan("Gold invest", 200_000, day: 28, .commitment, on: bri),
            plan("claude ai", 25, day: 4, .commitment, on: bri, charged: 10, currency: "USD"),
            plan("Netlify", 10, day: 13, .bills, on: bri, currency: "USD"),
        ]
        let bills = upcoming(plans, cards: [bri], now: day(10, 23, hour: 8))
        XCTAssertEqual(bills.map(\.label),
                       ["parkir motor kantor", "Gold invest", "transfer mom", "claude ai", "kos", "Netlify"])
        XCTAssertEqual(bills.map { cal.component(.day, from: $0.due) }, [25, 28, 1, 4, 8, 13])

        let usd = CurrencyManager.shared.convert(35, from: "USD", to: "IDR")
        XCTAssertEqual(ScheduledBills.total(bills, in: .daily), 3_355_000 + usd, accuracy: 1)
        XCTAssertEqual(ScheduledBills.total(bills, in: .investDebt), 0, "Gold invest is filed under Commitment")
        let netlify = bills.last!
        XCTAssertEqual(netlify.planAmount, 10)
        XCTAssertEqual(netlify.planCurrency, "USD")
    }

    /// A pay period longer than a month meets a bill on the 24th twice; one
    /// already recorded today is not due again.
    func testABillCanFallTwiceInOnePeriod() {
        let bri = bank("BRI")
        let twice = plan("Iuran", 100_000, day: 24, .commitment, on: bri)
        let today = plan("Pulsa", 50_000, day: 23, .bills, on: bri, charged: 10)
        let bills = upcoming([twice, today], cards: [bri], now: day(10, 23, hour: 8))
        XCTAssertEqual(bills.filter { $0.label == "Iuran" }.count, 2)
        XCTAssertEqual(bills.filter { $0.label == "Pulsa" }.map { cal.component(.month, from: $0.due) }, [11])
    }

    /// Kos paid by hand on the 5th is spent, not due on the 8th as well — and
    /// that one payment covers one bill, not both bills of the same amount.
    func testABillPaidByHandIsNotDueAgain() {
        let bri = bank("BRI")
        let kos = plan("kos", 2_100_000, day: 8, .bills, on: bri, charged: 10)
        let motor = plan("cicilan motor", 2_100_000, day: 10, .commitment, on: bri, charged: 10)
        spend(2_100_000, "Bayar kos", .bills, on: bri, at: day(11, 5, hour: 9))
        let bills = upcoming([kos, motor], cards: [bri], now: day(11, 6, hour: 9))
        XCTAssertEqual(bills.map(\.label), ["cicilan motor"])
    }

    /// Only the budget's own cards, only active plans. A plan that records
    /// nothing is due until it is paid.
    func testOnlyActivePlansOnTheBudgetsCards() {
        let bri = bank("BRI")
        let bca = bank("BCA")
        let elsewhere = plan("kos", 2_100_000, day: 8, .bills, on: bca, charged: 10)
        let paused = plan("gym", 300_000, day: 2, .health, on: bri)
        paused.isActive = false
        let manual = plan("arisan", 500_000, day: 5, .commitment, on: bri, charged: 11, autoRecord: false)
        let bills = upcoming([elsewhere, paused, manual], cards: [bri, bca], now: day(10, 23, hour: 8))
        XCTAssertEqual(bills.map(\.label), ["arisan"], "the stamp means nothing when nothing is recorded")
    }

    func testNothingIsDueOncePaydayHasCome() {
        let bri = bank("BRI")
        let kos = plan("kos", 2_100_000, day: 8, .bills, on: bri, charged: 10)
        XCTAssertTrue(upcoming([kos], cards: [bri], now: day(11, 25, hour: 8)).isEmpty)
    }

    // MARK: Filed where it counts as spending

    func testAPlanThatReadsLikeAnInvestmentIsOffered() {
        let bri = bank("BRI")
        let gold = plan("Gold invest", 200_000, day: 28, .commitment, on: bri)
        let emas = plan("Tabungan emas", 300_000, day: 2, .other, on: bri)
        let gym = plan("Gold's Gym", 400_000, day: 3, .health, on: bri)
        let box = plan("Kemasan toko", 150_000, day: 4, .bills, on: bri)
        let filed = plan("Reksadana", 500_000, day: 5, .investment, on: bri)
        let found = ScheduledBills.looksLikeInvestment([gold, emas, gym, box, filed],
                                                        cardIDs: [bri.id.uuidString])
        XCTAssertEqual(found.map(\.label), ["Gold invest", "Tabungan emas"])
    }

    // MARK: The purchase warning

    /// Paying the kos by hand early is the kos, not a purchase on top of it.
    func testAnEntryThatIsABillPaidEarlyIsNotCountedTwice() {
        let bri = bank("BRI")
        let bills = upcoming([plan("kos", 2_100_000, day: 8, .bills, on: bri, charged: 10),
                              plan("transfer mom", 1_000_000, day: 1, .commitment, on: bri, charged: 10)],
                             cards: [bri], now: day(10, 23, hour: 8))
        let paidKos = ScheduledBills.removingEntry(from: bills, amount: 2_100_000, name: "Bayar kos",
                                                   category: .bills, currency: "IDR")
        XCTAssertEqual(paidKos.map(\.label), ["transfer mom"])
        let groceries = ScheduledBills.removingEntry(from: bills, amount: 2_100_000, name: "Belanja bulanan",
                                                     category: .food, currency: "IDR")
        XCTAssertEqual(groceries.count, 2, "groceries of the same amount are not the kos")
    }

    // MARK: Days left, said with the last day

    func testThePeriodFromPaydayIsThirtyThreeDaysEndingTheTwentyFourth() {
        XCTAssertEqual(StatPeriod.daysLeft(in: (periodStart, periodEnd), now: day(10, 23, hour: 8)), 33)
        LanguageManager.shared.withLanguage(.indonesian) {
            let last = StatPeriod.lastDayLabel(before: periodEnd)
            XCTAssertEqual(last, "24 Nov")
            XCTAssertEqual(String(format: loc("budget.pace_hint"), "Rp 77.697", 33, last),
                           "Kamu bisa pakai Rp 77.697 per hari selama 33 hari, dari hari ini sampai 24 Nov.")
        }
    }
}
