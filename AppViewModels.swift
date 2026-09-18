import SwiftUI

// MARK: - App ViewModel

@Observable
final class AppViewModel {
    var cards: [BankCard] = []
    var selectedCardIndex: Int = 0
    var activeTab: AppTab = .home
    var isLoaded: Bool = false
    var showCardManager: Bool = false

    /// Each tab's push stack. Owned here so anything — a Home banner, a
    /// notification, an insight — can land the user on a feature in the tab it
    /// lives in, instead of stacking that feature as a sheet over Home.
    var homePath: [HomeRoute] = []
    var walletPath: [WalletRoute] = []
    var planPath: [PlanRoute] = []
    var statsPath: [StatsRoute] = []

    /// The active tab has a feature pushed on it. The tab bar steps aside then,
    /// like `hidesBottomBarWhenPushed`, so it never covers a feature's content.
    var isInsideFeature: Bool {
        switch activeTab {
        case .home:  return !homePath.isEmpty
        case .cards: return !walletPath.isEmpty
        case .plan:  return !planPath.isEmpty
        case .stats: return !statsPath.isEmpty
        default:     return false
        }
    }

    func open(_ route: PlanRoute) {
        activeTab = .plan
        planPath = [route]
    }

    func open(_ route: WalletRoute) {
        activeTab = .cards
        walletPath = [route]
    }

    // ✅ Safe: guard against stale selectedCardIndex after card deletion.
    // cards.isEmpty check alone is insufficient — index can still be out of range
    // if selectedCardIndex was 2 and cards shrunk to 1 between two render passes.
    var selectedCard: BankCard? {
        guard !cards.isEmpty, cards.indices.contains(selectedCardIndex) else { return nil }
        return cards[selectedCardIndex]
    }

    var recentTransactions: [TxRecord] {
        cards.flatMap { $0.transactions }.sorted { $0.date > $1.date }
    }

    // Uses the canonical cross-currency helper from BankCardHelpers.swift
    // instead of duplicating the conversion logic inline.
    var totalBalance: Double {
        BankCard.totalBalanceAcrossCards(cards, preferredCurrency: CurrencyManager.shared.preferredCurrency)
    }

    func selectTab(_ tab: AppTab) {
        HapticManager.shared.select()
        // A tab tap always lands on that tab's ROOT. Without this, a deep link
        // that pushed a feature onto a tab while you were on another one would
        // leave that path in place — and since the tab bar hides inside a
        // feature, tapping the tab would drop you into a screen you never
        // opened, with no tab bar to leave by.
        switch tab {
        case .home:  homePath.removeAll()
        case .cards: walletPath.removeAll()
        case .plan:  planPath.removeAll()
        case .stats: statsPath.removeAll()
        default:     break
        }
        activeTab = tab
    }

    func openProfile() {
        activeTab = .home
        homePath = [.profile]
    }

    func selectCard(_ index: Int) {
        guard index != selectedCardIndex else { return }
        HapticManager.shared.tap()
        selectedCardIndex = index
    }
}

// MARK: - Stats ViewModel

@Observable
final class StatsViewModel {
    var selectedStatTab: StatTab = .expenses
    var chartProgress: Double = 0
    var selectedSliceIndex: Int? = nil
    var filterPeriod: String = "This month"

    // NOTE: `categories` is populated by StatisticsView from real transactions
    // via the `realCategories` computed property. It is intentionally empty here —
    // do NOT add hardcoded placeholder data.
    var categories: [SpendCategory] = []

    var total: Double { categories.reduce(0) { $0 + $1.amount } }

    func animateIn() {
        chartProgress = 0
        withAnimation(.spring(response: 1.1, dampingFraction: 0.75).delay(0.2)) {
            chartProgress = 1
        }
    }

    func selectSlice(_ index: Int?) {
        HapticManager.shared.tap()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            selectedSliceIndex = (selectedSliceIndex == index) ? nil : index
        }
    }

    func switchTab(_ tab: StatTab) {
        HapticManager.shared.select()
        selectedStatTab = tab
        animateIn()
    }
}

// MARK: - Supporting Types

struct SpendCategory: Identifiable {
    let id = UUID()
    let name: String
    let amount: Double
    let color: Color
}

enum StatTab: String, CaseIterable {
    case income   = "Income"
    case expenses = "Expenses"

    /// The colour this side of the ledger already has everywhere else in the
    /// app — green in, red out. The selector painted BOTH tabs accent green, so
    /// the control that switches between money coming in and money going out
    /// looked identical in either state, directly under a summary card that
    /// colours the same two figures green and red.
    var tint: Color {
        switch self {
        case .income:   return AppTheme.accent
        case .expenses: return AppTheme.red
        }
    }

    /// Localized label for UI. rawValue stays English for internal logic.
    var localizedLabel: String {
        switch self {
        case .income:   return loc("stats.income")
        case .expenses: return loc("stats.expenses")
        }
    }
}

// MARK: - App Tab

/// Profile left the tab bar: it is account settings, opened from the avatar on
/// Home. Its slot went to Plan, which holds the money features people check
/// every week — budget, salary, bills, savings — that used to be sheets
/// stacked on top of Profile.
enum AppTab: Int, CaseIterable {
    case home = 0, stats, add, cards, plan

    var icon: String {
        switch self {
        case .home:  return "house.fill"
        case .stats: return "chart.bar.fill"
        case .add:   return "plus"
        case .cards: return "wallet.bifold.fill"
        case .plan:  return "list.clipboard.fill"
        }
    }

    var label: String {
        switch self {
        case .home:  return loc("tab.home")
        case .stats: return loc("tab.stats")
        case .add:   return ""
        case .cards: return loc("tab.cards")
        case .plan:  return loc("tab.plan")
        }
    }
}

enum HomeRoute: Hashable { case profile }
enum WalletRoute: Hashable { case obligations }
enum PlanRoute: Hashable {
    case budget, salary, bills, goals, investments
    // A specific holding's detail. Carried as a PlanRoute (not a bare view push)
    // so it appends to the tab's typed `[PlanRoute]` path — a value-less
    // NavigationLink here crashes with AnyNavigationPath.comparisonTypeMismatch.
    // InvestmentHolding is a PersistentModel, so it's Hashable for the path.
    case holding(InvestmentHolding)
}
enum StatsRoute: Hashable {
    case analysis
    /// The Weekly tile's own page — this week, day by day.
    case weekly
    /// The Trends tile's own page — cycle by cycle.
    case trends
    /// One cycle from the Trends page, opened up. Carries the window rather than
    /// the trend point so the route stays Hashable for the typed path.
    case cycle(start: Date, end: Date, label: String)
}
