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
    @Bindable var appVM: AppViewModel
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
    @State private var showAllCategories = false
    /// Which day of the Weekly page is open, and which of its rows was tapped.
    @State private var expandedDay: Date? = nil
    @State private var inspectedTx: TxRecord? = nil
    /// Category filter on the cycle page. Cleared whenever a different cycle opens.
    @State private var cycleCategoryFilter: TxCategory? = nil

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
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(AppTheme.bg.opacity(0.35))
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(AppTheme.purple.opacity(0.15)).frame(width: 46, height: 46)
                    Image(systemName: "crown.fill")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(AppTheme.purple)
                }
                Text(loc("stats.insights"))
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(.caption2, weight: .bold)).imageScale(.small)
                    Text(loc("stats.insights_locked"))
                        .font(.system(.caption, weight: .bold))
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
    
    /// The same expense rule as `filteredExpenses`, applied to any slice — so
    /// today's figure and the weekly bars agree with the period total instead of
    /// each inventing their own definition of "spent".
    private func expenseSum(_ txs: [TxRecord]) -> Double {
        txs.filter { $0.txSubtype != .transfer }
            .reduce(0.0) { sum, tx in
                let amt = abs(convertedAmount(tx))
                if tx.txSubtype == .refund { return sum - amt }
                return tx.amount < 0 ? sum + amt : sum
            }
    }

    /// Spent so far today. Deliberately NOT period-filtered — "today" is today
    /// whichever window the user is looking at.
    private var todaySpend: Double {
        guard let card = selectedCard else { return 0 }
        let cal = Calendar.current
        return expenseSum(card.transactions.filter { cal.isDateInToday($0.date) })
    }

    /// A Monday-first calendar, in the app's language.
    private var weekCalendar: Calendar {
        var cal = Calendar.current
        cal.locale = LanguageManager.shared.currentLocale
        cal.firstWeekday = 2
        return cal
    }

    struct WeekDay: Identifiable {
        let id = UUID()
        let date: Date
        let short: String       // "M"
        let full: String        // "Monday"
        let amount: Double
        let txCount: Int
        var isToday: Bool { Calendar.current.isDateInToday(date) }
        var isFuture: Bool { date > Date() }
    }

    /// This calendar week, day by day — the Weekly tile's bars and its page.
    private var weekDays: [WeekDay] {
        guard let card = selectedCard else { return [] }
        let cal = weekCalendar
        guard let week = cal.dateInterval(of: .weekOfYear, for: Date()) else { return [] }
        let short = cal.veryShortWeekdaySymbols            // Sunday-first
        let full = cal.weekdaySymbols
        return (0..<7).compactMap { i in
            guard let day = cal.date(byAdding: .day, value: i, to: week.start) else { return nil }
            let idx = (i + 1) % 7
            return WeekDay(date: day, short: short[idx], full: full[idx],
                           amount: expenseSum(card.transactions.filter { cal.isDate($0.date, inSameDayAs: day) }),
                           txCount: spendTx(on: day).count)
        }
    }

    /// The rows that make up a day's spend — exactly the ones `expenseSum` counts
    /// (refunds included, transfers and income left out), so the list opened under
    /// a day adds up to the figure printed beside it.
    private func spendTx(on day: Date) -> [TxRecord] {
        guard let card = selectedCard else { return [] }
        let cal = weekCalendar
        return card.transactions
            .filter {
                cal.isDate($0.date, inSameDayAs: day)
                    && $0.txSubtype != .transfer
                    && ($0.amount < 0 || $0.txSubtype == .refund)
            }
            .sorted { $0.date > $1.date }
    }

    private var weekBars: [(label: String, value: Double)] {
        weekDays.map { ($0.short, $0.amount) }
    }

    private var weekTotal: Double { weekDays.reduce(0) { $0 + $1.amount } }

    /// Last week's total, for the Weekly page's comparison.
    private var previousWeekTotal: Double {
        guard let card = selectedCard else { return 0 }
        let cal = weekCalendar
        guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: Date()),
              let lastWeekDay = cal.date(byAdding: .day, value: -7, to: thisWeek.start),
              let lastWeek = cal.dateInterval(of: .weekOfYear, for: lastWeekDay) else { return 0 }
        return expenseSum(card.transactions.filter {
            $0.date >= lastWeek.start && $0.date < lastWeek.end
        })
    }

    /// Expense per completed cycle/month — the Trends tile's bars.
    private var trendBars: [(label: String, value: Double)] {
        netWorthTrend.suffix(7).map { (String($0.label.prefix(1)), $0.expense) }
    }
    private var trendTotal: Double { netWorthTrend.last?.expense ?? 0 }

    /// What's left of the period's income after what's gone out. Nil when no
    /// income landed in the window — then the hero reports spending instead of
    /// inventing a budget the user never set.
    private var leftToSpend: Double? {
        filteredIncome > 0 ? filteredIncome - filteredExpenses : nil
    }

    /// Share of the period's income already spent, 0...1.
    private var spentRatio: Double {
        filteredIncome > 0 ? min(filteredExpenses / filteredIncome, 1) : 0
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

    // MARK: - Layout
    //
    // The screen answers four questions, in the order a person asks them, and
    // nothing else: how much has gone out and am I fine, where did it go, what
    // is worth knowing, and is this more than usual. It used to stack nine
    // cards — a cash-flow card, a net card with a balance reconciliation, a net
    // trend, commitments priced in goal-time, a weekly-rate card with an audit,
    // a donut, patterns — which were each right and together unreadable. The
    // working behind the numbers moved one tap away, to Full analysis.

    /// Top categories shown before "Show all".
    private static let categoryPreview = 5
    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: displayCurrency)
    }

    var body: some View {
        NavigationStack(path: $appVM.statsPath) {
            mainPage
                .navigationTitle(loc("stats.title"))
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: StatsRoute.self) { route in
                    switch route {
                    case .analysis: fullAnalysis
                    case .weekly:   weeklyDetail
                    case .trends:   trendsDetail
                    case .cycle(let s, let e, let label):
                        cycleDetail(start: s, end: e, label: label)
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
            selectedCardID = MainCard.reconcile(cards: appVM.cards)?.id.uuidString
            recomputeStats()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                statsVM.categories = realCategories
            }
        }
        // Re-running reconcile when activity first appears catches a first card
        // added after this tab mounted — otherwise the screen reports Rp 0 with
        // the data sitting right there. Keyed by `count` so it doesn't churn.
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
                // is built from, so the figures behind it have to be rebuilt.
                .onDisappear { recomputeStats() }
        }
        .onChange(of: statsVM.selectedStatTab) { _, _ in
            statsVM.selectedSliceIndex = nil
            showAllCategories = false
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: selectedPeriod) { _, _ in
            statsVM.selectedSliceIndex = nil
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
        }
        .onChange(of: customEnd) { _, _ in
            recomputeStats()
            withAnimation { statsVM.categories = realCategories }
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
                // The typical week is a Royal note, so it is withheld from the
                // export itself, not just hidden in the layout. Categories are
                // on the free screen, so they travel for everyone.
                weeklyAverage: premiumMgr.canAccess(.smartBudget) ? weeklyAverage : 0,
                topCategories: topCategories,
                transactions: filteredTx,
                currency: displayCurrency,
                configs: cardBudgetConfigs,
                previousExpenses: previousPeriodExpenses
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

    // MARK: Main page

    private var mainPage: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    spendHero
                    metricStrip
                    dualCards
                    if tidyableCount > 0 { tidyRow }
                    categoriesCard
                    notesCard
                    detailLink
                    Spacer(minLength: 110)
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("stats.title"))
                        .font(.system(.title, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(periodSubtitle)
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Button {
                    HapticManager.shared.tap()
                    showExportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.cardDark, in: Circle())
                }
                .accessibilityLabel(loc("a11y.export"))
                .buttonStyle(ScaleButtonStyle())
            }

            // The period is context, not content: one quiet chip.
            Menu {
                ForEach(availablePeriods, id: \.self) { period in
                    Button {
                        HapticManager.shared.tap()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            selectedPeriod = period
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
                    Image(systemName: "calendar")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(selectedPeriod.title)
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(.caption2, weight: .semibold)).imageScale(.small)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(AppTheme.cardDark, in: Capsule())
            }
        }
    }

    // MARK: 0 · The headline, at a glance
    //
    // A hero figure with the period's progress under it, a strip of the four
    // numbers people check daily, and two tiles that show the shape of the week
    // and of the months. The working stays one tap away in Full analysis.

    private var spendHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(leftToSpend != nil ? loc("stats.left_to_spend") : loc("stats.expenses"))
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(money(max(leftToSpend ?? filteredExpenses, 0)))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.5).lineLimit(1)
            }

            if filteredIncome > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    // The existing gauge, not a plain bar: it carries the tick for
                    // how much of the period has elapsed, so spending ahead of the
                    // calendar is visible rather than merely counted.
                    SpendGauge(fraction: spentRatio,
                               timeMarker: periodProgress.map { Double($0.elapsed) / Double($0.total) })

                    HStack(spacing: 8) {
                        Text(String(format: loc("stats.spent_of"),
                                    money(filteredExpenses), money(filteredIncome)))
                            .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 4)
                        if let c = expenseChange, abs(c) >= 1 {
                            HStack(spacing: 3) {
                                Image(systemName: c >= 0 ? "arrow.up.right" : "arrow.down.right")
                                    .font(.system(.caption2, weight: .bold))
                                Text(String(format: "%.0f%%", abs(c)))
                                    .font(.system(.caption2, weight: .bold))
                            }
                            .foregroundStyle(c >= 0 ? AppTheme.red : AppTheme.accent)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background((c >= 0 ? AppTheme.red : AppTheme.accent).opacity(0.15), in: Capsule())
                        }
                    }
                }
            }

            // Where this period is heading, in one sentence.
            if let line = paceLine {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: line.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(.subheadline))
                        .foregroundStyle(line.ok ? AppTheme.accent : AppTheme.orange)
                    Text(line.text)
                        .font(.system(.footnote, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((line.ok ? AppTheme.accent : AppTheme.orange).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: AppRadius.md))
            } else if filteredIncome <= 0 {
                Label(loc("stats.no_income_hint"), systemImage: "info.circle")
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: AppRadius.xl).fill(AppTheme.cardDark)
                .overlay {
                    LinearGradient(colors: [AppTheme.accent.opacity(0.20),
                                            AppTheme.blue.opacity(0.06), .clear],
                                   startPoint: .topTrailing, endPoint: .bottomLeading)
                }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
        }
    }

    private var metricStrip: some View {
        let top = topCategories.first
        return HStack(spacing: 0) {
            metricCell("chart.pie.fill", AppTheme.accent,
                       filteredIncome > 0 ? "\(Int(spentRatio * 100))%" : "—",
                       loc("stats.metric_budget"))
            metricDivider
            metricCell("sun.max.fill", AppTheme.amber, money(todaySpend), loc("common.today"))
            metricDivider
            metricCell("scope", AppTheme.blue, money(typicalDailySpend), loc("stats.metric_per_day"))
            metricDivider
            metricCell("tag.fill", top?.category.color ?? AppTheme.purple,
                       money(top?.amount ?? 0),
                       top?.category.displayLabel ?? loc("stats.metric_top"))
        }
        .padding(.vertical, 12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private func metricCell(_ icon: String, _ tint: Color, _ value: String, _ label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(.caption, weight: .bold)).foregroundStyle(tint)
            Text(value).font(.system(.subheadline, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    private var metricDivider: some View {
        Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(width: 1, height: 32)
    }

    private var dualCards: some View {
        HStack(spacing: 12) {
            miniStatCard(loc("stats.weekly"), loc("stats.this_week"), weekTotal,
                         "chart.bar.fill", AppTheme.blue, weekBars,
                         highlightLast: false, route: .weekly)
            miniStatCard(loc("stats.trends"), loc("stats.this_month"), trendTotal,
                         "chart.line.uptrend.xyaxis", AppTheme.accent, trendBars,
                         highlightLast: true, route: .trends)
        }
    }

    private func miniStatCard(_ title: String, _ subtitle: String, _ value: Double,
                              _ icon: String, _ tint: Color,
                              _ bars: [(label: String, value: Double)],
                              highlightLast: Bool, route: StatsRoute) -> some View {
        Button {
            HapticManager.shared.tap()
            appVM.statsPath.append(route)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(.caption, weight: .bold)).foregroundStyle(tint)
                    Text(title).font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right").font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                }
                Text(subtitle).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                Text(money(value)).font(.system(.title3, weight: .bold))
                    .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.5)
                    .padding(.bottom, 2)
                MiniBars(values: bars.map(\.value), labels: bars.map(\.label),
                         tint: tint, highlightLast: highlightLast)
                    .frame(height: 54)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    // MARK: 1 · How much went out, and am I fine

    private var expenseChange: Double? {
        guard let prev = previousPeriodExpenses, prev > 0 else { return nil }
        return (filteredExpenses - prev) / prev * 100
    }

    /// One sentence on where this is heading, for a period still running.
    private var paceLine: (ok: Bool, text: String)? {
        guard let projected = projectedSpend, filteredIncome > 0 else { return nil }
        if projected <= filteredIncome {
            return (true, String(format: loc("stats.pace_safe"), money(projected)))
        }
        return (false, String(format: loc("stats.pace_over"), money(projected),
                              money(projected - filteredIncome)))
    }

    private var tidyRow: some View {
        Button {
            HapticManager.shared.tap(); showTidy = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.purple)
                Text(String(format: loc("tidy.chip"), tidyableCount))
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    // MARK: 2 · Where it went

    /// Same subtype rules as the totals: transfers skipped, refunds taken off
    /// their category, income counting normal income only.
    private var categoryBreakdown: [(category: TxCategory, amount: Double)] {
        var totals: [TxCategory: Double] = [:]
        let expensesTab = statsVM.selectedStatTab == .expenses
        for tx in filteredTx where tx.txSubtype != .transfer {
            let amt = abs(convertedAmount(tx))
            if expensesTab {
                if tx.txSubtype == .refund { totals[tx.category, default: 0] -= amt }
                else if tx.amount < 0 { totals[tx.category, default: 0] += amt }
            } else if tx.txSubtype == .normal && tx.amount > 0 {
                totals[tx.category, default: 0] += amt
            }
        }
        return totals.filter { $0.value > 0 }
            .map { (category: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }
    }

    private var categoriesCard: some View {
        let rows = categoryBreakdown
        let total = rows.reduce(0) { $0 + $1.amount }
        let shown = showAllCategories ? rows : Array(rows.prefix(Self.categoryPreview))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text(loc(statsVM.selectedStatTab == .expenses ? "stats.where_title" : "stats.where_income_title"))
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer(minLength: 8)
                flowToggle
            }

            if rows.isEmpty {
                VStack(spacing: 10) {
                    Text(String(format: loc("stats.title_empty"),
                                statsVM.selectedStatTab.localizedLabel.lowercased()))
                        .font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                    Button {
                        HapticManager.shared.tap()
                        NotificationCenter.default.post(name: .requestOpenAddTransaction, object: nil)
                    } label: {
                        Label(loc("home.add_first_tx"), systemImage: "plus.circle.fill")
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(AppTheme.onVividFill)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(AppTheme.accentFill, in: Capsule())
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 14) {
                    ForEach(Array(shown.enumerated()), id: \.element.category) { i, row in
                        categoryRow(row.category, amount: row.amount,
                                    share: total > 0 ? row.amount / total : 0, index: i)
                    }
                }
                if rows.count > Self.categoryPreview {
                    Button {
                        HapticManager.shared.tap()
                        withAnimation(.spring(response: 0.35)) { showAllCategories.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showAllCategories
                                 ? loc("stats.show_less")
                                 : String(format: loc("stats.show_all_categories"), rows.count))
                            Image(systemName: showAllCategories ? "chevron.up" : "chevron.down")
                                .imageScale(.small)
                        }
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }

    /// Money out / money in, as two small pills.
    private var flowToggle: some View {
        HStack(spacing: 2) {
            ForEach(StatTab.allCases, id: \.self) { tab in
                let on = statsVM.selectedStatTab == tab
                Button {
                    guard !on else { return }
                    withAnimation(.spring(response: 0.3)) { statsVM.switchTab(tab) }
                } label: {
                    Text(tab.localizedLabel)
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(on ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(on ? AppTheme.bg : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(AppTheme.cardMid.opacity(0.7), in: Capsule())
    }

    private func categoryRow(_ cat: TxCategory, amount: Double, share: Double, index: Int) -> some View {
        let hue = Color(hex: cat.iconBg)
        return HStack(spacing: 12) {
            Image(systemName: cat.icon)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(hue, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(cat.displayLabel)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(money(amount))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                HStack(spacing: 8) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(AppTheme.cardMid.opacity(0.8))
                            Capsule().fill(hue)
                                .frame(width: max(g.size.width * CGFloat(share) * statsVM.chartProgress, 4))
                                .animation(.spring(response: 0.7, dampingFraction: 0.85)
                                    .delay(Double(index) * 0.05), value: statsVM.chartProgress)
                        }
                    }
                    .frame(height: 6)
                    Text("\(Int((share * 100).rounded()))%")
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    // MARK: 3 · Worth knowing

    /// At most three plain sentences. The pace already sits in the summary, so
    /// it is not repeated here.
    private var noteRows: [(icon: String, tint: Color, title: String, detail: String)] {
        var out: [(icon: String, tint: Color, title: String, detail: String)] = []
        if weeklyAverage > 0 {
            out.append(("cup.and.saucer.fill", AppTheme.purple,
                        String(format: loc("stats.weekly_line"), money(weeklyAverage)),
                        loc("stats.weekly_line_sub")))
        }
        for row in patternRows where row.icon != "chart.line.uptrend.xyaxis" {
            out.append((row.icon, row.tint, row.title, row.detail))
        }
        return Array(out.prefix(3))
    }

    @ViewBuilder
    private var notesCard: some View {
        let rows = noteRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc("stats.notes_title"))
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                if premiumMgr.canAccess(.smartBudget) {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            if i > 0 {
                                Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 48)
                            }
                            noteRow(row.icon, row.tint, row.title, row.detail)
                        }
                    }
                } else {
                    lockedNotes(rows)
                }
            }
            .padding(16)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        }
    }

    private func noteRow(_ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.sm))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    /// The shape of the notes with the words hidden, and one way to open them.
    private func lockedNotes(_ rows: [(icon: String, tint: Color, title: String, detail: String)]) -> some View {
        Button {
            HapticManager.shared.tap()
            NotificationCenter.default.post(name: .requestOpenPaywall, object: nil)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(2).enumerated()), id: \.offset) { _, row in
                        noteRow(row.icon, row.tint, row.title, row.detail)
                    }
                }
                .redacted(reason: .placeholder)
                .blur(radius: 3)
                .accessibilityHidden(true)
                HStack(spacing: 6) {
                    Image(systemName: "crown.fill")
                    Text(loc("stats.insights_locked"))
                }
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(PremiumPlan.royal.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(PremiumPlan.royal.color.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.md))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 4 · The working, one tap away

    private var detailLink: some View {
        Button {
            HapticManager.shared.tap()
            appVM.statsPath.append(.analysis)
        } label: {
            PlanRowLabel(icon: "doc.text.magnifyingglass", tint: AppTheme.blue,
                         title: loc("stats.detail_link"),
                         status: loc("stats.detail_link_sub"),
                         lockedPlan: nil)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    // MARK: Weekly · its own page
    //
    // The tile answers "how much this week"; this page answers "which days, and
    // is that unusual" — the same figures, opened up, day by day.

    private var weekRangeLabel: String {
        let cal = weekCalendar
        guard let w = cal.dateInterval(of: .weekOfYear, for: Date()) else { return "" }
        let df = DateFormatter()
        df.locale = LanguageManager.shared.currentLocale
        df.dateFormat = DateFormatter.dateFormat(fromTemplate: "dMMM", options: 0,
                                                 locale: LanguageManager.shared.currentLocale)
        let last = cal.safeDate(byAdding: .day, value: -1, to: w.end)
        return "\(df.string(from: w.start)) – \(df.string(from: last))"
    }

    private var weeklyDetail: some View {
        let elapsed = weekDays.filter { !$0.isFuture }
        let change: Double? = previousWeekTotal > 0
            ? (weekTotal - previousWeekTotal) / previousWeekTotal * 100 : nil
        let avg = elapsed.isEmpty ? 0 : weekTotal / Double(elapsed.count)
        let busiest = weekDays.max { $0.amount < $1.amount }
        let quietCount = elapsed.filter { $0.amount <= 0 }.count

        return ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    statHero(title: loc("stats.this_week"), subtitle: weekRangeLabel,
                             value: weekTotal, tint: AppTheme.blue,
                             change: change, changeCaption: loc("stats.vs_last_week"),
                             previous: previousWeekTotal)

                    chartCard(values: weekDays.map(\.amount), labels: weekDays.map(\.short),
                              tint: AppTheme.blue, highlightLast: false)

                    HStack(spacing: 10) {
                        factTile(loc("stats.daily_avg"), money(avg), AppTheme.blue)
                        factTile(loc("stats.busiest_day"),
                                 (busiest?.amount ?? 0) > 0 ? (busiest?.full ?? "—") : "—",
                                 AppTheme.orange)
                        factTile(loc("stats.no_spend_days"), "\(quietCount)", AppTheme.accent)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(weekDays.enumerated()), id: \.element.id) { i, d in
                            dayRow(d)
                            if i < weekDays.count - 1 {
                                Rectangle().fill(AppTheme.cardMid.opacity(0.6)).frame(height: 1)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))

                    Spacer(minLength: 100)
                }
                .padding(.horizontal, 22).padding(.top, 8)
            }
        }
        .navigationTitle(loc("stats.weekly"))
        .navigationBarTitleDisplayMode(.inline)
        // Attached HERE, not on the root: the stats screen already stacks four
        // sheets, and SwiftUI drops later ones when too many share a view.
        .sheet(item: $inspectedTx) { tx in
            TransactionDetailSheet(tx: tx)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }

    /// One day of the week: tap it to open the transactions behind its figure.
    @ViewBuilder
    private func dayRow(_ d: WeekDay) -> some View {
        let rows = expandedDay == d.date ? spendTx(on: d.date) : []
        let openable = !d.isFuture && d.txCount > 0
        VStack(spacing: 0) {
            Button {
                guard openable else { return }
                HapticManager.shared.tap()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    expandedDay = (expandedDay == d.date) ? nil : d.date
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(d.full)
                                .font(.system(.subheadline, weight: d.isToday ? .bold : .medium))
                                .foregroundStyle(AppTheme.textPrimary)
                            if d.isToday {
                                Text(loc("common.today"))
                                    .font(.system(.caption2, weight: .bold))
                                    .foregroundStyle(AppTheme.blue)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(AppTheme.blue.opacity(0.15), in: Capsule())
                            }
                        }
                        Text(d.isFuture ? loc("stats.day_ahead")
                                        : String(format: loc("stats.tx_count"), d.txCount))
                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Text(d.isFuture ? "—" : money(d.amount))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(d.amount > 0 ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    // Only days with something to show carry the affordance.
                    Image(systemName: "chevron.down")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                        .rotationEffect(.degrees(expandedDay == d.date ? 180 : 0))
                        .opacity(openable ? 1 : 0)
                }
                .padding(.vertical, 13)
                .contentShape(Rectangle())
                .opacity(d.isFuture ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(!openable)

            if !rows.isEmpty {
                VStack(spacing: 10) {
                    ForEach(rows) { tx in
                        Button {
                            HapticManager.shared.tap()
                            inspectedTx = tx
                        } label: {
                            TxRow(tx: tx, sourceCard: selectedCard,
                                  showCard: false, animateEntrance: false)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                }
                .padding(.vertical, 12)
                .padding(.leading, 6)
            }
        }
    }

    // MARK: Trends · its own page

    private var trendsDetail: some View {
        let points = netWorthTrend
        let done = points.filter { !$0.isRunning }
        let avg = done.isEmpty ? 0 : done.reduce(0.0) { $0 + $1.expense } / Double(done.count)
        let highest = done.max { $0.expense < $1.expense }
        let lowest = done.min { $0.expense < $1.expense }
        let prev = points.count >= 2 ? points[points.count - 2].expense : 0
        let change: Double? = prev > 0 ? (trendTotal - prev) / prev * 100 : nil

        return ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    statHero(title: points.last?.label ?? loc("stats.this_month"),
                             subtitle: loc(payCycleDay != nil ? "stats.trend_by_cycle" : "stats.trend_by_month"),
                             value: trendTotal, tint: AppTheme.accent,
                             change: change, changeCaption: loc("stats.vs_prev_period"),
                             previous: prev)

                    chartCard(values: points.map(\.expense), labels: points.map { String($0.label.prefix(3)) },
                              tint: AppTheme.accent, highlightLast: true)

                    HStack(spacing: 10) {
                        factTile(loc("stats.trend_avg"), money(avg), AppTheme.accent)
                        factTile(loc("stats.trend_highest"), highest.map { money($0.expense) } ?? "—", AppTheme.red)
                        factTile(loc("stats.trend_lowest"), lowest.map { money($0.expense) } ?? "—", AppTheme.blue)
                    }

                    VStack(spacing: 10) {
                        ForEach(points.reversed()) { p in
                            Button {
                                HapticManager.shared.tap()
                                appVM.statsPath.append(.cycle(start: p.start, end: p.end, label: p.label))
                            } label: {
                                VStack(spacing: 10) {
                                    HStack {
                                        HStack(spacing: 6) {
                                            Text(p.label)
                                                .font(.system(.subheadline, weight: .bold))
                                                .foregroundStyle(AppTheme.textPrimary)
                                            if p.isRunning {
                                                Text(loc("stats.trend_running"))
                                                    .font(.system(.caption2, weight: .bold))
                                                    .foregroundStyle(AppTheme.orange)
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(AppTheme.orange.opacity(0.15), in: Capsule())
                                            }
                                        }
                                        Spacer()
                                        Text(String(format: loc("stats.tx_count"), p.txCount))
                                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                        Image(systemName: "chevron.right")
                                            .font(.system(.caption2, weight: .semibold))
                                            .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                                    }
                                    HStack(spacing: 0) {
                                        trendFigure(loc("stats.income"), p.income, AppTheme.accent)
                                        metricDivider
                                        trendFigure(loc("stats.expenses"), p.expense, AppTheme.red)
                                        metricDivider
                                        trendFigure(loc("stats.net"), p.net,
                                                    p.net >= 0 ? AppTheme.accent : AppTheme.red)
                                    }
                                }
                                .padding(14)
                                .contentShape(Rectangle())
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }
                    }

                    Spacer(minLength: 100)
                }
                .padding(.horizontal, 22).padding(.top, 8)
            }
        }
        .navigationTitle(loc("stats.trends"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: One cycle, opened up
    //
    // A bar on the Trends chart is a conclusion; this is the spending it was
    // drawn from, grouped by day. Built from the same rules as every other
    // figure on the screen so the days add up to the cycle.

    private func rangeLabel(_ start: Date, _ end: Date) -> String {
        let df = DateFormatter()
        df.locale = LanguageManager.shared.currentLocale
        df.dateFormat = DateFormatter.dateFormat(fromTemplate: "dMMM", options: 0,
                                                 locale: LanguageManager.shared.currentLocale)
        // Half-open window: the last day covered is the day before it ends.
        let last = Calendar.current.safeDate(byAdding: .day, value: -1, to: end)
        return "\(df.string(from: start)) – \(df.string(from: last))"
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return loc("common.today") }
        if cal.isDateInYesterday(day) { return loc("common.yesterday") }
        return DateFormatterCache.template("EEEEdMMM").string(from: day)
    }

    private func cycleDetail(start: Date, end: Date, label: String) -> some View {
        let txs = (selectedCard?.transactions ?? []).filter { $0.date >= start && $0.date < end }
        let income = txs.filter { $0.amount > 0 && $0.txSubtype == .normal }
            .reduce(0.0) { $0 + convertedAmount($1) }
        let expense = expenseSum(txs)
        let spend = txs.filter { $0.txSubtype != .transfer && ($0.amount < 0 || $0.txSubtype == .refund) }
        // Only the categories this cycle actually has, biggest first — a filter
        // offering empty options is a filter that wastes taps.
        let catTotals = Dictionary(grouping: spend, by: \.category)
            .map { (cat: $0.key, total: expenseSum($0.value)) }
            .sorted { $0.total > $1.total }
        let shown = cycleCategoryFilter.map { f in spend.filter { $0.category == f } } ?? spend
        let groups = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }
            .map { (day: $0.key, rows: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }

        return ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 12) {
                        VStack(spacing: 2) {
                            Text(label).font(.system(.subheadline, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(rangeLabel(start, end))
                                .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        }
                        Text(money(expense))
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.5)
                        HStack(spacing: 0) {
                            trendFigure(loc("stats.income"), income, AppTheme.accent)
                            metricDivider
                            trendFigure(loc("stats.expenses"), expense, AppTheme.red)
                            metricDivider
                            trendFigure(loc("stats.net"), income - expense,
                                        income - expense >= 0 ? AppTheme.accent : AppTheme.red)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(18)
                    .background {
                        RoundedRectangle(cornerRadius: AppRadius.xl).fill(AppTheme.cardDark)
                            .overlay {
                                LinearGradient(colors: [AppTheme.accent.opacity(0.18),
                                                        AppTheme.accent.opacity(0.04), .clear],
                                               startPoint: .topTrailing, endPoint: .bottomLeading)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
                    }

                    if !catTotals.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    categoryChip(loc("stats.filter_all"), nil, AppTheme.blue,
                                                 isOn: cycleCategoryFilter == nil)
                                    ForEach(catTotals, id: \.cat) { c in
                                        categoryChip(c.cat.displayLabel, c.cat, c.cat.color,
                                                     isOn: cycleCategoryFilter == c.cat)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            // What the filter currently adds up to, so the list is
                            // never a set of rows with no total attached.
                            HStack {
                                Text(cycleCategoryFilter?.displayLabel ?? loc("stats.filter_all"))
                                    .font(.system(.caption, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                Text("\(money(expenseSum(shown))) · \(String(format: loc("stats.tx_count"), shown.count))")
                                    .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                        }
                    }

                    if groups.isEmpty {
                        Text(loc(cycleCategoryFilter == nil ? "stats.cycle_empty"
                                                            : "stats.cycle_empty_cat"))
                            .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 28)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
                    } else {
                        ForEach(groups, id: \.day) { g in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(dayLabel(g.day))
                                        .font(.system(.footnote, weight: .semibold))
                                        .foregroundStyle(AppTheme.textSecondary)
                                    Spacer()
                                    Text(money(expenseSum(g.rows)))
                                        .font(.system(.caption, weight: .bold))
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                                VStack(spacing: 10) {
                                    ForEach(g.rows) { tx in
                                        Button {
                                            HapticManager.shared.tap()
                                            inspectedTx = tx
                                        } label: {
                                            TxRow(tx: tx, sourceCard: selectedCard,
                                                  showCard: false, animateEntrance: false)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(ScaleButtonStyle())
                                    }
                                }
                                .padding(14)
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                            }
                        }
                    }

                    Spacer(minLength: 100)
                }
                .padding(.horizontal, 22).padding(.top, 8)
            }
        }
        .navigationTitle(label)
        .navigationBarTitleDisplayMode(.inline)
        // Keyed to the cycle, not to appearing: opening a different cycle starts
        // unfiltered, but coming back from a transaction sheet keeps your filter.
        .task(id: label) { cycleCategoryFilter = nil }
        .sheet(item: $inspectedTx) { tx in
            TransactionDetailSheet(tx: tx)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }

    private func categoryChip(_ label: String, _ cat: TxCategory?, _ tint: Color, isOn: Bool) -> some View {
        Button {
            HapticManager.shared.tap()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                // Tapping the active chip clears back to All.
                cycleCategoryFilter = isOn ? nil : cat
            }
        } label: {
            Text(label)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(isOn ? AppTheme.onVividFill : AppTheme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(isOn ? tint : AppTheme.cardDark, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func trendFigure(_ label: String, _ value: Double, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
            Text(money(abs(value))).font(.system(.footnote, weight: .bold)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Shared pieces for the two detail pages

    private func statHero(title: String, subtitle: String, value: Double, tint: Color,
                          change: Double?, changeCaption: String, previous: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(subtitle).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
            }
            Text(money(value))
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            if let c = change {
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: c >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(.caption2, weight: .bold))
                        Text(String(format: "%.0f%%", abs(c))).font(.system(.caption2, weight: .bold))
                    }
                    .foregroundStyle(c >= 0 ? AppTheme.red : AppTheme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background((c >= 0 ? AppTheme.red : AppTheme.accent).opacity(0.15), in: Capsule())
                    Text("\(changeCaption) · \(money(previous))")
                        .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: AppRadius.xl).fill(AppTheme.cardDark)
                .overlay {
                    LinearGradient(colors: [tint.opacity(0.20), tint.opacity(0.05), .clear],
                                   startPoint: .topTrailing, endPoint: .bottomLeading)
                }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
        }
    }

    private func chartCard(values: [Double], labels: [String], tint: Color,
                           highlightLast: Bool) -> some View {
        MiniBars(values: values, labels: labels, tint: tint,
                 highlightLast: highlightLast, height: 130, maxBarWidth: 34)
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }

    private func factTile(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(.subheadline, weight: .bold)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14).padding(.horizontal, 6)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    /// Every figure the summary is built from, for anyone who wants to check it:
    /// the balance reconciliation, the daily allowance and its audit, fixed
    /// payments priced in goal-time, the net trend and every pattern.
    private var fullAnalysis: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(periodSubtitle)
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        if let main = selectedCard {
                            Text(String(format: loc("stats.main_card_line"), cardLabel(main)))
                                .font(.system(.caption))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .padding(.bottom, 4)

                    NetBalanceSummary(net: filteredIncome - filteredExpenses, income: filteredIncome,
                                      expenses: filteredExpenses, currency: displayCurrency,
                                      cardBalanceNow: selectedCard?.computedBalance(),
                                      startBalance: periodStartBalance,
                                      transferNet: periodTransferNet,
                                      progress: periodProgress,
                                      previousExpenses: previousPeriodExpenses)

                    // The trend's working lives here now: the main page carries a
                    // compact "Trends" tile, and this is the one tap away.
                    SpendingTrendCard(trend: netWorthTrend, currency: displayCurrency,
                                      byPayCycle: payCycleDay != nil)

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
                        } else {
                            insightsCard
                                .blur(radius: 7)
                                .allowsHitTesting(false)
                                .overlay { lockedInsightsOverlay }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    HapticManager.shared.tap()
                                    NotificationCenter.default.post(name: .requestOpenPaywall, object: nil)
                                }
                        }
                    }

                    if premiumMgr.canAccess(.smartBudget), !commitmentReview.lines.isEmpty {
                        CommitmentPriorityCard(review: commitmentReview,
                                               currency: displayCurrency,
                                               dailyAllowance: dailyAllowance,
                                               typicalDaily: typicalDailySpend,
                                               irregularThisCycle: irregularSpend.total,
                                               daysInCycle: periodProgress?.total ?? periodDays)
                    }

                    // No trend chart here. The net-flow bars repeated the spending
                    // chart on the main page in other colours; that chart's
                    // breakdown already lists money in, money out and the net for
                    // every period.

                    if premiumMgr.canAccess(.smartBudget), !patternRows.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(loc("stats.patterns"))
                                .font(.system(.body, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .padding(.bottom, 4)
                            ForEach(Array(patternRows.enumerated()), id: \.offset) { _, row in
                                noteRow(row.icon, row.tint, row.title, row.detail)
                            }
                        }
                        .padding(16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
            }
        }
        .navigationTitle(loc("stats.detail_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.bg, for: .navigationBar)
    }
}

// MARK: - Mini bar chart
//
// Seven-ish bars with their labels — the shape of a week or of the months, at
// tile size. The tallest bar (or the current one) is the only one at full
// strength, so the eye lands on the answer rather than reading every column.

private struct MiniBars: View {
    let values: [Double]
    let labels: [String]
    let tint: Color
    var highlightLast: Bool = false
    var height: CGFloat = 36
    /// Capped so a chart with only three bars draws bars, not lozenges.
    var maxBarWidth: CGFloat = 22

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        let hotIndex = highlightLast
            ? values.count - 1
            : (values.firstIndex(of: values.max() ?? 0) ?? -1)
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(i == hotIndex ? tint : tint.opacity(0.28))
                        // A floor of 3pt so an empty day still reads as a day.
                        .frame(height: max(CGFloat(v / peak) * height, 3))
                        .frame(maxWidth: maxBarWidth)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack(spacing: 4) {
                ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
                    Text(l)
                        .font(.system(size: 9, weight: i == hotIndex ? .bold : .medium))
                        .foregroundStyle(i == hotIndex ? AppTheme.textPrimary
                                                       : AppTheme.textSecondary.opacity(0.8))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Spending trend

/// Spending per period, the latest one highlighted, against the average of the
/// periods that have finished. Answers "is this more than usual" at a glance;
/// tapping opens the numbers behind every bar.
struct SpendingTrendCard: View {
    let trend: [CycleTrendPoint]
    let currency: String
    var byPayCycle: Bool = false
    @State private var showBreakdown = false
    @State private var appeared = false

    private var finished: [CycleTrendPoint] { trend.filter { !$0.isRunning && $0.expense > 0 } }
    private var average: Double? {
        guard !finished.isEmpty else { return nil }
        return finished.reduce(0) { $0 + $1.expense } / Double(finished.count)
    }
    private var peak: Double { max(trend.map(\.expense).max() ?? 0, average ?? 0, 1) }

    var body: some View {
        if trend.contains(where: { $0.expense > 0 }) {
            Button {
                HapticManager.shared.tap()
                showBreakdown = true
            } label: {
                content
            }
            .buttonStyle(ScaleButtonStyle())
            .sheet(isPresented: $showBreakdown) {
                CycleTrendBreakdown(trend: trend, currency: currency)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc(byPayCycle ? "stats.trend_title_cycle" : "stats.trend_title"))
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(loc("stats.trend_hint"))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer(minLength: 8)
                if let average {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(loc("stats.trend_average"))
                            .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        Text(CurrencyManager.shared.formatted(average, currency: currency))
                            .font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    }
                }
            }

            let chartH: CGFloat = 96
            ZStack(alignment: .bottom) {
                if let average {
                    // The usual level, so each bar reads as above or below it.
                    Rectangle()
                        .fill(AppTheme.textSecondary.opacity(0.45))
                        .frame(height: 1)
                        .padding(.bottom, chartH * CGFloat(average / peak))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(Array(trend.enumerated()), id: \.element.id) { i, point in
                        let isLast = i == trend.count - 1
                        let h = max(chartH * CGFloat(point.expense / peak), point.expense > 0 ? 4 : 2)
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isLast ? AppTheme.red : AppTheme.red.opacity(0.28))
                                .frame(height: appeared ? h : 2)
                                .animation(.spring(response: 0.6, dampingFraction: 0.8)
                                    .delay(Double(i) * 0.05), value: appeared)
                        }
                        .frame(maxWidth: .infinity, maxHeight: chartH, alignment: .bottom)
                    }
                }
            }
            .frame(height: chartH)

            HStack(spacing: 10) {
                ForEach(Array(trend.enumerated()), id: \.element.id) { i, point in
                    let isLast = i == trend.count - 1
                    Text(point.label)
                        .font(.system(.caption2, weight: isLast ? .bold : .regular))
                        .foregroundStyle(isLast ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        .onAppear { appeared = true }
    }
}

// MARK: - Summary Cards

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
            Image(systemName: icon).font(.system(.caption2, weight: .bold)).imageScale(.small)
            Text(text).font(.system(.caption2, weight: .semibold))
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
                        .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                    Text(loc("stats.net_balance_sub"))
                        .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary.opacity(0.75))
                }
                Spacer()
                Text(net >= 0 ? "\(CurrencyManager.shared.formatted(net, currency: currency))"
                             : CurrencyManager.shared.formatted(net, currency: currency))
                    .font(.system(.callout, weight: .bold))
                    .foregroundStyle(net >= 0 ? AppTheme.accent : AppTheme.red)
                    .contentTransition(.numericText())
            }
            // Share of income spent, warming from green to red as it fills, with
            // a tick where TIME is: a bar ending past it is ahead of the calendar.
            SpendGauge(fraction: income > 0 ? expenses / income : 0,
                       timeMarker: progress.map { Double($0.elapsed) / Double($0.total) },
                       height: 8)
            HStack {
                Text(String(format: loc("stats.percentage_spent"), String(format: "%.0f", spentPct)))
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text(net >= 0
                     ? String(format: loc(progress == nil ? "stats.saved" : "stats.saved_sofar"),
                              String(format: "%.0f%%", savedPct))
                     : loc("stats.overspent"))
                    .font(.system(.caption2, weight: .medium))
                    .foregroundStyle(SpendGauge.tone(for: income > 0 ? expenses / income : 1))
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
                            .font(.system(.caption2, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                        Spacer()
                        Text("= " + (closing < 0 ? "-" : "") + CurrencyManager.shared.formatted(abs(closing), currency: currency))
                            .font(.system(.caption, weight: .bold))
                            .foregroundStyle(closing >= 0 ? AppTheme.accent : AppTheme.red)
                    }
                }
            } else if let balance = cardBalanceNow {
                Divider().background(AppTheme.cardMid)
                HStack {
                    Text(loc("stats.card_balance_now"))
                        .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Text((balance < 0 ? "-" : "") + CurrencyManager.shared.formatted(abs(balance), currency: currency))
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(balance >= 0 ? AppTheme.textPrimary : AppTheme.red)
                }
            }
        }
        .padding(.vertical, 16).padding(.horizontal, 18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private func reconRow(_ label: String, _ value: Double, signed: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text((value < 0 ? "−" : signed ? "+" : "")
                 + CurrencyManager.shared.formatted(abs(value), currency: currency))
                .font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
        }
    }
}

// MARK: - Trend point

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
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.purple)
                }
                Text(loc("stats.insights"))
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
            }
            
            // Weekly Average — hero metric
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.purple)
                    Text(loc("stats.weekly_avg"))
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                    if isPartialPeriod {
                        // Caveat chip — this window is too short for a stable
                        // weekly rate, so mark it as a partial estimate.
                        HStack(spacing: 3) {
                            Image(systemName: "info.circle.fill").font(.system(.caption2)).imageScale(.small)
                            Text(loc("stats.weekly_avg_partial_badge"))
                                .font(.system(.caption2, weight: .semibold))
                        }
                        .foregroundStyle(AppTheme.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(AppTheme.orange.opacity(0.12), in: Capsule())
                    }
                }
                Text(CurrencyManager.shared.formatted(weeklyAverage, currency: currency))
                    .font(.system(.title, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())
                Text(isPartialPeriod
                     ? String(format: loc("stats.weekly_avg_partial_sub"), periodDays)
                     : loc("stats.weekly_avg_sub"))
                    .font(.system(.caption2))
                    .foregroundStyle(isPartialPeriod ? AppTheme.orange.opacity(0.9) : AppTheme.textSecondary.opacity(0.8))

                // The figure only means something against what a day HAS.
                if let allowance = dailyAllowance, allowance > 0 {
                    let daily = weeklyAverage / 7
                    HStack(spacing: 5) {
                        Image(systemName: daily <= allowance ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(.caption2)).imageScale(.small)
                        Text(String(format: loc("stats.daily_vs_allowance"),
                                    CurrencyManager.shared.formatted(daily, currency: currency),
                                    CurrencyManager.shared.formatted(allowance, currency: currency)))
                            .font(.system(.caption2, weight: .medium))
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
                                .font(.system(.caption2, weight: .semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(.caption2, weight: .bold)).imageScale(.small)
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
                        .font(.system(.caption2))
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
                in: RoundedRectangle(cornerRadius: AppRadius.md)
            )
            
        }
        .padding(.vertical, 16).padding(.horizontal, 18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                appeared = true
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
    /// Spending over the same stretch of the previous period, for the change chip.
    var previousExpenses: Double? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: ShareItem?
    @State private var isGenerating = false

    private func cardDisplayLabel(_ card: BankCard) -> String {
        if card.isDigitalWallet, !card.walletProvider.isEmpty {
            return card.walletProvider
        }
        let holder = card.holderName.split(separator: " ").first.map(String.init) ?? card.holderName
        return "\(holder) ••\(card.last4)"
    }

    private var report: StatsReportCard {
        StatsReportCard(
            periodSubtitle: periodSubtitle,
            cardLabel: selectedCard.map(cardDisplayLabel) ?? "—",
            cardColor: selectedCard.map { Color(hex: $0.gradientStart) } ?? AppTheme.accent,
            income: income,
            budgetIncome: budgetIncome,
            expenses: expenses,
            weeklyAverage: weeklyAverage,
            topCategories: topCategories,
            transactionCount: transactions.count,
            currency: currency,
            cardID: selectedCard?.id.uuidString,
            configs: configs,
            filteredTransactions: transactions,
            previousExpenses: previousExpenses
        )
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        Text(loc("stats.export_hint"))
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 30)

                        // The preview IS the image: the same view, at the same
                        // width it is rendered at.
                        report
                            .frame(maxWidth: 400)
                            .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
                            .padding(.horizontal, 18)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 110)
                }

                Button {
                    HapticManager.shared.tap()
                    exportImage()
                } label: {
                    HStack(spacing: 10) {
                        if isGenerating {
                            ProgressView().tint(AppTheme.onVividFill)
                        } else {
                            Image(systemName: "square.and.arrow.up").font(.system(.body, weight: .semibold))
                        }
                        Text(loc("stats.export_image"))
                            .font(.system(.callout, weight: .bold))
                    }
                    .foregroundStyle(AppTheme.onVividFill)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(isGenerating)
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
                .background(
                    LinearGradient(colors: [AppTheme.bg.opacity(0), AppTheme.bg],
                                   startPoint: .top, endPoint: .center)
                        .ignoresSafeArea()
                )
            }
            .navigationTitle(loc("stats.export_preview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(items: [item.url])
        }
    }

    // MARK: - Export

    /// Renders the report to a PNG at 3× and hands it to the share sheet, in the
    /// app's own light/dark setting so the image matches what was previewed.
    @MainActor
    private func exportImage() {
        isGenerating = true
        let cardName = selectedCard.map(cardDisplayLabel) ?? "—"
        let resolvedScheme: ColorScheme = {
            if let pref = appColorScheme() { return pref }
            return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        }()

        let content = report
            .frame(width: 390)
            .padding(18)
            .background(AppTheme.bg)
            .environment(\.colorScheme, resolvedScheme)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 3.0

        guard let uiImg = renderer.uiImage, let data = uiImg.pngData() else {
            isGenerating = false
            return
        }
        let filename = "DiPo_\(cardName.replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970)).png"
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

// MARK: - Stats Report Card (preview and PNG export)

/// The report as an image someone would actually send: the same four answers
/// as the Statistics screen, in the same colours, sized for a phone story.
///
/// It used to lead on a net figure in a green or red wash, set income and
/// spending in two boxes, rank categories with orange/grey/purple medals in the
/// old muted category colours, and close on a bordered tinted advice box — a
/// different visual language from the screen it was exported from.
struct StatsReportCard: View {
    let periodSubtitle: String
    let cardLabel: String
    let cardColor: Color
    let income: Double
    /// Income for BUDGET MATH (the recommendation): the salary schedule when
    /// there is one, so a period ending before payday doesn't distort it.
    var budgetIncome: Double? = nil
    private var insightIncome: Double { budgetIncome ?? income }
    let expenses: Double
    let weeklyAverage: Double
    let topCategories: [(category: TxCategory, amount: Double, percentage: Double)]
    let transactionCount: Int
    let currency: String
    /// Card whose ratios appear in the budget split. nil = global defaults.
    let cardID: String?
    let configs: [CardBudgetConfig]
    /// The period's transactions — for the same `topInsight()` Home uses.
    let filteredTransactions: [TxRecord]
    var previousExpenses: Double? = nil

    @Environment(\.colorScheme) private var colorScheme

    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: currency)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            spendingBlock
            if !topCategories.isEmpty { categoriesBlock }
            insightBlock
            if SmartBudgetManager.shared.hasActiveBudget, income > 0 { budgetBlock }
            footer
        }
        .padding(20)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("DiPoMascot")
                .resizable().scaledToFit()
                .frame(width: 34, height: 34)
                .blendMode(colorScheme == .dark ? .screen : .multiply)
            VStack(alignment: .leading, spacing: 1) {
                Text(loc("stats.report_title"))
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(periodSubtitle)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                Circle().fill(cardColor).frame(width: 7, height: 7)
                Text(cardLabel)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(AppTheme.cardMid.opacity(0.6), in: Capsule())
        }
    }

    private var spendingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("stats.expenses"))
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(money(expenses))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.55)
            }
            if let prev = previousExpenses, prev > 0 {
                let change = (expenses - prev) / prev * 100
                let up = change >= 0
                Label(String(format: loc(up ? "stats.vs_prev_up" : "stats.vs_prev_down"),
                             Int(abs(change).rounded())),
                      systemImage: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(up ? AppTheme.red : AppTheme.accent)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background((up ? AppTheme.red : AppTheme.accent).opacity(0.12), in: Capsule())
            }
            if income > 0 {
                let used = expenses / income
                SpendGauge(fraction: used)
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(loc("stats.income")).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        Text(money(income)).font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(loc(income >= expenses ? "stats.left" : "stats.over"))
                            .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        Text(money(abs(income - expenses)))
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(SpendGauge.tone(for: used))
                    }
                }
            }
        }
    }

    private var categoriesBlock: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(loc("stats.where_title"))
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
            ForEach(Array(topCategories.prefix(5).enumerated()), id: \.offset) { _, item in
                ReportCategoryRow(category: item.category, amount: item.amount,
                                  percentage: item.percentage, currency: currency)
            }
        }
    }

    private var insightBlock: some View {
        let insight = SmartBudgetManager.shared.topInsight(
            allTransactions: filteredTransactions,
            income: insightIncome,
            cardID: cardID,
            configs: configs,
            targetCurrency: currency,
            periodStart: filteredTransactions.map(\.date).min()
        )
        let (icon, tint, title, body): (String, Color, String, String) = {
            if let insight { return (insight.icon, insight.color, insight.title, insight.body) }
            if insightIncome <= 0 {
                return ("info.circle.fill", AppTheme.textSecondary,
                        loc("rec.no_income_title"), loc("rec.no_income_body"))
            }
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

        return VStack(alignment: .leading, spacing: 10) {
            Text(loc("stats.notes_title"))
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
            reportNote(icon, tint, title, body)
            if weeklyAverage > 0 {
                reportNote("cup.and.saucer.fill", AppTheme.purple,
                           String(format: loc("stats.weekly_line"), money(weeklyAverage)),
                           String(format: loc("stats.report_tx_inline"), transactionCount))
            }
        }
    }

    private func reportNote(_ icon: String, _ tint: Color, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.xs))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(body)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// The budget split as one bar in the group colours — the same three
    /// shares the Smart Budget screen uses.
    private var budgetBlock: some View {
        let r = SmartBudgetManager.shared.ratios(forCardID: cardID, configs: configs)
        let parts: [(String, Double, Color)] = [
            (loc("budget.group.daily"), r.daily, AppTheme.blue),
            (loc("budget.group.lifestyle"), r.lifestyle, AppTheme.purple),
            (loc("budget.group.invest_debt"), r.investDebt, AppTheme.accent),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text(loc("budget.allocation_title"))
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
            GeometryReader { g in
                HStack(spacing: 3) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        Capsule().fill(part.2)
                            .frame(width: max((g.size.width - 6) * CGFloat(part.1), 4))
                    }
                }
            }
            .frame(height: 8)
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Circle().fill(part.2).frame(width: 7, height: 7)
                            Text(part.0).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        Text("\(Int((part.1 * 100).rounded()))% · " + money(income * part.1))
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Rectangle().fill(AppTheme.cardMid).frame(height: 1)
            Text(String(format: loc("stats.generated_by"), Date().displayDateTimeShort))
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: true, vertical: false)
            Rectangle().fill(AppTheme.cardMid).frame(height: 1)
        }
    }
}

/// A category in the report: its list colour, its share as a bar, its amount.
struct ReportCategoryRow: View {
    let category: TxCategory
    let amount: Double
    let percentage: Double
    let currency: String

    var body: some View {
        let hue = Color(hex: category.iconBg)
        HStack(spacing: 10) {
            Image(systemName: category.icon)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(hue, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(category.displayLabel)
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(CurrencyManager.shared.formatted(amount, currency: currency))
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Text("\(Int(percentage.rounded()))%")
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 32, alignment: .trailing)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.cardMid.opacity(0.8))
                        Capsule().fill(hue)
                            .frame(width: max(g.size.width * CGFloat(percentage / 100), 3))
                    }
                }
                .frame(height: 5)
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
                            .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)

                        ForEach(trend.reversed()) { p in
                            VStack(spacing: 9) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(p.label)
                                                .font(.system(.subheadline, weight: .bold))
                                                .foregroundStyle(AppTheme.textPrimary)
                                            if p.isRunning {
                                                Text(loc("stats.trend_running"))
                                                    .font(.system(.caption2, weight: .bold))
                                                    .foregroundStyle(AppTheme.orange)
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(AppTheme.orange.opacity(0.15), in: Capsule())
                                            }
                                        }
                                        Text(range(p))
                                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                    }
                                    Spacer()
                                    Text((p.net >= 0 ? "+" : "−") + money(abs(p.net)))
                                        .font(.system(.callout, weight: .bold))
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
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                            .padding(.horizontal, 22)
                        }

                        Text(loc("stats.trend_detail_note"))
                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
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
            Text(l).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(v).font(.system(.caption, weight: .semibold)).foregroundStyle(tint)
        }
    }
}
