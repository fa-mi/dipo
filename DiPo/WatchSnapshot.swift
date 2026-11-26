import Foundation

// MARK: - What the Apple Watch shows
//
// The watch answers two things: how much is left of this period, and "log
// what I just spent". It keeps no ledger of its own. The phone sends it this
// snapshot over WatchConnectivity (WatchBridge) whenever it refreshes the
// widgets, and the watch sends back entries (WatchEntry), which the phone
// saves to the main card the way the Siri intent does.
//
// The watch app and its complication decode this with copies of the same
// fields ("DiPoWatch Watch App/WatchSnapshot.swift" and
// "DiPoWatchWidget/WatchSnapshot.swift"); WatchSnapshotTests pins the names.
// Every word is resolved here, in the app's language, so the watch needs no
// string tables of its own.

struct WatchSnapshot: Codable, Equatable {

    /// A category offered for logging: the ones this person uses most.
    struct Category: Codable, Equatable {
        /// TxCategory.rawValue, sent back with an entry.
        var raw: String
        var label: String
        var hex: String
        var symbol: String
    }

    struct Labels: Codable, Equatable {
        /// "Sisa periode", "Lebih dari pemasukan" or "Belanja periode ini".
        var title: String
        var log: String
        /// "%@ untuk apa?"
        var forWhat: String
        var saved: String
        /// "di %@, lewat iPhone"
        var savedTo: String
        var pending: String
        var noCard: String
    }

    /// What is left of the period (or spent, without income), formatted.
    var amount: String
    /// Past income: the amount is how far over, said in orange.
    var over: Bool
    /// Hidden on Home: the watch hides it too.
    var hidden: Bool
    /// Home's period line, as shares of income.
    var living: Double
    var putAway: Double
    var today: Double?
    /// "6 hari lagi gajian"
    var payday: String?
    /// "±Rp 250.000 per hari": what is left, spread over the days to payday.
    var perDay: String?
    var categories: [Category]
    /// The main card's currency: an amount typed on the watch is in it.
    var currency: String
    /// Where an entry goes, as Siri names it; nil when there is no main card.
    var cardName: String?
    var labels: Labels
    var updated: Date

    /// The key the snapshot travels under in the application context.
    static let contextKey = "snapshot"

    /// The categories offered when there is no history to learn from.
    static let starterCategories: [TxCategory] = [.food, .transport, .shopping, .bills]

    /// - Parameters:
    ///   - detail: the large widget's period (WidgetDataSync), Home's line.
    ///   - income, expenses: the period's, as the widget shows them.
    ///   - history: rows to learn the most-used categories from.
    static func make(detail: WidgetPeriodDetail, income: Double, expenses: Double,
                     daysToPayday: Int?, currency: String, main: BankCard?, cards: [BankCard],
                     history: [TxRecord], now: Date = Date()) -> WatchSnapshot {
        let money = { CurrencyManager.shared.formatted($0, currency: currency) }
        let hasIncome = income >= 0.5
        let left = income - expenses
        let over = hasIncome && left < -0.5

        let title: String
        if !hasIncome { title = loc("watch.spent") }
        else { title = loc(over ? "watch.over" : "watch.left") }

        var perDay: String?
        if hasIncome, left >= 0.5, let days = daysToPayday {
            perDay = String(format: loc("watch.per_day"), money(left / Double(max(days, 1))))
        }

        return WatchSnapshot(
            amount: money(hasIncome ? abs(left) : expenses),
            over: over,
            hidden: main.map { DiPoIntentSupport.balancesHidden(main: $0, cards: cards) } ?? false,
            living: detail.living,
            putAway: detail.putAway,
            today: detail.today,
            payday: detail.payday,
            perDay: perDay,
            categories: mostUsed(in: history, now: now).map {
                Category(raw: $0.rawValue, label: $0.displayLabel, hex: $0.iconBg, symbol: $0.icon)
            },
            currency: main?.resolvedCurrency ?? currency,
            cardName: main.map { DiPoIntentSupport.spokenName($0, among: cards) },
            labels: Labels(
                title: title,
                log: loc("watch.log"),
                forWhat: loc("watch.for_what"),
                saved: loc("watch.saved"),
                savedTo: loc("watch.saved_to"),
                pending: loc("watch.pending"),
                noCard: loc("watch.no_card")),
            updated: now)
    }

    /// The four everyday categories logged most often in the last 90 days,
    /// topped up from the starter set: the watch's grid has four places.
    static func mostUsed(in history: [TxRecord], now: Date = Date()) -> [TxCategory] {
        let since = now.addingTimeInterval(-90 * 86_400)
        var counts: [TxCategory: Int] = [:]
        for tx in history where tx.date >= since && tx.date <= now
            && tx.amount < 0 && tx.txSubtype == .normal
            && ExpenseCategory.categories.contains(tx.category) {
            counts[tx.category, default: 0] += 1
        }
        var picked = counts.sorted { a, b in
            a.value != b.value ? a.value > b.value : a.key.rawValue < b.key.rawValue
        }.map(\.key)
        for starter in starterCategories where !picked.contains(starter) { picked.append(starter) }
        return Array(picked.prefix(4))
    }
}

// MARK: - What the watch sends back

/// One expense logged on the watch.
struct WatchEntry: Codable, Equatable {
    /// Made on the watch; the phone saves each id once.
    var id: String
    /// In the snapshot's `currency`, positive.
    var amount: Double
    /// TxCategory.rawValue, from the snapshot's categories.
    var category: String
    var at: Date

    /// The key an entry travels under in a user-info transfer.
    static let userInfoKey = "entry"
}
