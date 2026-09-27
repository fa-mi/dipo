import SwiftUI
import SwiftData

// Part of StatisticsView, moved out of StatisticsView.swift unchanged. Period boundaries and the figures the screen shows: the arithmetic, no views.

extension StatisticsView {
    /// Count of "Other" expenses the categoriser could confidently re-map.
    /// Day-of-month the salary lands on (from the first active schedule), used
    /// to anchor the "Pay cycle" period. nil when the user has no active
    /// salary — in which case the Pay-cycle option is hidden entirely.
    var payCycleDay: Int? {
        MainCard.payDay(salarySchedules)
    }

    /// Income for BUDGET MATH in the export insight: the stated salary schedule
    /// when there is one (so a pre-payday period doesn't distort the ratio),
    /// otherwise actual income received in the period.
    var budgetInsightIncome: Double {
        let active = MainCard.salaries(salarySchedules)
        guard !active.isEmpty else { return filteredIncome }
        return active.reduce(0.0) { $0 + CurrencyManager.shared.convert($1.amount, from: $1.currency, to: displayCurrency) }
    }

    /// Periods shown as chips. "Pay cycle" only appears when there's a salary
    /// schedule to anchor it on; otherwise it would be meaningless.
    var availablePeriods: [StatPeriod] {
        StatPeriod.allCases.filter { $0 != .payCycle || payCycleDay != nil }
    }

    /// Dates the salary actually landed. Used to anchor cycle boundaries so
    /// Statistics and Smart Budget agree on where a cycle begins.
    var salaryTxDates: [Date] {
        (selectedCard?.transactions ?? []).filter { $0.category == .salary && $0.amount > 0 }.map(\.date)
    }

    /// The anchored payday for a month offset from today. Every cycle boundary
    /// in this screen goes through here, so a cycle is always [payday, next
    /// payday) — never "start plus one calendar month", which drifts whenever a
    /// payday is pulled off a weekend or holiday. For this user's data the real
    /// gaps are 28 and 32 days, not two equal months.
    static func cycleBoundary(monthsFromNow offset: Int, payDay: Int?, salaryDates: [Date]) -> Date? {
        guard let day = payDay else { return nil }
        let cal = Calendar.current
        let base = StatPeriod.anchoredStart(StatPeriod.payCycleRange(payDay: day).start,
                                            salaryDates: salaryDates)
        let shifted = cal.safeDate(byAdding: .month, value: offset, to: base)
        let m = cal.component(.month, from: shifted), y = cal.component(.year, from: shifted)
        return StatPeriod.anchoredStart(
            cal.startOfDay(for: SalaryDateEngine.actualPayDate(dayOfMonth: day, month: m, year: y)),
            salaryDates: salaryDates)
    }

    func cycleBoundary(monthsFromNow offset: Int) -> Date? {
        Self.cycleBoundary(monthsFromNow: offset, payDay: payCycleDay, salaryDates: salaryTxDates)
    }

    var effectiveRange: (start: Date, end: Date) {
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
    static func progress(start: Date, end: Date, payDay: Int?,
                         salaryDates: [Date]) -> (elapsed: Int, total: Int)? {
        let cal = Calendar.current
        // A period that already ended needs no caveat.
        guard end > Date() || cal.isDateInToday(end) else { return nil }
        // Cycle length = this payday to the next one, not a calendar month.
        let cycleEnd = cycleBoundary(monthsFromNow: 1, payDay: payDay, salaryDates: salaryDates)
            ?? (cal.date(byAdding: .month, value: 1, to: start) ?? end)
        let total = max(cal.dateComponents([.day], from: start, to: cycleEnd).day ?? 30, 1)
        let elapsed = min(max((cal.dateComponents([.day], from: start, to: Date()).day ?? 0) + 1, 1), total)
        return elapsed >= total ? nil : (elapsed, total)
    }

    // MARK: Period figures — one definition, shared with the web dashboard
    //
    // The hero's income, spending and "same days last time" comparison, as
    // functions rather than view state. The web dashboard rebuilt them in
    // JavaScript with its own rules — refunds counted as income, the cycle
    // opening on the 25th rather than the day the salary landed, a running
    // cycle compared against a whole finished one — and so quoted a different
    // "left to spend" from the phone for the same data. The phone now computes
    // the figures once, here, and the sync sends them.

    /// Money in: real income only. A transfer is your own money moving, and a
    /// refund reverses an expense, so it is counted on that side instead.
    static func income(_ txs: [TxRecord], convert: (TxRecord) -> Double) -> Double {
        txs.filter { $0.amount > 0 && $0.txSubtype == .normal }
            .reduce(0) { $0 + convert($1) }
    }

    /// Money out: outflows minus refunds, transfers skipped. The same model the
    /// Smart Budget engine uses in `spent(in:)`, so card balance, stats and
    /// budget agree.
    static func expenses(_ txs: [TxRecord], convert: (TxRecord) -> Double) -> Double {
        txs.filter { $0.txSubtype != .transfer }
            .reduce(0.0) { sum, tx in
                let amt = abs(convert(tx))
                if tx.txSubtype == .refund { return sum - amt }
                return tx.amount < 0 ? sum + amt : sum
            }
    }

    /// Where the previous pay cycle began: last month's pay date, moved off a
    /// weekend the way the salary itself is — not one calendar month back. For
    /// a payday on the 25th, July 25 2026 is a Saturday and the salary lands
    /// Friday July 24, one day BEFORE a naive window opens; the comparison then
    /// misses a whole salary and reports a flat income as +400%.
    static func previousCycleStart(before start: Date, payDay: Int) -> Date {
        let cal = Calendar.current
        let m = cal.component(.month, from: start)
        let y = cal.component(.year,  from: start)
        let pm = m == 1 ? 12 : m - 1
        let py = m == 1 ? y - 1 : y
        return cal.startOfDay(
            for: SalaryDateEngine.actualPayDate(dayOfMonth: payDay, month: pm, year: py))
    }

    /// Income or spending over [from, to) under the SAME rules as the period
    /// it is compared with. It used to sum raw outflows and every inflow, so a
    /// refund made last cycle look richer and costlier than the one it was
    /// set against. Nil when nothing moved that way — no data is not zero.
    static func stretchTotal(_ txs: [TxRecord], from: Date, to: Date, income wantIncome: Bool,
                             convert: (TxRecord) -> Double) -> Double? {
        let slice = txs.filter { $0.date >= from && $0.date < to }
        let moved = slice.contains {
            wantIncome ? ($0.amount > 0 && $0.txSubtype == .normal)
                       : ($0.amount < 0 && $0.txSubtype != .transfer)
        }
        guard moved else { return nil }
        return wantIncome ? income(slice, convert: convert) : expenses(slice, convert: convert)
    }

    /// The pay-cycle hero's figures for one card, in one currency.
    struct CycleFigures {
        let start: Date
        let end: Date
        let income: Double
        let spent: Double
        var left: Double { income - spent }
        /// Day N of M while the cycle runs; nil once it has ended.
        let progress: (elapsed: Int, total: Int)?
        /// The same days of the previous cycle — what the hero's chip compares.
        let previousIncome: Double?
        let previousSpent: Double?
    }

    /// Exactly what Statistics shows for the pay cycle — the anchored window,
    /// the same rules, the same comparison — for a caller that is not this
    /// screen. Built from the same pieces `effectiveRange`, `filteredTx` and
    /// `previousPeriodTotal` use, so the two cannot drift.
    static func cycleFigures(card: BankCard, payDay: Int, currency: String) -> CycleFigures {
        let convert: (TxRecord) -> Double = { tx in
            let from = tx.currency.isEmpty ? card.resolvedCurrency : tx.currency
            return CurrencyManager.shared.convert(tx.amount, from: from, to: currency)
        }
        let all = card.transactions
        let salaryDates = all.filter { $0.category == .salary && $0.amount > 0 }.map(\.date)
        let r = StatPeriod.payCycleRange(payDay: payDay)
        let start = StatPeriod.anchoredStart(r.start, salaryDates: salaryDates)
        let window = all.filter { $0.date >= start && $0.date <= r.end }
        let p = progress(start: start, end: r.end, payDay: payDay, salaryDates: salaryDates)
        let prevStart = previousCycleStart(before: start, payDay: payDay)
        let cutoff = p.flatMap {
            Calendar.current.date(byAdding: .day, value: $0.elapsed, to: prevStart)
        } ?? start
        return CycleFigures(
            start: start, end: r.end,
            income: income(window, convert: convert),
            spent: expenses(window, convert: convert),
            progress: p,
            previousIncome: stretchTotal(all, from: prevStart, to: cutoff, income: true, convert: convert),
            previousSpent: stretchTotal(all, from: prevStart, to: cutoff, income: false, convert: convert))
    }

    var periodProgress: (elapsed: Int, total: Int)? {
        let (start, end) = effectiveRange
        return Self.progress(start: start, end: end,
                             payDay: payCycleDay, salaryDates: salaryTxDates)
    }

    /// Income over the same elapsed length one period back.
    var previousPeriodIncome: Double? {
        previousPeriodTotal(positive: true)
    }
    /// Same length of time, one period earlier — the only fair thing to compare
    /// a running period against.
    var previousPeriodExpenses: Double? { previousPeriodTotal(positive: false) }

    func previousPeriodTotal(positive: Bool) -> Double? {
        let cal = Calendar.current
        let (start, _) = effectiveRange

        // The previous window begins where the previous CYCLE actually began —
        // see `previousCycleStart` for why that is not one calendar month back.
        let prevStart: Date
        if selectedPeriod == .payCycle, let day = payCycleDay {
            prevStart = Self.previousCycleStart(before: start, payDay: day)
        } else {
            guard let naive = cal.date(byAdding: .month, value: -1, to: start) else { return nil }
            prevStart = naive
        }
        let cutoff: Date = {
            guard let p = periodProgress else { return start }
            return cal.date(byAdding: .day, value: p.elapsed, to: prevStart) ?? start
        }()
        return Self.stretchTotal(selectedCard?.transactions ?? [], from: prevStart, to: cutoff,
                                 income: positive, convert: convertedAmount)
    }


    /// Lock overlay shown on top of the blurred Smart Insights card for
    /// free users. Crown + "upgrade" affordance — tapping anywhere on the
    /// card opens the Royal paywall.
    var lockedInsightsOverlay: some View {
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

    var periodSubtitle: String {
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
    var cardsWithActivity: [BankCard] {
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
    var selectedCard: BankCard? {
        let _ = sb.budgetCardID
        return MainCard.resolve(in: appVM.cards)
    }
    
    /// The currency used to display all stats. Always derived from the selected card —
    /// stats show in the card's native currency, with cross-currency tx converted via CurrencyManager.
    var displayCurrency: String {
        selectedCard?.resolvedCurrency ?? CurrencyManager.shared.preferredCurrency
    }
    
    /// Transactions belonging to the selected card, within the selected period.
    /// Reads the memoized cache — populated by `recomputeStats()`.
    var filteredTx: [TxRecord] { cachedFilteredTx }

    /// Total transaction count across cards — cheap change-signal that triggers
    /// a stats recompute when a tx is added/removed.
    var statTxCount: Int { appVM.cards.reduce(0) { $0 + $1.transactions.count } }

    func computeFilteredTx() -> [TxRecord] {
        guard let card = selectedCard else { return [] }
        let (start, end) = effectiveRange
        return card.transactions.filter { $0.date >= start && $0.date <= end }
    }

    /// Recompute the memoized heavy derivations. Called on appear and whenever
    /// period / card / custom dates / tx count change — never per render.
    func recomputeStats() {
        // Rhythm first: everything below reads it.
        cachedRhythm = computeRhythm()
        cachedFilteredTx = computeFilteredTx()
        // Figures LAST: they read both of the above.
        cachedFigures = computeFigures()
        cachedNetWorthTrend = computeNetWorthTrend()
    }
    
    /// Convert a tx amount to the display currency (the selected card's currency).
    /// Handles legacy tx where currency may differ from card's currency.
    func convertedAmount(_ tx: TxRecord) -> Double {
        let txCurrency = tx.currency.isEmpty ? displayCurrency : tx.currency
        return CurrencyManager.shared.convert(tx.amount, from: txCurrency, to: displayCurrency)
    }
    
    /// Net movement from transfers & CC payments within the period. Excluded
    /// from income/expenses by design, but they DO move the card balance — this
    /// is the missing piece that reconciles "net this period" to the balance.
    var periodTransferNet: Double {
        filteredTx.filter { $0.txSubtype == .transfer }
            .reduce(0.0) { $0 + convertedAmount($1) }
    }

    /// Card balance at the START of the period: seed + every tx before it.
    var periodStartBalance: Double? {
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
    var filteredIncome: Double {
        Self.income(filteredTx, convert: convertedAmount)
    }

    /// Expenses for the period. Skip transfers (movement between user's own
    /// accounts, not real spend) and SUBTRACT refunds (refund cancels an
    /// earlier expense in the same category). Same model the SmartBudget
    /// engine uses in `spent(in:)` so card balance, stats, and budget all
    /// agree on the numbers.
    var filteredExpenses: Double {
        Self.expenses(filteredTx, convert: convertedAmount)
    }
    
    /// The same expense rule as `filteredExpenses`, applied to any slice — so
    /// today's figure and the weekly bars agree with the period total instead of
    /// each inventing their own definition of "spent".
    func expenseSum(_ txs: [TxRecord]) -> Double {
        Self.expenses(txs, convert: convertedAmount)
    }

    /// Spent so far today. Deliberately NOT period-filtered — "today" is today
    /// whichever window the user is looking at.
    var todaySpend: Double {
        guard let card = selectedCard else { return 0 }
        let cal = Calendar.current
        return expenseSum(card.transactions.filter { cal.isDateInToday($0.date) })
    }

    /// A Monday-first calendar, in the app's language.
    var weekCalendar: Calendar {
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
    var weekDays: [WeekDay] { weekDays { _ in true } }

    /// This week day by day, keeping only the rows the filter admits — so the
    /// chart, the day figures and the lists under them all narrow together.
    func weekDays(_ keep: (TxRecord) -> Bool) -> [WeekDay] {
        let cal = weekCalendar
        guard selectedCard != nil,
              let week = cal.dateInterval(of: .weekOfYear, for: Date()) else { return [] }
        let short = cal.veryShortWeekdaySymbols            // Sunday-first
        let full = cal.weekdaySymbols
        return (0..<7).compactMap { i in
            guard let day = cal.date(byAdding: .day, value: i, to: week.start) else { return nil }
            let rows = spendTx(on: day).filter(keep)
            let idx = (i + 1) % 7
            return WeekDay(date: day, short: short[idx], full: full[idx],
                           amount: expenseSum(rows), txCount: rows.count)
        }
    }

    /// Every row this week that counts as spending — what the chips are built from.
    var weekSpendTx: [TxRecord] {
        let cal = weekCalendar
        guard let card = selectedCard,
              let w = cal.dateInterval(of: .weekOfYear, for: Date()) else { return [] }
        return card.transactions.filter {
            $0.date >= w.start && $0.date < w.end
                && $0.txSubtype != .transfer && ($0.amount < 0 || $0.txSubtype == .refund)
        }
    }

    /// The rows that make up a day's spend — exactly the ones `expenseSum` counts
    /// (refunds included, transfers and income left out), so the list opened under
    /// a day adds up to the figure printed beside it.
    func spendTx(on day: Date) -> [TxRecord] {
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

    var weekBars: [(label: String, value: Double)] {
        weekDays.map { ($0.short, $0.amount) }
    }

    var weekTotal: Double { weekDays.reduce(0) { $0 + $1.amount } }

    /// Last week's total under the same filter, for the Weekly page's comparison.
    func previousWeekTotal(_ keep: (TxRecord) -> Bool) -> Double {
        guard let card = selectedCard else { return 0 }
        let cal = weekCalendar
        guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: Date()),
              let lastWeekDay = cal.date(byAdding: .day, value: -7, to: thisWeek.start),
              let lastWeek = cal.dateInterval(of: .weekOfYear, for: lastWeekDay) else { return 0 }
        return expenseSum(card.transactions.filter {
            $0.date >= lastWeek.start && $0.date < lastWeek.end && keep($0)
        })
    }

    /// Expense per completed cycle/month — the Trends tile's bars.
    var trendBars: [(label: String, value: Double)] {
        netWorthTrend.suffix(7).map { (String($0.label.prefix(1)), $0.expense) }
    }
    var trendTotal: Double { netWorthTrend.last?.expense ?? 0 }

    /// What's left of the period's income after what's gone out. Nil when no
    /// income landed in the window — then the hero reports spending instead of
    /// inventing a budget the user never set.
    var leftToSpend: Double? {
        filteredIncome > 0 ? filteredIncome - filteredExpenses : nil
    }

    /// Share of the period's income already spent, 0...1.
    var spentRatio: Double {
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
    var rhythm: SpendingRhythm { cachedRhythm }

    func computeRhythm() -> SpendingRhythm {
        SpendingRhythm(history: selectedCard?.transactions ?? []) { tx in
            self.convertedAmount(tx)
        }
    }

    /// Whether a transaction is part of "what a day costs".
    ///
    /// Fixed monthly commitments are excluded by category — those are
    /// contractual, not behavioural. Everything else is the engine's call,
    /// overridable per transaction.
    /// Shared with the cleanup tools, which have to reach the same verdict this
    /// screen does — a second definition would quietly disagree with the first.
    static func isDayToDay(_ tx: TxRecord, rhythm: SpendingRhythm,
                           convert: (TxRecord) -> Double) -> Bool {
        guard !fixedMonthlyCats.contains(tx.category) else { return false }
        return !rhythm.verdict(for: tx, amount: abs(convert(tx))).isIrregular
    }

    func isDayToDay(_ tx: TxRecord) -> Bool {
        Self.isDayToDay(tx, rhythm: rhythm, convert: convertedAmount)
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

    func computeFigures() -> SpendingFigures {
        Self.figures(for: cachedFilteredTx, rhythm: rhythm, convert: convertedAmount)
    }

    /// The median-day machinery, over any slice. Static so the cleanup tools can
    /// show the very figures they are correcting.
    static func figures(for txs: [TxRecord], rhythm: SpendingRhythm,
                        convert: (TxRecord) -> Double) -> SpendingFigures {
        var f = SpendingFigures()
        var perDay: [Date: Double] = [:]
        let cal = Calendar.current
        for tx in txs where tx.txSubtype != .transfer {
            let amt = abs(convert(tx))
            guard tx.amount < 0 || tx.txSubtype == .refund else { continue }
            let signed = tx.txSubtype == .refund ? -amt : amt
            if isDayToDay(tx, rhythm: rhythm, convert: convert) {
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
                if !fixedMonthlyCats.contains(tx.category), tx.amount < 0 {
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
    var variableSpend: Double { cachedFigures.variable }

    /// Fixed commitments and irregular episodes charged this period — counted
    /// ONCE, never rated.
    var fixedSpend: Double { cachedFigures.fixed }

    var variableDailyTotals: [Double] { cachedFigures.dailyTotals }

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
    var typicalDailySpend: Double { cachedFigures.typicalDaily }

    /// The irregular spending this period: episodic categories plus anything
    /// marked a one-off. Named rather than averaged away.
    ///
    /// Counted by TRANSACTION, not by day. An earlier version excluded whole
    /// expensive DAYS, which threw out the coffee bought on the same afternoon
    /// as the vehicle tax — the day was not unusual, one purchase in it was.
    var irregularSpend: (count: Int, total: Double) {
        (cachedFigures.irregularCount, cachedFigures.irregularTotal)
    }

    var weeklyAverage: Double { typicalDailySpend * 7 }

    /// What a day actually has to spend: income for the cycle, minus everything
    /// contractual, spread across the cycle's days.
    ///
    /// The point of a daily figure is to answer "am I fine today", and that
    /// cannot be answered against gross income — the rent is already spoken
    /// for. This is the number the typical-day figure should be read against.
    static func dailyAllowance(cycleDays total: Int,
                               salarySchedules: [SalarySchedule],
                               recurringPlans: [RecurringExpense],
                               mainCardID: UUID?,
                               currency: String) -> Double? {
        guard total > 0 else { return nil }
        let cm = CurrencyManager.shared
        let income = MainCard.salaries(salarySchedules).reduce(0.0) {
            $0 + cm.convert($1.amount, from: $1.currency, to: currency)
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
        let committed = recurringPlans
            .filter { $0.isActive && ($0.cardID == nil || $0.cardID == mainCardID) }
            .reduce(0.0) { $0 + cm.convert(abs($1.amount), from: $1.currency, to: currency) }
        return max(income - committed, 0) / Double(total)
    }

    var dailyAllowance: Double? {
        guard let p = periodProgress else { return nil }
        return Self.dailyAllowance(cycleDays: p.total,
                                   salarySchedules: salarySchedules,
                                   recurringPlans: recurringPlans,
                                   mainCardID: selectedCard?.id,
                                   currency: displayCurrency)
    }

    /// Number of whole days spanned by the current period.
    var periodDays: Int {
        let (start, end) = effectiveRange
        return max(Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0, 0)
    }

    /// A window under ~2 weeks doesn't hold enough data for a stable weekly
    /// pace — dividing a front-loaded, still-in-progress span (e.g. a pay
    /// cycle 8 days in) by fractional weeks inflates the figure. Flag those so
    /// the UI marks the weekly average as a partial estimate.
    var isPartialWeeklyPeriod: Bool {
        periodDays < 14
    }
    
    var topCategories: [(category: TxCategory, amount: Double, percentage: Double)] {
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
    var netWorthTrend: [CycleTrendPoint] { cachedNetWorthTrend }

    /// Fixed commitments measured against income and the active savings goal.
    var commitmentReview: CommitmentReview {
        CommitmentReview.build(recurrings: recurringPlans, salaries: salarySchedules,
                               goals: savingsGoals, configs: cardBudgetConfigs,
                               currency: displayCurrency)
    }

    func computeNetWorthTrend() -> [CycleTrendPoint] {
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
    var patternRows: [(icon: String, tint: Color, title: String, detail: String)] {
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
    var projectedSpend: Double? {
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
    var upcomingFixed: Double {
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

    var weekdayStandout: WeekdayStandout? {
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
    var noSpendDays: (count: Int, of: Int)? {
        guard let p = periodProgress else { return nil }
        let cal = Calendar.current
        let spentDays = Set(filteredTx
            .filter { $0.amount < 0 && $0.txSubtype == .normal }
            .map { cal.startOfDay(for: $0.date) })
        return (max(p.elapsed - spentDays.count, 0), p.elapsed)
    }

    /// Single largest outflow — the anchor a list of five recent rows never gave.
    var biggestExpense: TxRecord? {
        filteredTx.filter { $0.amount < 0 && $0.txSubtype == .normal }
            .max { abs(convertedAmount($0)) < abs(convertedAmount($1)) }
    }

    var realCategories: [SpendCategory] {
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

    var realTotal: Double { realCategories.reduce(0) { $0 + $1.amount } }

    var displayedTx: [TxRecord] {
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
}
