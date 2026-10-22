import XCTest
import SwiftData
@testable import DiPo

/// The wallet card's face: which principal, which bank, and the page of
/// latest entries under the cover.
@MainActor
final class CardFaceTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func card(_ holder: String, _ number: String, issuer: String = "") -> BankCard {
        let c = BankCard(holderName: holder, cardNumber: number, balance: 0, expireDate: "11/29",
                         gradientStart: "#00A0E3", gradientEnd: "#005AA5", sortOrder: 0, currency: "IDR")
        c.issuerID = issuer
        container.mainContext.insert(c)
        return c
    }

    private func tx(_ name: String, _ amount: Double, _ day: Int) -> TxRecord {
        let t = TxRecord(name: name, date: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day))!,
                         amount: amount, type: "tx.type.purchase", icon: "X",
                         iconBgHex: "#000000", category: .shopping, currency: "IDR")
        container.mainContext.insert(t)
        return t
    }

    // MARK: Principal

    func testThePrincipalIsReadFromTheFirstDigits() {
        let cases: [(String, CardNetwork)] = [
            ("4532118766204821", .visa),
            ("5221845086220969", .mastercard),
            ("2221000000000009", .mastercard),
            ("2720990000000007", .mastercard),
            ("371449635398431", .amex),
            ("341111111111111", .amex),
            ("3528000000000007", .jcb),
            ("3589000000000003", .jcb),
            ("6243000000000001", .unionpay),
            ("6013014008254073", .gpn),
            ("6019001234567890", .gpn),
            ("6360001234567890", .gpn),
            ("1946001234567890", .gpn),
        ]
        for (number, expected) in cases {
            XCTAssertEqual(CardNetwork.detect(from: number), expected, number)
        }
    }

    /// Just outside each range is not that principal.
    func testTheRangesStopWhereTheNetworksSayTheyDo() {
        for number in ["2220990000000000", "2721000000000000", "3527000000000000", "3590000000000000"] {
            XCTAssertEqual(CardNetwork.detect(from: number), .unknown, number)
        }
    }

    /// Ranges Maestro and GPN both claim are left unnamed rather than guessed,
    /// and so are a wallet's provider name and an empty field.
    func testSharedRangesAndNonNumbersStayUnknown() {
        for number in ["5012340000000000", "5612340000000000", "5812340000000000", "9123", "GoPay", ""] {
            XCTAssertEqual(CardNetwork.detect(from: number), .unknown, number)
        }
    }

    /// The store keeps only the BIN and the last four; the principal still reads.
    func testAStoredNumberStillNamesItsPrincipal() {
        XCTAssertEqual(CardNetwork.detect(from: CardNumber.stored("5221845086220969")), .mastercard)
        XCTAssertEqual(CardNetwork.detect(from: CardNumber.stored("6013014008254073")), .gpn)
        XCTAssertEqual(CardNetwork.detect(from: "5221 84•• •••• 0969"), .mastercard)
    }

    func testEachPrincipalAcceptsItsOwnLengths() {
        XCTAssertTrue(CardNetwork.amex.lengths.contains(15))
        XCTAssertFalse(CardNetwork.mastercard.lengths.contains(15))
        XCTAssertTrue(CardNetwork.gpn.lengths.contains(18))
        XCTAssertTrue(CardNetwork.unionpay.lengths.contains(19))
        XCTAssertEqual(CardNetwork.mastercard.lengths, [16])
        for network in [CardNetwork.visa, .mastercard, .gpn, .jcb, .unionpay, .amex, .unknown] {
            XCTAssertLessThanOrEqual(network.lengths.max() ?? 0, CardNetwork.maxLength, network.name)
        }
        // Counting towards the next length the principal issues.
        XCTAssertEqual(CardNetwork.gpn.target(for: 17), 18)
        XCTAssertEqual(CardNetwork.amex.target(for: 9), 15)
        XCTAssertEqual(CardNetwork.visa.target(for: 19), 19)
    }

    // MARK: Words on the face

    func testTheFaceNamesTheBankAndKeepsTheCardsOwnName() {
        let bri = card("Fahmi", CardNumber.stored("5221845086220969"), issuer: "bri")
        XCTAssertEqual(WalletCard.title(for: bri), "BRI")
        XCTAssertEqual(WalletCard.subtitle(for: bri), "Fahmi •• 0969")
    }

    /// Without a known bank the card's own name is the title, and the
    /// subtitle doesn't repeat it.
    func testAnUnknownBankFallsBackToTheCardsName() {
        let c = card("Tabungan", CardNumber.stored("5221845086224821"))
        XCTAssertEqual(WalletCard.title(for: c), "Tabungan")
        XCTAssertEqual(WalletCard.subtitle(for: c), "•• 4821")
    }

    func testAWalletShowsItsProviderAndAHiddenPhoneNumber() {
        let w = BankCard(holderName: "GoPay", cardNumber: "GoPay", balance: 0, expireDate: "Digital",
                         gradientStart: "#00AED6", gradientEnd: "#006E8A", sortOrder: 0, currency: "IDR",
                         isDigitalWallet: true, walletProvider: "GoPay", phoneNumber: "+62 812 3456 7890")
        container.mainContext.insert(w)
        XCTAssertEqual(WalletCard.title(for: w), "GoPay")
        XCTAssertEqual(WalletCard.subtitle(for: w), "0812 ••• 7890")
    }

    // MARK: The page

    func testThePageShowsTheNewestTwoNewestFirst() {
        let rows = [tx("Gaji", 4_500_000, 20), tx("Warung Bu Siti", -25_000, 21),
                    tx("Pulsa", -50_000, 3), tx("Token listrik", -100_000, 19)]
        XCTAssertEqual(WalletCard.latest(rows, limit: 2).map(\.name), ["Warung Bu Siti", "Gaji"])
        XCTAssertEqual(WalletCard.latest(rows, limit: 0).count, 0)
        XCTAssertEqual(WalletCard.latest([], limit: 2).count, 0)
    }

    /// A sign and the figure; the card's own currency is left off, another
    /// one is kept so a USD entry on a rupiah card still says so.
    func testAmountsPrintLikeAPassbook() {
        XCTAssertEqual(WalletCard.amountText(tx("Warung Bu Siti", -25_000, 21), cardCurrency: "IDR"), "\u{2212}25.000")
        XCTAssertEqual(WalletCard.amountText(tx("Gaji", 4_500_000, 20), cardCurrency: "IDR"), "+4.500.000")
        let usd = TxRecord(name: "App Store", date: .now, amount: -4.99, type: "tx.type.purchase", icon: "X",
                           iconBgHex: "#000000", category: .shopping, currency: "USD")
        container.mainContext.insert(usd)
        let shown = WalletCard.amountText(usd, cardCurrency: "IDR")
        XCTAssertTrue(shown.hasPrefix("\u{2212}") && shown.contains("4.99")
                      && shown.contains(CurrencyManager.symbol(for: "USD")), shown)
    }

    func testEntriesAreDatedTodayYesterdayOrByDay() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!
        let day = { (y: Int, d: Int) in cal.date(from: DateComponents(year: y, month: 10, day: d, hour: 9))! }
        XCTAssertEqual(WalletCard.dayLabel(day(2026, 21), now: now), loc("common.today"))
        XCTAssertEqual(WalletCard.dayLabel(day(2026, 20), now: now), loc("common.yesterday"))
        let earlier = WalletCard.dayLabel(day(2026, 19), now: now)
        XCTAssertTrue(earlier.contains("19") && !earlier.contains("2026"), earlier)
        XCTAssertTrue(WalletCard.dayLabel(day(2025, 19), now: now).contains("2025"))
    }

    func testNewStringsInBothLanguagesKeepTheirArguments() {
        let keys = ["wallet.no_recent", "wallet.recent_hidden", "wallet.limit_share"]
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for k in keys { XCTAssertNotEqual(loc(k), k, "\(k) in \(language)") }
                let share = String(format: loc("wallet.limit_share"), 33, "Rp 10.000.000")
                XCTAssertTrue(share.contains("33%") && share.contains("Rp 10.000.000"), share)
                let count = String(format: loc("cards.digit_count"), 17, 18)
                XCTAssertTrue(count.contains("17/18"), count)
            }
        }
    }
}
