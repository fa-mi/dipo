import Foundation
import SwiftData

// MARK: - DailyRollup (persistence) + RollupStore (cache)
//
// The durable and in-memory halves of the pre-aggregation layer described in
// RollupEngine.swift. `DailyRollup` is one persisted row per active day;
// `RollupStore` keeps the same buckets in memory as the fast read structure and
// is the single place that (re)builds both from the source of truth.
//
// The rollup is a PURE FUNCTION of the ledger (`RollupEngine.daily`), so a full
// rebuild can never silently drift from the transactions. Incremental single-day
// patching is a later optimisation layered on top — never a replacement for the
// ability to recompute from scratch.

@Model
final class DailyRollup {
    /// "cardID|yyyy-MM-dd" (Calendar.current). Unique so a (card, day) is stored
    /// once — the app's screens are per-card, so the bucket is too.
    @Attribute(.unique) var dayKey: String
    /// The owning card's id (`BankCard.id.uuidString`). A real stored field so a
    /// persisted query can scope to one card.
    var cardID: String
    /// Start-of-day — a real stored Date so a persisted query can filter a date
    /// range with an index (added when reads move onto the store).
    var dayStart: Date

    // Per-currency subtotals: the FX rate is applied at READ time so a posted
    // figure is never re-valued when the rate moves (see RollupEngine header).
    var incomeByCurrency: [String: Double]
    var expenseByCurrency: [String: Double]
    var transferNetByCurrency: [String: Double]

    /// Category breakdowns, keyed "category|currency". A category rawValue and a
    /// currency code never contain "|", so the first "|" splits them cleanly.
    var expenseByCategory: [String: Double]
    var incomeByCategory: [String: Double]
    /// Gross expense (refunds not netted) — the convention the Smart Budget
    /// views use. Defaulted so adding it is a lightweight, additive migration.
    var grossExpenseByCategory: [String: Double] = [:]
    /// Gross inflow by currency (every non-transfer amount >= 0) — HomeView's
    /// month-flow income rule. Defaulted for a lightweight, additive migration.
    var grossInflowByCurrency: [String: Double] = [:]

    var txCount: Int
    var updatedAt: Date

    init(_ b: DailyBucket) {
        self.dayKey = DailyRollup.key(cardID: b.cardID, day: b.dayStart)
        self.cardID = b.cardID
        self.dayStart = b.dayStart
        self.incomeByCurrency = b.incomeByCurrency
        self.expenseByCurrency = b.expenseByCurrency
        self.transferNetByCurrency = b.transferNetByCurrency
        self.expenseByCategory = DailyRollup.encodeCats(b.expenseByCategory)
        self.incomeByCategory = DailyRollup.encodeCats(b.incomeByCategory)
        self.grossExpenseByCategory = DailyRollup.encodeCats(b.grossExpenseByCategory)
        self.grossInflowByCurrency = b.grossInflowByCurrency
        self.txCount = b.txCount
        self.updatedAt = .now
    }

    /// Overwrite with a recomputed bucket for the same (card, day).
    func update(from b: DailyBucket) {
        incomeByCurrency = b.incomeByCurrency
        expenseByCurrency = b.expenseByCurrency
        transferNetByCurrency = b.transferNetByCurrency
        expenseByCategory = DailyRollup.encodeCats(b.expenseByCategory)
        incomeByCategory = DailyRollup.encodeCats(b.incomeByCategory)
        grossExpenseByCategory = DailyRollup.encodeCats(b.grossExpenseByCategory)
        grossInflowByCurrency = b.grossInflowByCurrency
        txCount = b.txCount
        updatedAt = .now
    }

    static func key(cardID: String, day: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%@|%04d-%02d-%02d", cardID, c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func encodeCats(_ d: [CatCur: Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (k, v) in d { out["\(k.category)|\(k.currency)"] = v }
        return out
    }

    private static func decodeCats(_ d: [String: Double]) -> [CatCur: Double] {
        var out: [CatCur: Double] = [:]
        for (k, v) in d {
            guard let i = k.firstIndex(of: "|") else { continue }
            out[CatCur(category: String(k[..<i]), currency: String(k[k.index(after: i)...]))] = v
        }
        return out
    }

    /// Rebuild the in-memory bucket from a persisted row, so a cold start can
    /// seed the cache without touching the transaction table.
    func toBucket() -> DailyBucket {
        DailyBucket(cardID: cardID,
                    dayStart: dayStart,
                    incomeByCurrency: incomeByCurrency,
                    expenseByCurrency: expenseByCurrency,
                    transferNetByCurrency: transferNetByCurrency,
                    expenseByCategory: DailyRollup.decodeCats(expenseByCategory),
                    incomeByCategory: DailyRollup.decodeCats(incomeByCategory),
                    grossExpenseByCategory: DailyRollup.decodeCats(grossExpenseByCategory),
                    grossInflowByCurrency: grossInflowByCurrency,
                    txCount: txCount)
    }
}

// MARK: - Store

@MainActor
final class RollupStore {
    static let shared = RollupStore()
    private init() {}

    /// The in-memory daily buckets screens read (fast: O(days-in-range)).
    private(set) var buckets: [DailyBucket] = []

    // What the last rebuild saw, so the next one can redo only the days a
    // change touched. Rebuilding everything re-read every transaction's
    // fields — 0,8 s for a busy five-year ledger — each time one was added.
    private var factsByID: [PersistentIdentifier: TxFact] = [:]
    private var idsByCard: [String: Set<PersistentIdentifier>] = [:]
    /// Transactions on each (card, day), keyed like `DailyRollup.dayKey`.
    private var idsByDay: [String: Set<PersistentIdentifier>] = [:]
    private var bucketsByKey: [String: DailyBucket] = [:]

    /// The transaction count the cache was built at — a cheap staleness signal,
    /// the same one StatisticsView uses (`statTxCount`). An edit that keeps the
    /// count but changes an amount is picked up on the next launch rebuild, the
    /// same limitation the on-screen memoization already has.
    private(set) var builtAtTxCount: Int = -1

    /// Launch entry point: seed from the persisted rollups when they are
    /// consistent with the ledger, otherwise recompute. Cheap on a normal
    /// launch (no re-scan, no store churn); self-healing when they diverge.
    func loadOrRebuild(context: ModelContext) {
        let txCount = (try? context.fetchCount(FetchDescriptor<TxRecord>())) ?? 0
        let rows = (try? context.fetch(FetchDescriptor<DailyRollup>())) ?? []
        let persistedTx = rows.reduce(0) { $0 + $1.txCount }
        if !rows.isEmpty, persistedTx == txCount {
            buckets = rows.map { $0.toBucket() }.sorted { $0.dayStart < $1.dayStart }
            builtAtTxCount = txCount
        } else {
            rebuild(context: context)
        }
    }

    /// Recompute buckets from the source of truth and mirror them to the store.
    @discardableResult
    func rebuild(context: ModelContext) -> [DailyBucket] {
        // Iterate cards, not TxRecord directly: a transaction has no back-link
        // to its card, and the app's figures are per-card, so each fact is
        // tagged with the card whose ledger it sits in.
        let cards = (try? context.fetch(FetchDescriptor<BankCard>())) ?? []
        factsByID = [:]; idsByCard = [:]; idsByDay = [:]
        var facts: [TxFact] = []
        for card in cards {
            let cid = card.id.uuidString
            var ids = Set<PersistentIdentifier>()
            for tx in card.transactions {
                let f = TxFact(tx, cardID: cid)
                let id = tx.persistentModelID
                facts.append(f)
                factsByID[id] = f
                ids.insert(id)
                idsByDay[DailyRollup.key(cardID: cid, day: f.date), default: []].insert(id)
            }
            idsByCard[cid] = ids
        }
        let computed = RollupEngine.daily(from: facts)
        buckets = computed
        bucketsByKey = Dictionary(computed.map { (DailyRollup.key(cardID: $0.cardID, day: $0.dayStart), $0) },
                                  uniquingKeysWith: { a, _ in a })
        builtAtTxCount = facts.count
        persist(computed, context: context)
        return computed
    }

    /// Bring the rollup up to date by redoing only the (card, day) buckets
    /// whose transactions were added or removed since the last build. Reads
    /// each transaction's identity, which is cheap, and the fields of only the
    /// new ones. Falls back to a full rebuild when there is nothing to diff
    /// against yet (first build since launch).
    @discardableResult
    func update(context: ModelContext) -> [DailyBucket] {
        guard builtAtTxCount >= 0, !idsByCard.isEmpty || builtAtTxCount == 0 else {
            return rebuild(context: context)
        }
        let cards = (try? context.fetch(FetchDescriptor<BankCard>())) ?? []
        var touched = Set<String>()
        var seenCards = Set<String>()
        for card in cards {
            let cid = card.id.uuidString
            seenCards.insert(cid)
            var current = Set<PersistentIdentifier>()
            for tx in card.transactions {
                let id = tx.persistentModelID
                current.insert(id)
                if factsByID[id] == nil {
                    let f = TxFact(tx, cardID: cid)
                    factsByID[id] = f
                    let key = DailyRollup.key(cardID: cid, day: f.date)
                    idsByDay[key, default: []].insert(id)
                    touched.insert(key)
                }
            }
            for gone in (idsByCard[cid] ?? []).subtracting(current) {
                forget(gone, touched: &touched)
            }
            idsByCard[cid] = current
        }
        for (cid, ids) in idsByCard where !seenCards.contains(cid) {
            for gone in ids { forget(gone, touched: &touched) }
            idsByCard[cid] = nil
        }
        builtAtTxCount = factsByID.count
        guard !touched.isEmpty else { return buckets }

        for key in touched {
            let facts = (idsByDay[key] ?? []).compactMap { factsByID[$0] }
            if let b = RollupEngine.daily(from: facts).first { bucketsByKey[key] = b } else { bucketsByKey[key] = nil }
        }
        buckets = bucketsByKey.values.sorted { $0.dayStart < $1.dayStart }
        persist(keys: touched, context: context)
        return buckets
    }

    private func forget(_ id: PersistentIdentifier, touched: inout Set<String>) {
        guard let f = factsByID.removeValue(forKey: id) else { return }
        let key = DailyRollup.key(cardID: f.cardID, day: f.date)
        idsByDay[key]?.remove(id)
        if idsByDay[key]?.isEmpty == true { idsByDay[key] = nil }
        touched.insert(key)
    }

    /// Save just the given days' rows.
    private func persist(keys: Set<String>, context: ModelContext) {
        let wanted = Array(keys)
        let rows = (try? context.fetch(FetchDescriptor<DailyRollup>(
            predicate: #Predicate { wanted.contains($0.dayKey) }))) ?? []
        var byKey: [String: DailyRollup] = [:]
        for row in rows {
            if byKey[row.dayKey] != nil { context.delete(row) } else { byKey[row.dayKey] = row }
        }
        for key in keys {
            switch (bucketsByKey[key], byKey[key]) {
            case let (b?, row?): row.update(from: b)
            case let (b?, nil):  context.insert(DailyRollup(b))
            case let (nil, row?): context.delete(row)
            case (nil, nil):     break
            }
        }
        try? context.save()
    }

    /// Rebuild only when the transaction count changed since the cache was
    /// built. Consumers call this when their own change-signal fires, so the
    /// cache is fresh at read time without a rebuild on every render.
    @discardableResult
    func rebuildIfStale(context: ModelContext, txCount: Int) -> [DailyBucket] {
        txCount == builtAtTxCount ? buckets : update(context: context)
    }

    private func persist(_ computed: [DailyBucket], context: ModelContext) {
        // Only the days that changed. A full delete-and-insert of every row
        // (≈1.800 a card for five years) on each new transaction was most of
        // a rebuild's cost — over a second for a busy five-year ledger, on the
        // main thread, every time a transaction was added. Adding one now
        // touches one row.
        let existing = (try? context.fetch(FetchDescriptor<DailyRollup>())) ?? []
        var byKey: [String: DailyRollup] = [:]
        for row in existing {
            if byKey[row.dayKey] != nil { context.delete(row) } else { byKey[row.dayKey] = row }
        }
        var changed = false
        var kept = Set<String>()
        for b in computed {
            let key = DailyRollup.key(cardID: b.cardID, day: b.dayStart)
            kept.insert(key)
            if let row = byKey[key] {
                if row.toBucket() != b {
                    row.update(from: b)
                    changed = true
                }
            } else {
                context.insert(DailyRollup(b))
                changed = true
            }
        }
        for (key, row) in byKey where !kept.contains(key) {
            context.delete(row)
            changed = true
        }
        if changed || existing.count != byKey.count { try? context.save() }
    }
}
