import XCTest
@testable import DiPo

/// The Plan tab keeps investments and assets under More until something is
/// kept in them, so it opens on what is in use.
@MainActor
final class PlanFoldTests: XCTestCase {

    func testUnusedInvestmentsAndAssetsWaitUnderMore() {
        XCTAssertEqual(PlanFold.underMore(holdings: 0, assets: 0), [.investments, .assets])
        XCTAssertEqual(PlanFold.underMore(holdings: 2, assets: 0), [.assets])
        XCTAssertEqual(PlanFold.underMore(holdings: 0, assets: 1), [.investments])
        XCTAssertTrue(PlanFold.underMore(holdings: 1, assets: 1).isEmpty, "Nothing waits once both are in use.")
    }

    func testMoreIsSaidInBothLanguages() {
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in ["plan.more", "plan.more_shown", "plan.more_hidden"] {
                    XCTAssertNotEqual(loc(key), key, "\(key) in \(language)")
                }
            }
        }
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(loc("plan.more"), "Lainnya")
        }
    }
}
