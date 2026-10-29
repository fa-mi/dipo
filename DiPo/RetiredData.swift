import Foundation

// MARK: - What a removed feature left on the phone
//
// The DiPo game (DiPo Quest and DiPo Lari Hemat) kept its progress in
// UserDefaults: the quest's one record, the runner's best score, and a play
// count for each day played. The game is gone, so its keys go too, at launch.
// Once a phone has none left, this is one look over the app's own keys.

enum RetiredData {
    static func forget(in defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where isGame(key) {
            defaults.removeObject(forKey: key)
        }
    }

    static func isGame(_ key: String) -> Bool {
        key == "quest_state_v1" || key == "game_best_saved" || key.hasPrefix("game_plays_")
    }
}
