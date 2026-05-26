import UserNotifications
import SwiftUI
import SwiftData


// MARK: - Debt View (main screen)

struct DebtView: View {
    @Environment(\.modelContext) private var context
    @Query private var debts: [DebtRecord]
    @Query(sort: \SalarySchedule.createdAt) private var salaries: [SalarySchedule]
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    /// Direct tx query — fires onChange whenever a tx is added/deleted from
    /// anywhere in the app (Home, detail sheet, etc). Without this, deleting
    /// a debt-payment tx from Home would not propagate back to debt balances
    /// because @Query on parent BankCard doesn't observe child tx mutations.
    @Query private var allTransactions: [TxRecord]

    @State private var vm = DebtViewModel()
    @State private var appeared = false
    @State private var simulatorDebt: DebtRecord? = nil

    /// Total income this month, converted to preferred currency.
    /// Captures salary auto-credits, bonus, freelance — everything actually received.
    /// Conversion is essential: a card holding USD income mixed with IDR cards
    /// must not be summed as raw numbers.
    private var monthlyIncome: Double {
        let cal = Calendar.current
        let monthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: Date()))
        let pref = CurrencyManager.shared.preferredCurrency
        return cards.flatMap { $0.transactions }
            .filter { $0.amount > 0 && $0.date >= monthStart }
            .reduce(0) { sum, tx in
                let txCur = tx.currency.isEmpty ? pref : tx.currency
                return sum + CurrencyManager.shared.convert(tx.amount, from: txCur, to: pref)
            }
    }

    private var monthlyExpenses: Double {
        let allTx = cards.flatMap { $0.transactions }
        let cal = Calendar.current
        let now = Date()
        let pref = CurrencyManager.shared.preferredCurrency
        // Exclude debt payments — they are already factored into safeSpendingBudget
        // via recommendedMonthlyDebtPayment, so including them would double-count
        return allTx.filter {
            $0.amount < 0 &&
            $0.category != .debtPayment &&
            cal.component(.month, from: $0.date) == cal.component(.month, from: now) &&
            cal.component(.year,  from: $0.date) == cal.component(.year,  from: now)
        }.reduce(0) { sum, tx in
            let txCur = tx.currency.isEmpty ? pref : tx.currency
            return sum + CurrencyManager.shared.convert(abs(tx.amount), from: txCur, to: pref)
        }
    }
    
    /// Total cash on hand right now across all cards, in preferred currency.
    /// Used as a fallback context: if recommended debt payment exceeds this
    /// month's salary, the user needs to know whether they can cover it from
    /// existing balance — paying debt isn't only a salary game.
    private var totalBalance: Double {
        let pref = CurrencyManager.shared.preferredCurrency
        return cards.reduce(0) { sum, card in
            sum + CurrencyManager.shared.convert(card.balance, from: card.resolvedCurrency, to: pref)
        }
    }

    private var engine: FinancialHealthEngine {
        FinancialHealthEngine(monthlyIncome: monthlyIncome,
                              debts: debts,
                              monthlyExpenses: monthlyExpenses)
    }
    
    /// Recomputes each debt's `currentBalance` from its linked payment transactions.
    /// This is the rollback mechanism: when the user deletes a debt-payment tx from
    /// Home (or anywhere else), the debt's stored balance no longer matches reality.
    /// Calling this on appear / on tx-count-change brings them back in sync.
    ///
    /// Note: only debts that have at least one linked tx ever recorded against them
    /// are touched — debts with no linked txs (e.g. created before this feature, or
    /// with payments made through other channels) keep their manually-entered balance.
    private func syncDebtBalances() {
        let linkedDebtIDs = Set(allTransactions.compactMap { $0.linkedDebtID.isEmpty ? nil : $0.linkedDebtID })
        var didChange = false
        for debt in debts {
            let hasLinkedTx = linkedDebtIDs.contains(debt.id.uuidString)
            // Only sync if debt has linked txs OR has previously been synced.
            // hasBeenTracked flag prevents accidentally overwriting manual edits.
            guard hasLinkedTx || debt.hasBeenTracked else { continue }
            
            let trueBalance = debt.effectiveBalance(from: allTransactions)
            if abs(debt.currentBalance - trueBalance) > 0.01 {
                debt.currentBalance = trueBalance
                // Re-activate if user deleted a payment that had marked it paid
                if trueBalance > 0 && !debt.isActive {
                    debt.isActive = true
                }
                didChange = true
            }
            if hasLinkedTx && !debt.hasBeenTracked {
                debt.hasBeenTracked = true
                didChange = true
            }
        }
        if didChange { try? context.save() }
    }

    var body: some View {
        ZStack { AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc("debt.title_full")).font(.system(size: 24, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                            Text(loc("debt.smart_sub")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                        // Simulator button
                        if !debts.isEmpty {
                            Button {
                                HapticManager.shared.tap()
                                simulatorDebt = debts.filter { $0.isActive }.first
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "chart.line.uptrend.xyaxis")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(loc("debt.simulate"))
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(AppTheme.accent.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }
                        Button { HapticManager.shared.tap(); vm.resetForm(); vm.showAddSheet = true } label: {
                            ZStack {
                                Circle().fill(AppTheme.red.opacity(0.9)).frame(width: 42, height: 42)
                                    .shadow(color: AppTheme.red.opacity(0.4), radius: 10, y: 4)
                                Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            }
                        }.buttonStyle(ScaleButtonStyle())
                    }
                    .padding(.horizontal, 22).padding(.top, 20)
                    .opacity(appeared ? 1 : 0)

                    if debts.isEmpty {
                        DebtEmptyState(vm: vm).padding(.top, 50).opacity(appeared ? 1 : 0)
                    } else {
                        VStack(spacing: 16) {
                            // Financial Health Score
                            HealthScoreCard(engine: engine, monthlyIncome: monthlyIncome)
                                .padding(.horizontal, 22).padding(.top, 20)
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 20)
                                .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.08), value: appeared)

                            // Smart allocation
                            if monthlyIncome > 0 {
                                AllocationCard(engine: engine, monthlyIncome: monthlyIncome, totalBalance: totalBalance)
                                    .padding(.horizontal, 22)
                                    .opacity(appeared ? 1 : 0)
                                    .offset(y: appeared ? 0 : 20)
                                    .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.14), value: appeared)
                            }

                            // Overspending warning
                            if engine.isOverspending {
                                OverspendingWarning(engine: engine)
                                    .padding(.horizontal, 22)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }

                            // Urgent payments
                            if !engine.urgentDebts.isEmpty {
                                UrgentPaymentsCard(debts: engine.urgentDebts)
                                    .padding(.horizontal, 22)
                                    .opacity(appeared ? 1 : 0)
                                    .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.18), value: appeared)
                            }

                            // Debt list
                            VStack(spacing: 12) {
                                HStack {
                                    Text(loc("debt.your_debts")).font(.system(size: 17, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                    Spacer()
                                    Text("\(debts.filter { $0.isActive }.count) active")
                                        .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                                }
                                .padding(.horizontal, 22)

                                ForEach(Array(engine.avalancheOrder.enumerated()), id: \.element.id) { i, debt in
                                    DebtCard(debt: debt, priority: i + 1, vm: vm)
                                        .padding(.horizontal, 22)
                                        .opacity(appeared ? 1 : 0)
                                        .offset(y: appeared ? 0 : 24)
                                        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.22 + Double(i) * 0.06), value: appeared)
                                }
                            }

                            // Payoff Strategy
                            if debts.filter({ $0.isActive }).count > 1 {
                                PayoffStrategyCard(engine: engine)
                                    .padding(.horizontal, 22)
                                    .opacity(appeared ? 1 : 0)
                                    .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.3), value: appeared)
                            }
                        }
                    }
                    Spacer(minLength: 120)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { appeared = true }
            DebtNotificationScheduler.scheduleAll(debts: debts)
            // Sync each debt's stored currentBalance against the actual linked
            // payment txs in the DB. This catches the case where a user deleted
            // a payment tx from Home — without this sync the debt would still
            // show "paid off" progress that no longer matches reality.
            syncDebtBalances()
        }
        .onChange(of: debts) { _, newDebts in
            // Reschedule notifications whenever debts change
            DebtNotificationScheduler.scheduleAll(debts: newDebts)
        }
        .onChange(of: allTransactions.count) { _, _ in
            // Any tx added or deleted ANYWHERE (Home, detail sheets, etc) →
            // re-sync debt balances so progress stays in lockstep with the DB.
            // This is the rollback hook for "user deleted a debt-payment tx".
            syncDebtBalances()
        }
        .sheet(isPresented: $vm.showAddSheet, onDismiss: { vm.resetForm() }) {
            DebtFormSheet(vm: vm)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .sheet(item: $simulatorDebt) { debt in
            PayoffSimulatorSheet(debt: debt, allDebts: debts.filter { $0.isActive }, income: monthlyIncome)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
    }
}

// MARK: - Health Score Card

struct HealthScoreCard: View {
    let engine: FinancialHealthEngine
    let monthlyIncome: Double
    @State private var animScore = 0

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                // Score circle
                ZStack {
                    Circle().stroke(AppTheme.cardMid, lineWidth: 8).frame(width: 80, height: 80)
                    Circle()
                        .trim(from: 0, to: CGFloat(animScore) / 100)
                        .stroke(engine.healthColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 80, height: 80)
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 1.2, dampingFraction: 0.8), value: animScore)
                    VStack(spacing: 0) {
                        Text("\(animScore)").font(.system(size: 22, weight: .bold)).foregroundStyle(engine.healthColor)
                        Text("/ 100").font(.system(size: 9)).foregroundStyle(AppTheme.textSecondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: engine.healthIcon).font(.system(size: 16)).foregroundStyle(engine.healthColor)
                        Text(loc("debt.health")).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    }
                    Text(engine.healthLabel)
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(engine.healthColor)
                    if monthlyIncome <= 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 10))
                            Text(loc("debt.health_sub"))
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(AppTheme.orange)
                    } else {
                        Text(String(format: loc("debt.dti_label"), String(format: "%.1f", engine.dtiRatio)))
                            .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
                Spacer()
            }

            // Advice
            HStack(spacing: 10) {
                Image(systemName: "lightbulb.fill").font(.system(size: 14)).foregroundStyle(AppTheme.orange)
                Text(engine.primaryAdvice).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary).lineSpacing(2)
            }
            .padding(12)
            .background(AppTheme.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.orange.opacity(0.2), lineWidth: 1))
        }
        .padding(18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(engine.healthColor.opacity(0.2), lineWidth: 1))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                animScore = engine.healthScore
            }
        }
        .onChange(of: engine.healthScore) { _, newScore in
            withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) {
                animScore = newScore
            }
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
            HStack {
                Image(systemName: "chart.pie.fill").font(.system(size: 16)).foregroundStyle(AppTheme.accent)
                Text(loc("salary.allocation")).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(loc("salary.per_month")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
            }
            
            // Explainer — clarifies that this allocation is based on monthly
            // salary (not balance), and what the recommended split means.
            Text(loc("salary.allocation.explainer"))
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.textSecondary)
                .lineSpacing(2)

            // Visual split bar
            GeometryReader { g in
                let debtPct = CGFloat(engine.recommendedDebtAllocationPercent / 100)
                let spendPct = max(0, 1 - debtPct)
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppTheme.red.opacity(0.8))
                        .frame(width: g.size.width * debtPct, height: 12)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppTheme.accent.opacity(0.6))
                        .frame(width: g.size.width * spendPct, height: 12)
                }
                .animation(.spring(response: 0.8, dampingFraction: 0.8), value: engine.recommendedDebtAllocationPercent)
            }
            .frame(height: 12)

            HStack(spacing: 20) {
                AllocationRow(color: AppTheme.red.opacity(0.8),
                              label: loc("debt.allocation.debt"),
                              percent: engine.recommendedDebtAllocationPercent,
                              amount: engine.recommendedMonthlyDebtPayment,
                              currency: CurrencyManager.shared.preferredCurrency)
                AllocationRow(color: AppTheme.accent.opacity(0.6),
                              label: loc("debt.allocation.safe"),
                              percent: max(0, 100 - engine.recommendedDebtAllocationPercent),
                              amount: engine.safeSpendingBudget,
                              currency: CurrencyManager.shared.preferredCurrency)
            }
            
            // Balance context — small chip showing how many months of debt
            // payments the user could cover from current cash if salary stopped.
            // Reframes the allocation in terms users actually relate to.
            if balanceCoversMonths > 0 && totalBalance > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "wallet.pass.fill").font(.system(size: 11)).foregroundStyle(AppTheme.accent)
                    Text(String(format: loc("debt.balance_coverage"),
                                CurrencyManager.shared.formatted(totalBalance, currency: CurrencyManager.shared.preferredCurrency),
                                String(format: "%.1f", balanceCoversMonths)))
                        .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary).lineSpacing(2)
                }
                .padding(.top, 2)
            }

            if engine.extraPaymentAvailable > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 12)).foregroundStyle(AppTheme.accent)
                    Text(String(format: loc("debt.extra_recommended"),
                                CurrencyManager.shared.formatted(engine.extraPaymentAvailable, currency: CurrencyManager.shared.preferredCurrency)))
                        .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary).lineSpacing(2)
                }
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct AllocationRow: View {
    let color: Color; let label: String
    let percent: Double; let amount: Double; let currency: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
            }
            Text("\(String(format: "%.0f", percent))%").font(.system(size: 16, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
            Text(CurrencyManager.shared.formatted(amount, currency: currency)).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
        }
    }
}

// MARK: - Overspending Warning

struct OverspendingWarning: View {
    let engine: FinancialHealthEngine
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(AppTheme.red.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 20)).foregroundStyle(AppTheme.red)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("debt.overspending")).font(.system(size: 14, weight: .bold)).foregroundStyle(AppTheme.red)
                Text(String(format: loc("debt.reduce_expenses"),
                            CurrencyManager.shared.formatted(engine.overspendAmount, currency: CurrencyManager.shared.preferredCurrency)))
                    .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary).lineSpacing(2)
            }
            Spacer()
        }
        .padding(14)
        .background(AppTheme.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.red.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Urgent Payments Card

struct UrgentPaymentsCard: View {
    let debts: [DebtRecord]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill").font(.system(size: 14)).foregroundStyle(AppTheme.orange)
                Text(loc("debt.due_soon")).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
            }
            ForEach(debts) { debt in
                HStack {
                    Image(systemName: debt.debtType.icon).font(.system(size: 14)).foregroundStyle(debt.debtType.color)
                    Text(debt.name).font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Text(CurrencyManager.shared.formatted(debt.minimumPayment, currency: debt.currency))
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(AppTheme.orange)
                    if debt.minimumPayment == 0 {
                        Text(loc("debt.set_min"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppTheme.red)
                    }
                    Text(String(format: loc("debt.due_short"), debt.dueDayOfMonth)).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                }
                .padding(10)
                .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .background(AppTheme.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.orange.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Debt Card

struct DebtCard: View {
    let debt: DebtRecord
    let priority: Int
    @Bindable var vm: DebtViewModel
    @Environment(\.modelContext) private var modelContext
    @State private var showActions      = false
    @State private var showDelete       = false
    @State private var showPaymentSheet = false
    @State private var animatedProgress: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    // Priority badge + icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(debt.debtType.color.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: debt.debtType.icon)
                            .font(.system(size: 20)).foregroundStyle(debt.debtType.color)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(debt.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                            Text(debt.debtType.label).font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(debt.debtType.color)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(debt.debtType.color.opacity(0.12), in: Capsule())
                        }
                        Text(String(format: loc("debt.apr_due"),
                                    String(format: "%.1f", debt.annualInterestRate),
                                    debt.dueDayOfMonth))
                            .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()
                    // Priority tag
                    Text("#\(priority)").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(priority == 1 ? AppTheme.red : AppTheme.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(priority == 1 ? AppTheme.red.opacity(0.12) : AppTheme.cardMid, in: Capsule())
                    Button { HapticManager.shared.tap(); showActions = true } label: {
                        Image(systemName: "ellipsis").font(.system(size: 15))
                            .foregroundStyle(AppTheme.textSecondary).frame(width: 36, height: 36)
                            .background(AppTheme.cardMid, in: Circle())
                    }.buttonStyle(ScaleButtonStyle())
                }

                // Balance info
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(loc("debt.remaining")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        Text(CurrencyManager.shared.formatted(debt.currentBalance, currency: debt.currency))
                            .font(.system(size: 22, weight: .bold)).foregroundStyle(AppTheme.red)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(loc("debt.min_payment")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        Text(CurrencyManager.shared.formatted(debt.minimumPayment, currency: debt.currency))
                            .font(.system(size: 16, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(loc("debt.monthly_int")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        Text(CurrencyManager.shared.formatted(debt.monthlyInterestCost, currency: debt.currency))
                            .font(.system(size: 16, weight: .bold)).foregroundStyle(AppTheme.orange)
                    }
                }

                // Progress bar
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(String(format: loc("debt.paid_off"), String(format: "%.1f", debt.percentagePaid)))
                            .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        Spacer()
                        if let months = debt.monthsToPayoffMinimum {
                            Text("\(months) months to payoff")
                                .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(AppTheme.cardMid).frame(height: 6)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(LinearGradient(colors: [debt.debtType.color, debt.debtType.color.opacity(0.5)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: g.size.width * CGFloat(animatedProgress / 100), height: 6)
                        }
                    }.frame(height: 6)
                }
                // Make Payment button
                Button {
                    HapticManager.shared.tap()
                    showPaymentSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "dollarsign.circle.fill").font(.system(size: 15))
                        Text(loc("debt.make_payment")).font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        LinearGradient(colors: [debt.debtType.color, debt.debtType.color.opacity(0.7)],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .shadow(color: debt.debtType.color.opacity(0.3), radius: 8, y: 4)
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(16)
        }
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .stroke(priority == 1 ? AppTheme.red.opacity(0.3) : Color.clear, lineWidth: 1))
        .confirmationDialog(debt.name, isPresented: $showActions, titleVisibility: .visible) {
            Button(loc("debt.make_payment")) { showPaymentSheet = true }
            Button(loc("common.edit")) { vm.loadForEdit(debt) }
            Button(loc("debt.mark_paid"), role: .none) { markPaid() }
            Button(loc("common.delete"), role: .destructive) { showDelete = true }
            Button(loc("common.cancel"), role: .cancel) {}
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).delay(0.2)) {
                animatedProgress = debt.percentagePaid
            }
        }
        .sheet(isPresented: $showPaymentSheet) {
            DebtPaymentSheet(debt: debt)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .confirmationDialog(String(format: loc("debt.delete_title"), debt.name), isPresented: $showDelete, titleVisibility: .visible) {
            Button(loc("common.delete"), role: .destructive) {
                modelContext.delete(debt); try? modelContext.save()
            }
            Button(loc("common.cancel"), role: .cancel) {}
        }
    }

    private func markPaid() {
        debt.currentBalance = 0; debt.isActive = false
        try? modelContext.save()
        HapticManager.shared.success()
    }
}

// MARK: - Payoff Strategy Card

struct PayoffStrategyCard: View {
    let engine: FinancialHealthEngine
    @State private var strategy = 0 // 0 = avalanche, 1 = snowball

    private var ordered: [DebtRecord] { strategy == 0 ? engine.avalancheOrder : engine.snowballOrder }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "map.fill").font(.system(size: 14)).foregroundStyle(AppTheme.purple)
                Text(loc("debt.payoff_strat")).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Spacer()
            }

            // Strategy toggle
            HStack(spacing: 0) {
                ForEach(["Avalanche", "Snowball"].indices, id: \.self) { i in
                    Button { HapticManager.shared.tap(); withAnimation { strategy = i } } label: {
                        Text(i == 0 ? "Avalanche" : "Snowball")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(strategy == i ? AppTheme.bg : AppTheme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background { if strategy == i { Capsule().fill(AppTheme.purple) } }
                    }
                }
            }
            .padding(3).background(AppTheme.cardMid, in: Capsule())

            // Strategy description
            Text(strategy == 0
                 ? "Pay highest interest first. Mathematically optimal — saves the most money in interest."
                 : "Pay smallest balance first. Quick wins keep you motivated.")
                .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary).lineSpacing(2)

            // Order list
            VStack(spacing: 8) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { i, debt in
                    HStack(spacing: 10) {
                        Text("\(i+1)").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.textSecondary).frame(width: 20)
                        Image(systemName: debt.debtType.icon).font(.system(size: 14)).foregroundStyle(debt.debtType.color)
                        Text(debt.name).font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                        Text(strategy == 0
                             ? String(format: loc("debt.apr_only"), String(format: "%.1f", debt.annualInterestRate))
                             : CurrencyManager.shared.formatted(debt.currentBalance, currency: debt.currency))
                            .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(10).background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Empty State

struct DebtEmptyState: View {
    @Bindable var vm: DebtViewModel
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(AppTheme.cardDark).frame(width: 88, height: 88)
                    .overlay(Circle().stroke(AppTheme.accent.opacity(0.2), lineWidth: 1))
                Image(systemName: "checkmark.seal.fill").font(.system(size: 36)).foregroundStyle(AppTheme.accent)
            }
            .gentleFloat()
            VStack(spacing: 8) {
                Text(loc("debt.no_debts")).font(.system(size: 18, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Text(loc("debt.empty_desc"))
                    .font(.system(size: 14)).foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
            }
            Button { HapticManager.shared.tap(); vm.resetForm(); vm.showAddSheet = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                    Text(loc("debt.add")).font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white).padding(.horizontal, 32).padding(.vertical, 14)
                .background(AppTheme.red.opacity(0.9), in: Capsule())
                .shadow(color: AppTheme.red.opacity(0.35), radius: 12, y: 6)
            }.buttonStyle(ScaleButtonStyle())
        }.padding(.horizontal, 40)
    }
}

// MARK: - Debt Form Sheet

struct DebtFormSheet: View {
    @Bindable var vm: DebtViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            ZStack { AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        // Type picker
                        VStack(spacing: 8) {
                            Text(loc("debt.type")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(DebtType.allCases, id: \.self) { type in
                                        Button { HapticManager.shared.tap(); vm.formType = type } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: type.icon).font(.system(size: 13))
                                                Text(type.label).font(.system(size: 13, weight: .medium))
                                            }
                                            .foregroundStyle(vm.formType == type ? AppTheme.bg : AppTheme.textSecondary)
                                            .padding(.horizontal, 14).padding(.vertical, 9)
                                            .background(vm.formType == type ? type.color : AppTheme.cardDark, in: Capsule())
                                        }.buttonStyle(ScaleButtonStyle())
                                    }
                                }.padding(.horizontal, 22)
                            }
                        }
                        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 20)

                        SheetField(label: loc("savings.description"), placeholder: loc("debt.description_placeholder"), text: $vm.formName)
                            .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.08), value: appeared)

                        // Balance fields
                        HStack(spacing: 12) {
                            VStack(spacing: 8) {
                                Text(loc("cards.current_balance")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                TextField("0", text: $vm.formBalance).font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(AppTheme.red).keyboardType(.decimalPad)
                                    .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                    .onChange(of: vm.formBalance) { _, v in
                                        let n = v.replacingOccurrences(of: ",", with: ".")
                                        let f = n.filter { $0.isNumber || $0 == "." }
                                        if f != v { vm.formBalance = f }
                                    }
                                // Live formatted preview — helps user catch
                                // wrong digit count (typing 5000 vs 50000).
                                if let p = AmountInputHelper.preview(vm.formBalance, currency: vm.formCurrency) {
                                    Text(p)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            VStack(spacing: 8) {
                                Text(loc("debt.min_payment")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                TextField("0", text: $vm.formMinPayment).font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(AppTheme.textPrimary).keyboardType(.decimalPad)
                                    .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                    .onChange(of: vm.formMinPayment) { _, v in
                                        let n = v.replacingOccurrences(of: ",", with: ".")
                                        let f = n.filter { $0.isNumber || $0 == "." }
                                        if f != v { vm.formMinPayment = f }
                                    }
                                if let p = AmountInputHelper.preview(vm.formMinPayment, currency: vm.formCurrency) {
                                    Text(p)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.12), value: appeared)

                        // Interest + Due day
                        HStack(spacing: 12) {
                            VStack(spacing: 8) {
                                Text(loc("debt.annual_int")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                TextField("0.0", text: $vm.formInterestRate).font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(AppTheme.orange).keyboardType(.decimalPad)
                                    .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                    .onChange(of: vm.formInterestRate) { _, v in
                                        // Normalize comma → dot for locales that use comma as decimal
                                        let normalized = v.replacingOccurrences(of: ",", with: ".")
                                        // Allow only digits and one dot
                                        let filtered = normalized.filter { $0.isNumber || $0 == "." }
                                        let dotCount = filtered.filter { $0 == "." }.count
                                        if dotCount > 1 {
                                            // Keep only first dot
                                            var seenDot = false
                                            vm.formInterestRate = String(filtered.filter { c in
                                                if c == "." { if seenDot { return false }; seenDot = true }
                                                return true
                                            })
                                        } else if filtered != v {
                                            vm.formInterestRate = filtered
                                        }
                                    }
                            }
                            VStack(spacing: 8) {
                                Text(loc("debt.due_day")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                // 44×44pt is Apple HIG's minimum tap target.
                                // Buttons were 36×36 — usable but missed
                                // accurately on smaller screens, especially
                                // for users with larger fingers / thumbs.
                                HStack(spacing: 0) {
                                    Button { HapticManager.shared.tap(); if vm.formDueDay > 1 { vm.formDueDay -= 1 } } label: {
                                        Image(systemName: "minus").font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(AppTheme.textPrimary).frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    Text("\(vm.formDueDay)").font(.system(size: 18, weight: .bold)).foregroundStyle(AppTheme.textPrimary).frame(width: 40)
                                        .contentTransition(.numericText())
                                    Button { HapticManager.shared.tap(); if vm.formDueDay < 31 { vm.formDueDay += 1 } } label: {
                                        Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(AppTheme.textPrimary).frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                }
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.16), value: appeared)

                        // Currency
                        VStack(spacing: 8) {
                            Text(loc("common.currency")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(vm.currencies, id: \.self) { c in
                                        Button { HapticManager.shared.tap(); vm.formCurrency = c } label: {
                                            Text(c).font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(vm.formCurrency == c ? AppTheme.bg : AppTheme.textSecondary)
                                                .padding(.horizontal, 16).padding(.vertical, 8)
                                                .background(vm.formCurrency == c ? AppTheme.accent : AppTheme.cardDark, in: Capsule())
                                        }.buttonStyle(ScaleButtonStyle())
                                    }
                                }.padding(.horizontal, 22)
                            }
                        }
                        .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)

                        // Payoff preview
                        if let bal = Double(vm.formBalance.replacingOccurrences(of: ",", with: ".")),
                           let minPay = Double(vm.formMinPayment.replacingOccurrences(of: ",", with: ".")),
                           let rate = Double(vm.formInterestRate.replacingOccurrences(of: ",", with: ".")), bal > 0, minPay > 0 {
                            let previewDebt = DebtRecord(name: "Preview", totalAmount: bal, currentBalance: bal,
                                                          minimumPayment: minPay, annualInterestRate: rate, dueDayOfMonth: 1)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(loc("debt.payoff_preview")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                HStack(spacing: 20) {
                                    if let m = previewDebt.monthsToPayoffMinimum {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(m) months").font(.system(size: 16, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                            Text(loc("debt.at_min")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                        }
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(CurrencyManager.shared.formatted(previewDebt.totalInterestAtMinimum, currency: vm.formCurrency))
                                            .font(.system(size: 16, weight: .bold)).foregroundStyle(AppTheme.orange)
                                        Text(loc("debt.total_int")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                            }
                            .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 22)
                            .opacity(appeared ? 1 : 0)
                        }

                        if let err = vm.formError {
                            InlineBanner(tone: .error, message: err)
                                .padding(.horizontal, 22)
                                .transition(.opacity)
                        }

                        // Form-validity: name + positive balance + positive
                        // Only `name` and `balance > 0` are strictly required.
                        // Minimum payment was previously gated to >0, but
                        // legit debts can have no fixed minimum (e.g., credit
                        // card before first statement, informal loan from
                        // family, fully-paid annuity installment). The engine
                        // handles min=0 gracefully — DTI calc just doesn't
                        // count it. Interest defaults to 0 for interest-free
                        // installments. Due day is always 1-31 so it can't
                        // be invalid. Same minimal-validation shape as
                        // WishlistView.
                        let canSave: Bool = {
                            let nameOK = !vm.formName.trimmingCharacters(in: .whitespaces).isEmpty
                            let balOK  = (Double(vm.formBalance.replacingOccurrences(of: ",", with: ".")) ?? 0) > 0
                            return nameOK && balOK
                        }()
                        Button { save() } label: {
                            Text(vm.isEditing ? loc("general.edit") : loc("debt.add"))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(canSave ? .white : AppTheme.textSecondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(canSave ? AppTheme.red.opacity(0.9) : AppTheme.textSecondary.opacity(0.3), in: Capsule())
                                .shadow(color: canSave ? AppTheme.red.opacity(0.35) : .clear, radius: 12, y: 6)
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .disabled(!canSave)
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.24), value: appeared)

                        Spacer(minLength: 40)
                    }.padding(.top, 8)
                }
            }
            .navigationTitle(vm.isEditing ? loc("debt.edit") : loc("debt.add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { HapticManager.shared.tap(); dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }

            }
        }
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) { appeared = true } }
    }

    private func save() {
        guard vm.validate() else { HapticManager.shared.error(); return }
        // Normalize comma → dot for locale-safe parsing
        let normalize: (String) -> String = { $0.replacingOccurrences(of: ",", with: ".") }
        let bal   = Double(normalize(vm.formBalance)) ?? 0
        let min   = Double(normalize(vm.formMinPayment)) ?? 0
        let rate  = Double(normalize(vm.formInterestRate)) ?? 0
        let total = Double(normalize(vm.formTotal)).flatMap { $0 > 0 ? $0 : nil } ?? bal

        if let existing = vm.editingDebt {
            existing.name = vm.formName.trimmingCharacters(in: .whitespaces)
            existing.debtType = vm.formType; existing.currentBalance = bal
            existing.totalAmount = total; existing.minimumPayment = min
            existing.annualInterestRate = rate; existing.dueDayOfMonth = vm.formDueDay
            existing.currency = vm.formCurrency; existing.notes = vm.formNotes
        } else {
            let debt = DebtRecord(name: vm.formName.trimmingCharacters(in: .whitespaces),
                                  type: vm.formType.rawValue, totalAmount: total,
                                  currentBalance: bal, minimumPayment: min,
                                  annualInterestRate: rate, dueDayOfMonth: vm.formDueDay,
                                  currency: vm.formCurrency, notes: vm.formNotes)
            modelContext.insert(debt)
        }
        try? modelContext.save()
        HapticManager.shared.success()
        dismiss()
    }
}

// MARK: - Debt Payment Sheet

struct DebtPaymentSheet: View {
    @Bindable var debt: DebtRecord
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]

    @State private var amountText   = ""
    @State private var selectedCardIndex = 0
    @State private var note         = ""
    @State private var errorMsg: String? = nil

    private var amount: Double { Double(amountText) ?? 0 }

    private var selectedCard: BankCard? {
        guard !cards.isEmpty else { return nil }
        return cards[min(selectedCardIndex, cards.count - 1)]
    }

    private var activeCurrency: String {
        selectedCard.map { $0.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : $0.currency } ?? debt.currency
    }

    // Amount entered in card currency converted to debt currency
    private var amountInDebtCurrency: Double {
        CurrencyManager.shared.convert(amount, from: activeCurrency, to: debt.currency)
    }

    // Card raw balance in card's own currency
    private func cardRawBalance(_ card: BankCard) -> Double {
        let cardCur = card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
        return card.balance + card.transactions.reduce(0.0) { sum, tx in
            sum + CurrencyManager.shared.convert(tx.amount, from: tx.currency, to: cardCur)
        }
    }

    // Available balance in card currency
    private var availableBalance: Double { selectedCard.map { cardRawBalance($0) } ?? 0 }

    private var wouldGoNegative: Bool { amount > availableBalance }

    private var currencyMismatch: Bool {
        guard let card = selectedCard else { return false }
        let cardCur = card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
        return cardCur != debt.currency
    }

    private var isValid: Bool {
        amount > 0 && amountInDebtCurrency <= debt.currentBalance && !wouldGoNegative
    }

    var body: some View {
        VStack(spacing: 0) {
            // Handle
            RoundedRectangle(cornerRadius: 3)
                .fill(AppTheme.cardMid).frame(width: 36, height: 4).padding(.top, 12)

            // Debt summary
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(debt.debtType.color.opacity(0.15)).frame(width: 48, height: 48)
                    Image(systemName: debt.debtType.icon)
                        .font(.system(size: 22)).foregroundStyle(debt.debtType.color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(debt.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    Text(String(
                        format: loc("debt.balance"),
                        CurrencyManager.shared.formatted(
                            debt.currentBalance,
                            currency: debt.currency
                        )
                    ))
                        .font(.system(size: 13)).foregroundStyle(AppTheme.red)
                    Text(String(
                        format: loc("debt.minimum_payment"),
                        CurrencyManager.shared.formatted(
                            debt.minimumPayment,
                            currency: debt.currency
                        )
                    ))
                        .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 20)

            Divider().padding(.horizontal, 22)

            // Quick amounts
            VStack(spacing: 10) {
                Text(loc("debt.payment_amt")).font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Minimum
                        QuickPayButton(
                            label: loc("debt.min_only"),
                            amount: debt.minimumPayment,
                            currency: debt.currency,
                            color: AppTheme.orange
                        ) { amountText = String(debt.minimumPayment) }

                        // Full balance
                        QuickPayButton(
                            label: loc("debt.payoff"),
                            amount: debt.currentBalance,
                            currency: debt.currency,
                            color: AppTheme.accent
                        ) { amountText = String(debt.currentBalance) }

                        // Double minimum
                        if debt.minimumPayment * 2 < debt.currentBalance {
                            QuickPayButton(
                                label: "2x min",
                                amount: debt.minimumPayment * 2,
                                currency: debt.currency,
                                color: AppTheme.blue
                            ) { amountText = String(debt.minimumPayment * 2) }
                        }
                    }
                    .padding(.horizontal, 22)
                }

                // Custom amount
                HStack(spacing: 8) {
                    Text(activeCurrency)
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(debt.debtType.color)
                    TextField("0", text: $amountText)
                        .font(.system(size: 28, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                        .keyboardType(.decimalPad)
                }
                .padding(16)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(amount > 0 ? debt.debtType.color.opacity(0.4) : Color.clear, lineWidth: 1.5))
                .padding(.horizontal, 22)

                // Remaining after payment preview
                if amount > 0 && amountInDebtCurrency <= debt.currentBalance {
                    let remaining = debt.currentBalance - amountInDebtCurrency
                    HStack(spacing: 8) {
                        Image(systemName: remaining == 0 ? "checkmark.seal.fill" : "minus.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(remaining == 0 ? AppTheme.accent : AppTheme.textSecondary)
                        Text(remaining == 0
                             ? String(format: loc("debt.payoff_full"), debt.name)
                             : String(format: loc("debt.remaining"), CurrencyManager.shared.formatted(remaining, currency: debt.currency)))
                            .font(.system(size: 13))
                            .foregroundStyle(remaining == 0 ? AppTheme.accent : AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 22)
                    .transition(.opacity)
                }

                // Insufficient balance warning
                if amount > 0 && wouldGoNegative {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13)).foregroundStyle(AppTheme.red)
                        Text(String(format: loc("debt.insufficient_balance"), CurrencyManager.shared.formatted(availableBalance, currency: activeCurrency)))
                            .font(.system(size: 13)).foregroundStyle(AppTheme.red)
                    }
                    .padding(.horizontal, 22)
                    .transition(.opacity)
                }

                // Currency mismatch — show equivalent in debt currency
                if currencyMismatch && amount > 0 {
                    let cardCur = activeCurrency
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12)).foregroundStyle(AppTheme.orange)
                        Text("≈ \(CurrencyManager.shared.formatted(amountInDebtCurrency, currency: debt.currency)) in \(debt.currency)")
                            .font(.system(size: 12)).foregroundStyle(AppTheme.orange)
                        Text("(\(cardCur) → \(debt.currency))")
                            .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 22)
                    .transition(.opacity)
                }
            }

            // Card picker (deduct from which account)
            if cards.count > 1 {
                Divider().padding(.horizontal, 22).padding(.vertical, 4)
                VStack(spacing: 8) {
                    Text(loc("debt.pay_from")).font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                                let network = CardNetwork.detect(from: card.cardNumber)
                                let cardCur = card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
                                let rawBal  = card.balance + card.transactions.reduce(0.0) { sum, tx in
                                    sum + CurrencyManager.shared.convert(tx.amount, from: tx.currency, to: cardCur)
                                }
                                let hasMismatch = cardCur != debt.currency
                                Button { HapticManager.shared.tap(); selectedCardIndex = i } label: {
                                    VStack(spacing: 4) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(LinearGradient(
                                                    colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                                                    startPoint: .leading, endPoint: .trailing))
                                                .frame(width: 80, height: 48)
                                                .overlay(RoundedRectangle(cornerRadius: 8)
                                                    .stroke(selectedCardIndex == i ? AppTheme.accent : Color.clear, lineWidth: 2))
                                            VStack(spacing: 2) {
                                                Text(card.isDigitalWallet
                                                     ? (card.walletProvider.isEmpty ? loc("cards.wallet") : card.walletProvider)
                                                     : "•••• \(card.cardNumber.suffix(4))")
                                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                                                Text(card.isDigitalWallet ? loc("cards.wallet") : network.name)
                                                    .font(.system(size: 8)).foregroundStyle(.white.opacity(0.6))
                                            }
                                        }
                                        Text(CurrencyManager.shared.formatted(rawBal, currency: cardCur))
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(selectedCardIndex == i ? AppTheme.accent : AppTheme.textSecondary)
                                        if hasMismatch {
                                            Text(loc("tx.auto_convert"))
                                                .font(.system(size: 8))
                                                .foregroundStyle(AppTheme.orange)
                                        }
                                    }
                                }
                                .buttonStyle(ScaleButtonStyle())
                            }
                        }
                        .padding(.horizontal, 22)
                    }
                }
            }

            Divider().padding(.horizontal, 22).padding(.top, 8)

            if let err = errorMsg {
                Text(err).font(.system(size: 13)).foregroundStyle(AppTheme.red).padding(.horizontal, 22)
            }

            // Pay button
            Button { makePayment() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "dollarsign.circle.fill").font(.system(size: 16))
                    Text(amount > 0 ? String(format: loc("debt.pay"), CurrencyManager.shared.formatted(amount, currency: activeCurrency)) : loc("debt.enter_amount"))
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(isValid ? .white : AppTheme.textSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(
                    isValid
                    ? AnyShapeStyle(LinearGradient(colors: [debt.debtType.color, debt.debtType.color.opacity(0.7)],
                                                   startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(AppTheme.cardMid),
                    in: Capsule()
                )
                .shadow(color: isValid ? debt.debtType.color.opacity(0.4) : .clear, radius: 12, y: 6)
            }
            .buttonStyle(ScaleButtonStyle()).disabled(!isValid).padding(.horizontal, 22)
            .padding(.top, 8)

            Spacer()
        }
        .animation(.spring(response: 0.3), value: selectedCardIndex)
        .animation(.spring(response: 0.3), value: amount)
        // When user switches card, reset amount so they don't accidentally pay wrong amount in wrong currency
        .onChange(of: selectedCardIndex) { _, _ in amountText = "" }
    }

    private func makePayment() {
        guard isValid else {
            errorMsg = wouldGoNegative ? loc("debt.insufficient_balance_card") : loc("debt.enter_amount")
            HapticManager.shared.error(); return
        }
        guard !cards.isEmpty else { errorMsg = loc("debt.empty_card"); return }

        let card = cards[min(selectedCardIndex, cards.count - 1)]
        let cardCur = card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
        
        let source = CurrencyManager.shared.formatted(amount, currency: activeCurrency)
        let target = CurrencyManager.shared.formatted(amountInDebtCurrency, currency: debt.currency)

        // 1. Record expense on card in card's currency (amount is already in card currency)
        // ⚠️ NEVER store loc(...) output in SwiftData — it freezes the string in whichever
        // language was active at creation time, so switching languages later leaves old
        // transactions stuck in the old language. Store stable keys instead; translation
        // happens at render time via TxRecord.displayType / displayNotes.
        let tx = TxRecord(
            name: String(format: loc("debt.payment_name"), debt.name),
            date: .now,
            amount: -amount,
            type: "tx.type.debt_payment",   // stable key — resolved at display time
            icon: "💳",
            iconBgHex: TxCategory.debtPayment.iconBg,
            category: .debtPayment,
            currency: cardCur,
            notes: currencyMismatch
                ? String(
                    format: loc("tx.note.debt_payment_conversion"),
                    source,
                    target)   // pre-formatted (language at create time persists — known limitation for format-string notes)
                : "tx.note.debt_payment_auto",   // stable key
            linkedDebtID: debt.id.uuidString  // ← link tx to debt for auto-rollback on delete
        )
        card.transactions.append(tx)

        // 2. Sync currentBalance to match the new effective balance.
        // currentBalance is now a denormalized cache of effectiveBalance — kept
        // in sync here for any code path that still reads it directly. The UI
        // should prefer effectiveBalance() which is always correct.
        try? context.save()  // save tx first so it appears in subsequent fetch
        debt.currentBalance = max(debt.currentBalance - amountInDebtCurrency, 0)
        debt.hasBeenTracked = true  // mark this debt as managed by linked txs

        // 3. Mark paid if balance reaches zero
        if debt.currentBalance == 0 {
            debt.isActive = false
            HapticManager.shared.rigidImpact()
        } else {
            HapticManager.shared.success()
        }

        try? context.save()
        dismiss()
    }
}

struct QuickPayButton: View {
    let label: String
    let amount: Double
    let currency: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: { HapticManager.shared.tap(); action() }) {
            VStack(spacing: 3) {
                Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                Text(CurrencyManager.shared.formatted(amount, currency: currency))
                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(color.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Payoff Simulator Sheet

struct PayoffSimulatorSheet: View {
    let debt: DebtRecord
    let allDebts: [DebtRecord]
    let income: Double
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDebt: DebtRecord
    @State private var extraPayment: Double = 0
    @State private var extraPaymentText: String = ""

    init(debt: DebtRecord, allDebts: [DebtRecord], income: Double) {
        self.debt = debt
        self.allDebts = allDebts
        self.income = income
        self._selectedDebt = State(initialValue: debt)
    }

    private var currency: String { selectedDebt.currency }
    private var fmt: (Double) -> String { { CurrencyManager.shared.formatted($0, currency: currency) } }
    
    /// Renders a quick-add chip label like "+100rb" / "+1jt" (Indonesian) or
    /// "+100K" / "+1M" (English) using the app's currently-selected language
    /// rather than the device locale. Adds the "+" sign so it's clear these
    /// add to the existing extra-payment amount.
    private func quickChipLabel(_ amt: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = LanguageManager.shared.currentLocale
        formatter.usesGroupingSeparator = true
        // For values >= 1000, use compact notation in the right language.
        // We do this manually because NumberFormatter's compact style behaves
        // inconsistently across locales — explicit suffixes are predictable.
        let lang = LanguageManager.shared.current.rawValue
        let useID = (lang == "id")
        let suffix: (String, String) = useID ? ("rb", "jt") : ("K", "M")
        let absAmt = abs(amt)
        let label: String
        if absAmt >= 1_000_000 {
            let v = Double(absAmt) / 1_000_000
            label = (v.truncatingRemainder(dividingBy: 1) == 0)
                ? "\(Int(v))\(suffix.1)"
                : String(format: "%.1f%@", v, suffix.1)
        } else if absAmt >= 1_000 {
            let v = Double(absAmt) / 1_000
            label = (v.truncatingRemainder(dividingBy: 1) == 0)
                ? "\(Int(v))\(suffix.0)"
                : String(format: "%.1f%@", v, suffix.0)
        } else {
            label = "\(absAmt)"
        }
        return (amt >= 0 ? "+" : "-") + label
    }

    private var baseMonths: Int?    { selectedDebt.monthsToPayoff(monthlyPayment: selectedDebt.minimumPayment) }
    private var boostedMonths: Int? {
        guard extraPayment > 0 else { return baseMonths }
        return selectedDebt.monthsToPayoff(monthlyPayment: selectedDebt.minimumPayment + extraPayment)
    }
    private var monthsSaved: Int {
        guard let b = baseMonths, let bst = boostedMonths else { return 0 }
        return max(b - bst, 0)
    }
    private var interestSaved: Double {
        let baseInterest = (selectedDebt.minimumPayment * Double(baseMonths ?? 0)) - selectedDebt.currentBalance
        let boostedInterest = ((selectedDebt.minimumPayment + extraPayment) * Double(boostedMonths ?? 0)) - selectedDebt.currentBalance
        return max(baseInterest - boostedInterest, 0)
    }
    private var payoffDateBase: String {
        guard let m = baseMonths else { return "N/A" }
        let date = Calendar.current.safeDate(byAdding: .month, value: m, to: .now)
        let fmt = DateFormatter(); fmt.dateFormat = "MMM yyyy"
        return fmt.string(from: date)
    }
    private var payoffDateBoosted: String {
        guard let m = boostedMonths else { return "N/A" }
        let date = Calendar.current.safeDate(byAdding: .month, value: m, to: .now)
        let fmt = DateFormatter(); fmt.dateFormat = "MMM yyyy"
        return fmt.string(from: date)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {

                        // Debt picker
                        if allDebts.count > 1 {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(loc("debt.select_debt"))
                                    .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(allDebts) { d in
                                            Button {
                                                HapticManager.shared.tap()
                                                withAnimation(.spring(response: 0.3)) { selectedDebt = d }
                                            } label: {
                                                Text(d.name)
                                                    .font(.system(size: 13, weight: selectedDebt.id == d.id ? .semibold : .regular))
                                                    .foregroundStyle(selectedDebt.id == d.id ? AppTheme.bg : AppTheme.textPrimary)
                                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                                    .background(selectedDebt.id == d.id ? AppTheme.accent : AppTheme.cardMid,
                                                                in: Capsule())
                                            }.buttonStyle(ScaleButtonStyle())
                                        }
                                    }.padding(.horizontal, 22)
                                }
                            }
                            .padding(.top, 4)
                        }

                        // Current debt summary
                        VStack(spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(selectedDebt.name)
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                    HStack(spacing: 8) {
                                        Text(selectedDebt.debtType.label)
                                            .font(.system(size: 11))
                                            .foregroundStyle(AppTheme.textSecondary)
                                            .padding(.horizontal, 8).padding(.vertical, 3)
                                            .background(AppTheme.cardMid, in: Capsule())
                                        Text(String(
                                            format: loc("debt.apr"),
                                            selectedDebt.annualInterestRate
                                        ))
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(AppTheme.red)
                                            .padding(.horizontal, 8).padding(.vertical, 3)
                                            .background(AppTheme.red.opacity(0.12), in: Capsule())
                                    }
                                }
                                Spacer()
                                Text(fmt(selectedDebt.currentBalance))
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(AppTheme.red)
                            }
                        }
                        .padding(16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.red.opacity(0.2), lineWidth: 1))
                        .padding(.horizontal, 22)

                        // Extra payment input
                        VStack(alignment: .leading, spacing: 10) {
                            Text(String(format: loc("debt.extra_payment_count"), fmt(extraPayment)))
                                .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)

                            HStack(spacing: 12) {
                                Text(CurrencyManager.symbol(for: currency))
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(AppTheme.textSecondary)
                                TextField("0", text: $extraPaymentText)
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .keyboardType(.numberPad)
                                    .onChange(of: extraPaymentText) { _, v in
                                        extraPayment = Double(v.filter { $0.isNumber }) ?? 0
                                    }
                            }
                            .padding(16)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))

                            // Quick add buttons.
                            // Amounts are scaled to the debt's currency so the
                            // chips stay sensible — adding "+1M" to a $1,000
                            // debt would be absurd, so for USD we offer
                            // +10/+25/+50/+100 instead. Compact-name notation
                            // ("K", "M", "rb", "jt") is rendered with the user's
                            // currently-selected language locale, not the device
                            // locale, so it matches the rest of the app's text.
                            HStack(spacing: 8) {
                                let quickAmounts: [Int] = {
                                    let cur = selectedDebt.currency.uppercased()
                                    if cur == "IDR" {
                                        return [100_000, 250_000, 500_000, 1_000_000]
                                    } else {
                                        // USD / EUR / similar — small unit currencies
                                        return [10, 25, 50, 100]
                                    }
                                }()
                                ForEach(quickAmounts, id: \.self) { amt in
                                    Button {
                                        HapticManager.shared.tap()
                                        extraPayment += Double(amt)
                                        extraPaymentText = String(Int(extraPayment))
                                    } label: {
                                        Text(quickChipLabel(amt))
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(AppTheme.accent)
                                            .padding(.horizontal, 10).padding(.vertical, 6)
                                            .background(AppTheme.accent.opacity(0.1), in: Capsule())
                                    }.buttonStyle(ScaleButtonStyle())
                                }
                                Spacer()
                                if extraPayment > 0 {
                                    Button {
                                        HapticManager.shared.tap()
                                        extraPayment = 0; extraPaymentText = ""
                                    } label: {
                                        Text(loc("notif.clear"))
                                            .font(.system(size: 12))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 22)

                        // Results comparison
                        VStack(spacing: 12) {
                            HStack {
                                Text(loc("debt.payoff_proj"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                if monthsSaved > 0 {
                                    Text(String(format: loc("debt.month_saved"), monthsSaved))
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(AppTheme.accent)
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(AppTheme.accent.opacity(0.12), in: Capsule())
                                }
                            }

                            // Side-by-side comparison
                            HStack(spacing: 12) {
                                // Minimum only
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(loc("debt.min_only"))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(AppTheme.textSecondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(String(
                                            format: loc("debt.amount_per_month"),
                                            fmt(selectedDebt.minimumPayment)
                                        ))
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                        if let m = baseMonths {
                                            Text(String(format: loc("debt.month"), m))
                                                .font(.system(size: 20, weight: .bold))
                                                .foregroundStyle(AppTheme.red)
                                            Text(String(format: loc("debt.free_by"), payoffDateBase))
                                                .font(.system(size: 11))
                                                .foregroundStyle(AppTheme.textSecondary)
                                        } else {
                                            Text("∞")
                                                .font(.system(size: 28, weight: .bold))
                                                .foregroundStyle(AppTheme.red)
                                            Text(loc("debt.payment_lt_int"))
                                                .font(.system(size: 11))
                                                .foregroundStyle(AppTheme.red.opacity(0.8))
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.red.opacity(0.2), lineWidth: 1))

                                // With extra
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(loc("debt.with_extra"))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(AppTheme.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(String(format: loc("debt.amount_per_month"), fmt(selectedDebt.minimumPayment + max(extraPayment, 0))))
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                        if let m = boostedMonths {
                                            Text(String(format: loc("debt.month"), m))
                                                .font(.system(size: 20, weight: .bold))
                                                .foregroundStyle(AppTheme.accent)
                                            Text(String(format: loc("debt.free_by"), payoffDateBoosted))
                                                .font(.system(size: 11))
                                                .foregroundStyle(AppTheme.textSecondary)
                                        } else {
                                            Text(String(format: loc("debt.amount_per_month"), fmt(selectedDebt.minimumPayment)))
                                                .font(.system(size: 13))
                                                .foregroundStyle(AppTheme.textSecondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(AppTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.accent.opacity(0.3), lineWidth: 1))
                            }

                            // Interest saved banner
                            if interestSaved > 0 {
                                HStack(spacing: 10) {
                                    Image(systemName: "banknote.fill")
                                        .font(.system(size: 16)).foregroundStyle(AppTheme.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(String(format: loc("debt.interest_saved"), fmt(interestSaved)))
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                        Text(String(format: loc("debt.interest_saved"), fmt(extraPayment)))
                                            .font(.system(size: 11))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                    Spacer()
                                }
                                .padding(14)
                                .background(AppTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.accent.opacity(0.25), lineWidth: 1))
                            }
                        }
                        .padding(.horizontal, 22)

                        // Monthly interest cost note
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                            Text(String(format: loc("debt.monthly_interest"), fmt(selectedDebt.monthlyInterestCost)))
                                .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                        }
                        .padding(.horizontal, 22)

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle(loc("debt.payoff_sim"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.done")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
    }
}
