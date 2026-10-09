import UserNotifications
import SwiftUI
import SwiftData

// Moved out of DebtView.swift, unchanged. The cards and list pieces the Debt screen is built from.

// MARK: - All Debts (full-list page)
//
// Reached from the "See all" row when there are more than a few debts. Cards
// are self-contained (each drives its own actions/detail), so this page just
// re-lists them all in avalanche priority order.
struct AllDebtsView: View {
    let order: [DebtRecord]
    @Bindable var vm: DebtViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(order.enumerated()), id: \.element.id) { i, debt in
                            DebtCard(debt: debt, priority: i + 1, vm: vm)
                                .padding(.horizontal, 22)
                        }
                    }
                    .padding(.vertical, 16)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("debt.your_debts"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
    }
}

// MARK: - Salary Setup CTA (shared empty-state for income-based features)

/// Empty-state card shown by Smart Budget and Debt when no salary/income is
/// set for the current month — those features compute everything as a ratio of
/// income, so they're inert without it. Gives the user a clear one-tap path to
/// set up their salary rather than showing zeros or a silent blank.
struct SalarySetupCTA: View {
    let message: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.12)).frame(width: 56, height: 56)
                Image(systemName: "banknote.fill")
                    .font(.system(.title2))
                    .foregroundStyle(AppTheme.accent)
            }
            VStack(spacing: 6) {
                Text(loc("salary.cta.title"))
                    .font(.system(.callout, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(message)
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            Button {
                HapticManager.shared.tap()
                action()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.system(.subheadline))
                    Text(loc("salary.cta.button")).font(.system(.subheadline, weight: .bold))
                }
                .foregroundStyle(AppTheme.onVividFill)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).stroke(AppTheme.accent.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Summary

/// What you owe, what it costs a month, when it ends, and one verdict with one
/// piece of advice. Replaces a score out of 100, which asked the user to learn
/// a scale before it told them anything.
struct DebtSummaryCard: View {
    let engine: FinancialHealthEngine
    let monthlyIncome: Double
    /// Of the total: what credit cards carry. Said under the figure so the
    /// total can be traced to the cards listed further down.
    var cardOwed: Double = 0
    let debtFreeDate: Date?
    var showSimulator: Bool
    let onAdd: () -> Void
    let onSimulate: () -> Void

    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: CurrencyManager.shared.preferredCurrency)
    }

    private var verdict: String {
        monthlyIncome > 0
            ? String(format: loc("debt.verdict_dti"), engine.healthLabel,
                     String(format: "%.0f", engine.dtiRatio))
            : engine.healthLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc("debt.total_title"))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(money(engine.totalDebt))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.55)
                        .contentTransition(.numericText())
                    if cardOwed >= 0.5 {
                        Text(String(format: loc("debt.total_cards_note"), money(cardOwed)))
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.accentFill, in: Circle())
                }
                .accessibilityLabel(loc("a11y.add_debt"))
                .buttonStyle(ScaleButtonStyle())
            }

            HStack(spacing: 10) {
                fact("calendar", loc("debt.monthly_payments_label"), money(engine.totalEffectiveMinimums))
                if let date = debtFreeDate {
                    fact("flag.checkered", loc("debt.free_label"),
                         date.formatted(.dateTime.month(.abbreviated).year()))
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: engine.healthIcon)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(engine.healthColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verdict)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(monthlyIncome > 0 ? engine.primaryAdvice : loc("debt.health_sub"))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(engine.healthColor.opacity(0.10), in: RoundedRectangle(cornerRadius: AppRadius.md))

            if showSimulator {
                Button(action: onSimulate) {
                    Label(loc("debt.simulate"), systemImage: "chart.line.uptrend.xyaxis")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AppTheme.cardMid.opacity(0.7), in: RoundedRectangle(cornerRadius: AppRadius.md))
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }

    private func fact(_ icon: String, _ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
            Text(value)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.cardMid.opacity(0.5), in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

// MARK: - Due soon

/// Payments falling within a few days, each with its own Pay button — the list
/// only said what was due and left the user to find the debt to pay it.
struct DueSoonCard: View {
    let debts: [DebtRecord]
    let onPay: (DebtRecord) -> Void

    private func dueText(_ debt: DebtRecord) -> (String, Bool) {
        let today = Calendar.current.component(.day, from: .now)
        let diff = debt.dueDayOfMonth - today
        if diff == 0 { return (loc("debt.due_today"), true) }
        if diff > 0 { return (String(format: loc("debt.due_in_days"), diff), diff <= 1) }
        return (String(format: loc("debt.overdue_days"), -diff), true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc("debt.due_soon"))
                .font(.system(.body, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
            VStack(spacing: 0) {
                ForEach(Array(debts.enumerated()), id: \.element.id) { i, debt in
                    if i > 0 {
                        Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 66)
                    }
                    let due = dueText(debt)
                    HStack(spacing: 12) {
                        Image(systemName: debt.debtType.icon)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(debt.debtType.color)
                            .frame(width: 40, height: 40)
                            .background(debt.debtType.color.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(debt.name)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .lineLimit(1)
                            Text(due.0 + " · " + CurrencyManager.shared.formatted(debt.effectiveMinimumPayment, currency: debt.currency))
                                .font(.system(.caption))
                                .foregroundStyle(due.1 ? AppTheme.orange : AppTheme.textSecondary)
                                .lineLimit(1).minimumScaleFactor(0.85)
                        }
                        Spacer(minLength: 6)
                        Button { HapticManager.shared.tap(); onPay(debt) } label: {
                            Text(loc("debt.pay_short"))
                                .font(.system(.footnote, weight: .bold))
                                .foregroundStyle(AppTheme.onVividFill)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(AppTheme.accentFill, in: Capsule())
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
    }
}

// MARK: - Allocation Card

struct AllocationCard: View {
    let engine: FinancialHealthEngine
    let monthlyIncome: Double
    let totalBalance: Double
    
    /// Months of debt coverage if user paid only from current balance (no salary).
    /// Helps user see they have a safety net beyond just monthly salary.
    private var balanceCoversMonths: Double {
        guard engine.recommendedMonthlyDebtPayment > 0 else { return 0 }
        return totalBalance / engine.recommendedMonthlyDebtPayment
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(loc("salary.allocation")).font(.system(.body, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(loc("salary.per_month")).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
            }
            
            // Explainer — clarifies that this allocation is based on monthly
            // salary (not balance), and what the recommended split means.
            Text(loc("salary.allocation.explainer"))
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Three parts, not two. Committed money was previously folded into
            // "safe to spend", which is how a user with Rp 3,7jt of rent and
            // subscriptions was told 100% of income was free.
            GeometryReader { g in
                let debtPct = CGFloat(engine.recommendedDebtAllocationPercent / 100)
                let savePct = CGFloat(engine.setAsidePercent / 100)
                let commitPct = CGFloat(engine.commitmentPercent / 100)
                let spendPct = max(0, 1 - debtPct - savePct - commitPct)
                HStack(spacing: 2) {
                    if debtPct > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AppTheme.red.opacity(0.8))
                            .frame(width: g.size.width * debtPct, height: 12)
                    }
                    // The share the plan reserves for the future. Without this
                    // segment the 20% was invisible AND unspent-for.
                    if savePct > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AppTheme.blue.opacity(0.8))
                            .frame(width: g.size.width * savePct, height: 12)
                    }
                    if commitPct > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AppTheme.orange.opacity(0.8))
                            .frame(width: g.size.width * commitPct, height: 12)
                    }
                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppTheme.accent.opacity(0.6))
                        .frame(width: g.size.width * spendPct, height: 12)
                }
                .animation(.spring(response: 0.8, dampingFraction: 0.8), value: engine.recommendedDebtAllocationPercent)
            }
            .frame(height: 12)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                if engine.recommendedMonthlyDebtPayment > 0 {
                    AllocationRow(color: AppTheme.red.opacity(0.8),
                                  label: loc("debt.allocation.debt"),
                                  percent: engine.recommendedDebtAllocationPercent,
                                  amount: engine.recommendedMonthlyDebtPayment,
                                  currency: CurrencyManager.shared.preferredCurrency)
                }
                AllocationRow(color: AppTheme.blue.opacity(0.8),
                              label: loc("debt.allocation.save"),
                              percent: engine.setAsidePercent,
                              amount: engine.toSaveOrInvest,
                              currency: CurrencyManager.shared.preferredCurrency)
                AllocationRow(color: AppTheme.orange.opacity(0.8),
                              label: loc("debt.allocation.committed"),
                              percent: engine.commitmentPercent,
                              amount: engine.fixedCommitments,
                              currency: CurrencyManager.shared.preferredCurrency)
                AllocationRow(color: AppTheme.accent.opacity(0.6),
                              label: loc("debt.allocation.safe"),
                              percent: engine.safeSpendingPercent,
                              amount: engine.safeSpendingBudget,
                              currency: CurrencyManager.shared.preferredCurrency)
            }
            
            // Balance context — small chip showing how many months of debt
            // payments the user could cover from current cash if salary stopped.
            // Reframes the allocation in terms users actually relate to.
            if balanceCoversMonths > 0 && totalBalance > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "wallet.pass.fill").font(.system(.caption2)).foregroundStyle(AppTheme.accent)
                    Text(String(format: loc("debt.balance_coverage"),
                                CurrencyManager.shared.formatted(totalBalance, currency: CurrencyManager.shared.preferredCurrency),
                                String(format: "%.1f", balanceCoversMonths)))
                        .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            if engine.extraPaymentAvailable > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(.caption)).foregroundStyle(AppTheme.accent)
                    Text(String(format: loc("debt.extra_recommended"),
                                CurrencyManager.shared.formatted(engine.extraPaymentAvailable, currency: CurrencyManager.shared.preferredCurrency)))
                        .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }
}

struct AllocationRow: View {
    let color: Color; let label: String
    let percent: Double; let amount: Double; let currency: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
            }
            Text("\(String(format: "%.0f", percent))%").font(.system(.callout, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
            Text(CurrencyManager.shared.formatted(amount, currency: currency)).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
        }
    }
}

// MARK: - Debt Card

struct DebtCard: View {
    let debt: DebtRecord
    let priority: Int
    /// First in the payoff order while there is more than one debt.
    var payFirst: Bool = false
    @Bindable var vm: DebtViewModel
    @Environment(\.modelContext) private var modelContext
    @State private var showActions      = false
    @State private var showDelete       = false
    @State private var showPaymentSheet = false
    @State private var animatedProgress: Double = 0

    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: debt.currency)
    }

    /// One line of plan: the monthly payment, when that ends it, and what the
    /// interest costs meanwhile. Three separate columns of figures used to say
    /// this, each with its own label.
    private var planLine: String {
        var parts = [String(format: loc(debt.isMinimumDerived ? "debt.suggested_line" : "debt.min_line"),
                            money(debt.effectiveMinimumPayment))]
        if let date = debt.payoffDate {
            parts.append(String(format: loc("debt.free_around"),
                                date.formatted(.dateTime.month(.abbreviated).year())))
        }
        if debt.monthlyInterestCost > 0.5 {
            parts.append(String(format: loc("debt.interest_line"), money(debt.monthlyInterestCost)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: debt.debtType.icon)
                    .font(.system(.title3))
                    .foregroundStyle(debt.debtType.color)
                    .frame(width: 44, height: 44)
                    .background(debt.debtType.color.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(debt.name)
                            .font(.system(.body, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        if payFirst {
                            Text(loc("debt.pay_first"))
                                .font(.system(.caption2, weight: .bold))
                                .foregroundStyle(AppTheme.orange)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(AppTheme.orange.opacity(0.14), in: Capsule())
                                .lineLimit(1)
                        }
                    }
                    Text(debt.debtType.label + " · " + String(format: loc("debt.due_short"), debt.dueDayOfMonth))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer(minLength: 6)
                Button { HapticManager.shared.tap(); showActions = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.cardMid.opacity(0.7), in: Circle())
                }
                .accessibilityLabel(loc("a11y.more_actions"))
                .hitTarget(36)
                .buttonStyle(ScaleButtonStyle())
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(money(debt.currentBalance))
                        .font(.system(.title2, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    Text(String(format: loc("debt.left_of"), money(debt.totalAmount)))
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Text(String(format: loc("debt.paid_off"), String(format: "%.0f", debt.percentagePaid)))
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.accentTrack)
                        Capsule().fill(AppTheme.accentFill)
                            .frame(width: g.size.width * CGFloat(animatedProgress / 100))
                    }
                }
                .frame(height: 8)
                Text(planLine)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                HapticManager.shared.tap()
                showPaymentSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(.callout))
                    Text(loc("debt.make_payment")).font(.system(.subheadline, weight: .bold))
                }
                .foregroundStyle(AppTheme.onVividFill)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        .sheet(isPresented: $showActions) {
            ActionListSheet(
                icon: debt.debtType.icon,
                iconTint: debt.debtType.color,
                title: debt.name,
                subtitle: CurrencyManager.shared.formatted(debt.currentBalance, currency: debt.currency),
                items: [
                    ActionItem(icon: "banknote.fill", title: loc("debt.make_payment"), tint: AppTheme.accent) {
                        showPaymentSheet = true
                    },
                    ActionItem(icon: "pencil", title: loc("common.edit"), tint: AppTheme.blue) {
                        vm.loadForEdit(debt)
                    },
                    ActionItem(icon: "checkmark.seal.fill", title: loc("debt.mark_paid"),
                               detail: loc("debt.action.mark_paid_sub"), tint: AppTheme.teal) {
                        markPaid()
                    },
                    // Migration path: a debt that is really a credit card becomes
                    // a proper card account (spendable + owed tracking).
                    ActionItem(icon: "creditcard.fill", title: loc("cc.convert_action"),
                               detail: loc("cc.convert_action_sub"), tint: AppTheme.purple) {
                        convertToCreditCard()
                    },
                    ActionItem(icon: "trash.fill", title: loc("common.delete"), destructive: true) {
                        showDelete = true
                    },
                ])
            .preferredColorScheme(appColorScheme())
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).delay(0.2)) {
                animatedProgress = debt.percentagePaid
            }
        }
        .sheet(isPresented: $showPaymentSheet) {
            DebtPaymentSheet(debt: debt)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .confirmSheet(isPresented: $showDelete,
                      title: String(format: loc("debt.delete_title"), debt.name),
                      message: loc("debt.delete_confirm"),
                      confirmLabel: loc("common.delete")) {
            modelContext.delete(debt); try? modelContext.save()
        }
    }

    private func markPaid() {
        debt.currentBalance = 0; debt.isActive = false
        debt.manuallyClosed = true   // keep it closed; don't let sync revive it
        try? modelContext.save()
        HapticManager.shared.success()
        // Marking it paid by hand is still paying it off — same moment, same
        // celebration. Only the credit-card conversion is excluded.
        ActionFeedbackCenter.shared.celebrateDebtPayoff(
            name: debt.name, total: debt.totalAmount, currency: debt.currency,
            since: debt.createdAt, monthlyFreed: debt.minimumPayment)
    }

    /// Convert this debt into a real credit-card account, then close the debt so
    /// the same money isn't tracked twice. Limit defaults to the original total
    /// (an editable best-guess); owed carries over from the current balance.
    private func convertToCreditCard() {
        let existing = (try? modelContext.fetch(FetchDescriptor<BankCard>())) ?? []
        let g = BankIssuer.fallbackGradient(for: "5")
        let card = BankCard(
            holderName: debt.name, cardNumber: "", balance: 0, expireDate: "",
            gradientStart: g.start, gradientEnd: g.end,
            sortOrder: existing.count, currency: debt.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : debt.currency)
        card.isCreditCard = true
        card.creditLimit = max(debt.totalAmount, debt.currentBalance)
        card.openingOwed = debt.currentBalance
        card.creditSince = Date()
        modelContext.insert(card)
        // Close the debt (don't delete — keeps history), so it's not double-counted.
        // Deliberately NO payoff celebration here: the money hasn't been repaid,
        // it has moved to a credit card. Confetti would be a lie.
        debt.currentBalance = 0; debt.isActive = false; debt.manuallyClosed = true
        try? modelContext.save()
        HapticManager.shared.success()
    }
}

// MARK: - Debt Payoff Celebration
//
// Reaching a savings goal already gets confetti. Clearing a debt used to get a
// haptic buzz and silence — even though it is the harder of the two, and the
// one people spend years on. This gives it the same vocabulary as
// `GoalCelebration` (scrim, confetti, staggered springs, cascade haptic) so the
// app has one way of saying "well done" rather than two.
//
// The copy stays concrete: how long it took, and how much monthly cash just
// came back. A bare "Congratulations!" is a greeting card; the numbers are the
// reason to feel good.
struct DebtPayoffCelebration: View {
    let summary: ActionFeedbackCenter.DebtPayoffSummary
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 0.5
    @State private var opacity: Double = 0
    @State private var ring: CGFloat = 0.6
    @State private var ringFade: Double = 0.55

    var body: some View {
        ZStack {
            Color.black.opacity(0.78).ignoresSafeArea()

            ConfettiView()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 22) {
                ZStack {
                    // A ring that expands outward and fades — the visual echo
                    // of a weight being lifted.
                    Circle()
                        .stroke(AppTheme.accent.opacity(ringFade), lineWidth: 2)
                        .frame(width: 118, height: 118)
                        .scaleEffect(ring)
                    Circle()
                        .fill(AppTheme.accent.opacity(0.15))
                        .frame(width: 104, height: 104)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                .scaleEffect(scale)

                VStack(spacing: 9) {
                    Text(loc("debt.celebrate.title"))
                        .font(.system(.title, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(summary.name)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .multilineTextAlignment(.center)
                    Text(String(format: loc("debt.celebrate.paid"),
                                CurrencyManager.shared.formatted(summary.total, currency: summary.currency)))
                        .font(.system(.subheadline))
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)

                    // Two facts worth carrying away: the effort behind it, and
                    // the money it hands back every month from here on.
                    VStack(spacing: 5) {
                        Text(summary.monthsTaken >= 1
                             ? String(format: loc("debt.celebrate.took"), summary.monthsTaken)
                             : loc("debt.celebrate.took_one"))
                        if summary.monthlyFreed > 0.5 {
                            Text(String(format: loc("debt.celebrate.freed"),
                                        CurrencyManager.shared.formatted(summary.monthlyFreed, currency: summary.currency)))
                                .foregroundStyle(AppTheme.accent.opacity(0.9))
                        }
                    }
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                }
                .padding(.horizontal, 28)
                .scaleEffect(scale)
                .opacity(opacity)

                Button {
                    HapticManager.shared.success()
                    onDismiss()
                } label: {
                    Text(loc("debt.celebrate.cta"))
                        .font(.system(.callout, weight: .bold))
                        .foregroundStyle(AppTheme.bg)
                        .padding(.horizontal, 44).padding(.vertical, 15)
                        .background(AppTheme.accentFill, in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
                .scaleEffect(scale)
                .opacity(opacity)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { scale = 1.1 }
            withAnimation(.easeOut(duration: 1.1)) { ring = 1.55; ringFade = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { scale = 1.0; opacity = 1 }
            }
            for i in 0..<5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.08) {
                    HapticManager.shared.rigidImpact()
                }
            }
        }
    }
}

// MARK: - Payoff Strategy Card

struct PayoffStrategyCard: View {
    let engine: FinancialHealthEngine
    @State private var strategy = 0 // 0 = highest interest first, 1 = smallest balance first

    private var ordered: [DebtRecord] { strategy == 0 ? engine.avalancheOrder : engine.snowballOrder }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("debt.payoff_strat"))
                .font(.system(.body, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)

            // Plain names. "Avalanche" and "Snowball" are terms from personal-
            // finance blogs, in English, on a screen most people read in Indonesian.
            HStack(spacing: 2) {
                ForEach([0, 1], id: \.self) { i in
                    let on = strategy == i
                    Button {
                        HapticManager.shared.tap()
                        withAnimation(.spring(response: 0.3)) { strategy = i }
                    } label: {
                        Text(loc(i == 0 ? "debt.strategy_interest" : "debt.strategy_small"))
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(on ? AppTheme.textPrimary : AppTheme.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(on ? AppTheme.bg : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(AppTheme.cardMid.opacity(0.7), in: Capsule())

            Text(loc(strategy == 0 ? "debt.avalanche_desc" : "debt.snowball_desc"))
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { i, debt in
                    if i > 0 {
                        Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 40)
                    }
                    HStack(spacing: 12) {
                        Text("\(i + 1)")
                            .font(.system(.footnote, weight: .bold))
                            .foregroundStyle(i == 0 ? AppTheme.onVividFill : AppTheme.textSecondary)
                            .frame(width: 26, height: 26)
                            .background(i == 0 ? AppTheme.accentFill : AppTheme.cardMid.opacity(0.7), in: Circle())
                        Text(debt.name)
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(strategy == 0
                             ? String(format: loc("debt.apr_only"), String(format: "%.1f", debt.annualInterestRate))
                             : CurrencyManager.shared.formatted(debt.currentBalance, currency: debt.currency))
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.vertical, 10)
                }
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }
}

// MARK: - Empty State

struct DebtEmptyState: View {
    @Bindable var vm: DebtViewModel
    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.14)).frame(width: 120, height: 120)
                Circle().fill(AppTheme.accentFill).frame(width: 76, height: 76)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(.title, weight: .semibold))
                    .foregroundStyle(AppTheme.onVividFill)
            }
            VStack(spacing: 8) {
                Text(loc("debt.no_debts"))
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("debt.empty_desc"))
                    .font(.system(.subheadline))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { HapticManager.shared.tap(); vm.resetForm(); vm.showAddSheet = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.system(.body))
                    Text(loc("debt.add")).font(.system(.callout, weight: .bold))
                }
                .foregroundStyle(AppTheme.onVividFill)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 10)
    }
}
