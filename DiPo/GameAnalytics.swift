import Foundation
import FirebaseAnalytics
import FirebaseFirestore

// MARK: - Game analytics
//
// What the games need for retention and churn analysis, under the same rules
// as ScreenAnalytics: a fixed list of events, numbers that describe the game
// only (unit, level, a perfect flag), never an amount, a merchant or anything
// typed — and nothing at all unless the backend has switched analytics on.
//
// Two places, for two readers:
// • Firebase Analytics gets the event. Once collection is on, Firebase builds
//   day-1/7/30 retention cohorts from it on its own, pseudonymously.
// • Firestore `analytics_game` gets an aggregate count per event and level,
//   no user id, so the DiPo admin page can draw the level funnel: where
//   players start, finish, run out of hearts or give up.

enum GameEvent: String, CaseIterable {
    case levelStart = "quest_level_start"
    case levelComplete = "quest_level_complete"
    /// Out of hearts.
    case levelFail = "quest_level_fail"
    case levelQuit = "quest_level_quit"
    case dailyChest = "quest_daily_chest"
    case unitChest = "quest_unit_chest"
    case runPlayed = "run_played"
}

enum GameAnalytics {
    static func log(_ event: GameEvent, level: QuestLevel? = nil, unit: Int? = nil, perfect: Bool? = nil) {
        guard ScreenAnalytics.shared.isEnabled else { return }
        let unit = level?.unit ?? unit
        var params: [String: Any] = [:]
        if let unit { params["unit"] = unit }
        if let level { params["level"] = level.index }
        if let perfect { params["perfect"] = perfect ? 1 : 0 }
        Analytics.logEvent(event.rawValue, parameters: params.isEmpty ? nil : params)
        Firestore.firestore()
            .collection("analytics_game").document(counterID(event, level: level, unit: unit))
            .setData(["count": FieldValue.increment(Int64(1)), "lastAt": FieldValue.serverTimestamp()], merge: true)
    }

    /// "quest_level_start_u1l2", "quest_daily_chest", "quest_unit_chest_u3".
    static func counterID(_ event: GameEvent, level: QuestLevel?, unit: Int?) -> String {
        if let level { return "\(event.rawValue)_\(level.id)" }
        if let unit { return "\(event.rawValue)_u\(unit)" }
        return event.rawValue
    }
}
