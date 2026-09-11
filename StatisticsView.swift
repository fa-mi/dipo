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
    /// Snaps a computed cycle start onto the salary transaction that actually
    /// opened it, when one sits within a day or two.
    ///
    /// A SAFETY NET, not a fix for a known defect — worth saying plainly,
    /// because it was added on a wrong premise. It looked like the engine's
    /// computed payday and the recorded salary disagreed, but that came from
    /// reading exported UTC timestamps as local dates: a salary at 00:00 WIB
    /// exports as 17:00 UTC the previous day. Read in the device's own zone,
    /// `SalaryDateEngine.actualPayDate` matches every recorded salary exactly.
    ///
    /// What it still guards is real: a hand-entered salary landing a day off the
    /// scheduled one, which would otherwise fall outside its own cycle. The
    /// tolerance is deliberately tight — wide enough for that, too narrow to
    /// grab an unrelated salary-category row and move the boundary onto it.
    static func anchoredStart(_ computed: Date, salaryDates: [Date],
                              toleranceDays: Int = 2) -> Date {
        let cal = Calendar.current
        let base = cal.startOfDay(for: computed)
        var best: Date? = nil
        var bestGap = Int.max
        for raw in salaryDates {
            let d = cal.startOfDay(for: raw)
            let gap = abs(cal.dateComponents([.day], from: d, to: base).day ?? .max)
            if gap <= toleranceDays, gap < bestGap { bestGap = gap; best = d }
        }
        return best ?? base
    }

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
    @Query private var recurringPlans: [RecurringExpense]
    @Query private var savingsGoals: [SavingsGoal]
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
    @State private var cachedRhythm = SpendingRhythm(history: []) { _ in 0 }
    @State private var cachedFigures = SpendingFigures()
    @State private var cachedNetWorthTrend: [CycleTrendPoint] = []
    @State private var customStart: Date = Calendar.current.safeDate(byAdding: .month, value: -1, to: Date())
    @State private var customEnd: Date = Date()
    @State private var showCustomPicker = false
    @State private var selectedCardID: String? = nil // Kept only as a recompute trigger; the card itself comes from MainCard.
    /// Observed so switching the main card in the Wallet redraws this screen.
    @State private var sb = SmartBudgetManager.shared
    @State private var showSpendingAudit = false
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
        MainCard.payDay(salarySchedules)
    }

    /// Income for BUDGET MATH in the export insight: the stated salary schedule
    /// when there is one (so a pre-payday period doesn't distort the ratio),
    /// otherwise actual income received in the period.
    private var budgetInsightIncome: Double {
        let active = MainCard.salaries(salarySchedules)
        guard !active.isEmpty else { return filteredIncome }
        return active.reduce(0.0) { $0 + CurrencyManager.shared.convert($1.amount, from: $1.currency, to: displayCurrency) }
    }

    /// Periods shown as chips. "Pay cycle" only appears when there's a salary
    /// schedule to anchor it on; otherwise it would be meaningless.
    private var availablePeriods: [StatPeriod] {
        StatPeriod.allCases.filter { $0 != .payCycle || payCycleDay != nil }
    }

    /// Dates the salary actually landed. Used to anchor cycle boundaries so
    /// Statistics and Smart Budget agree on where a cycle begins.
    private var salaryTxDates: [Date] {
        (selectedCard?.transactions ?? []).filter { $0.category == .salary && $0.amount > 0 }.map(\.date)
    }

    /// The anchored payday for a month offset from today. Every cycle boundary
    /// in this screen goes through here, so a cycle is always [payday, next
    /// payday) — never "start plus one calendar month", which drifts whenever a
    /// payday is pulled off a weekend or holiday. For this user's data the real
    /// gaps are 28 and 32 days, not two equal months.
    private func cycleBoundary(monthsFromNow offset: Int) -> Date? {
        guard let day = payCycleDay else { return nil }
        let cal = Calendar.current
        let base = StatPeriod.anchoredStart(StatPeriod.payCycleRange(payDay: day).start,
                                            salaryDates: salaryTxDates)
        let shifted = cal.safeDate(byAdding: .month, value: offset, to: base)
        let m = cal.component(.month, from: shifted), y = cal.component(.year, from: shifted)
        return StatPeriod.anchoredStart(
            cal.startOfDay(for: SalaryDateEngine.actualPayDate(dayOfMonth: day, month: m, year: y)),
            salaryDates: salaryTxDates)
    }

    private var effectiveRange: (start: Date, end: Date) {
        if selectedPeriod == .custom { return (customStart, customEnd) }
        if selectedPeriod == .payCycle, let day = payCycleDay {
            let r = StatPeriod.payCycleRange(payDay: day)
            return (StatPeriod.anchoredStart(r.start, salaryDates: salaryTxDates), r.end)
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
        // Cycle length = this payday to the next one, not a calendar month.
        let cycleEnd = cycleBoundary(monthsFromNow: 1) ?? (cal.date(byAdding: .month, value: 1, to: start) ?? end)
        let total = max(cal.dateComponents([.day], from: start, to: cycleEnd).day ?? 30, 1)
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

        // The previous window has to begin where the previous CYCLE actually
        // began, not one calendar month back. `payCycleRange` anchors the
        // current cycle on the business-day-adjusted pay date, so subtracting a
        // month here reintroduces exactly the drift that function exists to
        // avoid: for a payday on the 25th, July 25 2026 is a Saturday and the
        // salary lands Friday July 24 — one day BEFORE a naive window opens.
        // The comparison then misses an entire month's salary and reports a
        // flat, unchanged income as +400%.
        let prevStart: Date
        if selectedPeriod == .payCycle, let day = payCycleDay {
            let m = cal.component(.month, from: start)
            let y = cal.component(.year,  from: start)
            let pm = m == 1 ? 12 : m - 1
            let py = m == 1 ? y - 1 : y
            prevStart = cal.startOfDay(
                for: SalaryDateEngine.actualPayDate(dayOfMonth: day, month: pm, year: py))
        } else {
            guard let naive = cal.date(byAdding: .month, value: -1, to: start) else { return nil }
            prevStart = naive
        }
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
        // A pay cycle runs from payday to the day BEFORE the next payday, and
        // the header should say so. `effectiveRange.end` is TODAY for a running
        // cycle, so it used to read "25 Aug – 30 Aug" for a cycle that actually
        // covers 25 Aug – 24 Sep. The "Day 6 of 31" chip already reports how far
        // in you are; the title's job is to name the period, not the slice of it
        // that has happened.
        if selectedPeriod == .payCycle, payCycleDay != nil {
            let cal = Calendar.current
            let m = cal.component(.month, from: start), y = cal.component(.year, from: start)
            let nm = m == 12 ? 1 : m + 1
            let ny = m == 12 ? y + 1 : y
            _ = (m, y, nm, ny)
            let nextPay = cycleBoundary(monthsFromNow: 1)
                ?? cal.safeDate(byAdding: .month, value: 1, to: start)
            let lastDay = cal.safeDate(byAdding: .day, value: -1, to: nextPay)
            return "\(fmt.string(from: start)) – \(fmt.string(from: lastDay))"
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

    /// The card every figure on this screen is about — the main card.
    ///
    /// This used to auto-select "the first card with activity", which is why
    /// Statistics and Smart Budget could report different incomes for the same
    /// month with nothing on either screen explaining the gap. They now read
    /// the same anchor, so the two agree by construction rather than by luck.
    private var selectedCard: BankCard? {
        let _ = sb.budgetCardID
        return MainCard.resolve(in: appVM.cards)
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
        // Rhythm first: everything below reads it.
        cachedRhythm = computeRhythm()
        cachedFilteredTx = computeFilteredTx()
        // Figures LAST: they read both of the above.
        cachedFigures = computeFigures()
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
    
    /// Paid once a month rather than day to day: rent and kos, standing family
    /// transfers, subscriptions, investments, debt instalments.
    ///
    /// Defined once and shared by every figure that expresses a RATE, because
    /// they were each deciding separately and disagreeing. Rp 2.100.000 of kos
    /// is not "what a day costs" — it is one charge that happens to land on a
    /// day, and dividing it by elapsed days invents a spending habit nobody has.
    static let fixedMonthlyCats: Set<TxCategory> = [.bills, .investment, .debtPayment, .commitment]

    /// The user's own spending rhythm, learned from the main card's history.
    ///
    /// MEMOIZED, and it has to be. As a computed property this rebuilt every
    /// category profile — sorting and taking medians over the full history —
    /// and `isDayToDay` calls it once per transaction. On 383 transactions that
    /// is 383 rebuilds of a 383-item model per render pass, several times per
    /// frame across the filters that use it. The screen went from instant to
    /// visibly stuttering, which is exactly what a computed property that looks
    /// like a lookup and behaves like a full pass will do.
    ///
    /// Built over ALL history rather than the selected period: cadence measured
    /// across nine days would call almost everything episodic, and the rhythm
    /// should not change because someone tapped a different period chip.
    private var rhythm: SpendingRhythm { cachedRhythm }

    private func computeRhythm() -> SpendingRhythm {
        SpendingRhythm(history: selectedCard?.transactions ?? []) { tx in
            self.convertedAmount(tx)
        }
    }

    /// Whether a transaction is part of "what a day costs".
    ///
    /// Fixed monthly commitments are excluded by category — those are
    /// contractual, not behavioural. Everything else is the engine's call,
    /// overridable per transaction.
    private func isDayToDay(_ tx: TxRecord) -> Bool {
        guard !Self.fixedMonthlyCats.contains(tx.category) else { return false }
        return !rhythm.verdict(for: tx, amount: abs(convertedAmount(tx))).isIrregular
    }

    /// Everything the daily-rate figures need, computed in ONE pass.
    ///
    /// These used to be six computed properties, each walking `filteredTx` and
    /// several calling one another — `weeklyAverage` → `typicalDailySpend` →
    /// `variableDailyTotals`, `projectedSpend` → `variableSpend` + `fixedSpend`
    /// + `upcomingFixed`. A single render did fifteen-odd full passes over the
    /// history plus a sort, which is invisible on a small account and is
    /// exactly the budget an animation needs to hit 60fps.
    struct SpendingFigures {
        var variable = 0.0
        var fixed = 0.0
        var dailyTotals: [Double] = []
        var typicalDaily = 0.0
        var irregularCount = 0
        var irregularTotal = 0.0
        /// Day-to-day spending per weekday: total, the number of distinct dates
        /// that weekday occurred on, and how many purchases fell on it.
        /// Sunday-based index, matching `Calendar.component(.weekday:)` - 1.
        var byWeekday: [Int: (total: Double, days: Set<Date>, count: Int)] = [:]
    }

    private func computeFigures() -> SpendingFigures {
        var f = SpendingFigures()
        var perDay: [Date: Double] = [:]
        let cal = Calendar.current
        for tx in cachedFilteredTx where tx.txSubtype != .transfer {
            let amt = abs(convertedAmount(tx))
            guard tx.amount < 0 || tx.txSubtype == .refund else { continue }
            let signed = tx.txSubtype == .refund ? -amt : amt
            if isDayToDay(tx) {
                f.variable += signed
                if tx.amount < 0 {
                    let day = cal.startOfDay(for: tx.date)
                    perDay[day, default: 0] += amt
                    let wd = cal.component(.weekday, from: tx.date) - 1
                    var e = f.byWeekday[wd] ?? (0, [], 0)
                    e.total += amt; e.days.insert(day); e.count += 1
                    f.byWeekday[wd] = e
                }
            } else {
                f.fixed += signed
                // Fixed monthly commitments are excluded by contract; the
                // irregular tally is only the engine's calls and the user's.
                if !Self.fixedMonthlyCats.contains(tx.category), tx.amount < 0 {
                    f.irregularCount += 1
                    f.irregularTotal += amt
                }
            }
        }
        f.dailyTotals = perDay.values.sorted()
        if !f.dailyTotals.isEmpty {
            let m = f.dailyTotals.count / 2
            f.typicalDaily = f.dailyTotals.count % 2 == 0
                ? (f.dailyTotals[m - 1] + f.dailyTotals[m]) / 2
                : f.dailyTotals[m]
        }
        return f
    }

    /// Day-to-day spending only. The denominator of every rate on this screen.
    private var variableSpend: Double { cachedFigures.variable }

    /// Fixed commitments and irregular episodes charged this period — counted
    /// ONCE, never rated.
    private var fixedSpend: Double { cachedFigures.fixed }

    private var variableDailyTotals: [Double] { cachedFigures.dailyTotals }

    /// What a typical day costs — the MEDIAN, not the mean.
    ///
    /// Excluding fixed categories was necessary and not sufficient. What was
    /// left still contained an annual vehicle tax, a one-off perfume, a loan to
    /// a friend and three intercity tickets bought in one week — all of them
    /// genuinely discretionary, none of them a daily habit. A mean over 71 days
    /// of this user's data reads Rp 380.249 while half their days cost under
    /// Rp 186.000: the figure is more than double a typical day, and every
    /// insight built on it inherits the error.
    ///
    /// A median cannot be dragged by a handful of expensive days, which is
    /// exactly the property this number needs. The big days are not hidden —
    /// they are reported as what they are, in `irregularSpend`.
    private var typicalDailySpend: Double { cachedFigures.typicalDaily }

    /// The irregular spending this period: episodic categories plus anything
    /// marked a one-off. Named rather than averaged away.
    ///
    /// Counted by TRANSACTION, not by day. An earlier version excluded whole
    /// expensive DAYS, which threw out the coffee bought on the same afternoon
    /// as the vehicle tax — the day was not unusual, one purchase in it was.
    private var irregularSpend: (count: Int, total: Double) {
        (cachedFigures.irregularCount, cachedFigures.irregularTotal)
    }

    private var weeklyAverage: Double { typicalDailySpend * 7 }

    /// What a day actually has to spend: income for the cycle, minus everything
    /// contractual, spread across the cycle's days.
    ///
    /// The point of a daily figure is to answer "am I fine today", and that
    /// cannot be answered against gross income — the rent is already spoken
    /// for. This is the number the typical-day figure should be read against.
    private var dailyAllowance: Double? {
        guard let p = periodProgress, p.total > 0 else { return nil }
        let cm = CurrencyManager.shared
        let income = MainCard.salaries(salarySchedules).reduce(0.0) {
            $0 + cm.convert($1.amount, from: $1.currency, to: displayCurrency)
        }
        guard income > 0 else { return nil }

        // Contractual commitments ONLY — the declared recurring plans.
        //
        // This used to subtract `fixedSpend + upcomingFixed`, and `fixedSpend`
        // had quietly grown to mean "everything not day-to-day", which now
        // includes episodic travel and health and anything the user marked a
        // one-off. So a Rp 1.150.000 trip reduced the daily allowance as though
        // it were rent, and the figure read Rp 149.839 where the honest answer
        // — (Rp 10.000.000 − Rp 3.705.000) ÷ 31 — is Rp 203.065.
        //
        // A discretionary trip is spending measured AGAINST the allowance, not
        // a deduction FROM it. Using the plan total also makes the figure
        // stable: it is the same all cycle instead of stepping down each time a
        // bill posts.
        let mainID = selectedCard?.id
        let committed = recurringPlans
            .filter { $0.isActive && ($0.cardID == nil || $0.cardID == mainID) }
            .reduce(0.0) { $0 + cm.convert(abs($1.amount), from: $1.currency, to: displayCurrency) }
        return max(income - committed, 0) / Double(p.total)
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
    private var netWorthTrend: [CycleTrendPoint] { cachedNetWorthTrend }

    /// Fixed commitments measured against income and the active savings goal.
    private var commitmentReview: CommitmentReview {
        CommitmentReview.build(recurrings: recurringPlans, salaries: salarySchedules,
                               goals: savingsGoals, configs: cardBudgetConfigs,
                               currency: displayCurrency)
    }

    private func computeNetWorthTrend() -> [CycleTrendPoint] {
        let cal = Calendar.current
        let now = Date()
        let locale = LanguageManager.shared.currentLocale
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.dateFormat = DateFormatter.dateFormat(fromTemplate: "MMM", options: 0, locale: locale)
        var points: [CycleTrendPoint] = []

        // Bucket boundaries: pay-cycle anchored (start of current cycle, then
        // step back a month at a time) or calendar-month.
        let bucketStarts: [(start: Date, end: Date)] = {
            var out: [(Date, Date)] = []
            if let day = payCycleDay {
                let currentStart = StatPeriod.anchoredStart(
                    StatPeriod.payCycleRange(payDay: day).start, salaryDates: salaryTxDates)
                _ = currentStart
                for offset in stride(from: -5, through: 0, by: 1) {
                    // Each bucket spans its own payday to the next, so uneven
                    // cycles stay uneven instead of being forced to a month.
                    let s = cycleBoundary(monthsFromNow: offset)
                        ?? cal.safeDate(byAdding: .month, value: offset, to: currentStart)
                    let e = cycleBoundary(monthsFromNow: offset + 1)
                        ?? cal.safeDate(byAdding: .month, value: 1, to: s)
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
            return bucketStarts.map {
                CycleTrendPoint(label: fmt.string(from: payCycleDay != nil ? $0.end : $0.start),
                                start: $0.start, end: $0.end,
                                income: 0, expense: 0, txCount: 0)
            }
        }
        for (s, e) in bucketStarts {
            let rows = card.transactions
                .filter { $0.date >= s && $0.date < e && $0.txSubtype != .transfer }
            var inc = 0.0, exp = 0.0
            for t in rows {
                let v = convertedAmount(t)
                if v >= 0 { inc += v } else { exp += -v }
            }
            points.append(CycleTrendPoint(label: fmt.string(from: payCycleDay != nil ? e : s),
                                          start: s, end: e,
                                          income: inc, expense: exp, txCount: rows.count))
        }
        // Drop months that pre-date the account's first transaction. Rendering
        // them as placeholder tracks filled a third of the chart with bars for
        // periods that never existed — a two-month history should look like two
        // months, not like four empty ones and a spike.
        if let firstReal = points.firstIndex(where: { $0.net != 0 }) {
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
        if let w = weekdayStandout {
            let fmt = DateFormatter()
            fmt.locale = LanguageManager.shared.currentLocale
            let name = fmt.weekdaySymbols[max(min(w.weekday, 6), 0)]
            // Naming the day is the easy half. The half that changes anything is
            // whether it is heavy from more purchases or bigger ones.
            let detailKey = w.isSizeDriven ? "stats.pattern.weekday_size"
                          : w.isFrequencyDriven ? "stats.pattern.weekday_freq"
                          : "stats.pattern.weekday_plain"
            out.append((
                "calendar",
                AppTheme.blue,
                String(format: loc("stats.pattern.weekday"), name,
                       cm.formatted(w.average, currency: displayCurrency)),
                w.isSizeDriven
                    ? String(format: loc(detailKey),
                             cm.formatted(w.avgTicket, currency: displayCurrency),
                             cm.formatted(w.otherAvgTicket, currency: displayCurrency))
                    : w.isFrequencyDriven
                        ? String(format: loc(detailKey), w.txPerDay, w.otherTxPerDay)
                        : String(format: loc(detailKey), w.ratio)
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
        // Straight-lining EVERYTHING multiplied the monthly charges by however
        // much of the cycle had elapsed. On day 9 of 31 that is 3.4×, so a
        // single Rp 2.100.000 kos payment projected as Rp 7.200.000 of rent for
        // one month, and the screen announced a pace of Rp 13.565.600 against
        // Rp 10.000.000 of income. The alarm was arithmetic, not behaviour.
        //
        // Three parts, each treated as what it is:
        //   • day-to-day spending, projected at the rate it is actually running;
        //   • fixed charges already made, counted once;
        //   • fixed charges still to come, taken from the recurring plans rather
        //     than guessed — DiPo knows the rent is due on the 8th.
        let rated = variableSpend / Double(p.elapsed) * Double(p.total)
        return rated + fixedSpend + upcomingFixed
    }

    /// Recurring charges falling in the remainder of this period. Counted at
    /// face value: a plan due once is one charge, not a rate.
    private var upcomingFixed: Double {
        let cal = Calendar.current
        let (start, _) = effectiveRange
        // NOT `effectiveRange.end`: for a running pay cycle that is NOW, so
        // `end > now` was false on every render and this entire component
        // silently evaluated to zero. The window has to reach the next payday.
        guard let periodEnd = cycleBoundary(monthsFromNow: 1)
                ?? cal.date(byAdding: .month, value: 1, to: start) else { return 0 }
        let today = cal.startOfDay(for: Date())
        let cm = CurrencyManager.shared
        // Only plans that charge THIS card. Statistics reports the main card;
        // adding a subscription billed to another account would project money
        // that will never leave the one being measured.
        let mainID = selectedCard?.id
        return recurringPlans
            .filter { $0.isActive && ($0.cardID == nil || $0.cardID == mainID) }
            .reduce(0.0) { sum, plan in
                let due = RecurringDateEngine.nextDueDate(dayOfMonth: plan.dayOfMonth)
                // `due` is midnight; comparing it against `now` dropped a charge
                // falling TODAY — not yet in `fixedSpend` if it has not posted,
                // and excluded here too, so it fell through both.
                guard due >= today, due < periodEnd else { return sum }
                // Already posted → it is in `fixedSpend`; counting it again here
                // would double it.
                guard !plan.isChargedForCurrentDue else { return sum }
                return sum + cm.convert(abs(plan.amount), from: plan.currency, to: displayCurrency)
            }
    }

    /// The weekday that genuinely stands out, and WHY.
    ///
    /// The old version took the max weekday average and printed it. That names
    /// a day even when every day is alike — some day is always the highest —
    /// and it says nothing a person can act on.
    ///
    /// This one asks two questions instead. Is the day a real outlier against
    /// the other six (median + MAD, so one blowout Saturday cannot manufacture
    /// a pattern)? And is it heavy because of MORE purchases or BIGGER ones?
    /// That distinction is the whole advice: on this user's data Sunday costs
    /// 2.4× a typical weekday while the number of purchases is flat — 4.7 a day
    /// against 4.4. The lever is not going out less, it is what each outing
    /// costs, and "you spend more at weekends" would have pointed at the wrong
    /// one.
    struct WeekdayStandout {
        let weekday: Int
        let average: Double
        /// Ratio against the median of the other days.
        let ratio: Double
        let txPerDay: Double
        let otherTxPerDay: Double
        let avgTicket: Double
        let otherAvgTicket: Double
        /// True when the day is heavy because each purchase is larger, rather
        /// than because there are more of them.
        var isSizeDriven: Bool { avgTicket > otherAvgTicket * 1.35 }
        var isFrequencyDriven: Bool { txPerDay > otherTxPerDay * 1.35 }
    }

    private var weekdayStandout: WeekdayStandout? {
        let by = cachedFigures.byWeekday
        // Every weekday needs to have happened enough times for its average to
        // mean anything; below this a single date IS the average.
        let usable = by.filter { $0.value.days.count >= 3 }
        guard usable.count >= 5 else { return nil }

        let averages = usable.mapValues { $0.total / Double($0.days.count) }
        guard let top = averages.max(by: { $0.value < $1.value }) else { return nil }

        let others = averages.filter { $0.key != top.key }.map(\.value).sorted()
        guard others.count >= 4 else { return nil }
        let m = others[others.count / 2]
        let mad = others.map { abs($0 - m) }.sorted()[others.count / 2]
        guard mad > 0 else { return nil }
        // Same robust cutoff the category engine uses.
        guard 0.6745 * (top.value - m) / mad >= 2.0, m > 0 else { return nil }

        let t = usable[top.key]!
        let otherTx = usable.filter { $0.key != top.key }
        let otherCount = otherTx.reduce(0) { $0 + $1.value.count }
        let otherDays = otherTx.reduce(0) { $0 + $1.value.days.count }
        let otherTotal = otherTx.reduce(0.0) { $0 + $1.value.total }
        guard otherDays > 0, otherCount > 0 else { return nil }

        return WeekdayStandout(
            weekday: top.key,
            average: top.value,
            ratio: top.value / m,
            txPerDay: Double(t.count) / Double(t.days.count),
            otherTxPerDay: Double(otherCount) / Double(otherDays),
            avgTicket: t.total / Double(t.count),
            otherAvgTicket: otherTotal / Double(otherCount))
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

                    // The anchor, named. Not a control.
                    //
                    // It briefly offered a "Change" affordance here, which put
                    // the same decision in two places — and this is the worse
                    // of the two: choosing which account the whole app reasons
                    // about is a Wallet decision, made once, next to the cards
                    // themselves. Offering it again mid-analysis invites
                    // treating it as a per-screen filter, which is exactly the
                    // browsing behaviour that produced contradictory numbers on
                    // different screens in the first place.
                    if let main = selectedCard {
                        HStack(spacing: 9) {
                            LinearGradient(colors: [Color(hex: main.gradientStart),
                                                    Color(hex: main.gradientEnd)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(width: 4, height: 22)
                                .clipShape(Capsule())
                            Text(cardLabel(main))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .lineLimit(1)
                            Text(loc("main.badge"))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(AppTheme.accent.opacity(0.15), in: Capsule())
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 22)
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
                                      subtitle: payCycleDay != nil ? loc("stats.net_worth_sub_cycle") : loc("stats.net_worth_sub"),
                                      currency: displayCurrency)
                        .padding(.horizontal, 22)
                        .padding(.top, 12)
                    
                    // Smart Insights Card — Weekly avg + Top Category.
                    // Royal-only feature. Free users get a blurred teaser
                    // that opens the paywall on tap (same pattern as the
                    // Home Screen widget's locked-insights treatment).
                    // Commitments priced in goal-time, next to the descriptive
                    // insights. The weekly average says what happened; this says
                    // what it costs.
                    if premiumMgr.canAccess(.smartBudget), !commitmentReview.lines.isEmpty {
                        CommitmentPriorityCard(review: commitmentReview,
                                               currency: displayCurrency,
                                               dailyAllowance: dailyAllowance,
                                               typicalDaily: typicalDailySpend,
                                               irregularThisCycle: irregularSpend.total,
                                               daysInCycle: periodProgress?.total ?? periodDays)
                            .padding(.horizontal, 22)
                            .padding(.top, 12)
                    }

                    if filteredExpenses > 0 {
                        let insightsCard = SmartInsightsCard(
                            weeklyAverage: weeklyAverage,
                            dailyAllowance: dailyAllowance,
                            irregular: irregularSpend,
                            topCategories: topCategories,
                            totalExpenses: filteredExpenses,
                            currency: displayCurrency,
                            isPartialPeriod: isPartialWeeklyPeriod,
                            periodDays: periodDays,
                            onAudit: {
                                HapticManager.shared.tap()
                                showSpendingAudit = true
                            }
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
            selectedCardID = MainCard.reconcile(cards: appVM.cards)?.id.uuidString
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
        // app launch (tab switching only toggles opacity), so `.onAppear` fires
        // before the user has added their first card. Re-running reconcile when
        // activity first appears catches that transition — otherwise the screen
        // reports Rp 0 / Rp 0 with the data sitting right there. Keyed by
        // `count` so it doesn't churn on every tx insert.
        .onChange(of: cardsWithActivity.count) { _, _ in
            selectedCardID = MainCard.reconcile(cards: appVM.cards)?.id.uuidString
        }
        .onChange(of: sb.budgetCardID) { _, newID in
            selectedCardID = newID
        }
        .trackScreen(.statistics)
        .sheet(isPresented: $showSpendingAudit) {
            SpendingAuditSheet(transactions: filteredTx,
                               rhythm: rhythm,
                               typicalDaily: typicalDailySpend,
                               weekly: weeklyAverage,
                               dailyAllowance: dailyAllowance,
                               currency: displayCurrency)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
                // A swipe inside the sheet changes which transactions the rate
                // is built from, so the figures behind it have to be rebuilt —
                // otherwise the user corrects something and the number they
                // came to check does not move.
                .onDisappear { recomputeStats() }
        }
        .onChange(of: statsVM.selectedStatTab) { _, _ in
            statsVM.selectedSliceIndex = nil
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: selectedPeriod) { _, _ in
            statsVM.selectedSliceIndex = nil
            // If selected card has no tx in new period, auto-switch to a card that does
            selectedCardID = MainCard.reconcile(cards: appVM.cards)?.id.uuidString
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
                                    .fill(tab.tint)
                                    .shadow(color: tab.tint.opacity(0.35), radius: 8, y: 3)
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

/// One bar of the trend, carrying the numbers behind it.
///
/// The chart used to hold only a label and a net figure, which meant the only
/// way to check it was to trust it. Keeping income, expense, the window and the
/// transaction count alongside lets the card open and show its own working.
struct CycleTrendPoint: Identifiable {
    let id = UUID()
    let label: String
    let start: Date
    let end: Date
    let income: Double
    let expense: Double
    let txCount: Int
    var net: Double { income - expense }
    /// A period that has not finished yet holds an incomplete total.
    var isRunning: Bool { end > Date() }
}

struct NetWorthTrendCard: View {
    let trend: [CycleTrendPoint]
    var subtitle: String = loc("stats.net_worth_sub")
    var currency: String = CurrencyManager.shared.preferredCurrency
    @State private var appeared = false
    @State private var showBreakdown = false

    private var maxAbs: Double { trend.map { abs($0.net) }.max() ?? 1 }
    private var hasData: Bool { trend.contains { $0.net != 0 } }

    /// A single gradient bar, with an optional soft glow for the current period.
    private func bar(_ fill: LinearGradient, w: CGFloat, h: CGFloat, glow: Color?) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(fill)
            .frame(width: w, height: h)
            .shadow(color: (glow ?? .clear).opacity(glow == nil ? 0 : 0.45),
                    radius: glow == nil ? 0 : 5, y: 2)
    }

    var body: some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                guard hasData else { return }
                HapticManager.shared.tap()
                showBreakdown = true
            }
            .sheet(isPresented: $showBreakdown) {
                CycleTrendBreakdown(trend: trend, currency: currency)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
            }
    }

    private var content: some View {
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
                if let last = trend.last, let first = trend.first(where: { $0.net != 0 }) {
                    let up = last.net >= first.net
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
                let hasNegative = trend.contains { $0.net < 0 }
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
                                    let hasValue = point.net != 0
                                    let rawH = maxAbs > 0 ? CGFloat(abs(point.net) / maxAbs) * availableH : 0
                                    // Empty periods get a faint full-height
                                    // track, not a stub that reads as "almost
                                    // nothing" — before this, months with no
                                    // data at all looked like months of zero.
                                    let barH = hasValue ? max(rawH, 3) : availableH
                                    let isPositive = point.net >= 0
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
    /// What a day has to spend once the month's fixed costs are set aside.
    var dailyAllowance: Double? = nil
    /// Days that cost several times a typical one — reported, not averaged in.
    var irregular: (count: Int, total: Double) = (0, 0)
    let topCategories: [(category: TxCategory, amount: Double, percentage: Double)]
    let totalExpenses: Double
    let currency: String
    /// When the selected window is shorter than ~2 weeks the "per week" figure
    /// is extrapolated from very little data (e.g. a pay cycle only 8 days in)
    /// and reads much higher than a steady weekly pace. We keep showing it but
    /// flag it as a partial-period estimate so it isn't mistaken for a rate.
    var isPartialPeriod: Bool = false
    var periodDays: Int = 0
    /// Opens the audit. A figure that excludes some of your spending has to be
    /// traceable back to the transactions it did and did not use.
    var onAudit: (() -> Void)? = nil

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

                // The figure only means something against what a day HAS.
                if let allowance = dailyAllowance, allowance > 0 {
                    let daily = weeklyAverage / 7
                    HStack(spacing: 5) {
                        Image(systemName: daily <= allowance ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 10))
                        Text(String(format: loc("stats.daily_vs_allowance"),
                                    CurrencyManager.shared.formatted(daily, currency: currency),
                                    CurrencyManager.shared.formatted(allowance, currency: currency)))
                            .font(.system(size: 11, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(daily <= allowance ? AppTheme.accent : AppTheme.orange)
                    .padding(.top, 2)
                }

                // The expensive days, named instead of smeared across the week.
                if let onAudit {
                    // Named, not just tappable. An invisible tap target on a
                    // number is a feature only its author knows about.
                    Button(action: onAudit) {
                        HStack(spacing: 4) {
                            Text(loc("audit.open"))
                                .font(.system(size: 11, weight: .semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(AppTheme.purple)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .padding(.top, 2)
                }

                if irregular.count > 0 {
                    Text(String(format: loc(irregular.count == 1 ? "stats.oneoff_day" : "stats.oneoff_days"),
                                irregular.count,
                                CurrencyManager.shared.formatted(irregular.total, currency: currency)))
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                .padding(.top, 28)
                
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
            HStack(spacing: 8) {
                Image("DiPoMascot")
                    .resizable().scaledToFit()
                    .frame(width: 26, height: 26)
                    .blendMode(colorScheme == .dark ? .screen : .multiply)
                Text("DiPo")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                Circle().fill(cardColor).frame(width: 5, height: 5)
                Text(cardLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(periodSubtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            
            // Hero — Net Balance
            VStack(alignment: .leading, spacing: 4) {
                Text(loc("stats.net_balance"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(netBalance >= 0
                     ? "\(CurrencyManager.shared.formatted(netBalance, currency: currency))"
                     : CurrencyManager.shared.formatted(netBalance, currency: currency))
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundStyle(netBalance >= 0 ? AppTheme.accent : AppTheme.red)
                    .lineLimit(1).minimumScaleFactor(0.55)
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
            
            // Weekly average + transaction count demoted to one quiet line.
            // As boxes they carried the same visual weight as income and
            // expenses while answering a question nobody asks of a report.
            HStack(spacing: 6) {
                if weeklyAverage > 0 {
                    Text(String(format: loc("stats.report_weekly_inline"),
                                CurrencyManager.shared.formatted(weeklyAverage, currency: currency)))
                    Text("·")
                }
                Text(String(format: loc("stats.report_tx_inline"), transactionCount))
            }
            .font(.system(size: 10))
            .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
            
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
                        ForEach(Array(topCategories.prefix(3).enumerated()), id: \.offset) { idx, item in
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

// MARK: - Trend breakdown
//
// The chart's own working, shown on tap.
//
// A bar is a conclusion; this is the arithmetic behind it — the exact window,
// how much came in, how much went out, how many rows were counted, and the
// subtraction. Nothing here is recomputed: it is the same numbers the bar was
// drawn from, which is the point. A figure you cannot check is one you can only
// take on trust, and trust is the wrong thing to ask for about someone's money.
struct CycleTrendBreakdown: View {
    let trend: [CycleTrendPoint]
    let currency: String
    @Environment(\.dismiss) private var dismiss

    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: currency)
    }
    private func range(_ p: CycleTrendPoint) -> String {
        let df = DateFormatter()
        df.locale = LanguageManager.shared.currentLocale
        df.dateFormat = DateFormatter.dateFormat(fromTemplate: "dMMM", options: 0,
                                                 locale: LanguageManager.shared.currentLocale)
        // The window is half-open, so the last day it covers is the day before
        // it ends — the same convention the period header uses.
        let last = Calendar.current.safeDate(byAdding: .day, value: -1, to: p.end)
        return "\(df.string(from: p.start)) – \(df.string(from: last))"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        Text(loc("stats.trend_detail_intro"))
                            .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)

                        ForEach(trend.reversed()) { p in
                            VStack(spacing: 9) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(p.label)
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundStyle(AppTheme.textPrimary)
                                            if p.isRunning {
                                                Text(loc("stats.trend_running"))
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundStyle(AppTheme.orange)
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(AppTheme.orange.opacity(0.15), in: Capsule())
                                            }
                                        }
                                        Text(range(p))
                                            .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                    }
                                    Spacer()
                                    Text((p.net >= 0 ? "+" : "−") + money(abs(p.net)))
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(p.net >= 0 ? AppTheme.accent : AppTheme.red)
                                }
                                Divider().overlay(AppTheme.cardMid)
                                row(loc("stats.income"), money(p.income), AppTheme.accent)
                                row(loc("stats.expenses"), "− " + money(p.expense), AppTheme.red)
                                row(loc("stats.trend_counted"),
                                    String(format: loc("search.results_count"), p.txCount),
                                    AppTheme.textSecondary)
                            }
                            .padding(14)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 22)
                        }

                        Text(loc("stats.trend_detail_note"))
                            .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22).padding(.top, 4)
                        Spacer(minLength: 30)
                    }
                    .padding(.top, 12)
                }
            }
            .navigationTitle(loc("stats.trend_detail_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
    }

    private func row(_ l: String, _ v: String, _ tint: Color) -> some View {
        HStack {
            Text(l).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(v).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
        }
    }
}
