import XCTest
@testable import DiPo

/// What removed features kept on the phone leaves it; nothing else does.
@MainActor
final class RetiredDataTests: XCTestCase {

    private let suite = "RetiredDataTests"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testTheGameKeysGo() {
        defaults.set(Data([1, 2, 3]), forKey: "quest_state_v1")
        defaults.set(41_000, forKey: "game_best_saved")
        defaults.set(2, forKey: "game_plays_2026-10-12")
        defaults.set(1, forKey: "game_plays_2026-10-13")

        RetiredData.forget(in: defaults)

        for key in ["quest_state_v1", "game_best_saved", "game_plays_2026-10-12", "game_plays_2026-10-13"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
    }

    func testTheOtherRetiredKeysGo() {
        let keys = ["sb_dismissed_insights", "sb_seen_coaching", "dipo_id_holidays_manual",
                    "dipo_id_workdays_manual", "addon_navigasi", "navi_trip"]
        for key in keys { defaults.set(["x"], forKey: key) }

        RetiredData.forget(in: defaults)

        for key in keys { XCTAssertNil(defaults.object(forKey: key), key) }
    }

    func testEverythingElseStays() {
        defaults.set("2026-10-29", forKey: "checkin_snoozed_day")
        defaults.set(true, forKey: "sb_enabled")
        defaults.set(["2026-12-25"], forKey: "dipo_id_holidays_network")
        defaults.set(3, forKey: "interest_game_hits")

        RetiredData.forget(in: defaults)

        XCTAssertEqual(defaults.string(forKey: "checkin_snoozed_day"), "2026-10-29")
        XCTAssertTrue(defaults.bool(forKey: "sb_enabled"))
        XCTAssertEqual(defaults.stringArray(forKey: "dipo_id_holidays_network"), ["2026-12-25"])
        XCTAssertEqual(defaults.integer(forKey: "interest_game_hits"), 3, "the hobby interest is not the game")
    }
}
