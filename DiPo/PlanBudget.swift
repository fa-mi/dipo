import SwiftUI

// MARK: - Plan: what is left to spend, first
//
// Plan opened on a column of feature rows; how the month was going was one
// tap away, inside Smart Budget. Now, with a budget on, it opens on what is
// left to spend this period as its one big number, and Needs, Wants and
// Savings & debt as three plain rows with a thin bar. Past a limit says so in
// orange, with by how much.
//
// The figures are worked out the way the Smart Budget screen and its alerts
// work them out (the main card's pot, the pay cycle, stated income plus money
// added to the period), so the three can't disagree.

struct PlanBudget: Equatable {
    struct Group: Equatable {
        let group: BudgetGroup
        let limit: Double
        let spent: Double

        /// Past a limit. Savings & debt is a target, so going past it is
        /// good news and never "over".
        var over: Double { group.isCeiling ? max(spent - limit, 0) : 0 }
        var progress: Double { limit > 0 ? spent / limit : 0 }
    }

    let groups: [Group]
    let currency: String

    /// What is left to spend on Needs and Wants: their limits less what they
    /// have spent. Below zero once together they are past.
    var left: Double {
        groups.filter(\.group.isCeiling).reduce(0) { $0 + $1.limit - $1.spent }
    }

    /// Nil without income: every limit is a share of it.
    static func make(income: Double,
                     ratios: (daily: Double, lifestyle: Double, investDebt: Double),
                     currency: String,
                     spent: (BudgetGroup) -> Double) -> PlanBudget? {
        guard income > 0 else { return nil }
        let share: [BudgetGroup: Double] = [.daily: ratios.daily, .lifestyle: ratios.lifestyle,
                                            .investDebt: ratios.investDebt]
        return PlanBudget(groups: BudgetGroup.allCases.map {
            Group(group: $0, limit: income * (share[$0] ?? 0), spent: max(spent($0), 0))
        }, currency: currency)
    }

    /// This period's figures for the budget that is on, read as Smart Budget
    /// reads them. Nil when the budget is off or there is no income.
    static func current(cards: [BankCard], schedules: [SalarySchedule],
                        configs: [CardBudgetConfig],
                        manager sb: SmartBudgetManager = .shared) -> PlanBudget? {
        guard sb.hasActiveBudget else { return nil }
        let currency = CurrencyManager.shared.preferredCurrency
        let cal = Calendar.current
        let main = MainCard.resolve(in: cards)
        let period: (start: Date, end: Date) = {
            if let day = MainCard.payDay(schedules) {
                return StatPeriod.cycle(payDay: day, salaryDates: StatPeriod.salaryDates(on: main))
            }
            let start = cal.safeDate(from: cal.dateComponents([.year, .month], from: Date()))
            return (start, cal.safeDate(byAdding: .month, value: 1, to: start))
        }()
        let scoped = main != nil ? MainCard.budgetSpendingTransactions(in: cards) : cards.flatMap(\.transactions)
        var income = MainCard.budgetIncome(schedules: schedules, transactions: scoped,
                                           from: period.start, to: period.end, currency: currency).amount
        if main != nil {
            income += ExtraFunds.total(in: scoped, from: period.start, to: period.end, currency: currency)
        }
        let window = scoped.filter {
            $0.date >= period.start && $0.txSubtype != .transfer && ($0.amount < 0 || $0.txSubtype == .refund)
        }
        return make(income: income, ratios: sb.ratios(forCardID: sb.budgetCardID, configs: configs),
                    currency: currency) {
            sb.spent(in: $0, transactions: window, targetCurrency: currency, periodStart: period.start)
        }
    }
}

/// The big number and the three rows. Opens Smart Budget.
struct PlanBudgetBlock: View {
    let budget: PlanBudget
    let onOpen: () -> Void

    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: budget.currency) }

    /// "Rp 1.200.000 of Rp 2.500.000", or for Savings & debt "… of the
    /// Rp 1.000.000 target".
    static func figure(_ g: PlanBudget.Group, money: (Double) -> String) -> String {
        String(format: loc(g.group.isCeiling ? "plan.group_of" : "plan.saved_of_target"),
               money(g.spent), money(g.limit))
    }

    var body: some View {
        Button { HapticManager.shared.tap(); onOpen() } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(loc("plan.budget_left"))
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                // Past both limits together says so in words and orange, never
                // as a minus.
                Text(budget.left >= -0.5 ? money(max(budget.left, 0))
                     : String(format: loc("plan.budget_over"), money(-budget.left)))
                    .font(.system(.largeTitle, weight: .bold).monospacedDigit())
                    .foregroundStyle(budget.left >= -0.5 ? AppTheme.textPrimary : AppTheme.orange)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .contentTransition(.numericText())

                VStack(spacing: 0) {
                    ForEach(budget.groups, id: \.group) { g in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                // The name stays whole; the figure gives way.
                                Text(g.group.label)
                                    .font(.system(.subheadline, weight: .medium))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .fixedSize()
                                Spacer(minLength: 6)
                                Text(Self.figure(g, money: money))
                                    .font(.system(.caption).monospacedDigit())
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .lineLimit(1).minimumScaleFactor(0.65)
                            }
                            DebtThinBar(progress: g.progress,
                                        tint: g.over > 0.5 ? AppTheme.orange : AppTheme.textPrimary)
                            if g.over > 0.5 {
                                Text(String(format: loc("plan.group_over"), money(g.over)))
                                    .font(.system(.caption, weight: .medium))
                                    .foregroundStyle(AppTheme.orange)
                            }
                        }
                        .padding(.vertical, 10)
                    }
                }
                .padding(.top, 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(loc("profile.budget"))
    }
}

// MARK: - The main number on a Plan row

enum PlanRowValue {
    /// What every active debt and credit card owes, in one currency. A card
    /// recorded by hand as a debt is the balance the card already carries, so
    /// cards are left out then, as the Debts page does.
    static func owed(debts: [DebtRecord], cards: [BankCard], installments: [CardInstallment],
                     currency: String) -> Double {
        let cm = CurrencyManager.shared
        let active = debts.filter(\.isActive)
        let onDebts = active.reduce(0.0) { $0 + cm.convert($1.currentBalance, from: $1.currency, to: currency) }
        let cardRecorded = active.contains { !$0.manuallyClosed && $0.type == DebtType.creditCard.rawValue }
        guard !cardRecorded else { return onDebts }
        return cards.filter(\.isCreditCard).reduce(onDebts) {
            $0 + cm.convert($1.totalOwed(installments), from: $1.resolvedCurrency, to: currency)
        }
    }

    /// What the goals still running have saved.
    static func saved(goals: [SavingsGoal], currency: String) -> Double {
        let cm = CurrencyManager.shared
        return goals.filter { !$0.isCompleted }.reduce(0.0) {
            $0 + cm.convert($1.currentValue, from: $1.currency, to: currency)
        }
    }
}
