import XCTest
@testable import DiPo

/// Smart Budget's forecast for a group the monthly expenses still to come
/// will push past its limit. Fahmi read "Will go Rp 177.213 over" and asked
/// what it meant: it named no limit and no reason. The words now say what is
/// passed and why.
@MainActor
final class BudgetForecastWordsTests: XCTestCase {

    func testTheBadgeNamesTheLimit() {
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(String(format: loc("budget.will_go_over_short"), "Rp 177.213"),
                           "Akan lewat batas Rp 177.213")
        }
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(String(format: loc("budget.will_go_over_short"), "Rp 177.213"),
                           "Will pass its limit by Rp 177.213")
        }
    }

    /// The line under it says why: the monthly expenses not yet taken.
    func testTheLineSaysWhy() {
        for key in ["budget.bills_card_over", "budget.bills_will_over"] {
            LanguageManager.shared.withLanguage(.indonesian) {
                XCTAssertEqual(String(format: loc(key), "Rp 2.281.402", "Kebutuhan", "Rp 177.213"),
                               "Rp 2.281.402 pengeluaran bulanan belum terpotong. Setelah terpotong, Kebutuhan lewat Rp 177.213 dari batas.",
                               key)
            }
            LanguageManager.shared.withLanguage(.english) {
                XCTAssertEqual(String(format: loc(key), "Rp 2.281.402", "Needs", "Rp 177.213"),
                               "Rp 2.281.402 in monthly expenses is still to come. Once it's paid, Needs goes Rp 177.213 past its limit.",
                               key)
            }
        }
    }

    /// The amount past the limit is worked out from the figures on screen,
    /// so they add up: Rp 4.895.810 spent and Rp 2.281.402 to come against
    /// Rp 7.000.000 is Rp 177.212 over, not the Rp 177.213 the unrounded
    /// difference rounded to.
    func testTheOverAmountAddsUpOnScreen() {
        XCTAssertEqual(BudgetGroupMath.past(7_000_000, by: [4_895_810.4, 2_281_402.4]), 177_212)
        XCTAssertEqual(BudgetGroupMath.past(1_500_000, by: [1_669_250.4]), 169_250)
        // A currency shown with cents rounds each part to the cent.
        XCTAssertEqual(BudgetGroupMath.past(100, by: [12.346, 90.004], unit: 0.01), 2.35, accuracy: 0.000_1)
        XCTAssertEqual(CurrencyManager.minorUnit("IDR"), 1)
        XCTAssertEqual(CurrencyManager.minorUnit("usd"), 0.01)
    }
}
