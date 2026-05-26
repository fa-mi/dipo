import SwiftUI
import SwiftData
import UserNotifications

// MARK: - Wishlist SwiftData Model

@Model
final class SavingsGoal {
    var id: UUID
    var name: String
    var emoji: String
    var targetAmount: Double
    var savedAmount: Double
    var currency: String
    var targetDate: Date?
    var priority: Int          // 1=high, 2=medium, 3=low
    var isCompleted: Bool
    var createdAt: Date
    var notes: String
    var monthlyContribution: Double
    var isPinned: Bool = false  // shows progress on home screen

    init(name: String, emoji: String = "🎯", targetAmount: Double,
         savedAmount: Double = 0, currency: String = "IDR",
         targetDate: Date? = nil, priority: Int = 2,
         monthlyContribution: Double = 0, notes: String = "") {
        self.id = UUID()
        self.name = name
        self.emoji = emoji
        self.targetAmount = targetAmount
        self.savedAmount = savedAmount
        self.currency = currency
        self.targetDate = targetDate
        self.priority = priority
        self.isCompleted = false
        self.createdAt = .now
        self.notes = notes
        self.monthlyContribution = monthlyContribution
        self.isPinned = false
    }

    var progress: Double { targetAmount > 0 ? min(savedAmount / targetAmount, 1.0) : 0 }
    var progressPercent: Double { progress * 100 }
    var remaining: Double { max(targetAmount - savedAmount, 0) }

    var monthsToGoal: Int? {
        guard monthlyContribution > 0, remaining > 0 else { return nil }
        return Int(ceil(remaining / monthlyContribution))
    }

    var estimatedDate: Date? {
        guard let m = monthsToGoal else { return nil }
        return Calendar.current.date(byAdding: .month, value: m, to: .now)
    }

    var priorityLabel: String {
        switch priority {
        case 1: return loc("savings.high")
        case 2: return loc("savings.medium")
        default: return loc("savings.low")
        }
    }

    var priorityColor: Color {
        switch priority {
        case 1: return Color(hex: "#FF6B6B")
        case 2: return Color(hex: "#FB923C")
        default: return Color(hex: "#38BDF8")
        }
    }
}

// MARK: - Wishlist View

struct WishlistView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavingsGoal.priority) private var goals: [SavingsGoal]
    @Query(sort: \SalarySchedule.createdAt) private var salaries: [SalarySchedule]

    @State private var showAddGoal    = false
    @State private var editingGoal: SavingsGoal? = nil
    @State private var appeared       = false
    @State private var celebratingGoal: SavingsGoal? = nil

    /// Sum savedAmount across active goals, converted to the user's preferred
    /// currency. Naive `+` would mix IDR with USD (5,000,000 IDR + 100 USD →
    /// "5,000,100" — meaningless), so we normalize each goal first.
    private var totalSaved: Double {
        goals.filter { !$0.isCompleted }.reduce(0) {
            $0 + CurrencyManager.shared.convert(
                $1.savedAmount, from: $1.currency,
                to: CurrencyManager.shared.preferredCurrency
            )
        }
    }
    private var totalTarget: Double {
        goals.filter { !$0.isCompleted }.reduce(0) {
            $0 + CurrencyManager.shared.convert(
                $1.targetAmount, from: $1.currency,
                to: CurrencyManager.shared.preferredCurrency
            )
        }
    }
    private var monthlyIncome: Double {
        // Salary schedules also carry their own currency (a USD-paid expat
        // can have multiple salaries in mixed currencies). Same conversion
        // rationale applies.
        salaries.filter { $0.isActive }.reduce(0) {
            $0 + CurrencyManager.shared.convert(
                $1.amount, from: $1.currency,
                to: CurrencyManager.shared.preferredCurrency
            )
        }
    }
    private var activeGoals: [SavingsGoal] { goals.filter { !$0.isCompleted } }
    private var completedGoals: [SavingsGoal] { goals.filter { $0.isCompleted } }

    var body: some View {
        PremiumGate(feature: .savingsGoals) {
        NavigationStack {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc("profile.savings"))
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(String(format: loc("savings.active_goals"), activeGoals.count))
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                        Button {
                            HapticManager.shared.tap()
                            showAddGoal = true
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(AppTheme.accent)
                                    .frame(width: 42, height: 42)
                                    .shadow(color: AppTheme.accent.opacity(0.4), radius: 10, y: 4)
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(AppTheme.bg)
                            }
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .opacity(appeared ? 1 : 0)

                    if goals.isEmpty {
                        GoalsEmptyState(showAdd: $showAddGoal)
                            .padding(.top, 50)
                            .opacity(appeared ? 1 : 0)
                    } else {
                        VStack(spacing: 16) {
                            // Overall progress summary
                            if !activeGoals.isEmpty {
                                GoalsSummaryCard(
                                    totalSaved: totalSaved,
                                    totalTarget: totalTarget,
                                    monthlyIncome: monthlyIncome,
                                    goalCount: activeGoals.count
                                )
                                .padding(.horizontal, 22)
                                .padding(.top, 16)
                                .opacity(appeared ? 1 : 0)
                                .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.06), value: appeared)
                            }

                            // Active goals
                            if !activeGoals.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(loc("savings.in_progress"))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .padding(.horizontal, 22)

                                    ForEach(Array(activeGoals.enumerated()), id: \.element.id) { i, goal in
                                        GoalCard(
                                            goal: goal,
                                            monthlyIncome: monthlyIncome,
                                            onDeposit: { amount in depositToGoal(goal, amount: amount) },
                                            onEdit: { editingGoal = goal },
                                            onDelete: { deleteGoal(goal) },
                                            onComplete: { completeGoal(goal) },
                                            onPin: { togglePin(goal) }
                                        )
                                        .padding(.horizontal, 22)
                                        .opacity(appeared ? 1 : 0)
                                        .offset(y: appeared ? 0 : 24)
                                        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.12 + Double(i) * 0.07), value: appeared)
                                    }
                                }
                            }

                            // Completed goals
                            if !completedGoals.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(loc("savings.achieved"))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .padding(.horizontal, 22)

                                    ForEach(completedGoals) { goal in
                                        CompletedGoalRow(goal: goal, onDelete: { deleteGoal(goal) })
                                            .padding(.horizontal, 22)
                                    }
                                }
                            }
                        }
                    }

                    Spacer(minLength: 120)
                }
            }

            // Celebration overlay
            if let goal = celebratingGoal {
                GoalCelebration(goal: goal) {
                    withAnimation { celebratingGoal = nil }
                }
                .transition(.opacity)
                .zIndex(999)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { appeared = true }
        }
        .sheet(isPresented: $showAddGoal) {
            GoalFormSheet(editGoal: nil)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .sheet(item: $editingGoal) { goal in
            GoalFormSheet(editGoal: goal)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        } // end NavigationStack
        } // end PremiumGate
    }

    private func depositToGoal(_ goal: SavingsGoal, amount: Double) {
        let wasComplete = goal.progress >= 1.0
        goal.savedAmount += amount
        try? context.save()
        HapticManager.shared.success()
        if !wasComplete && goal.progress >= 1.0 {
            HapticManager.shared.rigidImpact()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                    celebratingGoal = goal
                }
            }
            scheduleGoalNotification(goal)
        }
    }

    private func completeGoal(_ goal: SavingsGoal) {
        goal.isCompleted = true
        try? context.save()
        HapticManager.shared.rigidImpact()
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
            celebratingGoal = goal
        }
    }

    private func deleteGoal(_ goal: SavingsGoal) {
        context.delete(goal)
        try? context.save()
        HapticManager.shared.warning()
    }

    private func togglePin(_ goal: SavingsGoal) {
        // Unpin all others first — only one pinned goal at a time
        if !goal.isPinned {
            for g in goals where g.isPinned { g.isPinned = false }
        }
        goal.isPinned.toggle()
        try? context.save()
        HapticManager.shared.select()
    }

    private func scheduleGoalNotification(_ goal: SavingsGoal) {
        let content = UNMutableNotificationContent()
        content.title = String(format: loc("savings.notif_title"), goal.emoji)
        content.body  = String(format: loc("savings.notif_body"), goal.name)
        content.sound = .defaultCritical
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: goal.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

// MARK: - Goals Summary Card

struct GoalsSummaryCard: View {
    let totalSaved: Double
    let totalTarget: Double
    let monthlyIncome: Double
    let goalCount: Int

    private var overallProgress: Double { totalTarget > 0 ? min(totalSaved / totalTarget, 1.0) : 0 }
    private var savingsRate: Double { monthlyIncome > 0 ? (totalSaved / monthlyIncome) * 100 : 0 }

    var body: some View {
        HStack(spacing: 20) {
            // Progress ring
            ZStack {
                Circle()
                    .stroke(AppTheme.cardMid, lineWidth: 8)
                    .frame(width: 72, height: 72)
                Circle()
                    .trim(from: 0, to: overallProgress)
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 1.0, dampingFraction: 0.8), value: overallProgress)
                Text("\(Int(overallProgress * 100))%")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(loc("savings.overall"))
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(CurrencyManager.shared.formatted(totalSaved, currency: CurrencyManager.shared.preferredCurrency))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())
                Text(String(format: loc("savings.of_across"),
                            CurrencyManager.shared.formatted(totalTarget, currency: CurrencyManager.shared.preferredCurrency),
                            goalCount))
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.accent.opacity(0.15), lineWidth: 1))
    }
}

// MARK: - Goal Card

struct GoalCard: View {
    let goal: SavingsGoal
    let monthlyIncome: Double
    let onDeposit: (Double) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onComplete: () -> Void
    let onPin: () -> Void

    @State private var showDepositSheet = false
    @State private var showActions      = false
    @State private var depositAmount    = ""

    private var suggestedMonthly: Double {
        guard let months = goal.monthsToGoal, months > 0 else {
            return goal.remaining > 0 ? goal.remaining / 12 : 0
        }
        return goal.remaining / Double(months)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                // Header
                HStack {
                    Text(goal.emoji)
                        .font(.system(size: 32))
                        .frame(width: 52, height: 52)
                        .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(goal.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        HStack(spacing: 6) {
                            Circle().fill(goal.priorityColor).frame(width: 6, height: 6)
                            Text("\(goal.priorityLabel) priority")
                                .font(.system(size: 12))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    Spacer()

                    Button {
                        HapticManager.shared.tap()
                        showActions = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 36, height: 36)
                            .background(AppTheme.cardMid, in: Circle())
                    }
                    .buttonStyle(ScaleButtonStyle())
                }

                // Amount progress
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc("savings.saved"))
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text(CurrencyManager.shared.formatted(goal.savedAmount, currency: goal.currency))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(AppTheme.accent)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(loc("savings.goal"))
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text(CurrencyManager.shared.formatted(goal.targetAmount, currency: goal.currency))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                }

                // Progress bar
                VStack(spacing: 6) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6).fill(AppTheme.cardMid).frame(height: 10)
                            RoundedRectangle(cornerRadius: 6)
                                .fill(LinearGradient(
                                    colors: [AppTheme.accent, AppTheme.accent.opacity(0.6)],
                                    startPoint: .leading, endPoint: .trailing
                                ))
                                .frame(width: g.size.width * CGFloat(goal.progress), height: 10)
                                .animation(.spring(response: 0.8, dampingFraction: 0.8), value: goal.progress)
                        }
                    }
                    .frame(height: 10)

                    HStack {
                        Text("\(String(format: "%.1f", goal.progressPercent))% saved")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)
                        Spacer()
                        if let months = goal.monthsToGoal {
                            Text("\(months) months left")
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.textSecondary)
                        } else if goal.monthlyContribution == 0 {
                            Text(loc("savings.set_monthly"))
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.orange)
                        }
                    }
                }

                // Smart insight
                if goal.monthlyContribution > 0 || suggestedMonthly > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "brain.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.purple)
                        if goal.monthlyContribution > 0 {
                            Text(String(format: loc("savings.save_per_mo"),
                                        CurrencyManager.shared.formatted(goal.monthlyContribution, currency: goal.currency)))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppTheme.textPrimary)
                            if monthlyIncome > 0 {
                                Text(String(format: loc("savings.pct_of_income"),
                                            String(format: "%.0f", (goal.monthlyContribution/monthlyIncome)*100)))
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        } else {
                            Text(String(format: loc("savings.suggested_per_mo"),
                                        CurrencyManager.shared.formatted(suggestedMonthly, currency: goal.currency)))
                                .font(.system(size: 12))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(AppTheme.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                // Details navigation
                NavigationLink(destination: GoalDetailView(goal: goal, monthlyIncome: monthlyIncome)) {
                    HStack {
                        Text(loc("savings.view_details"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppTheme.accent)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                // Deposit button
                Button {
                    HapticManager.shared.tap()
                    showDepositSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 16))
                        Text(loc("savings.add")).font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: AppTheme.accent.opacity(0.3), radius: 8, y: 4)
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(16)
        }
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20)
            .stroke(goal.progress >= 1.0 ? AppTheme.accent.opacity(0.5) : Color.clear, lineWidth: 1.5))
        .confirmationDialog(goal.name, isPresented: $showActions, titleVisibility: .visible) {
            Button(goal.isPinned ? loc("savings.unpin") : loc("savings.pin")) { onPin() }
            Button(loc("common.edit")) { onEdit() }
            Button(loc("savings.complete")) { onComplete() }
            Button(loc("common.delete"), role: .destructive) { onDelete() }
            Button(loc("common.cancel"), role: .cancel) {}
        }
        .sheet(isPresented: $showDepositSheet) {
            DepositSheet(goal: goal, onDeposit: { amount in
                showDepositSheet = false
                onDeposit(amount)
            })
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.bg)
        }
    }
}

// MARK: - Deposit Sheet

struct DepositSheet: View {
    let goal: SavingsGoal
    let onDeposit: (Double) -> Void
    @State private var amountText = ""
    @Environment(\.dismiss) private var dismiss

    var amount: Double { Double(amountText) ?? 0 }

    var body: some View {
        VStack(spacing: 24) {
            // Handle
            RoundedRectangle(cornerRadius: 3)
                .fill(AppTheme.cardMid)
                .frame(width: 36, height: 4)
                .padding(.top, 12)

            VStack(spacing: 6) {
                Text(goal.emoji).font(.system(size: 40))
                Text(String(format: loc("savings.add_to"), goal.name))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(String(format: loc("savings.saved_of"),
                            CurrencyManager.shared.formatted(goal.savedAmount, currency: goal.currency),
                            CurrencyManager.shared.formatted(goal.targetAmount, currency: goal.currency)))
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            // Amount input
            HStack(spacing: 8) {
                Text(goal.currency)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                TextField("0.00", text: $amountText)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .keyboardType(.decimalPad)
            }
            .padding(18)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 22)

            // Smart quick amounts based on currency
            let quickAmounts: [Double] = goal.currency == "IDR"
                ? [50_000, 100_000, 500_000, 1_000_000]
                : goal.currency == "JPY" || goal.currency == "IDR"
                ? [1_000, 5_000, 10_000, 50_000]
                : [10, 50, 100, 500]

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(quickAmounts, id: \.self) { quick in
                        Button {
                            HapticManager.shared.tap()
                            amountText = goal.currency == "IDR" || goal.currency == "JPY"
                                ? String(Int(quick))
                                : String(quick)
                        } label: {
                            Text("+\(CurrencyManager.shared.formatted(quick, currency: goal.currency))")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(AppTheme.cardDark, in: Capsule())
                                .overlay(Capsule().stroke(AppTheme.accent.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }

                    // Also show minimum contribution shortcut
                    if goal.monthlyContribution > 0 {
                        Button {
                            HapticManager.shared.tap()
                            amountText = String(goal.monthlyContribution)
                        } label: {
                            VStack(spacing: 1) {
                                Text(loc("savings.monthly")).font(.system(size: 9)).foregroundStyle(AppTheme.textSecondary)
                                Text(CurrencyManager.shared.formatted(goal.monthlyContribution, currency: goal.currency))
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(AppTheme.purple)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(AppTheme.purple.opacity(0.1), in: Capsule())
                            .overlay(Capsule().stroke(AppTheme.purple.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                }
                .padding(.horizontal, 2)
            }

            Button {
                guard amount > 0 else { return }
                HapticManager.shared.success()
                onDeposit(amount)
            } label: {
                Text(amount > 0
                     ? String(format: loc("savings.add_amount"), CurrencyManager.shared.formatted(amount, currency: goal.currency))
                     : loc("savings.add"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(amount > 0 ? AppTheme.accent : AppTheme.cardMid, in: Capsule())
                    .shadow(color: amount > 0 ? AppTheme.accent.opacity(0.35) : .clear, radius: 12, y: 6)
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(amount <= 0)
            .padding(.horizontal, 22)

            Spacer()
        }
    }
}

// MARK: - Goal Celebration (iOS-exclusive spring physics + haptics)

struct GoalCelebration: View {
    let goal: SavingsGoal
    let onDismiss: () -> Void
    @State private var scale: CGFloat = 0.5
    @State private var opacity: Double = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()

            // Real falling confetti — pieces drop from above the screen,
            // drift sideways, and spin as they fall (see ConfettiView).
            ConfettiView()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 24) {
                Text(goal.emoji)
                    .font(.system(size: 80))
                    .scaleEffect(scale)

                VStack(spacing: 10) {
                    Text(loc("savings.reached"))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(goal.name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                    Text(String(format: loc("savings.you_saved"),
                                CurrencyManager.shared.formatted(goal.targetAmount, currency: goal.currency)))
                        .font(.system(size: 15))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .scaleEffect(scale)
                .opacity(opacity)

                Button {
                    HapticManager.shared.success()
                    onDismiss()
                } label: {
                    Text(loc("savings.amazing"))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppTheme.bg)
                        .padding(.horizontal, 48).padding(.vertical, 16)
                        .background(AppTheme.accent, in: Capsule())
                        .shadow(color: AppTheme.accent.opacity(0.5), radius: 16, y: 8)
                }
                .buttonStyle(ScaleButtonStyle())
                .scaleEffect(scale)
                .opacity(opacity)
            }
        }
        .onAppear {
            // iOS-exclusive: chained spring animations with stagger
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { scale = 1.1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { scale = 1.0; opacity = 1 }
            }
            // Cascade haptic — iOS UIImpactFeedbackGenerator
            for i in 0..<5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.08) {
                    HapticManager.shared.rigidImpact()
                }
            }
        }
    }
}

// MARK: - Confetti

/// One falling confetti piece. Each carries its own randomized physics so
/// the burst looks organic rather than a uniform grid.
private struct ConfettiPiece: Identifiable {
    let id = UUID()
    let startX: CGFloat       // horizontal start, fraction of width (0...1)
    let drift: CGFloat        // horizontal travel during the fall, in points
    let color: Color
    let size: CGFloat
    let isCircle: Bool        // mix of circles + rectangles
    let delay: Double         // staggered launch so pieces don't move in lockstep
    let duration: Double      // fall speed
    let spin: Double          // total rotation in degrees over the fall
}

/// A self-contained confetti burst. Drop it into any ZStack — pieces fall
/// from just above the top edge to just below the bottom, drifting and
/// spinning. Fire-and-forget: it animates once on appear.
struct ConfettiView: View {
    private let palette: [Color] = [
        AppTheme.accent, AppTheme.orange, AppTheme.purple,
        AppTheme.blue, Color(hex: "#FF6B6B"), Color(hex: "#FBBF24"),
    ]

    @State private var pieces: [ConfettiPiece] = []
    /// Flips to `true` on appear — drives every piece from top → bottom.
    @State private var fell = false

    var body: some View {
        GeometryReader { geo in
            ForEach(pieces) { piece in
                Group {
                    if piece.isCircle {
                        Circle().fill(piece.color)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(piece.color)
                    }
                }
                .frame(width: piece.size, height: piece.size * (piece.isCircle ? 1 : 0.55))
                .rotationEffect(.degrees(fell ? piece.spin : 0))
                .position(
                    x: piece.startX * geo.size.width + (fell ? piece.drift : 0),
                    // Start ~60pt above the top edge, end ~60pt below bottom.
                    y: fell ? geo.size.height + 60 : -60
                )
                .animation(
                    .easeIn(duration: piece.duration).delay(piece.delay),
                    value: fell
                )
            }
        }
        .onAppear {
            pieces = (0..<60).map { _ in
                ConfettiPiece(
                    startX:   CGFloat.random(in: 0.05...0.95),
                    drift:    CGFloat.random(in: -70...70),
                    color:    palette.randomElement()!,
                    size:     CGFloat.random(in: 7...13),
                    isCircle: Bool.random(),
                    delay:    Double.random(in: 0...0.5),
                    duration: Double.random(in: 1.6...2.8),
                    spin:     Double.random(in: -540...540)
                )
            }
            // Defer the flip one runloop tick so SwiftUI registers the
            // initial (above-screen) state before animating the fall.
            DispatchQueue.main.async { fell = true }
        }
    }
}

// MARK: - Completed Goal Row

struct CompletedGoalRow: View {
    let goal: SavingsGoal
    let onDelete: () -> Void
    @State private var showDelete = false

    var body: some View {
        HStack(spacing: 14) {
            Text(goal.emoji).font(.system(size: 24))
                .frame(width: 44, height: 44)
                .background(AppTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.accent.opacity(0.3), lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                Text(goal.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(CurrencyManager.shared.formatted(goal.targetAmount, currency: goal.currency) + " saved")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 20))
                .foregroundStyle(AppTheme.accent)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { onDelete() } label: {
                Label(loc("common.delete"), systemImage: "trash")
            }
        }
    }
}

// MARK: - Empty State

struct GoalsEmptyState: View {
    @Binding var showAdd: Bool
    var body: some View {
        VStack(spacing: 20) {
            Text("🎯").font(.system(size: 60)).gentleFloat()
            VStack(spacing: 8) {
                Text(loc("savings.no_goals")).font(.system(size: 18, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Text(loc("savings.empty_goals"))
                    .font(.system(size: 14)).foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
            }
            Button { HapticManager.shared.tap(); showAdd = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                    Text(loc("savings.add_goal")).font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(AppTheme.bg)
                .padding(.horizontal, 32).padding(.vertical, 14)
                .background(AppTheme.accent, in: Capsule())
                .shadow(color: AppTheme.accent.opacity(0.4), radius: 12, y: 6)
            }.buttonStyle(ScaleButtonStyle())
        }.padding(.horizontal, 40)
    }
}

// MARK: - Goal Form Sheet

struct GoalFormSheet: View {
    let editGoal: SavingsGoal?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var emoji = "🎯"
    @State private var targetAmount = ""
    @State private var savedAmount  = ""
    @State private var monthly      = ""
    @State private var currency     = CurrencyManager.shared.preferredCurrency
    @State private var priority     = 2
    @State private var hasTargetDate = false
    @State private var targetDate   = Date().addingTimeInterval(365*24*3600)
    @State private var notes        = ""
    @State private var appeared     = false
    @State private var errorMsg: String? = nil

    let emojis = ["🎯","🚗","🏠","✈️","💻","📱","🎓","💍","⛵","🎸","🏋️","👶","🌏","💰","🏖️","🎮"]
    let currencies = ["USD","IDR"]
    private var isEditing: Bool { editGoal != nil }

    // Live payoff preview
    private var monthsPreview: Int? {
        guard let target = Double(targetAmount),
              let saved  = Double(savedAmount.isEmpty ? "0" : savedAmount),
              let mo     = Double(monthly),
              mo > 0, target > saved else { return nil }
        return Int(ceil((target - saved) / mo))
    }
    
    /// Locale-aware "Around <Month Year>" string, computed from monthsPreview.
    /// Returns nil when monthsPreview is nil — keeps the View body simple.
    private var previewDateText: String? {
        guard let months = monthsPreview,
              let date = Calendar.current.date(byAdding: .month, value: months, to: .now)
        else { return nil }
        let df = DateFormatter()
        df.locale = LanguageManager.shared.currentLocale
        df.dateFormat = "MMMM yyyy"
        return String(format: loc("savings.around_date"), df.string(from: date))
    }

    var body: some View {
        NavigationStack {
            ZStack { AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {

                        // Emoji picker
                        VStack(spacing: 10) {
                            Text(loc("savings.choose_emoji")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(emojis, id: \.self) { e in
                                        Button { HapticManager.shared.tap(); emoji = e } label: {
                                            Text(e).font(.system(size: 28))
                                                .frame(width: 52, height: 52)
                                                .background(emoji == e ? AppTheme.accent.opacity(0.2) : AppTheme.cardDark,
                                                            in: RoundedRectangle(cornerRadius: 14))
                                                .overlay(RoundedRectangle(cornerRadius: 14)
                                                    .stroke(emoji == e ? AppTheme.accent.opacity(0.6) : Color.clear, lineWidth: 1.5))
                                        }.buttonStyle(ScaleButtonStyle())
                                    }
                                }.padding(.horizontal, 22)
                            }
                        }
                        .opacity(appeared ? 1 : 0)

                        SheetField(label: loc("savings.description"), placeholder: loc("savings.description_placeholder"), text: $name)
                            .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.08), value: appeared)

                        // Amounts
                        HStack(spacing: 12) {
                            VStack(spacing: 8) {
                                Text(loc("savings.target_amt")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                TextField("0", text: $targetAmount).font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(AppTheme.textPrimary).keyboardType(.decimalPad)
                                    .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                if let p = AmountInputHelper.preview(targetAmount, currency: currency) {
                                    Text(p).font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            VStack(spacing: 8) {
                                Text(loc("savings.already")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                TextField("0", text: $savedAmount).font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(AppTheme.accent).keyboardType(.decimalPad)
                                    .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                if let p = AmountInputHelper.preview(savedAmount, currency: currency) {
                                    Text(p).font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.12), value: appeared)

                        // Monthly + currency
                        HStack(spacing: 12) {
                            VStack(spacing: 8) {
                                Text(loc("savings.monthly_sav")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                TextField("0", text: $monthly).font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(AppTheme.purple).keyboardType(.decimalPad)
                                    .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                            }
                            VStack(spacing: 8) {
                                Text(loc("common.currency")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Menu {
                                    ForEach(currencies, id: \.self) { c in
                                        Button(c) { currency = c }
                                    }
                                } label: {
                                    HStack {
                                        Text(currency).font(.system(size: 18, weight: .bold)).foregroundStyle(AppTheme.accent)
                                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                                    }
                                    .padding(14).frame(maxWidth: .infinity)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                }
                            }
                        }
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.16), value: appeared)

                        // Priority
                        VStack(spacing: 8) {
                            Text(loc("debt.priority")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            HStack(spacing: 10) {
                                ForEach([(1,loc("savings.high"),Color(hex: "#FF6B6B")),(2,loc("savings.medium"),AppTheme.orange),(3,loc("savings.low"),AppTheme.blue)], id: \.0) { p, label, color in
                                    Button { HapticManager.shared.tap(); priority = p } label: {
                                        Text(label).font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(priority == p ? AppTheme.bg : AppTheme.textSecondary)
                                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                                            .background(priority == p ? color : AppTheme.cardDark, in: Capsule())
                                    }.buttonStyle(ScaleButtonStyle())
                                }
                            }.padding(.horizontal, 22)
                        }
                        .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)

                        // Live preview
                        if let months = monthsPreview {
                            HStack(spacing: 12) {
                                Image(systemName: "calendar.badge.clock").font(.system(size: 20)).foregroundStyle(AppTheme.purple)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(String(format: loc("savings.reach_in_months"), months))
                                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                    if let dateStr = previewDateText {
                                        Text(dateStr)
                                            .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(14)
                            .background(AppTheme.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.purple.opacity(0.2), lineWidth: 1))
                            .padding(.horizontal, 22)
                            .animation(.spring(response: 0.4), value: monthsPreview)
                        }

                        if let err = errorMsg {
                            InlineBanner(tone: .error, message: err)
                                .padding(.horizontal, 22)
                                .transition(.opacity)
                        }

                        // Form-validity computed once — drives both background
                        // tint and the foreground/disabled affordance below so
                        // the user can SEE the button is inactive instead of
                        // tapping and getting an inline error.
                        let canSave = !name.trimmingCharacters(in: .whitespaces).isEmpty
                            && (Double(targetAmount) ?? 0) > 0
                        Button { save() } label: {
                            Text(isEditing ? loc("general.edit") : loc("savings.add_goal"))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(canSave ? AppTheme.bg : AppTheme.textSecondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(canSave ? AppTheme.accent : AppTheme.textSecondary.opacity(0.3), in: Capsule())
                                .shadow(color: canSave ? AppTheme.accent.opacity(0.35) : .clear, radius: 12, y: 6)
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .disabled(!canSave)
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.24), value: appeared)

                        Spacer(minLength: 40)
                    }.padding(.top, 8)
                }
            }
            .navigationTitle(isEditing ? loc("savings.edit") : loc("savings.add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { HapticManager.shared.tap(); dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        .onAppear {
            if let g = editGoal {
                name = g.name; emoji = g.emoji
                targetAmount = String(g.targetAmount); savedAmount = String(g.savedAmount)
                monthly = String(g.monthlyContribution); currency = g.currency
                priority = g.priority; notes = g.notes
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) { appeared = true }
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { errorMsg = loc("savings.error.name"); return }
        guard let target = Double(targetAmount), target > 0 else { errorMsg = loc("savings.error.amount"); return }
        let saved   = Double(savedAmount) ?? 0
        let monthly = Double(monthly) ?? 0

        if let g = editGoal {
            g.name = name.trimmingCharacters(in: .whitespaces); g.emoji = emoji
            g.targetAmount = target; g.savedAmount = saved
            g.monthlyContribution = monthly; g.currency = currency
            g.priority = priority; g.notes = notes
        } else {
            let goal = SavingsGoal(name: name.trimmingCharacters(in: .whitespaces),
                                   emoji: emoji, targetAmount: target, savedAmount: saved,
                                   currency: currency, priority: priority,
                                   monthlyContribution: monthly, notes: notes)
            context.insert(goal)
        }
        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}

// MARK: - Goal Detail View

struct GoalDetailView: View {
    @Bindable var goal: SavingsGoal
    let monthlyIncome: Double
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var showDepositSheet = false
    @State private var showDelete       = false
    @State private var appeared         = false
    @State private var animatedProgress: Double = 0
    @State private var displayPct: Int = 0

    private var progress: Double  { goal.targetAmount > 0 ? min(goal.savedAmount / goal.targetAmount, 1.0) : 0 }
    private var remaining: Double { max(goal.targetAmount - goal.savedAmount, 0) }
    private var currency: String  { goal.currency }
    
    private var estimatedDateText: String? {
        guard let date = goal.estimatedDate else { return nil }
        let df = DateFormatter()
        df.locale = LanguageManager.shared.currentLocale
        df.dateFormat = "MMMM yyyy"
        return df.string(from: date)
    }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {

                    // Hero ring
                    ZStack {
                        Circle().stroke(AppTheme.cardMid, lineWidth: 10).frame(width: 130, height: 130)
                        Circle()
                            .trim(from: 0, to: animatedProgress)
                            .stroke(
                                LinearGradient(colors: [AppTheme.accent, AppTheme.accent.opacity(0.65)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .frame(width: 130, height: 130)
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 2) {
                            Text(goal.emoji).font(.system(size: 40))
                            Text("\(displayPct)%")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(AppTheme.accent)
                                .contentTransition(.numericText(countsDown: false))
                                .animation(.easeInOut(duration: 0.05), value: displayPct)
                        }
                    }
                    .padding(.top, 8)

                    // Name + priority
                    VStack(spacing: 8) {
                        Text(goal.name).font(.system(size: 24, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                        HStack(spacing: 8) {
                            Circle().fill(goal.priorityColor).frame(width: 7, height: 7)
                            Text("\(goal.priorityLabel) priority")
                                .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                            if goal.isPinned {
                                Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(AppTheme.accent)
                                Text(loc("cards.pin_to_home")).font(.system(size: 12)).foregroundStyle(AppTheme.accent)
                            }
                        }
                    }

                    // ── Amounts card ─────────────────────────────────
                    VStack(spacing: 16) {

                        // Full-width rows — no squishing on large numbers
                        VStack(spacing: 0) {
                            HStack {
                                HStack(spacing: 6) {
                                    Circle().fill(AppTheme.accent).frame(width: 8, height: 8)
                                    Text(loc("savings.saved")).font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                                }
                                Spacer()
                                Text(CurrencyManager.shared.formatted(goal.savedAmount, currency: currency))
                                    .font(.system(size: 15, weight: .bold)).foregroundStyle(AppTheme.accent)
                                    .contentTransition(.numericText())
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)

                            Divider().background(AppTheme.cardMid).padding(.horizontal, 16)

                            HStack {
                                HStack(spacing: 6) {
                                    Circle().fill(AppTheme.textSecondary).frame(width: 8, height: 8)
                                    Text(loc("savings.goal")).font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                                }
                                Spacer()
                                Text(CurrencyManager.shared.formatted(goal.targetAmount, currency: currency))
                                    .font(.system(size: 15, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)

                            Divider().background(AppTheme.cardMid).padding(.horizontal, 16)

                            HStack {
                                HStack(spacing: 6) {
                                    Circle().fill(AppTheme.orange).frame(width: 8, height: 8)
                                    Text(loc("debt.remaining")).font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                                }
                                Spacer()
                                Text(CurrencyManager.shared.formatted(remaining, currency: currency))
                                    .font(.system(size: 15, weight: .bold)).foregroundStyle(AppTheme.orange)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
                        }
                        .background(AppTheme.cardDark.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))

                        // Progress bar
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 6).fill(AppTheme.cardMid).frame(height: 10)
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(LinearGradient(
                                        colors: [AppTheme.accent, AppTheme.accent.opacity(0.6)],
                                        startPoint: .leading, endPoint: .trailing))
                                    .frame(width: g.size.width * CGFloat(animatedProgress), height: 10)
                            }
                        }
                        .frame(height: 10)

                        Text(String(format: loc("savings.percent_saved_of"),
                                    String(format: "%.1f", progress * 100),
                                    CurrencyManager.shared.formatted(goal.targetAmount, currency: currency)))
                            .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.accent.opacity(0.15), lineWidth: 1))
                    .padding(.horizontal, 22)

                    // Smart Projection
                    if goal.monthlyContribution > 0 || (monthlyIncome > 0 && remaining > 0) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 7) {
                                Image(systemName: "brain.fill").font(.system(size: 14)).foregroundStyle(AppTheme.purple)
                                Text(loc("debt.smart_proj"))
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                            }

                            if goal.monthlyContribution > 0 {
                                HStack(spacing: 0) {
                                    VStack(spacing: 6) {
                                        Text(loc("savings.monthly_sav"))
                                            .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                        Text(CurrencyManager.shared.formatted(goal.monthlyContribution, currency: currency))
                                            .font(.system(size: 14, weight: .bold)).foregroundStyle(AppTheme.purple)
                                            .minimumScaleFactor(0.6).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)

                                    if monthlyIncome > 0 {
                                        Rectangle().fill(AppTheme.purple.opacity(0.2)).frame(width: 1, height: 36)
                                        VStack(spacing: 6) {
                                            Text(loc("debt.of_income"))
                                                .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                            Text("\(String(format: "%.0f", (goal.monthlyContribution / monthlyIncome) * 100))%")
                                                .font(.system(size: 14, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                        }
                                        .frame(maxWidth: .infinity)
                                    }

                                    if let months = goal.monthsToGoal {
                                        Rectangle().fill(AppTheme.purple.opacity(0.2)).frame(width: 1, height: 36)
                                        VStack(spacing: 6) {
                                            Text(loc("debt.months_left"))
                                                .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                            Text("\(months)")
                                                .font(.system(size: 14, weight: .bold)).foregroundStyle(AppTheme.accent)
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                }
                                .padding(.vertical, 4)

                                if let dateStr = estimatedDateText {
                                    HStack(spacing: 6) {
                                        Image(systemName: "calendar.badge.clock")
                                            .font(.system(size: 12)).foregroundStyle(AppTheme.purple)
                                        Text(String(format: loc("savings.goal_reached_around"), dateStr))
                                            .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 18)
                        .background(AppTheme.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.purple.opacity(0.2), lineWidth: 1))
                        .padding(.horizontal, 22)
                    }

                    // Notes
                    if !goal.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(loc("common.notes"))
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                            Text(goal.notes)
                                .font(.system(size: 14)).foregroundStyle(AppTheme.textPrimary).lineSpacing(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 22)
                    }

                    // Actions
                    VStack(spacing: 12) {
                        Button {
                            HapticManager.shared.tap()
                            showDepositSheet = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus.circle.fill").font(.system(size: 16))
                                Text(loc("savings.add")).font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundStyle(AppTheme.bg).frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(AppTheme.accent, in: Capsule())
                            .shadow(color: AppTheme.accent.opacity(0.35), radius: 10, y: 5)
                        }
                        .buttonStyle(ScaleButtonStyle())

                        HStack(spacing: 12) {
                            Button {
                                goal.isPinned.toggle()
                                try? context.save()
                                HapticManager.shared.select()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: goal.isPinned ? "pin.slash.fill" : "pin.fill").font(.system(size: 13))
                                    Text(goal.isPinned ? loc("savings.unpin") : loc("savings.pin")).font(.system(size: 13, weight: .medium))
                                }
                                .foregroundStyle(AppTheme.accent).frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(AppTheme.accent.opacity(0.1), in: Capsule())
                                .overlay(Capsule().stroke(AppTheme.accent.opacity(0.3), lineWidth: 1))
                            }
                            .buttonStyle(ScaleButtonStyle())

                            Button {
                                HapticManager.shared.warning()
                                showDelete = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "trash").font(.system(size: 13))
                                    Text(loc("action.delete")).font(.system(size: 13, weight: .medium))
                                }
                                .foregroundStyle(AppTheme.red).frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(AppTheme.red.opacity(0.1), in: Capsule())
                                .overlay(Capsule().stroke(AppTheme.red.opacity(0.3), lineWidth: 1))
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }
                    }
                    .padding(.horizontal, 22)

                    Spacer(minLength: 40)
                }
                .padding(.top, 16)
            }
        }
        .navigationTitle(goal.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.bg, for: .navigationBar)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { appeared = true }
            withAnimation(.easeInOut(duration: 1.1).delay(0.25)) { animatedProgress = progress }
            let targetPct = Int(progress * 100)
            guard targetPct > 0 else { return }
            let stepInterval = 1.1 / Double(targetPct)
            var current = 0
            Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { t in
                current += 1
                displayPct = current
                if current >= targetPct { t.invalidate() }
            }
        }
        .sheet(isPresented: $showDepositSheet) {
            DepositSheet(goal: goal, onDeposit: { amount in
                goal.savedAmount += amount
                try? context.save()
                showDepositSheet = false
                HapticManager.shared.success()
            })
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.bg)
        }
        .confirmationDialog(String(format: loc("savings.delete_title"), goal.name), isPresented: $showDelete, titleVisibility: .visible) {
            Button(loc("common.delete"), role: .destructive) {
                context.delete(goal)
                try? context.save()
                HapticManager.shared.warning()
                dismiss()
            }
            Button(loc("common.cancel"), role: .cancel) {}
        } message: { Text(loc("savings.delete_confirm")) }
    }
}
