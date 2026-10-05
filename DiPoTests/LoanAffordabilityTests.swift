import XCTest
@testable import DiPo

/// "How much house or car is safe": worked backwards from income, existing
/// payments and savings beyond the emergency fund.
@MainActor
final class LoanAffordabilityTests: XCTestCase {

    // MARK: Loan from instalment

    func testAnnuityPrincipalRoundTripsTheKPRInstalment() {
        let loan = LoanAffordability.principal(forInstalment: 1_100_000, annualRatePercent: 10,
                                               years: 15, method: .annuity)
        XCTAssertEqual(loan, 102_363_183, accuracy: 1)
        XCTAssertEqual(PlannerMath.annuityInstalment(principal: loan, annualRatePercent: 10, years: 15),
                       1_100_000, accuracy: 0.01)
    }

    func testFlatPrincipalRoundTripsTheVehicleInstalment() {
        let loan = LoanAffordability.principal(forInstalment: 2_000_000, annualRatePercent: 10,
                                               years: 5, method: .flat)
        XCTAssertEqual(loan, 80_000_000, accuracy: 0.01)                   // 2 jt × 60 / 1,5
        XCTAssertEqual(PlannerMath.flatInstalment(principal: loan, annualRatePercent: 10, years: 5).monthly,
                       2_000_000, accuracy: 0.01)
    }

    // MARK: Which limit sets the price

    /// Rp 10 jt income, Rp 1 jt of debts, Rp 1,5 jt of bills: the 36% line
    /// leaves Rp 1,1 jt, below the lenders' 30% (Rp 2 jt).
    func testIncomeLimitsThePriceWhenSavingsAreAmple() {
        let a = LoanAffordability.evaluate(income: 10_000_000, debtPayments: 1_000_000,
                                           fixedBills: 1_500_000, spareCash: 100_000_000,
                                           annualRatePercent: 10, years: 15, method: .annuity,
                                           minDownShare: 0.10)
        XCTAssertEqual(a.limit, .instalment)
        XCTAssertFalse(a.lenderRuleBinds)
        XCTAssertEqual(a.maxInstalment, 1_100_000, accuracy: 0.01)
        XCTAssertEqual(a.maxLoan, 102_363_183, accuracy: 1)
        XCTAssertEqual(a.maxPrice, 202_363_183, accuracy: 1)               // whole spare cash as down payment
        XCTAssertEqual(a.downPaymentShortfall, 0)
    }

    func testSavingsLimitThePriceWhenTheDownPaymentIsShort() {
        let a = LoanAffordability.evaluate(income: 10_000_000, debtPayments: 1_000_000,
                                           fixedBills: 1_500_000, spareCash: 5_000_000,
                                           annualRatePercent: 10, years: 15, method: .annuity,
                                           minDownShare: 0.10)
        XCTAssertEqual(a.limit, .downPayment)
        XCTAssertEqual(a.maxPrice, 50_000_000, accuracy: 0.01)              // 5 jt is 10% of 50 jt
        XCTAssertEqual(a.maxLoan, 45_000_000, accuracy: 0.01)
        XCTAssertEqual(a.priceIfSaved, 113_736_870, accuracy: 1)
        XCTAssertEqual(a.downPaymentShortfall, 6_373_687, accuracy: 1)
    }

    func testNoSpareCashMeansNoPriceYetButSaysWhatToSave() {
        let a = LoanAffordability.evaluate(income: 10_000_000, debtPayments: 0, fixedBills: 0,
                                           spareCash: -3_000_000,               // emergency fund not full
                                           annualRatePercent: 10, years: 5, method: .flat,
                                           minDownShare: 0.20)
        XCTAssertEqual(a.limit, .downPayment)
        XCTAssertEqual(a.maxPrice, 0)
        XCTAssertEqual(a.downPaymentCash, 0)
        XCTAssertGreaterThan(a.downPaymentShortfall, 0)
    }

    func testLendersThirtyPercentBindsWhenDebtsAreTheLoad() {
        let a = LoanAffordability.evaluate(income: 10_000_000, debtPayments: 2_800_000, fixedBills: 0,
                                           spareCash: 50_000_000, annualRatePercent: 10, years: 5,
                                           method: .flat, minDownShare: 0.20)
        XCTAssertTrue(a.lenderRuleBinds)
        XCTAssertEqual(a.maxInstalment, 200_000, accuracy: 0.01)
    }

    /// The screenshot case: Rp 10 jt income with Rp 3,98 jt already fixed.
    func testNoRoomWhenFixedPaymentsAreAlreadyPastTheLine() {
        let a = LoanAffordability.evaluate(income: 10_000_000, debtPayments: 1_500_000,
                                           fixedBills: 2_482_028, spareCash: 50_000_000,
                                           annualRatePercent: 10, years: 15, method: .annuity,
                                           minDownShare: 0.10)
        XCTAssertEqual(a.limit, .noRoom)
        XCTAssertEqual(a.maxPrice, 0)
        XCTAssertEqual(a.overBy, 382_028, accuracy: 0.01)
    }

    /// A loan sized at the safe instalment lands on the load card's "Healthy".
    func testSafeInstalmentKeepsTheLoadCardHealthy() {
        let load = ObligationLoad(monthlyIncome: 10_000_000, debtMinimums: 1_000_000, commitments: 1_500_000,
                                  debtAllowanceRatio: 0.2, dailyAllowanceRatio: 0.5)
        let a = LoanAffordability.evaluate(income: load.monthlyIncome, debtPayments: load.debtPayments,
                                           fixedBills: load.commitments, spareCash: 100_000_000,
                                           annualRatePercent: 10, years: 15, method: .annuity,
                                           minDownShare: 0.10)
        XCTAssertEqual(load.adding(instalment: a.maxInstalment).verdict, .healthy)
    }

    // MARK: Credit cards in the fixed load

    private func creditCard(openingOwed: Double) -> BankCard {
        let c = BankCard(holderName: "CC", cardNumber: "5221845086220969", balance: 0,
                         expireDate: "11/29", gradientStart: "#000000", gradientEnd: "#111111",
                         sortOrder: 0, currency: "IDR")
        c.isCreditCard = true
        c.creditLimit = 20_000_000
        c.openingOwed = openingOwed
        c.creditSince = .distantPast
        return c
    }

    func testCardInstalmentsAndCarriedBalanceMinimumCount() {
        let card = creditCard(openingOwed: 4_000_000)
        let inst = CardInstallment(cardID: card.id, merchant: "HP", totalAmount: 6_000_000,
                                   tenorMonths: 12, startDate: .now, flatRatePercent: 0, currency: "IDR")
        let monthly = ObligationLoad.cardPayments(cards: [card], installments: [inst], debts: [],
                                                  currency: "IDR")
        XCTAssertEqual(monthly, 500_000 + 200_000, accuracy: 0.01)          // instalment + 5% of 4 jt
    }

    func testCarriedBalanceIsNotCountedTwiceWhenRecordedAsADebt() {
        let card = creditCard(openingOwed: 4_000_000)
        let debt = DebtRecord(name: "Kartu kredit", type: DebtType.creditCard.rawValue,
                              totalAmount: 4_000_000, currentBalance: 4_000_000,
                              minimumPayment: 200_000, annualInterestRate: 21, dueDayOfMonth: 5,
                              currency: "IDR")
        XCTAssertEqual(ObligationLoad.cardPayments(cards: [card], installments: [], debts: [debt],
                                                   currency: "IDR"), 0, accuracy: 0.01)
    }
}
