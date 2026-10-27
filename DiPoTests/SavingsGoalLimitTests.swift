import XCTest
@testable import DiPo

/// Signed in without Royal, one personal goal is saved for at a time; Royal
/// saves for as many as it likes. Reaching a goal frees the place.
@MainActor
final class SavingsGoalLimitTests: XCTestCase {

    func testWithoutRoyalOneGoalAtATime() {
        XCTAssertEqual(SavingsGoal.freeLimit, 1)
        XCTAssertTrue(SavingsGoal.canAddAnother(active: 0, royal: false), "The first goal is free.")
        XCTAssertFalse(SavingsGoal.canAddAnother(active: 1, royal: false), "A second at once needs Royal.")
        XCTAssertFalse(SavingsGoal.canAddAnother(active: 3, royal: false),
                       "Goals kept from a lapsed Royal stay, and no more start.")
    }

    func testRoyalHasNoLimit() {
        for active in [0, 1, 5, 40] {
            XCTAssertTrue(SavingsGoal.canAddAnother(active: active, royal: true), "\(active) in progress")
        }
    }

    func testOneGoalIsSaidAsOne() {
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(SavingsGoal.inProgressText(1), "1 goal in progress")
            XCTAssertEqual(SavingsGoal.inProgressText(2), "2 goals in progress")
        }
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(SavingsGoal.inProgressText(1), "1 target berjalan")
            XCTAssertEqual(SavingsGoal.inProgressText(4), "4 target berjalan")
        }
    }

    func testTheLimitIsSaidInBothLanguages() {
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in ["savings.more_royal", "savings.more_royal_sub", "savings.active_goals_one"] {
                    XCTAssertNotEqual(loc(key), key, "\(key) in \(language)")
                }
                XCTAssertTrue(loc("savings.more_royal_sub").contains("\(SavingsGoal.freeLimit)"),
                              "The words name the limit the code keeps, in \(language).")
                XCTAssertTrue(loc("premium.feature.savings_goals_desc").contains("\(SavingsGoal.freeLimit)"),
                              "The paywall says what Royal adds over the free goal, in \(language).")
            }
        }
    }
}
