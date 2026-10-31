import XCTest
@testable import DiPo

/// The wallet's pocket: what the cards add up to, printed on the pocket.
@MainActor
final class WalletPocketTests: XCTestCase {

    private func card(_ balance: Double, currency: String = "IDR", hidden: Bool = false,
                      owed: Double? = nil) -> BankCard {
        let c = BankCard(holderName: "Fahmi", cardNumber: "5221845086220969", balance: balance,
                         expireDate: "11/29", gradientStart: "#00A0E3", gradientEnd: "#005AA5",
                         sortOrder: 0, currency: currency)
        c.isHidden = hidden
        if let owed {
            c.isCreditCard = true
            c.creditLimit = 15_000_000
            c.openingOwed = owed
            c.creditSince = .distantPast
        }
        return c
    }

    /// Cash is the debit cards and wallets. A credit card's bill is listed on
    /// its own line and never taken off the cash. A card hidden on its face
    /// still counts.
    func testCashAndBillsAddUpApart() {
        let cards = [card(5_240_000), card(342_500, hidden: true), card(0, owed: 1_250_000)]
        let totals = WalletPocket.totals(of: cards, preferred: "IDR")
        XCTAssertEqual(totals.cash, [.init(currency: "IDR", value: 5_582_500)])
        XCTAssertEqual(totals.bills, [.init(currency: "IDR", value: 1_250_000)])
    }

    /// Each currency is summed on its own, the preferred one first: a total at
    /// today's rate would be a guess.
    func testCurrenciesAreNeverMixed() {
        let cards = [card(120, currency: "USD"), card(1_000_000), card(50, currency: "EUR")]
        let totals = WalletPocket.totals(of: cards, preferred: "IDR")
        XCTAssertEqual(totals.cash.map(\.currency), ["IDR", "EUR", "USD"])
        XCTAssertEqual(totals.cash.first?.value, 1_000_000)
        XCTAssertTrue(totals.bills.isEmpty)
    }

    /// A credit card paid off owes nothing: no bill line, and no cash either.
    func testAPaidOffCreditCardAddsNothing() {
        let totals = WalletPocket.totals(of: [card(0, owed: 0)], preferred: "IDR")
        XCTAssertTrue(totals.cash.isEmpty)
        XCTAssertTrue(totals.bills.isEmpty)
    }

    /// An overdrawn account takes the total below zero rather than vanishing.
    func testAnOverdrawnAccountLowersTheTotal() {
        let totals = WalletPocket.totals(of: [card(300_000), card(-500_000)], preferred: "IDR")
        XCTAssertEqual(totals.cash, [.init(currency: "IDR", value: -200_000)])
    }

    func testTheWalletsWordsInBothLanguages() {
        let keys = ["wallet.total_cash", "wallet.cc_bills", "wallet.tap_hint", "wallet.recent",
                    "wallet.act_main", "wallet.act_match"]
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in keys { XCTAssertNotEqual(loc(key), key, "\(key) in \(language)") }
            }
        }
    }
}
