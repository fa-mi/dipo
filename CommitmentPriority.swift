import SwiftUI
import SwiftData

// MARK: - Commitment priority
//
// What a recurring commitment costs, expressed in the thing the user actually
// said they want.
//
// A deliberate limit on what this does: it does NOT rank commitments by worth.
// "Is sending money to your mother better than Netflix" is not a question an
// app gets to answer — that is the user's to weigh, and an app that lectures
// about it is one they stop trusting on the numbers too.
//
// What it can do honestly is two things a person cannot easily do in their
// head:
//
//   • separate what is CHANGEABLE from what is not — a subscription can be
//     stopped tomorrow with no consequence; rent and family support cannot, at
//     least not without one. That is a factual distinction, not a moral one.
//   • price each one in goal-time — "Rp 200k/month is five weeks of Trip to
//     Mecca". That is arithmetic, and it is the number that actually changes a
//     decision.
//
// Then it stops talking and lets the user decide.
struct CommitmentLine: Identifiable {
    let id: UUID
    let label: String
    let monthly: Double
    let category: TxCategory
    /// Whether stopping it is a decision the user can simply make.
    let isDiscretionary: Bool
    /// Months of the savings goal this commitment's annual cost would fund.
    var goalMonthsEquivalent: Double
}

struct CommitmentReview {
    let lines: [CommitmentLine]
    let monthlyIncome: Double
    /// The goal being measured against, if the user has one.
    let goalName: String?
    let goalRemaining: Double
    let goalMonthly: Double
    /// Per-card budget overrides, so bucket allowances reflect the ratios the
    /// user actually configured rather than the global defaults.
    let configs: [CardBudgetConfig]

    /// Which Smart Budget bucket each commitment lands in, and how much of that
    /// bucket's allowance it has already used.
    ///
    /// This is the question a percentage of income cannot answer. "37% of
    /// income" sounds like a third of everything; what it actually means here is
    /// that ALL of it sits in Daily Needs — 74% of that bucket gone before a
    /// single meal, ojek or doctor's visit — while Lifestyle and Invest & Debt
    /// are untouched. Those are completely different situations and the single
    /// percentage hides which one you are in.
    struct BucketLoad: Identifiable {
        let id = UUID()
        let group: BudgetGroup
        let committed: Double
        let allowance: Double
        var share: Double { allowance > 0 ? committed / allowance : 0 }
    }

    var buckets: [BucketLoad] {
        let mgr = SmartBudgetManager.shared
        return BudgetGroup.allCases.map { g in
            let committed = lines
                .filter { mgr.group(for: $0.category) == g }
                .reduce(0.0) { $0 + $1.monthly }
            return BucketLoad(group: g, committed: committed,
                              allowance: mgr.monthlyLimit(for: g, income: monthlyIncome,
                                                          cardID: mgr.budgetCardID,
                                                          configs: configs))
        }
    }

    /// The bucket carrying the most of the load — what the headline should name.
    var heaviestBucket: BucketLoad? {
        buckets.filter { $0.committed > 0 }.max { $0.share < $1.share }
    }

    var total: Double { lines.reduce(0) { $0 + $1.monthly } }
    var discretionary: Double { lines.filter(\.isDiscretionary).reduce(0) { $0 + $1.monthly } }
    var contractual: Double { total - discretionary }
    var shareOfIncome: Double { monthlyIncome > 0 ? total / monthlyIncome : 0 }

    /// Months to the goal at the current contribution, and at that contribution
    /// plus everything discretionary. The gap between the two is the entire
    /// point of the card.
    var monthsAtCurrentPace: Double? {
        guard goalMonthly > 0, goalRemaining > 0 else { return nil }
        return goalRemaining / goalMonthly
    }
    var monthsIfRedirected: Double? {
        guard goalRemaining > 0, discretionary > 0 else { return nil }
        let pace = goalMonthly + discretionary
        guard pace > 0 else { return nil }
        return goalRemaining / pace
    }
    var monthsSaved: Double? {
        guard let a = monthsAtCurrentPace, let b = monthsIfRedirected else { return nil }
        return max(a - b, 0)
    }

    static func build(recurrings: [RecurringExpense],
                      salaries: [SalarySchedule],
                      goals: [SavingsGoal],
                      configs: [CardBudgetConfig],
                      currency: String) -> CommitmentReview {
        let cm = CurrencyManager.shared

        // Categories where stopping is simply a choice. `commitment` — rent,
        // family transfers, tuition — is deliberately NOT here: those carry
        // obligations to other people, and putting them on a "could cut" list
        // would be the app overstepping.
        let discretionaryCats: Set<TxCategory> = [.shopping, .travel, .other, .food]
        // Subscription-shaped names inside Bills. Electricity is a bill you
        // cannot stop; a streaming service is one you can.
        let subscriptionWords = ["netflix", "spotify", "youtube", "disney", "hbo", "prime",
                                 "icloud", "chatgpt", "claude", "canva", "adobe", "vidio",
                                 "wetv", "viu", "apple music", "langganan", "subscription"]

        var income = 0.0
        for s in salaries where s.isActive {
            income += cm.convert(s.amount, from: s.currency, to: currency)
        }

        let goal = goals.first { !$0.isCompleted }
        let remaining = goal.map { max(cm.convert($0.targetAmount - $0.savedAmount,
                                                  from: $0.currency, to: currency), 0) } ?? 0
        let goalMonthly = goal.map { cm.convert($0.monthlyContribution, from: $0.currency, to: currency) } ?? 0

        var lines: [CommitmentLine] = []
        for r in recurrings where r.isActive {
            let monthly = cm.convert(r.amount, from: r.currency, to: currency)
            let name = r.label.lowercased()
            let discretionary = discretionaryCats.contains(r.category)
                || subscriptionWords.contains { name.contains($0) }
            lines.append(CommitmentLine(
                id: r.id,
                label: r.label,
                monthly: monthly,
                category: r.category,
                isDiscretionary: discretionary,
                goalMonthsEquivalent: goalMonthly > 0 ? (monthly * 12) / goalMonthly : 0))
        }
        lines.sort { $0.monthly > $1.monthly }

        return CommitmentReview(lines: lines, monthlyIncome: income,
                                goalName: goal?.name, goalRemaining: remaining,
                                goalMonthly: goalMonthly, configs: configs)
    }
}

// MARK: - Card

struct CommitmentPriorityCard: View {
    let review: CommitmentReview
    let currency: String
    @State private var expanded = false

    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: currency)
    }
    private func months(_ v: Double) -> String {
        v >= 12 ? String(format: loc("commit.years"), v / 12) : String(format: loc("commit.months"), v)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13)).foregroundStyle(AppTheme.purple)
                Text(loc("commit.title"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(String(format: "%.0f%%", review.shareOfIncome * 100))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(review.shareOfIncome > 0.40 ? AppTheme.orange : AppTheme.textSecondary)
            }

            Text(String(format: loc("commit.summary"),
                        money(review.total), money(review.monthlyIncome)))
                .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Where that share actually lands. A percentage of income says
            // nothing about which part of the plan is under pressure.
            if let heavy = review.heaviestBucket, heavy.allowance > 0 {
                Text(String(format: loc("commit.bucket_headline"),
                            heavy.group.label,
                            String(format: "%.0f%%", heavy.share * 100)))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(heavy.share > 0.80 ? AppTheme.red
                                     : heavy.share > 0.60 ? AppTheme.orange : AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 7) {
                ForEach(review.buckets) { b in
                    if b.allowance > 0 {
                        VStack(spacing: 3) {
                            HStack {
                                Text(b.group.label)
                                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                Spacer()
                                Text("\(money(b.committed)) / \(money(b.allowance))")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(AppTheme.textPrimary)
                            }
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(AppTheme.cardMid).frame(height: 5)
                                    Capsule()
                                        .fill(b.share > 0.80 ? AppTheme.red
                                              : b.share > 0.60 ? AppTheme.orange : AppTheme.accent)
                                        .frame(width: g.size.width * min(b.share, 1), height: 5)
                                }
                            }
                            .frame(height: 5)
                        }
                    }
                }
            }

            // The trade-off, priced. Only shown when there is both a goal and
            // something changeable — without either there is no choice to offer.
            if let saved = review.monthsSaved, saved >= 0.5,
               let name = review.goalName, review.discretionary > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: loc("commit.goal_impact"),
                                money(review.discretionary), name, months(saved)))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let now = review.monthsAtCurrentPace, let then = review.monthsIfRedirected {
                        HStack(spacing: 6) {
                            Text(months(now)).font(.system(size: 11))
                                .foregroundStyle(AppTheme.textSecondary)
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AppTheme.textSecondary)
                            Text(months(then)).font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                }
                .padding(11)
                .background(AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }

            Button {
                HapticManager.shared.tap()
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(loc(expanded ? "commit.hide" : "commit.show"))
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(AppTheme.accent)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 8) {
                    ForEach(review.lines) { line in
                        HStack(spacing: 10) {
                            Image(systemName: line.category.icon)
                                .font(.system(size: 11)).foregroundStyle(line.category.color)
                                .frame(width: 26, height: 26)
                                .background(line.category.color.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                                Text(line.goalMonthsEquivalent > 0.2 && review.goalName != nil
                                     ? String(format: loc("commit.equals_goal"),
                                              months(line.goalMonthsEquivalent))
                                     : loc(line.isDiscretionary ? "commit.changeable" : "commit.fixed"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            Spacer(minLength: 6)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(money(line.monthly))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                Text(loc(line.isDiscretionary ? "commit.changeable" : "commit.fixed"))
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(line.isDiscretionary ? AppTheme.orange : AppTheme.textSecondary)
                            }
                        }
                        .padding(10)
                        .background(AppTheme.cardMid.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
                    }
                    Text(loc("commit.note"))
                        .font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
    }
}
