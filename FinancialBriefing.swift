import SwiftUI
import SwiftData

// MARK: - Financial Briefing
//
// The "advisor brain": reads EVERYTHING the app knows — transactions, debts,
// credit cards, goals, declared recurring commitments, salary — and writes a
// structured briefing the way a human advisor would: what's happening, WHY it
// matters, what to do about it, and what the next months look like.
//
// Design rules that keep this honest:
//   • Every finding cites the user's own numbers. No generic filler.
//   • A rule that has no supporting data produces NOTHING (no padded lists).
//   • Findings are ordered by severity; positives are included so the picture
//     is balanced, never just doom.
//   • All amounts are converted to the user's preferred currency first.
//   • ONE methodology everywhere: every cash-flow row is money that actually
//     moved in the analysis window, and the headline quotes the same "left
//     over" the table ends on. (v1 mixed planned amounts with actuals and
//     quoted two different deficits on one screen — never again.)

enum BriefingSeverity: Int {
    case critical = 0, warning, insight, positive

    var color: Color {
        switch self {
        case .critical: return AppTheme.red
        case .warning:  return AppTheme.orange
        case .insight:  return AppTheme.blue
        case .positive: return AppTheme.accent
        }
    }
    var icon: String {
        switch self {
        case .critical: return "exclamationmark.octagon.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .insight:  return "lightbulb.fill"
        case .positive: return "checkmark.seal.fill"
        }
    }
}

struct BriefingFinding: Identifiable {
    let id = UUID()
    let severity: BriefingSeverity
    let title: String
    /// The full explanation: the number, the WHY, and what to watch.
    let body: String
    /// Optional concrete next step.
    var action: String? = nil
}

struct CashflowRow: Identifiable {
    let id = UUID()
    let label: String
    let amount: Double
    /// negative rows render red, positive green, neutral gray
    let tone: Int   // -1 outflow, 0 neutral, +1 inflow/left
    /// Small explanatory line under the label ("Plan Rp 3.1M + Rp 1.4M outside plan").
    var caption: String? = nil
    /// Sub-row (category breakdown) — rendered smaller and indented.
    var indent: Bool = false
}

/// One bucket of the recommended salary split (daily / lifestyle / invest-debt).
struct AllocationRec: Identifiable {
    let id = UUID()
    let label: String
    let pct: Int          // recommended share of income
    let amount: Double    // pct × income, preferred currency
    let currentPct: Int   // what the user actually did this window
    let detail: String    // what belongs in this bucket, with the user's numbers
    let color: Color
}

struct FinancialBriefing {
    var headline: String
    /// Explicit analysis window ("Pay cycle 25 Jun – 24 Jul · complete").
    var periodLabel: String
    var cashflow: [CashflowRow]
    var findings: [BriefingFinding]
    /// Recommended daily/lifestyle/invest-debt split, empty when too little data.
    var allocation: [AllocationRec]
    var allocationNote: String?
    var outlook: [String]
}

// MARK: - Engine

enum FinancialBriefingEngine {

    // swiftlint:disable:next function_body_length
    static func build(cards: [BankCard],
                      debts: [DebtRecord],
                      goals: [SavingsGoal],
                      recurrings: [RecurringExpense],
                      salaries: [SalarySchedule],
                      intents: [CycleIntent] = []) -> FinancialBriefing {
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        let cal = Calendar.current
        let now = Date()
        func fmt(_ v: Double) -> String { cm.formatted(v, currency: pref) }
        func toPref(_ amount: Double, _ cur: String) -> Double {
            cm.convert(amount, from: cur.isEmpty ? pref : cur, to: pref)
        }

        // ── Base figures ────────────────────────────────────────────────
        let activeSalaries = salaries.filter { $0.isActive }
        let income = activeSalaries.reduce(0.0) { $0 + toPref($1.amount, $1.currency) }

        // Cycle window = actual-pay-date anchored, same as everywhere else.
        let cycleStart: Date = {
            if let day = activeSalaries.first?.dayOfMonth {
                return StatPeriod.payCycleRange(payDay: day).start
            }
            return cal.safeDate(from: cal.dateComponents([.year, .month], from: now))
        }()
        // Judge the last COMPLETE cycle while the current one is <7 days old —
        // same rationale as the Smart Score.
        let elapsed = cal.dateComponents([.day], from: cycleStart, to: now).day ?? 0
        var windowStart = cycleStart
        var windowEnd = now
        var isCompleteCycle = false
        if elapsed < 7, let day = activeSalaries.first?.dayOfMonth,
           let dayBefore = cal.date(byAdding: .day, value: -1, to: cycleStart) {
            windowStart = StatPeriod.payCycleRange(payDay: day, now: dayBefore).start
            windowEnd = cycleStart
            isCompleteCycle = true
        }

        // Explicit period label so the user always knows WHAT month of their
        // life these numbers describe — pay-cycle aligned, not calendar-month.
        let periodLabel: String = {
            let f = DateFormatter()
            f.locale = LanguageManager.shared.currentLocale
            f.dateFormat = "d MMM"
            if activeSalaries.first?.dayOfMonth != nil {
                if isCompleteCycle {
                    let lastDay = cal.date(byAdding: .day, value: -1, to: windowEnd) ?? windowEnd
                    return String(format: loc("brief.period_complete"),
                                  f.string(from: windowStart), f.string(from: lastDay))
                }
                return String(format: loc("brief.period_progress"),
                              f.string(from: windowStart), elapsed + 1)
            }
            return loc("brief.period_calmonth")
        }()

        // Deliberate choices the user declared for THIS window. Without them
        // this screen kept calling a planned overspend a leak while the
        // recommendation screen — same cycle, same data — already agreed it was
        // intentional.
        let declared = CycleIntentSet.resolve(
            intents, cycleKey: ISO8601DateFormatter.dayString(from: windowStart))

        let allTx = cards.flatMap { $0.transactions }
        let windowExpense = allTx.filter {
            $0.date >= windowStart && $0.date < windowEnd
            && $0.amount < 0 && $0.txSubtype == .normal
        }
        func spent(_ cats: [TxCategory]) -> Double {
            windowExpense.filter { cats.contains($0.category) }
                .reduce(0.0) { $0 + toPref(abs($1.amount), $1.currency) }
        }

        // ONE methodology: every figure below is money that ACTUALLY moved in
        // the window. Plans (recurring, debt minimums) appear only as captions
        // and findings, never as table rows — mixing the two is what made v1
        // quote two different deficits on one screen.
        let fixedSpent    = spent(SmartBudgetManager.fixedCategories)       // kos, bills, transfers
        let essentialVar  = spent([.food, .transport, .health])
        let lifestyleVar  = spent(SmartBudgetManager.lifestyleCategories)   // shopping, travel, other
        let variableSpent = essentialVar + lifestyleVar
        let debtPaid      = spent([.debtPayment])
        let investActual  = spent([.investment])
        let consumption   = fixedSpent + variableSpent
        let leftAfterAll  = income - consumption - debtPaid - investActual
        let isDeficit     = income > 0 && leftAfterAll < 0

        // Commitments from other features (plans — used for captions/findings).
        let activeRecurring = recurrings.filter { $0.isActive }
        let recurringMonthly = activeRecurring.reduce(0.0) { $0 + toPref($1.amount, $1.currency) }
        let activeDebts = debts.filter { $0.isActive && $0.currentBalance > 0 }
        // Credit-card balances carry a real monthly minimum too (~10% is the
        // Indonesian norm). Leaving them out made this screen recommend a
        // smaller Invest & debt share than the recommendation screen did for
        // the very same cycle. `effectiveMinimumPayment` also covers 0%
        // installments where the user never typed a minimum.
        let creditCardsOwedForMin = cards.filter { $0.isCreditCard }
            .reduce(0.0) { $0 + toPref($1.owedBalance(), $1.resolvedCurrency) }
        let debtMin = activeDebts.reduce(0.0) { $0 + toPref($1.effectiveMinimumPayment, $1.currency) }
                    + creditCardsOwedForMin * 0.10
        let totalDebt = activeDebts.reduce(0.0) { $0 + toPref($1.currentBalance, $1.currency) }
        let creditCards = cards.filter { $0.isCreditCard }
        let ccOwed = creditCards.reduce(0.0) { $0 + toPref($1.owedBalance(), $1.resolvedCurrency) }
        let goalPace = goals.filter { !$0.isCompleted }
            .reduce(0.0) { $0 + toPref($1.monthlyContribution, $1.currency) }

        let committed = recurringMonthly + debtMin
        let leftAfterCommitted = income - committed
        let savingsRate = income > 0 ? max(0, leftAfterAll / income) : 0

        // ── Headline ── quotes the SAME left-over number the table ends on.
        let headline: String
        if income <= 0 {
            headline = loc("brief.headline.no_income")
        } else if isDeficit {
            headline = String(format: loc(declared.excusesDeficit ? "brief.headline.deficit_planned"
                                                                 : "brief.headline.deficit"),
                              fmt(-leftAfterAll))
        } else if savingsRate >= 0.20 {
            headline = String(format: loc("brief.headline.strong"), Int(savingsRate * 100))
        } else if savingsRate > 0.05 {
            headline = String(format: loc("brief.headline.tight"), Int(savingsRate * 100))
        } else {
            headline = loc("brief.headline.breakeven")
        }

        // ── Cash-flow anatomy ── actuals only, sub-rows explain "variable".
        var flow: [CashflowRow] = []
        if income > 0 {
            flow.append(CashflowRow(label: loc("brief.flow.income"), amount: income, tone: 1))

            if fixedSpent > 0 {
                // Caption reconciles actual vs the recurring PLAN so a gap
                // (double-logged transfer, unregistered subscription) is
                // visible instead of silently inflating "living costs".
                var caption: String? = nil
                if recurringMonthly > 0 {
                    let overPlan = fixedSpent - recurringMonthly
                    caption = overPlan > 1_000
                        ? String(format: loc("brief.flow.fixed_over"), fmt(recurringMonthly), fmt(overPlan))
                        : String(format: loc("brief.flow.fixed_plan"), fmt(recurringMonthly))
                }
                flow.append(CashflowRow(label: loc("brief.flow.fixed"), amount: -fixedSpent,
                                        tone: -1, caption: caption))
            }

            if debtPaid > 0 {
                let caption = debtMin > 0
                    ? String(format: loc("brief.flow.debt_caption"), fmt(debtMin)) : nil
                flow.append(CashflowRow(label: loc("brief.flow.debt"), amount: -debtPaid,
                                        tone: -1, caption: caption))
            }

            if variableSpent > 0 {
                flow.append(CashflowRow(label: loc("brief.flow.variable"), amount: -variableSpent, tone: -1))
                // Category sub-rows: where the variable money actually went.
                var byCat: [TxCategory: (n: Int, total: Double)] = [:]
                let variableCats: [TxCategory] = [.food, .transport, .health, .shopping, .travel, .other]
                for tx in windowExpense where variableCats.contains(tx.category) {
                    let cur = byCat[tx.category] ?? (0, 0)
                    byCat[tx.category] = (cur.n + 1, cur.total + toPref(abs(tx.amount), tx.currency))
                }
                for (cat, v) in byCat.sorted(by: { $0.value.total > $1.value.total }) where v.total > 0 {
                    flow.append(CashflowRow(
                        label: String(format: loc("brief.flow.cat_count"), cat.displayLabel, v.n),
                        amount: -v.total, tone: 0, indent: true))
                }
            }

            if investActual > 0 {
                flow.append(CashflowRow(label: loc("brief.flow.invest"), amount: -investActual, tone: -1))
            }

            flow.append(CashflowRow(
                label: loc("brief.flow.left"), amount: leftAfterAll,
                tone: leftAfterAll >= 0 ? 1 : -1,
                caption: leftAfterAll < 0 ? loc("brief.flow.deficit_note") : nil))
        }

        // ── Findings ────────────────────────────────────────────────────
        var findings: [BriefingFinding] = []

        // 0. Double-logged commitment — a manual twin of a recurring charge.
        // Matched by amount (±1%) in fixed categories, NOT by name: the twin
        // usually has a different name than the plan ("Tranfer ibu bulanan"
        // vs plan "transfer mom"). Flag-only — both charges can be real.
        for plan in activeRecurring {
            let amt = toPref(plan.amount, plan.currency)
            guard amt > 0 else { continue }
            let tol = max(amt * 0.01, 1_000)
            let twins = windowExpense.filter {
                (SmartBudgetManager.fixedCategories.contains($0.category)
                 || $0.notes == "tx.note.recurring_auto")
                && abs(toPref(abs($0.amount), $0.currency) - amt) <= tol
            }
            if twins.count > 1 {
                findings.append(BriefingFinding(
                    severity: .warning,
                    title: loc("brief.dupe_title"),
                    body: String(format: loc("brief.dupe_body"),
                                 plan.label, twins.count, fmt(amt),
                                 fmt(Double(twins.count - 1) * amt)),
                    action: loc("brief.dupe_action")))
            }
        }

        // 1. Rigid cost structure — committed share of income.
        if income > 0, committed > 0 {
            let share = Int((committed / income * 100).rounded())
            if committed > income * 0.45 {
                findings.append(BriefingFinding(
                    severity: .warning,
                    title: loc("brief.rigid_title"),
                    body: String(format: loc("brief.rigid_body"), fmt(committed), share,
                                 fmt(leftAfterCommitted)),
                    action: loc("brief.rigid_action")))
            }
        }

        // 2. Small-ticket bleed — many tiny purchases quietly compounding.
        // Threshold scales with income (~0.5%; Rp 50K on Rp 10M) instead of a
        // hardcoded figure, so it stays meaningful across income levels.
        let smallThr = income > 0 ? income * 0.005 : 50_000
        let small = windowExpense.filter { toPref(abs($0.amount), $0.currency) < smallThr
            && !SmartBudgetManager.isFixedCategory($0.category) }
        let smallTotal = small.reduce(0.0) { $0 + toPref(abs($1.amount), $1.currency) }
        if consumption > 0, small.count >= 15, smallTotal > consumption * 0.12,
           !declared.excusesLifestyle, !declared.excusesDeficit {
            findings.append(BriefingFinding(
                severity: .warning,
                title: loc("brief.bleed_title"),
                body: String(format: loc("brief.bleed_body"), small.count, fmt(smallThr), fmt(smallTotal),
                             Int((smallTotal / consumption * 100).rounded()), fmt(smallTotal * 12)),
                action: loc("brief.bleed_action")))
        }

        // 3. Habit merchant — one name appearing again and again.
        var byMerchant: [String: (n: Int, total: Double)] = [:]
        for tx in windowExpense where !SmartBudgetManager.isFixedCategory(tx.category) {
            let key = tx.name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            let cur = byMerchant[key] ?? (0, 0)
            byMerchant[key] = (cur.n + 1, cur.total + toPref(abs(tx.amount), tx.currency))
        }
        if let habit = byMerchant.filter({ $0.value.n >= 4 }).max(by: { $0.value.total < $1.value.total }) {
            findings.append(BriefingFinding(
                severity: .insight,
                title: String(format: loc("brief.habit_title"), habit.key),
                body: String(format: loc("brief.habit_body"), habit.value.n, habit.key,
                             fmt(habit.value.total), fmt(habit.value.total * 12))))
        }

        // 4. Debt freedom date — when installments end and cash frees up.
        if debtMin > 0 {
            // Months to clear the LONGEST-running debt at minimum payments.
            let monthsLeft = activeDebts.compactMap { d -> Int? in
                // `effectiveMinimumPayment`, not the raw field: users routinely
                // leave the minimum at 0 on 0%-APR installments, and the raw
                // value skipped those debts entirely — so the "freedom date"
                // silently described only part of what they owe.
                let minP = toPref(d.effectiveMinimumPayment, d.currency)
                guard minP > 0 else { return nil }
                return Int(ceil(toPref(d.currentBalance, d.currency) / minP))
            }.max() ?? 0
            if monthsLeft > 0, let freedom = cal.date(byAdding: .month, value: monthsLeft, to: now) {
                let f = DateFormatter(); f.locale = LanguageManager.shared.currentLocale
                f.dateFormat = "MMMM yyyy"
                findings.append(BriefingFinding(
                    severity: .insight,
                    title: loc("brief.freedom_title"),
                    body: String(format: loc("brief.freedom_body"), fmt(debtMin),
                                 f.string(from: freedom), fmt(debtMin)),
                    action: loc("brief.freedom_action")))
            }
        }

        // 5. Interest reality — costly debt first, or reassurance at 0%.
        let costly = activeDebts.filter { $0.annualInterestRate > 0 }
        if let worst = costly.max(by: { $0.annualInterestRate < $1.annualInterestRate }) {
            findings.append(BriefingFinding(
                severity: .critical,
                title: loc("brief.interest_title"),
                body: String(format: loc("brief.interest_body"), worst.name,
                             Int(worst.annualInterestRate), fmt(toPref(worst.currentBalance, worst.currency))),
                action: loc("brief.interest_action")))
        } else if totalDebt + ccOwed > 0 {
            findings.append(BriefingFinding(
                severity: .positive,
                title: loc("brief.zero_interest_title"),
                body: String(format: loc("brief.zero_interest_body"), fmt(totalDebt + ccOwed))))
        }

        // 6. Credit-card hygiene — utilization + affordability of next bill.
        for cc in creditCards where cc.creditLimit > 0 {
            let owed = toPref(cc.owedBalance(), cc.resolvedCurrency)
            let util = cc.creditUtilization
            if util > 0.5 {
                findings.append(BriefingFinding(
                    severity: .warning,
                    title: String(format: loc("brief.cc_util_title"), cc.holderName),
                    body: String(format: loc("brief.cc_util_body"), Int(util * 100),
                                 fmt(owed), fmt(toPref(cc.availableCredit(), cc.resolvedCurrency)))))
            }
        }

        // 7. Goal reality check — is the stated pace actually funded?
        for g in goals where !g.isCompleted && g.monthlyContribution > 0 {
            let pace = toPref(g.monthlyContribution, g.currency)
            let remaining = toPref(g.remaining, g.currency)
            let months = pace > 0 ? Int(ceil(remaining / pace)) : 0
            guard months > 0 else { continue }
            let years = Double(months) / 12.0
            if leftAfterAll < 0, !declared.excusesGoalFunding {
                findings.append(BriefingFinding(
                    severity: .warning,
                    title: String(format: loc("brief.goal_unfunded_title"), g.name),
                    body: String(format: loc("brief.goal_unfunded_body"), fmt(pace), g.name),
                    action: loc("brief.goal_unfunded_action")))
            } else if months > 24 {
                findings.append(BriefingFinding(
                    severity: .insight,
                    title: String(format: loc("brief.goal_slow_title"), g.name),
                    body: String(format: loc("brief.goal_slow_body"), fmt(pace), g.name,
                                 String(format: "%.1f", years), fmt(remaining))))
            }
        }

        // 8. What's going RIGHT — always close on real positives.
        if investActual + debtPaid > 0, income > 0 {
            findings.append(BriefingFinding(
                severity: .positive,
                title: loc("brief.invest_ok_title"),
                body: String(format: loc("brief.invest_ok_body"),
                             fmt(investActual + debtPaid),
                             Int(((investActual + debtPaid) / income * 100).rounded()))))
        }

        // Order: severity first, then keep insertion order. Cap to keep it readable.
        findings.sort { $0.severity.rawValue < $1.severity.rawValue }
        if findings.count > 6 { findings = Array(findings.prefix(6)) }

        // ── Recommended allocation ── daily / lifestyle / invest-debt split
        // derived from the user's OWN cost structure, not a one-size 50/30/20:
        //   • daily must cover the fixed block plus a livable essential slice
        //   • invest/debt must at least cover debt minimums
        //   • lifestyle takes the remainder, never below 10%
        var allocation: [AllocationRec] = []
        var allocationNote: String? = nil
        if income > 0, windowExpense.count >= 15 {
            func snap5(_ x: Double) -> Double { (x * 20).rounded() / 20 }
            let fixedShare = fixedSpent / income
            // Essential variable capped at 25% so current overspending doesn't
            // get baked in as a "need".
            let essentialShare = min(essentialVar / income, 0.25)
            var daily = snap5(min(max(fixedShare + essentialShare, 0.40), 0.65))
            var invest = snap5(min(max(isDeficit ? 0.10 : 0.20, debtMin / income + 0.05), 0.35))
            // Same "heavy debt" test the recommendation engine uses: either
            // interest-bearing, or minimums already eating >10% of income.
            if !costly.isEmpty || debtMin > income * 0.10 { invest = max(invest, 0.30) }
            if daily + invest > 0.90 { invest = max(0.90 - daily, 0.10) }   // keep ≥10% lifestyle
            let lifestyle = 1.0 - daily - invest

            let dailyCur = Int(((fixedSpent + essentialVar) / income * 100).rounded())
            let lifeCur  = Int((lifestyleVar / income * 100).rounded())
            let invCur   = Int(((debtPaid + investActual) / income * 100).rounded())
            let goalName = goals.first(where: { !$0.isCompleted && $0.monthlyContribution > 0 })?.name

            allocation = [
                AllocationRec(
                    label: loc("brief.alloc.daily"), pct: Int(daily * 100),
                    amount: income * daily, currentPct: dailyCur,
                    detail: String(format: loc("brief.alloc.daily_detail"), fmt(fixedSpent)),
                    color: AppTheme.accent),
                AllocationRec(
                    label: loc("brief.alloc.lifestyle"), pct: Int(lifestyle * 100),
                    amount: income * lifestyle, currentPct: lifeCur,
                    detail: loc("brief.alloc.lifestyle_detail"),
                    color: AppTheme.orange),
                AllocationRec(
                    label: loc("brief.alloc.investdebt"), pct: Int(invest * 100),
                    amount: income * invest, currentPct: invCur,
                    detail: String(format: loc("brief.alloc.invest_detail"),
                                   fmt(debtMin), fmt(max(income * invest - debtMin, 0)),
                                   goalName ?? loc("brief.alloc.your_goals")),
                    color: AppTheme.purple),
            ]
            allocationNote = loc("brief.alloc_note")
        }

        // ── Outlook ─────────────────────────────────────────────────────
        var outlook: [String] = []
        let cash = cards.filter { !$0.isCreditCard }
            .reduce(0.0) { $0 + toPref($1.computedBalance(), $1.resolvedCurrency) }
        let liabilities = totalDebt + ccOwed
        // Savings goals hold real money — same definition as the Home chip, so
        // the two screens can never disagree about whether the user is "under".
        let goalSavings = goals.filter { !$0.isCompleted }
            .reduce(0.0) { $0 + toPref($1.netWorthContribution(from: allTx), $1.currency) }
        let netWorth = cash + goalSavings - liabilities
        if netWorth < 0, debtMin > 0 {
            let monthsToZero = Int(ceil(abs(netWorth) / debtMin))
            if monthsToZero < 60, let d = cal.date(byAdding: .month, value: monthsToZero, to: now) {
                let f = DateFormatter(); f.locale = LanguageManager.shared.currentLocale
                f.dateFormat = "MMMM yyyy"
                outlook.append(String(format: loc("brief.outlook_networth"), fmt(abs(netWorth)), f.string(from: d)))
            }
        } else if netWorth >= 0 {
            outlook.append(String(format: loc("brief.outlook_networth_pos"), fmt(netWorth)))
        }
        if goalPace > 0, let g = goals.first(where: { !$0.isCompleted && $0.monthlyContribution > 0 }) {
            let remaining = toPref(g.remaining, g.currency)
            let pace = toPref(g.monthlyContribution, g.currency)
            if pace > 0 {
                let months = Int(ceil(remaining / pace))
                if let d = cal.date(byAdding: .month, value: months, to: now) {
                    let f = DateFormatter(); f.locale = LanguageManager.shared.currentLocale
                    f.dateFormat = "MMMM yyyy"
                    outlook.append(String(format: loc("brief.outlook_goal"), g.name, f.string(from: d)))
                }
            }
        }

        if !declared.isEmpty {
            let names = CycleIntentKind.allCases.filter { declared.has($0) }
                .map(\.label).joined(separator: " · ")
            findings.insert(BriefingFinding(
                severity: .positive,
                title: loc("brief.intent_title"),
                body: String(format: loc("brief.intent_body"), names)), at: 0)
        }

        return FinancialBriefing(headline: headline, periodLabel: periodLabel,
                                 cashflow: flow, findings: findings,
                                 allocation: allocation, allocationNote: allocationNote,
                                 outlook: outlook)
    }
}

// MARK: - View

struct FinancialBriefingView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @Query private var debts: [DebtRecord]
    @Query private var goals: [SavingsGoal]
    @Query private var recurrings: [RecurringExpense]
    @Query(sort: \SalarySchedule.createdAt) private var salaries: [SalarySchedule]
    @Query private var cycleIntents: [CycleIntent]

    @State private var briefing: FinancialBriefing? = nil
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                if let b = briefing {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            // Period badge — always tells the user which slice
                            // of their life the numbers describe.
                            HStack(spacing: 6) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(b.periodLabel)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(AppTheme.purple)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(AppTheme.purple.opacity(0.12), in: Capsule())
                            .padding(.horizontal, 22).padding(.top, 8)

                            // Headline
                            Text(b.headline)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 22)

                            // Cash-flow anatomy
                            if !b.cashflow.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(b.cashflow) { row in
                                        cashflowRow(row)
                                        if row.id != b.cashflow.last?.id, !row.indent {
                                            Divider().background(AppTheme.cardMid)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                                .padding(.horizontal, 22)
                            }

                            // Recommended allocation
                            if !b.allocation.isEmpty {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text(loc("brief.alloc_header"))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                    ForEach(b.allocation) { rec in allocationRow(rec) }
                                    if let note = b.allocationNote {
                                        Text(note)
                                            .font(.system(size: 11))
                                            .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                                .padding(.horizontal, 22)
                            }

                            // Findings
                            ForEach(b.findings) { f in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Image(systemName: f.severity.icon)
                                            .font(.system(size: 14)).foregroundStyle(f.severity.color)
                                        Text(f.title).font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                    }
                                    Text(f.body).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                                    if let action = f.action {
                                        HStack(spacing: 6) {
                                            Image(systemName: "arrow.turn.down.right").font(.system(size: 11))
                                            Text(action).font(.system(size: 12, weight: .medium))
                                        }
                                        .foregroundStyle(f.severity.color)
                                    }
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(f.severity.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(f.severity.color.opacity(0.2), lineWidth: 1))
                                .padding(.horizontal, 22)
                            }

                            // Outlook
                            if !b.outlook.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(loc("brief.outlook_header"))
                                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                    ForEach(b.outlook, id: \.self) { line in
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "binoculars.fill")
                                                .font(.system(size: 11)).foregroundStyle(AppTheme.purple).padding(.top, 2)
                                            Text(line).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppTheme.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                                .padding(.horizontal, 22)
                            }

                            Text(loc("brief.disclaimer"))
                                .font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                                .padding(.horizontal, 22)

                            Spacer(minLength: 30)
                        }
                        .opacity(appeared ? 1 : 0)
                    }
                } else {
                    ProgressView().tint(AppTheme.purple)
                }
            }
            .navigationTitle(loc("brief.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.done")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
            }
            .onAppear {
                briefing = FinancialBriefingEngine.build(
                    cards: cards, debts: debts, goals: goals,
                    recurrings: recurrings, salaries: salaries,
                    intents: cycleIntents)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { appeared = true }
            }
        }
    }

    // MARK: Row builders

    @ViewBuilder
    private func cashflowRow(_ row: CashflowRow) -> some View {
        let cm = CurrencyManager.shared
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.label)
                    .font(.system(size: row.indent ? 12 : 13))
                    .foregroundStyle(row.indent ? AppTheme.textSecondary.opacity(0.8) : AppTheme.textSecondary)
                Spacer()
                Text((row.amount < 0 ? "−" : "") + cm.formatted(abs(row.amount), currency: cm.preferredCurrency))
                    .font(.system(size: row.indent ? 12 : 14, weight: row.indent ? .regular : .semibold))
                    .foregroundStyle(row.indent ? AppTheme.textSecondary.opacity(0.8)
                                     : row.tone > 0 ? AppTheme.accent
                                     : row.tone < 0 && row.label == loc("brief.flow.left") ? AppTheme.red
                                     : AppTheme.textPrimary)
            }
            if let caption = row.caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, row.indent ? 4 : 9)
        .padding(.leading, row.indent ? 14 : 0)
    }

    @ViewBuilder
    private func allocationRow(_ rec: AllocationRec) -> some View {
        let cm = CurrencyManager.shared
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(rec.color).frame(width: 8, height: 8)
                Text(rec.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text("\(rec.pct)%")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(rec.color)
                Text(cm.formatted(rec.amount, currency: cm.preferredCurrency))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            // The FILLED bar is what actually happened; the marker is the
            // recommended target. A bar past its marker means over budget, and
            // it turns orange so the eye lands on the bucket that overshot.
            let isOver = rec.currentPct > rec.pct
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.cardMid).frame(height: 6)
                    Capsule().fill((isOver ? AppTheme.orange : rec.color).opacity(0.85))
                        .frame(width: geo.size.width * CGFloat(min(rec.currentPct, 100)) / 100, height: 6)
                    // Target marker
                    Rectangle().fill(AppTheme.textPrimary.opacity(0.9))
                        .frame(width: 2, height: 12)
                        .offset(x: geo.size.width * CGFloat(min(rec.pct, 100)) / 100 - 1)
                }
            }
            .frame(height: 12)
            HStack(spacing: 6) {
                Text(String(format: loc(isOver ? "brief.alloc.over" : "brief.alloc.under"),
                            rec.currentPct, abs(rec.currentPct - rec.pct)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isOver ? AppTheme.orange : AppTheme.accent)
                Spacer()
                Text(loc("brief.alloc.marker_legend"))
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
            }
            Text(rec.detail)
                .font(.system(size: 11.5))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(1.5)
        }
    }
}
