import SwiftUI
import SwiftData

// MARK: - Statistics Date Period

enum StatPeriod: String, CaseIterable {
    case thisMonth  = "This Month"
    case lastMonth  = "Last month"
    case payCycle   = "Pay cycle"
    case last3      = "3 months"
    case last6      = "6 months"
    case thisYear   = "This year"
    case allTime    = "All time"
    case custom     = "Custom"

    /// Localized label for UI. rawValue stays English for internal logic.
    var title: String {
        switch self {
        case .thisMonth:  return loc("stats.period.this_month")
        case .lastMonth:  return loc("stats.period.last_month")
        case .payCycle:   return loc("stats.period.pay_cycle")
        case .last3:      return loc("stats.period.3months")
        case .last6:      return loc("stats.period.6months")
        case .thisYear:   return loc("stats.period.this_year")
        case .allTime:    return loc("stats.period.all_time")
        case .custom:     return loc("stats.period.custom")
        }
    }

    func dateRange() -> (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .thisMonth:
            let start = cal.safeDate(from: cal.dateComponents([.year, .month], from: now))
            return (start, now)
        case .lastMonth:
            let thisMonthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: now))
            let start = cal.safeDate(byAdding: .month, value: -1, to: thisMonthStart)
            return (start, thisMonthStart)
        case .payCycle:
            // Fallback anchor = 1st of month. The view overrides this with the
            // real payday via `StatPeriod.payCycleRange(payDay:)`; this branch
            // only runs if there's no active salary schedule to anchor on.
            let start = cal.safeDate(from: cal.dateComponents([.year, .month], from: now))
            return (start, now)
        case .last3:
            return (cal.safeDate(byAdding: .month, value: -3, to: now), now)
        case .last6:
            return (cal.safeDate(byAdding: .month, value: -6, to: now), now)
        case .thisYear:
            let start = cal.safeDate(from: cal.dateComponents([.year], from: now))
            return (start, now)
        case .allTime:
            return (Date.distantPast, now)
        case .custom:
            return (now, now) // overridden by custom state
        }
    }

    /// Pay-cycle window (payday → now) anchored on a day-of-month. e.g. payday
    /// 25 → the current cycle runs from the 25th of this-or-last month up to
    /// today. Months without the exact day are handled by clamping the anchor
    /// to the 28th so short months never skip it (fine for the common 1–28
    /// paydays).
    static func payCycleRange(payDay: Int, now: Date = Date()) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let month = cal.component(.month, from: today)
        let year  = cal.component(.year,  from: today)

        // Anchor on the ACTUAL pay date — the same business-day-adjusted date
        // the payday banner shows. Using the raw day-of-month meant that when
        // payday fell on a weekend and the salary was pulled earlier (e.g. paid
        // Fri 24th for a 25th payday), the budget cycle did NOT roll over on the
        // day you were actually paid: the new salary landed inside the OLD
        // cycle, so Home said "Payday is TODAY" while the budget still showed
        // last cycle's spending.
        let thisMonthPay = cal.startOfDay(
            for: SalaryDateEngine.actualPayDate(dayOfMonth: payDay, month: month, year: year))
        if today >= thisMonthPay { return (thisMonthPay, now) }

        let prevMonth = month == 1 ? 12 : month - 1
        let prevYear  = month == 1 ? year - 1 : year
        let lastPay = cal.startOfDay(
            for: SalaryDateEngine.actualPayDate(dayOfMonth: payDay, month: prevMonth, year: prevYear))
        return (lastPay, now)
    }
}

// MARK: - Statistics View

struct StatisticsView: View {
    @State var statsVM: StatsViewModel
    let appVM: AppViewModel
    @Query private var cardBudgetConfigs: [CardBudgetConfig]
    @Query(sort: \SalarySchedule.createdAt) private var salarySchedules: [SalarySchedule]
    @State private var selectedPeriod: StatPeriod = .thisMonth
    /// Held in @State so SwiftUI observes plan changes; reading
    /// `PremiumManager.shared` inline inside `body` registers no dependency,
    /// leaving a user who just upgraded stuck behind the blur until they
    /// navigate away and back.
    @State private var premiumMgr = PremiumManager.shared
    /// Guards the one-time "default to pay cycle" so it can't override a manual
    /// period choice on later re-appears.
    @State private var didDefaultPeriod = false
    // Memoized heavy derivations. `filteredTx` was recomputed by EVERY derived
    // property (income, expenses, weekly avg, categories, list) — the date
    // filter ran ~6× per render. `netWorthTrend` scans all tx across 6 buckets.
    // We now compute both once, only when inputs change (see recomputeStats).
    @State private var cachedFilteredTx: [TxRecord] = []
    @State private var cachedNetWorthTrend: [(label: String, value: Double)] = []
    @State private var customStart: Date = Calendar.current.safeDate(byAdding: .month, value: -1, to: Date())
    @State private var customEnd: Date = Date()
    @State private var showCustomPicker = false
    @State private var selectedCardID: String? = nil // Will auto-select first card on appear
    @State private var showExportSheet = false
    @State private var showTidy = false

    /// Count of "Other" expenses the categoriser could confidently re-map.
    private var tidyableCount: Int {
        appVM.cards.flatMap { $0.transactions }.reduce(0) { count, tx in
            guard tx.amount < 0, tx.txSubtype == .normal, tx.category == .other,
                  let s = SmartBudgetManager.suggestCategory(for: tx.name, txType: "Expense"), s != .other
            else { return count }
            return count + 1
        }
    }

    /// Day-of-month the salary lands on (from the first active schedule), used
    /// to anchor the "Pay cycle" period. nil when the user has no active
    /// salary — in which case the Pay-cycle option is hidden entirely.
    private var payCycleDay: Int? {
        salarySchedules.first(where: { $0.isActive })?.dayOfMonth
    }

    /// Income for BUDGET MATH in the export insight: the stated salary schedule
    /// when there is one (so a pre-payday period doesn't distort the ratio),
    /// otherwise actual income received in the period.
    private var budgetInsightIncome: Double {
        let active = salarySchedules.filter { $0.isActive }
        guard !active.isEmpty else { return filteredIncome }
        return active.reduce(0.0) { $0 + CurrencyManager.shared.convert($1.amount, from: $1.currency, to: displayCurrency) }
    }

    /// Periods shown as chips. "Pay cycle" only appears when there's a salary
    /// schedule to anchor it on; otherwise it would be meaningless.
    private var availablePeriods: [StatPeriod] {
        StatPeriod.allCases.filter { $0 != .payCycle || payCycleDay != nil }
    }

    private var effectiveRange: (start: Date, end: Date) {
        if selectedPeriod == .custom { return (customStart, customEnd) }
        if selectedPeriod == .payCycle, let day = payCycleDay {
            return StatPeriod.payCycleRange(payDay: day)
        }
        return selectedPeriod.dateRange()
    }

    /// How far through the selected period we are, 0…1 — nil for finished
    /// periods. Without it, "73% saved" on day 8 of a 30-day cycle reads as an
    /// achievement when it just means the month hasn't happened yet.
    private var periodProgress: (elapsed: Int, total: Int)? {
        let cal = Calendar.current
        let (start, end) = effectiveRange
        // A period that already ended needs no caveat.
        guard end > Date() || cal.isDateInToday(end) else { return nil }
        let total = max(cal.dateComponents([.day], from: start, to: cal.date(byAdding: .month, value: 1, to: start) ?? end).day ?? 30, 1)
        let elapsed = min(max((cal.dateComponents([.day], from: start, to: Date()).day ?? 0) + 1, 1), total)
        return elapsed >= total ? nil : (elapsed, total)
    }

    /// Income over the same elapsed length one period back.
    private var previousPeriodIncome: Double? {
        previousPeriodTotal(positive: true)
    }
    /// Same length of time, one period earlier — the only fair thing to compare
    /// a running period against.
    private var previousPeriodExpenses: Double? { previousPeriodTotal(positive: false) }

    private func previousPeriodTotal(positive: Bool) -> Double? {
        let cal = Calendar.current
        let (start, _) = effectiveRange
        guard let prevStart = cal.date(byAdding: .month, value: -1, to: start) else { return nil }
        let cutoff: Date = {
            guard let p = periodProgress else { return start }
            return cal.date(byAdding: .day, value: p.elapsed, to: prevStart) ?? start
        }()
        let tx = (selectedCard?.transactions ?? []).filter {
            $0.date >= prevStart && $0.date < cutoff && $0.txSubtype != .transfer
                && (positive ? $0.amount > 0 : $0.amount < 0)
        }
        guard !tx.isEmpty else { return nil }
        return tx.reduce(0.0) { $0 + abs(convertedAmount($1)) }
    }


    /// Lock overlay shown on top of the blurred Smart Insights card for
    /// free users. Crown + "upgrade" affordance — tapping anywhere on the
    /// card opens the Royal paywall.
    private var lockedInsightsOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(AppTheme.bg.opacity(0.35))
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(AppTheme.purple.opacity(0.15)).frame(width: 46, height: 46)
                    Image(systemName: "crown.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AppTheme.purple)
                }
                Text(loc("stats.insights"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold))
                    Text(loc("stats.insights_locked"))
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(AppTheme.purple)
            }
        }
    }

    // NOTE: Removed unused `allTx` property — it returned txs across all cards
    // without currency conversion. Use `filteredTx` (per-card) instead.

    private var periodSubtitle: String {
        let locale = LanguageManager.shared.currentLocale
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.dateFormat = DateFormatter.dateFormat(fromTemplate: "dMMMMyyyy", options: 0, locale: locale)
        if selectedPeriod == .custom {
            return "\(fmt.string(from: customStart)) – \(fmt.string(from: customEnd))"
        }
        // Use effectiveRange so the pay-cycle window (payday → today) shows its
        // real anchored dates, not the calendar-month fallback.
        let (start, end) = effectiveRange
        if selectedPeriod == .allTime { return loc("stats.all_tx") }
        if selectedPeriod == .thisMonth || selectedPeriod == .lastMonth {
            let mfmt = DateFormatter()
            mfmt.locale = locale
            mfmt.dateFormat = DateFormatter.dateFormat(fromTemplate: "MMMMyyyy", options: 0, locale: locale)
            return mfmt.string(from: start)
        }
        return "\(fmt.string(from: start)) – \(fmt.string(from: end))"
    }

    // NOTE: Removed unconverted `income`, `expenses`, `netBalance` properties.
    // They aggregated tx.amount across ALL cards in raw currency (no conversion),
    // which produced absurd results when the selected card uses a different
    // currency. Use `filteredIncome`, `filteredExpenses` (per-card, converted)
    // instead. See line 144-150.
    
    // MARK: - Card Filter & Analytics
    
    /// Cards that actually moved money in the selected period. Used for
    /// defaults and for dimming — NOT for hiding.
    private var cardsWithActivity: [BankCard] {
        // Compute the range ONCE (it was recomputed for every transaction of
        // every card — O(cards × tx) range calls).
        let (start, end) = effectiveRange
        return appVM.cards.filter { card in
            card.transactions.contains { $0.date >= start && $0.date <= end }
        }
    }

    /// Every card the user has. The picker used to list only cards with
    /// activity in the period, so on a cycle that just began nine accounts
    /// silently collapsed to one and it looked like the others had vanished.
    /// "No spending on this card" is information too — show the chip, mark it
    /// quiet, and let the user look.
    private var availableCards: [BankCard] { appVM.cards }

    private func hasActivity(_ card: BankCard) -> Bool {
        let (start, end) = effectiveRange
        return card.transactions.contains { $0.date >= start && $0.date <= end }
    }
    
    /// The currently-selected card (resolved from selectedCardID).
    private var selectedCard: BankCard? {
        guard let cardID = selectedCardID else { return nil }
        return appVM.cards.first(where: { $0.id.uuidString == cardID })
    }
    
    /// The currency used to display all stats. Always derived from the selected card —
    /// stats show in the card's native currency, with cross-currency tx converted via CurrencyManager.
    private var displayCurrency: String {
        selectedCard?.resolvedCurrency ?? CurrencyManager.shared.preferredCurrency
    }
    
    /// Transactions belonging to the selected card, within the selected period.
    /// Reads the memoized cache — populated by `recomputeStats()`.
    private var filteredTx: [TxRecord] { cachedFilteredTx }

    /// Total transaction count across cards — cheap change-signal that triggers
    /// a stats recompute when a tx is added/removed.
    private var statTxCount: Int { appVM.cards.reduce(0) { $0 + $1.transactions.count } }

    private func computeFilteredTx() -> [TxRecord] {
        guard let card = selectedCard else { return [] }
        let (start, end) = effectiveRange
        return card.transactions.filter { $0.date >= start && $0.date <= end }
    }

    /// Recompute the memoized heavy derivations. Called on appear and whenever
    /// period / card / custom dates / tx count change — never per render.
    private func recomputeStats() {
        cachedFilteredTx = computeFilteredTx()
        cachedNetWorthTrend = computeNetWorthTrend()
    }
    
    /// Convert a tx amount to the display currency (the selected card's currency).
    /// Handles legacy tx where currency may differ from card's currency.
    private func convertedAmount(_ tx: TxRecord) -> Double {
        let txCurrency = tx.currency.isEmpty ? displayCurrency : tx.currency
        return CurrencyManager.shared.convert(tx.amount, from: txCurrency, to: displayCurrency)
    }
    
    /// Net movement from transfers & CC payments within the period. Excluded
    /// from income/expenses by design, but they DO move the card balance — this
    /// is the missing piece that reconciles "net this period" to the balance.
    private var periodTransferNet: Double {
        filteredTx.filter { $0.txSubtype == .transfer }
            .reduce(0.0) { $0 + convertedAmount($1) }
    }

    /// Card balance at the START of the period: seed + every tx before it.
    private var periodStartBalance: Double? {
        guard let card = selectedCard else { return nil }
        let (start, _) = effectiveRange
        let before = card.transactions.filter { $0.date < start }
            .reduce(0.0) { $0 + convertedAmount($1) }
        return card.balance + before
    }

    /// Income for the period — counts NORMAL income tx only. Refunds have
    /// positive amount too but represent reversal of past expenses (not new
    /// income); including them would inflate income and produce misleading
    /// "great savings rate!" cards. Transfers are inter-account movement,
    /// not income at all.
    private var filteredIncome: Double {
        filteredTx
            .filter { $0.amount > 0 && $0.txSubtype == .normal }
            .reduce(0) { $0 + convertedAmount($1) }
    }

    /// Expenses for the period. Skip transfers (movement between user's own
    /// accounts, not real spend) and SUBTRACT refunds (refund cancels an
    /// earlier expense in the same category). Same model the SmartBudget
    /// engine uses in `spent(in:)` so card balance, stats, and budget all
    /// agree on the numbers.
    private var filteredExpenses: Double {
        filteredTx
            .filter { $0.txSubtype != .transfer }
            .reduce(0.0) { sum, tx in
                let amt = abs(convertedAmount(tx))
                if tx.txSubtype == .refund { return sum - amt }
                return tx.amount < 0 ? sum + amt : sum
            }
    }
    
    private var weeklyAverage: Double {
        let (start, end) = effectiveRange
        let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 1
        let weeks = max(Double(days) / 7.0, 0.1)
        // Exclude FIXED MONTHLY commitments — bills (rent, subscriptions,
        // utilities), investments, and debt payments. These are paid once a
        // month, so averaging them into a "per week" figure hugely inflates it
        // and misrepresents day-to-day spending. Only variable/discretionary
        // spend (food, transport, shopping, health, travel, other) is counted.
        let fixed: Set<TxCategory> = [.bills, .investment, .debtPayment, .commitment]
        let variable = filteredTx
            .filter { $0.txSubtype != .transfer && !fixed.contains($0.category) }
            .reduce(0.0) { sum, tx in
                let amt = abs(convertedAmount(tx))
                if tx.txSubtype == .refund { return sum - amt }
                return tx.amount < 0 ? sum + amt : sum
            }
        return variable / weeks
    }

    /// Number of whole days spanned by the current period.
    private var periodDays: Int {
        let (start, end) = effectiveRange
        return max(Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0, 0)
    }

    /// A window under ~2 weeks doesn't hold enough data for a stable weekly
    /// pace — dividing a front-loaded, still-in-progress span (e.g. a pay
    /// cycle 8 days in) by fractional weeks inflates the figure. Flag those so
    /// the UI marks the weekly average as a partial estimate.
    private var isPartialWeeklyPeriod: Bool {
        periodDays < 14
    }
    
    private var topCategories: [(category: TxCategory, amount: Double, percentage: Double)] {
        // Same subtype-aware logic as filteredExpenses: skip transfers
        // entirely, subtract refunds from their category. Without this a
        // user who refunded Rp 800rb in Shopping still sees Shopping as the
        // top category — visually wrong since the money came back.
        var totals: [TxCategory: Double] = [:]
        for tx in filteredTx where tx.txSubtype != .transfer {
            let amt = abs(convertedAmount(tx))
            if tx.txSubtype == .refund {
                totals[tx.category, default: 0] -= amt
            } else if tx.amount < 0 {
                totals[tx.category, default: 0] += amt
            }
        }
        // Drop categories that net to ≤0 (refunds outweigh spend) — they're
        // not "top expenses" in any meaningful sense.
        totals = totals.filter { $0.value > 0 }
        let total = totals.values.reduce(0, +)
        guard total > 0 else { return [] }
        
        return totals
            .map { (category: $0.key, amount: $0.value, percentage: ($0.value / total) * 100) }
            .sorted { $0.amount > $1.amount }
            .prefix(5)
            .map { $0 }
    }

    /// Last 6 periods of net balance for the trend chart (selected card, display
    /// currency). When the user has a salary schedule, the buckets follow the
    /// PAY CYCLE (payday→payday) instead of the calendar month — otherwise the
    /// current calendar month reads falsely negative (salary landed on the 25th
    /// of the *previous* month, so a fresh calendar month has expenses but no
    /// income yet).
    private var netWorthTrend: [(label: String, value: Double)] { cachedNetWorthTrend }

    private func computeNetWorthTrend() -> [(label: String, value: Double)] {
        let cal = Calendar.current
        let now = Date()
        let locale = LanguageManager.shared.currentLocale
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.dateFormat = DateFormatter.dateFormat(fromTemplate: "MMM", options: 0, locale: locale)
        var points: [(label: String, value: Double)] = []

        // Bucket boundaries: pay-cycle anchored (start of current cycle, then
        // step back a month at a time) or calendar-month.
        let bucketStarts: [(start: Date, end: Date)] = {
            var out: [(Date, Date)] = []
            if let day = payCycleDay {
                let currentStart = StatPeriod.payCycleRange(payDay: day).start
                for offset in stride(from: -5, through: 0, by: 1) {
                    let s = cal.safeDate(byAdding: .month, value: offset, to: currentStart)
                    let e = cal.safeDate(byAdding: .month, value: 1, to: s)
                    out.append((s, e))
                }
            } else {
                for offset in stride(from: -5, through: 0, by: 1) {
                    let s = cal.safeDate(from: cal.dateComponents([.year, .month],
                        from: cal.safeDate(byAdding: .month, value: offset, to: now)))
                    let e = cal.safeDate(byAdding: .month, value: 1, to: s)
                    out.append((s, e))
                }
            }
            return out
        }()

        guard let card = selectedCard else {
            // Label a pay-cycle bucket by the month it ends in (the "salary
            // month"); a calendar bucket by its own month.
            return bucketStarts.map { (fmt.string(from: payCycleDay != nil ? $0.end : $0.start), 0) }
        }
        for (s, e) in bucketStarts {
            let net = card.transactions
                .filter { $0.date >= s && $0.date < e && $0.txSubtype != .transfer }
                .reduce(0.0) { $0 + convertedAmount($1) }
            points.append((fmt.string(from: payCycleDay != nil ? e : s), net))
        }
        // Drop months that pre-date the account's first transaction. Rendering
        // them as placeholder tracks filled a third of the chart with bars for
        // periods that never existed — a two-month history should look like two
        // months, not like four empty ones and a spike.
        if let firstReal = points.firstIndex(where: { $0.value != 0 }) {
            points = Array(points[firstReal...])
        }
        return points
    }

    /// Assembled pattern rows. Each one only appears when the data genuinely
    /// supports it — an empty section beats a padded one.
    private var patternRows: [(icon: String, tint: Color, title: String, detail: String)] {
        var out: [(String, Color, String, String)] = []
        let cm = CurrencyManager.shared

        if let projected = projectedSpend, let p = periodProgress {
            let overIncome = filteredIncome > 0 && projected > filteredIncome
            out.append((
                "chart.line.uptrend.xyaxis",
                overIncome ? AppTheme.orange : AppTheme.accent,
                String(format: loc("stats.pattern.pace"), cm.formatted(projected, currency: displayCurrency)),
                overIncome
                    ? String(format: loc("stats.pattern.pace_over"),
                             cm.formatted(projected - filteredIncome, currency: displayCurrency), p.total)
                    : String(format: loc("stats.pattern.pace_ok"), p.total)
            ))
        }
        if let day = costliestWeekday {
            out.append((
                "calendar",
                AppTheme.blue,
                String(format: loc("stats.pattern.weekday"), day.name),
                String(format: loc("stats.pattern.weekday_sub"),
                       cm.formatted(day.average, currency: displayCurrency))
            ))
        }
        if let quiet = noSpendDays, quiet.count > 0 {
            out.append((
                "leaf.fill",
                AppTheme.accent,
                String(format: loc("stats.pattern.quiet"), quiet.count),
                String(format: loc("stats.pattern.quiet_sub"), quiet.of)
            ))
        }
        if let big = biggestExpense {
            let amt = abs(convertedAmount(big))
            let share = filteredExpenses > 0 ? Int((amt / filteredExpenses * 100).rounded()) : 0
            out.append((
                "arrow.up.right.circle.fill",
                AppTheme.textSecondary,
                String(format: loc("stats.pattern.biggest"), big.name),
                String(format: loc("stats.pattern.biggest_sub"),
                       cm.formatted(amt, currency: displayCurrency), share)
            ))
        }
        return out
    }

    /// Projected spend by the end of a running period, straight-line from the
    /// pace so far. Nil once the period is over — a finished period needs no
    /// forecast, it has a result.
    private var projectedSpend: Double? {
        guard let p = periodProgress, p.elapsed > 0, filteredExpenses > 0 else { return nil }
        return filteredExpenses / Double(p.elapsed) * Double(p.total)
    }

    /// The weekday that costs the most on average. Needs at least two of that
    /// weekday, otherwise a single big Saturday would masquerade as a pattern.
    private var costliestWeekday: (name: String, average: Double)? {
        let cal = Calendar.current
        var totals: [Int: (sum: Double, days: Set<Date>)] = [:]
        for tx in filteredTx where tx.amount < 0 && tx.txSubtype == .normal {
            let wd = cal.component(.weekday, from: tx.date)
            let day = cal.startOfDay(for: tx.date)
            var entry = totals[wd] ?? (0, [])
            entry.sum += abs(convertedAmount(tx))
            entry.days.insert(day)
            totals[wd] = entry
        }
        let ranked = totals.compactMap { wd, v -> (Int, Double, Int)? in
            guard v.days.count >= 2 else { return nil }
            return (wd, v.sum / Double(v.days.count), v.days.count)
        }.sorted { $0.1 > $1.1 }
        guard let top = ranked.first else { return nil }
        let fmt = DateFormatter()
        fmt.locale = LanguageManager.shared.currentLocale
        // weekdaySymbols is 0-indexed from Sunday; Calendar's weekday is 1-based.
        let name = fmt.weekdaySymbols[max(top.0 - 1, 0)]
        return (name, top.1)
    }

    /// Days in the elapsed period with no spending at all — the one metric here
    /// that rewards restraint instead of measuring damage.
    private var noSpendDays: (count: Int, of: Int)? {
        guard let p = periodProgress else { return nil }
        let cal = Calendar.current
        let spentDays = Set(filteredTx
            .filter { $0.amount < 0 && $0.txSubtype == .normal }
            .map { cal.startOfDay(for: $0.date) })
        return (max(p.elapsed - spentDays.count, 0), p.elapsed)
    }

    /// Single largest outflow — the anchor a list of five recent rows never gave.
    private var biggestExpense: TxRecord? {
        filteredTx.filter { $0.amount < 0 && $0.txSubtype == .normal }
            .max { abs(convertedAmount($0)) < abs(convertedAmount($1)) }
    }

    private var realCategories: [SpendCategory] {
        // Subtype-aware bar chart data: transfer skipped, refund subtracted
        // from its bucket. Without this a heavily-refunded month shows
        // inflated bars in the chart that don't match the income/expense
        // totals above (which are subtype-aware).
        var totals: [TxCategory: Double] = [:]
        for tx in filteredTx where tx.txSubtype != .transfer {
            let amt = abs(convertedAmount(tx))
            let isExpenseTab = statsVM.selectedStatTab == .expenses
            if isExpenseTab {
                if tx.txSubtype == .refund {
                    totals[tx.category, default: 0] -= amt
                } else if tx.amount < 0 {
                    totals[tx.category, default: 0] += amt
                }
            } else {
                // Income tab: only normal positive tx counts (refund is
                // not income even though stored as positive amount).
                if tx.txSubtype == .normal && tx.amount > 0 {
                    totals[tx.category, default: 0] += amt
                }
            }
        }
        return TxCategory.allCases.compactMap { cat in
            guard let amt = totals[cat], amt > 0 else { return nil }
            return SpendCategory(name: cat.displayLabel, amount: amt, color: cat.color)
        }
    }

    private var realTotal: Double { realCategories.reduce(0) { $0 + $1.amount } }

    private var displayedTx: [TxRecord] {
        // List view still shows ALL transactions including refund/transfer
        // so the user can see them in chronological order. Only the
        // aggregated numbers (income/expenses/categories) filter by subtype.
        // This keeps the audit trail visible.
        let base = statsVM.selectedStatTab == .expenses
            ? filteredTx.filter { $0.amount < 0 }
            : filteredTx.filter { $0.amount > 0 }
        // Sort newest-first — the section is labelled "Recent", but
        // `card.transactions` is in insertion order, so `prefix(5)` was
        // showing arbitrary rows, not the latest ones.
        return base.sorted { $0.date > $1.date }
    }
    
    /// Compact card label for filter pills and exports.
    /// Digital wallet → provider name. Card → holder + last4.
    func cardLabel(_ card: BankCard) -> String {
        if card.isDigitalWallet, !card.walletProvider.isEmpty {
            return card.walletProvider
        }
        let holder = card.holderName.split(separator: " ").first.map(String.init) ?? card.holderName
        return "\(holder) ••\(card.last4)"
    }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Title
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc("stats.title")).font(.system(size: 24, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                            Text(periodSubtitle).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                        Button {
                            HapticManager.shared.tap()
                            showExportSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 18))
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 44, height: 44)
                                .background(AppTheme.accent.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)

                    // Period picker — a single quiet chip that opens a menu.
                    // A row of five filled pills competed with the numbers for
                    // attention and ate a whole band of the screen; the period
                    // is context, not the content.
                    HStack {
                        Menu {
                            ForEach(availablePeriods, id: \.self) { period in
                                Button {
                                    HapticManager.shared.tap()
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                        selectedPeriod = period
                                        statsVM.selectedSliceIndex = nil
                                        statsVM.animateIn()
                                        if period == .custom { showCustomPicker = true }
                                    }
                                } label: {
                                    if selectedPeriod == period {
                                        Label(period.title, systemImage: "checkmark")
                                    } else {
                                        Text(period.title)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(selectedPeriod.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            .padding(.horizontal, 13).padding(.vertical, 8)
                            .background(AppTheme.cardDark, in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)

                    // Card filter — user must select a specific card (no aggregation across currencies)
                    if !availableCards.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                // Individual cards only — no "All Cards" aggregation
                                ForEach(availableCards, id: \.id) { card in
                                    Button {
                                        HapticManager.shared.tap()
                                        withAnimation(.spring(response: 0.3)) {
                                            selectedCardID = card.id.uuidString
                                            statsVM.selectedSliceIndex = nil
                                            statsVM.animateIn()
                                        }
                                    } label: {
                                        let isSelected = selectedCardID == card.id.uuidString
                                        let quiet = !hasActivity(card)
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(Color(hex: card.gradientStart))
                                                .frame(width: 8, height: 8)
                                                .opacity(quiet && !isSelected ? 0.35 : 1)
                                            Text(cardLabel(card))
                                                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                                .lineLimit(1)
                                        }
                                        .foregroundStyle(isSelected ? .white
                                                         : AppTheme.textSecondary.opacity(quiet ? 0.5 : 1))
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .background(isSelected ? Color(hex: card.gradientStart) : AppTheme.cardDark, in: Capsule())
                                        .overlay(Capsule().stroke(AppTheme.cardMid.opacity(quiet && !isSelected ? 0.5 : 0), lineWidth: 1))
                                    }
                                    .buttonStyle(ScaleButtonStyle())
                                }
                            }
                            .padding(.horizontal, 22)
                        }
                        .padding(.top, 10)
                    }

                    // Tidy "Other" chip — surfaces when uncategorised expenses
                    // could be auto-fixed, so they stop skewing Daily/Lifestyle.
                    if tidyableCount > 0 {
                        Button {
                            HapticManager.shared.tap(); showTidy = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .semibold))
                                Text(String(format: loc("tidy.chip"), tidyableCount)).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(AppTheme.purple)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(AppTheme.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.purple.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .padding(.horizontal, 22).padding(.top, 16)
                    }

                    // Summary cards
                    CashflowCard(income: filteredIncome, expenses: filteredExpenses,
                                 previousIncome: previousPeriodIncome,
                                 previousExpenses: previousPeriodExpenses,
                                 currency: displayCurrency)
                        .padding(.horizontal, 22)
                        .padding(.top, 16)

                    // Net balance card
                    NetBalanceSummary(net: filteredIncome - filteredExpenses, income: filteredIncome, expenses: filteredExpenses, currency: displayCurrency,
                                      cardBalanceNow: selectedCard?.computedBalance(),
                                      startBalance: periodStartBalance,
                                      transferNet: periodTransferNet,
                                      progress: periodProgress,
                                      previousExpenses: previousPeriodExpenses)
                        .padding(.horizontal, 22)
                        .padding(.top, 10)

                    // Net worth trend — 6 month sparkline
                    NetWorthTrendCard(trend: netWorthTrend,
                                      subtitle: payCycleDay != nil ? loc("stats.net_worth_sub_cycle") : loc("stats.net_worth_sub"))
                        .padding(.horizontal, 22)
                        .padding(.top, 12)
                    
                    // Smart Insights Card — Weekly avg + Top Category.
                    // Royal-only feature. Free users get a blurred teaser
                    // that opens the paywall on tap (same pattern as the
                    // Home Screen widget's locked-insights treatment).
                    if filteredExpenses > 0 {
                        let insightsCard = SmartInsightsCard(
                            weeklyAverage: weeklyAverage,
                            topCategories: topCategories,
                            totalExpenses: filteredExpenses,
                            currency: displayCurrency,
                            isPartialPeriod: isPartialWeeklyPeriod,
                            periodDays: periodDays
                        )
                        if premiumMgr.canAccess(.smartBudget) {
                            insightsCard
                                .padding(.horizontal, 22)
                                .padding(.top, 12)
                        } else {
                            insightsCard
                                // Blur the real data — the user sees the
                                // shape of the insight but can't read it.
                                .blur(radius: 7)
                                .allowsHitTesting(false)
                                .overlay { lockedInsightsOverlay }
                                .padding(.horizontal, 22)
                                .padding(.top, 12)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    HapticManager.shared.tap()
                                    // Reuses the paywall notification that
                                    // MainTabView already listens for.
                                    NotificationCenter.default.post(
                                        name: .requestOpenPaywall, object: nil)
                                }
                        }
                    }

                    StatSegmentPicker(vm: statsVM)
                        .padding(.horizontal, 22)
                        .padding(.top, 20)

                    if realCategories.isEmpty {
                        // Empty state with direct CTA to Add Transaction.
                        // Without the CTA the user reads "no expenses yet"
                        // and has to figure out the central "+" tab is what
                        // adds them. Linking from here makes the workflow
                        // obvious — and MainTabView's listener auto-switches
                        // to Home on save so the new tx is visible afterwards.
                        VStack(spacing: 14) {
                            Image(systemName: statsVM.selectedStatTab == .expenses ? "cart" : "arrow.down.circle")
                                .font(.system(size: 40))
                                .foregroundStyle(AppTheme.textSecondary)
                                .gentleFloat()
                            Text(String(format: loc("stats.title_empty"), statsVM.selectedStatTab.localizedLabel.lowercased()))
                                .font(.system(size: 16)).foregroundStyle(AppTheme.textSecondary)
                            Text(loc("stats.empty"))
                                .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary.opacity(0.7))

                            Button {
                                HapticManager.shared.tap()
                                NotificationCenter.default.post(name: .requestOpenAddTransaction, object: nil)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus.circle.fill").font(.system(size: 14))
                                    Text(loc("home.add_first_tx")).font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .background(AppTheme.accent.opacity(0.12), in: Capsule())
                                .overlay(Capsule().stroke(AppTheme.accent.opacity(0.3), lineWidth: 1))
                            }
                            .buttonStyle(ScaleButtonStyle())
                            .padding(.top, 4)
                        }
                        .padding(.top, 48)
                    } else {
                        CategoryDonutChart(
                            categories: realCategories,
                            total: realTotal,
                            currency: displayCurrency,
                            statsVM: statsVM
                        )
                        .padding(.horizontal, 22)
                        .padding(.top, 20)
                    }

                    // Patterns — forward-looking and behavioural. The old
                    // "Recent Expenses" list here repeated Home's transaction
                    // feed without adding anything Statistics should own.
                    if statsVM.selectedStatTab == .expenses && !patternRows.isEmpty
                        && premiumMgr.canAccess(.smartBudget) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(loc("stats.patterns"))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .padding(.bottom, 12)

                            VStack(spacing: 0) {
                                ForEach(Array(patternRows.enumerated()), id: \.offset) { i, row in
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: row.icon)
                                            .font(.system(size: 14))
                                            .foregroundStyle(row.tint)
                                            .frame(width: 22)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(row.title)
                                                .font(.system(size: 13.5, weight: .semibold))
                                                .foregroundStyle(AppTheme.textPrimary)
                                                .fixedSize(horizontal: false, vertical: true)
                                            Text(row.detail)
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(AppTheme.textSecondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .lineSpacing(1.5)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 12)
                                    if i < patternRows.count - 1 {
                                        Divider().background(AppTheme.cardMid.opacity(0.5))
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 24)
                    }

                    Spacer(minLength: 110)
                }
            }
        }
        .onAppear {
            statsVM.animateIn()
            // Default the period to the pay cycle (payday → today) when the
            // user has a salary schedule — their financial month runs from
            // payday, not the calendar 1st. One-time so it never overrides a
            // manual choice.
            if !didDefaultPeriod {
                didDefaultPeriod = true
                if payCycleDay != nil { selectedPeriod = .payCycle }
            }
            // Auto-select first available card if none is selected.
            // Statistics is always per-card to avoid mixing currencies.
            if selectedCardID == nil, let first = (cardsWithActivity.first ?? availableCards.first) {
                selectedCardID = first.id.uuidString
            }
            // Populate the memoized derivations before reading realCategories.
            recomputeStats()
            // Update categories with real data on appear
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                statsVM.categories = realCategories.isEmpty
                    ? [SpendCategory(name: "No data", amount: 1, color: AppTheme.textSecondary)]
                    : realCategories
            }
        }
        // StatisticsView lives in MainTabView's ZStack and is mounted ONCE at
        // app launch (tab switching only toggles opacity). That means
        // `.onAppear` fires before the user adds their first transaction —
        // at that point `availableCards` is empty so `selectedCardID` stays
        // nil. When transactions are added later from another tab, the body
        // re-evaluates (SwiftData @Observable) and `availableCards` recomputes
        // with the new card, BUT `selectedCardID` is never updated → the
        // summary shows Rp 0 / Rp 0 even though the data is there.
        // This onChange catches the "first card became available" transition
        // and auto-selects it. Keyed by `count` so we don't churn on every
        // tx insert into an already-selected card.
        .onChange(of: cardsWithActivity.count) { _, newCount in
            if selectedCardID == nil, newCount > 0,
               let first = cardsWithActivity.first {
                selectedCardID = first.id.uuidString
            }
        }
        .onChange(of: statsVM.selectedStatTab) { _, _ in
            statsVM.selectedSliceIndex = nil
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: selectedPeriod) { _, _ in
            statsVM.selectedSliceIndex = nil
            // If selected card has no tx in new period, auto-switch to a card that does
            if selectedCardID == nil, let first = (cardsWithActivity.first ?? availableCards.first) {
                selectedCardID = first.id.uuidString
            }
            recomputeStats()
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: selectedCardID) { _, _ in
            statsVM.selectedSliceIndex = nil
            recomputeStats()
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: customStart) { _, _ in
            recomputeStats()
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: customEnd) { _, _ in
            recomputeStats()
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        // A tx added/removed anywhere → refresh the memoized derivations.
        .onChange(of: statTxCount) { _, _ in
            recomputeStats()
            withAnimation { statsVM.categories = realCategories }
        }
        .sheet(isPresented: $showCustomPicker) {
            CustomDateRangeSheet(startDate: $customStart, endDate: $customEnd)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showExportSheet) {
            StatsExportSheet(
                period: selectedPeriod,
                periodSubtitle: periodSubtitle,
                selectedCard: selectedCard,
                income: filteredIncome,
                budgetIncome: budgetInsightIncome,
                expenses: filteredExpenses,
                // Royal-only figures. The Smart Insights card on screen blurs
                // these behind the paywall, but the export handed them over in
                // plain text — tap Share and a free user could read exactly
                // what the blur was hiding. Withhold the data itself rather
                // than hiding it in the layout.
                weeklyAverage: premiumMgr.canAccess(.smartBudget) ? weeklyAverage : 0,
                topCategories: premiumMgr.canAccess(.smartBudget) ? topCategories : [],
                transactions: filteredTx,
                currency: displayCurrency,
                configs: cardBudgetConfigs
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.bg)
            .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showTidy) {
            TidyCategoriesView(cards: appVM.cards)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }
}

// MARK: - Summary Cards

/// Income and expenses in one calm card, each with how it moved versus the
/// same stretch of the previous period. Two separately-bordered boxes made the
/// top of the screen loud and said nothing about direction.
struct CashflowCard: View {
    let income: Double
    let expenses: Double
    let previousIncome: Double?
    let previousExpenses: Double?
    let currency: String

    private func delta(_ now: Double, _ before: Double?) -> Double? {
        guard let before, before > 0 else { return nil }
        return (now - before) / before * 100
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column(loc("stats.income"), income, delta(income, previousIncome),
                   upIsGood: true, dot: AppTheme.accent)
            Rectangle().fill(AppTheme.cardMid.opacity(0.5))
                .frame(width: 1, height: 40)
                .padding(.horizontal, 6)
            column(loc("stats.expenses"), expenses, delta(expenses, previousExpenses),
                   upIsGood: false, dot: AppTheme.red)
        }
        .padding(.vertical, 16).padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
    }

    private func column(_ title: String, _ amount: Double, _ change: Double?,
                        upIsGood: Bool, dot: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(title).font(.system(size: 11.5)).foregroundStyle(AppTheme.textSecondary)
            }
            Text(CurrencyManager.shared.formatted(amount, currency: currency))
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.7)
            if let change {
                let up = change >= 0
                let good = up == upIsGood
                HStack(spacing: 3) {
                    Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(String(format: "%.0f%%", abs(change)))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(good ? AppTheme.accent : AppTheme.red)
            } else {
                // Keeps both columns the same height when one side has no
                // history to compare against.
                Text(" ").font(.system(size: 11, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NetBalanceSummary: View {
    let net: Double
    let income: Double
    let expenses: Double
    let currency: String
    /// The selected card's CUMULATIVE balance (what Home shows). Rendered as a
    /// footer so period-flow and account-stock sit side by side — users kept
    /// reading "Net this period" as the card balance and reporting a "bug".
    var cardBalanceNow: Double? = nil
    /// Balance at the period's start + net transfer movement — together with
    /// `net` they RECONCILE exactly to the card balance:
    /// start + net + transfers = balance. Nil hides the breakdown.
    var startBalance: Double? = nil
    var transferNet: Double? = nil
    /// Day N of M when the period is still running. Nil for finished periods.
    var progress: (elapsed: Int, total: Int)? = nil
    /// Spending over the same number of days one period ago.
    var previousExpenses: Double? = nil

    private func chip(_ icon: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private var spentPct: Double {
        guard income > 0 else { return 0 }
        return min((expenses / income) * 100, 100)
    }
    
    private var savedPct: Double {
        guard income > 0 else { return 0 }
        return max(0, 100 - (expenses / income) * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                // Spelled out so it isn't mistaken for the card's Balance on
                // Home: that one is the cumulative account balance, this is the
                // in/out flow for the selected period only.
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("stats.net_balance"))
                        .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                    Text(loc("stats.net_balance_sub"))
                        .font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary.opacity(0.75))
                }
                Spacer()
                Text(net >= 0 ? "\(CurrencyManager.shared.formatted(net, currency: currency))"
                             : CurrencyManager.shared.formatted(net, currency: currency))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(net >= 0 ? AppTheme.accent : AppTheme.red)
                    .contentTransition(.numericText())
            }
            // Expense ratio bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(AppTheme.accent.opacity(0.2)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 4).fill(AppTheme.red)
                        .frame(width: g.size.width * CGFloat(spentPct / 100), height: 6)
                        .animation(.spring(response: 0.8, dampingFraction: 0.8), value: spentPct)
                    // Where TIME is. Spending bar behind this line = ahead of
                    // pace; past it = burning faster than the calendar.
                    if let p = progress {
                        let t = CGFloat(p.elapsed) / CGFloat(p.total)
                        Rectangle().fill(AppTheme.textPrimary.opacity(0.55))
                            .frame(width: 2, height: 12)
                            .offset(x: g.size.width * t - 1)
                    }
                }
            }
            .frame(height: 12)
            HStack {
                Text(String(format: loc("stats.percentage_spent"), String(format: "%.0f", spentPct)))
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text(net >= 0
                     ? String(format: loc(progress == nil ? "stats.saved" : "stats.saved_sofar"),
                              String(format: "%.0f%%", savedPct))
                     : loc("stats.overspent"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(net >= 0 ? AppTheme.accent : AppTheme.red)
            }

            // Two facts that make the percentages mean something: how far into
            // the period we are, and how this pace compares to last time.
            if progress != nil || previousExpenses != nil {
                HStack(spacing: 8) {
                    if let p = progress {
                        chip("clock", AppTheme.blue,
                             String(format: loc("stats.day_of"), p.elapsed, p.total))
                    }
                    if let prev = previousExpenses, prev > 0 {
                        let delta = (expenses - prev) / prev * 100
                        let up = delta >= 0
                        chip(up ? "arrow.up.right" : "arrow.down.right",
                             up ? AppTheme.orange : AppTheme.accent,
                             String(format: loc(up ? "stats.vs_prev_up" : "stats.vs_prev_down"),
                                    Int(abs(delta).rounded())))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }

            // Full reconciliation: start balance + net + transfers = today's
            // balance. Every rupiah between "net this period" and the card
            // balance is accounted for on screen.
            if let start = startBalance, let balance = cardBalanceNow {
                Divider().background(AppTheme.cardMid)
                VStack(spacing: 6) {
                    reconRow(loc("stats.recon_start"), start)
                    reconRow(loc("stats.net_balance"), net, signed: true)
                    if let transfers = transferNet, abs(transfers) > 0.5 {
                        reconRow(loc("stats.recon_transfers"), transfers, signed: true)
                    }
                    // When the period is still running, start + net + transfers
                    // lands exactly on today's balance. For a past period (e.g.
                    // "Last Month") it lands on that period's CLOSING balance —
                    // label whichever applies so the math always visibly closes.
                    let closing = start + net + (transferNet ?? 0)
                    let isToday = abs(closing - balance) < 1
                    Divider().background(AppTheme.cardMid.opacity(0.6))
                    HStack {
                        Text(loc(isToday ? "stats.card_balance_now" : "stats.recon_end"))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                        Spacer()
                        Text("= " + (closing < 0 ? "-" : "") + CurrencyManager.shared.formatted(abs(closing), currency: currency))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(closing >= 0 ? AppTheme.accent : AppTheme.red)
                    }
                }
            } else if let balance = cardBalanceNow {
                Divider().background(AppTheme.cardMid)
                HStack {
                    Text(loc("stats.card_balance_now"))
                        .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Text((balance < 0 ? "-" : "") + CurrencyManager.shared.formatted(abs(balance), currency: currency))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(balance >= 0 ? AppTheme.textPrimary : AppTheme.red)
                }
            }
        }
        .padding(.vertical, 16).padding(.horizontal, 18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
    }

    private func reconRow(_ label: String, _ value: Double, signed: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text((value < 0 ? "−" : signed ? "+" : "")
                 + CurrencyManager.shared.formatted(abs(value), currency: currency))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
        }
    }
}

// MARK: - Segment Picker

struct StatSegmentPicker: View {
    @Bindable var vm: StatsViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StatTab.allCases, id: \.self) { tab in
                Button {
                    vm.switchTab(tab)
                } label: {
                    Text(tab.localizedLabel)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(vm.selectedStatTab == tab ? AppTheme.bg : AppTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            if vm.selectedStatTab == tab {
                                Capsule()
                                    .fill(AppTheme.accent)
                                    .shadow(color: AppTheme.accent.opacity(0.4), radius: 10, y: 4)
                            }
                        }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: vm.selectedStatTab)
            }
        }
        .padding(4)
        .background(AppTheme.cardDark, in: Capsule())
    }
}

// MARK: - Net Worth Trend Card

struct NetWorthTrendCard: View {
    let trend: [(label: String, value: Double)]
    var subtitle: String = loc("stats.net_worth_sub")
    @State private var appeared = false

    private var maxAbs: Double { trend.map { abs($0.value) }.max() ?? 1 }
    private var hasData: Bool { trend.contains { $0.value != 0 } }

    /// A single gradient bar, with an optional soft glow for the current period.
    private func bar(_ fill: LinearGradient, w: CGFloat, h: CGFloat, glow: Color?) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(fill)
            .frame(width: w, height: h)
            .shadow(color: (glow ?? .clear).opacity(glow == nil ? 0 : 0.45),
                    radius: glow == nil ? 0 : 5, y: 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("stats.net_worth"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                // Overall direction
                if let last = trend.last, let first = trend.first(where: { $0.value != 0 }) {
                    let up = last.value >= first.value
                    HStack(spacing: 4) {
                        Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                        Text(up ? loc("stats.positive") : loc("stats.negative"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(up ? AppTheme.accent : AppTheme.red)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background((up ? AppTheme.accent : AppTheme.red).opacity(0.12), in: Capsule())
                }
            }

            if hasData {
                let hasNegative = trend.contains { $0.value < 0 }
                let chartH: CGFloat = 70
                
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        let w = geo.size.width
                        let barW = (w - CGFloat(trend.count - 1) * 6) / CGFloat(trend.count)
                        // If all positive: bars grow up from bottom, baseline at bottom.
                        // If has negative: zero line at center, positive bars up, negative bars down.
                        let availableH: CGFloat = hasNegative ? chartH * 0.45 : chartH - 4
                        
                        ZStack(alignment: hasNegative ? .center : .bottom) {
                            // Baseline
                            Rectangle()
                                .fill(AppTheme.cardMid.opacity(0.6))
                                .frame(height: 1)
                                .frame(maxWidth: .infinity, alignment: .center)
                            
                            HStack(alignment: hasNegative ? .center : .bottom, spacing: 6) {
                                ForEach(Array(trend.enumerated()), id: \.offset) { i, point in
                                    let hasValue = point.value != 0
                                    let rawH = maxAbs > 0 ? CGFloat(abs(point.value) / maxAbs) * availableH : 0
                                    // Empty periods get a faint full-height
                                    // track, not a stub that reads as "almost
                                    // nothing" — before this, months with no
                                    // data at all looked like months of zero.
                                    let barH = hasValue ? max(rawH, 3) : availableH
                                    let isPositive = point.value >= 0
                                    let isLast = i == trend.count - 1
                                    let base: Color = isPositive ? AppTheme.accent : AppTheme.red
                                    // Current period pops at full saturation; past
                                    // periods are dimmed so the eye lands on "now".
                                    let strength = !hasValue ? 0.10 : (isLast ? 1.0 : 0.45)
                                    let grad = LinearGradient(
                                        colors: [base.opacity(strength), base.opacity(strength * 0.55)],
                                        startPoint: isPositive ? .top : .bottom,
                                        endPoint: isPositive ? .bottom : .top)
                                    // Grow-in height (staggered) for a lively reveal.
                                    let h = appeared ? barH : 0

                                    if hasNegative {
                                        VStack(spacing: 0) {
                                            if isPositive {
                                                Spacer(minLength: 0)
                                                bar(grad, w: barW, h: h, glow: (isLast && hasValue) ? base : nil)
                                                Color.clear.frame(height: chartH * 0.5)
                                            } else {
                                                Color.clear.frame(height: chartH * 0.5)
                                                bar(grad, w: barW, h: h, glow: (isLast && hasValue) ? base : nil)
                                                Spacer(minLength: 0)
                                            }
                                        }
                                        .frame(height: chartH)
                                        .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(Double(i) * 0.06), value: appeared)
                                    } else {
                                        bar(grad, w: barW, h: h, glow: (isLast && hasValue) ? base : nil)
                                            .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(Double(i) * 0.06), value: appeared)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: chartH)
                    
                    // Labels in separate row
                    HStack(spacing: 6) {
                        ForEach(Array(trend.enumerated()), id: \.offset) { i, point in
                            let isLast = i == trend.count - 1
                            Text(point.label)
                                .font(.system(size: 10, weight: isLast ? .semibold : .regular))
                                .foregroundStyle(isLast ? AppTheme.textPrimary : AppTheme.textSecondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            } else {
                Text(loc("stats.trend_empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.accent.opacity(0.12), lineWidth: 1))
        .onAppear { appeared = true }
    }
}

// MARK: - Smart Insights Card (Weekly Avg + Top Categories)

struct SmartInsightsCard: View {
    let weeklyAverage: Double
    let topCategories: [(category: TxCategory, amount: Double, percentage: Double)]
    let totalExpenses: Double
    let currency: String
    /// When the selected window is shorter than ~2 weeks the "per week" figure
    /// is extrapolated from very little data (e.g. a pay cycle only 8 days in)
    /// and reads much higher than a steady weekly pace. We keep showing it but
    /// flag it as a partial-period estimate so it isn't mistaken for a rate.
    var isPartialPeriod: Bool = false
    var periodDays: Int = 0

    @State private var appeared = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(AppTheme.purple.opacity(0.15)).frame(width: 32, height: 32)
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.purple)
                }
                Text(loc("stats.insights"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
            }
            
            // Weekly Average — hero metric
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.purple)
                    Text(loc("stats.weekly_avg"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                    if isPartialPeriod {
                        // Caveat chip — this window is too short for a stable
                        // weekly rate, so mark it as a partial estimate.
                        HStack(spacing: 3) {
                            Image(systemName: "info.circle.fill").font(.system(size: 8))
                            Text(loc("stats.weekly_avg_partial_badge"))
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(AppTheme.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(AppTheme.orange.opacity(0.12), in: Capsule())
                    }
                }
                Text(CurrencyManager.shared.formatted(weeklyAverage, currency: currency))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())
                Text(isPartialPeriod
                     ? String(format: loc("stats.weekly_avg_partial_sub"), periodDays)
                     : loc("stats.weekly_avg_sub"))
                    .font(.system(size: 11))
                    .foregroundStyle(isPartialPeriod ? AppTheme.orange.opacity(0.9) : AppTheme.textSecondary.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                LinearGradient(
                    colors: [AppTheme.purple.opacity(0.18), AppTheme.purple.opacity(0.05)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14)
            )
            
        }
        .padding(.vertical, 16).padding(.horizontal, 18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                appeared = true
            }
        }
    }
}

struct TopCategoryRow: View {
    let rank: Int
    let category: TxCategory
    let amount: Double
    let percentage: Double
    let currency: String
    let appeared: Bool
    
    private var rankColor: Color {
        switch rank {
        case 1: return AppTheme.orange
        case 2: return AppTheme.textSecondary
        case 3: return AppTheme.purple
        default: return AppTheme.textSecondary
        }
    }
    
    var body: some View {
        HStack(spacing: 10) {
            // Rank badge
            ZStack {
                Circle().fill(rankColor.opacity(0.15)).frame(width: 26, height: 26)
                Text("\(rank)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(rankColor)
            }
            
            // Category icon
            ZStack {
                Circle().fill(category.color.opacity(0.15)).frame(width: 32, height: 32)
                Image(systemName: category.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(category.color)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text(category.displayLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                
                // Mini progress bar
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(category.color.opacity(0.15))
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(category.color)
                            .frame(width: appeared ? g.size.width * CGFloat(percentage / 100) : 0, height: 4)
                            .animation(.spring(response: 0.8, dampingFraction: 0.8).delay(Double(rank) * 0.08), value: appeared)
                    }
                }
                .frame(height: 4)
            }
            
            VStack(alignment: .trailing, spacing: 2) {
                Text(CurrencyManager.shared.formatted(amount, currency: currency))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(String(format: "%.0f%%", percentage))
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
}

// MARK: - Statistics Export Sheet

struct StatsExportSheet: View {
    let period: StatPeriod
    let periodSubtitle: String
    let selectedCard: BankCard?
    let income: Double
    /// Salary-aware income for the recommendation math (see StatsReportCard).
    var budgetIncome: Double? = nil
    let expenses: Double
    let weeklyAverage: Double
    let topCategories: [(category: TxCategory, amount: Double, percentage: Double)]
    let transactions: [TxRecord]
    let currency: String
    /// Per-card budget configs forwarded from the parent so this sheet can
    /// hand them to StatsReportCard for ratio resolution.
    let configs: [CardBudgetConfig]
    
    @State private var shareItem: ShareItem?
    @State private var isGenerating = false
    
    private func cardDisplayLabel(_ card: BankCard) -> String {
        if card.isDigitalWallet, !card.walletProvider.isEmpty {
            return card.walletProvider
        }
        let holder = card.holderName.split(separator: " ").first.map(String.init) ?? card.holderName
        return "\(holder) ••\(card.last4)"
    }
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                // Title only — no icon
                VStack(spacing: 4) {
                    Text(loc("stats.export_preview"))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(periodSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.top, 12)
                
                // Visual preview — actual report card scaled down
                StatsReportCard(
                    periodSubtitle: periodSubtitle,
                    cardLabel: selectedCard.map(cardDisplayLabel) ?? "—",
                    cardColor: selectedCard.map { Color(hex: $0.gradientStart) } ?? AppTheme.purple,
                    income: income,
                    budgetIncome: budgetIncome,
                    expenses: expenses,
                    weeklyAverage: weeklyAverage,
                    topCategories: topCategories,
                    transactionCount: transactions.count,
                    currency: currency,
                    cardID: selectedCard?.id.uuidString,
                    configs: configs,
                    filteredTransactions: transactions
                )
                .padding(.horizontal, 22)
                
                // Single export button — Save as Image
                Button {
                    HapticManager.shared.tap()
                    exportImage()
                } label: {
                    HStack(spacing: 10) {
                        if isGenerating {
                            ProgressView().tint(.white).scaleEffect(0.85)
                        } else {
                            Image(systemName: "photo.fill").font(.system(size: 16))
                        }
                        Text(loc("stats.export_image"))
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [AppTheme.accent, AppTheme.accent.opacity(0.85)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .shadow(color: AppTheme.accent.opacity(0.4), radius: 8, y: 3)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(isGenerating)
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(items: [item.url])
        }
    }
    
    // MARK: - Export Functions
    
    /// Render the report card to a PNG image and share via UIActivityViewController.
    /// Uses ImageRenderer (iOS 16+) at 3x scale for retina-quality output.
    /// Respects user's appearance preference (light/dark/system) so the exported
    /// image matches what the user sees in the app.
    @MainActor
    private func exportImage() {
        isGenerating = true
        let cardName = selectedCard.map(cardDisplayLabel) ?? "—"
        let cardColor = selectedCard.map { Color(hex: $0.gradientStart) } ?? AppTheme.purple
        
        // Resolve user's color scheme preference (light/dark/system → system fallback)
        let resolvedScheme: ColorScheme = {
            if let pref = appColorScheme() { return pref }
            return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        }()
        
        let report = StatsReportCard(
            periodSubtitle: periodSubtitle,
            cardLabel: cardName,
            cardColor: cardColor,
            income: income,
            budgetIncome: budgetIncome,
            expenses: expenses,
            weeklyAverage: weeklyAverage,
            topCategories: topCategories,
            transactionCount: transactions.count,
            currency: currency,
            cardID: selectedCard?.id.uuidString,
            configs: configs,
            filteredTransactions: transactions
        )
        .frame(width: 380)
        .padding(20)
        .background(AppTheme.bg)
        .environment(\.colorScheme, resolvedScheme)
        
        let renderer = ImageRenderer(content: report)
        renderer.scale = 3.0
        
        guard let uiImg = renderer.uiImage,
              let data = uiImg.pngData() else {
            isGenerating = false
            return
        }
        
        let filename = "DiPo_Stats_\(cardName.replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970)).png"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        
        do {
            try data.write(to: tempURL)
            shareItem = ShareItem(url: tempURL)
        } catch {
            print("Image export error: \(error)")
        }
        isGenerating = false
    }
    
}

// MARK: - Stats Report Card (Used for both preview and PNG export)

/// A polished, screenshot-worthy report card. This view is rendered to PNG
/// via ImageRenderer for the "Export as Image" feature, and also used as the
/// preview in StatsExportSheet so users see exactly what they'll get.
struct StatsReportCard: View {
    let periodSubtitle: String
    let cardLabel: String
    let cardColor: Color
    let income: Double
    /// Income to use for BUDGET MATH (the recommendation + savings fallback).
    /// Prefers the salary schedule so the insight isn't distorted by a period
    /// that ends before payday — same signal Home/Smart Budget use. Falls back
    /// to `income` (actual received) when no schedule exists.
    var budgetIncome: Double? = nil
    private var insightIncome: Double { budgetIncome ?? income }
    let expenses: Double
    let weeklyAverage: Double
    let topCategories: [(category: TxCategory, amount: Double, percentage: Double)]
    let transactionCount: Int
    let currency: String
    /// Card whose ratios should appear in the budget breakdown. nil = use
    /// global defaults.
    let cardID: String?
    /// Per-card configs queried by the parent view; this card's ratios are
    /// resolved from this list (with global fallback).
    let configs: [CardBudgetConfig]
    /// Transactions for the period — needed by `recommendationSection` to call
    /// the same `topInsight()` engine Home uses, so the export shows the same
    /// recommendation the user sees on the home screen banner.
    let filteredTransactions: [TxRecord]
    
    @Environment(\.colorScheme) private var colorScheme
    
    private var netBalance: Double { income - expenses }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Brand header — DiPo Mascot logo + label
            HStack {
                HStack(spacing: 10) {
                    Image("DiPoMascot")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 38, height: 38)
                        .blendMode(colorScheme == .dark ? .screen : .multiply)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Digital Pocket ID")
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(loc("stats.title"))
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(periodSubtitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    HStack(spacing: 4) {
                        Circle().fill(cardColor).frame(width: 6, height: 6)
                        Text(cardLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            
            // Hero — Net Balance
            VStack(alignment: .leading, spacing: 4) {
                Text(loc("stats.net_balance"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(netBalance >= 0
                     ? "\(CurrencyManager.shared.formatted(netBalance, currency: currency))"
                     : CurrencyManager.shared.formatted(netBalance, currency: currency))
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(netBalance >= 0 ? AppTheme.accent : AppTheme.red)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                LinearGradient(
                    colors: [
                        (netBalance >= 0 ? AppTheme.accent : AppTheme.red).opacity(0.18),
                        (netBalance >= 0 ? AppTheme.accent : AppTheme.red).opacity(0.04)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 16)
            )
            
            // Income / Expenses split
            HStack(spacing: 8) {
                ReportMetricBox(
                    label: loc("stats.income"),
                    value: CurrencyManager.shared.formatted(income, currency: currency),
                    color: AppTheme.accent,
                    icon: "arrow.down.circle.fill"
                )
                ReportMetricBox(
                    label: loc("stats.expenses"),
                    value: CurrencyManager.shared.formatted(expenses, currency: currency),
                    color: AppTheme.red,
                    icon: "arrow.up.circle.fill"
                )
            }
            
            // Weekly Avg (Royal) + Tx Count. A withheld weekly average arrives
            // as 0 — printing "Rp 0" would read as a real figure, so the box is
            // dropped and the transaction count takes the full width.
            HStack(spacing: 8) {
                if weeklyAverage > 0 {
                    ReportMetricBox(
                        label: loc("stats.weekly_short"),
                        value: CurrencyManager.shared.formatted(weeklyAverage, currency: currency),
                        color: AppTheme.purple,
                        icon: "calendar.badge.clock"
                    )
                }
                ReportMetricBox(
                    label: loc("stats.transactions"),
                    value: "\(transactionCount)",
                    color: AppTheme.orange,
                    icon: "list.bullet.rectangle.fill"
                )
            }
            
            // Top Categories
            if !topCategories.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.orange)
                        Text(loc("stats.top_categories"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    VStack(spacing: 7) {
                        ForEach(Array(topCategories.prefix(5).enumerated()), id: \.offset) { idx, item in
                            ReportCategoryRow(
                                rank: idx + 1,
                                category: item.category,
                                amount: item.amount,
                                percentage: item.percentage,
                                currency: currency
                            )
                        }
                    }
                }
                .padding(14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
            }
            
            // Budget Allocation — premium-gated. Use `hasActiveBudget` (not the
            // raw `isEnabled` toggle) so a user who lost their Royal access
            // (logout, expired sub, sign-in as different non-Royal account)
            // doesn't see this section in the export. The user's old toggle
            // setting is preserved in UserDefaults but stays hidden until they
            // resubscribe — same UX pattern as other Royal-only widgets.
            if SmartBudgetManager.shared.hasActiveBudget {
                budgetAllocationSection
            }
            
            // Smart Recommendation
            recommendationSection
            
            // Footer
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 8))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                Text(String(format: loc("stats.generated_by"), Date().displayDateTimeShort))
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(AppTheme.bg)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.cardMid, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
    
    /// Budget allocation breakdown — shown only when Smart Budget is enabled.
    /// Ratios are resolved per-card via `SmartBudgetManager.ratios(forCardID:)`,
    /// so the export reflects the same allocation the user sees on Home for
    /// this specific card.
    private var budgetAllocationSection: some View {
        let r = SmartBudgetManager.shared.ratios(forCardID: cardID, configs: configs)
        let dailyLimit = income * r.daily
        let lifestyleLimit = income * r.lifestyle
        let investLimit = income * r.investDebt
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.purple)
                Text(loc("budget.allocation_title"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            VStack(spacing: 6) {
                BudgetAllocationRow(
                    label: loc("budget.group.daily"),
                    ratio: r.daily,
                    limit: dailyLimit,
                    color: AppTheme.blue,
                    currency: currency
                )
                BudgetAllocationRow(
                    label: loc("budget.group.lifestyle"),
                    ratio: r.lifestyle,
                    limit: lifestyleLimit,
                    color: AppTheme.purple,
                    currency: currency
                )
                BudgetAllocationRow(
                    label: loc("budget.group.invest_debt"),
                    ratio: r.investDebt,
                    limit: investLimit,
                    color: AppTheme.accent,
                    currency: currency
                )
            }
        }
        .padding(12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
    }
    
    /// Smart recommendation — single source of truth shared with the Home
    /// screen's "Wawasan Cerdas" banner. Both call into
    /// `SmartBudgetManager.topInsight()` so the messaging is consistent: if
    /// Home says "Lifestyle melebihi anggaran", Stats says the same. We only
    /// fall back to a savings-rate summary when there's nothing actionable
    /// to report (no overspend, no anomaly).
    private var recommendationSection: some View {
        // Try the same engine Home uses, with the same per-card ratios.
        // `filteredTransactions` is already scoped to the selected period, so
        // anchor the engine to that window too. Without this it re-filters to
        // the calendar month and the exported insight can disagree with the
        // numbers printed right above it.
        let homeInsight = SmartBudgetManager.shared.topInsight(
            allTransactions: filteredTransactions,
            income: insightIncome,
            cardID: cardID,
            configs: configs,
            targetCurrency: currency,
            periodStart: filteredTransactions.map(\.date).min()
        )

        let (icon, tint, title, body): (String, Color, String, String) = {
            // 1. Reuse Home's insight if it has something to say
            if let insight = homeInsight {
                return (insight.icon, insight.color, insight.title, insight.body)
            }
            // 2. No income → prompt to add salary
            if insightIncome <= 0 {
                return ("info.circle.fill", AppTheme.textSecondary,
                        loc("rec.no_income_title"), loc("rec.no_income_body"))
            }
            // 3. Fallback: savings-rate summary
            let savingsRate = max(0, (insightIncome - expenses) / insightIncome * 100)
            let spendRatio = expenses / insightIncome
            if spendRatio > 0.9 {
                return ("exclamationmark.triangle.fill", AppTheme.red,
                        loc("rec.overspend_title"),
                        String(format: loc("rec.overspend_body"), Int(spendRatio * 100)))
            }
            if savingsRate >= 20 {
                return ("checkmark.seal.fill", AppTheme.accent,
                        loc("rec.great_savings_title"),
                        String(format: loc("rec.great_savings_body"), Int(savingsRate)))
            }
            return ("lightbulb.fill", AppTheme.orange,
                    loc("rec.balance_title"),
                    String(format: loc("rec.balance_body"), Int(savingsRate)))
        }()
        
        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                Text(body)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.25), lineWidth: 1))
    }
}

/// Compact budget allocation row showing label, percentage, and budget cap.
/// Used in StatsReportCard's budget section for image export.
struct BudgetAllocationRow: View {
    let label: String
    let ratio: Double
    let limit: Double
    let color: Color
    let currency: String
    
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(String(format: "%.0f%%", ratio * 100))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(minWidth: 32, alignment: .trailing)
            Text(CurrencyManager.shared.formatted(limit, currency: currency))
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
        }
    }
}

struct ReportMetricBox: View {
    let label: String
    let value: String
    let color: Color
    let icon: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ReportCategoryRow: View {
    let rank: Int
    let category: TxCategory
    let amount: Double
    let percentage: Double
    let currency: String
    
    private var rankColor: Color {
        switch rank {
        case 1: return AppTheme.orange
        case 2: return AppTheme.textSecondary
        case 3: return AppTheme.purple
        default: return AppTheme.textSecondary.opacity(0.7)
        }
    }
    
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(rankColor.opacity(0.15)).frame(width: 20, height: 20)
                Text("\(rank)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(rankColor)
            }
            ZStack {
                Circle().fill(category.color.opacity(0.15)).frame(width: 24, height: 24)
                Image(systemName: category.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(category.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(category.displayLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(category.color.opacity(0.15))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(category.color)
                            .frame(width: g.size.width * CGFloat(percentage / 100), height: 3)
                    }
                }
                .frame(height: 3)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(CurrencyManager.shared.formatted(amount, currency: currency))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(String(format: "%.0f%%", percentage))
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Category Donut
//
// The hero for the category breakdown: one ring, the total in the middle, and
// a wrapping pill legend. Replaces a stack of full-width bars that took most of
// the screen and repeated the same number three ways (bar, %, amount).
// Selecting a slice swaps the centre to that category, so detail is available
// without a permanent list competing with the chart.
struct CategoryDonutChart: View {
    let categories: [SpendCategory]
    let total: Double
    let currency: String
    @Bindable var statsVM: StatsViewModel

    /// Ordered biggest-first so the ring reads clockwise from the dominant slice.
    private var ordered: [SpendCategory] { categories.sorted { $0.amount > $1.amount } }

    private var selected: SpendCategory? {
        guard let i = statsVM.selectedSliceIndex, ordered.indices.contains(i) else { return nil }
        return ordered[i]
    }

    /// Start/end fractions for each slice, in draw order.
    private var slices: [(cat: SpendCategory, start: Double, end: Double)] {
        guard total > 0 else { return [] }
        var acc = 0.0
        return ordered.map { cat in
            let frac = cat.amount / total
            let s = acc; acc += frac
            return (cat, s, acc)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(Array(slices.enumerated()), id: \.element.cat.id) { i, slice in
                    let isSel = statsVM.selectedSliceIndex == i
                    let dimmed = statsVM.selectedSliceIndex != nil && !isSel
                    Circle()
                        .trim(from: slice.start * statsVM.chartProgress,
                              to: slice.end * statsVM.chartProgress)
                        .stroke(slice.cat.color.opacity(dimmed ? 0.25 : 1),
                                style: StrokeStyle(lineWidth: isSel ? 30 : 24, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: statsVM.selectedSliceIndex)
                        .onTapGesture {
                            HapticManager.shared.tap()
                            statsVM.selectSlice(isSel ? nil : i)
                        }
                }

                // Centre reads as the answer to whatever is selected.
                VStack(spacing: 3) {
                    Text(selected?.name ?? loc("stats.total"))
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(CurrencyManager.shared.formatted(selected?.amount ?? total, currency: currency))
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .contentTransition(.numericText())
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if let sel = selected, total > 0 {
                        Text(String(format: "%.0f%%", sel.amount / total * 100))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(sel.color)
                    }
                }
                .padding(.horizontal, 34)
            }
            .frame(width: 176, height: 176)
            .padding(.top, 4)

            // Legend — wraps naturally, no horizontal scroll to discover.
            FlowLegend(items: Array(ordered.enumerated()), selectedIndex: statsVM.selectedSliceIndex) { i in
                HapticManager.shared.tap()
                statsVM.selectSlice(statsVM.selectedSliceIndex == i ? nil : i)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18).padding(.horizontal, 18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Wrapping row of legend pills. SwiftUI has no flow layout before iOS 16's
/// `Layout`, and a horizontal ScrollView hides categories off-screen — so the
/// rows are chunked by a rough width estimate, which is stable for the short
/// category names this app uses.
struct FlowLegend: View {
    let items: [(offset: Int, element: SpendCategory)]
    let selectedIndex: Int?
    let onTap: (Int) -> Void

    /// ~7pt per character plus the dot and padding; 3 per row keeps it tidy at
    /// every supported width.
    private var rows: [[(offset: Int, element: SpendCategory)]] {
        stride(from: 0, to: items.count, by: 3).map {
            Array(items[$0..<min($0 + 3, items.count)])
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.element.id) { item in
                        let isSel = selectedIndex == item.offset
                        Button { onTap(item.offset) } label: {
                            HStack(spacing: 5) {
                                Circle().fill(item.element.color).frame(width: 7, height: 7)
                                Text(item.element.name)
                                    .font(.system(size: 11, weight: isSel ? .semibold : .regular))
                                    .foregroundStyle(isSel ? AppTheme.textPrimary : AppTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(isSel ? item.element.color.opacity(0.14) : Color.clear, in: Capsule())
                            .overlay(Capsule().stroke(AppTheme.cardMid.opacity(isSel ? 0 : 0.7), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
