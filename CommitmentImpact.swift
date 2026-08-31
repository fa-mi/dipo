import SwiftUI
import SwiftData

// MARK: - Commitment impact, shown before the commitment is made
//
// This is the piece that turns Smart Budget from a dashboard into decision
// support, and the distinction is narrower than it sounds.
//
// Everything DiPo already does — the health score, the obligation card, the
// commitment breakdown, the KPR simulator — reports on decisions that have
// ALREADY been taken, or waits for someone to go looking. That is a dashboard.
// It informs, but only after the fact, and only if the user thinks to ask.
//
// A decision support system meets the decision where it happens. The one moment
// in this app where a person is actively committing future money — every month,
// indefinitely — is the instant before they tap Save on a recurring expense.
// DiPo knows their income, their bucket allowances, what is already committed,
// and what they are saving for. Until now it watched that moment in silence and
// only spoke afterwards, once the number had already moved.
//
// So this says three things while the choice is still open:
//
//   1. WHICH bucket this lands in and what it does to it — a percentage of
//      income cannot tell you which part of the plan is about to take the hit.
//   2. What it costs in the thing the user said they want, priced in TIME.
//   3. Whether it crosses a line — stated plainly, once, without nagging.
//
// Then it stops. The user still decides; they simply decide knowing. An app
// that blocks the save, or argues, has stopped supporting the decision and
// started making it.
struct CommitmentImpact {
    let group: BudgetGroup
    let allowance: Double
    /// Committed in this bucket before the new one.
    let committedBefore: Double
    let proposed: Double
    /// Goal months this commitment's annual cost would have funded.
    let goalMonthsPerYear: Double
    let goalName: String?

    var committedAfter: Double { committedBefore + proposed }
    var shareBefore: Double { allowance > 0 ? committedBefore / allowance : 0 }
    var shareAfter: Double { allowance > 0 ? committedAfter / allowance : 0 }
    var overflows: Bool { allowance > 0 && committedAfter > allowance }
    var spillover: Double { max(committedAfter - allowance, 0) }

    static func build(proposedAmount: Double,
                      category: TxCategory,
                      currency: String,
                      excludingPlanID: UUID?,
                      recurrings: [RecurringExpense],
                      salaries: [SalarySchedule],
                      goals: [SavingsGoal],
                      configs: [CardBudgetConfig]) -> CommitmentImpact? {
        let cm = CurrencyManager.shared
        let mgr = SmartBudgetManager.shared
        guard proposedAmount > 0, let group = mgr.group(for: category) else { return nil }

        var income = 0.0
        for s in salaries where s.isActive {
            income += cm.convert(s.amount, from: s.currency, to: currency)
        }
        guard income > 0 else { return nil }

        // Everything already committed in the SAME bucket. An edit must exclude
        // the plan being edited, or its own current amount counts twice and the
        // preview reports a jump that isn't happening.
        var before = 0.0
        for r in recurrings where r.isActive && r.id != excludingPlanID {
            guard mgr.group(for: r.category) == group else { continue }
            before += cm.convert(r.amount, from: r.currency, to: currency)
        }

        let goal = goals.first { !$0.isCompleted }
        let goalMonthly = goal.map { cm.convert($0.monthlyContribution, from: $0.currency, to: currency) } ?? 0

        return CommitmentImpact(
            group: group,
            allowance: mgr.monthlyLimit(for: group, income: income,
                                        cardID: mgr.budgetCardID, configs: configs),
            committedBefore: before,
            proposed: proposedAmount,
            goalMonthsPerYear: goalMonthly > 0 ? (proposedAmount * 12) / goalMonthly : 0,
            goalName: goal?.name)
    }
}

struct CommitmentImpactPreview: View {
    let impact: CommitmentImpact
    let currency: String

    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: currency)
    }
    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    private func months(_ v: Double) -> String {
        v >= 12 ? String(format: loc("commit.years"), v / 12) : String(format: loc("commit.months"), v)
    }

    private var tint: Color {
        if impact.overflows { return AppTheme.red }
        return impact.shareAfter > 0.80 ? AppTheme.orange : AppTheme.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc("impact.title"))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AppTheme.textSecondary)
                .tracking(0.6)

            // The before → after, which is the whole point. A single "after"
            // figure tells you where you'd land but not what this choice moved.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pct(impact.shareBefore))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(pct(impact.shareAfter))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(tint)
                Text(loc("impact.of_bucket"))
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer(minLength: 0)
            }

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.cardMid).frame(height: 7)
                    // What was already there, then what this adds on top.
                    Capsule().fill(AppTheme.textSecondary.opacity(0.45))
                        .frame(width: g.size.width * min(impact.shareBefore, 1), height: 7)
                    Capsule().fill(tint)
                        .frame(width: g.size.width * min(impact.shareAfter, 1), height: 7)
                        .opacity(0.85)
                        .mask(alignment: .leading) {
                            Rectangle()
                                .padding(.leading, g.size.width * min(impact.shareBefore, 1))
                        }
                }
            }
            .frame(height: 7)

            Text(String(format: loc("impact.bucket_detail"),
                        impact.group.label,
                        money(impact.committedAfter),
                        money(impact.allowance)))
                .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if impact.overflows {
                Label(String(format: loc("impact.overflow"), money(impact.spillover)),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Priced in the thing they said they want.
            if impact.goalMonthsPerYear > 0.2, let goal = impact.goalName {
                Divider().overlay(AppTheme.cardMid)
                Text(String(format: loc("impact.goal_cost"),
                            months(impact.goalMonthsPerYear), goal))
                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.25), lineWidth: 1))
    }
}
