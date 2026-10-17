import XCTest
import SwiftData
@testable import DiPo

/// The Debts screen and the Financial ladder describe the same money, so they
/// have to agree — or say why they differ.
///
/// Fahmi's phone on 13 Oct: Debts read "Total you owe Rp 8.500.000" while the
/// ladder read "Credit card: Rp 8.000.000 still owed". Both were right: the
/// other Rp 500.000 was this month's shopping, not yet due, which the ladder
/// leaves out of what is carried (and charged interest). Nothing said so. And
/// the ladder's "You spend Rp 2.085.800 a month more than you earn" counted
/// the salary but not the Rp 1 jt of side income that came every month.
@MainActor
final class DebtFiguresAgreeTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func card(credit: Bool, owed: Double = 0) -> BankCard {
        let c = BankCard(holderName: credit ? "Tokopedia CC" : "BRI", cardNumber: "5221845086220969",
                         balance: 0, expireDate: "11/29", gradientStart: "#000000", gradientEnd: "#111111",
                         sortOrder: 0, currency: "IDR")
        c.isCreditCard = credit
        c.openingOwed = owed
        c.creditSince = credit ? .distantPast : nil
        context.insert(c)
        return c
    }

    @discardableResult
    private func tx(on card: BankCard, _ amount: Double, _ category: TxCategory, at date: Date = .now) -> TxRecord {
        let t = TxRecord(name: "x", date: date, amount: amount, type: amount < 0 ? "tx.type.purchase" : "tx.type.income",
                         icon: "X", iconBgHex: category.iconBg, category: category, currency: "IDR")
        context.insert(t)
        card.transactions.append(t)
        return t
    }

    private func english<T>(_ body: () -> T) -> T { LanguageManager.shared.withLanguage(.english, body) }

    // MARK: The credit card

    /// Rp 8 jt from earlier bills plus Rp 500 rb bought this month.
    private func fahmisCard() -> BankCard {
        let c = card(credit: true, owed: 8_000_000)
        tx(on: c, -500_000, .shopping)
        return c
    }

    func testBothScreensReadTheCardFromTheSameRule() {
        let c = fahmisCard()
        XCTAssertEqual(c.totalOwed([]), 8_500_000, "Debts: total you owe")
        XCTAssertEqual(ObligationLoad.cardCarried(cards: [c], currency: "IDR"), 8_000_000, "carried, charged interest")
        XCTAssertEqual(ObligationLoad.cardPayments(cards: [c], installments: [], debts: [], currency: "IDR"),
                       400_000, accuracy: 0.5, "Debts: pay each month — 5% of what is carried")

        let ladder = LadderInputs.gather(cards: [c], debts: [], holdings: [], goals: [], salaries: [],
                                         currency: "IDR", installments: [])
        XCTAssertEqual(ladder.costlyDebt?.balance, 8_000_000)
        XCTAssertEqual(ladder.costlyDebt?.owedInTotal, 8_500_000, "the ladder shows the Debts total beside it")
    }

    func testTheLadderSaysWhichPartIsCarried() {
        let c = fahmisCard()
        let r = FinancialLadder.evaluate(.gather(cards: [c], debts: [], holdings: [], goals: [], salaries: [],
                                                 currency: "IDR", installments: []))
        let line = english { LadderCopy.detail(.debt, r, currency: "IDR") }
        XCTAssertTrue(line.contains("8.000.000") && line.contains("8.500.000"), line)
        XCTAssertTrue(line.contains("carried over"), line)
        XCTAssertFalse(line.contains("still owed"), "the old wording read as the whole debt: \(line)")
    }

    func testWhenEverythingIsCarriedTheLadderNamesOneFigure() {
        let c = card(credit: true, owed: 8_000_000)
        let r = FinancialLadder.evaluate(.gather(cards: [c], debts: [], holdings: [], goals: [], salaries: [],
                                                 currency: "IDR", installments: []))
        XCTAssertEqual(r.inputs.costlyDebt?.owedInTotal, 0, "nothing new on the card, so no second figure")
        let line = english { LadderCopy.detail(.debt, r, currency: "IDR") }
        XCTAssertTrue(line.contains("8.000.000") && !line.contains(" of "), line)
    }

    func testSmartBudgetsAdviceNamesTheCarriedPartToo() {
        var e = FinancialHealthEngine(monthlyIncome: 10_100_000, debts: [])
        e.cardOwed = 8_500_000
        e.cardCarried = 8_000_000
        XCTAssertEqual(e.debtFirst.target, .card(carried: 8_000_000))
        let advice = english { e.debtFirst.body(currency: "IDR") }
        XCTAssertTrue(advice.contains("8.000.000"), advice)
        XCTAssertEqual(e.totalDebt, 8_500_000)

        // Only new shopping on the card: nothing is charged interest yet.
        e.cardCarried = 0
        XCTAssertNil(e.debtFirst.target)
        XCTAssertTrue(e.debtFirst.cardRecentOnly)
        let recent = english { e.debtFirst.body(currency: "IDR") }
        XCTAssertTrue(recent.hasSuffix(english { loc("debt.first.card_recent") }), recent)
    }

    func testOnlyNewShoppingIsNotCostlyDebt() {
        let c = card(credit: true)
        tx(on: c, -750_000, .food)
        let i = LadderInputs.gather(cards: [c], debts: [], holdings: [], goals: [], salaries: [],
                                    currency: "IDR", installments: [])
        XCTAssertNil(i.costlyDebt)
    }

    // MARK: Income

    func testRegularSideIncomeCountsAndABonusDoesNot() {
        let bank = card(credit: false)
        let salary = SalarySchedule(label: "Gaji", amount: 10_100_000, dayOfMonth: 25, currency: "IDR", cardID: bank.id)
        context.insert(salary)
        let cal = Calendar.current
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: .now))!
        func day(_ monthsBack: Int, _ d: Int = 10) -> Date {
            cal.date(byAdding: .day, value: d - 1, to: cal.date(byAdding: .month, value: -monthsBack, to: thisMonth)!)!
        }
        tx(on: bank, -50_000, .food, at: day(4))                     // logging began four months ago
        for back in 1...3 { tx(on: bank, 1_000_000, .incomeOther, at: day(back)) }   // every month
        tx(on: bank, 12_850_000, .bonus, at: day(2))                  // once
        tx(on: bank, 1_800_000, .investment, at: day(2))              // sold gold: not earning

        let i = LadderInputs.gather(cards: [bank], debts: [], holdings: [], goals: [], salaries: [salary],
                                    currency: "IDR", installments: [])
        XCTAssertEqual(i.monthlyIncome, 11_100_000, accuracy: 0.5)
    }

    func testNoSideIncomeLeavesTheSalaryAlone() {
        let bank = card(credit: false)
        let salary = SalarySchedule(label: "Gaji", amount: 4_000_000, dayOfMonth: 25, currency: "IDR", cardID: bank.id)
        context.insert(salary)
        tx(on: bank, -50_000, .food)
        let i = LadderInputs.gather(cards: [bank], debts: [], holdings: [], goals: [], salaries: [salary],
                                    currency: "IDR", installments: [])
        XCTAssertEqual(i.monthlyIncome, 4_000_000, accuracy: 0.5)
    }

    // MARK: Words

    func testTheStringsExistInBothLanguages() {
        let keys = ["ladder.debt.card_carried", "ladder.debt.card_part", "debt.first.why_card",
                    "debt.first.card_recent", "debt.verdict_dti", "debt.afford.heavy_body"]
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in keys { XCTAssertNotEqual(loc(key), key, "missing \(key) in \(language)") }
                let part = String(format: loc("ladder.debt.card_part"), "Kartu", "Rp 8.000.000", "Rp 8.500.000")
                XCTAssertTrue(part.contains("Rp 8.000.000") && part.contains("Rp 8.500.000"), part)
            }
        }
    }
}
