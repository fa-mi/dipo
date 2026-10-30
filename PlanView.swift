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
    @Query private var cards: [BankCard]
    @Query private var debts: [DebtRecord]
    @Query private var physicalAssets: [PhysicalAsset]
    @Query private var installments: [CardInstallment]
    @State private var pm = PremiumManager.shared
    @State private var budget = SmartBudgetManager.shared
    @State private var showPaywall = false
    @State private var showAskDiPo = false
    /// Whether the rows waiting under More are shown.
    @State private var moreOpen = false
    /// Read from the whole history, so refreshed on save, not per render.
    @State private var ladder: LadderResult?
    /// DiPo Navigasi, the add-on: its row shows only while it is on.
    @AppStorage(Navigasi.enabledKey) private var naviOn = false
    @AppStorage(Navigasi.tripKey) private var naviTrip = Data()

    var body: some View {
        NavigationStack(path: $vm.planPath) {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        // Free for everyone: knowing what to do next with money
                        // is the point of DiPo, not a premium extra.
                        Button {
                            HapticManager.shared.tap()
                            vm.planPath.append(PlanRoute.ladder)
                        } label: {
                            FinancialLadderCard(result: ladder ?? computeLadder(),
                                                currency: CurrencyManager.shared.preferredCurrency)
                        }
                        .buttonStyle(.plain)
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
                            // Open when signed in: one personal goal at a time
                            // is free, and Target Bersama needs no Royal to take
                            // part in.
                            row(.goals, icon: "target", tint: AppTheme.teal,
                                title: loc("profile.savings"), status: goalsStatus,
                                feature: UserSession.shared.isLoggedIn ? nil : .savingsGoals)
                            if naviOn {
                                divider
                                row(.navigasi, icon: "location.north.circle.fill", tint: AppTheme.accent,
                                    title: loc("navi.title"), status: naviStatus,
                                    feature: UserSession.shared.isLoggedIn ? nil : .savingsGoals)
                            }
                            if !folded.contains(.investments) {
                                divider
                                investmentsRow
                            }
                            if !folded.contains(.assets) {
                                divider
                                assetsRow
                            }
                        }
                        // What is owed and what is owed back belongs with the plan,
                        // not with the cards: it used to sit under Wallet, so
                        // checking a debt meant switching tabs mid-plan.
                        section(loc("plan.section_debts")) {
                            row(.obligations, icon: "scalemass.fill", tint: AppTheme.teal,
                                title: loc("oblig.nav"), status: debtsStatus,
                                feature: .smartDebt)
                        }
                        section(loc("plan.section_help")) {
                            askRow
                        }
                        if !folded.isEmpty {
                            moreCard
                        }
                        Spacer(minLength: 110)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    // Centred and capped, like Home (AppLayout).
                    .phoneWidthCapped()
                    .containerRelativeFrame(.horizontal)
                }
            }
            // Hidden, but still the back button's label on every screen below.
            .navigationTitle(loc("tab.plan"))
            .toolbar(.hidden, for: .navigationBar)
            .onStoreChange { ladder = computeLadder() }
            .navigationDestination(for: PlanRoute.self) { route in
                switch route {
                case .budget: SmartBudgetSettingsSheet().pushedFeature()
                case .salary: SalaryView().pushedFeature()
                case .bills:  RecurringExpensesView().pushedFeature()
                case .goals:  WishlistView().pushedFeature()
                case .investments: InvestmentView().pushedFeature()
                case .holding(let h): HoldingDetailView(holding: h).pushedFeature()
                case .ladder: FinancialLadderView().pushedFeature()
                case .assets: AssetsView().pushedFeature()
                case .obligations: ObligationsView().pushedFeature()
                case .navigasi: NavigasiView().pushedFeature()
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

    private func computeLadder() -> LadderResult {
        FinancialLadder.evaluate(.gather(cards: cards, debts: debts, holdings: holdings, goals: goals,
                                         salaries: schedules,
                                         currency: CurrencyManager.shared.preferredCurrency,
                                         installments: installments))
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
        guard UserSession.shared.isLoggedIn else { return loc("profile.requires_royal") }
        let active = goals.filter { !$0.isCompleted }.count
        return active == 0 ? loc("savings.no_goals") : SavingsGoal.inProgressText(active)
    }

    /// Where the trip is headed and when it arrives, or that it is off route.
    private var naviStatus: String {
        guard let trip = Navigasi.Trip.decode(naviTrip),
              let goal = goals.first(where: { $0.id == trip.goalID }) else { return loc("navi.status_pick") }
        let name = "\(goal.emoji) \(goal.name)"
        guard goal.isCompleted || goal.monthlyContribution > 0 else { return loc("navi.choose_route") }
        let status = Navigasi.status(of: trip, goal: goal, cards: cards, salaries: schedules)
        switch status.leg {
        case .arrived:
            return String(format: loc("navi.arrived_sub"), name)
        case .behind(let short, _):
            return String(format: loc("navi.status_behind"),
                          CurrencyManager.shared.formatted(short, currency: goal.currency))
        case .setAside, .done, .accepted:
            return String(format: loc("navi.status_on"), name, status.arrival.map(Navigasi.monthYear) ?? "")
        }
    }

    private var investStatus: String {
        guard pm.canAccess(.investments) else { return loc("profile.requires_royal") }
        guard !holdings.isEmpty else { return loc("invest.status.empty") }
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        let entries = holdings.map { (type: $0.typeRaw, currency: $0.currency, stats: $0.stats()) }
        let total = PortfolioEngine.portfolio(entries, targetCurrency: pref,
                                              convert: { cm.convert($0, from: $1, to: $2) }).marketValue
        let money = cm.formatted(total, currency: pref)
        return holdings.count == 1
            ? String(format: loc("invest.status.summary_one"), money)
            : String(format: loc("invest.status.summary"), holdings.count, money)
    }

    private var debtsStatus: String {
        guard pm.canAccess(.smartDebt) else { return loc("profile.requires_royal") }
        let active = debts.filter(\.isActive).count
        return active > 0 ? String(format: loc("wallet.debts_status"), active) : loc("oblig.entry_sub")
    }

    private var assetsStatus: String {
        guard pm.canAccess(.assets) else { return loc("profile.requires_royal") }
        guard !physicalAssets.isEmpty else { return loc("asset.status.empty") }
        let pref = CurrencyManager.shared.preferredCurrency
        let total = AssetSummary.of(physicalAssets, currency: pref).totalValue
        let money = CurrencyManager.shared.formatted(total.rounded(), currency: pref)
        return physicalAssets.count == 1
            ? String(format: loc("asset.status.summary_one"), money)
            : String(format: loc("asset.status.summary"), physicalAssets.count, money)
    }

    // MARK: Investments and assets, and More

    /// Under More until something is kept in them.
    private var folded: [PlanRoute] {
        PlanFold.underMore(holdings: holdings.count, assets: physicalAssets.count)
    }

    private var investmentsRow: some View {
        row(.investments, icon: "chart.line.uptrend.xyaxis", tint: AppTheme.accent,
            title: loc("premium.feature.investments"), status: investStatus,
            feature: .investments)
    }

    private var assetsRow: some View {
        row(.assets, icon: "house.fill", tint: AppTheme.teal,
            title: loc("premium.feature.assets"), status: assetsStatus,
            feature: .assets)
    }

    /// One row naming what waits here; a tap shows those rows beneath it.
    private var moreCard: some View {
        var names: [String] = []
        if folded.contains(.investments) { names.append(loc("premium.feature.investments")) }
        if folded.contains(.assets) { names.append(loc("premium.feature.assets")) }
        return VStack(spacing: 0) {
            Button {
                HapticManager.shared.tap()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { moreOpen.toggle() }
            } label: {
                PlanRowLabel(icon: "ellipsis", tint: AppTheme.textSecondary,
                             title: loc("plan.more"), status: names.joined(separator: " · "),
                             lockedPlan: nil, disclosure: moreOpen)
            }
            .buttonStyle(.plain)
            .accessibilityValue(loc(moreOpen ? "plan.more_shown" : "plan.more_hidden"))
            if moreOpen {
                if folded.contains(.investments) {
                    divider
                    investmentsRow
                }
                if folded.contains(.assets) {
                    divider
                    assetsRow
                }
            }
        }
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
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
    /// Set for a row that shows more beneath it: whether that is open.
    var disclosure: Bool? = nil

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
                PlanBadge(plan: plan)
            } else if let open = disclosure {
                Image(systemName: "chevron.down")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .rotationEffect(.degrees(open ? 180 : 0))
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

/// The plan a locked thing needs, in place of its chevron.
struct PlanBadge: View {
    let plan: PremiumPlan

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: plan.icon).imageScale(.small)
            Text(plan.label)
        }
        .font(.system(.caption2, weight: .bold))
        .foregroundStyle(plan.color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(plan.color.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

// MARK: - What waits under More

enum PlanFold {
    /// Investments and assets sit with the goals once something is kept in
    /// them. Until then they wait under More, so the tab opens on what is in
    /// use and a free account isn't met by two locked rows.
    static func underMore(holdings: Int, assets: Int) -> [PlanRoute] {
        var routes: [PlanRoute] = []
        if holdings == 0 { routes.append(.investments) }
        if assets == 0 { routes.append(.assets) }
        return routes
    }
}
