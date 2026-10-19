import XCTest
import SwiftData
@testable import DiPo

/// What the money owed to the user would clear if it came back, and what a
/// usual month looks like then.
@MainActor
final class OwedBackPlanTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func card(_ name: String, carried: Double) -> OwedBackPlan.Costly {
        .init(id: UUID(), name: name, kind: .card, balance: carried)
    }

    private func loan(_ name: String, rate: Double, balance: Double, minimum: Double) -> OwedBackPlan.Costly {
        .init(id: UUID(), name: name, kind: .loan(annualRate: rate), balance: balance, minimum: minimum)
    }

    /// Fahmi's figures: the Tokopedia card carries Rp 5.250.000, Rp 7.500.000
    /// is owed back, and a usual month already costs more than comes in.
    private let fahmi = DebtAffordability(monthlyIncome: 11_200_000, monthlySpending: 12_185_800,
                                          monthlyPayments: 1_116_667)

    // MARK: What it clears

    func testItClearsTheCardAndKeepsTheRestAsABuffer() throws {
        let plan = try XCTUnwrap(OwedBackPlan.make(owedBack: 7_500_000, costly: [card("Tokopedia CC", carried: 5_250_000)],
                                                   totalDebt: 16_000_000, reading: fahmi))
        XCTAssertEqual(plan.payoffs.count, 1)
        XCTAssertEqual(plan.payoffs[0].paid, 5_250_000)
        XCTAssertTrue(plan.payoffs[0].cleared)
        XCTAssertEqual(plan.leftOver, 2_250_000)
        // The card's minimum is 5% of the carried balance; the instalments stay.
        XCTAssertEqual(plan.after.monthlyPayments, 1_116_667 - 262_500, accuracy: 0.5)
    }

    /// The money comes once; a usual month that costs more than comes in is
    /// short again the month after. The plan says so instead of hiding it.
    func testAMonthThatSpendsMoreThanComesInStaysTooHeavy() throws {
        let plan = try XCTUnwrap(OwedBackPlan.make(owedBack: 7_500_000, costly: [card("Tokopedia CC", carried: 5_250_000)],
                                                   totalDebt: 16_000_000, reading: fahmi))
        XCTAssertEqual(plan.before.verdict, .heavy)
        XCTAssertEqual(plan.after.verdict, .heavy)
        XCTAssertEqual(plan.after.left, -1_839_967, accuracy: 0.5)
        let note = LanguageManager.shared.withLanguage(.english) { plan.note(currency: "IDR") }
        XCTAssertTrue(note.contains(CurrencyManager.shared.formatted(1_839_967, currency: "IDR")), note)
        XCTAssertTrue(note.contains("spending"), note)
    }

    func testDearLoansGoFirstThenCards() throws {
        let reading = DebtAffordability(monthlyIncome: 10_000_000, monthlySpending: 8_400_000, monthlyPayments: 1_900_000)
        let plan = try XCTUnwrap(OwedBackPlan.make(
            owedBack: 6_000_000,
            costly: [card("BCA", carried: 3_000_000),
                     loan("KTA", rate: 12, balance: 2_000_000, minimum: 300_000),
                     loan("Pinjol", rate: 28, balance: 4_000_000, minimum: 500_000)],
            totalDebt: 9_400_000, reading: reading))
        XCTAssertEqual(plan.payoffs.map(\.debt.name), ["Pinjol", "KTA"])
        XCTAssertTrue(plan.payoffs.allSatisfy(\.cleared))
        XCTAssertEqual(plan.leftOver, 0)
        // Both loans' payments end: 1.900.000 − 500.000 − 300.000.
        XCTAssertEqual(plan.after.monthlyPayments, 1_100_000, accuracy: 0.5)
        XCTAssertEqual(plan.before.verdict, .heavy)
        XCTAssertEqual(plan.after.verdict, .tight, "Rp 500.000 left is under a tenth of income")
        let note = LanguageManager.shared.withLanguage(.english) { plan.note(currency: "IDR") }
        XCTAssertTrue(note.contains(CurrencyManager.shared.formatted(500_000, currency: "IDR")), note)
    }

    /// A loan's payment is fixed until it is paid off: part of the balance
    /// doesn't change the month. A card's minimum falls with the balance.
    func testAPartlyPaidLoanStillAsksItsPayment() throws {
        let reading = DebtAffordability(monthlyIncome: 10_000_000, monthlySpending: 7_000_000, monthlyPayments: 1_000_000)
        let plan = try XCTUnwrap(OwedBackPlan.make(owedBack: 1_000_000,
                                                   costly: [loan("KTA", rate: 20, balance: 5_000_000, minimum: 600_000)],
                                                   totalDebt: 5_000_000, reading: reading))
        XCTAssertFalse(plan.payoffs[0].cleared)
        XCTAssertEqual(plan.after.monthlyPayments, 1_000_000)
        let partCard = try XCTUnwrap(OwedBackPlan.make(owedBack: 1_000_000, costly: [card("BCA", carried: 5_000_000)],
                                                       totalDebt: 5_000_000, reading: reading))
        XCTAssertEqual(partCard.after.monthlyPayments, 1_000_000 - 50_000, accuracy: 0.5)
    }

    func testClearingEverythingLeavesNoDebt() throws {
        let reading = DebtAffordability(monthlyIncome: 10_000_000, monthlySpending: 7_000_000, monthlyPayments: 150_000)
        let plan = try XCTUnwrap(OwedBackPlan.make(owedBack: 5_000_000, costly: [card("BCA", carried: 3_000_000)],
                                                   totalDebt: 3_000_000, reading: reading))
        XCTAssertNil(plan.after.verdict)
        let label = LanguageManager.shared.withLanguage(.english) { plan.after.verdictLabel }
        XCTAssertEqual(label, "No debt left")
    }

    func testNothingToShowWithoutMoneyOwedSomethingDearOrAnIncome() {
        XCTAssertNil(OwedBackPlan.make(owedBack: 0, costly: [card("BCA", carried: 1_000_000)],
                                       totalDebt: 1_000_000, reading: fahmi))
        XCTAssertNil(OwedBackPlan.make(owedBack: 3_000_000, costly: [], totalDebt: 10_000_000, reading: fahmi),
                     "0% instalments and cheap debt are paid on schedule, not early")
        let noIncome = DebtAffordability(monthlyIncome: 0, monthlySpending: 5_000_000, monthlyPayments: 500_000)
        XCTAssertNil(OwedBackPlan.make(owedBack: 3_000_000, costly: [card("BCA", carried: 1_000_000)],
                                       totalDebt: 1_000_000, reading: noIncome))
    }

    // MARK: Money that just came back

    func testARepaymentIsOfferedToTheDearestDebtUpToItsBalance() throws {
        let costly = [card("Tokopedia CC", carried: 5_250_000), loan("Pinjol", rate: 30, balance: 1_000_000, minimum: 200_000)]
        let first = try XCTUnwrap(OwedBackPlan.firstPayoff(of: 3_000_000, costly: costly))
        XCTAssertEqual(first.debt.name, "Pinjol")
        XCTAssertEqual(first.paid, 1_000_000, "never more than is owed")
        let onCard = try XCTUnwrap(OwedBackPlan.firstPayoff(of: 3_000_000, costly: [costly[0]]))
        XCTAssertEqual(onCard.paid, 3_000_000)
        XCTAssertFalse(onCard.cleared)
        XCTAssertNil(OwedBackPlan.firstPayoff(of: 0, costly: costly))
        XCTAssertNil(OwedBackPlan.firstPayoff(of: 3_000_000, costly: []))
    }

    // MARK: From the records

    func testTheDearDebtsAreReadFromTheRecords() {
        let cc = BankCard(holderName: "Tokopedia CC", cardNumber: "5221845086220970", balance: 0, expireDate: "11/29",
                          gradientStart: "#000000", gradientEnd: "#111111", sortOrder: 1, currency: "IDR")
        cc.isCreditCard = true
        cc.creditLimit = 40_000_000
        cc.openingOwed = 5_250_000
        cc.creditSince = .distantPast
        let bank = BankCard(holderName: "BRI", cardNumber: "5221845086220969", balance: 2_000_000, expireDate: "11/29",
                            gradientStart: "#000000", gradientEnd: "#111111", sortOrder: 0, currency: "IDR")
        let pinjol = DebtRecord(name: "Pinjol", type: DebtType.loan.rawValue, totalAmount: 3_000_000,
                                currentBalance: 2_000_000, minimumPayment: 400_000, annualInterestRate: 30,
                                dueDayOfMonth: 5, currency: "IDR")
        let kpr = DebtRecord(name: "KPR", type: DebtType.loan.rawValue, totalAmount: 300_000_000,
                             currentBalance: 250_000_000, minimumPayment: 3_000_000, annualInterestRate: 7,
                             dueDayOfMonth: 5, currency: "IDR")
        [cc, bank].forEach(context.insert)
        [pinjol, kpr].forEach(context.insert)

        let found = OwedBackPlan.costly(debts: [pinjol, kpr], cards: [bank, cc], currency: "IDR")
        XCTAssertEqual(found.map(\.name), ["Pinjol", "Tokopedia CC"], "the 7% mortgage is cheap; the bank account owes nothing")
        XCTAssertEqual(found.last?.balance ?? 0, 5_250_000, accuracy: 0.5)

        // A card debt recorded by hand is the card's balance: counted once.
        let byHand = DebtRecord(name: "Tokopedia CC", type: DebtType.creditCard.rawValue, totalAmount: 5_250_000,
                                currentBalance: 5_250_000, minimumPayment: 262_500, annualInterestRate: 21,
                                dueDayOfMonth: 20, currency: "IDR")
        context.insert(byHand)
        let once = OwedBackPlan.costly(debts: [pinjol, kpr, byHand], cards: [bank, cc], currency: "IDR")
        XCTAssertEqual(once.map(\.name), ["Pinjol", "Tokopedia CC"])
        XCTAssertEqual(once.last?.kind, .loan(annualRate: 21))
    }

    // MARK: Words

    func testEveryStringExistsInBothLanguagesAndKeepsItsArguments() {
        let keys = ["debt.owed_back.title", "debt.owed_back.carried", "debt.owed_back.rate", "debt.owed_back.cleared",
                    "debt.owed_back.of", "debt.owed_back.left_over", "debt.owed_back.buffer", "debt.owed_back.verdict",
                    "debt.owed_back.debt_free", "debt.owed_back.interest", "debt.owed_back.interest_less",
                    "debt.owed_back.still_short", "debt.owed_back.closes", "debt.owed_back.spare",
                    "receivable.offer.recorded", "receivable.offer.into", "receivable.offer.title",
                    "receivable.offer.why_card", "receivable.offer.why_loan", "receivable.offer.pay",
                    "receivable.offer.later", "receivable.offer.hint"]
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for k in keys { XCTAssertNotEqual(loc(k), k, "\(k) in \(language)") }
                XCTAssertEqual(String(format: loc("debt.owed_back.rate"), "28"), language == .english ? "28% a year" : "28% setahun")
                let into = String(format: loc("receivable.offer.into"), "Budi", "BRI")
                XCTAssertTrue(into.contains("Budi") && into.contains("BRI"), into)
                let pay = String(format: loc("receivable.offer.pay"), "Rp 3.000.000", "Tokopedia CC")
                XCTAssertTrue(pay.contains("Rp 3.000.000") && pay.contains("Tokopedia CC"), pay)
                XCTAssertTrue(String(format: loc("receivable.offer.why_loan"), "30").contains("30%"))
            }
        }
    }
}
