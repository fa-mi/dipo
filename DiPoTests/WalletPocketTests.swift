import XCTest
@testable import DiPo

/// The wallet's pockets: which card goes in which, and what the cards add up
/// to, printed on each pocket.
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

    // MARK: Two pockets

    private func issued(_ issuer: String, wallet: Bool = false) -> BankCard {
        let c = card(100_000)
        c.issuerID = issuer
        c.isDigitalWallet = wallet
        return c
    }

    /// Digital banks and e-wallets share a pocket. Every other bank, and a
    /// card whose bank DiPo doesn't know, goes in the conventional one.
    func testCardsSortIntoTheirPockets() {
        XCTAssertEqual(WalletPocketKind.of(issued("jago")), .digital)
        XCTAssertEqual(WalletPocketKind.of(issued("seabank")), .digital)
        XCTAssertEqual(WalletPocketKind.of(issued("blu")), .digital)
        XCTAssertEqual(WalletPocketKind.of(issued("", wallet: true)), .digital, "an e-wallet")
        XCTAssertEqual(WalletPocketKind.of(issued("bri")), .conventional)
        XCTAssertEqual(WalletPocketKind.of(issued("bca")), .conventional)
        XCTAssertEqual(WalletPocketKind.of(issued("")), .conventional, "a bank DiPo doesn't know")
    }

    /// Every digital bank named is one the card form offers: a typo would
    /// quietly send its cards to the other pocket.
    func testEveryDigitalBankIsAKnownIssuer() {
        let known = Set(BankIssuer.all.map(\.id))
        XCTAssertTrue(WalletPocketKind.digitalBanks.isSubset(of: known),
                      "\(WalletPocketKind.digitalBanks.subtracting(known))")
    }

    /// Only a pocket that holds a card is shown, conventional first, and
    /// every card is in exactly one, in the wallet's order.
    func testPocketsHoldEveryCardOnce() {
        let bri = issued("bri"), jago = issued("jago"), dana = issued("", wallet: true), bca = issued("bca")
        let groups = WalletPocketKind.groups([jago, bri, dana, bca])
        XCTAssertEqual(groups.map(\.kind), [.conventional, .digital])
        XCTAssertEqual(groups[0].cards.map(\.id), [bri.id, bca.id])
        XCTAssertEqual(groups[1].cards.map(\.id), [jago.id, dana.id])
        XCTAssertEqual(WalletPocketKind.groups([dana]).map(\.kind), [.digital])
        XCTAssertTrue(WalletPocketKind.groups([]).isEmpty)
    }

    func testTheWalletsWordsInBothLanguages() {
        let keys = ["wallet.total_cash", "wallet.cc_bills", "wallet.tap_hint", "wallet.recent",
                    "wallet.act_main", "wallet.act_match", "wallet.pocket_conventional",
                    "wallet.pocket_digital"]
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in keys { XCTAssertNotEqual(loc(key), key, "\(key) in \(language)") }
            }
        }
    }
}
