import SwiftUI
import SwiftData

// MARK: - Smart Recommendation Engine
//
// The "brain" behind DiPo's personalized budgeting advice. Given the user's
// own transaction history (plus income, goals, and debts), it produces a
// single structured `SmartRecommendation` the UI renders as a confirmation
// screen ("DiPo recommends a smarter way for you").
//
// IMPORTANT — this is NOT machine learning / model training. It's heuristic
// analysis of the user's OWN history, so it works from day one; the more
// months of data, the more reliable the patterns (reflected in `confidence`).
// We never block the user waiting for "enough data" — we analyze immediately
// and label how sure we are.

enum RecoRating: Int {
    case poor = 0, fair, good, great, high

    var label: String {
        switch self {
        case .poor:  return loc("reco.rating.poor")
        case .fair:  return loc("reco.rating.fair")
        case .good:  return loc("reco.rating.good")
        case .great: return loc("reco.rating.great")
        case .high:  return loc("reco.rating.high")
        }
    }

    var color: Color {
        switch self {
        case .poor:  return AppTheme.red
        case .fair:  return AppTheme.orange
        case .good:  return AppTheme.accent
        case .great: return AppTheme.accent
        case .high:  return AppTheme.purple
        }
    }
}

/// One actionable recommendation card ("Save Rp X more/month", etc.).
struct RecoItem: Identifiable {
    let id = UUID()
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    /// Short trailing badge, e.g. "+4 months", "Rp 850K", "High Impact".
    let badge: String
    let badgeTint: Color
}

/// Why one health metric got the rating it did, in the user's own numbers.
/// The score card shows only a short label + verdict (long labels used to be
/// truncated); tapping opens these so "Needs work" is never a dead end.
struct RecoMetricDetail: Identifiable {
    let id = UUID()
    let icon: String
    /// Short label used on the compact card ("Saving", "Balance").
    let shortLabel: String
    /// Full label used in the explanation sheet ("Saving Habit").
    let fullLabel: String
    let rating: RecoRating
    /// The measured figure behind the verdict, e.g. "0% of income left".
    let measured: String
    /// Plain-language reason plus what would improve it.
    let explanation: String
}

/// One wedge of a breakdown (saving allocation or spending mix).
struct RecoSlice: Identifiable {
    let id = UUID()
    let label: String
    let pct: Int
    let amount: Double
    let color: Color
}

/// Actuals for the CURRENT pay cycle (what the Smart Budget screen shows). When
/// supplied, the score + ratings are judged on this — the reality the user is
/// looking at — instead of a trailing 2-month average that can hide a cycle
/// that's currently over budget. Recommendation amounts still use the trend.
struct RecoCycleSnapshot {
    let daily: Double        // spent in the Daily-needs group this cycle
    let lifestyle: Double    // spent in the Lifestyle group this cycle
    let investDebt: Double   // put toward Invest & Debt this cycle
    /// Money actually moved INTO savings goals this cycle (goal-linked
    /// transactions). Setting money aside is the saving habit itself, so the
    /// rating credits it directly instead of only measuring what was left over
    /// — a user who transfers to a goal every payday was being rated "Weak"
    /// purely because their living costs used the rest of the income.
    let savingsDeposits: Double
    let income: Double       // cycle income (salary schedule)
    /// Biggest single consumption category this cycle — turns "you're over by
    /// Rp X" into advice the user can actually act on ("Food & Drinks, 88 txs").
    var topCategory: String? = nil
    var topCategoryAmount: Double = 0
    var topCategoryCount: Int = 0
}

/// The full analysis result rendered by `SmartRecommendationView`.
struct SmartRecommendation: Identifiable {
    let id = UUID()
    var smartScore: Int
    var scoreLabel: String
    var spendingBalance: RecoRating
    var savingHabit: RecoRating
    var investmentPotential: RecoRating

    var transactionsAnalyzed: Int
    var dataMonths: Int
    var confidence: InsightConfidence
    var currency: String

    var monthlyIncome: Double
    var avgMonthlyExpense: Double
    var currentMonthlySaving: Double
    var recommendedMonthlySaving: Double
    var extraSavingPerMonth: Double
    var potentialCut: Double
    var suggestedInvestment: Double
    var autoSaveAmount: Double

    /// Budget split DiPo suggests (sums to 1.0). Applying the recommendation
    /// writes these into SmartBudgetManager's global ratios.
    var recommendedRatios: (daily: Double, lifestyle: Double, investDebt: Double)

    var topItems: [RecoItem]
    var reasons: [String]

    var topGoalName: String?
    var goalMonthsFaster: Int?

    // Detail-screen breakdowns
    /// Where the recommended monthly saving goes (emergency / goal / short-term).
    var savingAllocation: [RecoSlice]
    /// % increase of recommended saving vs what the user currently saves.
    var savingVsCurrentPct: Int
    /// Projected value of the suggested monthly investing after 10 years (~7%/yr).
    var investReturn10y: Double
    /// Average monthly spend by category (biggest first).
    var spendingBreakdown: [RecoSlice]
    /// Current months-to-goal at the user's existing pace (for the accel. timeline).
    var goalCurrentMonths: Int?
    /// Months-to-goal after adding the recommended extra saving.
    var goalNewMonths: Int?

    // Cash-flow reality check (deficit-aware mode)
    /// True when average spending exceeds income — the recommendation pivots
    /// from "save/invest more" to "stop the leak first".
    var isDeficit: Bool = false
    /// How much monthly spending exceeds income (0 when not in deficit).
    var deficitAmount: Double = 0
    /// Sum of active debts' effective minimum payments per month (+ CC minimum).
    var debtMinimumMonthly: Double = 0
    /// Monthly total of sub-threshold "small" purchases (the invisible leak).
    var smallSpendMonthly: Double = 0
    /// How many small purchases per month make up that total.
    var smallSpendCount: Int = 0
    /// Total amount of charges that look like duplicates of recurring plans
    /// (manual twin + auto-record). Flag-only — never excluded from the math.
    var duplicateSuspectAmount: Double = 0
    /// Human-readable analysis window ("Pay cycle 25 Jun – 23 Jul"), empty when
    /// the analysis fell back to a plain time-span average.
    var periodLabel: String = ""
    /// Per-metric verdicts with the numbers and reasoning behind them.
    var metricDetails: [RecoMetricDetail] = []
    /// Deliberate choices the user declared for this cycle. Present so the UI
    /// can show what it is respecting — an intent that changes the verdict
    /// invisibly would be worse than no intent at all.
    var declaredIntents: [CycleIntentKind] = []

    /// True when there's too little history for a personalized read — the UI
    /// shows a "preliminary" banner and leans on structural best-practice.
    var isPreliminary: Bool { dataMonths < 1 || transactionsAnalyzed < 15 }
}

enum SmartRecommendationEngine {

    /// Analyze the user's finances and produce a recommendation. `income` is
    /// the user's best-known monthly income (salary schedule or derived); all
    /// amounts are in `currency` (the user's preferred currency).
    static func analyze(transactions: [TxRecord],
                        monthlyIncome income: Double,
                        goals: [SavingsGoal],
                        debts: [DebtRecord],
                        currency: String,
                        currentCycle: RecoCycleSnapshot? = nil,
                        recurringMonthly: Double = 0,
                        recurringLabels: [String] = [],
                        creditCardOwed: Double = 0,
                        creditCardMinPayment: Double = 0,
                        salaryDayOfMonth: Int? = nil,
                        recurrings: [RecurringExpense] = [],
                        intents: CycleIntentSet = .empty) -> SmartRecommendation {

        let sb = SmartBudgetManager.shared
        let cm = CurrencyManager.shared
        let months = max(sb.dataMonthsAvailable(allTransactions: transactions), 1)
        let confidence = sb.defaultConfidence(allTransactions: transactions)

        // ── Analysis window ──
        // Preferred: complete payday→payday cycles (see paydayCycleWindow) —
        // "monthly habit" then means real pay periods, and the in-progress
        // cycle (already judged separately via `currentCycle`) can't dilute
        // the averages. Fallback when there's no salary schedule or not one
        // full cycle of data yet: whole history over its time span.
        func toPref(_ amt: Double, _ cur: String) -> Double {
            cm.convert(amt, from: cur.isEmpty ? currency : cur, to: currency)
        }
        // Only real spending — skip transfers (own-account moves) and refunds.
        let allExpenseTx = transactions.filter { $0.amount < 0 && $0.txSubtype == .normal }
        let cycleWindow = salaryDayOfMonth.flatMap {
            sb.paydayCycleWindow(allTransactions: transactions, salaryDay: $0)
        }
        let expenseTx: [TxRecord]
        let monthsDivisor: Double
        if let w = cycleWindow {
            expenseTx = allExpenseTx.filter { $0.date >= w.start && $0.date < w.end }
            monthsDivisor = Double(w.cycles)
        } else {
            expenseTx = allExpenseTx
            monthsDivisor = sb.dataSpanMonths(allTransactions: transactions)
        }
        // What the UI reports: whole pay cycles when aligned, span months otherwise.
        let dataMonthsDisplay = cycleWindow?.cycles ?? months
        let periodLabel: String = {
            guard let w = cycleWindow else { return "" }
            let f = DateFormatter()
            f.locale = LanguageManager.shared.currentLocale
            f.dateFormat = "d MMM"
            let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: w.end) ?? w.end
            return String(format: loc(w.cycles == 1 ? "reco.period_cycle" : "reco.period_cycles"),
                          w.cycles, f.string(from: w.start), f.string(from: lastDay))
        }()

        let totalExpense = expenseTx.reduce(0.0) { $0 + toPref(abs($1.amount), $1.currency) }
        let avgMonthlyExpense = totalExpense / monthsDivisor

        func avgGroup(_ cats: [TxCategory]) -> Double {
            expenseTx.filter { cats.contains($0.category) }
                .reduce(0.0) { $0 + toPref(abs($1.amount), $1.currency) } / monthsDivisor
        }
        let dailyAvg     = avgGroup(SmartBudgetManager.dailyCategories)
        let lifestyleAvg = avgGroup(SmartBudgetManager.lifestyleCategories)
        // Fixed (contractual) vs variable slice of the daily group — rent/kos,
        // family transfers, and bills can't be cut in-month, so the split each
        // user actually needs depends on how big this fixed block is.
        let fixedAvg = avgGroup(SmartBudgetManager.fixedCategories)
        let variableDailyAvg = max(dailyAvg - fixedAvg, 0)

        // ── Small-purchase leak ── many sub-threshold buys that never feel
        // expensive one at a time. Category groups can't see this pattern (it
        // usually hides inside "daily needs" like food), so it's detected by
        // transaction size. Threshold scales with income (~0.5%, e.g. Rp 50K
        // on Rp 10M); flagged when the pile exceeds 8% of income.
        let smallThreshold = income > 0 ? income * 0.005 : 50_000
        let smallTx = expenseTx.filter {
            !SmartBudgetManager.investDebtCategories.contains($0.category)
                && toPref(abs($0.amount), $0.currency) < smallThreshold
        }
        let smallSpendMonthly = smallTx.reduce(0.0) { $0 + toPref(abs($1.amount), $1.currency) } / monthsDivisor
        let smallSpendCount = Int((Double(smallTx.count) / monthsDivisor).rounded())
        let hasSmallLeak = income > 0 && smallSpendMonthly > income * 0.08

        // ── Duplicate recurring charges ── manual entries that look like twins
        // of recurring-plan charges (matched by amount, not name). Flagged so
        // the user can verify — never silently excluded from the math.
        let expectedCharges = cycleWindow?.cycles ?? max(Int(monthsDivisor.rounded()), 1)
        let dupeSuspects = sb.detectRecurringDuplicates(
            expenseTx: expenseTx, recurrings: recurrings,
            expectedPerPlan: expectedCharges, currency: currency)
        let dupeExcess = dupeSuspects.reduce(0.0) { $0 + $1.excessAmount }

        // ── Essential-cost floor ──
        // Logged expenses frequently miss rent, family transfers, and cash
        // spending. If the tracked average is implausibly low for the income,
        // assume a realistic minimum of ~50% of income goes to essentials —
        // otherwise the engine thinks the user banks nearly their whole
        // paycheck, and both the score and the recommendations become fantasy.
        //
        // `recurringMonthly` is the user's DECLARED fixed commitments (kos,
        // family transfers, subscriptions) from the Monthly Expenses feature.
        // That's a hard, known floor of costs — far better than the 50% guess —
        // so we take whichever is higher. Declared commitments that aren't yet
        // logged as transactions still count against what's realistically
        // saveable.
        // ── Committed outflows from OTHER features ──
        // Debt minimum payments and existing goal contributions are cash the
        // user has already committed — they must be part of the "what's really
        // saveable" picture, not ignored. Previously the engine only looked at
        // `interest > 0` as a boolean, so Rp 12M of 0%-interest debt with
        // Rp 800k/mo minimums was treated as no debt at all.
        let activeDebts = debts.filter { $0.isActive && $0.currentBalance > 0 }
        // Credit-card balances (from the CC accounts) are debt too — fold them in
        // so the recommendation sees the full obligation. `effectiveMinimumPayment`
        // derives a sensible minimum when the user left it at 0 (common for 0%
        // installments) — a real outstanding balance never counts as "no payment".
        let debtMinPayments = activeDebts.reduce(0.0) { $0 + cm.convert($1.effectiveMinimumPayment, from: $1.currency, to: currency) }
                            + creditCardMinPayment
        let totalDebt = activeDebts.reduce(0.0) { $0 + cm.convert($1.currentBalance, from: $1.currency, to: currency) }
                      + creditCardOwed
        let hasCostlyDebt = activeDebts.contains { $0.annualInterestRate > 0 }
        let hasAnyDebt = !activeDebts.isEmpty || creditCardOwed > 0
        let goalContributions = goals.filter { !$0.isCompleted }
            .reduce(0.0) { $0 + cm.convert($1.monthlyContribution, from: $1.currency, to: currency) }

        let guessFloor = income > 0 ? income * 0.50 : 0
        // Known fixed commitments = declared recurring + debt minimums. The floor
        // is the higher of the 50% guess and these real, committed costs.
        let committedFixed = recurringMonthly + debtMinPayments
        let essentialFloor = max(guessFloor, committedFixed)
        let effectiveExpense = max(avgMonthlyExpense, essentialFloor)
        let loggedRatio = essentialFloor > 0 ? min(avgMonthlyExpense / essentialFloor, 1) : 1

        // ── Saving ──
        // Surplus is computed against the *effective* (floored) expense so we
        // never assume the user saves money that's really going to unlogged
        // essentials.
        let currentSaving = income - effectiveExpense
        let savingsRate   = income > 0 ? currentSaving / income : 0

        // ── Deficit mode ── average spending exceeds income. No savings target
        // is real until the gap closes, so the whole recommendation pivots:
        // cut first, save later, never suggest investing money that isn't there.
        let isDeficit = income > 0 && currentSaving < 0
        let deficitAmount = isDeficit ? -currentSaving : 0

        // Recommend a SUSTAINABLE set-aside, not the whole surplus. Rationale:
        //   • `currentSaving` = income − *logged* expenses, but real costs like
        //     rent, transport, and family transfers are often under-logged, so
        //     the raw surplus overstates what's actually free to save.
        //   • Even for a genuine strong saver, telling them to bank ~70% of
        //     income is not livable advice.
        // So: aim for at least 20% of income, meet a strong saver partway, but
        // CAP at 35% — the plan always leaves the majority of income for living.
        let targetSaving: Double = {
            guard income > 0 else { return max(currentSaving, 0) }
            if isDeficit { return 0 }   // a "save 20%" target in deficit is fantasy
            return min(max(income * 0.20, currentSaving), income * 0.35)
        }()
        let recommendedRate = income > 0 ? targetSaving / income : 0
        // Extra saving vs what's ACTUALLY being saved today (floored at 0 — a
        // deficit doesn't mean you can add MORE than the whole plan). Without
        // the floor, a negative currentSaving inflated `extraSaving` beyond
        // `targetSaving`, so "goal X months faster" assumed contributions
        // larger than the plan itself sets aside.
        let extraSaving   = max(targetSaving - max(currentSaving, 0), 0)

        // ── Cut opportunity ──
        //   • deficit: cut enough to close the gap plus a 5% buffer
        //   • otherwise: lifestyle above a healthy 30% share, or half of the
        //     small-purchase pile when that leak is the dominant pattern
        let healthyLifestyle = income * 0.30
        let lifestyleCut = income > 0 ? max(lifestyleAvg - healthyLifestyle, 0) : lifestyleAvg * 0.15
        let potentialCut = isDeficit
            ? deficitAmount + income * 0.05
            : max(lifestyleCut, hasSmallLeak ? smallSpendMonthly * 0.5 : 0)

        // ── Investment ── a SLICE of the recommended saving (its long-term
        // portion), never an amount ON TOP of it — otherwise saving + investing
        // could exceed income (the old bug: 6.9jt save + 3.5jt invest > 10jt).
        // ~40% of the set-aside goes to long-term investing.
        let suggestedInvestment = targetSaving > 0 ? roundNice(targetSaving * 0.40) : 0

        // ── Recommended budget split ── derived from the user's own cost
        // structure instead of a one-size 50/30/20:
        //   • daily must cover the fixed block (kos, bills, family transfers)
        //     plus a livable essential-variable slice — for users whose fixed
        //     costs eat 40%+ of income, a 50% daily cap is unmeetable and the
        //     app just nags them all month
        //   • invest/debt must at least cover debt minimums (debt payments are
        //     budgeted in that group) — otherwise the plan forbids paying debts
        //   • lifestyle takes the remainder, never below 10%
        // With little data, fall back to the classic split and simple nudges.
        func snap5(_ x: Double) -> Double { (x * 20).rounded() / 20 }
        var daily = 0.50, lifestyle = 0.30, invest = 0.20
        // Debt with a real cash-flow drag (interest, OR minimum payments that
        // already eat >10% of income) → steer money toward the Invest & Debt
        // bucket so payoff is funded, even when the nominal rate is 0%.
        let debtIsHeavy = hasCostlyDebt || (income > 0 && debtMinPayments > income * 0.10)
        if income > 0 && expenseTx.count >= 15 {
            let fixedShare = fixedAvg / income
            // Essential variable (food, transport, health) — capped at 25% so a
            // user's current overspending doesn't get baked in as a "need".
            let essentialShare = min(variableDailyAvg / income, 0.25)
            daily = snap5(min(max(fixedShare + essentialShare, 0.40), 0.65))
            let investFloor = isDeficit ? 0.10 : 0.20
            invest = snap5(min(max(investFloor, debtMinPayments / income + 0.05), 0.35))
            if debtIsHeavy { invest = max(invest, 0.30) }
            if !isDeficit && savingsRate >= 0.30 { invest = max(invest, 0.35); daily = min(daily, 0.45) }
            // Keep at least 10% lifestyle — a plan with zero fun gets abandoned.
            if daily + invest > 0.90 { invest = max(0.90 - daily, 0.10) }
            lifestyle = 1.0 - daily - invest
        } else if debtIsHeavy {
            daily = 0.50; lifestyle = 0.20; invest = 0.30
        } else if income > 0 && lifestyleAvg > income * 0.35 {
            // Overspending lifestyle → rein it in, redirect to invest/debt.
            daily = 0.50; lifestyle = 0.25; invest = 0.25
        } else if savingsRate >= 0.30 {
            // Strong saver → lean into investing.
            daily = 0.45; lifestyle = 0.20; invest = 0.35
        }

        // ── Rating inputs ──
        // Judge on the CURRENT cycle when we have it (matches the red "over
        // budget" banners the user sees); otherwise fall back to the 2-month
        // trend. `rSavingsRate` is income left after day-to-day consumption
        // (Daily needs + Lifestyle) — the money not burned on living, which is
        // what actually funds saving/investing.
        let rDailyShare: Double
        let rLifeShare: Double
        let rSavingsRate: Double
        let rOverspent: Bool
        /// Share of income actually routed to investing / debt payoff.
        let rInvestShare: Double
        if let c = currentCycle, c.income > 0 {
            rDailyShare  = c.daily / c.income
            rLifeShare   = c.lifestyle / c.income
            // Credit BOTH what's left over AND what was deliberately set aside.
            rSavingsRate = max(max(0, (c.income - c.daily - c.lifestyle) / c.income),
                               c.savingsDeposits / c.income)
            rInvestShare = max(0, c.investDebt / c.income)
            // Living costs ALONE outrunning income is the real red flag. Money
            // routed to investing or debt payoff must not count as overspending
            // — including it scored good behaviour as "Poor" spending balance.
            rOverspent   = (c.daily + c.lifestyle) > c.income
        } else {
            rDailyShare  = income > 0 ? dailyAvg / income : 0
            rLifeShare   = income > 0 ? lifestyleAvg / income : 0
            rSavingsRate = savingsRate
            rInvestShare = 0
            rOverspent   = avgMonthlyExpense > income && income > 0
        }
        let lifeShare = rLifeShare   // reused below for the "why" reasons

        let savingHabit: RecoRating = {
            if rSavingsRate >= 0.30 { return .great }
            if rSavingsRate >= 0.20 { return .good }
            if rSavingsRate > 0.05  { return .fair }
            // Declared as deliberate → not a failing grade. The measured 0%
            // still shows in the detail; only the verdict softens.
            return intents.excusesSaving ? .fair : .poor
        }()
        // Balance now weighs BOTH groups, not just lifestyle — being over on
        // Daily needs is just as much an imbalance as over on Lifestyle.
        let spendingBalance: RecoRating = {
            if rOverspent { return intents.excusesDeficit ? .fair : .poor }
            let consumed = rDailyShare + rLifeShare
            // Total consumption dominates: leaving 4% of income is precarious
            // no matter how the two buckets split it.
            if consumed > 0.95 { return .fair }
            let over = (rDailyShare > 0.50 ? 1 : 0) + (rLifeShare > 0.30 ? 1 : 0)
            if over >= 2 || consumed > 0.88 { return .fair }
            if over == 1 { return .good }
            return .great
        }()
        // Credit BOTH capacity (money still free) and what's already being put to
        // work. Judging on leftover alone rated someone routing 12% of income to
        // investing the same as someone routing nothing.
        let investmentPotential: RecoRating = {
            let signal = max(rSavingsRate, rInvestShare)
            if signal >= 0.30 { return .high }
            if signal >= 0.15 { return .good }
            if signal > 0.05  { return .fair }
            return intents.excusesInvesting ? .fair : .poor
        }()

        // ── Metric explanations ── every verdict must be able to answer "why?"
        // with the user's own figures and a concrete way to move it.
        let pctLeft = Int((max(rSavingsRate, 0) * 100).rounded())
        let deposited = currentCycle?.savingsDeposits ?? 0
        let pctConsumed = Int(((rDailyShare + rLifeShare) * 100).rounded())
        let pctInvested = Int((max(rInvestShare, rSavingsRate) * 100).rounded())
        let metricDetails: [RecoMetricDetail] = [
            RecoMetricDetail(
                icon: "waveform.path.ecg",
                shortLabel: loc("reco.metric.balance_short"),
                fullLabel: loc("reco.metric.balance"),
                rating: spendingBalance,
                measured: String(format: loc("reco.metric.balance_measured"), pctConsumed),
                explanation: rOverspent
                    ? loc("reco.metric.balance_why_over")
                    : String(format: loc("reco.metric.balance_why"),
                             Int((rDailyShare * 100).rounded()), Int((rLifeShare * 100).rounded()))),
            RecoMetricDetail(
                icon: "lock.fill",
                shortLabel: loc("reco.metric.saving_short"),
                fullLabel: loc("reco.metric.saving"),
                rating: savingHabit,
                measured: deposited > 0
                    ? String(format: loc("reco.metric.saving_measured_deposit"),
                             cm.formatted(roundNice(deposited), currency: currency), pctLeft)
                    : String(format: loc("reco.metric.saving_measured"), pctLeft),
                explanation: {
                    if deposited > 0 { return String(format: loc("reco.metric.saving_why"), pctLeft) }
                    if isDeficit && pctLeft <= 0 {
                        return String(format: loc("reco.metric.saving_why_deficit"),
                                      cm.formatted(roundNice(deficitAmount), currency: currency))
                    }
                    if isDeficit {
                        // Something WAS left after living costs, but debt
                        // payments and investing used more than that.
                        return String(format: loc("reco.metric.saving_why_absorbed"), pctLeft,
                                      cm.formatted(roundNice(deficitAmount), currency: currency))
                    }
                    return String(format: loc("reco.metric.saving_why"), pctLeft)
                }()),
            RecoMetricDetail(
                icon: "chart.line.uptrend.xyaxis",
                shortLabel: loc("reco.metric.invest_short"),
                fullLabel: loc("reco.metric.invest"),
                rating: investmentPotential,
                measured: String(format: loc("reco.metric.invest_measured"), pctInvested),
                explanation: hasCostlyDebt
                    ? loc("reco.metric.invest_why_debt")
                    : String(format: loc("reco.metric.invest_why"), pctInvested)),
        ]

        // ── Smart Score (0–100) ── saving (45) + balance (30) + invest potential (25).
        //
        // Curves are anchored on the targets this app actually preaches (20%
        // saving, 80% of income for living, 20% to invest/debt) and are
        // CONTINUOUS. The old version demanded a 30% saving rate for full marks
        // and handed out a hard 0 for balance the moment you tipped over, so a
        // disciplined saver on a modest income could never score respectably.
        //
        // Saving: hitting the stated 20% goal earns nearly all of it; going
        // further to 35% earns the last few points.
        let savingScore = min(max(rSavingsRate / 0.20, 0), 1) * 40
                        + min(max((rSavingsRate - 0.20) / 0.15, 0), 1) * 5
        // Balance: 80% of income on living = on plan. Degrades smoothly from
        // there and only bottoms out at ~110%, instead of snapping to zero.
        let consumptionShare = rDailyShare + rLifeShare
        let balanceScore = 30 * min(max(1 - max(consumptionShare - 0.80, 0) / 0.30, 0), 1)
        // Invest: credit both spare capacity and money already put to work,
        // against the 20% invest/debt target.
        let investScore = min(max(max(rSavingsRate, rInvestShare) / 0.20, 0), 1) * 25
        // A declared pause shouldn't be scored as a miss. Rather than gifting
        // the points, re-weight: the remaining components are judged on their
        // own scale, so the score reflects how the user did at what they were
        // actually trying to do this cycle.
        let rawScore: Double = {
            let base = savingScore + balanceScore + investScore
            guard intents.excusesInvesting else { return base }
            let judged = savingScore + balanceScore          // out of 75
            return judged * (100.0 / 75.0)
        }()
        // Temper the score for realism. Two dampers, both in [~0.7…1.0]:
        //   • dataFactor — when spending looks under-logged (`loggedRatio` low),
        //     the "great saving" is an assumption, not a fact, so pull down.
        //   • confFactor — little history (low/medium confidence) also lowers
        //     certainty. A brand-new user should never see a confident 100.
        let dataFactor = 0.70 + 0.30 * loggedRatio
        let confFactor: Double = {
            switch confidence {
            case .high:   return 1.00
            case .medium: return 0.92
            case .low:    return 0.80
            }
        }()
        let score = max(0, min(Int((rawScore * dataFactor * confFactor).rounded()), 100))
        let scoreLabel: String = {
            switch score {
            case 80...:  return loc("reco.score.great")
            case 60..<80: return loc("reco.score.good")
            case 40..<60: return loc("reco.score.fair")
            default:      return loc("reco.score.start")
            }
        }()

        // ── Top goal & acceleration ──
        let activeGoals = goals.filter { !$0.isCompleted && $0.remaining > 0 }
            .sorted { ($0.priority, -$0.remaining) < ($1.priority, -$1.remaining) }
        let topGoal = activeGoals.first
        var goalMonthsFaster: Int? = nil
        var goalCurrentMonths: Int? = nil
        var goalNewMonths: Int? = nil
        if let g = topGoal, extraSaving > 0 {
            let goalRemaining = cm.convert(g.remaining, from: g.currency, to: currency)
            let currentPacePref = max(cm.convert(g.monthlyContribution, from: g.currency, to: currency), 1)
            let curMonths = Int(ceil(goalRemaining / currentPacePref))
            let newMonths = Int(ceil(goalRemaining / max(currentPacePref + extraSaving, 1)))
            goalCurrentMonths = curMonths
            goalNewMonths = newMonths
            let faster = curMonths - newMonths
            if faster > 0 { goalMonthsFaster = faster }
        }

        // ── Recommendation cards ──
        //
        // These must agree with the score. Previously they were built purely
        // from the 2-month trend, so a user who blew this cycle's budget still
        // got "put your idle surplus to work" next to a Smart Score of 5.
        // `cycleOverage` is the concrete amount over target RIGHT NOW, and
        // `hasSurplus` gates any advice that assumes spare money exists.
        var cycleOverage: Double = 0
        if let c = currentCycle, c.income > 0 {
            cycleOverage = max(c.daily - c.income * sb.dailyRatio, 0)
                         + max(c.lifestyle - c.income * sb.lifestyleRatio, 0)
        }
        let hasSurplus = rSavingsRate >= 0.10

        var items: [RecoItem] = []
        // Deficit leads: nothing else matters until the leak stops.
        if isDeficit {
            // Same number either way — only the framing changes. A planned
            // overspend gets reported, not alarmed about.
            let planned = intents.excusesDeficit
            items.append(RecoItem(
                icon: planned ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: planned ? AppTheme.blue : AppTheme.red,
                title: planned ? loc("reco.item.planned_gap_title") : loc("reco.item.leak_title"),
                subtitle: String(format: loc(planned ? "reco.item.planned_gap_sub" : "reco.item.leak_sub"),
                                 cm.formatted(roundNice(deficitAmount), currency: currency)),
                badge: loc(planned ? "reco.badge.by_choice" : "reco.badge.priority"),
                badgeTint: planned ? AppTheme.blue : AppTheme.red))
        }
        // Suspected duplicates come right after — verifying them can shrink the
        // apparent problem before any real cutting starts.
        for s in dupeSuspects {
            items.append(RecoItem(
                icon: "doc.on.doc.fill", tint: AppTheme.orange,
                title: String(format: loc("reco.item.dupe_title"), s.label),
                subtitle: String(format: loc("reco.item.dupe_sub"),
                                 s.found, cm.formatted(s.chargeAmount, currency: currency), s.expected),
                badge: loc("reco.badge.check"),
                badgeTint: AppTheme.orange))
        }
        if cycleOverage > 0 {
            // Lead with the number the user can act on this cycle — and name the
            // category driving it, so it isn't just "spend less".
            let overFmt = cm.formatted(roundNice(cycleOverage), currency: currency)
            let subtitle: String = {
                if let c = currentCycle, let cat = c.topCategory, c.topCategoryCount > 0 {
                    return String(format: loc("reco.item.trim_sub_driver"), overFmt, cat,
                                  cm.formatted(roundNice(c.topCategoryAmount), currency: currency),
                                  c.topCategoryCount)
                }
                return String(format: loc("reco.item.trim_sub"), overFmt)
            }()
            items.append(RecoItem(
                icon: "scissors", tint: AppTheme.orange,
                title: loc("reco.item.trim_title"),
                subtitle: subtitle,
                badge: overFmt,
                badgeTint: AppTheme.orange))
        }
        if extraSaving > 0, hasSurplus {
            items.append(RecoItem(
                icon: "banknote.fill", tint: AppTheme.accent,
                title: String(format: loc("reco.item.save_title"), cm.formatted(roundNice(extraSaving), currency: currency)),
                subtitle: goalMonthsFaster != nil
                    ? String(format: loc("reco.item.save_sub_goal"), goalMonthsFaster!)
                    : loc("reco.item.save_sub"),
                badge: goalMonthsFaster != nil ? String(format: loc("reco.badge.months_faster"), goalMonthsFaster!) : loc("reco.badge.recommended"),
                badgeTint: AppTheme.accent))
        }
        // The generic cut card is redundant when the deficit card already leads
        // with a bigger, scarier number — show it only in surplus mode.
        if potentialCut > 0 && !isDeficit {
            items.append(RecoItem(
                icon: "scissors", tint: AppTheme.orange,
                title: loc("reco.item.cut_title"),
                subtitle: String(format: loc("reco.item.cut_sub"), cm.formatted(roundNice(potentialCut), currency: currency)),
                badge: cm.formatted(roundNice(potentialCut), currency: currency),
                badgeTint: AppTheme.orange))
        }
        if hasSmallLeak {
            // Suggest a daily cap (~60% of the current pile) rather than a ban —
            // caps survive real life; bans don't.
            let dailyCap = roundNice(smallSpendMonthly * 0.6 / 30)
            items.append(RecoItem(
                icon: "cart.badge.minus", tint: AppTheme.orange,
                title: loc("reco.item.smallspend_title"),
                subtitle: String(format: loc("reco.item.smallspend_sub"),
                                 smallSpendCount,
                                 cm.formatted(smallThreshold, currency: currency),
                                 cm.formatted(roundNice(smallSpendMonthly), currency: currency)),
                badge: String(format: loc("reco.badge.daily_cap"), cm.formatted(dailyCap, currency: currency)),
                badgeTint: AppTheme.orange))
        }
        // Goal pledges the current cash flow can't actually fund — the fix is
        // moving the transfer to payday, before spending starts.
        if goalContributions > 0, goalContributions > max(currentSaving, 0), !intents.excusesGoalFunding {
            items.append(RecoItem(
                icon: "calendar.badge.clock", tint: AppTheme.blue,
                title: String(format: loc("reco.item.goalfund_title"), cm.formatted(roundNice(goalContributions), currency: currency)),
                subtitle: loc("reco.item.goalfund_sub"),
                badge: loc("reco.badge.payday"),
                badgeTint: AppTheme.blue))
        }
        // Interest-bearing debt beats investing: no fund reliably out-earns the
        // interest you're being charged. Recommend directing spare money to
        // payoff instead, and suppress the invest card while such debt exists.
        if hasCostlyDebt, hasSurplus, let target = activeDebts.filter({ $0.annualInterestRate > 0 })
            .max(by: { $0.annualInterestRate < $1.annualInterestRate }) {
            let payoff = min(suggestedInvestment > 0 ? suggestedInvestment : income * 0.10,
                             cm.convert(target.currentBalance, from: target.currency, to: currency))
            items.append(RecoItem(
                icon: "creditcard.fill", tint: AppTheme.red,
                title: String(format: loc("reco.item.debt_title"), cm.formatted(roundNice(payoff), currency: currency)),
                subtitle: String(format: loc("reco.item.debt_sub"), target.name, Int(target.annualInterestRate)),
                badge: loc("reco.badge.high_impact"), badgeTint: AppTheme.red))
        }
        // Only pitch investing when there is genuinely spare money AND no
        // interest-bearing debt to clear first. (0%-interest debt doesn't block
        // investing — mathematically it's fine to invest ahead of free debt.)
        if suggestedInvestment > 0, hasSurplus, !hasCostlyDebt, !intents.excusesInvesting {
            items.append(RecoItem(
                icon: "chart.line.uptrend.xyaxis", tint: AppTheme.purple,
                title: String(format: loc("reco.item.invest_title"), cm.formatted(suggestedInvestment, currency: currency)),
                subtitle: loc("reco.item.invest_sub"),
                badge: loc("reco.badge.high_impact"),
                badgeTint: AppTheme.purple))
        }
        // Always give at least one card so the screen never looks empty.
        if items.isEmpty {
            items.append(RecoItem(
                icon: "checkmark.seal.fill", tint: AppTheme.accent,
                title: loc("reco.item.ontrack_title"),
                subtitle: loc("reco.item.ontrack_sub"),
                badge: loc("reco.badge.keep_going"), badgeTint: AppTheme.accent))
        }

        // ── "Why we recommend this" ──
        var reasons: [String] = []
        for kind in CycleIntentKind.allCases where intents.has(kind) {
            let note = intents.notes[kind]
            reasons.append(note.map { String(format: loc("reco.why.intent_note"), kind.label, $0) }
                           ?? String(format: loc("reco.why.intent"), kind.label))
        }
        if isDeficit {
            reasons.append(String(format: loc("reco.why.deficit"), cm.formatted(roundNice(deficitAmount), currency: currency)))
        }
        if dupeExcess > 0 {
            reasons.append(String(format: loc("reco.why.dupe"), cm.formatted(roundNice(dupeExcess), currency: currency)))
        }
        if hasSmallLeak {
            reasons.append(String(format: loc("reco.why.smallspend"), smallSpendCount, cm.formatted(roundNice(smallSpendMonthly), currency: currency)))
        }
        // ONE bullet for fixed costs. Emitting both a "fixed share is 35%"
        // line (from actual spend) and a "recurring plan is 31%" line (from the
        // declared plan) put two different percentages for the same thing on
        // one screen. Report the actual figure and name the plan inside it.
        if income > 0, fixedAvg > 0 {
            let sharePct = Int((fixedAvg / income * 100).rounded())
            let names = recurringLabels.prefix(3).joined(separator: ", ")
            let amount = cm.formatted(roundNice(fixedAvg), currency: currency)
            if !names.isEmpty && recurringMonthly > 0 {
                reasons.append(String(format: loc("reco.why.fixed_combined"),
                                      amount, sharePct, names,
                                      cm.formatted(roundNice(recurringMonthly), currency: currency)))
            } else {
                reasons.append(String(format: loc("reco.why.fixedshare"), sharePct))
            }
        }
        if lifeShare > 0.30, !intents.excusesLifestyle {
            reasons.append(String(format: loc("reco.why.lifestyle"), Int(lifeShare * 100)))
        }
        // Only the pattern-detected fallback survives here — declared plans are
        // already named in the combined fixed-costs bullet above.
        if recurringMonthly <= 0, fixedAvg <= 0,
           let recurring = detectRecurringMonthly(expenseTx, currency: currency, months: monthsDivisor), recurring > 0 {
            reasons.append(String(format: loc("reco.why.recurring"), cm.formatted(roundNice(recurring), currency: currency)))
        }
        // Debt context — the engine now KNOWS the balance and monthly drag.
        if hasAnyDebt {
            let key = hasCostlyDebt ? "reco.why.debt_interest" : "reco.why.debt"
            reasons.append(String(format: loc(key),
                                  cm.formatted(roundNice(totalDebt), currency: currency),
                                  cm.formatted(roundNice(debtMinPayments), currency: currency)))
        }
        // Goal context — surface what's already being set aside toward a goal.
        if goalContributions > 0, let g = topGoal {
            reasons.append(String(format: loc("reco.why.goal"),
                                  cm.formatted(roundNice(goalContributions), currency: currency), g.name))
        }
        if savingsRate < 0.20 && !isDeficit {
            reasons.append(loc("reco.why.saverate"))
        }
        if savingsRate > 0.10 && !hasAnyDebt {
            reasons.append(loc("reco.why.invest"))
        }
        // Transparency: the plan intentionally keeps most income for living.
        // Skipped in deficit, where the set-aside target is deliberately zero.
        if income > 0 && targetSaving > 0 {
            reasons.append(String(format: loc("reco.why.livable"), Int((recommendedRate * 100).rounded())))
        }
        if reasons.isEmpty { reasons.append(loc("reco.why.default")) }
        // Ordered by how much they drive the plan, so trimming keeps the
        // load-bearing ones.
        if reasons.count > 5 { reasons = Array(reasons.prefix(5)) }

        let autoSave = roundNice(targetSaving)

        // ── Saving allocation ── split the recommended monthly saving across an
        // emergency buffer, the top goal, and short-term goals.
        var savingAllocation: [RecoSlice] = []
        if targetSaving > 0 {
            if let g = topGoal {
                savingAllocation = [
                    RecoSlice(label: loc("reco.alloc.emergency"), pct: 40, amount: targetSaving * 0.40, color: AppTheme.accent),
                    RecoSlice(label: String(format: loc("reco.alloc.goal"), g.name), pct: 40, amount: targetSaving * 0.40, color: AppTheme.blue),
                    RecoSlice(label: loc("reco.alloc.shortterm"), pct: 20, amount: targetSaving * 0.20, color: AppTheme.purple),
                ]
            } else {
                savingAllocation = [
                    RecoSlice(label: loc("reco.alloc.emergency"), pct: 60, amount: targetSaving * 0.60, color: AppTheme.accent),
                    RecoSlice(label: loc("reco.alloc.shortterm"), pct: 40, amount: targetSaving * 0.40, color: AppTheme.purple),
                ]
            }
        }
        // Only surface a "+% vs current" when the target is genuinely higher
        // than what the user currently saves (a stretch goal). When they
        // already save more than the target, showing a negative "+%" would be
        // confusing, so we clamp to 0 (badge hidden).
        let savingVsCurrentPct: Int = {
            if currentSaving > 0 { return max(0, Int(((targetSaving - currentSaving) / currentSaving) * 100)) }
            return targetSaving > 0 ? 100 : 0
        }()

        // ── Investment 10-year projection ── future value of the suggested
        // monthly contribution at a conservative 7%/yr (compounded monthly).
        let investReturn10y: Double = {
            guard suggestedInvestment > 0 else { return 0 }
            let r = 0.07 / 12.0, n = 120.0
            return suggestedInvestment * ((pow(1 + r, n) - 1) / r)
        }()

        // ── Spending mix ── average monthly spend per category, biggest first.
        var byCat: [TxCategory: Double] = [:]
        for tx in expenseTx { byCat[tx.category, default: 0] += toPref(abs(tx.amount), tx.currency) }
        let spendingBreakdown: [RecoSlice] = byCat.sorted { $0.value > $1.value }.prefix(5).map { cat, val in
            RecoSlice(label: cat.displayLabel,
                      pct: totalExpense > 0 ? Int((val / totalExpense) * 100) : 0,
                      amount: val / Double(months),
                      color: cat.color)
        }

        return SmartRecommendation(
            smartScore: max(0, min(score, 100)),
            scoreLabel: scoreLabel,
            spendingBalance: spendingBalance,
            savingHabit: savingHabit,
            investmentPotential: investmentPotential,
            transactionsAnalyzed: transactions.count,
            dataMonths: dataMonthsDisplay,
            confidence: confidence,
            currency: currency,
            monthlyIncome: income,
            avgMonthlyExpense: avgMonthlyExpense,
            currentMonthlySaving: currentSaving,
            recommendedMonthlySaving: targetSaving,
            extraSavingPerMonth: extraSaving,
            potentialCut: potentialCut,
            suggestedInvestment: suggestedInvestment,
            autoSaveAmount: autoSave,
            recommendedRatios: (daily, lifestyle, invest),
            topItems: items,
            reasons: reasons,
            topGoalName: topGoal?.name,
            goalMonthsFaster: goalMonthsFaster,
            savingAllocation: savingAllocation,
            savingVsCurrentPct: savingVsCurrentPct,
            investReturn10y: investReturn10y,
            spendingBreakdown: spendingBreakdown,
            goalCurrentMonths: goalCurrentMonths,
            goalNewMonths: goalNewMonths,
            isDeficit: isDeficit,
            deficitAmount: deficitAmount,
            debtMinimumMonthly: debtMinPayments,
            smallSpendMonthly: smallSpendMonthly,
            smallSpendCount: smallSpendCount,
            duplicateSuspectAmount: dupeExcess,
            periodLabel: periodLabel,
            metricDetails: metricDetails,
            declaredIntents: CycleIntentKind.allCases.filter { intents.has($0) }
        )
    }

    // MARK: - Helpers

    /// Rough recurring/subscription estimate: bills-category spend averaged per
    /// month. A fuller version would cluster same-name same-amount charges, but
    /// bills is a good, cheap proxy for "committed monthly outflow".
    private static func detectRecurringMonthly(_ expenseTx: [TxRecord], currency: String, months: Double) -> Double? {
        let cm = CurrencyManager.shared
        let bills = expenseTx.filter { $0.category == .bills }
        guard !bills.isEmpty else { return nil }
        let total = bills.reduce(0.0) { $0 + cm.convert(abs($1.amount), from: $1.currency.isEmpty ? currency : $1.currency, to: currency) }
        return total / max(months, 1)
    }

    /// Round an amount to a friendly figure so recommendations read cleanly
    /// (e.g. Rp 1.237.400 → Rp 1.250.000). Scales the rounding step with size.
    static func roundNice(_ value: Double) -> Double {
        guard value > 0 else { return 0 }
        let step: Double
        switch value {
        case ..<100_000:      step = 10_000
        case ..<1_000_000:    step = 50_000
        case ..<10_000_000:   step = 250_000
        default:              step = 500_000
        }
        return (value / step).rounded() * step
    }
}
