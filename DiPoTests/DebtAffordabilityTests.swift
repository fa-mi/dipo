import XCTest
import SwiftData
@testable import DiPo

/// The Debts screen gives one verdict — can a usual month carry these
/// payments — and Smart Budget's one piece of advice: clear dear debt before
/// saving or investing.
///
/// Fahmi's screen on 17 Oct read "Debt: Very healthy · payments take 11% of
/// income" and, right under it, "This pay period you've spent Rp 1.175.718
/// more than planned", then a four-way split of the salary. How a pay period
/// is going is Statistics' question; it no longer reaches this screen.
@MainActor
final class DebtAffordabilityTests: XCTestCase {

    private func english<T>(_ body: () -> T) -> T { LanguageManager.shared.withLanguage(.english, body) }

    /// Fahmi's figures: Rp 10 jt income, Rp 1.129.167 a month in payments.
    private func reading(spending: Double, payments: Double = 1_129_167,
                         income: Double = 10_000_000) -> DebtAffordability {
        DebtAffordability(monthlyIncome: income, monthlySpending: spending, monthlyPayments: payments)
    }

    // MARK: The verdict

    func testAUsualMonthWithRoomToSpareIsSafe() {
        let r = reading(spending: 6_500_000)
        XCTAssertEqual(r.verdict, .safe)
        XCTAssertEqual(r.left, 2_370_833, accuracy: 0.5)
        let title = english { r.title() }
        XCTAssertEqual(title, "Safe · payments are 11% of your income")
        let detail = english { r.detail(currency: "IDR") } ?? ""
        XCTAssertTrue(detail.contains("6.500.000") && detail.contains("1.129.167")
                      && detail.contains("2.370.833") && detail.contains("10.000.000"), detail)
    }

    /// Under a tenth of income left: one surprise bill and a payment slips.
    func testAThinMarginIsTight() {
        let r = reading(spending: 8_400_000)
        XCTAssertEqual(r.verdict, .tight)
        XCTAssertTrue(r.marginIsThin)
        let detail = english { r.detail(currency: "IDR") } ?? ""
        XCTAssertTrue(detail.contains("470.833") && detail.contains("new debt"), detail)
        XCTAssertTrue(english { r.title() }.hasPrefix("Tight"))
    }

    func testExactlyATenthLeftIsNotThin() {
        XCTAssertEqual(reading(spending: 7_870_833).verdict, .safe)
        XCTAssertEqual(reading(spending: 7_870_834).verdict, .tight)
    }

    /// The month closes, but payments are past what any bank would lend on.
    func testPaymentsPastTheBanksLimitAreTightEvenWhenTheMonthCloses() {
        let r = reading(spending: 5_400_000, payments: 3_400_000)
        XCTAssertFalse(r.marginIsThin)
        XCTAssertTrue(r.pastLenderLimit)
        XCTAssertEqual(r.verdict, .tight)
        let detail = english { r.detail(currency: "IDR") } ?? ""
        XCTAssertTrue(detail.contains("30%") && detail.contains("1.200.000"), detail)
        XCTAssertEqual(english { r.title() }, "Tight · payments are 34% of your income")
    }

    /// Spending and payments together past income: the payments come out of
    /// savings or more borrowing.
    func testMoreGoingOutThanComingInIsTooHeavy() {
        let r = reading(spending: 9_500_000)
        XCTAssertEqual(r.verdict, .heavy)
        let detail = english { r.detail(currency: "IDR") } ?? ""
        XCTAssertTrue(detail.contains("629.167") && detail.contains("debt will grow"), detail)
    }

    func testOnlyNewShoppingOnACardAsksForNothingEachMonth() {
        let r = reading(spending: 4_000_000, payments: 0)
        XCTAssertEqual(r.verdict, .safe)
        let detail = english { r.detail(currency: "IDR") } ?? ""
        XCTAssertTrue(detail.contains("6.000.000") && !detail.contains("in debt each month"), detail)
        let over = reading(spending: 10_400_000, payments: 0)
        XCTAssertEqual(over.verdict, .heavy)
        XCTAssertTrue((english { over.detail(currency: "IDR") } ?? "").contains("400.000"))
    }

    func testWithoutAnIncomeThereIsNothingToWeighAgainst() {
        let r = reading(spending: 4_000_000, income: 0)
        XCTAssertNil(r.verdict)
        XCTAssertEqual(r.title(), loc("debt.afford.unknown"))
        XCTAssertEqual(r.detail(currency: "IDR"), loc("debt.afford.no_income"))
    }

    // MARK: From the user's records

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func records() -> (ModelContext, BankCard, SalarySchedule, Date) {
        let context = container.mainContext
        let bank = BankCard(holderName: "BRI", cardNumber: "5221845086220969", balance: 0, expireDate: "11/29",
                            gradientStart: "#000000", gradientEnd: "#111111", sortOrder: 0, currency: "IDR")
        context.insert(bank)
        let salary = SalarySchedule(label: "Gaji", amount: 10_000_000, dayOfMonth: 25, currency: "IDR", cardID: bank.id)
        context.insert(salary)
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!
        return (context, bank, salary, now)
    }

    private func spend(_ amount: Double, _ category: TxCategory, on card: BankCard, _ y: Int, _ m: Int, _ d: Int,
                       in context: ModelContext) {
        let date = Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
        let t = TxRecord(name: "x", date: date, amount: -amount, type: "tx.type.purchase", icon: "X",
                         iconBgHex: category.iconBg, category: category, currency: "IDR")
        context.insert(t)
        card.transactions.append(t)
    }

    /// A pay period running hot does not turn the verdict: it is read from
    /// the months that are over, and their middle one.
    func testThisPayPeriodDoesNotDecideTheVerdict() {
        let (context, bank, salary, now) = records()
        spend(50_000, .food, on: bank, 2026, 6, 5, in: context)           // logging began in June
        for month in 7...9 { spend(6_000_000, .food, on: bank, 2026, month, 10, in: context) }
        spend(9_000_000, .shopping, on: bank, 2026, 10, 5, in: context)    // October, running hot

        let r = DebtAffordability.usualMonth(cards: [bank], debts: [], salaries: [salary], installments: [],
                                             commitments: 0, payments: 1_129_167, hasDebt: true,
                                             currency: "IDR", now: now)
        XCTAssertEqual(r.monthlyIncome, 10_000_000, accuracy: 0.5)
        XCTAssertEqual(r.monthlySpending, 6_000_000, accuracy: 0.5)
        XCTAssertEqual(r.verdict, .safe)
    }

    /// Someone who logs little still pays the bills they declared.
    func testDeclaredBillsAreTheFloorForSpending() {
        let (_, bank, salary, now) = records()
        let r = DebtAffordability.usualMonth(cards: [bank], debts: [], salaries: [salary], installments: [],
                                             commitments: 4_000_000, payments: 1_000_000, hasDebt: true,
                                             currency: "IDR", now: now)
        XCTAssertEqual(r.monthlySpending, 4_000_000, accuracy: 0.5)
        XCTAssertEqual(r.left, 5_000_000, accuracy: 0.5)
    }

    // MARK: Smart Budget: clear dear debt first

    /// Fahmi's card: Rp 5.500.000 carried, Rp 1.500.000 set aside a month.
    func testTheRestOfTheShareGoesToACarriedCardBalance() {
        let a = DebtFirstAdvice(share: 1_500_000, ratio: 0.15, minimums: 1_129_167,
                                target: .card(carried: 5_500_000))
        XCTAssertEqual(a.extra, 370_833, accuracy: 0.5)
        XCTAssertFalse(a.noRoom)
        english {
            XCTAssertEqual(a.title(), "Pay off the card first, then save")
            let share = a.shareLine(currency: "IDR") ?? ""
            XCTAssertTrue(share.contains("1.500.000") && share.contains("15%")
                          && share.hasSuffix(loc("debt.first.share_costly")), share)
            let body = a.body(currency: "IDR")
            XCTAssertTrue(body.contains("5.500.000") && body.contains("370.833"), body)
        }
    }

    func testANamedDebtShowsHowMuchSoonerItEnds() throws {
        let a = DebtFirstAdvice(share: 1_500_000, ratio: 0.15, minimums: 900_000,
                                target: .debt(name: "Kredivo", annualRate: 36, balance: 10_000_000, minimum: 500_000))
        let p = try XCTUnwrap(a.faster())
        XCTAssertEqual(p.fast.months, 11)
        XCTAssertEqual(p.slow?.months, 31)
        XCTAssertEqual(p.fast.interest, 1_853_763, accuracy: 1)
        XCTAssertEqual(p.slow?.interest ?? 0, 5_499_464, accuracy: 1)
        english {
            XCTAssertEqual(a.title(), "Pay off Kredivo first, then save")
            let body = a.body(currency: "IDR")
            XCTAssertTrue(body.contains("36%") && body.contains("3.645.701") && body.contains("600.000"), body)
        }
    }

    func testAMinimumBelowTheInterestNeverEnds() throws {
        XCTAssertNil(DebtFirstAdvice.payoff(balance: 10_000_000, annualRate: 36, payment: 300_000))
        let a = DebtFirstAdvice(share: 1_500_000, ratio: 0.15, minimums: 650_000,
                                target: .debt(name: "Pinjol", annualRate: 36, balance: 10_000_000, minimum: 250_000))
        let p = try XCTUnwrap(a.faster())
        XCTAssertNil(p.slow)
        XCTAssertEqual(p.fast.months, 11, "Rp 250 rb minimum plus the Rp 850 rb rest of the share")
        let body = english { a.body(currency: "IDR") }
        XCTAssertTrue(body.contains("it never ends"), body)
    }

    func testInterestFreePayoffIsJustTheBalanceOverThePayment() {
        XCTAssertEqual(DebtFirstAdvice.payoff(balance: 1_200_000, annualRate: 0, payment: 100_000),
                       DebtFirstAdvice.Payoff(months: 12, interest: 0))
    }

    func testMinimumsTakingTheWholeShareLeaveNothingToSave() {
        let a = DebtFirstAdvice(share: 1_500_000, ratio: 0.15, minimums: 1_700_000,
                                target: .card(carried: 5_500_000))
        XCTAssertTrue(a.noRoom)
        XCTAssertNil(a.shareLine(currency: "IDR"))
        XCTAssertNil(a.faster())
        let body = english { a.body(currency: "IDR") }
        XCTAssertTrue(body.contains("1.700.000") && body.contains("1.500.000") && body.contains("your card"), body)
    }

    func testCheapDebtIsPaidOnScheduleAndTheRestSaved() {
        let a = DebtFirstAdvice(share: 1_500_000, ratio: 0.15, minimums: 1_129_167, target: nil)
        english {
            XCTAssertEqual(a.title(), "Saving alongside is fine")
            XCTAssertEqual(a.shareLine(currency: "IDR"), "Your savings & debt budget: Rp 1.500.000 a month (15%).")
            XCTAssertTrue(a.body(currency: "IDR").contains("under 10% a year"))
        }
        let full = DebtFirstAdvice(share: 1_500_000, ratio: 0.15, minimums: 2_000_000, target: nil)
        XCTAssertEqual(full.title(), loc("debt.first.title_full"))
    }

    // MARK: Which debt is dear

    func testTheDearestCostlyDebtComesFirstThenACarriedCard() {
        let context = container.mainContext
        let kur = DebtRecord(name: "KUR", type: "loan", totalAmount: 20_000_000, currentBalance: 12_000_000,
                             minimumPayment: 600_000, annualInterestRate: 6, dueDayOfMonth: 10, currency: "IDR")
        let paylater = DebtRecord(name: "Paylater", type: "other", totalAmount: 3_000_000, currentBalance: 2_000_000,
                                  minimumPayment: 300_000, annualInterestRate: 30, dueDayOfMonth: 5, currency: "IDR")
        [kur, paylater].forEach(context.insert)

        var e = FinancialHealthEngine(monthlyIncome: 10_000_000, debts: [kur, paylater], investDebtRatio: 0.15)
        e.cardCarried = 5_500_000
        guard case .debt(let name, let rate, _, _)? = e.payFirst else { return XCTFail("expected the paylater") }
        XCTAssertEqual(name, "Paylater")
        XCTAssertEqual(rate, 30)

        XCTAssertEqual(e.debtFirst.minimums, 900_000, accuracy: 0.5)

        // Paid off: KUR at 6% is not dear, the carried card balance is.
        paylater.manuallyClosed = true
        paylater.isActive = false
        XCTAssertEqual(e.payFirst, .card(carried: 5_500_000))

        e.cardCarried = 0
        XCTAssertNil(e.payFirst)
        XCTAssertEqual(e.debtFirst.share, 1_500_000, accuracy: 0.5)
        XCTAssertEqual(e.debtFirst.minimums, 600_000, accuracy: 0.5)
    }

    // MARK: Words

    func testEveryNewStringExistsInBothLanguagesAndKeepsItsArguments() {
        let keys = ["debt.afford.safe", "debt.afford.tight", "debt.afford.heavy", "debt.afford.unknown",
                    "debt.afford.no_income", "debt.afford.safe_body", "debt.afford.tight_body",
                    "debt.afford.tight_share", "debt.afford.heavy_body", "debt.afford.nopay_body",
                    "debt.afford.nopay_heavy", "debt.first.header", "debt.first.title_card", "debt.first.title_debt",
                    "debt.first.title_ok", "debt.first.title_full", "debt.first.share", "debt.first.share_costly",
                    "debt.first.row_min", "debt.first.row_extra_card", "debt.first.row_extra_debt",
                    "debt.first.row_save", "debt.first.row_save_later", "debt.first.card_noun", "debt.first.why_card",
                    "debt.first.why_debt", "debt.first.faster", "debt.first.faster_never",
                    "debt.first.back_to_saving", "debt.first.no_room", "debt.first.ok", "debt.first.full",
                    "debt.first.card_recent"]
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for k in keys { XCTAssertNotEqual(loc(k), k, "\(k) in \(language)") }
                let safe = String(format: loc("debt.afford.safe_body"), "Rp A", "Rp B", "Rp C", "Rp D")
                XCTAssertTrue(["Rp A", "Rp B", "Rp C", "Rp D"].allSatisfy(safe.contains), safe)
                let heavy = String(format: loc("debt.afford.heavy_body"), "Rp A", "Rp B", "Rp C", "Rp D")
                XCTAssertTrue(["Rp A", "Rp B", "Rp C", "Rp D"].allSatisfy(heavy.contains), heavy)
                let faster = String(format: loc("debt.first.faster"), "Jun 2027", "Mar 2028", "Rp E")
                XCTAssertTrue(["Jun 2027", "Mar 2028", "Rp E"].allSatisfy(faster.contains), faster)
                let why = String(format: loc("debt.first.why_debt"), "Kredivo", "36")
                XCTAssertTrue(why.contains("Kredivo") && why.contains("36%"), why)
            }
        }
    }
}
