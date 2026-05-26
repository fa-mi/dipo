import SwiftUI
import SwiftData

// MARK: - Statistics Date Period

enum StatPeriod: String, CaseIterable {
    case thisMonth  = "This Month"
    case lastMonth  = "Last month"
    case last3      = "3 months"
    case last6      = "6 months"
    case thisYear   = "This year"
    case allTime    = "All time"
    case custom     = "Custom"

    /// Localized label for UI. rawValue stays English for internal logic.
    var title: String {
        switch self {
        case .thisMonth:  return loc("stats.period.this_month")
        case .lastMonth:  return loc("stats.period.last_month")
        case .last3:      return loc("stats.period.3months")
        case .last6:      return loc("stats.period.6months")
        case .thisYear:   return loc("stats.period.this_year")
        case .allTime:    return loc("stats.period.all_time")
        case .custom:     return loc("stats.period.custom")
        }
    }

    func dateRange() -> (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .thisMonth:
            let start = cal.safeDate(from: cal.dateComponents([.year, .month], from: now))
            return (start, now)
        case .lastMonth:
            let thisMonthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: now))
            let start = cal.safeDate(byAdding: .month, value: -1, to: thisMonthStart)
            return (start, thisMonthStart)
        case .last3:
            return (cal.safeDate(byAdding: .month, value: -3, to: now), now)
        case .last6:
            return (cal.safeDate(byAdding: .month, value: -6, to: now), now)
        case .thisYear:
            let start = cal.safeDate(from: cal.dateComponents([.year], from: now))
            return (start, now)
        case .allTime:
            return (Date.distantPast, now)
        case .custom:
            return (now, now) // overridden by custom state
        }
    }
}

// MARK: - Statistics View

struct StatisticsView: View {
    @State var statsVM: StatsViewModel
    let appVM: AppViewModel
    @Query private var cardBudgetConfigs: [CardBudgetConfig]
    @State private var selectedPeriod: StatPeriod = .thisMonth
    @State private var customStart: Date = Calendar.current.safeDate(byAdding: .month, value: -1, to: Date())
    @State private var customEnd: Date = Date()
    @State private var showCustomPicker = false
    @State private var selectedCardID: String? = nil // Will auto-select first card on appear
    @State private var showExportSheet = false

    private var effectiveRange: (start: Date, end: Date) {
        selectedPeriod == .custom
            ? (customStart, customEnd)
            : selectedPeriod.dateRange()
    }

    /// Lock overlay shown on top of the blurred Smart Insights card for
    /// free users. Crown + "upgrade" affordance — tapping anywhere on the
    /// card opens the Royal paywall.
    private var lockedInsightsOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(AppTheme.bg.opacity(0.35))
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(AppTheme.purple.opacity(0.15)).frame(width: 46, height: 46)
                    Image(systemName: "crown.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AppTheme.purple)
                }
                Text(loc("stats.insights"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold))
                    Text(loc("stats.insights_locked"))
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(AppTheme.purple)
            }
        }
    }

    // NOTE: Removed unused `allTx` property — it returned txs across all cards
    // without currency conversion. Use `filteredTx` (per-card) instead.

    private var periodSubtitle: String {
        let locale = LanguageManager.shared.currentLocale
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.dateFormat = DateFormatter.dateFormat(fromTemplate: "dMMMMyyyy", options: 0, locale: locale)
        if selectedPeriod == .custom {
            return "\(fmt.string(from: customStart)) – \(fmt.string(from: customEnd))"
        }
        let (start, end) = selectedPeriod.dateRange()
        if selectedPeriod == .allTime { return loc("stats.all_tx") }
        if selectedPeriod == .thisMonth || selectedPeriod == .lastMonth {
            let mfmt = DateFormatter()
            mfmt.locale = locale
            mfmt.dateFormat = DateFormatter.dateFormat(fromTemplate: "MMMMyyyy", options: 0, locale: locale)
            return mfmt.string(from: start)
        }
        return "\(fmt.string(from: start)) – \(fmt.string(from: end))"
    }

    // NOTE: Removed unconverted `income`, `expenses`, `netBalance` properties.
    // They aggregated tx.amount across ALL cards in raw currency (no conversion),
    // which produced absurd results when the selected card uses a different
    // currency. Use `filteredIncome`, `filteredExpenses` (per-card, converted)
    // instead. See line 144-150.
    
    // MARK: - Card Filter & Analytics
    
    private var availableCards: [BankCard] {
        // Show only cards that have at least one tx in current period
        appVM.cards.filter { card in
            card.transactions.contains(where: { tx in
                let (start, end) = effectiveRange
                return tx.date >= start && tx.date <= end
            })
        }
    }
    
    /// The currently-selected card (resolved from selectedCardID).
    private var selectedCard: BankCard? {
        guard let cardID = selectedCardID else { return nil }
        return appVM.cards.first(where: { $0.id.uuidString == cardID })
    }
    
    /// The currency used to display all stats. Always derived from the selected card —
    /// stats show in the card's native currency, with cross-currency tx converted via CurrencyManager.
    private var displayCurrency: String {
        selectedCard?.resolvedCurrency ?? CurrencyManager.shared.preferredCurrency
    }
    
    /// Transactions belonging to the selected card, within the selected period.
    /// Returns empty array if no card is selected.
    private var filteredTx: [TxRecord] {
        guard let card = selectedCard else { return [] }
        let (start, end) = effectiveRange
        return card.transactions.filter { $0.date >= start && $0.date <= end }
    }
    
    /// Convert a tx amount to the display currency (the selected card's currency).
    /// Handles legacy tx where currency may differ from card's currency.
    private func convertedAmount(_ tx: TxRecord) -> Double {
        let txCurrency = tx.currency.isEmpty ? displayCurrency : tx.currency
        return CurrencyManager.shared.convert(tx.amount, from: txCurrency, to: displayCurrency)
    }
    
    /// Income for the period — counts NORMAL income tx only. Refunds have
    /// positive amount too but represent reversal of past expenses (not new
    /// income); including them would inflate income and produce misleading
    /// "great savings rate!" cards. Transfers are inter-account movement,
    /// not income at all.
    private var filteredIncome: Double {
        filteredTx
            .filter { $0.amount > 0 && $0.txSubtype == .normal }
            .reduce(0) { $0 + convertedAmount($1) }
    }

    /// Expenses for the period. Skip transfers (movement between user's own
    /// accounts, not real spend) and SUBTRACT refunds (refund cancels an
    /// earlier expense in the same category). Same model the SmartBudget
    /// engine uses in `spent(in:)` so card balance, stats, and budget all
    /// agree on the numbers.
    private var filteredExpenses: Double {
        filteredTx
            .filter { $0.txSubtype != .transfer }
            .reduce(0.0) { sum, tx in
                let amt = abs(convertedAmount(tx))
                if tx.txSubtype == .refund { return sum - amt }
                return tx.amount < 0 ? sum + amt : sum
            }
    }
    
    private var weeklyAverage: Double {
        let (start, end) = effectiveRange
        let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 1
        let weeks = max(Double(days) / 7.0, 0.1)
        return filteredExpenses / weeks
    }
    
    private var topCategories: [(category: TxCategory, amount: Double, percentage: Double)] {
        // Same subtype-aware logic as filteredExpenses: skip transfers
        // entirely, subtract refunds from their category. Without this a
        // user who refunded Rp 800rb in Shopping still sees Shopping as the
        // top category — visually wrong since the money came back.
        var totals: [TxCategory: Double] = [:]
        for tx in filteredTx where tx.txSubtype != .transfer {
            let amt = abs(convertedAmount(tx))
            if tx.txSubtype == .refund {
                totals[tx.category, default: 0] -= amt
            } else if tx.amount < 0 {
                totals[tx.category, default: 0] += amt
            }
        }
        // Drop categories that net to ≤0 (refunds outweigh spend) — they're
        // not "top expenses" in any meaningful sense.
        totals = totals.filter { $0.value > 0 }
        let total = totals.values.reduce(0, +)
        guard total > 0 else { return [] }
        
        return totals
            .map { (category: $0.key, amount: $0.value, percentage: ($0.value / total) * 100) }
            .sorted { $0.amount > $1.amount }
            .prefix(5)
            .map { $0 }
    }

    /// Last 6 months of net balance for trend chart — only for selected card, in display currency
    private var netWorthTrend: [(label: String, value: Double)] {
        let cal = Calendar.current
        let now = Date()
        let locale = LanguageManager.shared.currentLocale
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.dateFormat = DateFormatter.dateFormat(fromTemplate: "MMM", options: 0, locale: locale)
        var points: [(label: String, value: Double)] = []
        guard let card = selectedCard else {
            // No card selected — return empty trend
            for offset in stride(from: -5, through: 0, by: 1) {
                let mStart = cal.safeDate(from: cal.dateComponents([.year, .month],
                    from: cal.safeDate(byAdding: .month, value: offset, to: now)))
                points.append((fmt.string(from: mStart), 0))
            }
            return points
        }
        for offset in stride(from: -5, through: 0, by: 1) {
            let mStart = cal.safeDate(from: cal.dateComponents([.year, .month],
                from: cal.safeDate(byAdding: .month, value: offset, to: now)))
            let mEnd = cal.safeDate(byAdding: .month, value: 1, to: mStart)
            let net = card.transactions
                .filter { $0.date >= mStart && $0.date < mEnd }
                .reduce(0.0) { $0 + convertedAmount($1) }
            points.append((fmt.string(from: mStart), net))
        }
        return points
    }

    private var realCategories: [SpendCategory] {
        // Subtype-aware bar chart data: transfer skipped, refund subtracted
        // from its bucket. Without this a heavily-refunded month shows
        // inflated bars in the chart that don't match the income/expense
        // totals above (which are subtype-aware).
        var totals: [TxCategory: Double] = [:]
        for tx in filteredTx where tx.txSubtype != .transfer {
            let amt = abs(convertedAmount(tx))
            let isExpenseTab = statsVM.selectedStatTab == .expenses
            if isExpenseTab {
                if tx.txSubtype == .refund {
                    totals[tx.category, default: 0] -= amt
                } else if tx.amount < 0 {
                    totals[tx.category, default: 0] += amt
                }
            } else {
                // Income tab: only normal positive tx counts (refund is
                // not income even though stored as positive amount).
                if tx.txSubtype == .normal && tx.amount > 0 {
                    totals[tx.category, default: 0] += amt
                }
            }
        }
        return TxCategory.allCases.compactMap { cat in
            guard let amt = totals[cat], amt > 0 else { return nil }
            return SpendCategory(name: cat.displayLabel, amount: amt, color: cat.color)
        }
    }

    private var realTotal: Double { realCategories.reduce(0) { $0 + $1.amount } }

    private var displayedTx: [TxRecord] {
        // List view still shows ALL transactions including refund/transfer
        // so the user can see them in chronological order. Only the
        // aggregated numbers (income/expenses/categories) filter by subtype.
        // This keeps the audit trail visible.
        statsVM.selectedStatTab == .expenses
            ? filteredTx.filter { $0.amount < 0 }
            : filteredTx.filter { $0.amount > 0 }
    }
    
    /// Compact card label for filter pills and exports.
    /// Digital wallet → provider name. Card → holder + last4.
    func cardLabel(_ card: BankCard) -> String {
        if card.isDigitalWallet, !card.walletProvider.isEmpty {
            return card.walletProvider
        }
        let holder = card.holderName.split(separator: " ").first.map(String.init) ?? card.holderName
        return "\(holder) ••\(card.last4)"
    }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Title
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc("stats.title")).font(.system(size: 24, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                            Text(periodSubtitle).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                        Button {
                            HapticManager.shared.tap()
                            showExportSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 18))
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 44, height: 44)
                                .background(AppTheme.accent.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)

                    // Period filter pills
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(StatPeriod.allCases, id: \.self) { period in
                                Button {
                                    HapticManager.shared.tap()
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                        selectedPeriod = period
                                        statsVM.selectedSliceIndex = nil
                                        statsVM.animateIn()
                                        if period == .custom { showCustomPicker = true }
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        if period == .custom {
                                            Image(systemName: "calendar.badge.plus")
                                                .font(.system(size: 11))
                                        }
                                        Text(period.title)
                                            .font(.system(size: 13, weight: selectedPeriod == period ? .semibold : .regular))
                                    }
                                    .foregroundStyle(selectedPeriod == period ? AppTheme.bg : AppTheme.textSecondary)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(selectedPeriod == period ? AppTheme.accent : AppTheme.cardDark, in: Capsule())
                                    .overlay(Capsule().stroke(selectedPeriod == period ? AppTheme.accent : Color.clear, lineWidth: 1))
                                }
                                .buttonStyle(ScaleButtonStyle())
                            }
                        }
                        .padding(.horizontal, 22)
                    }
                    .padding(.top, 12)
                    
                    // Card filter — user must select a specific card (no aggregation across currencies)
                    if !availableCards.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                // Individual cards only — no "All Cards" aggregation
                                ForEach(availableCards, id: \.id) { card in
                                    Button {
                                        HapticManager.shared.tap()
                                        withAnimation(.spring(response: 0.3)) {
                                            selectedCardID = card.id.uuidString
                                            statsVM.selectedSliceIndex = nil
                                            statsVM.animateIn()
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(Color(hex: card.gradientStart))
                                                .frame(width: 8, height: 8)
                                            Text(cardLabel(card))
                                                .font(.system(size: 13, weight: selectedCardID == card.id.uuidString ? .semibold : .regular))
                                                .lineLimit(1)
                                        }
                                        .foregroundStyle(selectedCardID == card.id.uuidString ? .white : AppTheme.textSecondary)
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .background(selectedCardID == card.id.uuidString ? Color(hex: card.gradientStart) : AppTheme.cardDark, in: Capsule())
                                    }
                                    .buttonStyle(ScaleButtonStyle())
                                }
                            }
                            .padding(.horizontal, 22)
                        }
                        .padding(.top, 10)
                    }

                    // Summary cards
                    HStack(spacing: 12) {
                        StatSummaryCard(title: loc("stats.income"), amount: filteredIncome, color: AppTheme.accent, currency: displayCurrency)
                        StatSummaryCard(title: loc("stats.expenses"), amount: filteredExpenses, color: AppTheme.red, currency: displayCurrency)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 16)

                    // Net balance card
                    NetBalanceSummary(net: filteredIncome - filteredExpenses, income: filteredIncome, expenses: filteredExpenses, currency: displayCurrency)
                        .padding(.horizontal, 22)
                        .padding(.top, 10)

                    // Net worth trend — 6 month sparkline
                    NetWorthTrendCard(trend: netWorthTrend)
                        .padding(.horizontal, 22)
                        .padding(.top, 12)
                    
                    // Smart Insights Card — Weekly avg + Top Category.
                    // Royal-only feature. Free users get a blurred teaser
                    // that opens the paywall on tap (same pattern as the
                    // Home Screen widget's locked-insights treatment).
                    if filteredExpenses > 0 {
                        let insightsCard = SmartInsightsCard(
                            weeklyAverage: weeklyAverage,
                            topCategories: topCategories,
                            totalExpenses: filteredExpenses,
                            currency: displayCurrency
                        )
                        if PremiumManager.shared.plan == .royal {
                            insightsCard
                                .padding(.horizontal, 22)
                                .padding(.top, 12)
                        } else {
                            insightsCard
                                // Blur the real data — the user sees the
                                // shape of the insight but can't read it.
                                .blur(radius: 7)
                                .allowsHitTesting(false)
                                .overlay { lockedInsightsOverlay }
                                .padding(.horizontal, 22)
                                .padding(.top, 12)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    HapticManager.shared.tap()
                                    // Reuses the paywall notification that
                                    // MainTabView already listens for.
                                    NotificationCenter.default.post(
                                        name: .requestOpenPaywall, object: nil)
                                }
                        }
                    }

                    StatSegmentPicker(vm: statsVM)
                        .padding(.horizontal, 22)
                        .padding(.top, 20)

                    if realCategories.isEmpty {
                        // Empty state with direct CTA to Add Transaction.
                        // Without the CTA the user reads "no expenses yet"
                        // and has to figure out the central "+" tab is what
                        // adds them. Linking from here makes the workflow
                        // obvious — and MainTabView's listener auto-switches
                        // to Home on save so the new tx is visible afterwards.
                        VStack(spacing: 14) {
                            Image(systemName: statsVM.selectedStatTab == .expenses ? "cart" : "arrow.down.circle")
                                .font(.system(size: 40))
                                .foregroundStyle(AppTheme.textSecondary)
                                .gentleFloat()
                            Text(String(format: loc("stats.title_empty"), statsVM.selectedStatTab.localizedLabel.lowercased()))
                                .font(.system(size: 16)).foregroundStyle(AppTheme.textSecondary)
                            Text(loc("stats.empty"))
                                .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary.opacity(0.7))

                            Button {
                                HapticManager.shared.tap()
                                NotificationCenter.default.post(name: .requestOpenAddTransaction, object: nil)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus.circle.fill").font(.system(size: 14))
                                    Text(loc("home.add_first_tx")).font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .background(AppTheme.accent.opacity(0.12), in: Capsule())
                                .overlay(Capsule().stroke(AppTheme.accent.opacity(0.3), lineWidth: 1))
                            }
                            .buttonStyle(ScaleButtonStyle())
                            .padding(.top, 4)
                        }
                        .padding(.top, 48)
                    } else {
                        // Bar chart — all categories with bars, percentages, amounts in one place
                        LiveBarChart(
                            categories: realCategories,
                            total: realTotal,
                            currency: displayCurrency,
                            statsVM: statsVM
                        )
                        .padding(.horizontal, 22)
                        .padding(.top, 20)
                    }

                    // Recent transactions for selected tab
                    if !displayedTx.isEmpty {
                        VStack(spacing: 0) {
                            HStack {
                                Text(String(format: loc("stats.recent"), statsVM.selectedStatTab.localizedLabel))
                                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                            }
                            .padding(.bottom, 14)
                            VStack(spacing: 12) {
                                ForEach(displayedTx.prefix(5)) { tx in
                                    TxRow(tx: tx)
                                }
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 24)
                    }

                    Spacer(minLength: 110)
                }
            }
        }
        .onAppear {
            statsVM.animateIn()
            // Auto-select first available card if none is selected.
            // Statistics is always per-card to avoid mixing currencies.
            if selectedCardID == nil, let first = availableCards.first {
                selectedCardID = first.id.uuidString
            }
            // Update categories with real data on appear
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                statsVM.categories = realCategories.isEmpty
                    ? [SpendCategory(name: "No data", amount: 1, color: AppTheme.textSecondary)]
                    : realCategories
            }
        }
        // StatisticsView lives in MainTabView's ZStack and is mounted ONCE at
        // app launch (tab switching only toggles opacity). That means
        // `.onAppear` fires before the user adds their first transaction —
        // at that point `availableCards` is empty so `selectedCardID` stays
        // nil. When transactions are added later from another tab, the body
        // re-evaluates (SwiftData @Observable) and `availableCards` recomputes
        // with the new card, BUT `selectedCardID` is never updated → the
        // summary shows Rp 0 / Rp 0 even though the data is there.
        // This onChange catches the "first card became available" transition
        // and auto-selects it. Keyed by `count` so we don't churn on every
        // tx insert into an already-selected card.
        .onChange(of: availableCards.count) { _, newCount in
            if selectedCardID == nil, newCount > 0,
               let first = availableCards.first {
                selectedCardID = first.id.uuidString
            }
        }
        .onChange(of: statsVM.selectedStatTab) { _, _ in
            statsVM.selectedSliceIndex = nil
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: selectedPeriod) { _, _ in
            statsVM.selectedSliceIndex = nil
            // If selected card has no tx in new period, auto-switch to a card that does
            if let cardID = selectedCardID,
               !availableCards.contains(where: { $0.id.uuidString == cardID }),
               let first = availableCards.first {
                selectedCardID = first.id.uuidString
            } else if selectedCardID == nil, let first = availableCards.first {
                selectedCardID = first.id.uuidString
            }
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: selectedCardID) { _, _ in
            statsVM.selectedSliceIndex = nil
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: customStart) { _, _ in
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: customEnd) { _, _ in
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .sheet(isPresented: $showCustomPicker) {
            CustomDateRangeSheet(startDate: $customStart, endDate: $customEnd)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showExportSheet) {
            StatsExportSheet(
                period: selectedPeriod,
                periodSubtitle: periodSubtitle,
                selectedCard: selectedCard,
                income: filteredIncome,
                expenses: filteredExpenses,
                weeklyAverage: weeklyAverage,
                topCategories: topCategories,
                transactions: filteredTx,
                currency: displayCurrency,
                configs: cardBudgetConfigs
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.bg)
            .preferredColorScheme(appColorScheme())
        }
    }
}

// MARK: - Summary Cards

struct StatSummaryCard: View {
    let title: String
    let amount: Double
    let color: Color
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
            }
            Text(CurrencyManager.shared.formatted(amount, currency: currency))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.2), lineWidth: 1))
    }
}

struct NetBalanceSummary: View {
    let net: Double
    let income: Double
    let expenses: Double
    let currency: String

    private var spentPct: Double {
        guard income > 0 else { return 0 }
        return min((expenses / income) * 100, 100)
    }
    
    private var savedPct: Double {
        guard income > 0 else { return 0 }
        return max(0, 100 - (expenses / income) * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(loc("stats.net_balance"))
                    .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text(net >= 0 ? "\(CurrencyManager.shared.formatted(net, currency: currency))"
                             : CurrencyManager.shared.formatted(net, currency: currency))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(net >= 0 ? AppTheme.accent : AppTheme.red)
                    .contentTransition(.numericText())
            }
            // Expense ratio bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(AppTheme.accent.opacity(0.2)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 4).fill(AppTheme.red)
                        .frame(width: g.size.width * CGFloat(spentPct / 100), height: 6)
                        .animation(.spring(response: 0.8, dampingFraction: 0.8), value: spentPct)
                }
            }
            .frame(height: 6)
            HStack {
                Text(String(format: loc("stats.percentage_spent"), String(format: "%.1f", spentPct)))
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text(net >= 0
                     ? String(format: loc("stats.saved"), String(format: "%.1f%%", savedPct))
                     : loc("stats.overspent"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(net >= 0 ? AppTheme.accent : AppTheme.red)
            }
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Live Bar Chart (horizontal bars per category)
// Replaced LiveDonutChart for better readability — bars don't get clipped,
// labels are always visible, and percentage comparisons are intuitive.

struct LiveBarChart: View {
    let categories: [SpendCategory]
    let total: Double
    let currency: String
    @Bindable var statsVM: StatsViewModel
    
    private var maxAmount: Double {
        categories.map(\.amount).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Hero — total at top
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("stats.total"))
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(CurrencyManager.shared.formatted(total, currency: currency))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Text("\(categories.count) " + loc("stats.categories"))
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(AppTheme.cardMid, in: Capsule())
            }
            .padding(.horizontal, 4)
            
            // Bars
            VStack(spacing: 10) {
                ForEach(Array(categories.enumerated()), id: \.element.id) { i, cat in
                    LiveBarRow(
                        index: i,
                        category: cat,
                        total: total,
                        maxAmount: maxAmount,
                        currency: currency,
                        progress: statsVM.chartProgress,
                        isSelected: statsVM.selectedSliceIndex == i,
                        onTap: { statsVM.selectSlice(statsVM.selectedSliceIndex == i ? nil : i) }
                    )
                }
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.cardMid.opacity(0.5), lineWidth: 1))
    }
}

struct LiveBarRow: View {
    let index: Int
    let category: SpendCategory
    let total: Double
    let maxAmount: Double
    let currency: String
    let progress: Double
    let isSelected: Bool
    let onTap: () -> Void
    
    private var percentage: Double {
        total > 0 ? (category.amount / total) * 100 : 0
    }
    
    private var barRatio: Double {
        maxAmount > 0 ? category.amount / maxAmount : 0
    }
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                // Top row: category label + amount
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(category.color.opacity(0.15)).frame(width: 26, height: 26)
                        Circle().fill(category.color).frame(width: 8, height: 8)
                    }
                    Text(category.name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(CurrencyManager.shared.formatted(category.amount, currency: currency))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(category.color)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                
                // Bar + percentage
                HStack(spacing: 8) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(category.color.opacity(0.12))
                                .frame(height: 8)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    LinearGradient(
                                        colors: [category.color, category.color.opacity(0.75)],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                )
                                .frame(width: g.size.width * CGFloat(barRatio) * CGFloat(progress), height: 8)
                                .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(Double(index) * 0.05), value: progress)
                        }
                    }
                    .frame(height: 8)
                    
                    Text(String(format: "%.0f%%", percentage))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(isSelected ? category.color.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? category.color.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(ScaleButtonStyle())
        .animation(.spring(response: 0.3), value: isSelected)
    }
}

// MARK: - Segment Picker

struct StatSegmentPicker: View {
    @Bindable var vm: StatsViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StatTab.allCases, id: \.self) { tab in
                Button {
                    vm.switchTab(tab)
                } label: {
                    Text(tab.localizedLabel)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(vm.selectedStatTab == tab ? AppTheme.bg : AppTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            if vm.selectedStatTab == tab {
                                Capsule()
                                    .fill(AppTheme.accent)
                                    .shadow(color: AppTheme.accent.opacity(0.4), radius: 10, y: 4)
                            }
                        }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: vm.selectedStatTab)
            }
        }
        .padding(4)
        .background(AppTheme.cardDark, in: Capsule())
    }
}

// MARK: - Net Worth Trend Card

struct NetWorthTrendCard: View {
    let trend: [(label: String, value: Double)]

    private var maxAbs: Double { trend.map { abs($0.value) }.max() ?? 1 }
    private var hasData: Bool { trend.contains { $0.value != 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("stats.net_worth"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(loc("stats.net_worth_sub"))
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                // Overall direction
                if let last = trend.last, let first = trend.first(where: { $0.value != 0 }) {
                    let up = last.value >= first.value
                    HStack(spacing: 4) {
                        Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                        Text(up ? loc("stats.positive") : loc("stats.negative"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(up ? AppTheme.accent : AppTheme.red)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background((up ? AppTheme.accent : AppTheme.red).opacity(0.12), in: Capsule())
                }
            }

            if hasData {
                let hasNegative = trend.contains { $0.value < 0 }
                let chartH: CGFloat = 70
                
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        let w = geo.size.width
                        let barW = (w - CGFloat(trend.count - 1) * 6) / CGFloat(trend.count)
                        // If all positive: bars grow up from bottom, baseline at bottom.
                        // If has negative: zero line at center, positive bars up, negative bars down.
                        let availableH: CGFloat = hasNegative ? chartH * 0.45 : chartH - 4
                        
                        ZStack(alignment: hasNegative ? .center : .bottom) {
                            // Baseline
                            Rectangle()
                                .fill(AppTheme.cardMid.opacity(0.6))
                                .frame(height: 1)
                                .frame(maxWidth: .infinity, alignment: .center)
                            
                            HStack(alignment: hasNegative ? .center : .bottom, spacing: 6) {
                                ForEach(Array(trend.enumerated()), id: \.offset) { i, point in
                                    let rawH = maxAbs > 0 ? CGFloat(abs(point.value) / maxAbs) * availableH : 0
                                    let barH = max(rawH, 3)
                                    let isPositive = point.value >= 0
                                    let isLast = i == trend.count - 1
                                    let barColor = isPositive
                                        ? (isLast ? AppTheme.accent : AppTheme.accent.opacity(0.5))
                                        : (isLast ? AppTheme.red : AppTheme.red.opacity(0.5))
                                    
                                    if hasNegative {
                                        // Bars grow from center outward
                                        VStack(spacing: 0) {
                                            if isPositive {
                                                Spacer(minLength: 0)
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(barColor)
                                                    .frame(width: barW, height: barH)
                                                Color.clear.frame(height: chartH * 0.5)
                                            } else {
                                                Color.clear.frame(height: chartH * 0.5)
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(barColor)
                                                    .frame(width: barW, height: barH)
                                                Spacer(minLength: 0)
                                            }
                                        }
                                        .frame(height: chartH)
                                    } else {
                                        // All positive — bars grow up from bottom
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(barColor)
                                            .frame(width: barW, height: barH)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: chartH)
                    
                    // Labels in separate row
                    HStack(spacing: 6) {
                        ForEach(Array(trend.enumerated()), id: \.offset) { i, point in
                            let isLast = i == trend.count - 1
                            Text(point.label)
                                .font(.system(size: 10, weight: isLast ? .semibold : .regular))
                                .foregroundStyle(isLast ? AppTheme.textPrimary : AppTheme.textSecondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            } else {
                Text(loc("stats.trend_empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.accent.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Smart Insights Card (Weekly Avg + Top Categories)

struct SmartInsightsCard: View {
    let weeklyAverage: Double
    let topCategories: [(category: TxCategory, amount: Double, percentage: Double)]
    let totalExpenses: Double
    let currency: String
    
    @State private var appeared = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(AppTheme.purple.opacity(0.15)).frame(width: 32, height: 32)
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.purple)
                }
                Text(loc("stats.insights"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
            }
            
            // Weekly Average — hero metric
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.purple)
                    Text(loc("stats.weekly_avg"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Text(CurrencyManager.shared.formatted(weeklyAverage, currency: currency))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())
                Text(loc("stats.weekly_avg_sub"))
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                LinearGradient(
                    colors: [AppTheme.purple.opacity(0.18), AppTheme.purple.opacity(0.05)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.purple.opacity(0.25), lineWidth: 1))
            
            // Top Categories
            if !topCategories.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.orange)
                        Text(loc("stats.top_categories"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    
                    VStack(spacing: 8) {
                        ForEach(Array(topCategories.prefix(3).enumerated()), id: \.offset) { idx, item in
                            TopCategoryRow(
                                rank: idx + 1,
                                category: item.category,
                                amount: item.amount,
                                percentage: item.percentage,
                                currency: currency,
                                appeared: appeared
                            )
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.purple.opacity(0.15), lineWidth: 1))
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                appeared = true
            }
        }
    }
}

struct TopCategoryRow: View {
    let rank: Int
    let category: TxCategory
    let amount: Double
    let percentage: Double
    let currency: String
    let appeared: Bool
    
    private var rankColor: Color {
        switch rank {
        case 1: return AppTheme.orange
        case 2: return AppTheme.textSecondary
        case 3: return AppTheme.purple
        default: return AppTheme.textSecondary
        }
    }
    
    var body: some View {
        HStack(spacing: 10) {
            // Rank badge
            ZStack {
                Circle().fill(rankColor.opacity(0.15)).frame(width: 26, height: 26)
                Text("\(rank)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(rankColor)
            }
            
            // Category icon
            ZStack {
                Circle().fill(category.color.opacity(0.15)).frame(width: 32, height: 32)
                Image(systemName: category.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(category.color)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text(category.displayLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                
                // Mini progress bar
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(category.color.opacity(0.15))
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(category.color)
                            .frame(width: appeared ? g.size.width * CGFloat(percentage / 100) : 0, height: 4)
                            .animation(.spring(response: 0.8, dampingFraction: 0.8).delay(Double(rank) * 0.08), value: appeared)
                    }
                }
                .frame(height: 4)
            }
            
            VStack(alignment: .trailing, spacing: 2) {
                Text(CurrencyManager.shared.formatted(amount, currency: currency))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(String(format: "%.0f%%", percentage))
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
}

// MARK: - Statistics Export Sheet

struct StatsExportSheet: View {
    let period: StatPeriod
    let periodSubtitle: String
    let selectedCard: BankCard?
    let income: Double
    let expenses: Double
    let weeklyAverage: Double
    let topCategories: [(category: TxCategory, amount: Double, percentage: Double)]
    let transactions: [TxRecord]
    let currency: String
    /// Per-card budget configs forwarded from the parent so this sheet can
    /// hand them to StatsReportCard for ratio resolution.
    let configs: [CardBudgetConfig]
    
    @State private var shareItem: ShareItem?
    @State private var isGenerating = false
    
    private func cardDisplayLabel(_ card: BankCard) -> String {
        if card.isDigitalWallet, !card.walletProvider.isEmpty {
            return card.walletProvider
        }
        let holder = card.holderName.split(separator: " ").first.map(String.init) ?? card.holderName
        return "\(holder) ••\(card.last4)"
    }
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                // Title only — no icon
                VStack(spacing: 4) {
                    Text(loc("stats.export_preview"))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(periodSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.top, 12)
                
                // Visual preview — actual report card scaled down
                StatsReportCard(
                    periodSubtitle: periodSubtitle,
                    cardLabel: selectedCard.map(cardDisplayLabel) ?? "—",
                    cardColor: selectedCard.map { Color(hex: $0.gradientStart) } ?? AppTheme.purple,
                    income: income,
                    expenses: expenses,
                    weeklyAverage: weeklyAverage,
                    topCategories: topCategories,
                    transactionCount: transactions.count,
                    currency: currency,
                    cardID: selectedCard?.id.uuidString,
                    configs: configs,
                    filteredTransactions: transactions
                )
                .padding(.horizontal, 22)
                
                // Single export button — Save as Image
                Button {
                    HapticManager.shared.tap()
                    exportImage()
                } label: {
                    HStack(spacing: 10) {
                        if isGenerating {
                            ProgressView().tint(.white).scaleEffect(0.85)
                        } else {
                            Image(systemName: "photo.fill").font(.system(size: 16))
                        }
                        Text(loc("stats.export_image"))
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [AppTheme.accent, AppTheme.accent.opacity(0.85)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .shadow(color: AppTheme.accent.opacity(0.4), radius: 8, y: 3)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(isGenerating)
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(items: [item.url])
        }
    }
    
    // MARK: - Export Functions
    
    /// Render the report card to a PNG image and share via UIActivityViewController.
    /// Uses ImageRenderer (iOS 16+) at 3x scale for retina-quality output.
    /// Respects user's appearance preference (light/dark/system) so the exported
    /// image matches what the user sees in the app.
    @MainActor
    private func exportImage() {
        isGenerating = true
        let cardName = selectedCard.map(cardDisplayLabel) ?? "—"
        let cardColor = selectedCard.map { Color(hex: $0.gradientStart) } ?? AppTheme.purple
        
        // Resolve user's color scheme preference (light/dark/system → system fallback)
        let resolvedScheme: ColorScheme = {
            if let pref = appColorScheme() { return pref }
            return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        }()
        
        let report = StatsReportCard(
            periodSubtitle: periodSubtitle,
            cardLabel: cardName,
            cardColor: cardColor,
            income: income,
            expenses: expenses,
            weeklyAverage: weeklyAverage,
            topCategories: topCategories,
            transactionCount: transactions.count,
            currency: currency,
            cardID: selectedCard?.id.uuidString,
            configs: configs,
            filteredTransactions: transactions
        )
        .frame(width: 380)
        .padding(20)
        .background(AppTheme.bg)
        .environment(\.colorScheme, resolvedScheme)
        
        let renderer = ImageRenderer(content: report)
        renderer.scale = 3.0
        
        guard let uiImg = renderer.uiImage,
              let data = uiImg.pngData() else {
            isGenerating = false
            return
        }
        
        let filename = "DiPo_Stats_\(cardName.replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970)).png"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        
        do {
            try data.write(to: tempURL)
            shareItem = ShareItem(url: tempURL)
        } catch {
            print("Image export error: \(error)")
        }
        isGenerating = false
    }
    
}

// MARK: - Stats Report Card (Used for both preview and PNG export)

/// A polished, screenshot-worthy report card. This view is rendered to PNG
/// via ImageRenderer for the "Export as Image" feature, and also used as the
/// preview in StatsExportSheet so users see exactly what they'll get.
struct StatsReportCard: View {
    let periodSubtitle: String
    let cardLabel: String
    let cardColor: Color
    let income: Double
    let expenses: Double
    let weeklyAverage: Double
    let topCategories: [(category: TxCategory, amount: Double, percentage: Double)]
    let transactionCount: Int
    let currency: String
    /// Card whose ratios should appear in the budget breakdown. nil = use
    /// global defaults.
    let cardID: String?
    /// Per-card configs queried by the parent view; this card's ratios are
    /// resolved from this list (with global fallback).
    let configs: [CardBudgetConfig]
    /// Transactions for the period — needed by `recommendationSection` to call
    /// the same `topInsight()` engine Home uses, so the export shows the same
    /// recommendation the user sees on the home screen banner.
    let filteredTransactions: [TxRecord]
    
    @Environment(\.colorScheme) private var colorScheme
    
    private var netBalance: Double { income - expenses }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Brand header — DiPo Mascot logo + label
            HStack {
                HStack(spacing: 10) {
                    Image("DiPoMascot")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 38, height: 38)
                        .blendMode(colorScheme == .dark ? .screen : .multiply)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Digital Pocket ID")
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(loc("stats.title"))
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(periodSubtitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    HStack(spacing: 4) {
                        Circle().fill(cardColor).frame(width: 6, height: 6)
                        Text(cardLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            
            // Hero — Net Balance
            VStack(alignment: .leading, spacing: 4) {
                Text(loc("stats.net_balance"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(netBalance >= 0
                     ? "\(CurrencyManager.shared.formatted(netBalance, currency: currency))"
                     : CurrencyManager.shared.formatted(netBalance, currency: currency))
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(netBalance >= 0 ? AppTheme.accent : AppTheme.red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                LinearGradient(
                    colors: [
                        (netBalance >= 0 ? AppTheme.accent : AppTheme.red).opacity(0.18),
                        (netBalance >= 0 ? AppTheme.accent : AppTheme.red).opacity(0.04)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke((netBalance >= 0 ? AppTheme.accent : AppTheme.red).opacity(0.25), lineWidth: 1))
            
            // Income / Expenses split
            HStack(spacing: 8) {
                ReportMetricBox(
                    label: loc("stats.income"),
                    value: CurrencyManager.shared.formatted(income, currency: currency),
                    color: AppTheme.accent,
                    icon: "arrow.down.circle.fill"
                )
                ReportMetricBox(
                    label: loc("stats.expenses"),
                    value: CurrencyManager.shared.formatted(expenses, currency: currency),
                    color: AppTheme.red,
                    icon: "arrow.up.circle.fill"
                )
            }
            
            // Weekly Avg + Tx Count
            HStack(spacing: 8) {
                ReportMetricBox(
                    label: loc("stats.weekly_short"),
                    value: CurrencyManager.shared.formatted(weeklyAverage, currency: currency),
                    color: AppTheme.purple,
                    icon: "calendar.badge.clock"
                )
                ReportMetricBox(
                    label: loc("stats.transactions"),
                    value: "\(transactionCount)",
                    color: AppTheme.orange,
                    icon: "list.bullet.rectangle.fill"
                )
            }
            
            // Top Categories
            if !topCategories.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.orange)
                        Text(loc("stats.top_categories"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    VStack(spacing: 7) {
                        ForEach(Array(topCategories.prefix(5).enumerated()), id: \.offset) { idx, item in
                            ReportCategoryRow(
                                rank: idx + 1,
                                category: item.category,
                                amount: item.amount,
                                percentage: item.percentage,
                                currency: currency
                            )
                        }
                    }
                }
                .padding(12)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
            }
            
            // Budget Allocation — premium-gated. Use `hasActiveBudget` (not the
            // raw `isEnabled` toggle) so a user who lost their Royal access
            // (logout, expired sub, sign-in as different non-Royal account)
            // doesn't see this section in the export. The user's old toggle
            // setting is preserved in UserDefaults but stays hidden until they
            // resubscribe — same UX pattern as other Royal-only widgets.
            if SmartBudgetManager.shared.hasActiveBudget {
                budgetAllocationSection
            }
            
            // Smart Recommendation
            recommendationSection
            
            // Footer
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 8))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                Text(String(format: loc("stats.generated_by"), Date().displayDateTimeShort))
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(AppTheme.bg)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.cardMid, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
    
    /// Budget allocation breakdown — shown only when Smart Budget is enabled.
    /// Ratios are resolved per-card via `SmartBudgetManager.ratios(forCardID:)`,
    /// so the export reflects the same allocation the user sees on Home for
    /// this specific card.
    private var budgetAllocationSection: some View {
        let r = SmartBudgetManager.shared.ratios(forCardID: cardID, configs: configs)
        let dailyLimit = income * r.daily
        let lifestyleLimit = income * r.lifestyle
        let investLimit = income * r.investDebt
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.purple)
                Text(loc("budget.allocation_title"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            VStack(spacing: 6) {
                BudgetAllocationRow(
                    label: loc("budget.group.daily"),
                    ratio: r.daily,
                    limit: dailyLimit,
                    color: AppTheme.blue,
                    currency: currency
                )
                BudgetAllocationRow(
                    label: loc("budget.group.lifestyle"),
                    ratio: r.lifestyle,
                    limit: lifestyleLimit,
                    color: AppTheme.purple,
                    currency: currency
                )
                BudgetAllocationRow(
                    label: loc("budget.group.invest_debt"),
                    ratio: r.investDebt,
                    limit: investLimit,
                    color: AppTheme.accent,
                    currency: currency
                )
            }
        }
        .padding(12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
    }
    
    /// Smart recommendation — single source of truth shared with the Home
    /// screen's "Wawasan Cerdas" banner. Both call into
    /// `SmartBudgetManager.topInsight()` so the messaging is consistent: if
    /// Home says "Lifestyle melebihi anggaran", Stats says the same. We only
    /// fall back to a savings-rate summary when there's nothing actionable
    /// to report (no overspend, no anomaly).
    private var recommendationSection: some View {
        // Try the same engine Home uses, with the same per-card ratios.
        let homeInsight = SmartBudgetManager.shared.topInsight(
            allTransactions: filteredTransactions,
            income: income,
            cardID: cardID,
            configs: configs,
            targetCurrency: currency
        )
        
        let (icon, tint, title, body): (String, Color, String, String) = {
            // 1. Reuse Home's insight if it has something to say
            if let insight = homeInsight {
                return (insight.icon, insight.color, insight.title, insight.body)
            }
            // 2. No income → prompt to add salary
            if income <= 0 {
                return ("info.circle.fill", AppTheme.textSecondary,
                        loc("rec.no_income_title"), loc("rec.no_income_body"))
            }
            // 3. Fallback: savings-rate summary
            let savingsRate = max(0, (income - expenses) / income * 100)
            let spendRatio = expenses / income
            if spendRatio > 0.9 {
                return ("exclamationmark.triangle.fill", AppTheme.red,
                        loc("rec.overspend_title"),
                        String(format: loc("rec.overspend_body"), Int(spendRatio * 100)))
            }
            if savingsRate >= 20 {
                return ("checkmark.seal.fill", AppTheme.accent,
                        loc("rec.great_savings_title"),
                        String(format: loc("rec.great_savings_body"), Int(savingsRate)))
            }
            return ("lightbulb.fill", AppTheme.orange,
                    loc("rec.balance_title"),
                    String(format: loc("rec.balance_body"), Int(savingsRate)))
        }()
        
        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                Text(body)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.25), lineWidth: 1))
    }
}

/// Compact budget allocation row showing label, percentage, and budget cap.
/// Used in StatsReportCard's budget section for image export.
struct BudgetAllocationRow: View {
    let label: String
    let ratio: Double
    let limit: Double
    let color: Color
    let currency: String
    
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(String(format: "%.0f%%", ratio * 100))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(minWidth: 32, alignment: .trailing)
            Text(CurrencyManager.shared.formatted(limit, currency: currency))
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
        }
    }
}

struct ReportMetricBox: View {
    let label: String
    let value: String
    let color: Color
    let icon: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.18), lineWidth: 1))
    }
}

struct ReportCategoryRow: View {
    let rank: Int
    let category: TxCategory
    let amount: Double
    let percentage: Double
    let currency: String
    
    private var rankColor: Color {
        switch rank {
        case 1: return AppTheme.orange
        case 2: return AppTheme.textSecondary
        case 3: return AppTheme.purple
        default: return AppTheme.textSecondary.opacity(0.7)
        }
    }
    
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(rankColor.opacity(0.15)).frame(width: 20, height: 20)
                Text("\(rank)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(rankColor)
            }
            ZStack {
                Circle().fill(category.color.opacity(0.15)).frame(width: 24, height: 24)
                Image(systemName: category.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(category.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(category.displayLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(category.color.opacity(0.15))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(category.color)
                            .frame(width: g.size.width * CGFloat(percentage / 100), height: 3)
                    }
                }
                .frame(height: 3)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(CurrencyManager.shared.formatted(amount, currency: currency))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(String(format: "%.0f%%", percentage))
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
