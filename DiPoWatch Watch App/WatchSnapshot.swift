import Foundation

// MARK: - What the iPhone sends
//
// A copy of the app's DiPo/WatchSnapshot.swift: the same field names, which
// are the contract (WatchSnapshotTests in the app checks them). Every word in
// it is already in the person's language.

struct WatchSnapshot: Decodable, Equatable {
    struct Category: Decodable, Equatable, Hashable {
        var raw: String
        var label: String
        var hex: String
        var symbol: String
    }

    struct Labels: Decodable, Equatable {
        var title: String
        var log: String
        var forWhat: String
        var saved: String
        var savedTo: String
        var pending: String
        var noCard: String
    }

    var amount: String
    var over: Bool
    var hidden: Bool
    var living: Double
    var putAway: Double
    var today: Double?
    var payday: String?
    var perDay: String?
    var categories: [Category]
    var currency: String
    var cardName: String?
    var labels: Labels
    var updated: Date

    static let contextKey = "snapshot"
    /// Where the watch keeps the latest one, for its complications.
    static let storeKey = "watch.snapshot"
    static let appGroupID = "group.com.fahmiaquinas.DiPo"
}

// MARK: - What the watch sends

struct WatchEntry: Encodable, Equatable {
    var id: String
    var amount: Double
    var category: String
    var at: Date

    static let userInfoKey = "entry"
}

// MARK: - Before the iPhone has sent anything

/// The few words the watch needs on its own, before the first snapshot.
enum WatchCopy {
    static var isIndonesian: Bool {
        (Locale.preferredLanguages.first ?? "id").hasPrefix("id")
    }

    static var openPhone: String {
        isIndonesian ? "Buka DiPo di iPhone sekali untuk mulai."
                     : "Open DiPo on your iPhone once to start."
    }

    static var done: String { isIndonesian ? "Selesai" : "Done" }
}

/// An amount typed on the watch, as DiPo writes money: "Rp 25.000".
enum WatchMoney {
    static func text(_ value: Double, currency: String) -> String {
        let code = currency.uppercased()
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: code == "IDR" ? "id_ID" : "en_US")
        f.maximumFractionDigits = code == "IDR" ? 0 : 2
        let number = f.string(from: NSNumber(value: value)) ?? String(Int(value))
        return code == "IDR" ? "Rp \(number)" : "\(code) \(number)"
    }
}
