import Foundation

// MARK: - What removed features left on the phone
//
// Each key below belongs to code that is gone, so nothing reads it again:
// - the DiPo game (DiPo Quest and DiPo Lari Hemat): the quest's record, the
//   runner's best score, and a play count for each day played;
// - the Smart Insight banner's "dismiss" and first-time coaching flags;
// - the hand-entered holidays and working days, which nothing ever filled;
// - DiPo Navigasi: its add-on switch and the trip under way.
// They go at launch. Once a phone has none left, this is one look over the
// app's own keys.

enum RetiredData {
    static func forget(in defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where isRetired(key) {
            defaults.removeObject(forKey: key)
        }
    }

    private static let keys: Set<String> = [
        "quest_state_v1", "game_best_saved",
        "sb_dismissed_insights", "sb_seen_coaching",
        "dipo_id_holidays_manual", "dipo_id_workdays_manual",
        "addon_navigasi", "navi_trip",
    ]

    static func isRetired(_ key: String) -> Bool {
        keys.contains(key) || key.hasPrefix("game_plays_")
    }
}
