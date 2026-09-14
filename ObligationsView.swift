import SwiftUI
import SwiftData

// MARK: - Obligations
//
// Debt Tracker, Owed to You and the Planner used to be three separate menu
// entries, which was wrong in a way that went beyond clutter: they are three
// views of ONE question — what is already committed, what is coming back, and
// what a new commitment would do to the rest.
//
// The card at the top is the part that makes the merge worth doing. A KPR
// instalment of Rp 5,3jt means nothing on its own; "your fixed obligations go
// from 18% to 62% of income, against the 20% Smart Budget sets aside for debt"
// is a decision. Every calculator here reports its answer in those terms.

// MARK: - The shared calculation

struct ObligationLoad {
    let monthlyIncome: Double
    /// Minimum payments on active debts — the amount that must be paid to stay
    /// current, not the full balance.
    let debtMinimums: Double
    /// Declared recurring commitments (rent, subscriptions, standing transfers).
    let commitments: Double
    /// Smart Budget's own allocations, so this card checks obligations against
    /// the framework the user already configured instead of inventing a second
    /// one beside it. Debt payments belong to Invest & Debt; rent, transfers and
    /// subscriptions are filed under Daily Needs (see `dailyCategories`).
    let debtAllowanceRatio: Double
    let dailyAllowanceRatio: Double
    /// Active salary paid into OTHER accounts, deliberately absent from
    /// `monthlyIncome`. Carried so the card can say so: a second job vanishing
    /// from the plan with no explanation reads as the app losing it, and a
    /// user with two jobs is exactly who notices.
    var incomeElsewhere: Double = 0
    var jobsElsewhere: Int = 0

    var total: Double { debtMinimums + commitments }
    var ratio: Double { monthlyIncome > 0 ? total / monthlyIncome : 0 }

    var debtAllowance: Double { monthlyIncome * debtAllowanceRatio }
    var dailyAllowance: Double { monthlyIncome * dailyAllowanceRatio }
    /// The share the plan reserves for saving and investing — debt payments
    /// come out of it, so whatever debt does not use stays reserved.
    var setAside: Double { max(debtAllowance, debtMinimums) }

    /// What is left after everything contractual AND after the plan's own
    /// reserve. Subtracting only debt and commitments left the Invest & Debt
    /// allocation sitting in "free to decide", so this card said Rp 6.295.000
    /// while the Salary Allocation Plan directly below it said Rp 4.295.000 —
    /// two answers to one question, on one screen.
    var freeAfterObligations: Double { max(monthlyIncome - total - setAside + debtMinimums, 0) }

    // Standard back-end DTI bands. This measure is exactly what lenders call
    // back-end debt-to-income: debt payments PLUS housing and other contractual
    // commitments, over gross income.
    //
    // The first version of this compared the total against Smart Budget's 20%
    // Invest & Debt allocation, which was a category error. `commitment` — kos,
    // family transfers, subscriptions — is filed under DAILY NEEDS (the 50%
    // bucket), not Invest & Debt. Measuring rent against the debt allowance
    // meant almost anyone read "Too heavy" regardless of their finances, and it
    // put a red 37% directly above the Debt Tracker's "Excellent, DTI 0.0%".
    // Two health verdicts on one screen, disagreeing, and the wrong one was
    // mine.
    static let healthyCeiling = 0.36
    static let stretchedCeiling = 0.43

    var allocated: Double { monthlyIncome * Self.healthyCeiling }
    /// Room left before crossing the healthy band.
    var headroom: Double { allocated - total }

    enum Verdict { case healthy, tight, over }

    var verdict: Verdict {
        guard monthlyIncome > 0 else { return .healthy }
        if ratio <= Self.healthyCeiling { return .healthy }
        return ratio <= Self.stretchedCeiling ? .tight : .over
    }

    /// The same load with a hypothetical new instalment added — what every
    /// calculator in the Simulate tab reports against.
    func adding(instalment: Double) -> ObligationLoad {
        ObligationLoad(monthlyIncome: monthlyIncome,
                       debtMinimums: debtMinimums + instalment,
                       commitments: commitments,
                       debtAllowanceRatio: debtAllowanceRatio,
                       dailyAllowanceRatio: dailyAllowanceRatio,
                       incomeElsewhere: incomeElsewhere,
                       jobsElsewhere: jobsElsewhere)
    }

    static func build(debts: [DebtRecord],
                      recurrings: [RecurringExpense],
                      salaries: [SalarySchedule],
                      configs: [CardBudgetConfig]) -> ObligationLoad {
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency

        var income = 0.0
        for s in MainCard.salaries(salaries) {
            income += cm.convert(s.amount, from: s.currency, to: pref)
        }
        let elsewhere = MainCard.salariesElsewhere(salaries)
        var otherIncome = 0.0
        for s in elsewhere {
            otherIncome += cm.convert(s.amount, from: s.currency, to: pref)
        }
        var minimums = 0.0
        for d in debts where d.isActive && !d.manuallyClosed {
            minimums += cm.convert(d.minimumPayment, from: d.currency, to: pref)
        }
        var commitments = 0.0
        for r in recurrings where r.isActive {
            commitments += cm.convert(r.amount, from: r.currency, to: pref)
        }
        // Per-card overrides win over the global ratios, same rule the rest of
        // the app follows.
        let sb = SmartBudgetManager.shared
        let r = sb.ratios(forCardID: sb.budgetCardID, configs: configs)
        return ObligationLoad(monthlyIncome: income,
                              debtMinimums: minimums,
                              commitments: commitments,
                              debtAllowanceRatio: r.investDebt,
                              dailyAllowanceRatio: r.daily,
                              incomeElsewhere: otherIncome,
                              jobsElsewhere: elsewhere.count)
    }
}

extension ObligationLoad.Verdict {
    var tint: Color {
        switch self {
        case .healthy: return AppTheme.accent
        case .tight:   return AppTheme.orange
        case .over:    return AppTheme.red
        }
    }
    var labelKey: String {
        switch self {
        case .healthy: return "oblig.verdict_healthy"
        case .tight:   return "oblig.verdict_tight"
        case .over:    return "oblig.verdict_over"
        }
    }
}

// MARK: - Load card

struct ObligationLoadCard: View {
    let load: ObligationLoad
    /// When set, the card shows a before → after comparison instead of a single
    /// state. Used by the simulators.
    var projected: ObligationLoad? = nil

    private var cm: CurrencyManager { CurrencyManager.shared }
    private func money(_ v: Double) -> String { cm.formatted(v, currency: cm.preferredCurrency) }
    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    private var shown: ObligationLoad { projected ?? load }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(loc("oblig.load_title"))
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text(loc(shown.verdict.labelKey))
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(shown.verdict.tint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(shown.verdict.tint.opacity(0.15), in: Capsule())
            }

            if load.monthlyIncome <= 0 {
                Text(loc("oblig.no_income"))
                    .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(pct(shown.ratio))
                        .font(.system(.largeTitle, weight: .bold))
                        .foregroundStyle(shown.verdict.tint)
                    if projected != nil {
                        Text("← " + pct(load.ratio))
                            .font(.system(.footnote, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()
                }
                Text(String(format: loc("oblig.of_income"),
                            money(shown.total), money(load.monthlyIncome)))
                    .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)

                ratioBar

                // Each component against the bucket Smart Budget puts it in,
                // rather than one lump against an unrelated ceiling.
                VStack(spacing: 7) {
                    line(String(format: loc("oblig.vs_debt"), pct(load.debtAllowanceRatio)),
                         money(shown.debtMinimums) + " / " + money(load.debtAllowance),
                         tint: shown.debtMinimums > load.debtAllowance ? AppTheme.red : AppTheme.textPrimary)
                    line(String(format: loc("oblig.vs_daily"), pct(load.dailyAllowanceRatio)),
                         money(shown.commitments) + " / " + money(load.dailyAllowance),
                         tint: shown.commitments > load.dailyAllowance ? AppTheme.red : AppTheme.textPrimary)
                    Divider().overlay(AppTheme.cardMid)
                    line(loc("oblig.free_after"), money(shown.freeAfterObligations),
                         tint: AppTheme.accent)
                }

                if load.incomeElsewhere > 0 {
                    Label(String(format: loc(load.jobsElsewhere == 1
                                             ? "oblig.income_elsewhere"
                                             : "oblig.income_elsewhere_n"),
                                 money(load.incomeElsewhere), load.jobsElsewhere),
                          systemImage: "arrow.turn.down.right")
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    /// Obligations against the Smart Budget allocation, drawn to the same
    /// scale so "past the line" is literally past a line.
    private var ratioBar: some View {
        GeometryReader { geo in
            let scale = max(shown.ratio, ObligationLoad.stretchedCeiling, 0.5) * 1.1
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.cardMid).frame(height: 8)
                Capsule().fill(shown.verdict.tint)
                    .frame(width: w * min(shown.ratio / scale, 1), height: 8)
                Rectangle().fill(AppTheme.textSecondary.opacity(0.7))
                    .frame(width: 2, height: 14)
                    .offset(x: w * min(ObligationLoad.healthyCeiling / scale, 1) - 1)
            }
        }
        .frame(height: 14)
    }

    private func line(_ label: String, _ value: String, tint: Color = AppTheme.textPrimary) -> some View {
        // Label wraps, figure never does — "x / y" split across two lines
        // was unreadable, and English labels run longer than Indonesian ones.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(value).font(.system(.caption, weight: .semibold)).foregroundStyle(tint)
                .fixedSize()
        }
    }
}

// MARK: - Hub

struct ObligationsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var debts: [DebtRecord]
    @Query private var recurrings: [RecurringExpense]
    @Query private var salaries: [SalarySchedule]
    @Query private var budgetConfigs: [CardBudgetConfig]

    enum Tab: String, CaseIterable, Identifiable {
        case owed, lent, simulate
        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .owed:     return "oblig.tab_owed"
            case .lent:     return "oblig.tab_lent"
            case .simulate: return "oblig.tab_simulate"
            }
        }
    }
    @State private var tab: Tab = .owed

    private var load: ObligationLoad {
        ObligationLoad.build(debts: debts, recurrings: recurrings, salaries: salaries,
                             configs: budgetConfigs)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                // Deliberately NOT wrapped in a ScrollView: each segment below
                // brings its own, and nesting two scroll views makes both
                // behave badly. The load card and picker stay pinned, which is
                // also the right call — the ratio is the context you want to
                // keep in view while reading any of the three tabs.
                VStack(spacing: 14) {
                    // The obligation breakdown moved INSIDE the You-owe tab,
                    // next to the health score, so the app states its verdict on
                    // the user's finances exactly once.
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases) { t in
                            Text(loc(t.titleKey)).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 22)
                    .padding(.top, 12)

                    switch tab {
                    case .owed:     DebtView(embedded: true)
                    case .lent:     ReceivablesView(embedded: true)
                    // Only the tools that CREATE debt live here. Take-home pay
                    // and pension projections are income questions and moved to
                    // Smart Budget, where cash flow is already the subject.
                    case .simulate: PlannerView(embedded: true, load: load,
                                                tools: [.kpr, .vehicle])
                    }
                }
            }
            .trackScreen(.obligations)
            .navigationTitle(loc("oblig.nav"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
    }
}
