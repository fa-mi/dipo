import XCTest
@testable import DiPo

/// Home opens on the total row above the cards. It says what the cards
/// together hold and when payday is; what is left of the period is the
/// period card's to say, once.
@MainActor
final class HomeBalanceTests: XCTestCase {

    /// One cash account: the total is that card's balance, printed right
    /// below it, so the row would only repeat it.
    func testTotalRowOnlyWithTwoCashAccountsOrMore() {
        XCTAssertFalse(HomeTotalRow.shows(cashAccounts: 0))
        XCTAssertFalse(HomeTotalRow.shows(cashAccounts: 1))
        XCTAssertTrue(HomeTotalRow.shows(cashAccounts: 2))
        XCTAssertTrue(HomeTotalRow.shows(cashAccounts: 5))
    }

    func testPaydayInWords() {
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(HomeTotalRow.paydayText(days: 9), "9 hari lagi gajian")
            XCTAssertEqual(HomeTotalRow.paydayText(days: 1), "Besok gajian")
            XCTAssertEqual(HomeTotalRow.paydayText(days: 0), "Hari ini gajian")
            XCTAssertNil(HomeTotalRow.paydayText(days: -1))
            XCTAssertNil(HomeTotalRow.paydayText(days: nil), "no salary schedule, nothing to count down")
        }
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(HomeTotalRow.paydayText(days: 11), "11 days to payday")
            XCTAssertEqual(String(format: loc("home.total_accounts"), 3), "Total · 3 accounts")
        }
    }

    /// What is left of the period comes from one formula, the period card's.
    func testRemainingCountsDebtPaidAndAddedMoneyRight() {
        XCTAssertEqual(MonthFlowCard.remaining(income: 10_000_000, expense: 9_283_500, putAway: 0, extra: 0), 716_500)
        // A card bill paid is debt cleared, not living costs.
        XCTAssertEqual(MonthFlowCard.remaining(income: 10_000_000, expense: 12_000_000, putAway: 3_900_000, extra: 0),
                       1_900_000)
        // Money the person added to the period widens what is left.
        XCTAssertEqual(MonthFlowCard.remaining(income: 1_000_000, expense: 2_000_000, putAway: 0, extra: 1_500_000),
                       500_000)
        XCTAssertEqual(MonthFlowCard.remaining(income: 5_000_000, expense: 6_250_000, putAway: 0, extra: 0), -1_250_000)
    }

    func testHomeStringsExistInBothLanguages() {
        let keys = ["home.total_balance", "home.total_accounts",
                    "home.hero.payday_today", "home.hero.payday_tomorrow", "home.hero.payday_in",
                    "home.hide_all", "home.show_all"]
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                for k in keys { XCTAssertNotEqual(loc(k), k, "\(k) in \(lang)") }
            }
        }
    }
}
