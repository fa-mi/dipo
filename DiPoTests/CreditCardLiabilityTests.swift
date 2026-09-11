import XCTest
@testable import DiPo

// A credit card carrying an instalment reported far less debt than the bank
// did, because `owedBalance()` only ever counted logged transactions. The Debt
// Tracker then rendered `InstallmentSection` — the list of those very
// instalments — directly beneath the row that excluded them, so one screen
// displayed a debt and denied it at the same time.
//
// The same blind figure fed Home's net worth and the Financial Briefing, so the
// under-count propagated into every headline number in the app.
final class CreditCardLiabilityTests: XCTestCase {

    private func creditCard(limit: Double, openingOwed: Double) -> BankCard {
        let c = BankCard(holderName: "CC", cardNumber: "5221845086220969", balance: 0,
                         expireDate: "11/29", gradientStart: "#000000", gradientEnd: "#111111",
                         sortOrder: 0, currency: "IDR")
        c.isCreditCard = true
        c.creditLimit = limit
        c.openingOwed = openingOwed
        c.creditSince = .distantPast
        return c
    }

    /// An instalment that has not been billed yet: the full principal is still
    /// outstanding, so it is the cleanest case to assert against.
    private func freshInstallment(on card: BankCard, amount: Double, tenor: Int) -> CardInstallment {
        CardInstallment(cardID: card.id, merchant: "Laptop", totalAmount: amount,
                        tenorMonths: tenor, startDate: .now, flatRatePercent: 0,
                        currency: "IDR")
    }

    // MARK: Owed

    func testOwedExcludesInstalmentsWithoutTheInstalmentList() {
        let card = creditCard(limit: 10_000_000, openingOwed: 2_000_000)
        // The old reading. Kept as a test so the gap is documented, not folklore.
        XCTAssertEqual(card.owedBalance(), 2_000_000, accuracy: 1)
    }

    func testTotalOwedAddsOutstandingInstalmentPrincipal() {
        let card = creditCard(limit: 10_000_000, openingOwed: 2_000_000)
        let inst = freshInstallment(on: card, amount: 6_000_000, tenor: 12)
        XCTAssertEqual(card.totalOwed([inst]), 8_000_000, accuracy: 1)
    }

    func testInstalmentOnAnotherCardIsNotCounted() {
        let card = creditCard(limit: 10_000_000, openingOwed: 2_000_000)
        let other = creditCard(limit: 5_000_000, openingOwed: 0)
        let inst = freshInstallment(on: other, amount: 6_000_000, tenor: 12)
        XCTAssertEqual(card.totalOwed([inst]), 2_000_000, accuracy: 1)
    }

    func testInactiveInstalmentIsNotCounted() {
        let card = creditCard(limit: 10_000_000, openingOwed: 2_000_000)
        let inst = freshInstallment(on: card, amount: 6_000_000, tenor: 12)
        inst.isActive = false
        XCTAssertEqual(card.totalOwed([inst]), 2_000_000, accuracy: 1)
    }

    // MARK: Available credit

    func testAvailableCreditShrinksByInstalmentPrincipal() {
        let card = creditCard(limit: 10_000_000, openingOwed: 2_000_000)
        let inst = freshInstallment(on: card, amount: 6_000_000, tenor: 12)
        // Blind reading said 8,000,000 was still spendable. It was 2,000,000.
        XCTAssertEqual(card.availableCredit([inst]), 2_000_000, accuracy: 1)
    }

    func testAvailableCreditNeverGoesNegative() {
        let card = creditCard(limit: 5_000_000, openingOwed: 2_000_000)
        let inst = freshInstallment(on: card, amount: 9_000_000, tenor: 12)
        XCTAssertEqual(card.availableCredit([inst]), 0, accuracy: 1)
    }

    // MARK: Utilisation

    func testUtilisationCountsInstalments() {
        let card = creditCard(limit: 10_000_000, openingOwed: 2_000_000)
        let inst = freshInstallment(on: card, amount: 6_000_000, tenor: 12)
        // 20% blind vs 80% actual — the difference between "healthy" and the
        // point a scoring model starts treating the card as a risk signal.
        XCTAssertEqual(card.creditUtilization, 0.2, accuracy: 0.001)
        XCTAssertEqual(card.utilisation([inst]), 0.8, accuracy: 0.001)
    }

    func testUtilisationClampsAtOne() {
        let card = creditCard(limit: 5_000_000, openingOwed: 2_000_000)
        let inst = freshInstallment(on: card, amount: 9_000_000, tenor: 12)
        XCTAssertEqual(card.utilisation([inst]), 1.0, accuracy: 0.001)
    }

    func testUtilisationIsZeroWhenNoLimitIsSet() {
        let card = creditCard(limit: 0, openingOwed: 1_000_000)
        XCTAssertEqual(card.utilisation([]), 0, accuracy: 0.001)
    }

    // MARK: Monthly charge — the figure the briefing bills as a commitment

    func testInstalmentMonthlyChargeIsTheStatementAmount() {
        let card = creditCard(limit: 10_000_000, openingOwed: 0)
        let inst = freshInstallment(on: card, amount: 6_000_000, tenor: 12)
        // 0% promo: no interest, so the charge is a flat division. The briefing
        // adds THIS at face value rather than guessing 10% of the principal,
        // which would have said 600,000 for a bill that is actually 500,000.
        XCTAssertEqual(card.installmentMonthlyCharge([inst]), 500_000, accuracy: 1)
    }
}
