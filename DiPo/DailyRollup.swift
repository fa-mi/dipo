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
    /// "yyyy-MM-dd" (Calendar.current). Unique so a day is stored once.
    @Attribute(.unique) var dayKey: String
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

    var txCount: Int
    var updatedAt: Date

    init(_ b: DailyBucket) {
        self.dayKey = DailyRollup.key(for: b.dayStart)
        self.dayStart = b.dayStart
        self.incomeByCurrency = b.incomeByCurrency
        self.expenseByCurrency = b.expenseByCurrency
        self.transferNetByCurrency = b.transferNetByCurrency
        self.expenseByCategory = DailyRollup.encodeCats(b.expenseByCategory)
        self.incomeByCategory = DailyRollup.encodeCats(b.incomeByCategory)
        self.txCount = b.txCount
        self.updatedAt = .now
    }

    static func key(for day: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
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
        DailyBucket(dayStart: dayStart,
                    incomeByCurrency: incomeByCurrency,
                    expenseByCurrency: expenseByCurrency,
                    transferNetByCurrency: transferNetByCurrency,
                    expenseByCategory: DailyRollup.decodeCats(expenseByCategory),
                    incomeByCategory: DailyRollup.decodeCats(incomeByCategory),
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
        let txs = (try? context.fetch(FetchDescriptor<TxRecord>())) ?? []
        let computed = RollupEngine.daily(from: txs.map(TxFact.init))
        buckets = computed
        builtAtTxCount = txs.count
        persist(computed, context: context)
        return computed
    }

    /// Rebuild only when the transaction count changed since the cache was
    /// built. Consumers call this when their own change-signal fires, so the
    /// cache is fresh at read time without a rebuild on every render.
    @discardableResult
    func rebuildIfStale(context: ModelContext, txCount: Int) -> [DailyBucket] {
        txCount == builtAtTxCount ? buckets : rebuild(context: context)
    }

    private func persist(_ computed: [DailyBucket], context: ModelContext) {
        // Full replace. One row per active day is a tiny set (~365/yr), so a
        // wholesale swap is simpler to reason about than a per-day diff and the
        // cost is negligible next to the transaction scan that produced it.
        let existing = (try? context.fetch(FetchDescriptor<DailyRollup>())) ?? []
        for row in existing { context.delete(row) }
        for b in computed { context.insert(DailyRollup(b)) }
        try? context.save()
    }
}
