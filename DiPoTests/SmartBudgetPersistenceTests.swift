import XCTest
@testable import DiPo

// The bug that made the app ask for a main card on every launch: `load()`
// assigns five properties, each assignment fires `didSet { save() }`, and the
// first of them therefore wrote the still-default values of the other four back
// over the stored ones. `set(nil, forKey:)` REMOVES a key, so `sb_card_id` was
// deleted four lines before the line that reads it ran.
//
// The setting was never failing to save. It was being destroyed while loading.
final class SmartBudgetPersistenceTests: XCTestCase {

    private let keys = ["sb_enabled", "sb_daily", "sb_lifestyle", "sb_invest", "sb_card_id"]

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testSettingsSurviveAReload() {
        let mgr = SmartBudgetManager.shared
        mgr.isEnabled = true
        mgr.dailyRatio = 0.60
        mgr.lifestyleRatio = 0.20
        mgr.investDebtRatio = 0.20
        mgr.budgetCardID = "BRI-uuid"

        // What the store must hold once the app has written it.
        XCTAssertEqual(UserDefaults.standard.string(forKey: "sb_card_id"), "BRI-uuid")
        XCTAssertEqual(UserDefaults.standard.double(forKey: "sb_daily"), 0.60, accuracy: 0.0001)

        // Simulate the next launch reading it back.
        mgr.reloadForTesting()
        XCTAssertEqual(mgr.budgetCardID, "BRI-uuid")
        XCTAssertEqual(mgr.dailyRatio, 0.60, accuracy: 0.0001)
        XCTAssertEqual(mgr.lifestyleRatio, 0.20, accuracy: 0.0001)
    }

    func testLoadDoesNotOverwriteWithDefaults() {
        UserDefaults.standard.set(true, forKey: "sb_enabled")
        UserDefaults.standard.set(0.60, forKey: "sb_daily")
        UserDefaults.standard.set(0.20, forKey: "sb_lifestyle")
        UserDefaults.standard.set(0.20, forKey: "sb_invest")
        UserDefaults.standard.set("BRI-uuid", forKey: "sb_card_id")

        SmartBudgetManager.shared.reloadForTesting()

        // The key must still be there afterwards — the old code deleted it
        // mid-load and then read back the hole it had just made.
        XCTAssertEqual(UserDefaults.standard.string(forKey: "sb_card_id"), "BRI-uuid")
        XCTAssertEqual(SmartBudgetManager.shared.budgetCardID, "BRI-uuid")
    }
}
