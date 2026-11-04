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
}
