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

    // MARK: The pager follows the pocket in front

    /// Three cards in one pocket, five in the other: the pager is as tall as
    /// the one in view, and halfway through a swipe, halfway between them.
    func testThePagerIsAsTallAsThePocketInFront() {
        let w: CGFloat = 390
        let kinds: [WalletPocketKind] = [.conventional, .digital]
        func frames(_ offset: CGFloat) -> [WalletPocketKind: CGRect] {
            [.conventional: CGRect(x: -offset, y: 8, width: w, height: 300),
             .digital: CGRect(x: w - offset, y: 8, width: w, height: 420)]
        }
        XCTAssertEqual(WalletPockets.height(of: frames(0), kinds: kinds), 300)
        XCTAssertEqual(WalletPockets.height(of: frames(w / 2), kinds: kinds), 360)
        XCTAssertEqual(WalletPockets.height(of: frames(w), kinds: kinds), 420)
    }

    /// One pocket is as tall as itself; a pocket that has gone (its last card
    /// deleted) no longer counts; nothing measured yet leaves the natural height.
    func testThePagerReadsOnlyThePocketsThere() {
        let only = [WalletPocketKind.conventional: CGRect(x: 0, y: 0, width: 390, height: 250)]
        XCTAssertEqual(WalletPockets.height(of: only, kinds: [.conventional]), 250)
        let stale = only.merging([.digital: CGRect(x: 0, y: 0, width: 390, height: 900)]) { $1 }
        XCTAssertEqual(WalletPockets.height(of: stale, kinds: [.conventional]), 250)
        XCTAssertNil(WalletPockets.height(of: [:], kinds: [.conventional, .digital]))
    }

    /// The pockets sit under their names, not at the foot of a pager sized
    /// for the fuller one.
    func testThePocketsAreTopAligned() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("DiPo/WalletPocket.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("HStack(alignment: .top, spacing: 0)"))
        XCTAssertFalse(source.contains("HStack(alignment: .bottom, spacing: 0)"))
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
