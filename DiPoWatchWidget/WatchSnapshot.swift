import Foundation

// A copy of the snapshot the watch app keeps in the App Group (see
// "DiPoWatch Watch App/WatchSnapshot.swift" and the app's
// DiPo/WatchSnapshot.swift): the same field names. Only what a complication
// draws is read; the rest is ignored by the decoder.

struct WatchSnapshot: Decodable, Equatable {
    struct Labels: Decodable, Equatable {
        var title: String
    }

    var amount: String
    var over: Bool
    var hidden: Bool
    var living: Double
    var putAway: Double
    var payday: String?
    var labels: Labels

    static let storeKey = "watch.snapshot"
    static let appGroupID = "group.com.fahmiaquinas.DiPo"

    static func stored() -> WatchSnapshot? {
        UserDefaults(suiteName: appGroupID)?
            .data(forKey: storeKey)
            .flatMap { try? JSONDecoder().decode(WatchSnapshot.self, from: $0) }
    }

    /// What is left of income, 0…1, for the circular gauge.
    var leftShare: Double { max(1 - min(max(living, 0), 1) - min(max(putAway, 0), 1), 0) }
}
