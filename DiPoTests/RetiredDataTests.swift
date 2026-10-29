import XCTest
@testable import DiPo

/// The removed game's progress leaves the phone; nothing else does.
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

    func testEverythingElseStays() {
        defaults.set("2026-10-29", forKey: "checkin_snoozed_day")
        defaults.set(true, forKey: "sb_enabled")
        defaults.set(3, forKey: "interest_game_hits")

        RetiredData.forget(in: defaults)

        XCTAssertEqual(defaults.string(forKey: "checkin_snoozed_day"), "2026-10-29")
        XCTAssertTrue(defaults.bool(forKey: "sb_enabled"))
        XCTAssertEqual(defaults.integer(forKey: "interest_game_hits"), 3, "the hobby interest is not the game")
    }
}
