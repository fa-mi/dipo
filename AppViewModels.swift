import SwiftUI

// MARK: - App ViewModel

@Observable
final class AppViewModel {
    var cards: [BankCard] = []
    var selectedCardIndex: Int = 0
    var activeTab: AppTab = .home
    var isLoaded: Bool = false
    var showCardManager: Bool = false

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
        activeTab = tab
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

    /// Localized label for UI. rawValue stays English for internal logic.
    var localizedLabel: String {
        switch self {
        case .income:   return loc("stats.income")
        case .expenses: return loc("stats.expenses")
        }
    }
}

// MARK: - App Tab

enum AppTab: Int, CaseIterable {
    case home = 0, stats, add, cards, profile

    var icon: String {
        switch self {
        case .home:    return "house.fill"
        case .stats:   return "chart.bar.fill"
        case .add:     return "plus"
        case .cards:   return "creditcard.fill"
        case .profile: return "person"
        }
    }

    var label: String {
        switch self {
        case .home:    return loc("tab.home")
        case .stats:   return loc("tab.stats")
        case .add:     return ""
        case .cards:   return loc("tab.cards")
        case .profile: return loc("tab.profile")
        }
    }
}
