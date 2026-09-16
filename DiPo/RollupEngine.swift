import Foundation

// MARK: - Rollup Engine
//
// A pre-aggregation layer for the ledger. Today every screen that shows a
// figure does `cards.flatMap { $0.transactions }.filter { ... }.reduce { ... }`
// — it faults the ENTIRE transaction relationship into memory and walks it
// linearly, on the main thread, on every render (see StatisticsView,
// SmartBudgetManager, HomeView). That is fine at a few thousand rows and starts
// to hitch somewhere in the 10k–50k range a decade-long power user will reach.
//
// This engine turns O(transactions) into O(days-in-range): transactions are
// summed once into per-DAY buckets, and any screen then answers a question by
// adding up the buckets its window covers.
//
// WHY DAILY, NOT MONTHLY. DiPo's primary lens is the PAY CYCLE — [payday, next
// payday) — which crosses calendar-month boundaries (a payday on the 25th makes
// a cycle run e.g. 24 Jul → 24 Aug). A calendar-month bucket therefore cannot
// answer the app's own main question without re-scanning the transactions at
// the month edges. The day is the finest grain that is still tiny (~365/yr,
// ~3.65k/decade) yet can reconstruct ANY date range — pay cycle, calendar
// month, custom — with at most two partial days that never need re-scanning.
// Month-year (for the Firestore backup the app is designed to sync to) is then
// just a GROUPING of these daily buckets, not a separate source of truth.
//
// WHY PER-CURRENCY SUBTOTALS. A posted amount is stored in its own currency and
// converted to the display currency at READ time, deliberately, so a past
// entry never re-values when the FX rate moves (see the FX note on TxRecord).
// If a bucket stored one pre-converted number it would freeze that rate. So
// each bucket keeps a subtotal PER currency, and the reader converts at query
// time with the live rate. This is exact, not an approximation: currency
// conversion is a per-currency scalar (one rate), so converting each currency's
// subtotal and summing equals converting every transaction individually —
//     Σ_tx convert(amtₜₓ, ccyₜₓ→target) = Σ_ccy convert(Σ amt, ccy→target).
//
// WHY DERIVED, NOT INCREMENTED. `daily(from:)` is a pure function of the
// transactions, so the rollup can always be rebuilt from the source of truth
// and can never silently drift from it. Incrementally patching a single bucket
// on each write is a later optimisation layered ON TOP of this, never a
// replacement for it.

// MARK: - Input

/// A minimal, framework-free projection of a `TxRecord`: everything the rollup
/// needs and nothing that ties the maths to SwiftData, so the aggregation is a
/// pure function that can be exercised in isolation. The adapter from a real
/// `TxRecord` lives at the bottom of this file.
///
/// `currency == ""` is meaningful and preserved: legacy rows stored an empty
/// currency, and every reader treats that as "already in the target currency"
/// (`convertedAmount` / `spent` both do `currency.isEmpty ? target : currency`).
struct TxFact: Equatable {
    let date: Date
    /// Signed, in `currency`. Negative = money out, positive = money in.
    let amount: Double
    let currency: String
    /// `TxCategory` rawValue, kept as a String so the engine is independent of
    /// the enum's evolution.
    let category: String
    /// `TxSubtype` rawValue: "normal" | "refund" | "transfer".
    let subtype: String
    /// The card this transaction posted to. The app's main screens are
    /// PER-CARD (Statistics shows the resolved main card; Smart Budget scopes to
    /// it), so buckets carry the card and a reader selects one card's slice.
    /// All-cards figures are the sum across cards. `TxRecord` has no back-link to
    /// its card, so the adapter is handed the id while iterating a card's ledger.
    let cardID: String

    init(date: Date, amount: Double, currency: String, category: String,
         subtype: String, cardID: String = "") {
        self.date = date
        self.amount = amount
        self.currency = currency
        self.category = category
        self.subtype = subtype
        self.cardID = cardID
    }
}

// MARK: - Bucket

/// One day's aggregate. Everything is kept per-currency so the reader applies
/// the live FX rate (see file header). Magnitudes follow the SAME conventions
/// the app already uses in `StatisticsView.filteredExpenses/filteredIncome` and
/// `SmartBudgetManager.spent(in:)`, so numbers read back from a rollup match
/// what those screens compute today, to the rupiah.
struct DailyBucket: Equatable {
    /// The card this bucket belongs to (`TxFact.cardID`). One bucket per
    /// (card, day); an all-cards figure sums buckets across cards.
    let cardID: String
    /// Start-of-day (Calendar.current) this bucket covers.
    let dayStart: Date

    /// Normal income only (amount > 0, subtype normal), by currency. Refunds
    /// are NOT income — they reverse a past expense — and transfers are not
    /// income at all, matching `filteredIncome`.
    var incomeByCurrency: [String: Double] = [:]

    /// Expense magnitude by currency, following `filteredExpenses`/`spent`:
    /// a normal negative amount ADDS |amount|; a refund SUBTRACTS |amount|
    /// (it cancels an earlier expense); a normal positive is income, not spend.
    var expenseByCurrency: [String: Double] = [:]

    /// Signed transfer movement by currency (subtype transfer). Excluded from
    /// income and expenses by design, but it moves the card balance — the piece
    /// that reconciles "net this period" to the balance (see `periodTransferNet`).
    var transferNetByCurrency: [String: Double] = [:]

    /// Expense magnitude split by category, keyed by `CatCur`. Same expense
    /// model as `expenseByCurrency`, mirroring `categoryBreakdown` on the
    /// expenses tab.
    var expenseByCategory: [CatCur: Double] = [:]

    /// Income split by category (normal, amount > 0), mirroring
    /// `categoryBreakdown` on the income tab.
    var incomeByCategory: [CatCur: Double] = [:]

    /// GROSS expense split by category: every non-transfer outflow (amount < 0),
    /// with refunds NOT subtracted. This is the convention the Smart Budget
    /// views use (`overGroups`/`currentCycleSnapshot` filter `amount < 0`), kept
    /// alongside the refund-netted `expenseByCategory` so a rollup can reproduce
    /// either convention without committing the whole app to one.
    var grossExpenseByCategory: [CatCur: Double] = [:]

    /// GROSS inflow by currency: every non-transfer amount ≥ 0 (normal income
    /// AND refunds). HomeView's month-flow counts any positive as "income", a
    /// looser rule than `incomeByCurrency` (normal only) — keeping both lets the
    /// rollup match either screen.
    var grossInflowByCurrency: [String: Double] = [:]

    /// Every transaction that fell on this day, transfers included — a cheap
    /// change-signal, matching `statTxCount`.
    var txCount: Int = 0
}

/// A (category, currency) pair. A struct key rather than a `"cat|ccy"` string so
/// no separator can ever collide with a category or currency value.
struct CatCur: Hashable {
    let category: String
    let currency: String
}

// MARK: - Reader result

/// Totals for a set of buckets, already converted into one target currency.
struct RollupTotals: Equatable {
    var income: Double = 0
    var expenses: Double = 0
    var transferNet: Double = 0
    /// Category rawValue → expense magnitude (target currency), positives only
    /// are meaningful to display; a fully-refunded category can be ≤ 0.
    var expenseByCategory: [String: Double] = [:]
    /// Category rawValue → income (target currency).
    var incomeByCategory: [String: Double] = [:]
    /// Category rawValue → gross expense (target currency), refunds not netted.
    var grossExpenseByCategory: [String: Double] = [:]
    /// Total gross expense (target currency): every non-transfer outflow.
    var grossExpense: Double = 0
    /// Total gross inflow (target currency): every non-transfer amount ≥ 0.
    var grossInflow: Double = 0
    var txCount: Int = 0
}

// MARK: - Engine

enum RollupEngine {

    /// Fold transactions into one bucket per (card, calendar day).
    ///
    /// `calendar` is injectable only so tests can pin a timezone; production
    /// always passes `.current`, matching every screen that slices by date.
    static func daily(from facts: [TxFact], calendar: Calendar = .current) -> [DailyBucket] {
        struct Key: Hashable { let cardID: String; let day: Date }
        var byKey: [Key: DailyBucket] = [:]

        for f in facts {
            let day = calendar.startOfDay(for: f.date)
            let key = Key(cardID: f.cardID, day: day)
            var b = byKey[key] ?? DailyBucket(cardID: f.cardID, dayStart: day)
            let ccy = f.currency
            let mag = abs(f.amount)

            if f.subtype == "transfer" {
                // Movement between the user's own accounts: not spend, not
                // income — only the signed balance movement is kept.
                b.transferNetByCurrency[ccy, default: 0] += f.amount
            } else {
                // Expense model (identical to filteredExpenses / spent):
                if f.subtype == "refund" {
                    b.expenseByCurrency[ccy, default: 0] -= mag
                    b.expenseByCategory[CatCur(category: f.category, currency: ccy), default: 0] -= mag
                } else if f.amount < 0 {
                    b.expenseByCurrency[ccy, default: 0] += mag
                    b.expenseByCategory[CatCur(category: f.category, currency: ccy), default: 0] += mag
                }
                // Gross expense: any non-transfer outflow, refunds not netted.
                if f.amount < 0 {
                    b.grossExpenseByCategory[CatCur(category: f.category, currency: ccy), default: 0] += mag
                }
                // Gross inflow: any non-transfer amount >= 0 (HomeView counts a
                // refund's positive amount as income too).
                if f.amount >= 0 {
                    b.grossInflowByCurrency[ccy, default: 0] += f.amount
                }
                // Income model (identical to filteredIncome): normal & positive.
                if f.subtype == "normal" && f.amount > 0 {
                    b.incomeByCurrency[ccy, default: 0] += f.amount
                    b.incomeByCategory[CatCur(category: f.category, currency: ccy), default: 0] += f.amount
                }
            }

            b.txCount += 1
            byKey[key] = b
        }

        return byKey.values.sorted {
            $0.dayStart != $1.dayStart ? $0.dayStart < $1.dayStart : $0.cardID < $1.cardID
        }
    }

    /// Sum a set of buckets into one target currency.
    ///
    /// `convert` is injected (`CurrencyManager.shared.convert` in the app, a
    /// fixed-rate stub in tests). An empty currency key means "already in the
    /// target currency" and is passed through unconverted, matching every
    /// reader in the app.
    static func totals(for buckets: [DailyBucket],
                       targetCurrency: String,
                       convert: (Double, String, String) -> Double) -> RollupTotals {
        func toTarget(_ amount: Double, _ from: String) -> Double {
            if amount == 0 { return 0 }
            let src = from.isEmpty ? targetCurrency : from
            return src == targetCurrency ? amount : convert(amount, src, targetCurrency)
        }

        var out = RollupTotals()
        for b in buckets {
            for (ccy, v) in b.incomeByCurrency   { out.income      += toTarget(v, ccy) }
            for (ccy, v) in b.expenseByCurrency  { out.expenses    += toTarget(v, ccy) }
            for (ccy, v) in b.transferNetByCurrency { out.transferNet += toTarget(v, ccy) }
            for (key, v) in b.expenseByCategory  {
                out.expenseByCategory[key.category, default: 0] += toTarget(v, key.currency)
            }
            for (key, v) in b.incomeByCategory   {
                out.incomeByCategory[key.category, default: 0] += toTarget(v, key.currency)
            }
            for (key, v) in b.grossExpenseByCategory {
                let converted = toTarget(v, key.currency)
                out.grossExpenseByCategory[key.category, default: 0] += converted
                out.grossExpense += converted
            }
            for (ccy, v) in b.grossInflowByCurrency { out.grossInflow += toTarget(v, ccy) }
            out.txCount += b.txCount
        }
        return out
    }

    /// Buckets for one card (or all cards when `cardID` is nil) whose day falls
    /// inside `[start, end]` — the closed range the date-bounded screens use
    /// (`$0.date >= start && $0.date <= end`). Cheap linear filter over the small
    /// bucket set; a persisted rollup will instead fetch this by an indexed date
    /// predicate.
    static func buckets(_ buckets: [DailyBucket],
                        cardID: String? = nil,
                        in range: ClosedRange<Date>) -> [DailyBucket] {
        buckets.filter {
            (cardID == nil || $0.cardID == cardID!)
                && $0.dayStart >= range.lowerBound && $0.dayStart <= range.upperBound
        }
    }

    /// Buckets for one card (or all cards) from `start` onward, with NO upper
    /// bound — the exact window `SmartBudgetManager.spent(in:)` uses
    /// (`$0.date >= monthStart`). Because there is no `end`, whole-day buckets
    /// reproduce that filter exactly, with no partial-edge day to reconcile.
    static func buckets(_ buckets: [DailyBucket],
                        cardID: String? = nil,
                        from start: Date) -> [DailyBucket] {
        buckets.filter {
            (cardID == nil || $0.cardID == cardID!) && $0.dayStart >= start
        }
    }

    // MARK: Backup grouping

    /// Group daily buckets by "yyyy-MM" — the stable, timezone-portable key for
    /// a per-month backup document (the grain the Firestore/DB sync is designed
    /// around). Calendar months, NOT pay cycles: a storage key must not move
    /// when the user changes their salary day, or every past bucket would be
    /// orphaned. Pay-cycle math stays in the app layer, reading daily buckets.
    static func groupByMonth(_ buckets: [DailyBucket], calendar: Calendar = .current) -> [String: [DailyBucket]] {
        Dictionary(grouping: buckets) { monthKey(for: $0.dayStart, calendar: calendar) }
    }

    /// "yyyy-MM" for a date, in the given calendar's timezone. Built from
    /// components (not a locale-formatted string) so the language setting can
    /// never change the key.
    static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}

// MARK: - Adapter

extension TxFact {
    /// Project a stored transaction into a `TxFact`. Reads the raw stored
    /// strings (`categoryRaw`, `subtype`) directly so no enum round-trip or
    /// localisation is involved. `cardID` is supplied by the caller because
    /// `TxRecord` holds no back-reference to its owning card — the store builds
    /// facts while iterating each `BankCard.transactions`.
    init(_ tx: TxRecord, cardID: String) {
        self.init(date: tx.date,
                  amount: tx.amount,
                  currency: tx.currency,
                  category: tx.categoryRaw,
                  subtype: tx.subtype,
                  cardID: cardID)
    }
}
