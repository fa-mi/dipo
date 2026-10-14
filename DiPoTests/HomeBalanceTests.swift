import XCTest
@testable import DiPo

/// Home opens on the money: the total, the line under it, and the accounts
/// side by side.
@MainActor
final class HomeBalanceTests: XCTestCase {

    private func card(holder: String, number: String) -> BankCard {
        BankCard(holderName: holder, cardNumber: number, balance: 0, expireDate: "12/30",
                 gradientStart: "#000000", gradientEnd: "#111111", sortOrder: 0, currency: "IDR")
    }

    /// The line under the total quotes the period card's own "left" figure.
    func testHeroLineSaysWhatIsLeftLikeThePeriodCard() {
        LanguageManager.shared.withLanguage(.indonesian) {
            let line = HomeHeroLine.make(income: 10_000_000, expense: 8_103_485, putAway: 0, extra: 0,
                                         daysToPayday: 11)
            XCTAssertEqual(line.left, .left(1_896_515))
            XCTAssertEqual(line.payday, "11 hari lagi gajian")
            XCTAssertEqual(MonthFlowCard.remaining(income: 10_000_000, expense: 8_103_485, putAway: 0, extra: 0),
                           1_896_515)
        }
    }

    /// A card bill paid is debt cleared, not living costs; money added to the
    /// period widens what is left.
    func testDebtPaidAndMoneyAddedAreNotOverspending() {
        let paid = HomeHeroLine.make(income: 10_000_000, expense: 12_000_000, putAway: 3_900_000, extra: 0,
                                     daysToPayday: nil)
        XCTAssertEqual(paid.left, .left(1_900_000))
        let added = HomeHeroLine.make(income: 1_000_000, expense: 2_000_000, putAway: 0, extra: 1_500_000,
                                      daysToPayday: nil)
        XCTAssertEqual(added.left, .left(500_000))
        XCTAssertNil(added.payday)
    }

    func testPastIncomeIsSaidAsOverNeverAMinus() {
        let line = HomeHeroLine.make(income: 5_000_000, expense: 6_250_000, putAway: 0, extra: 0, daysToPayday: 3)
        XCTAssertEqual(line.left, .over(1_250_000))
    }

    /// Before payday has brought anything in, nothing is "left of" it; the
    /// line only counts the days.
    func testNoIncomeYetSaysOnlyThePayday() {
        LanguageManager.shared.withLanguage(.indonesian) {
            let line = HomeHeroLine.make(income: 0, expense: 450_000, putAway: 0, extra: 0, daysToPayday: 1)
            XCTAssertNil(line.left)
            XCTAssertEqual(line.payday, "Besok gajian")
            XCTAssertEqual(HomeHeroLine.make(income: 0, expense: 0, putAway: 0, extra: 0, daysToPayday: 0).payday,
                           "Hari ini gajian")
            XCTAssertNil(HomeHeroLine.make(income: 0, expense: 0, putAway: 0, extra: 0, daysToPayday: -1).payday)
            XCTAssertNil(HomeHeroLine.make(income: 0, expense: 0, putAway: 0, extra: 0, daysToPayday: nil).payday)
        }
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(HomeHeroLine.make(income: 0, expense: 0, putAway: 0, extra: 0, daysToPayday: 11).payday,
                           "11 days to payday")
        }
    }

    /// A tile names the bank (picked, else detected from the number, else
    /// the holder name) and the last four digits; a wallet, its provider.
    func testTileNamesTheBankAndTheLastFour() {
        let picked = card(holder: "Fahmi Aquinas", number: "1234 5678 9012 0969")
        picked.issuerID = "bri"
        XCTAssertEqual(picked.tileLabel, "BRI •• 0969")

        let detected = card(holder: "Fahmi Aquinas", number: "5221 8400 0000 1182")
        XCTAssertEqual(detected.tileLabel, "BRI •• 1182", "522184 is BRI's BIN")

        XCTAssertEqual(card(holder: "Tabungan", number: "9999 0000 0000 4321").tileLabel, "Tabungan •• 4321")

        let wallet = card(holder: "Fahmi", number: "")
        wallet.isDigitalWallet = true
        wallet.walletProvider = "GoPay"
        XCTAssertEqual(wallet.tileLabel, "GoPay")

        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(card(holder: "", number: "").tileLabel, "Account")
            XCTAssertEqual(card(holder: "", number: "4111 1111 1111 7788").tileLabel, "•• 7788")
        }
    }

    /// With DiPo off, the header shows the user's initial; the "User"
    /// placeholder is no name, so it gets the silhouette.
    func testHeaderInitialIsTheNameNotThePlaceholder() {
        XCTAssertEqual(HomeHeader.initial(of: "fahmi"), "F")
        XCTAssertEqual(HomeHeader.initial(of: "  ana "), "A")
        XCTAssertNil(HomeHeader.initial(of: "User"))
        XCTAssertNil(HomeHeader.initial(of: "   "))
    }

    func testHomeStringsExistInBothLanguages() {
        let keys = ["home.total_balance", "home.hero.left", "home.hero.left_month", "home.hero.over",
                    "home.hero.payday_today", "home.hero.payday_tomorrow", "home.hero.payday_in",
                    "home.hide_all", "home.show_all", "home.add_account", "home.manage_cards",
                    "profile.home_dipo", "profile.home_dipo_sub"]
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                for k in keys { XCTAssertNotEqual(loc(k), k, "\(k) in \(lang)") }
            }
        }
    }
}
