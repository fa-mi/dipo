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

/// One wedge of a breakdown (saving allocation or spending mix).
struct RecoSlice: Identifiable {
    let id = UUID()
    let label: String
    let pct: Int
    let amount: Double
    let color: Color
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
                        currency: String) -> SmartRecommendation {

        let sb = SmartBudgetManager.shared
        let cm = CurrencyManager.shared
        let months = max(sb.dataMonthsAvailable(allTransactions: transactions), 1)
        let confidence = sb.defaultConfidence(allTransactions: transactions)

        // ── Average monthly expense (per category group), over available data ──
        func toPref(_ amt: Double, _ cur: String) -> Double {
            cm.convert(amt, from: cur.isEmpty ? currency : cur, to: currency)
        }
        // Only real spending — skip transfers (own-account moves) and refunds.
        let expenseTx = transactions.filter { $0.amount < 0 && $0.txSubtype == .normal }
        let totalExpense = expenseTx.reduce(0.0) { $0 + toPref(abs($1.amount), $1.currency) }
        let avgMonthlyExpense = totalExpense / Double(months)

        func avgGroup(_ cats: [TxCategory]) -> Double {
            expenseTx.filter { cats.contains($0.category) }
                .reduce(0.0) { $0 + toPref(abs($1.amount), $1.currency) } / Double(months)
        }
        let dailyAvg     = avgGroup(SmartBudgetManager.dailyCategories)
        let lifestyleAvg = avgGroup(SmartBudgetManager.lifestyleCategories)

        // ── Essential-cost floor ──
        // Logged expenses frequently miss rent, family transfers, and cash
        // spending. If the tracked average is implausibly low for the income,
        // assume a realistic minimum of ~50% of income goes to essentials —
        // otherwise the engine thinks the user banks nearly their whole
        // paycheck, and both the score and the recommendations become fantasy.
        // `loggedRatio` (0…1) measures how complete the logging looks: 1.0 when
        // tracked spend already meets the floor, lower the more it under-shoots.
        let essentialFloor = income > 0 ? income * 0.50 : 0
        let effectiveExpense = max(avgMonthlyExpense, essentialFloor)
        let loggedRatio = essentialFloor > 0 ? min(avgMonthlyExpense / essentialFloor, 1) : 1

        // ── Saving ──
        // Surplus is computed against the *effective* (floored) expense so we
        // never assume the user saves money that's really going to unlogged
        // essentials.
        let currentSaving = income - effectiveExpense
        let savingsRate   = income > 0 ? currentSaving / income : 0
        // Recommend a SUSTAINABLE set-aside, not the whole surplus. Rationale:
        //   • `currentSaving` = income − *logged* expenses, but real costs like
        //     rent, transport, and family transfers are often under-logged, so
        //     the raw surplus overstates what's actually free to save.
        //   • Even for a genuine strong saver, telling them to bank ~70% of
        //     income is not livable advice.
        // So: aim for at least 20% of income, meet a strong saver partway, but
        // CAP at 35% — the plan always leaves the majority of income for living.
        let targetSaving: Double = income > 0
            ? min(max(income * 0.20, currentSaving), income * 0.35)
            : max(currentSaving, 0)
        let recommendedRate = income > 0 ? targetSaving / income : 0
        let extraSaving   = max(targetSaving - currentSaving, 0)

        // ── Cut opportunity ── lifestyle spend above a healthy 30% share.
        let healthyLifestyle = income * 0.30
        let potentialCut = income > 0 ? max(lifestyleAvg - healthyLifestyle, 0) : lifestyleAvg * 0.15

        // ── Investment ── a SLICE of the recommended saving (its long-term
        // portion), never an amount ON TOP of it — otherwise saving + investing
        // could exceed income (the old bug: 6.9jt save + 3.5jt invest > 10jt).
        // ~40% of the set-aside goes to long-term investing.
        let suggestedInvestment = targetSaving > 0 ? roundNice(targetSaving * 0.40) : 0

        // ── Recommended budget split ── start from the classic 50/30/20 and
        // nudge based on what the data shows.
        var daily = 0.50, lifestyle = 0.30, invest = 0.20
        let hasCostlyDebt = debts.contains { $0.isActive && $0.annualInterestRate > 0 }
        if hasCostlyDebt {
            // Prioritise clearing interest-bearing debt.
            daily = 0.50; lifestyle = 0.20; invest = 0.30
        } else if income > 0 && lifestyleAvg > income * 0.35 {
            // Overspending lifestyle → rein it in, redirect to invest/debt.
            daily = 0.50; lifestyle = 0.25; invest = 0.25
        } else if savingsRate >= 0.30 {
            // Strong saver → lean into investing.
            daily = 0.45; lifestyle = 0.20; invest = 0.35
        }

        // ── Ratings ──
        let savingHabit: RecoRating = {
            if savingsRate >= 0.30 { return .great }
            if savingsRate >= 0.20 { return .good }
            if savingsRate > 0     { return .fair }
            return .poor
        }()
        let lifeShare = income > 0 ? lifestyleAvg / income : 0
        let spendingBalance: RecoRating = {
            if avgMonthlyExpense > income && income > 0 { return .poor }
            if lifeShare > 0.40 { return .fair }
            if lifeShare > 0.30 { return .good }
            return .great
        }()
        let investmentPotential: RecoRating = {
            if savingsRate >= 0.30 { return .high }
            if savingsRate >= 0.15 { return .good }
            if savingsRate > 0     { return .fair }
            return .poor
        }()

        // ── Smart Score (0–100) ── saving (45) + balance (30) + invest potential (25).
        let savingScore = min(max(savingsRate / 0.30, 0), 1) * 45
        let balanceScore = Double(spendingBalance.rawValue) / Double(RecoRating.great.rawValue) * 30
        let investScore = Double(investmentPotential.rawValue) / Double(RecoRating.high.rawValue) * 25
        let rawScore = savingScore + balanceScore + investScore
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
        var items: [RecoItem] = []
        if extraSaving > 0 {
            items.append(RecoItem(
                icon: "banknote.fill", tint: AppTheme.accent,
                title: String(format: loc("reco.item.save_title"), cm.formatted(roundNice(extraSaving), currency: currency)),
                subtitle: goalMonthsFaster != nil
                    ? String(format: loc("reco.item.save_sub_goal"), goalMonthsFaster!)
                    : loc("reco.item.save_sub"),
                badge: goalMonthsFaster != nil ? String(format: loc("reco.badge.months_faster"), goalMonthsFaster!) : loc("reco.badge.recommended"),
                badgeTint: AppTheme.accent))
        }
        if potentialCut > 0 {
            items.append(RecoItem(
                icon: "scissors", tint: AppTheme.orange,
                title: loc("reco.item.cut_title"),
                subtitle: String(format: loc("reco.item.cut_sub"), cm.formatted(roundNice(potentialCut), currency: currency)),
                badge: cm.formatted(roundNice(potentialCut), currency: currency),
                badgeTint: AppTheme.orange))
        }
        if suggestedInvestment > 0 {
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
        if lifeShare > 0.30 {
            reasons.append(String(format: loc("reco.why.lifestyle"), Int(lifeShare * 100)))
        }
        if let recurring = detectRecurringMonthly(expenseTx, currency: currency, months: months), recurring > 0 {
            reasons.append(String(format: loc("reco.why.recurring"), cm.formatted(roundNice(recurring), currency: currency)))
        }
        if savingsRate < 0.20 {
            reasons.append(loc("reco.why.saverate"))
        }
        if savingsRate > 0.10 && !debts.contains(where: { $0.isActive }) {
            reasons.append(loc("reco.why.invest"))
        }
        // Transparency: the plan intentionally keeps most income for living.
        if income > 0 {
            reasons.append(String(format: loc("reco.why.livable"), Int((recommendedRate * 100).rounded())))
        }
        if reasons.isEmpty { reasons.append(loc("reco.why.default")) }

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
            dataMonths: months,
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
            goalNewMonths: goalNewMonths
        )
    }

    // MARK: - Helpers

    /// Rough recurring/subscription estimate: bills-category spend averaged per
    /// month. A fuller version would cluster same-name same-amount charges, but
    /// bills is a good, cheap proxy for "committed monthly outflow".
    private static func detectRecurringMonthly(_ expenseTx: [TxRecord], currency: String, months: Int) -> Double? {
        let cm = CurrencyManager.shared
        let bills = expenseTx.filter { $0.category == .bills }
        guard !bills.isEmpty else { return nil }
        let total = bills.reduce(0.0) { $0 + cm.convert(abs($1.amount), from: $1.currency.isEmpty ? currency : $1.currency, to: currency) }
        return total / Double(months)
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
