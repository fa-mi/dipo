import SwiftUI
import SwiftData

// MARK: - Plan tab
//
// The money features people check every week — budget, salary, bills, savings —
// used to be rows in Profile, each opening a sheet on top of it (Profile →
// Salary → form → ⋯ was three sheets deep, and one stray swipe closed the lot).
// They live here now and open by push, so there is always a back button and
// sheets are left for short tasks: forms and confirmations.

struct PlanView: View {
    @Bindable var vm: AppViewModel
    @Query(sort: \SalarySchedule.createdAt) private var schedules: [SalarySchedule]
    @Query private var bills: [RecurringExpense]
    @Query private var goals: [SavingsGoal]
    @Query private var holdings: [InvestmentHolding]
    @State private var pm = PremiumManager.shared
    @State private var budget = SmartBudgetManager.shared
    @State private var showPaywall = false
    @State private var showAskDiPo = false

    var body: some View {
        NavigationStack(path: $vm.planPath) {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        section(loc("plan.section_month")) {
                            row(.budget, icon: "chart.pie.fill", tint: AppTheme.accent,
                                title: loc("profile.budget"), status: budgetStatus,
                                feature: .smartBudget)
                            divider
                            row(.salary, icon: "banknote.fill", tint: AppTheme.blue,
                                title: loc("profile.salary"), status: salaryStatus)
                            divider
                            row(.bills, icon: "arrow.triangle.2.circlepath", tint: AppTheme.orange,
                                title: loc("profile.recurring"), status: billsStatus)
                        }
                        section(loc("plan.section_goals")) {
                            row(.goals, icon: "target", tint: AppTheme.teal,
                                title: loc("profile.savings"), status: goalsStatus,
                                feature: .savingsGoals)
                            divider
                            row(.investments, icon: "chart.line.uptrend.xyaxis", tint: AppTheme.accent,
                                title: loc("premium.feature.investments"), status: investStatus,
                                feature: .investments)
                        }
                        section(loc("plan.section_help")) {
                            askRow
                        }
                        Spacer(minLength: 110)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                }
            }
            // Hidden, but still the back button's label on every screen below.
            .navigationTitle(loc("tab.plan"))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: PlanRoute.self) { route in
                switch route {
                case .budget: SmartBudgetSettingsSheet().pushedFeature()
                case .salary: SalaryView().pushedFeature()
                case .bills:  RecurringExpensesView().pushedFeature()
                case .goals:  WishlistView().pushedFeature()
                case .investments: InvestmentView().pushedFeature()
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
            }
            // A conversation, not a destination: it keeps its own input bar at
            // the bottom, where the tab bar would sit on a pushed screen.
            .sheet(isPresented: $showAskDiPo) {
                AIChatView()
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(loc("tab.plan"))
                .font(.system(.title, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(loc("plan.sub"))
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: Status lines — what each feature would tell you if you opened it

    private var budgetStatus: String {
        guard pm.canAccess(.smartBudget) else { return loc("profile.requires_royal") }
        return budget.isEnabled ? loc("profile.budget_active") : loc("budget.off")
    }

    private var salaryStatus: String {
        let active = schedules.filter(\.isActive)
        guard let salary = MainCard.anchorSalary(schedules) ?? active.first else {
            return loc("salary.no_salary")
        }
        return loc("salary.next_payday") + " · " + SalaryCycle(dayOfMonth: salary.dayOfMonth).countdown
    }

    private var billsStatus: String {
        let active = bills.filter(\.isActive)
        guard !active.isEmpty else { return loc("recurring.none_title") }
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        let total = active.reduce(0) { $0 + cm.convert($1.amount, from: $1.currency, to: pref) }
        return String(format: loc("plan.bills_status"), active.count, cm.formatted(total, currency: pref))
    }

    private var goalsStatus: String {
        guard pm.canAccess(.savingsGoals) else { return loc("profile.requires_royal") }
        let active = goals.filter { !$0.isCompleted }.count
        return active == 0 ? loc("savings.no_goals") : String(format: loc("savings.active_goals"), active)
    }

    private var investStatus: String {
        guard pm.canAccess(.investments) else { return loc("profile.requires_royal") }
        guard !holdings.isEmpty else { return loc("invest.status.empty") }
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        let entries = holdings.map { (type: $0.typeRaw, currency: $0.currency, stats: $0.stats()) }
        let total = PortfolioEngine.portfolio(entries, targetCurrency: pref,
                                              convert: { cm.convert($0, from: $1, to: $2) }).marketValue
        return String(format: loc("invest.status.summary"), holdings.count, cm.formatted(total, currency: pref))
    }

    // MARK: Building blocks

    private func section<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(.body, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
            VStack(spacing: 0) { rows() }
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
    }

    private var divider: some View {
        Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 68)
    }

    private func row(_ route: PlanRoute, icon: String, tint: Color, title: String,
                     status: String, feature: PremiumFeature? = nil) -> some View {
        let locked = feature.map { !pm.canAccess($0) } ?? false
        return Button {
            HapticManager.shared.tap()
            if locked { showPaywall = true } else { vm.planPath.append(route) }
        } label: {
            PlanRowLabel(icon: icon, tint: tint, title: title, status: status,
                         lockedPlan: locked ? feature?.requiredPlan : nil)
        }
        .buttonStyle(.plain)
    }

    private var askRow: some View {
        let locked = !pm.canAccess(.aiAdvisor)
        return Button {
            HapticManager.shared.tap()
            if locked { showPaywall = true } else { showAskDiPo = true }
        } label: {
            PlanRowLabel(icon: "sparkles", tint: AppTheme.purple,
                         title: loc("profile.ai_advisor"),
                         status: locked ? loc("profile.requires_royal") : loc("profile.ai_advisor_sub"),
                         lockedPlan: locked ? PremiumFeature.aiAdvisor.requiredPlan : nil)
        }
        .buttonStyle(.plain)
    }
}

/// One feature row: icon tile, name, a live status line, and a chevron — or the
/// plan it needs, when it is locked.
struct PlanRowLabel: View {
    let icon: String
    let tint: Color
    let title: String
    let status: String
    let lockedPlan: PremiumPlan?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(lockedPlan == nil ? tint : AppTheme.textSecondary)
                .frame(width: 40, height: 40)
                .background((lockedPlan == nil ? tint : AppTheme.textSecondary).opacity(0.14),
                            in: RoundedRectangle(cornerRadius: AppRadius.sm))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(status)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            if let plan = lockedPlan {
                HStack(spacing: 3) {
                    Image(systemName: plan.icon).imageScale(.small)
                    Text(plan.label)
                }
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(plan.color)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(plan.color.opacity(0.12), in: Capsule())
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
