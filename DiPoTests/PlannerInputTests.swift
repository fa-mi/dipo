import XCTest
@testable import DiPo

/// The planner's calculators: BPJS named in English too, and the JHT share
/// used to fill the monthly contribution from the user's salary.
@MainActor
final class PlannerInputTests: XCTestCase {

    func testJhtIsFivePointSevenPercentOfWage() {
        XCTAssertEqual(10_000_000 * CalculatorSheet.jhtShareOfWage, 570_000, accuracy: 0.01)
        XCTAssertEqual(Double(CalculatorSheet.Example.jhtMonthly), 570_000)
    }

    func testBpjsIsNamedInEnglishToo() {
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertTrue(loc("planner.row_jht").contains("BPJS"))
            XCTAssertTrue(loc("planner.row_jp").contains("BPJS"))
            XCTAssertTrue(loc("planner.health").contains("BPJS"))
        }
        for lang in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(lang) {
                for key in ["planner.example_hint", "planner.filled_jht_monthly", "planner.filled_jht_opening"] {
                    XCTAssertNotEqual(loc(key), key, key)
                }
            }
        }
    }
}
