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
    var monthlyContribution: Double // how much to save per month

    init(name: String, emoji: String = "🎯", targetAmount: Double,
         savedAmount: Double = 0, currency: String = "USD",
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
        case 1: return "High"
        case 2: return "Medium"
        default: return "Low"
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

    private var totalSaved: Double { goals.filter { !$0.isCompleted }.reduce(0) { $0 + $1.savedAmount } }
    private var totalTarget: Double { goals.filter { !$0.isCompleted }.reduce(0) { $0 + $1.targetAmount } }
    private var monthlyIncome: Double { salaries.filter { $0.isActive }.reduce(0) { $0 + $1.amount } }
    private var activeGoals: [SavingsGoal] { goals.filter { !$0.isCompleted } }
    private var completedGoals: [SavingsGoal] { goals.filter { $0.isCompleted } }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Savings Goals")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text("\(activeGoals.count) active goals")
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
                                    Text("In Progress")
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
                                            onComplete: { completeGoal(goal) }
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
                                    Text("Achieved 🎉")
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

    private func scheduleGoalNotification(_ goal: SavingsGoal) {
        let content = UNMutableNotificationContent()
        content.title = "Goal Reached! \(goal.emoji)"
        content.body = "You've saved enough for \(goal.name)! Time to make it happen!"
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
                Text("Overall Progress")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(CurrencyManager.shared.formatted(totalSaved, currency: "USD"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())
                Text("of \(CurrencyManager.shared.formatted(totalTarget, currency: "USD")) across \(goalCount) goals")
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
                        Text("Saved")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text(CurrencyManager.shared.formatted(goal.savedAmount, currency: goal.currency))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(AppTheme.accent)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Goal")
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
                            Text("Set monthly contribution")
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
                            Text("Save \(CurrencyManager.shared.formatted(goal.monthlyContribution, currency: goal.currency))/mo")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppTheme.textPrimary)
                            if monthlyIncome > 0 {
                                Text("= \(String(format: "%.0f", (goal.monthlyContribution/monthlyIncome)*100))% of income")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        } else {
                            Text("Suggested: \(CurrencyManager.shared.formatted(suggestedMonthly, currency: goal.currency))/mo to finish in 12 months")
                                .font(.system(size: 12))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(AppTheme.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                // Deposit button
                Button {
                    HapticManager.shared.tap()
                    showDepositSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 16))
                        Text("Add Savings").font(.system(size: 14, weight: .semibold))
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
            Button("Edit") { onEdit() }
            Button("Mark as Complete") { onComplete() }
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
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
                Text("Add savings to \(goal.name)")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("\(CurrencyManager.shared.formatted(goal.savedAmount, currency: goal.currency)) saved of \(CurrencyManager.shared.formatted(goal.targetAmount, currency: goal.currency))")
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

            // Quick amounts
            HStack(spacing: 10) {
                ForEach([10.0, 50.0, 100.0, 500.0], id: \.self) { quick in
                    Button {
                        HapticManager.shared.tap()
                        amountText = String(Int(quick))
                    } label: {
                        Text("+\(Int(quick))")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(AppTheme.cardDark, in: Capsule())
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }

            Button {
                guard amount > 0 else { return }
                HapticManager.shared.success()
                onDeposit(amount)
            } label: {
                Text("Add \(amount > 0 ? CurrencyManager.shared.formatted(amount, currency: goal.currency) : "amount")")
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
    @State private var confettiItems: [(CGFloat, CGFloat, Color, Double)] = []

    let colors: [Color] = [AppTheme.accent, AppTheme.orange, AppTheme.purple, AppTheme.blue, Color(hex: "#FF6B6B")]

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()

            // Confetti particles (iOS spring physics — not possible in Android without custom engine)
            ForEach(confettiItems.indices, id: \.self) { i in
                Circle()
                    .fill(confettiItems[i].2)
                    .frame(width: 8, height: 8)
                    .offset(x: confettiItems[i].0, y: confettiItems[i].1)
                    .opacity(confettiItems[i].3)
            }

            VStack(spacing: 24) {
                Text(goal.emoji)
                    .font(.system(size: 80))
                    .scaleEffect(scale)

                VStack(spacing: 10) {
                    Text("Goal Reached! 🎉")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(goal.name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                    Text("You saved \(CurrencyManager.shared.formatted(goal.targetAmount, currency: goal.currency))")
                        .font(.system(size: 15))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .scaleEffect(scale)
                .opacity(opacity)

                Button {
                    HapticManager.shared.success()
                    onDismiss()
                } label: {
                    Text("Amazing! 🙌")
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
            // Generate confetti
            confettiItems = (0..<40).map { _ in
                (CGFloat.random(in: -180...180),
                 CGFloat.random(in: -350...100),
                 colors.randomElement()!,
                 Double.random(in: 0.6...1.0))
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
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Empty State

struct GoalsEmptyState: View {
    @Binding var showAdd: Bool
    var body: some View {
        VStack(spacing: 20) {
            Text("🎯").font(.system(size: 60))
            VStack(spacing: 8) {
                Text("No savings goals yet").font(.system(size: 18, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Text("Set goals for a car, house, vacation,\nor anything you're saving toward.")
                    .font(.system(size: 14)).foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
            }
            Button { HapticManager.shared.tap(); showAdd = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                    Text("Add a Goal").font(.system(size: 15, weight: .semibold))
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
    @State private var currency     = "USD"
    @State private var priority     = 2
    @State private var hasTargetDate = false
    @State private var targetDate   = Date().addingTimeInterval(365*24*3600)
    @State private var notes        = ""
    @State private var appeared     = false
    @State private var errorMsg: String? = nil

    let emojis = ["🎯","🚗","🏠","✈️","💻","📱","🎓","💍","⛵","🎸","🏋️","👶","🌏","💰","🏖️","🎮"]
    let currencies = ["USD","IDR","EUR","GBP","SGD"]
    private var isEditing: Bool { editGoal != nil }

    // Live payoff preview
    private var monthsPreview: Int? {
        guard let target = Double(targetAmount),
              let saved  = Double(savedAmount.isEmpty ? "0" : savedAmount),
              let mo     = Double(monthly),
              mo > 0, target > saved else { return nil }
        return Int(ceil((target - saved) / mo))
    }

    var body: some View {
        NavigationStack {
            ZStack { AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {

                        // Emoji picker
                        VStack(spacing: 10) {
                            Text("Choose an emoji").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
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

                        SheetField(label: "Goal name", placeholder: "e.g. New Car, Vacation, MacBook", text: $name)
                            .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.08), value: appeared)

                        // Amounts
                        HStack(spacing: 12) {
                            VStack(spacing: 8) {
                                Text("Target amount").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                TextField("0", text: $targetAmount).font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(AppTheme.textPrimary).keyboardType(.decimalPad)
                                    .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                            }
                            VStack(spacing: 8) {
                                Text("Already saved").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                TextField("0", text: $savedAmount).font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(AppTheme.accent).keyboardType(.decimalPad)
                                    .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.12), value: appeared)

                        // Monthly + currency
                        HStack(spacing: 12) {
                            VStack(spacing: 8) {
                                Text("Monthly savings").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                TextField("0", text: $monthly).font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(AppTheme.purple).keyboardType(.decimalPad)
                                    .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                            }
                            VStack(spacing: 8) {
                                Text("Currency").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
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
                            Text("Priority").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            HStack(spacing: 10) {
                                ForEach([(1,"High",Color(hex: "#FF6B6B")),(2,"Medium",AppTheme.orange),(3,"Low",AppTheme.blue)], id: \.0) { p, label, color in
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
                                    Text("You'll reach this goal in \(months) months")
                                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                    if let date = Calendar.current.date(byAdding: .month, value: months, to: .now) {
                                        Text("Around \(date.formatted(.dateTime.month(.wide).year()))")
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
                            Text(err).font(.system(size: 13)).foregroundStyle(AppTheme.red).padding(.horizontal, 22)
                        }

                        Button { save() } label: {
                            Text(isEditing ? "Save Changes" : "Add Goal")
                                .font(.system(size: 16, weight: .bold)).foregroundStyle(AppTheme.bg)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(AppTheme.accent, in: Capsule())
                                .shadow(color: AppTheme.accent.opacity(0.35), radius: 12, y: 6)
                        }
                        .buttonStyle(ScaleButtonStyle()).padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.24), value: appeared)

                        Spacer(minLength: 40)
                    }.padding(.top, 8)
                }
            }
            .navigationTitle(isEditing ? "Edit Goal" : "New Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { HapticManager.shared.tap(); dismiss() }.foregroundStyle(AppTheme.textSecondary)
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
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { errorMsg = "Enter a goal name"; return }
        guard let target = Double(targetAmount), target > 0 else { errorMsg = "Enter a target amount"; return }
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
