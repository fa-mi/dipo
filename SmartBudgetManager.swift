import SwiftUI
import SwiftData

// MARK: - Smart Budget Manager
// Singleton that persists budget settings and provides spending intelligence

@Observable
final class SmartBudgetManager {
    static let shared = SmartBudgetManager()
    private init() { load() }

    // MARK: - Settings (persisted in UserDefaults)

    /// Master toggle — user's preference for whether they want Smart Budget on.
    /// This persists across login state and across app launches.
    /// IMPORTANT: This being `true` is NOT enough to grant access. Always check
    /// `hasActiveBudget` (or `PremiumManager.shared.canAccess(.smartBudget)`)
    /// before surfacing budget data — otherwise a Royal user who logs out
    /// (or whose subscription lapsed) would still see premium-only widgets
    /// like the budget allocation block in the export sheet.
    var isEnabled: Bool = false {
        didSet { save() }
    }

    /// Effective access flag. True ONLY when both:
    ///   - the user toggled Smart Budget on in settings, AND
    ///   - they currently have Royal subscription (or active session that
    ///     `canAccess(.smartBudget)` returns true for).
    /// Use this — not `isEnabled` — anywhere you decide whether to render
    /// budget allocation, run `topInsight`, or block transactions via
    /// `wouldExceed`. This is the single point where premium gating happens
    /// for Smart Budget; new code paths only need to check this one flag.
    var hasActiveBudget: Bool {
        isEnabled && PremiumManager.shared.canAccess(.smartBudget)
    }

    /// % of income allocated to daily needs (food, transport, bills)
    var dailyRatio: Double = 0.50 {
        didSet { save() }
    }

    /// % of income allocated to lifestyle (shopping, health, travel, other)
    var lifestyleRatio: Double = 0.30 {
        didSet { save() }
    }

    /// % of income allocated to invest/debt payments
    var investDebtRatio: Double = 0.20 {
        didSet { save() }
    }

    /// The main card used for budget tracking.
    /// nil = use all cards. Set by the user in Smart Budget settings.
    var budgetCardID: String? = nil {
        didSet { save() }
    }

    // MARK: - Category Groups

    static let dailyCategories: [TxCategory]   = [.food, .transport, .bills, .health]
    static let lifestyleCategories: [TxCategory] = [.shopping, .travel, .other]
    static let investDebtCategories: [TxCategory] = [.investment, .bonus, .debtPayment]

    /// Categories that are typically FIXED (recurring, contractual, hard to
    /// change in-month). When the engine generates "you have Rp X left for
    /// daily", it's more useful to know the *variable* portion since fixed
    /// is already committed. Bills + recurring health (insurance) are the
    /// most common fixed buckets in Indonesian context.
    static let fixedCategories: [TxCategory] = [.bills]

    /// True if the category is generally fixed (already-committed). Used
    /// to compute "variable remaining" insight: more actionable than the
    /// raw group remaining when bills swallow most of the daily budget.
    static func isFixedCategory(_ cat: TxCategory) -> Bool {
        fixedCategories.contains(cat)
    }

    // MARK: - Computed Budget Limits

    func monthlyLimit(for group: BudgetGroup, income: Double) -> Double {
        switch group {
        case .daily:     return income * dailyRatio
        case .lifestyle: return income * lifestyleRatio
        case .investDebt: return income * investDebtRatio
        }
    }
    
    /// Simple ratio accessor by group — used by views that want the global
    /// allocation ratio without per-card complexity.
    func ratio(for group: BudgetGroup) -> Double {
        switch group {
        case .daily:      return dailyRatio
        case .lifestyle:  return lifestyleRatio
        case .investDebt: return investDebtRatio
        }
    }
    
    /// Per-card ratio resolution. Looks up CardBudgetConfig from the given list
    /// (typically a @Query result) and falls back to global defaults if no
    /// config row exists yet for this card. This is the single API the rest
    /// of the app should use for "what are this card's ratios".
    func ratios(forCardID cardID: String?, configs: [CardBudgetConfig]) -> (daily: Double, lifestyle: Double, investDebt: Double) {
        guard let cardID,
              let cfg = configs.first(where: { $0.cardID == cardID })
        else { return (dailyRatio, lifestyleRatio, investDebtRatio) }
        return (cfg.dailyRatio, cfg.lifestyleRatio, cfg.investDebtRatio)
    }
    
    /// Convenience: monthly limit for a group using per-card ratios.
    func monthlyLimit(for group: BudgetGroup, income: Double, cardID: String?, configs: [CardBudgetConfig]) -> Double {
        let r = ratios(forCardID: cardID, configs: configs)
        switch group {
        case .daily:      return income * r.daily
        case .lifestyle:  return income * r.lifestyle
        case .investDebt: return income * r.investDebt
        }
    }

    func group(for category: TxCategory) -> BudgetGroup? {
        if Self.dailyCategories.contains(category)     { return .daily }
        if Self.lifestyleCategories.contains(category) { return .lifestyle }
        if Self.investDebtCategories.contains(category) { return .investDebt }
        return nil
    }

    // MARK: - Spending Analysis

    /// How much spent this month in a group, denominated in the given target
    /// currency. Without this parameter, `spent` would always be in the user's
    /// preferred currency while `income` (computed by the caller) might be in
    /// a different card's currency — causing wildly wrong ratios like
    /// "2,866,395% over budget" when comparing IDR-denominated spend against
    /// a USD-denominated limit.
    func spent(in group: BudgetGroup, transactions: [TxRecord], targetCurrency: String? = nil) -> Double {
        let cal = Calendar.current
        let monthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: Date()))
        let cats = categories(for: group)
        let target = targetCurrency ?? CurrencyManager.shared.preferredCurrency
        // Transfer subtype: skip outright (movement between user's own
        // accounts, not real spend). Refund subtype: SUBTRACT from spend
        // since it reverses an earlier expense in the same category. Both
        // are gated behind hasActiveBudget at the public-method level.
        return transactions
            .filter { $0.date >= monthStart && cats.contains($0.category) }
            .filter { $0.txSubtype != .transfer }
            .reduce(0.0) { sum, tx in
                let txCur = tx.currency.isEmpty ? target : tx.currency
                let amt = CurrencyManager.shared.convert(abs(tx.amount), from: txCur, to: target)
                if tx.txSubtype == .refund {
                    // Refund is stored as positive amount conceptually but
                    // the user might log it either way. We treat |amount|
                    // as the refund value and subtract from the bucket.
                    return sum - amt
                }
                // Normal expense (negative amount).
                return tx.amount < 0 ? sum + amt : sum
            }
    }

    func categories(for group: BudgetGroup) -> [TxCategory] {
        switch group {
        case .daily:      return Self.dailyCategories
        case .lifestyle:  return Self.lifestyleCategories
        case .investDebt: return Self.investDebtCategories
        }
    }

    /// Remaining budget for a group this month
    func remaining(in group: BudgetGroup, transactions: [TxRecord], income: Double) -> Double {
        monthlyLimit(for: group, income: income) - spent(in: group, transactions: transactions)
    }

    /// Splits this-month spend in the daily group into fixed (bills) vs
    /// variable (food/transport/health). Surfaced in insights so users can
    /// see "Bills 800k done, sisa 700k untuk makan/transport" instead of
    /// just "Daily 1.5jt of 2jt used" which doesn't tell them what's
    /// actually adjustable this week.
    func dailySpendBreakdown(transactions: [TxRecord],
                             targetCurrency: String? = nil) -> (fixed: Double, variable: Double) {
        let cal = Calendar.current
        let monthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: Date()))
        let target = targetCurrency ?? CurrencyManager.shared.preferredCurrency
        var fixed: Double = 0
        var variable: Double = 0
        for tx in transactions where tx.amount < 0 && tx.date >= monthStart {
            guard Self.dailyCategories.contains(tx.category) else { continue }
            let txCur = tx.currency.isEmpty ? target : tx.currency
            let amt = CurrencyManager.shared.convert(abs(tx.amount), from: txCur, to: target)
            if Self.isFixedCategory(tx.category) {
                fixed += amt
            } else {
                variable += amt
            }
        }
        return (fixed, variable)
    }

    /// % used for a group
    func percentUsed(in group: BudgetGroup, transactions: [TxRecord], income: Double) -> Double {
        let limit = monthlyLimit(for: group, income: income)
        guard limit > 0 else { return 0 }
        return min(spent(in: group, transactions: transactions) / limit, 1.5)
    }

    /// Check if a new transaction would exceed the group limit.
    /// Pass the currency of the transaction being added so amounts are correctly converted.
    func wouldExceed(category: TxCategory, amount: Double, currency: String = "IDR",
                     transactions: [TxRecord], income: Double) -> BudgetAlert? {
        // Defense-in-depth: bail on missing access too. Otherwise a logged-out
        // user with a stale `isEnabled = true` setting would get budget
        // exceedance prompts during transaction entry — visible leakage of a
        // premium feature.
        guard hasActiveBudget else { return nil }

        // Debt payments are financially positive — never block regardless of ratio
        if category == .debtPayment { return nil }

        guard let grp = group(for: category) else { return nil }
        let limit = monthlyLimit(for: grp, income: income)
        guard limit > 0 else { return nil }

        let alreadySpent: Double
        if grp == .investDebt {
            let monthStart = Calendar.current.safeDate(from: Calendar.current.dateComponents([.year, .month], from: Date()))
            alreadySpent = transactions
                .filter { $0.amount < 0 && $0.date >= monthStart
                    && ($0.category == .investment || $0.category == .bonus) }
                .reduce(0) { $0 + CurrencyManager.shared.toPreferred(abs($1.amount), from: $1.currency) }
        } else {
            alreadySpent = spent(in: grp, transactions: transactions)
        }

        // Convert the new amount to preferred currency before comparing
        let amountConverted = CurrencyManager.shared.toPreferred(abs(amount), from: currency)
        let newTotal = alreadySpent + amountConverted

        if newTotal > limit {
            let over = newTotal - limit
            return BudgetAlert(group: grp, limit: limit, spent: alreadySpent, newTotal: newTotal, over: over,
                               categoryLabel: specificLabel(for: category))
        }
        if newTotal / limit > 0.9 && alreadySpent / limit <= 0.9 {
            return BudgetAlert(group: grp, limit: limit, spent: alreadySpent, newTotal: newTotal, over: 0,
                               isWarning: true, categoryLabel: specificLabel(for: category))
        }
        return nil
    }

    /// Human-readable label for a specific category in budget context
    private func specificLabel(for category: TxCategory) -> String {
        switch category {
        case .debtPayment: return "Debt payment"
        case .investment:  return "Investment"
        default:           return group(for: category)?.label ?? category.rawValue
        }
    }

    // MARK: - Smart Insights

    /// Generate the top insight for the home screen.
    ///
    /// `cardID` and `configs` together let this method use per-card budget
    /// ratios — when the user swipes to a different card on Home, this gets
    /// called with that card's id and returns insights tuned to *that* card's
    /// allocation strategy. Pass `cardID = nil` and any `configs` to use the
    /// global default ratios (legacy behavior).
    ///
    /// `targetCurrency` is the currency that `income` is denominated in. All
    /// spend amounts are converted to this currency before comparing against
    /// limits. CRITICAL: caller MUST pass this when income is per-card. Without
    /// it, spend defaults to user's preferredCurrency while income may be
    /// USD, producing absurd ratios (4M IDR / $90 = "4,400,000% over").
    /// Backwards-compatible wrapper around `evaluateAll`. Returns the first
    /// (highest-priority) insight only — used by callers that just want a
    /// single primary banner. New callers wanting multi-banner UX should
    /// use `evaluateAll(...)` directly.
    func topInsight(allTransactions: [TxRecord], income: Double,
                    cardID: String? = nil,
                    configs: [CardBudgetConfig] = [],
                    targetCurrency: String? = nil,
                    goals: [SavingsGoal] = []) -> SmartInsight? {
        evaluateAll(
            allTransactions: allTransactions,
            income: income,
            cardID: cardID,
            configs: configs,
            targetCurrency: targetCurrency,
            goals: goals
        ).first
    }

    /// Internal-or-future-use multi-insight evaluator. Returns insights ordered
    /// by severity (errors → warnings → positive), deduped, capped at 3.
    /// Reuses the existing single-match logic by collecting instead of
    /// returning early on the first match. UI can render 1 primary + 2
    /// "see more" entries when the count is >1.
    func evaluateAll(allTransactions: [TxRecord], income: Double,
                     cardID: String? = nil,
                     configs: [CardBudgetConfig] = [],
                     targetCurrency: String? = nil,
                     goals: [SavingsGoal] = []) -> [SmartInsight] {
        // Royal-only feature. Defense-in-depth: every public engine method
        // checks hasActiveBudget so a future caller that forgets to gate
        // can't accidentally leak premium output. The wrapped methods
        // (primaryInsight, yearOverYearInsight) check independently too.
        guard hasActiveBudget else { return [] }
        // Opportunistic cleanup of last month's dismissals so the new month
        // resurfaces insights cleanly. Cheap, runs at most once per call.
        sweepStaleDismissals()
        // The current `topInsight` body uses `return` to short-circuit on
        // first match; we keep that behavior for the primary insight, and
        // run a separate lightweight pass for "secondary" positive ones.
        var results: [SmartInsight] = []
        if let primary = primaryInsight(
            allTransactions: allTransactions, income: income,
            cardID: cardID, configs: configs,
            targetCurrency: targetCurrency, goals: goals
        ) {
            results.append(primary)
        }

        // Secondary positives — show alongside primary IF primary was a
        // warning/error (so the user gets balanced feedback instead of just
        // doom). Don't duplicate any already-surfaced category.
        let target = targetCurrency ?? CurrencyManager.shared.preferredCurrency
        let cal = Calendar.current
        let monthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: Date()))
        let thisTx = allTransactions.filter { $0.date >= monthStart && $0.amount < 0 }
        let debtPaid = allTransactions
            .filter { $0.amount < 0 && $0.date >= monthStart && $0.category == .debtPayment }
            .reduce(0.0) { sum, tx in
                let txCur = tx.currency.isEmpty ? target : tx.currency
                return sum + CurrencyManager.shared.convert(abs(tx.amount), from: txCur, to: target)
            }
        let totalSpent = thisTx.reduce(0.0) { sum, tx in
            let txCur = tx.currency.isEmpty ? target : tx.currency
            return sum + CurrencyManager.shared.convert(abs(tx.amount), from: txCur, to: target)
        } - debtPaid
        let savings = income - totalSpent - debtPaid

        // Add positive savings insight if primary was a warning AND user is
        // actually saving — this is the "balanced feedback" case.
        let primaryIsWarning = results.first?.color == AppTheme.red || results.first?.color == AppTheme.orange
        if primaryIsWarning, savings > 0, income > 0 {
            let rate = Int((savings / income) * 100)
            if rate >= 10 {  // only celebrate ≥10% — below that it's noise
                results.append(SmartInsight(
                    icon: rate >= 20 ? "checkmark.seal.fill" : "info.circle.fill",
                    color: rate >= 20 ? AppTheme.accent : AppTheme.blue,
                    title: rate >= 20
                        ? loc("insight.savings_great_title")
                        : String(format: loc("insight.savings_rate_title"), rate),
                    body: rate >= 20
                        ? String(format: loc("insight.savings_great_body"), rate)
                        : String(format: loc("insight.savings_low_body"), rate)
                ))
            }
        }

        // Year-over-year insight — surface when user has ≥12 months of
        // data and the same-month comparison is meaningful. Goes AFTER
        // primary + secondary positive (which is short-term-focused) but
        // BEFORE the cap at 3, so power users see the long-term signal
        // alongside this-month feedback.
        if let yoy = yearOverYearInsight(
            allTransactions: allTransactions,
            targetCurrency: target
        ) {
            results.append(yoy)
        }

        // Filter dismissed insights — same type within current month is
        // suppressed until the user resurfaces it via Settings or month rolls.
        // Then attach confidence based on how much historical data we have:
        // a "spike vs last month" insight from a 1-week-old account is
        // necessarily low-confidence even if the math looks alarming.
        let confidence = defaultConfidence(allTransactions: allTransactions)
        let filtered = results
            .filter { notDismissed($0) }
            .map { (insight: SmartInsight) -> SmartInsight in
                var copy = insight
                copy.confidence = confidence
                return copy
            }
        return Array(filtered.prefix(3))
    }

    /// Original first-match insight logic. Renamed from `topInsight` so the
    /// new `topInsight` wrapper + `evaluateAll` aggregator can share it.
    private func primaryInsight(allTransactions: [TxRecord], income: Double,
                                cardID: String?, configs: [CardBudgetConfig],
                                targetCurrency: String?, goals: [SavingsGoal]) -> SmartInsight? {
        // Premium gate: same defense-in-depth rationale as wouldExceed —
        // hasActiveBudget covers both "user toggled it off" and "user no
        // longer has Royal access".
        guard hasActiveBudget, income > 0 else { return nil }
        // targetCurrency: currency income is denominated in (e.g. "USD" for PayPal).
        // ALL spend amounts must be converted to this same currency before comparing
        // against limits, otherwise IDR spend vs USD limit produces absurd ratios.
        let target = targetCurrency ?? CurrencyManager.shared.preferredCurrency
        // Per-card ratios: each card can have its own daily/lifestyle/investDebt split.
        // Falls back to global ratios when no per-card config exists for this cardID.
        let r = ratios(forCardID: cardID, configs: configs)
        let cal = Calendar.current
        let now = Date()
        let monthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: now))
        let lastMonthStart = cal.safeDate(byAdding: .month, value: -1, to: monthStart)

        let thisTx = allTransactions.filter { $0.date >= monthStart && $0.amount < 0 }
        let lastTx = allTransactions.filter { $0.date >= lastMonthStart && $0.date < monthStart && $0.amount < 0 }

        // Check each group for overspend using PER-CARD ratios.
        // spent() is called with targetCurrency so IDR spend and USD income
        // are always compared in the same unit.
        for grp in BudgetGroup.allCases {
            let limit: Double = {
                switch grp {
                case .daily:      return income * r.daily
                case .lifestyle:  return income * r.lifestyle
                case .investDebt: return income * r.investDebt
                }
            }()

            if grp == .investDebt {
                // For investDebt, split into debt payments vs investment separately
                let cal = Calendar.current
                let mStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: now))

                let debtSpent = allTransactions
                    .filter { $0.amount < 0 && $0.date >= mStart && $0.category == .debtPayment }
                    .reduce(0.0) { sum, tx in
                        let txCur = tx.currency.isEmpty ? target : tx.currency
                        return sum + CurrencyManager.shared.convert(abs(tx.amount), from: txCur, to: target)
                    }

                let investSpent = allTransactions
                    .filter { $0.amount < 0 && $0.date >= mStart && $0.category == .investment }
                    .reduce(0.0) { sum, tx in
                        let txCur = tx.currency.isEmpty ? target : tx.currency
                        return sum + CurrencyManager.shared.convert(abs(tx.amount), from: txCur, to: target)
                    }

                // Debt payments: only warn if they exceed 70% of total income (extreme overpayment)
                if debtSpent > income * 0.70 {
                    let pct = Int((debtSpent / (income * 0.70) - 1) * 100)
                    return SmartInsight(
                        icon: "creditcard.fill",
                        color: AppTheme.orange,
                        title: loc("insight.debt_high_title"),
                        body: String(format: loc("insight.debt_high_body"), pct),
                        action: SmartInsightAction(
                            label: loc("insight.action.view_debt"),
                            kind: .openDebt
                        )
                    )
                }

                // Investment spending: warn if over the investDebt ratio limit
                if investSpent > limit {
                    if limit <= 0 {
                        return SmartInsight(
                            icon: "chart.line.uptrend.xyaxis",
                            color: AppTheme.red,
                            title: loc("insight.invest_over_title"),
                            body: String(format: loc("insight.group_unbudgeted_body"), BudgetGroup.investDebt.label.lowercased()),
                            action: SmartInsightAction(
                                label: loc("insight.action.adjust_budget"),
                                kind: .openBudgetSettings
                            )
                        )
                    }
                    let pct = Int((investSpent / limit - 1) * 100)
                    return SmartInsight(
                        icon: "chart.line.uptrend.xyaxis",
                        color: AppTheme.red,
                        title: loc("insight.invest_over_title"),
                        body: String(format: loc("insight.invest_over_body"), pct),
                        action: SmartInsightAction(
                            label: loc("insight.action.adjust_budget"),
                            kind: .openBudgetSettings
                        )
                    )
                }
            } else {
                let spent = self.spent(in: grp, transactions: allTransactions, targetCurrency: target)
                if spent > limit {
                    // Guard against limit = 0 (user set this group's ratio to 0%).
                    // Without this guard, `spent / 0` blows up to infinity and we
                    // render absurd values like "2,866,395% over budget".
                    // When the user has explicitly allocated 0% to a group, ANY
                    // spending there is unbudgeted — show a special message
                    // instead of computing a meaningless ratio.
                    if limit <= 0 {
                        return SmartInsight(
                            icon: "exclamationmark.triangle.fill",
                            color: AppTheme.red,
                            title: String(format: loc("insight.group_over_title"), grp.label),
                            body: String(format: loc("insight.group_unbudgeted_body"), grp.label.lowercased()),
                            action: SmartInsightAction(
                                label: loc("insight.action.adjust_budget"),
                                kind: .openBudgetSettings
                            )
                        )
                    }
                    let pct = Int((spent / limit - 1) * 100)
                    // Quantified target: "to get back on track, limit X/day".
                    // dayOfMonth + daysInMonth give us the "days remaining"
                    // window. We also surface this in the action label so
                    // the user sees something concrete, not just "Adjust".
                    let dayOfMonth = cal.component(.day, from: now)
                    let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
                    let daysLeft = max(daysInMonth - dayOfMonth + 1, 1)
                    let remaining = max(limit - spent, 0)
                    let dailyTarget = remaining / Double(daysLeft)
                    let dailyFmt = CurrencyManager.shared.formatted(dailyTarget, currency: target)
                    // For the Daily group specifically, decompose into fixed
                    // (bills, already-committed) vs variable (food/transport,
                    // user-adjustable). User can act on the variable portion
                    // this week — not the fixed portion which is contracted.
                    var bodyWithTarget = String(format: loc("insight.group_over_body"), pct, grp.label.lowercased())
                    if grp == .daily {
                        let bd = dailySpendBreakdown(transactions: allTransactions, targetCurrency: target)
                        if bd.fixed > 0 || bd.variable > 0 {
                            let fixedFmt = CurrencyManager.shared.formatted(bd.fixed, currency: target)
                            let variableFmt = CurrencyManager.shared.formatted(bd.variable, currency: target)
                            bodyWithTarget += " " + String(format: loc("insight.daily_breakdown"), fixedFmt, variableFmt)
                        }
                    }
                    bodyWithTarget += " " + String(format: loc("insight.target_per_day"), dailyFmt, daysLeft)
                    return SmartInsight(
                        icon: "exclamationmark.triangle.fill",
                        color: AppTheme.red,
                        title: String(format: loc("insight.group_over_title"), grp.label),
                        body: bodyWithTarget,
                        action: SmartInsightAction(
                            label: loc("insight.action.adjust_budget"),
                            kind: .openBudgetSettings
                        )
                    )
                }
            }
        }

        // Compare vs last month — all in target currency for consistency.
        // Use reliableSpikePct so we don't surface "Food up 1117%" when last
        // month barely had any food data. Minimum baseline = Rp 100k-equiv.
        let cats = TxCategory.allCases
        var biggestSpike: (cat: TxCategory, pct: Int)? = nil
        for cat in cats {
            let thisAmt = thisTx.filter { $0.category == cat }.reduce(0.0) { sum, tx in
                let txCur = tx.currency.isEmpty ? target : tx.currency
                return sum + CurrencyManager.shared.convert(abs(tx.amount), from: txCur, to: target)
            }
            let lastAmt = lastTx.filter { $0.category == cat }.reduce(0.0) { sum, tx in
                let txCur = tx.currency.isEmpty ? target : tx.currency
                return sum + CurrencyManager.shared.convert(abs(tx.amount), from: txCur, to: target)
            }
            guard let pct = reliableSpikePct(this: thisAmt, last: lastAmt, target: target) else {
                continue
            }
            if biggestSpike == nil || pct > (biggestSpike?.pct ?? 0) {
                biggestSpike = (cat, pct)
            }
        }
        if let spike = biggestSpike {
            return SmartInsight(
                icon: spike.cat.icon,
                color: spike.cat.color,
                title: String(format: loc("insight.cat_up_title"), spike.cat.displayLabel, spike.pct),
                body: String(format: loc("insight.cat_up_body"), spike.pct, spike.cat.displayLabel.lowercased())
            )
        }

        // Lifestyle pacing — mid-month proactive check.
        // If we're past the 40% mark of the month and lifestyle spend is already
        // tracking high vs the limit, warn before they go over. This is the
        // "smart" insight users praise — catches problems before they happen.
        let dayOfMonth = cal.component(.day, from: now)
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let monthProgress = Double(dayOfMonth) / Double(daysInMonth)
        if monthProgress >= 0.40 && monthProgress <= 0.85 {
            let lifestyleLimit = income * r.lifestyle
            let lifestyleSpent = self.spent(in: .lifestyle, transactions: allTransactions, targetCurrency: target)
            if lifestyleLimit > 0 {
                let utilization = lifestyleSpent / lifestyleLimit
                // Spent ratio outpacing month progress by 20%+ → on track to overspend
                if utilization > monthProgress + 0.20 && utilization < 1.0 {
                    let projected = Int((utilization / monthProgress) * 100) - 100
                    return SmartInsight(
                        icon: "speedometer",
                        color: AppTheme.orange,
                        title: loc("insight.lifestyle_pacing_title"),
                        body: String(format: loc("insight.lifestyle_pacing_body"), projected)
                    )
                }
            }
        }

        // Ratio sanity check — warn user if their budget allocation looks risky.
        // High lifestyle ratio (≥60%) means very little room for essentials/savings.
        // This is a proactive insight — fires even if they haven't overspent yet,
        // because the *plan* itself is fragile.
        if r.lifestyle >= 0.60 {
            let lifestylePct = Int(r.lifestyle * 100)
            return SmartInsight(
                icon: "exclamationmark.triangle",
                color: AppTheme.orange,
                title: loc("insight.ratio_risky_title"),
                body: String(format: loc("insight.ratio_risky_lifestyle_body"), lifestylePct),
                action: SmartInsightAction(
                    label: loc("insight.action.adjust_budget"),
                    kind: .openBudgetSettings
                )
            )
        }
        // Very low daily ratio (<25%) — essentials might not fit
        if r.daily < 0.25 && r.daily > 0 {
            let dailyPct = Int(r.daily * 100)
            return SmartInsight(
                icon: "exclamationmark.triangle",
                color: AppTheme.orange,
                title: loc("insight.ratio_risky_title"),
                body: String(format: loc("insight.ratio_risky_daily_body"), dailyPct),
                action: SmartInsightAction(
                    label: loc("insight.action.adjust_budget"),
                    kind: .openBudgetSettings
                )
            )
        }

        // Savings rate — exclude debt payments (they're net-worth positive, not spending)
        let debtPaid = allTransactions
            .filter { $0.amount < 0 && $0.date >= monthStart && $0.category == .debtPayment }
            .reduce(0.0) { sum, tx in
                let txCur = tx.currency.isEmpty ? target : tx.currency
                return sum + CurrencyManager.shared.convert(abs(tx.amount), from: txCur, to: target)
            }
        let totalSpent = thisTx.reduce(0.0) { sum, tx in
            let txCur = tx.currency.isEmpty ? target : tx.currency
            return sum + CurrencyManager.shared.convert(abs(tx.amount), from: txCur, to: target)
        } - debtPaid
        let savings = income - totalSpent - debtPaid  // what's truly left over

        // If user is actively paying debt, show a debt-focused insight instead
        if debtPaid > 0 {
            let debtPct = Int((debtPaid / income) * 100)
            let trueSpendPct = Int((totalSpent / income) * 100)
            if trueSpendPct <= Int((1 - r.daily - r.lifestyle) * 100) + 5 {
                return SmartInsight(
                    icon: "creditcard.fill",
                    color: AppTheme.accent,
                    title: loc("insight.debt_progress_title"),
                    body: String(format: loc("insight.debt_progress_body"), debtPct),
                    action: SmartInsightAction(
                        label: loc("insight.action.view_debt"),
                        kind: .openDebt
                    )
                )
            }
        }

        // Goal-linked tradeoff — surface a personally meaningful "if you
        // cut X, you reach goal Y weeks earlier" message. Inserted BEFORE
        // the generic savings-rate insight because it's strictly more
        // actionable: tells the user a concrete number they could reclaim
        // and ties it to a goal they personally care about.
        if let goalInsight = goalLinkedInsight(
            allTransactions: allTransactions,
            income: income,
            goals: goals,
            targetCurrency: target
        ) {
            return goalInsight
        }

        if savings > 0 {
            let rate = Int((savings / income) * 100)
            let icon = rate >= 20 ? "checkmark.seal.fill" : "info.circle.fill"
            let color: Color = rate >= 20 ? AppTheme.accent : AppTheme.orange
            return SmartInsight(
                icon: icon, color: color,
                title: rate >= 20
                    ? loc("insight.savings_great_title")
                    : String(format: loc("insight.savings_rate_title"), rate),
                body: rate >= 20
                    ? String(format: loc("insight.savings_great_body"), rate)
                    : String(format: loc("insight.savings_low_body"), rate)
            )
        }

        return nil
    }

    // MARK: - Goal-Linked Insight

    /// Surfaces a personally-meaningful insight that connects current
    /// spending to the user's top SavingsGoal. Quantifies a tradeoff:
    /// "kalau cut lifestyle 10% bulan ini, target [goal] tercapai N minggu
    /// lebih cepat". This is the most personal kind of insight — descriptive
    /// alarms ("you overspent X%") feel impersonal next to "your honeymoon
    /// will land 3 weeks earlier if you skip 2 GoFood orders."
    ///
    /// - Returns nil when no actionable trade-off exists (no goal, goal
    ///   already complete, or current pace is fine + no overspend room to
    ///   reclaim).
    func goalLinkedInsight(allTransactions: [TxRecord],
                           income: Double,
                           goals: [SavingsGoal],
                           targetCurrency: String? = nil) -> SmartInsight? {
        guard hasActiveBudget, income > 0 else { return nil }
        let target = targetCurrency ?? CurrencyManager.shared.preferredCurrency

        // Pick the highest-priority active goal that's not yet complete.
        // Tie-break by largest remaining (= most meaningful tradeoff).
        let activeGoals = goals.filter { !$0.isCompleted && $0.targetAmount > $0.savedAmount }
        guard let goal = activeGoals
            .sorted(by: { ($0.priority, $1.remaining) < ($1.priority, $0.remaining) })
            .first else { return nil }

        // How much would the user need to save monthly to hit `targetDate`?
        // If no targetDate, fall back to monthlyContribution (their stated pace).
        // All amounts converted to a single currency for consistent math.
        let goalRemaining = CurrencyManager.shared.convert(
            goal.remaining, from: goal.currency, to: target)
        guard goalRemaining > 0 else { return nil }

        // Current month's lifestyle spend — this is what we're inviting the
        // user to potentially reclaim. We only suggest cutting from
        // discretionary spend (lifestyle), never essentials (daily).
        let lifestyleSpent = self.spent(in: .lifestyle,
                                        transactions: allTransactions,
                                        targetCurrency: target)
        // Need a meaningful baseline. If lifestyle <Rp 100k equivalent
        // (~$7), trade-off is too small to be motivating.
        let minMeaningful = CurrencyManager.shared.convert(100_000, from: "IDR", to: target)
        guard lifestyleSpent > minMeaningful else { return nil }

        // Hypothetical: what if user cut 15% of this month's lifestyle?
        // 15% is the sweet spot — meaningful enough to matter, small enough
        // to feel achievable (not "cut 50% of fun").
        let cutPercent = 0.15
        let monthlySaving = lifestyleSpent * cutPercent

        // How many months earlier does the goal land if user keeps this
        // saving up? Avoid division by zero / nonsense for tiny amounts.
        guard monthlySaving > 0, goalRemaining > monthlySaving else { return nil }
        let monthsEarlier = goalRemaining / (goalRemaining / 1.0 + monthlySaving) // rough proxy
        // Simpler model: if user already saving X/month toward goal, adding
        // monthlySaving cuts time by `monthlySaving / X * weeks`.
        // We use a flat conversion: 1 month saving = ~4.3 weeks earlier.
        let weeksEarlier = Int((monthlySaving / goalRemaining) * 52)
        guard weeksEarlier >= 1 else { return nil }
        let _ = monthsEarlier  // silence unused (kept for future calibration)

        let savingFmt = CurrencyManager.shared.formatted(monthlySaving, currency: target)
        return SmartInsight(
            icon: "target",
            color: AppTheme.accent,
            title: String(format: loc("insight.goal_linked_title"),
                          goal.emoji.isEmpty ? "🎯" : goal.emoji,
                          goal.name),
            body: String(format: loc("insight.goal_linked_body"),
                         Int(cutPercent * 100), savingFmt, weeksEarlier, goal.name),
            action: SmartInsightAction(
                label: loc("insight.action.view_goal"),
                kind: .openSavingsGoals
            )
        )
    }

    // MARK: - Auto Categorize

    static let merchantMap: [(keywords: [String], category: TxCategory)] = [
        // Food — minimarkets, restaurants, cafes, food delivery, groceries
        (["indomaret", "alfamart", "alfamidi", "lawson", "7-eleven", "711", "circle k",
          "family mart", "minimarket",
          "warteg", "warung", "makan", "nasi", "mie", "bakso", "sate", "padang",
          "kfc", "mcdonald", "mcd", "burger king", "pizza hut", "domino", "wendy",
          "starbucks", "cafe", "coffee", "kopi kenangan", "janji jiwa", "fore",
          "gofood", "grabfood", "shopeefood", "restoran", "restaurant", "food",
          "hokben", "yoshinoya", "geprek", "ayam", "soto", "rendang",
          "j.co", "dunkin", "krispy kreme", "chatime", "xing fu tang",
          "ranch market", "all fresh", "farmers market", "transmart", "carrefour"], .food),
        // Transport — ride hailing, fuel, parking, public transit
        (["grab", "gojek", "gocar", "goride", "grabcar", "grabbike", "ojek", "taxi",
          "uber", "bluebird", "blue bird", "maxim", "indriver", "incar",
          "parkir", "parking", "secure parking", "toll", "tol",
          "bensin", "pertamina", "shell", "bp", "vivo", "spbu",
          "bus", "kereta", "commuter", "krl", "mrt", "lrt", "transjakarta",
          "kereta api", "kai", "whoosh", "argo"], .transport),
        // Shopping — e-commerce, malls, fashion, electronics
        (["tokopedia", "shopee", "lazada", "tiktok shop", "bukalapak", "blibli",
          "amazon", "ebay", "aliexpress",
          "zalora", "h&m", "zara", "uniqlo", "miniso", "matahari", "ramayana",
          "mall", "plaza", "grand indonesia", "central park", "kota kasablanka",
          "supermarket", "hypermart", "hero", "giant", "lottemart", "ranch market",
          "ace hardware", "informa", "ikea", "ruparupa",
          "erafone", "samsung", "iphone", "apple store", "ibox", "digimap",
          "best", "electronic city", "elektronik"], .shopping),
        // Bills — utilities, internet, streaming, insurance, taxes
        (["pln", "listrik", "electricity", "air", "water", "pdam", "gas",
          "telkom", "telkomsel", "indosat", "xl", "tri", "smartfren",
          "indihome", "first media", "biznet", "myrepublic", "internet", "wifi",
          "netflix", "spotify", "youtube", "youtube premium", "disney", "viu",
          "iqiyi", "we tv", "vidio", "hbo", "subscription", "langganan",
          "asuransi", "insurance", "prudential", "allianz", "manulife", "axa",
          "bpjs", "pajak", "tax", "pbb",
          "icloud", "google one", "dropbox"], .bills),
        // Health — pharmacies, hospitals, clinics, fitness
        (["apotik", "apotek", "pharmacy", "kimia farma", "guardian", "watson",
          "century", "k-24", "viva apotek",
          "rumah sakit", "rs ", "hospital", "siloam", "mitra keluarga", "pondok indah",
          "klinik", "clinic", "halodoc", "alodokter", "dokter", "doctor",
          "dental", "drg.", "gigi",
          "gym", "fitness", "celebrity fitness", "gold's gym", "anytime fitness",
          "sport", "olahraga"], .health),
        // Travel — hotels, flights, OTA platforms
        (["hotel", "airbnb", "oyo", "reddoorz", "airy",
          "traveloka", "tiket.com", "tiket com", "booking", "agoda", "trivago", "pegipegi",
          "pesawat", "flight", "garuda", "lion air", "citilink", "batik air",
          "airasia", "scoot", "singapore airlines", "qatar", "emirates",
          "pelni", "kapal", "ship", "ferry", "wisata", "tour", "travel"], .travel),
        // Investment — brokerages, crypto, savings products
        (["bibit", "bareksa", "ajaib", "stockbit", "ipot", "mirae",
          "idx", "saham", "reksa dana", "reksadana", "mutual fund",
          "crypto", "bitcoin", "ethereum", "binance", "indodax", "tokocrypto", "pintu",
          "deposito", "tabungan berjangka", "saving"], .investment),
    ]

    /// Suggest tx subtype from merchant name keywords. Used by
    /// AddTransactionSheet to pre-flag refunds/transfers without making the
    /// user remember to tap the toggle. Returns `.normal` for non-matching
    /// names so caller can use the result directly. Keywords are bilingual
    /// (English + Bahasa Indonesia) since users mix freely.
    static func suggestSubtype(for name: String) -> TxSubtype {
        let lower = name.lowercased()
        // Refund signals — merchant returning money for a prior purchase.
        let refundKeywords = ["refund", "reversal", "return funds", "returned",
                              "pengembalian", "kembali dana", "retur"]
        if refundKeywords.contains(where: lower.contains) { return .refund }
        // Transfer signals — moving money between user's own accounts.
        let transferKeywords = ["transfer", "tarik tunai", "withdrawal",
                                "atm", "topup", "top up", "top-up",
                                "isi saldo", "moved to"]
        if transferKeywords.contains(where: lower.contains) { return .transfer }
        return .normal
    }

    /// Suggest a category from merchant name. Default txType is "Expense" since
    /// receipt scans never produce income tx. Pass "Income" to skip suggestion.
    static func suggestCategory(for name: String, txType: String) -> TxCategory? {
        // Income txs go to .salary etc. — categorization isn't merchant-based.
        if txType == "Income" { return nil }
        let lower = name.lowercased()
        for entry in merchantMap {
            for keyword in entry.keywords {
                if lower.contains(keyword) { return entry.category }
            }
        }
        return nil
    }

    // MARK: - Spike-Ratio Reliability Filter

    /// Returns a percentage to use in spike-style insights ("Food up X%"),
    /// or nil if the comparison is too unreliable to surface meaningfully.
    ///
    /// Two pitfalls this guards against:
    ///
    /// 1. **Tiny baseline**: a Rp 5.000 last-month coffee compared with a
    ///    Rp 600.000 grocery this-month produces "12000% spike" — math-true
    ///    but actionably useless. We require the prior period to have at
    ///    least Rp 100k-equivalent spend before comparing. Below that the
    ///    user just hasn't established a normal yet.
    ///
    /// 2. **Extreme ratios**: anything above 500% probably reflects a
    ///    structural change (started a new habit, moved cities, big
    ///    one-time purchase) rather than a budget signal worth alerting on.
    ///    Capping the display at 500% would lie about the math; instead we
    ///    suppress the insight entirely so other (reliable) insights take
    ///    its slot in the multi-banner stack.
    ///
    /// - Parameters:
    ///   - this: current period spend (already converted to target currency)
    ///   - last: prior period spend (same currency)
    ///   - target: currency for the minimum-baseline conversion
    ///   - minimumPctIncrease: minimum percent change to surface (default 30%)
    /// - Returns: integer percent change, or nil to suppress the insight
    func reliableSpikePct(this: Double, last: Double, target: String,
                          minimumPctIncrease: Int = 30) -> Int? {
        let minBaseline = CurrencyManager.shared.convert(100_000, from: "IDR", to: target)
        guard last >= minBaseline, this > 0 else { return nil }
        let pctIncrease = ((this - last) / last) * 100
        let pctInt = Int(pctIncrease)
        // Reject implausibly large ratios — these are usually data-shape
        // artifacts (first month of usage, vacation big-bang, life event).
        guard pctInt <= 500 else { return nil }
        guard pctInt >= minimumPctIncrease else { return nil }
        return pctInt
    }

    // MARK: - Year-over-Year & Seasonal Detection

    /// Year-over-year comparison insight. Surfaces when:
    ///   - User has ≥12 months of expense data (otherwise confidence is too low)
    ///   - Current month's spend differs meaningfully from same-month-last-year
    ///
    /// This is the most valuable insight for long-time users since it
    /// captures life-stage changes ("you spent Rp 5jt less this Mei vs Mei
    /// 2025"). Rolling 3-month baselines miss this entirely because they
    /// don't span seasons.
    func yearOverYearInsight(allTransactions: [TxRecord],
                             targetCurrency: String? = nil) -> SmartInsight? {
        guard hasActiveBudget else { return nil }
        let target = targetCurrency ?? CurrencyManager.shared.preferredCurrency

        // Need 12+ months of distinct data; without it the comparison is
        // meaningless (might just be a new account starting up).
        guard dataMonthsAvailable(allTransactions: allTransactions) >= 12 else { return nil }

        let cal = Calendar.current
        let now = Date()
        let monthStart  = cal.safeDate(from: cal.dateComponents([.year, .month], from: now))
        let nextMonth   = cal.safeDate(byAdding: .month, value: 1, to: monthStart)
        // Same calendar month, one year ago.
        let lastYearStart = cal.safeDate(byAdding: .year, value: -1, to: monthStart)
        let lastYearEnd   = cal.safeDate(byAdding: .month, value: 1, to: lastYearStart)

        let sumExpense: ([TxRecord]) -> Double = { txs in
            txs.filter { $0.txSubtype != .transfer }
                .reduce(0.0) { sum, tx in
                    let amt = CurrencyManager.shared.convert(abs(tx.amount), from: tx.currency, to: target)
                    if tx.txSubtype == .refund { return sum - amt }
                    return tx.amount < 0 ? sum + amt : sum
                }
        }

        let thisMonthSpend = sumExpense(
            allTransactions.filter { $0.date >= monthStart && $0.date < nextMonth }
        )
        let lastYearSpend = sumExpense(
            allTransactions.filter { $0.date >= lastYearStart && $0.date < lastYearEnd }
        )

        // Both sides need to have MEANINGFUL data to be comparable. A user
        // who barely tracked last year (Rp 50k total in May 2025) but
        // tracks fully this year would generate "May: 5000% higher" — math
        // is fine but the insight is noise. Use a Rp 500k-equivalent floor
        // (5x the cat_up baseline) since YoY compares whole-month totals
        // not single-category — they should be much larger.
        let yoyMinBaseline = CurrencyManager.shared.convert(500_000, from: "IDR", to: target)
        guard lastYearSpend >= yoyMinBaseline, thisMonthSpend >= yoyMinBaseline else { return nil }

        let delta = thisMonthSpend - lastYearSpend
        let pct = Int((delta / lastYearSpend) * 100)
        let absPct = abs(pct)
        // Don't make noise about <10% changes — those are within normal
        // month-to-month variance even when comparing same months.
        // Also cap at 500% on the upside; like cat_up, beyond that the
        // signal is more likely a structural life change than an
        // actionable budgeting trend.
        guard absPct >= 10, absPct <= 500 else { return nil }

        let savedFmt = CurrencyManager.shared.formatted(abs(delta), currency: target)
        let monthName: String = {
            let f = DateFormatter()
            f.locale = LanguageManager.shared.currentLocale
            f.dateFormat = "MMMM"
            return f.string(from: now)
        }()

        if pct < 0 {
            // Saved compared to last year — celebration insight.
            return SmartInsight(
                icon: "chart.line.downtrend.xyaxis",
                color: AppTheme.accent,
                title: String(format: loc("insight.yoy_saving_title"), monthName),
                body: String(format: loc("insight.yoy_saving_body"), absPct, savedFmt)
            )
        } else {
            // Spent more — but we don't immediately alarm; just inform.
            // The category-level overspend insight already alarms when
            // appropriate. This is a higher-altitude trend signal.
            return SmartInsight(
                icon: "chart.line.uptrend.xyaxis",
                color: AppTheme.orange,
                title: String(format: loc("insight.yoy_higher_title"), monthName),
                body: String(format: loc("insight.yoy_higher_body"), absPct, savedFmt)
            )
        }
    }

    /// Whether this month historically shows a spending spike for THIS user.
    /// Compares current month to same-month-last-year — if last year was
    /// already high, the current spike is "expected seasonal" and we
    /// shouldn't trigger the anomaly alarm. Personal pattern, no hard-coded
    /// Lebaran/Christmas calendar (which would mismatch user life-stage).
    ///
    /// Returns false when we don't have ≥1 year of data (can't compare).
    func isLikelySeasonal(category: TxCategory,
                          allTransactions: [TxRecord]) -> Bool {
        let cal = Calendar.current
        let now = Date()
        let monthStart   = cal.safeDate(from: cal.dateComponents([.year, .month], from: now))
        let lastYearStart = cal.safeDate(byAdding: .year, value: -1, to: monthStart)
        let lastYearEnd   = cal.safeDate(byAdding: .month, value: 1, to: lastYearStart)

        // Reference average: 3 months around the same period last year
        // (one before, the month, one after). This smooths exact-day timing
        // shifts (Lebaran moves ~11 days/year on Gregorian).
        let refStart = cal.safeDate(byAdding: .month, value: -1, to: lastYearStart)
        let refEnd   = cal.safeDate(byAdding: .month, value: 1, to: lastYearEnd)
        let refTxs = allTransactions.filter {
            $0.date >= refStart && $0.date < refEnd
            && $0.category == category && $0.txSubtype != .transfer
        }
        let monthsCovered = 3.0
        let refAvg = refTxs.reduce(0.0) { sum, tx in
            let amt = CurrencyManager.shared.toPreferred(abs(tx.amount), from: tx.currency)
            if tx.txSubtype == .refund { return sum - amt }
            return tx.amount < 0 ? sum + amt : sum
        } / monthsCovered

        // If the historical average for the same category around this time
        // last year was already substantial (say >Rp 200k equivalent), the
        // category is "naturally high" this month for this user.
        let threshold = CurrencyManager.shared.toPreferred(200_000, from: "IDR")
        return refAvg > threshold
    }

    // MARK: - Confidence Scoring

    /// How many distinct months of expense data the user has. Used as the
    /// primary signal for insight confidence — engines need 2-3 months to
    /// give meaningful comparisons (anomaly detection, spike, monthly
    /// trends).
    func dataMonthsAvailable(allTransactions: [TxRecord]) -> Int {
        let cal = Calendar.current
        let monthsWithData = Set(
            allTransactions
                .filter { $0.amount < 0 }
                .map { cal.dateComponents([.year, .month], from: $0.date) }
                .compactMap { c -> String? in
                    guard let y = c.year, let m = c.month else { return nil }
                    return "\(y)-\(m)"
                }
        )
        return monthsWithData.count
    }

    /// Convenience: derive an InsightConfidence level from data age.
    /// Caller can override if it has additional signals (variance, etc.).
    func defaultConfidence(allTransactions: [TxRecord]) -> InsightConfidence {
        let months = dataMonthsAvailable(allTransactions: allTransactions)
        if months >= 3 { return .high }
        if months >= 1 { return .medium }
        return .low
    }

    // MARK: - Coaching / First-Time Education

    /// Returns the appropriate coaching topic key for an insight, if it's
    /// the user's first time seeing this category. Returns nil for repeat
    /// views — UI should hide the education panel after first time.
    ///
    /// "Category" here means the conceptual kind of insight (savings rate,
    /// budget overspend, goal-linked, etc.), not the SwiftData TxCategory.
    /// Maps from insight content via title prefix matching — keeps the
    /// engine free of tight coupling to specific insight identifiers.
    func coachingTopic(for insight: SmartInsight) -> String? {
        let topic = topicID(for: insight)
        guard !topic.isEmpty else { return nil }
        let seen = Set(UserDefaults.standard.stringArray(forKey: "sb_seen_coaching") ?? [])
        return seen.contains(topic) ? nil : topic
    }

    /// Mark a coaching topic as seen so it doesn't show again. Called from UI
    /// after the user dismisses the education panel.
    func markCoachingSeen(_ topic: String) {
        var seen = Set(UserDefaults.standard.stringArray(forKey: "sb_seen_coaching") ?? [])
        seen.insert(topic)
        UserDefaults.standard.set(Array(seen), forKey: "sb_seen_coaching")
    }

    private func topicID(for insight: SmartInsight) -> String {
        // Match by title-loc-key heuristic. Each topic maps to a coaching
        // body string in LanguageManager.
        let title = insight.title.lowercased()
        if title.contains("savings rate") || title.contains("tabungan") {
            return "savings_rate"
        }
        if title.contains("over budget") || title.contains("melebihi") {
            return "overspend"
        }
        if title.contains("within reach") || title.contains("tinggal sedikit") {
            return "goal_tradeoff"
        }
        if title.contains("debt") || title.contains("hutang") {
            return "debt_focus"
        }
        if title.contains("risky") || title.contains("berisiko") {
            return "ratio_risk"
        }
        return ""
    }

    // MARK: - Insight Dismissal & Frequency Cap

    /// Stable hash for an insight type — used as the dismissal key. Keyed on
    /// SF Symbol icon name (which is language-independent) + color rawValue
    /// + month, NOT on the displayed title. The previous title-based hash
    /// was language-sensitive: a user who dismissed "Lifestyle over budget"
    /// in English would still see "Gaya hidup melebihi anggaran" appear
    /// after switching to ID, because the hashed key differed. Icon + color
    /// stays constant across translations and uniquely identifies each
    /// insight family in practice (with minor collisions that are
    /// acceptable — sharing dismissal between visually-identical insight
    /// types matches user intent of "stop showing this kind of alert").
    private func dismissalKey(for insight: SmartInsight) -> String {
        let cal = Calendar.current
        let now = Date()
        let ymKey = String(format: "%04d-%02d",
                           cal.component(.year, from: now),
                           cal.component(.month, from: now))
        // Color is a SwiftUI Color which doesn't have a stable rawValue, so
        // we extract a coarse signature via its description (e.g.
        // "DynamicColor(...)"). Good enough — the icon is the dominant
        // discriminator and shared icons across insights are intentional.
        let colorTag = String(describing: insight.color).hashValue
        return "insight_\(ymKey)_\(insight.icon)_\(colorTag)"
    }

    /// User-dismissed an insight banner. Persists the dismissal so the same
    /// insight type doesn't reappear this month. Survives across app launches
    /// via UserDefaults.
    func dismissInsight(_ insight: SmartInsight) {
        let key = dismissalKey(for: insight)
        var set = Set(UserDefaults.standard.stringArray(forKey: "sb_dismissed_insights") ?? [])
        set.insert(key)
        UserDefaults.standard.set(Array(set), forKey: "sb_dismissed_insights")
    }

    /// Filters insights against the dismissed set. Called from `evaluateAll`.
    private func notDismissed(_ insight: SmartInsight) -> Bool {
        let key = dismissalKey(for: insight)
        let set = Set(UserDefaults.standard.stringArray(forKey: "sb_dismissed_insights") ?? [])
        return !set.contains(key)
    }

    /// Clear dismissals when month rolls over so insights reappear in the
    /// new month. Called opportunistically from any insight access — cheap
    /// O(N) on a small UserDefaults set.
    private func sweepStaleDismissals() {
        let cal = Calendar.current
        let now = Date()
        let currentYM = String(format: "%04d-%02d",
                               cal.component(.year, from: now),
                               cal.component(.month, from: now))
        let raw = UserDefaults.standard.stringArray(forKey: "sb_dismissed_insights") ?? []
        let kept = raw.filter { $0.contains("_\(currentYM)_") }
        if kept.count != raw.count {
            UserDefaults.standard.set(kept, forKey: "sb_dismissed_insights")
        }
    }

    // MARK: - Spending Anomaly Detection

    /// Detects if any category is spending unusually high vs personal 3-month average
    func spendingAnomalies(allTransactions: [TxRecord]) -> [SmartInsight] {
        // Royal-only — match the gating pattern of every other public
        // engine method so callers can't leak premium output by forgetting
        // a wrapping `if hasActiveBudget`.
        guard hasActiveBudget else { return [] }
        let cal = Calendar.current
        let now = Date()
        let monthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: now))

        // Build 3-month baseline per category
        var insights: [SmartInsight] = []

        for cat in TxCategory.allCases {
            // This month's spend — skip transfers (not real spend) and
            // subtract refunds (they reversed an expense). Same model as
            // `spent(in:)` so anomaly math agrees with budget math.
            let thisMonth = allTransactions
                .filter { $0.date >= monthStart && $0.category == cat && $0.txSubtype != .transfer }
                .reduce(0.0) { sum, tx in
                    let amt = CurrencyManager.shared.toPreferred(abs(tx.amount), from: tx.currency)
                    if tx.txSubtype == .refund { return sum - amt }
                    return tx.amount < 0 ? sum + amt : sum
                }
            guard thisMonth > 0 else { continue }

            // Average of previous 3 months — same skip/refund treatment.
            var monthlyAmounts: [Double] = []
            for offset in 1...3 {
                let mStart = cal.safeDate(byAdding: .month, value: -offset, to: monthStart)
                let mEnd   = cal.safeDate(byAdding: .month, value: 1, to: mStart)
                let amt = allTransactions
                    .filter { $0.date >= mStart && $0.date < mEnd && $0.category == cat && $0.txSubtype != .transfer }
                    .reduce(0.0) { sum, tx in
                        let v = CurrencyManager.shared.toPreferred(abs(tx.amount), from: tx.currency)
                        if tx.txSubtype == .refund { return sum - v }
                        return tx.amount < 0 ? sum + v : sum
                    }
                if amt > 0 { monthlyAmounts.append(amt) }
            }
            guard monthlyAmounts.count >= 2 else { continue }
            let avg = monthlyAmounts.reduce(0, +) / Double(monthlyAmounts.count)
            guard avg > 0 else { continue }

            // Reliability filter via reliableSpikePct: rejects tiny baselines
            // (avg <Rp 100k-equiv) AND extreme ratios (>500%). Also bumps the
            // floor to 50% as before — anomaly should be more dramatic than
            // the cat_up insight.
            let target = CurrencyManager.shared.preferredCurrency
            guard let pct = reliableSpikePct(this: thisMonth, last: avg,
                                              target: target,
                                              minimumPctIncrease: 50) else {
                continue
            }
            // Suppress alarm if this is a known seasonal pattern for the
            // user (last year same-month-area was also high). Avoids
            // false alarms during Lebaran/akhir tahun for users whose
            // history shows the same shape every year.
            if isLikelySeasonal(category: cat, allTransactions: allTransactions) {
                continue
            }
            insights.append(SmartInsight(
                icon: cat.icon,
                color: AppTheme.red,
                title: String(format: loc("insight.spike_title"), cat.displayLabel),
                body: String(format: loc("insight.spike_body"), pct, cat.displayLabel.lowercased())
            ))
        }
        return insights
    }

    // MARK: - Recurring Transaction Detection

    struct RecurringPattern: Identifiable {
        let id = UUID()
        let name: String
        let amount: Double
        let currency: String
        let category: TxCategory
        let intervalDays: Int // ~30 = monthly, ~7 = weekly
        let lastDate: Date
        var nextExpected: Date {
            Calendar.current.safeDate(byAdding: .day, value: intervalDays, to: lastDate)
        }
        var isDueSoon: Bool {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: nextExpected).day ?? 99
            return days <= 7
        }
    }

    /// Finds transactions that recur on a regular interval (weekly/monthly)
    func detectRecurring(allTransactions: [TxRecord]) -> [RecurringPattern] {
        // Royal-only gate — same rationale as spendingAnomalies.
        guard hasActiveBudget else { return [] }
        // Group expenses by normalized name. Skip transfers (they're not
        // real spend; they're inter-account moves the user does on a
        // schedule and we don't want flagged as "subscription").
        let expenses = allTransactions.filter { $0.amount < 0 && $0.txSubtype != .transfer }
        var grouped: [String: [TxRecord]] = [:]
        for tx in expenses {
            let key = tx.name.lowercased().trimmingCharacters(in: .whitespaces)
            grouped[key, default: []].append(tx)
        }

        var patterns: [RecurringPattern] = []
        for (_, txs) in grouped {
            guard txs.count >= 2 else { continue }
            let sorted = txs.sorted { $0.date < $1.date }

            // Calculate gaps between occurrences
            var gaps: [Int] = []
            for i in 1..<sorted.count {
                let days = Calendar.current.dateComponents([.day], from: sorted[i-1].date, to: sorted[i].date).day ?? 0
                if days > 0 { gaps.append(days) }
            }
            guard !gaps.isEmpty else { continue }

            let avgGap = gaps.reduce(0, +) / gaps.count
            // Check consistency: all gaps within 5 days of average
            let consistent = gaps.allSatisfy { abs($0 - avgGap) <= 5 }
            guard consistent else { continue }

            // Only flag weekly (~7 days) or monthly (~28-31 days)
            let intervalDays: Int
            if (6...8).contains(avgGap) { intervalDays = 7 }
            else if (25...35).contains(avgGap) { intervalDays = 30 }
            else { continue }

            // Use most common amount
            let amounts = txs.map { abs($0.amount) }
            let avgAmt = amounts.reduce(0, +) / Double(amounts.count)

            // ✅ guard replaces four sorted.last! force-unwraps
            guard let latest = sorted.last else { continue }
            patterns.append(RecurringPattern(
                name: latest.name,
                amount: avgAmt,
                currency: latest.currency,
                category: latest.category,
                intervalDays: intervalDays,
                lastDate: latest.date
            ))
        }

        // Sort: due soon first, then by amount
        return patterns
            .sorted { ($0.isDueSoon ? 0 : 1, $1.amount) < ($1.isDueSoon ? 0 : 1, $0.amount) }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Persistence

    private static let storageKeys = [
        "sb_enabled", "sb_daily", "sb_lifestyle", "sb_invest", "sb_card_id",
        // Dismissed-insight keys are user-specific; clear on reset/logout so
        // the next user starts fresh and old dismissals don't suppress new
        // user's insights.
        "sb_dismissed_insights",
    ]

    private func save() {
        UserDefaults.standard.set(isEnabled, forKey: "sb_enabled")
        UserDefaults.standard.set(dailyRatio, forKey: "sb_daily")
        UserDefaults.standard.set(lifestyleRatio, forKey: "sb_lifestyle")
        UserDefaults.standard.set(investDebtRatio, forKey: "sb_invest")
        UserDefaults.standard.set(budgetCardID, forKey: "sb_card_id")
    }

    private func load() {
        if UserDefaults.standard.object(forKey: "sb_enabled") != nil {
            isEnabled       = UserDefaults.standard.bool(forKey: "sb_enabled")
            dailyRatio      = UserDefaults.standard.double(forKey: "sb_daily")
            lifestyleRatio  = UserDefaults.standard.double(forKey: "sb_lifestyle")
            investDebtRatio = UserDefaults.standard.double(forKey: "sb_invest")
            budgetCardID    = UserDefaults.standard.string(forKey: "sb_card_id")
        }
    }

    /// Called by `PremiumManager.onLogout`. Turns the master toggle off so a
    /// subsequent user signing in on this device doesn't inherit the previous
    /// user's Smart Budget configuration. The ratios themselves are NOT
    /// cleared — if the same user signs back in they only need to flip the
    /// toggle back on, not re-enter their 50/30/20 split.
    func onLogoutCleanup() {
        // Setting `isEnabled = false` triggers didSet → save(), so the
        // off-state persists across launches.
        isEnabled = false
    }

    /// Apply one of the built-in profile presets to the global ratios. Does
    /// NOT toggle `isEnabled` — caller decides if this is part of an "enable
    /// + apply" or just "switch preset on already-enabled budget" flow.
    /// Triggers a single save() at the end via didSet on the last property.
    func applyPreset(_ preset: BudgetProfile) {
        let r = preset.ratios
        dailyRatio      = r.daily
        lifestyleRatio  = r.lifestyle
        investDebtRatio = r.investDebt
    }

    /// Called by ProfileView's "Reset All Data" flow. Wipes every persisted
    /// setting back to defaults so the next session starts truly clean.
    func resetAllSettings() {
        isEnabled = false
        dailyRatio = 0.50
        lifestyleRatio = 0.30
        investDebtRatio = 0.20
        budgetCardID = nil
        // Clear the UserDefaults keys outright in case any stale value was
        // written by an older version of the app.
        for key in Self.storageKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

// MARK: - Budget Profile Presets

/// Pre-configured budget allocations matched to common Indonesian lifestyle
/// profiles. The default 50/30/20 (Senator Warren's rule) only fits one demo;
/// presets recognise that a mahasiswa kost-an, freelancer with variable
/// income, and a couple paying KPR have very different cash-flow shapes.
///
/// User picks a preset in the wizard during onboarding (or can switch later).
/// Each preset carries its own daily/lifestyle/investDebt ratios plus a short
/// human-readable rationale that's displayed when the user previews it.
enum BudgetProfile: String, CaseIterable, Identifiable {
    case studentSaver      // tinggal sama ortu / kost murah, hemat
    case salaryStarter     // karyawan baru, gaji stabil mid-tier
    case familyWithKids    // pengeluaran anak besar
    case mortgagePayer     // KPR aktif → debt heavy
    case freelancer        // income tidak menentu → emergency-first
    case custom            // user-defined fallback (no wizard touch)

    var id: String { rawValue }

    /// Daily / Lifestyle / InvestDebt allocation. Sum to 1.0.
    var ratios: (daily: Double, lifestyle: Double, investDebt: Double) {
        switch self {
        case .studentSaver:    return (0.50, 0.20, 0.30)  // hemat → invest banyak
        case .salaryStarter:   return (0.50, 0.30, 0.20)  // klasik 50/30/20
        case .familyWithKids:  return (0.60, 0.20, 0.20)  // kebutuhan anak besar
        case .mortgagePayer:   return (0.50, 0.20, 0.30)  // 30% buat cicilan KPR
        case .freelancer:      return (0.40, 0.20, 0.40)  // emergency fund tinggi
        case .custom:          return (0.50, 0.30, 0.20)  // klasik default
        }
    }

    var displayName: String {
        switch self {
        case .studentSaver:    return loc("budget.profile.student.name")
        case .salaryStarter:   return loc("budget.profile.starter.name")
        case .familyWithKids:  return loc("budget.profile.family.name")
        case .mortgagePayer:   return loc("budget.profile.mortgage.name")
        case .freelancer:      return loc("budget.profile.freelance.name")
        case .custom:          return loc("budget.profile.custom.name")
        }
    }

    /// One-sentence pitch shown in the preset gallery card.
    var tagline: String {
        switch self {
        case .studentSaver:    return loc("budget.profile.student.tagline")
        case .salaryStarter:   return loc("budget.profile.starter.tagline")
        case .familyWithKids:  return loc("budget.profile.family.tagline")
        case .mortgagePayer:   return loc("budget.profile.mortgage.tagline")
        case .freelancer:      return loc("budget.profile.freelance.tagline")
        case .custom:          return loc("budget.profile.custom.tagline")
        }
    }

    /// SF Symbol shown on the preset card.
    var icon: String {
        switch self {
        case .studentSaver:    return "graduationcap.fill"
        case .salaryStarter:   return "briefcase.fill"
        case .familyWithKids:  return "figure.2.and.child.holdinghands"
        case .mortgagePayer:   return "house.fill"
        case .freelancer:      return "laptopcomputer"
        case .custom:          return "slider.horizontal.3"
        }
    }

    /// Theme color for the preset card accent.
    var color: Color {
        switch self {
        case .studentSaver:    return AppTheme.blue
        case .salaryStarter:   return AppTheme.accent
        case .familyWithKids:  return AppTheme.orange
        case .mortgagePayer:   return AppTheme.purple
        case .freelancer:      return Color(hex: "#EF4444")
        case .custom:          return AppTheme.textSecondary
        }
    }
}

// MARK: - Supporting Types

enum BudgetGroup: String, CaseIterable {
    case daily      = "daily"
    case lifestyle  = "lifestyle"
    case investDebt = "investDebt"

    var label: String {
        switch self {
        case .daily:      return loc("budget.group.daily")
        case .lifestyle:  return loc("budget.group.lifestyle")
        case .investDebt: return loc("budget.group.invest_debt")
        }
    }

    var icon: String {
        switch self {
        case .daily:      return "fork.knife"
        case .lifestyle:  return "sparkles"
        case .investDebt: return "chart.line.uptrend.xyaxis"
        }
    }

    var color: Color {
        switch self {
        case .daily:      return AppTheme.blue
        case .lifestyle:  return AppTheme.purple
        case .investDebt: return AppTheme.accent
        }
    }
}

struct BudgetAlert {
    let group: BudgetGroup
    let limit: Double
    let spent: Double
    let newTotal: Double
    let over: Double
    var isWarning: Bool = false
    /// Specific label e.g. "Debt payment" or "Investment" instead of generic group label
    var categoryLabel: String = ""

    var isExceeded: Bool { over > 0 }

    /// Display label — use specific category label if set, otherwise group label
    var displayLabel: String { categoryLabel.isEmpty ? group.label : categoryLabel }
}

/// Action attached to an insight — drives an optional CTA button below the
/// insight body. Adding `action` upgrades a descriptive insight ("you spent
/// 25% over budget") into a prescriptive one ("you spent 25% over budget
/// → [Adjust Budget]"). Each kind maps to a known navigation target so the
/// caller (HomeView SmartInsightBanner) can route appropriately without
/// hardcoding routes inside the engine.
struct SmartInsightAction {
    /// Localized button label, e.g. "Adjust Budget" or "View Goal".
    let label: String
    /// Where tapping leads. The receiving view is responsible for opening
    /// the right sheet — engine stays UI-agnostic.
    let kind: Kind

    enum Kind {
        /// Open the Smart Budget settings sheet (overspend → tweak ratio).
        case openBudgetSettings
        /// Open Wishlist / Savings Goals (goal-linked insight).
        case openSavingsGoals
        /// Open the Debt management screen.
        case openDebt
        /// Pure acknowledgement — no nav, just dismiss the banner.
        /// Useful for celebration insights ("Great job!") where a route
        /// would feel pushy.
        case acknowledge
    }
}

/// How much trust to put in this insight. New users with <1 month of data
/// get rough heuristics flagged as `.low`; established users with 3+ months
/// of clean data get `.high`. UI shows a discreet badge on low-confidence
/// items so the user knows the recommendation is preliminary.
enum InsightConfidence {
    case high     // 3+ months data, low variance, stable income
    case medium   // 1-2 months data
    case low      // <1 month or extreme variance
}

struct SmartInsight: Identifiable {
    let id = UUID()
    let icon: String
    let color: Color
    let title: String
    let body: String
    /// Optional CTA. nil = no button rendered. Most insights set this so
    /// the user has a clear next step instead of just reading text.
    var action: SmartInsightAction? = nil
    /// Confidence the engine has in this insight. Defaults to `.high` for
    /// existing call sites; new sites should pass an explicit value when
    /// they have variance / data-age signal.
    var confidence: InsightConfidence = .high
}
