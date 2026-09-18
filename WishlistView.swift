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

    // MARK: - Reconciliation with real transactions
    //
    // Before deposits wrote transactions, `savedAmount` was just a number the
    // user typed — no proof any money moved. These helpers separate the part
    // backed by real transactions from the part whose origin DiPo can't see,
    // so net worth never silently double-counts cash that never left an
    // account it already tracks.

    /// Deposits recorded through the app for this goal (always in the goal's
    /// currency). Cash for these has already been deducted from an account.
    func trackedDeposits(from allTransactions: [TxRecord]) -> Double {
        let cm = CurrencyManager.shared
        let idStr = id.uuidString
        return allTransactions
            .filter { $0.linkedGoalID == idStr && $0.amount < 0 }
            .reduce(0.0) { $0 + cm.convert(abs($1.amount), from: $1.currency.isEmpty ? currency : $1.currency, to: currency) }
    }

    /// The pot this goal started with: money already saved when it was created
    /// (or set directly afterwards). It never moved through a tracked account,
    /// so it correctly has no transaction — this is an opening balance, the
    /// savings equivalent of a credit card's `openingOwed`, not missing data.
    /// Derived rather than stored: recording a past deposit shifts money from
    /// this bucket into `trackedDeposits` automatically.
    func openingBalance(from allTransactions: [TxRecord]) -> Double {
        max(savedAmount - trackedDeposits(from: allTransactions), 0)
    }

    /// Savings are a pot of their own, kept separate from account balances, so
    /// the whole saved amount counts toward net worth. Deposits made through
    /// DiPo already reduced the funding account, so nothing is counted twice.
    func netWorthContribution(from allTransactions: [TxRecord]) -> Double {
        savedAmount
    }

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
        case 1: return AppTheme.red
        case 2: return AppTheme.orange
        default: return AppTheme.blue
        }
    }
}

// MARK: - Deposits

extension SavingsGoal {
    /// The one way money goes into a goal. Returns true when this deposit is
    /// the one that reached the target.
    ///
    /// This logic lived in two places, and the copy on the detail screen had
    /// drifted: a deposit made there never celebrated or sent the goal-reached
    /// notification. Both copies also appended the transaction without
    /// inserting it first — which, as the recurring engine notes, SwiftData
    /// does not always persist, because TxRecord has no inverse relationship.
    @MainActor @discardableResult
    func recordDeposit(_ amount: Double, from card: BankCard?, context: ModelContext) -> Bool {
        let wasComplete = progress >= 1.0
        savedAmount += amount
        if let card {
            // In the CARD's currency — the money leaves that account, so its
            // balance moves by what was actually debited.
            let debited = CurrencyManager.shared.convert(amount, from: currency, to: card.resolvedCurrency)
            let tx = TxRecord(
                name: String(format: loc("savings.tx_name"), name),
                date: .now,
                amount: -debited,
                type: "tx.type.purchase",
                icon: emoji,
                iconBgHex: TxCategory.investment.iconBg,
                category: .investment,
                currency: card.resolvedCurrency,
                notes: "tx.note.goal_deposit",
                linkedGoalID: id.uuidString)
            context.insert(tx)
            card.transactions.append(tx)
        }
        try? context.save()
        ActionFeedbackCenter.shared.savingsAdded(amount: amount, currency: currency,
                                                 goalName: name, emoji: emoji)
        return !wasComplete && progress >= 1.0
    }

    /// In-app bell entry plus a device notification when a goal is reached.
    @MainActor func announceReached() {
        let cm = CurrencyManager.shared
        let advice: String? = monthlyContribution > 0
            ? String(format: loc("notif.goal_advice_redirect"), cm.formatted(monthlyContribution, currency: currency))
            : loc("notif.goal_advice_next")
        NotificationManager.shared.postSavingsGoalReached(name: name, emoji: emoji, advice: advice)

        let content = UNMutableNotificationContent()
        content.title = String(format: loc("savings.notif_title"), emoji)
        content.body  = String(format: loc("savings.notif_body"), name)
        content.sound = .defaultCritical
        let request = UNNotificationRequest(identifier: id.uuidString, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// What deleting this goal changes, in words. Net worth counts active
    /// goals' saved money; the deposit transactions stay in the ledger.
    var deleteImpactMessage: String {
        savedAmount > 0.5
            ? String(format: loc("savings.delete_impact"),
                     CurrencyManager.shared.formatted(savedAmount, currency: currency))
            : loc("savings.delete_confirm")
    }
}

/// Whole numbers without a trailing ".0" for currencies that have no minor unit.
enum SavingsNumber {
    static func edit(_ v: Double, currency: String) -> String {
        guard v != 0 else { return "" }
        if v.rounded() == v { return String(Int64(v)) }
        return String(v)
    }
}

// MARK: - Wishlist View

struct WishlistView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavingsGoal.priority) private var goals: [SavingsGoal]
    @Query(sort: \SalarySchedule.createdAt) private var salaries: [SalarySchedule]

    /// Drives the "New Goal" flow: chooser → personal / shared create form.
    @State private var goalSheet: GoalSheet? = nil
    @State private var editingGoal: SavingsGoal? = nil
    @State private var appeared       = false
    @State private var celebratingGoal: SavingsGoal? = nil
    @State private var completedActions: SavingsGoal? = nil
    @State private var deletingCompleted: SavingsGoal? = nil

    /// Max personal goals shown inline before collapsing behind "See all".
    private let goalPreviewLimit = 3

    private var pref: String { CurrencyManager.shared.preferredCurrency }
    private func toPref(_ v: Double, _ from: String) -> Double {
        CurrencyManager.shared.convert(v, from: from, to: pref)
    }
    private var activeGoals: [SavingsGoal] { goals.filter { !$0.isCompleted } }
    private var completedGoals: [SavingsGoal] { goals.filter { $0.isCompleted } }
    private var totalSaved: Double { activeGoals.reduce(0) { $0 + toPref($1.savedAmount, $1.currency) } }
    private var totalTarget: Double { activeGoals.reduce(0) { $0 + toPref($1.targetAmount, $1.currency) } }
    private var monthlyPlan: Double { activeGoals.reduce(0) { $0 + toPref($1.monthlyContribution, $1.currency) } }
    private var monthlyIncome: Double {
        MainCard.salaries(salaries).reduce(0) { $0 + toPref($1.amount, $1.currency) }
    }

    var body: some View {
        PremiumGate(feature: .savingsGoals) {
        FeatureStack { pushed in
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    header.padding(.horizontal, 22).padding(.top, 20)

                    if !activeGoals.isEmpty {
                        GoalsSummaryCard(totalSaved: totalSaved, totalTarget: totalTarget,
                                         monthlyPlan: monthlyPlan, monthlyIncome: monthlyIncome,
                                         goalCount: activeGoals.count)
                            .padding(.horizontal, 22)
                    }

                    // Personal goals first: they are what this screen is for.
                    if !activeGoals.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionTitle(loc("savings.in_progress"))
                            ForEach(activeGoals.prefix(goalPreviewLimit)) { goal in
                                GoalCard(goal: goal, monthlyIncome: monthlyIncome,
                                         onDeposit: { amount, card in deposit(goal, amount, card) },
                                         onEdit: { editingGoal = goal },
                                         onDelete: { deleteGoal(goal) },
                                         onComplete: { completeGoal(goal) },
                                         onPin: { togglePin(goal) })
                            }
                            if activeGoals.count > goalPreviewLimit {
                                NavigationLink {
                                    AllPersonalGoalsView(
                                        goals: activeGoals, monthlyIncome: monthlyIncome,
                                        onDeposit: { g, amt, card in deposit(g, amt, card) },
                                        onEdit: { editingGoal = $0 },
                                        onDelete: { deleteGoal($0) },
                                        onComplete: { completeGoal($0) },
                                        onPin: { togglePin($0) })
                                } label: {
                                    SeeAllLabel(count: activeGoals.count)
                                }
                            }
                        }
                        .padding(.horizontal, 22)
                    } else if goals.isEmpty {
                        GoalsEmptyState { goalSheet = .chooser }
                            .padding(.top, 12)
                    }

                    UnitySavingsSection(onCreate: { goalSheet = .shared })

                    if !completedGoals.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionTitle(loc("savings.completed_title"))
                            VStack(spacing: 0) {
                                ForEach(Array(completedGoals.enumerated()), id: \.element.id) { i, goal in
                                    if i > 0 {
                                        Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 70)
                                    }
                                    CompletedGoalRow(goal: goal) {
                                        HapticManager.shared.tap(); completedActions = goal
                                    }
                                }
                            }
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        }
                        .padding(.horizontal, 22)
                    }

                    Spacer(minLength: 100)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)
            }

            if let goal = celebratingGoal {
                GoalCelebration(goal: goal) {
                    withAnimation { celebratingGoal = nil }
                }
                .transition(.opacity)
                .zIndex(999)
            }
        }
        .featureBar(pushed: pushed)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true }
        }
        .sheet(item: $goalSheet) { which in
            switch which {
            case .chooser:
                GoalTypeChooserView(onPersonal: { goalSheet = .personal },
                                    onShared:   { goalSheet = .shared })
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
            case .personal:
                GoalFormSheet(editGoal: nil)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
            case .shared:
                SharedGoalFormSheet()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
            }
        }
        .sheet(item: $editingGoal) { goal in
            GoalFormSheet(editGoal: goal)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        // Reached goals had a swipe-to-delete that never worked: `.swipeActions`
        // only exists inside a List, and these rows sit in a ScrollView. So a
        // reached goal could not be removed at all.
        .sheet(item: $completedActions) { goal in
            ActionListSheet(
                icon: "checkmark.seal.fill",
                title: goal.name,
                subtitle: String(format: loc("savings.saved_amount_row"),
                                 CurrencyManager.shared.formatted(goal.savedAmount, currency: goal.currency)),
                items: [
                    ActionItem(icon: "arrow.uturn.backward", title: loc("savings.reopen"),
                               detail: loc("savings.reopen_sub"), tint: AppTheme.blue) {
                        goal.isCompleted = false
                        try? context.save()
                        HapticManager.shared.success()
                    },
                    ActionItem(icon: "trash.fill", title: loc("common.delete"), destructive: true) {
                        deletingCompleted = goal
                    },
                ])
            .preferredColorScheme(appColorScheme())
        }
        .confirmSheet(item: $deletingCompleted,
                      title: { String(format: loc("savings.delete_title"), $0.name) },
                      message: { _ in loc("savings.delete_confirm") },
                      confirmLabel: loc("common.delete")) { goal in
            deleteGoal(goal)
        }
        } // end FeatureStack
        } // end PremiumGate
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("profile.savings"))
                    .font(.system(.title, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(String(format: loc("savings.active_goals"), activeGoals.count))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Button {
                HapticManager.shared.tap(); goalSheet = .chooser
            } label: {
                Image(systemName: "plus")
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(AppTheme.onVividFill)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.accentFill, in: Circle())
            }
            .accessibilityLabel(loc("a11y.add_goal"))
            .buttonStyle(ScaleButtonStyle())
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, weight: .bold))
            .foregroundStyle(AppTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deposit(_ goal: SavingsGoal, _ amount: Double, _ card: BankCard?) {
        let reached = goal.recordDeposit(amount, from: card, context: context)
        HapticManager.shared.success()
        if reached {
            HapticManager.shared.rigidImpact()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { celebratingGoal = goal }
            }
            goal.announceReached()
        }
    }

    private func completeGoal(_ goal: SavingsGoal) {
        goal.isCompleted = true
        try? context.save()
        HapticManager.shared.rigidImpact()
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { celebratingGoal = goal }
    }

    private func deleteGoal(_ goal: SavingsGoal) {
        let name = goal.name
        context.delete(goal)
        try? context.save()
        HapticManager.shared.warning()
        ActionFeedbackCenter.shared.removed(loc("feedback.goal_deleted"), detail: name)
    }

    private func togglePin(_ goal: SavingsGoal) {
        // Only one goal is shown on Home at a time.
        if !goal.isPinned {
            for g in goals where g.isPinned { g.isPinned = false }
        }
        goal.isPinned.toggle()
        try? context.save()
        HapticManager.shared.select()
    }
}

// MARK: - All Personal Goals (full-list page)

struct AllPersonalGoalsView: View {
    let goals: [SavingsGoal]
    let monthlyIncome: Double
    let onDeposit: (SavingsGoal, Double, BankCard?) -> Void
    let onEdit: (SavingsGoal) -> Void
    let onDelete: (SavingsGoal) -> Void
    let onComplete: (SavingsGoal) -> Void
    let onPin: (SavingsGoal) -> Void

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 14) {
                    ForEach(goals) { goal in
                        GoalCard(goal: goal, monthlyIncome: monthlyIncome,
                                 onDeposit: { amt, card in onDeposit(goal, amt, card) },
                                 onEdit: { onEdit(goal) },
                                 onDelete: { onDelete(goal) },
                                 onComplete: { onComplete(goal) },
                                 onPin: { onPin(goal) })
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
        }
        .navigationTitle(loc("savings.in_progress"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

// MARK: - Goals Summary Card

struct GoalsSummaryCard: View {
    let totalSaved: Double
    let totalTarget: Double
    let monthlyPlan: Double
    let monthlyIncome: Double
    let goalCount: Int

    private var progress: Double { totalTarget > 0 ? min(totalSaved / totalTarget, 1.0) : 0 }
    private var pref: String { CurrencyManager.shared.preferredCurrency }

    var body: some View {
        let cm = CurrencyManager.shared
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(loc("savings.overall"))
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(cm.formatted(totalSaved, currency: pref))
                        .font(.system(.largeTitle, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    Spacer(minLength: 8)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(.title3, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                }
                Text(String(format: loc("savings.of_across"), cm.formatted(totalTarget, currency: pref), goalCount))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            SavingsProgressBar(progress: progress, height: 10)

            if monthlyPlan > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "repeat")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                    Text(loc("savings.monthly"))
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Text(String(format: loc("savings.save_per_mo"), cm.formatted(monthlyPlan, currency: pref)))
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    if monthlyIncome > 0 {
                        Text("· " + String(format: loc("savings.pct_of_income"),
                                           String(format: "%.0f", monthlyPlan / monthlyIncome * 100)))
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
        }
        .padding(18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }
}

struct SavingsProgressBar: View {
    let progress: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.cardMid)
                Capsule().fill(AppTheme.accentFill)
                    .frame(width: max(g.size.width * CGFloat(progress), progress > 0 ? height : 0))
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.8, dampingFraction: 0.8), value: progress)
    }
}

// MARK: - Goal Card

struct GoalCard: View {
    let goal: SavingsGoal
    let monthlyIncome: Double
    let onDeposit: (Double, BankCard?) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onComplete: () -> Void
    let onPin: () -> Void

    @State private var showDepositSheet = false
    @State private var showActions      = false
    @State private var showDeleteConfirm = false

    private var suggestedMonthly: Double { goal.remaining > 0 ? goal.remaining / 12 : 0 }

    private var planLine: (icon: String, text: String, tint: Color)? {
        let cm = CurrencyManager.shared
        if goal.progress >= 1.0 {
            return ("checkmark.seal.fill", loc("savings.reached"), AppTheme.accent)
        }
        if let date = goal.estimatedDate {
            let when = date.formatted(.dateTime.month(.abbreviated).year())
            return ("calendar", String(format: loc("savings.goal_reached_around"), when)
                    + " · " + String(format: loc("savings.save_per_mo"),
                                     cm.formatted(goal.monthlyContribution, currency: goal.currency)),
                    AppTheme.textSecondary)
        }
        if suggestedMonthly > 0 {
            return ("lightbulb", String(format: loc("savings.suggested_per_mo"),
                                        cm.formatted(suggestedMonthly, currency: goal.currency)),
                    AppTheme.orange)
        }
        return nil
    }

    var body: some View {
        let cm = CurrencyManager.shared
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink(destination: GoalDetailView(goal: goal, monthlyIncome: monthlyIncome)) {
                HStack(spacing: 12) {
                    Text(goal.emoji)
                        .font(.system(.title2))
                        .frame(width: 48, height: 48)
                        .background(AppTheme.cardMid.opacity(0.7), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(goal.name)
                            .font(.system(.body, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Circle().fill(goal.priorityColor).frame(width: 6, height: 6)
                            Text(String(format: loc("savings.priority_fmt"), goal.priorityLabel))
                            if goal.isPinned {
                                Text("·")
                                Image(systemName: "pin.fill").imageScale(.small)
                                Text(loc("savings.on_home"))
                            }
                        }
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(cm.formatted(goal.savedAmount, currency: goal.currency))
                        .font(.system(.title2, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    Text(String(format: loc("savings.of_target"), cm.formatted(goal.targetAmount, currency: goal.currency)))
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Text("\(Int((goal.progress * 100).rounded()))%")
                        .font(.system(.footnote, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                }
                SavingsProgressBar(progress: goal.progress)
                if let line = planLine {
                    Label(line.text, systemImage: line.icon)
                        .font(.system(.caption))
                        .foregroundStyle(line.tint)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 10) {
                Button {
                    HapticManager.shared.tap(); showDepositSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").font(.system(.callout))
                        Text(loc("savings.add")).font(.system(.subheadline, weight: .bold))
                    }
                    .foregroundStyle(AppTheme.onVividFill)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
                }
                .buttonStyle(ScaleButtonStyle())

                Button {
                    HapticManager.shared.tap(); showActions = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(width: 46, height: 46)
                        .background(AppTheme.cardMid.opacity(0.7), in: RoundedRectangle(cornerRadius: AppRadius.md))
                }
                .accessibilityLabel(loc("a11y.more_actions"))
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        .sheet(isPresented: $showActions) {
            ActionListSheet(
                icon: "target",
                title: goal.name,
                subtitle: String(format: loc("savings.saved_of"),
                                 cm.formatted(goal.savedAmount, currency: goal.currency),
                                 cm.formatted(goal.targetAmount, currency: goal.currency)),
                items: [
                    ActionItem(icon: "pencil", title: loc("common.edit"), tint: AppTheme.blue) { onEdit() },
                    ActionItem(icon: goal.isPinned ? "pin.slash.fill" : "pin.fill",
                               title: goal.isPinned ? loc("savings.unpin") : loc("savings.pin"),
                               detail: goal.isPinned ? nil : loc("savings.pin_sub"),
                               tint: AppTheme.purple) { onPin() },
                    ActionItem(icon: "flag.checkered", title: loc("savings.complete"),
                               detail: loc("savings.complete_sub"), tint: AppTheme.teal) { onComplete() },
                    ActionItem(icon: "trash.fill", title: loc("common.delete"), destructive: true) {
                        showDeleteConfirm = true
                    },
                ])
            .preferredColorScheme(appColorScheme())
        }
        .confirmSheet(isPresented: $showDeleteConfirm,
                      title: String(format: loc("savings.delete_title"), goal.name),
                      message: goal.deleteImpactMessage,
                      confirmLabel: loc("common.delete")) { onDelete() }
        .sheet(isPresented: $showDepositSheet) {
            DepositSheet(goal: goal, onDeposit: { amount, card in
                showDepositSheet = false
                onDeposit(amount, card)
            })
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.bg)
        }
    }
}

// MARK: - Deposit Sheet

struct DepositSheet: View {
    let goal: SavingsGoal
    /// `card` is the account the money leaves; every deposit becomes a real
    /// transaction so balances, statistics and the budget see it.
    let onDeposit: (Double, BankCard?) -> Void
    @State private var amountText = ""
    @State private var sourceIndex = 0
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]

    var amount: Double { Double(amountText) ?? 0 }
    /// Cash accounts only — a goal can't be funded from a credit line.
    private var fundingCards: [BankCard] { cards.filter { !$0.isCreditCard } }
    private var selectedCard: BankCard? {
        fundingCards.indices.contains(sourceIndex) ? fundingCards[sourceIndex] : fundingCards.first
    }
    private var canDeposit: Bool { amount > 0 && selectedCard != nil }

    var body: some View {
        let cm = CurrencyManager.shared
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Text(goal.emoji).font(.system(.largeTitle))
                        Text(String(format: loc("savings.add_to"), goal.name))
                            .font(.system(.title3, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .multilineTextAlignment(.center)
                        Text(String(format: loc("savings.saved_of"),
                                    cm.formatted(goal.savedAmount, currency: goal.currency),
                                    cm.formatted(goal.targetAmount, currency: goal.currency)))
                            .font(.system(.subheadline))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.top, 24)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Text(CurrencyManager.symbol(for: goal.currency))
                                .font(.system(.subheadline, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .padding(.horizontal, 13).padding(.vertical, 12)
                                .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                            TextField("0", text: $amountText)
                                .font(.system(.largeTitle, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .keyboardType(.decimalPad)
                        }
                        .padding(14)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        if let p = AmountInputHelper.preview(amountText, currency: goal.currency) {
                            Text(p).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 22)

                    quickAmounts.padding(.horizontal, 22)

                    VStack(alignment: .leading, spacing: 10) {
                        FormSectionLabel(text: loc("savings.source_account"))
                            .padding(.horizontal, 22)
                        if fundingCards.isEmpty {
                            InlineBanner(tone: .warning, message: loc("savings.reconcile_no_account"))
                                .padding(.horizontal, 22)
                        } else {
                            CardSwipePicker(cards: fundingCards, selectedIndex: $sourceIndex) { card in
                                (loc("home.balance_total"), card.formattedBalance)
                            }
                            Text(loc("savings.source_account_sub"))
                                .font(.system(.caption))
                                .foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 22)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }

            // Pinned — never scrolls out of reach.
            Button {
                guard canDeposit else { return }
                HapticManager.shared.success()
                onDeposit(amount, selectedCard)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(.body))
                    Text(amount > 0
                         ? String(format: loc("savings.add_amount"), cm.formatted(amount, currency: goal.currency))
                         : loc("savings.add"))
                        .font(.system(.callout, weight: .bold))
                }
                .foregroundStyle(canDeposit ? AppTheme.onVividFill : AppTheme.textSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(canDeposit ? AppTheme.accentFill : AppTheme.cardMid,
                            in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!canDeposit)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(AppTheme.bg)
        }
        .onAppear {
            // Start on the main card when it can fund a deposit.
            if let main = MainCard.resolve(in: cards), let i = fundingCards.firstIndex(where: { $0.id == main.id }) {
                sourceIndex = i
            }
        }
    }

    private var quickAmounts: some View {
        let cm = CurrencyManager.shared
        let values: [Double] = goal.currency == "IDR" ? [50_000, 100_000, 500_000, 1_000_000]
            : goal.currency == "JPY" ? [1_000, 5_000, 10_000, 50_000] : [10, 50, 100, 500]
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return VStack(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(values, id: \.self) { v in
                    Button {
                        HapticManager.shared.tap()
                        // Adds to what is typed, so two taps mean twice the amount.
                        amountText = SavingsNumber.edit(amount + v, currency: goal.currency)
                    } label: {
                        Text("+" + cm.formatted(v, currency: goal.currency))
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
            if goal.monthlyContribution > 0 {
                Button {
                    HapticManager.shared.tap()
                    amountText = SavingsNumber.edit(goal.monthlyContribution, currency: goal.currency)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "repeat").font(.system(.caption, weight: .semibold))
                        Text(loc("savings.monthly")).font(.system(.footnote))
                        Text(cm.formatted(goal.monthlyContribution, currency: goal.currency))
                            .font(.system(.footnote, weight: .bold))
                    }
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(AppTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                }
                .buttonStyle(ScaleButtonStyle())
            }
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
                        .font(.system(.title, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(goal.name)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                    Text(String(format: loc("savings.you_saved"),
                                CurrencyManager.shared.formatted(goal.targetAmount, currency: goal.currency)))
                        .font(.system(.subheadline))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .scaleEffect(scale)
                .opacity(opacity)

                Button {
                    HapticManager.shared.success()
                    onDismiss()
                } label: {
                    Text(loc("savings.amazing"))
                        .font(.system(.callout, weight: .bold))
                        .foregroundStyle(AppTheme.bg)
                        .padding(.horizontal, 48).padding(.vertical, 16)
                        .background(AppTheme.accentFill, in: Capsule())
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
        AppTheme.blue, AppTheme.fuchsia, AppTheme.amber,
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
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(goal.emoji).font(.system(.title3))
                .frame(width: 44, height: 44)
                .background(AppTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.sm))
            VStack(alignment: .leading, spacing: 3) {
                Text(goal.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                // The amount actually saved — this showed the TARGET, with the
                // word "saved" hardcoded in English.
                Text(String(format: loc("savings.saved_amount_row"),
                            CurrencyManager.shared.formatted(goal.savedAmount, currency: goal.currency)))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 6)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(.title3))
                .foregroundStyle(AppTheme.accent)
            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.cardMid.opacity(0.7), in: Circle())
            }
            .accessibilityLabel(loc("a11y.more_actions"))
            .hitTarget(32)
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(14)
    }
}

// MARK: - Empty State

struct GoalsEmptyState: View {
    let onAdd: () -> Void
    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.14)).frame(width: 120, height: 120)
                Circle().fill(AppTheme.accentFill).frame(width: 76, height: 76)
                Image(systemName: "target")
                    .font(.system(.title, weight: .semibold))
                    .foregroundStyle(AppTheme.onVividFill)
            }
            VStack(spacing: 8) {
                Text(loc("savings.no_goals"))
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("savings.empty_goals"))
                    .font(.system(.subheadline))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { HapticManager.shared.tap(); onAdd() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.system(.body))
                    Text(loc("savings.add_goal")).font(.system(.callout, weight: .bold))
                }
                .foregroundStyle(AppTheme.onVividFill)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 32)
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
    @State private var notes        = ""
    @State private var appeared     = false
    @State private var errorMsg: String? = nil

    let emojis = ["🎯","🚗","🏠","✈️","💻","📱","🎓","💍","⛵","🎸","🏋️","👶","🌏","💰","🏖️","🎮"]
    private var isEditing: Bool { editGoal != nil }

    private var monthsPreview: Int? {
        guard let target = Double(targetAmount),
              let saved  = Double(savedAmount.isEmpty ? "0" : savedAmount),
              let mo     = Double(monthly),
              mo > 0, target > saved else { return nil }
        return Int(ceil((target - saved) / mo))
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (Double(targetAmount) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            ZStack { AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        emojiSection
                        IconField(label: loc("savings.description"), icon: "target",
                                  placeholder: loc("savings.description_placeholder"), text: $name)
                            .padding(.horizontal, 22)
                        targetSection
                        VStack(spacing: 14) {
                            amountField(label: loc("savings.already"), icon: "tray.full", text: $savedAmount)
                            amountField(label: loc("savings.monthly_sav"), icon: "repeat", text: $monthly)
                        }
                        .padding(.horizontal, 22)
                        prioritySection
                        if let months = monthsPreview { previewCard(months) }
                        if let err = errorMsg {
                            InlineBanner(tone: .error, message: err).padding(.horizontal, 22)
                        }
                        Button { save() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill").font(.system(.body))
                                Text(loc("savings.save_goal")).font(.system(.callout, weight: .bold))
                            }
                            .foregroundStyle(canSave ? AppTheme.onVividFill : AppTheme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 17)
                            .background(canSave ? AppTheme.accentFill : AppTheme.textSecondary.opacity(0.25),
                                        in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .disabled(!canSave)
                        .padding(.horizontal, 22)
                        Spacer(minLength: 30)
                    }
                    .padding(.top, 8)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                    .animation(AppMotion.appear, value: appeared)
                }
            }
            .navigationTitle(isEditing ? loc("savings.edit_title") : loc("savings.new_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { HapticManager.shared.tap(); dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        .onAppear {
            if let g = editGoal {
                name = g.name; emoji = g.emoji
                // "20000000", not "20000000.0".
                targetAmount = SavingsNumber.edit(g.targetAmount, currency: g.currency)
                savedAmount  = SavingsNumber.edit(g.savedAmount, currency: g.currency)
                monthly      = SavingsNumber.edit(g.monthlyContribution, currency: g.currency)
                currency = g.currency; priority = g.priority; notes = g.notes
            }
            withAnimation { appeared = true }
        }
    }

    private var emojiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormSectionLabel(text: loc("savings.choose_emoji")).padding(.horizontal, 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(emojis, id: \.self) { e in
                        let on = emoji == e
                        Button { HapticManager.shared.tap(); emoji = e } label: {
                            Text(e).font(.system(.title2))
                                .frame(width: 54, height: 54)
                                .background(on ? AppTheme.accent.opacity(0.16) : AppTheme.cardDark,
                                            in: RoundedRectangle(cornerRadius: AppRadius.md))
                                .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                                    .stroke(on ? AppTheme.accent.opacity(0.65) : Color.clear, lineWidth: 1.5))
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 2)
            }
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FormSectionLabel(text: loc("savings.target_amt"))
            HStack(spacing: 12) {
                // Every currency the app can price — this was USD and IDR only.
                Menu {
                    ForEach(CurrencyManager.supportedCurrencies, id: \.code) { c in
                        Button("\(c.flag) \(c.code)") { currency = c.code }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(CurrencyManager.symbol(for: currency))
                            .font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                        Text(currency)
                            .font(.system(.footnote, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(.caption2)).imageScale(.small).foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                }
                TextField("0", text: $targetAmount)
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .keyboardType(.decimalPad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            if let p = AmountInputHelper.preview(targetAmount, currency: currency) {
                Text(p).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 22)
    }

    private func amountField(label: String, icon: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            IconField(label: label, icon: icon, placeholder: "0", text: text, keyboard: .decimalPad)
            if let p = AmountInputHelper.preview(text.wrappedValue, currency: currency) {
                Text(p).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private var prioritySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormSectionLabel(text: loc("savings.priority_title"))
            HStack(spacing: 10) {
                ForEach([(1, loc("savings.high"), AppTheme.red),
                         (2, loc("savings.medium"), AppTheme.orange),
                         (3, loc("savings.low"), AppTheme.blue)], id: \.0) { p, label, color in
                    let on = priority == p
                    Button { HapticManager.shared.tap(); priority = p } label: {
                        HStack(spacing: 6) {
                            Circle().fill(color).frame(width: 8, height: 8)
                            Text(label).font(.system(.subheadline, weight: on ? .semibold : .regular))
                        }
                        .foregroundStyle(on ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(on ? color.opacity(0.14) : AppTheme.cardDark,
                                    in: RoundedRectangle(cornerRadius: AppRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                            .stroke(on ? color.opacity(0.6) : Color.clear, lineWidth: 1.5))
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
        }
        .padding(.horizontal, 22)
    }

    private func previewCard(_ months: Int) -> some View {
        let when = Calendar.current.date(byAdding: .month, value: months, to: .now)
        return HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.system(.subheadline, weight: .bold))
                .foregroundStyle(AppTheme.onVividFill)
                .frame(width: 34, height: 34)
                .background(AppTheme.accentFill, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: loc("savings.reach_in_months"), months))
                    .font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                if let when {
                    Text(String(format: loc("savings.around_date"),
                                when.formatted(.dateTime.month(.wide).year())))
                        .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .padding(.horizontal, 22)
        .animation(.spring(response: 0.4), value: months)
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
        ActionFeedbackCenter.shared.goalSaved(
            name: name.trimmingCharacters(in: .whitespaces), emoji: emoji, isUpdate: editGoal != nil)
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
    @State private var showPastDepositSheet = false
    @State private var showEdit = false
    @State private var showDelete = false
    @State private var animatedProgress: Double = 0
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]

    private var currency: String { goal.currency }
    private var allTx: [TxRecord] { cards.flatMap(\.transactions) }
    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: currency) }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    hero
                    numbers
                    sourceCard
                    actions
                    if !goal.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            FormSectionLabel(text: loc("common.notes"))
                            Text(goal.notes).font(.system(.subheadline)).foregroundStyle(AppTheme.textPrimary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                    }
                    Spacer(minLength: 30)
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
            }
        }
        .navigationTitle(goal.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(AppTheme.bg, for: .navigationBar)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).delay(0.2)) { animatedProgress = goal.progress }
        }
        .onChange(of: goal.progress) { _, p in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { animatedProgress = p }
        }
        .sheet(isPresented: $showDepositSheet) {
            DepositSheet(goal: goal, onDeposit: { amount, card in
                showDepositSheet = false
                // The same deposit path as the list, including the goal-reached
                // notification this screen never sent.
                if goal.recordDeposit(amount, from: card, context: context) {
                    HapticManager.shared.rigidImpact()
                    goal.announceReached()
                } else {
                    HapticManager.shared.success()
                }
            })
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.bg)
        }
        .sheet(isPresented: $showPastDepositSheet) {
            RecordPastDepositSheet(goal: goal)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .sheet(isPresented: $showEdit) {
            GoalFormSheet(editGoal: goal)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .confirmSheet(isPresented: $showDelete,
                      title: String(format: loc("savings.delete_title"), goal.name),
                      message: goal.deleteImpactMessage,
                      confirmLabel: loc("common.delete")) {
            // Close this screen first, then delete: SwiftData traps on a view
            // reading a deleted model.
            let name = goal.name
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                context.delete(goal)
                try? context.save()
                HapticManager.shared.warning()
                ActionFeedbackCenter.shared.removed(loc("feedback.goal_deleted"), detail: name)
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(AppTheme.cardMid, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: animatedProgress)
                    .stroke(AppTheme.accentFill, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(goal.emoji).font(.system(size: 38))
                    Text("\(Int((goal.progress * 100).rounded()))%")
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .contentTransition(.numericText())
                }
            }
            .frame(width: 124, height: 124)

            VStack(spacing: 4) {
                Text(money(goal.savedAmount))
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text(String(format: loc("savings.of_target"), money(goal.targetAmount)))
                    .font(.system(.subheadline))
                    .foregroundStyle(AppTheme.textSecondary)
                HStack(spacing: 6) {
                    Circle().fill(goal.priorityColor).frame(width: 7, height: 7)
                    Text(String(format: loc("savings.priority_fmt"), goal.priorityLabel))
                    if goal.isPinned {
                        Text("·")
                        Image(systemName: "pin.fill").imageScale(.small)
                        Text(loc("savings.on_home"))
                    }
                }
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }

    /// The figures, as one list — "still needed", the monthly plan, and when
    /// that plan gets there.
    private var numbers: some View {
        VStack(spacing: 0) {
            row(loc("savings.remaining"), money(goal.remaining))
            if goal.monthlyContribution > 0 {
                divider
                row(loc("savings.monthly_sav"), money(goal.monthlyContribution)
                    + (monthlyIncome > 0
                       ? "  ·  " + String(format: loc("savings.pct_of_income"),
                                          String(format: "%.0f", goal.monthlyContribution / monthlyIncome * 100))
                       : ""))
                if let months = goal.monthsToGoal, let date = goal.estimatedDate {
                    divider
                    row(loc("savings.reached_label"),
                        String(format: loc("savings.months_left_fmt"), months) + "  ·  "
                        + date.formatted(.dateTime.month(.abbreviated).year()))
                }
            } else if goal.remaining > 0 {
                divider
                row(loc("savings.monthly_sav"), loc("savings.set_monthly"), tint: AppTheme.orange)
            }
        }
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private var divider: some View {
        Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 16)
    }

    private func row(_ label: String, _ value: String, tint: Color = AppTheme.textPrimary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(value).font(.system(.subheadline, weight: .semibold)).foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    /// Where the saved money came from: what the user already had before DiPo
    /// (no record needed) and what was added through DiPo (recorded).
    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            FormSectionLabel(text: loc("savings.breakdown_title"))
            VStack(spacing: 8) {
                HStack {
                    Text(loc("savings.opening_balance")).font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Text(money(goal.openingBalance(from: allTx))).font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                }
                HStack {
                    Text(loc("savings.recorded_deposits")).font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Text(money(goal.trackedDeposits(from: allTx))).font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                }
            }
            Text(loc("savings.breakdown_hint"))
                .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                HapticManager.shared.tap(); showDepositSheet = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill").font(.system(.body))
                    Text(loc("savings.add")).font(.system(.callout, weight: .bold))
                }
                .foregroundStyle(AppTheme.onVividFill)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())

            VStack(spacing: 0) {
                linkRow("pencil", AppTheme.blue, loc("common.edit"), nil) { showEdit = true }
                divider.padding(.leading, 46)
                linkRow(goal.isPinned ? "pin.slash.fill" : "pin.fill", AppTheme.purple,
                        goal.isPinned ? loc("savings.unpin") : loc("savings.pin"),
                        goal.isPinned ? nil : loc("savings.pin_sub")) {
                    goal.isPinned.toggle(); try? context.save(); HapticManager.shared.select()
                }
                divider.padding(.leading, 46)
                linkRow("clock.arrow.circlepath", AppTheme.teal, loc("savings.record_past"),
                        loc("savings.record_past_sub")) { showPastDepositSheet = true }
                divider.padding(.leading, 46)
                linkRow("trash.fill", AppTheme.red, loc("common.delete"), nil, destructive: true) {
                    HapticManager.shared.warning(); showDelete = true
                }
            }
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
    }

    private func linkRow(_ icon: String, _ tint: Color, _ title: String, _ detail: String?,
                         destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.tap(); action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(destructive ? AppTheme.onVividFill : tint)
                    .frame(width: 36, height: 36)
                    .background(destructive ? tint : tint.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(destructive ? AppTheme.red : AppTheme.textPrimary)
                    if let detail {
                        Text(detail).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 6)
                if !destructive {
                    Image(systemName: "chevron.right").font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Record a deposit that already happened
//
// For money that already moved into the goal without being logged — e.g. a
// transfer made straight from the banking app. It writes ONLY the transaction:
// the goal's saved total already includes this money, so adding to it again
// would inflate the goal.
struct RecordPastDepositSheet: View {
    let goal: SavingsGoal
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]

    @State private var amountText = ""
    @State private var sourceIndex = 0
    @State private var date = Date()

    private var amount: Double { Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var fundingCards: [BankCard] { cards.filter { !$0.isCreditCard } }
    private var selectedCard: BankCard? {
        fundingCards.indices.contains(sourceIndex) ? fundingCards[sourceIndex] : fundingCards.first
    }
    private var canSave: Bool { amount > 0 && selectedCard != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(loc("savings.past_intro"))
                            .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 22)

                        VStack(alignment: .leading, spacing: 8) {
                            FormSectionLabel(text: loc("savings.past_amount"))
                            HStack(spacing: 12) {
                                Text(CurrencyManager.symbol(for: goal.currency))
                                    .font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                    .padding(.horizontal, 13).padding(.vertical, 12)
                                    .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                                TextField("0", text: $amountText)
                                    .font(.system(.largeTitle, weight: .bold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .keyboardType(.decimalPad)
                            }
                            .padding(14)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        }
                        .padding(.horizontal, 22)

                        VStack(alignment: .leading, spacing: 10) {
                            FormSectionLabel(text: loc("savings.source_account")).padding(.horizontal, 22)
                            if fundingCards.isEmpty {
                                InlineBanner(tone: .warning, message: loc("savings.reconcile_no_account"))
                                    .padding(.horizontal, 22)
                            } else {
                                CardSwipePicker(cards: fundingCards, selectedIndex: $sourceIndex) { card in
                                    (loc("home.balance_total"), card.formattedBalance)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            FormSectionLabel(text: loc("savings.past_date"))
                            HStack(spacing: 10) {
                                Image(systemName: "calendar").foregroundStyle(AppTheme.textSecondary)
                                DatePicker("", selection: $date, in: ...Date(), displayedComponents: .date)
                                    .datePickerStyle(.compact).labelsHidden().tint(AppTheme.accent)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                            Text(loc("savings.past_note"))
                                .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 22)

                        Button {
                            guard canSave else { return }
                            HapticManager.shared.success()
                            save()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill").font(.system(.body))
                                Text(loc("savings.past_save")).font(.system(.callout, weight: .bold))
                            }
                            .foregroundStyle(canSave ? AppTheme.onVividFill : AppTheme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(canSave ? AppTheme.accentFill : AppTheme.cardMid,
                                        in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .disabled(!canSave)
                        .padding(.horizontal, 22)

                        Spacer(minLength: 20)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle(loc("savings.record_past"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
    }

    /// Writes the transaction only — `goal.savedAmount` already contains this
    /// money, so touching it would double the goal's progress.
    private func save() {
        guard let card = selectedCard else { return }
        let debited = CurrencyManager.shared.convert(amount, from: goal.currency, to: card.resolvedCurrency)
        let tx = TxRecord(
            name: String(format: loc("savings.tx_name"), goal.name),
            date: date,
            amount: -debited,
            type: "tx.type.purchase",
            icon: goal.emoji,
            iconBgHex: TxCategory.investment.iconBg,
            category: .investment,
            currency: card.resolvedCurrency,
            notes: "tx.note.goal_backfill",
            linkedGoalID: goal.id.uuidString)
        context.insert(tx)
        card.transactions.append(tx)
        try? context.save()
        dismiss()
    }
}
