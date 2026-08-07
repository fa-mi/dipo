import SwiftUI
import SwiftData


// MARK: - Home View

struct HomeView: View {
    @Bindable var vm: AppViewModel
    @Environment(\.modelContext) private var context
    @Query(sort: \SalarySchedule.createdAt) private var salarySchedules: [SalarySchedule]
    @Query(sort: \BankCard.sortOrder) private var queriedCards: [BankCard]
    @Query(filter: #Predicate<SavingsGoal> { $0.isPinned && !$0.isCompleted }) private var pinnedGoals: [SavingsGoal]
    /// All active goals — used by the SmartBudget engine for goal-linked
    /// insight ("cut X% lifestyle → goal lands N weeks earlier").
    @Query(filter: #Predicate<SavingsGoal> { !$0.isCompleted }) private var activeGoals: [SavingsGoal]
    /// Per-card budget configurations. Each row stores Smart Budget ratios for
    /// one card; cards without a config row use SmartBudgetManager's global
    /// defaults. Looked up by `cardID == BankCard.id.uuidString`.
    @Query private var cardBudgetConfigs: [CardBudgetConfig]
    /// For the Net Worth line: liabilities = credit-card owed + active debts.
    @Query(filter: #Predicate<DebtRecord> { $0.isActive }) private var activeDebts: [DebtRecord]
    /// Declared Monthly Expenses — surfaced on Home when a charge is imminent,
    /// so the balance drop never comes as a surprise.
    @Query private var recurringExpenses: [RecurringExpense]

    /// The next DECLARED recurring charge due within 3 days (soonest first).
    private var upcomingDeclaredRecurring: RecurringExpense? {
        recurringExpenses
            .filter { $0.isActive }
            .map { ($0, RecurringDateEngine.daysUntil(dayOfMonth: $0.dayOfMonth)) }
            .filter { $0.1 <= 3 }
            .min { $0.1 < $1.1 }?.0
    }
    // Observed so HomeView re-renders whenever budgetCardID changes
    @State private var budgetManager = SmartBudgetManager.shared

    @State private var showSearch           = false
    @State private var showNotifications    = false
    @State private var showAddCard          = false
    @State private var showAddSalary        = false
    @State private var categoryFilter: TxCategory? = nil
    @State private var showSmartBudget = false
    @State private var showSalarySheet   = false
    @State private var showWishlistSheet  = false
    @State private var showGoalDetail: SavingsGoal? = nil
    /// Open Debt sheet when an insight CTA routes there. Separate from the
    /// Profile entry so we don't have to thread bindings across views.
    @State private var showDebtFromInsight = false
    @State private var headerAppeared    = false
    @State private var contentAppeared   = false
    // Memoized Smart-Budget analyses. Each engine iterates ALL transactions
    // (× categories), and they were previously recomputed on EVERY body render
    // — the main source of scroll/carousel lag as the transaction count grows.
    // Now they run only when inputs actually change (see recomputeHomeInsights).
    @State private var cachedInsights:  [SmartInsight] = []
    @State private var cachedAnomalies: [SmartInsight] = []
    @State private var cachedRecurring: [SmartBudgetManager.RecurringPattern] = []

    private var nearestSalary: SalarySchedule? {
        salarySchedules.filter { $0.isActive }
            .sorted { SalaryDateEngine.daysUntilPay(dayOfMonth: $0.dayOfMonth)
                    < SalaryDateEngine.daysUntilPay(dayOfMonth: $1.dayOfMonth) }
            .first
    }

    private var totalBalance: Double {
        // Cash only — credit cards are liabilities, not money you hold. They
        // must never inflate the "total balance" figure.
        //
        // Every amount is converted to the preferred currency first. Summing
        // raw values added a USD card's balance to an IDR one as if they were
        // the same unit — and since `totalLiabilities` DID convert, net worth
        // silently mixed converted debts with unconverted cash.
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        return vm.cards.filter { !$0.isCreditCard }
            .reduce(0.0) { sum, card in
                let cur = card.resolvedCurrency
                let txSum = card.transactions.reduce(0.0) { txAcc, tx in
                    txAcc + cm.convert(tx.amount, from: tx.currency.isEmpty ? cur : tx.currency, to: pref)
                }
                return sum + cm.convert(card.balance, from: cur, to: pref) + txSum
            }
    }

    /// Total liabilities: credit-card owed + active debt balances, in the
    /// preferred currency.
    private var totalLiabilities: Double {
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        let cc = vm.cards.filter { $0.isCreditCard }
            .reduce(0.0) { $0 + cm.convert($1.owedBalance(), from: $1.resolvedCurrency, to: pref) }
        let debt = activeDebts.reduce(0.0) { $0 + cm.convert($1.currentBalance, from: $1.currency, to: pref) }
        return cc + debt
    }
    private var hasLiabilities: Bool { totalLiabilities > 0.5 }

    /// Money already set aside in savings goals. This is the user's money —
    /// leaving it out made someone with Rp 30M saved and Rp 12M of installments
    /// look bankrupt. Only counts what is provably NOT still sitting in a
    /// tracked account: deposits recorded as transactions (cash already went
    /// down) plus balances the user confirmed are held outside DiPo. Anything
    /// unconfirmed is left out until they answer the prompt on the goal, so
    /// the same rupiah is never counted twice.
    private var goalSavings: Double {
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        let tx = vm.cards.flatMap(\.transactions)
        return activeGoals.reduce(0.0) {
            $0 + cm.convert($1.netWorthContribution(from: tx), from: $1.currency, to: pref)
        }
    }

    /// Net worth = cash + savings goals − liabilities.
    private var netWorth: Double { totalBalance + goalSavings - totalLiabilities }

    // Transactions for the currently selected card only
    private var selectedCard: BankCard? {
        guard !queriedCards.isEmpty else { return nil }
        let idx = min(vm.selectedCardIndex, queriedCards.count - 1)
        return queriedCards[idx]
    }

    private var selectedCardTransactions: [TxRecord] {
        (selectedCard?.transactions ?? []).sorted { $0.date > $1.date }
    }

    // Negative balance is per selected card
    private var selectedCardBalance: Double {
        guard let card = selectedCard else { return 0 }
        // `computedBalance()` is the canonical figure the card face shows and it
        // converts each transaction into the card's currency. Re-summing raw
        // amounts here made the negative-balance warning disagree with the
        // balance printed right above it whenever a card held a foreign-currency
        // transaction.
        return card.computedBalance()
    }

    private var selectedCardCurrency: String {
        selectedCard?.transactions.first?.currency ?? CurrencyManager.shared.preferredCurrency
    }

    private var hasCards: Bool { !vm.cards.isEmpty }
    private var hasSalary: Bool { !salarySchedules.isEmpty }

    /// The card "Wawasan Cerdas" insights are computed for. We deliberately
    /// follow the carousel's `selectedCard` rather than a fixed setting — this
    /// makes the home screen feel like Apple Wallet: swipe to a card, see THAT
    /// card's insights, allocation, and savings rate instantly.
    ///
    /// Falls back to nil only when there are no cards, in which case downstream
    /// computed props use aggregate/preferred-currency defaults.
    private var budgetCard: BankCard? { selectedCard }
    
    /// Currency the budget insights are denominated in. If a budget card is
    /// selected, use its currency; otherwise fall back to user's preferred.
    private var budgetCurrency: String {
        budgetCard?.resolvedCurrency ?? CurrencyManager.shared.preferredCurrency
    }

    /// Total income this month, scoped to the budget card if set.
    /// - When budget card is set → income from THIS card's tx (this month only).
    /// - When unset → scheduled salary or all-card aggregate (legacy).
    /// All amounts are converted to budgetCurrency for consistent comparison.
    private var totalMonthlyIncome: Double {
        let cal = Calendar.current
        let monthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: Date()))
        
        // Per-card mode: income on the selected card. Prefer the SALARY SCHEDULE
        // for that card — month-to-date income alone reads as near-zero for the
        // whole stretch before payday (a late payday like the 24th), which
        // collapsed the budget limit and produced absurd insights ("416% over").
        if let card = budgetCard {
            let cardSalaries = salarySchedules.filter { $0.isActive && $0.cardID == card.id }
            let active = cardSalaries.isEmpty ? salarySchedules.filter { $0.isActive } : cardSalaries
            func conv(_ tx: TxRecord) -> Double {
                CurrencyManager.shared.convert(tx.amount, from: tx.currency.isEmpty ? budgetCurrency : tx.currency,
                                               to: budgetCurrency)
            }
            // Stated monthly income only — same rule as the Smart Budget screen,
            // so Home's insight and that screen can't disagree about the limit.
            if !active.isEmpty {
                return active.reduce(0.0) {
                    $0 + CurrencyManager.shared.convert($1.amount, from: $1.currency, to: budgetCurrency)
                }
            }
            return card.transactions
                .filter { $0.amount > 0 && $0.txSubtype != .transfer && $0.date >= monthStart }
                .reduce(0.0) { $0 + conv($1) }
        }
        
        // Aggregate mode: prefer scheduled salary, otherwise sum all positive tx
        // Convert — a USD freelance schedule beside an IDR salary was being
        // added as a bare number, so budgets were sized off a nonsense income.
        let scheduled = salarySchedules.filter { $0.isActive }
            .reduce(0.0) { $0 + CurrencyManager.shared.toPreferred($1.amount, from: $1.currency) }
        if scheduled > 0 { return scheduled }
        return vm.cards.flatMap { $0.transactions }
            .filter { $0.amount > 0 && $0.txSubtype != .transfer && $0.date >= monthStart }
            .reduce(0.0) { $0 + CurrencyManager.shared.toPreferred($1.amount, from: $1.currency) }
    }

    /// Transactions to feed into insight engines. When a budget card is set,
    /// only that card's tx are returned — keeps spending analysis aligned with
    /// the income computation above.
    private var budgetTransactions: [TxRecord] {
        if let card = budgetCard {
            return card.transactions
        }
        return vm.cards.flatMap { $0.transactions }
    }

    /// Cheap change-signal for the memoized insights: total transaction count
    /// across all cards. Recompute fires when a tx is added or removed.
    private var totalTxCount: Int { vm.cards.reduce(0) { $0 + $1.transactions.count } }

    /// Runs the three Smart-Budget analyses ONCE, off the render path, storing
    /// the results in @State. Called on appear and whenever the inputs change
    /// (selected card, tx count, budget on/off, ratios) — never per render.
    private func recomputeHomeInsights() {
        guard SmartBudgetManager.shared.hasActiveBudget else {
            cachedInsights = []; cachedAnomalies = []; cachedRecurring = []
            return
        }
        let tx = budgetTransactions
        // Scope insights to the PAY CYCLE (same window the Smart Budget screen
        // uses) so Home and Smart Budget can't disagree about being over budget.
        let cycleStart: Date? = salarySchedules.first(where: { $0.isActive })
            .map { StatPeriod.payCycleRange(payDay: $0.dayOfMonth).start }
        cachedInsights = SmartBudgetManager.shared.evaluateAll(
            allTransactions: tx, income: totalMonthlyIncome,
            cardID: budgetCard?.id.uuidString, configs: cardBudgetConfigs,
            targetCurrency: budgetCurrency, goals: activeGoals,
            periodStart: cycleStart)
        cachedAnomalies = SmartBudgetManager.shared.spendingAnomalies(allTransactions: tx)
        cachedRecurring = SmartBudgetManager.shared.detectRecurring(allTransactions: tx)
    }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    // Header always visible
                    HomeHeader(vm: vm, showSearch: $showSearch, showNotifications: $showNotifications)
                        .padding(.horizontal, 22)
                        .padding(.top, 18)
                        .opacity(headerAppeared ? 1 : 0)
                        .offset(y: headerAppeared ? 0 : -16)
                        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.05), value: headerAppeared)

                    if !hasCards {
                        NoCardState(showAddCard: $showAddCard, showAddSalary: $showAddSalary)
                            .padding(.top, 40)
                                                        .opacity(contentAppeared ? 1 : 0)
                            .offset(y: contentAppeared ? 0 : 30)
                            .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.15), value: contentAppeared)

                    } else {
                        if !hasSalary {
                            SetupSalaryBanner(showAddSalary: $showAddSalary)
                                .padding(.horizontal, 22)
                                .padding(.top, 14)
                                                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if let salary = nearestSalary {
                            Button { HapticManager.shared.tap(); showSalarySheet = true } label: {
                                SalaryReminderBanner(schedule: salary, tappable: true)
                            }
                            .buttonStyle(ScaleButtonStyle())
                            .padding(.horizontal, 22)
                            .padding(.top, hasSalary ? 14 : 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        // Smart Insights banner — Royal feature.
                        // hasActiveBudget combines `isEnabled` and the Royal
                        // canAccess check; using it here keeps the gate logic
                        // identical to the export view, transaction blocker,
                        // and any future caller — change once, propagates.
                        // Multi-banner stack: primary + up to 1 secondary
                        // (positive feedback when primary is a warning). Capped
                        // at 2 to avoid stack-spam on a small home viewport.
                        // Values are memoized (recomputeHomeInsights) so this
                        // renders instantly without re-running the engine.
                        ForEach(Array(cachedInsights.prefix(2).enumerated()), id: \.offset) { idx, insight in
                            Button { HapticManager.shared.tap(); showSmartBudget = true } label: {
                                SmartInsightBanner(
                                    insight: insight,
                                    tappable: idx == 0,  // chevron only on primary
                                    onAction: { kind in routeInsightAction(kind) }
                                )
                            }
                            .buttonStyle(ScaleButtonStyle())
                            .padding(.horizontal, 22)
                            .padding(.top, idx == 0 ? 10 : 6)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .id("insight-\(budgetCard?.id.uuidString ?? "none")-\(idx)")
                        }

                        // Spending anomaly banner — Royal feature (memoized).
                        ForEach(cachedAnomalies.prefix(1)) { anomaly in
                            SmartInsightBanner(insight: anomaly)
                                .padding(.horizontal, 22)
                                .padding(.top, 8)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        // Declared recurring charge coming up — from the Monthly
                        // Expenses schedules the user set up themselves. Shown
                        // BEFORE the detected-pattern banner because a declared
                        // schedule is a certainty, not a guess.
                        if let due = upcomingDeclaredRecurring {
                            DeclaredRecurringBanner(expense: due)
                                .padding(.horizontal, 22)
                                .padding(.top, 8)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        // Recurring reminder — Royal feature (memoized).
                        if let next = cachedRecurring.first(where: { $0.isDueSoon }) {
                            RecurringReminderBanner(pattern: next, onDismiss: { recomputeHomeInsights() })
                                .padding(.horizontal, 22)
                                .padding(.top, 8)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if selectedCardBalance < 0 {
                            NegativeBalanceBanner(balance: selectedCardBalance, currency: selectedCardCurrency)
                                .padding(.horizontal, 22)
                                .padding(.top, 10)
                                                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if let pinned = pinnedGoals.first {
                            Button { HapticManager.shared.tap(); showWishlistSheet = true } label: {
                                PinnedGoalBanner(goal: pinned, tappable: true)
                            }
                            .buttonStyle(ScaleButtonStyle())
                            .padding(.horizontal, 22)
                            .padding(.top, 14)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        // Card Carousel — capped width on iPad
                        CardCarousel(vm: vm)
                                                        .padding(.top, 18)
                            .opacity(contentAppeared ? 1 : 0)
                            .scaleEffect(contentAppeared ? 1 : 0.94)
                            .animation(.spring(response: 0.6, dampingFraction: 0.78).delay(0.12), value: contentAppeared)

                        // Net Worth — cash minus liabilities. Only shown when the
                        // user actually has liabilities (credit cards / debts),
                        // otherwise it's just the cash total again.
                        if hasLiabilities {
                            let fmt = { (v: Double) in CurrencyManager.shared.formatted(v, currency: CurrencyManager.shared.preferredCurrency) }
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 10) {
                                    Image(systemName: "chart.pie.fill").font(.system(size: 13)).foregroundStyle(AppTheme.purple)
                                    Text(loc("home.net_worth")).font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                                    Spacer()
                                    Text((netWorth < 0 ? "-" : "") + fmt(Swift.abs(netWorth)))
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(netWorth >= 0 ? AppTheme.textPrimary : AppTheme.red)
                                }
                                // Spell out the arithmetic — a bare "net worth"
                                // figure (especially a negative one) is alarming
                                // and unreadable without its parts.
                                Text(goalSavings > 0.5
                                     ? String(format: loc("home.net_worth_breakdown_savings"),
                                              fmt(totalBalance), fmt(goalSavings), fmt(totalLiabilities))
                                     : String(format: loc("home.net_worth_breakdown"),
                                              fmt(totalBalance), fmt(totalLiabilities)))
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppTheme.textSecondary.opacity(0.75))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.purple.opacity(0.15), lineWidth: 1))
                            .padding(.horizontal, 22).padding(.top, 12)
                            .opacity(contentAppeared ? 1 : 0)
                        }

                        // Category filter — grid on iPad, scroll on iPhone
                        CategoryFilterBar(selectedFilter: $categoryFilter)
                                                        .padding(.top, 22)
                            .opacity(contentAppeared ? 1 : 0)
                            .offset(y: contentAppeared ? 0 : 20)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: contentAppeared)

                        TransactionSection(
                            transactions: selectedCardTransactions,
                            cards: queriedCards,
                            showViewAll: true,
                            allTransactions: budgetTransactions,
                            categoryFilter: categoryFilter,
                            onClearFilter: { withAnimation { categoryFilter = nil } }
                        )
                        .id(vm.selectedCardIndex)
                        .padding(.top, 28)
                        .padding(.horizontal, 22)
                                                .opacity(contentAppeared ? 1 : 0)
                        .offset(y: contentAppeared ? 0 : 24)
                        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.28), value: contentAppeared)
                    }

                    Spacer(minLength: 120)
                }
                .frame(maxWidth: .infinity) // Center the content column
            }
            
            // Receipt scan moved into AddTransactionSheet as an entry button at
            // the top of the form — discoverable in the same place users go to
            // record any expense, instead of a separate floating button.
        }
        .onChange(of: vm.selectedCardIndex) { _, _ in
            withAnimation(.spring(response: 0.3)) { categoryFilter = nil }
            recomputeHomeInsights()
        }
        // Recompute memoized insights only when their inputs actually change —
        // not on every render. Keeps Home smooth as transactions pile up.
        .onChange(of: totalTxCount)            { _, _ in recomputeHomeInsights() }
        .onChange(of: budgetManager.isEnabled) { _, _ in recomputeHomeInsights() }
        .onChange(of: budgetManager.dailyRatio)     { _, _ in recomputeHomeInsights() }
        .onChange(of: budgetManager.lifestyleRatio) { _, _ in recomputeHomeInsights() }
        .onChange(of: budgetManager.investDebtRatio){ _, _ in recomputeHomeInsights() }
        .onAppear {
            headerAppeared  = true
            contentAppeared = true
            recomputeHomeInsights()
        }
        .sheet(isPresented: $vm.showCardManager) {
            CardListView(vm: vm)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showSearch) {
            SearchView(vm: vm)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showNotifications) {
            NotificationCenterView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showAddCard) {
            CardFormSheet(vm: vm, editCard: nil)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showAddSalary) {
            SalaryFormSheet(vm: SalaryViewModel(), context: context)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showSalarySheet) {
            SalaryView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showWishlistSheet) {
            WishlistView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showSmartBudget) {
            SmartBudgetSettingsSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showDebtFromInsight) {
            DebtView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }

    /// Route handler for `SmartInsight.action`. Each kind opens the matching
    /// sheet on Home — this lives on HomeView (not the engine) because the
    /// engine is intentionally UI-agnostic.
    private func routeInsightAction(_ kind: SmartInsightAction.Kind) {
        switch kind {
        case .openBudgetSettings: showSmartBudget = true
        case .openSavingsGoals:   showWishlistSheet = true
        case .openDebt:           showDebtFromInsight = true
        case .acknowledge:        break  // banner state managed elsewhere
        }
    }
}

// MARK: - No Card State

struct NoCardState: View {
    @Binding var showAddCard: Bool
    @Binding var showAddSalary: Bool
    @State private var pulse = false

    // Progress: 0 of 3 steps done when no card
    private let steps: [(String, String, String)] = [
        ("creditcard.fill",   "Add a card",    "Visa or Mastercard"),
        ("banknote.fill",     "Set up salary", "So we know your income"),
        ("plus.circle.fill",  "Add expenses",  "Track your spending")
    ]

    var body: some View {
        VStack(spacing: 24) {
            // Animated mascot
            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(AppTheme.accent.opacity(0.10 - Double(i) * 0.025), lineWidth: 1.5)
                        .frame(width: CGFloat(110 + i * 40), height: CGFloat(110 + i * 40))
                        .scaleEffect(pulse ? 1.08 : 1)
                        .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true).delay(Double(i) * 0.35), value: pulse)
                }
                Circle()
                    .fill(Color.black)
                    .frame(width: 96, height: 96)
                    .shadow(color: AppTheme.accent.opacity(0.45), radius: 20)
                DiPoLogo(size: 96, showBackground: true)
                    .clipShape(Circle())
            }

            VStack(spacing: 6) {
                Text(loc("home.get_started")).font(.system(size: 24, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                Text(loc("home.get_started_sub"))
                    .font(.system(size: 14)).foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
            }

            // Progress bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(AppTheme.cardMid).frame(height: 6)
                    RoundedRectangle(cornerRadius: 4).fill(AppTheme.accent).frame(width: g.size.width * 0, height: 6)
                }
            }
            .frame(height: 6)
            .padding(.horizontal, 32)

            Text(loc("home.step1")).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)

            // Tappable step rows
            VStack(spacing: 10) {
                // Step 1 — Add card (always active, tappable)
                Button { HapticManager.shared.tap(); showAddCard = true } label: {
                    TappableSetupStep(number: 1, icon: "creditcard.fill", title: loc("onboarding.add_card"),
                                      subtitle: loc("onboarding.sub_card"), isActive: true, isDone: false)
                }
                .buttonStyle(ScaleButtonStyle())

                // Step 2 — Salary (shown but requires card first — tap shows hint)
                TappableSetupStep(number: 2, icon: "banknote.fill", title: loc("onboarding.add_salary"),
                                  subtitle: loc("onboarding.sub_salary"), isActive: false, isDone: false)

                // Step 3 — Expenses (locked)
                TappableSetupStep(number: 3, icon: "plus.circle.fill", title: loc("onboarding.add_transactions"),
                                  subtitle: loc("onboarding.sub_transactions"), isActive: false, isDone: false)
            }
            .padding(.horizontal, 28)

            Button { HapticManager.shared.success(); showAddCard = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 18))
                    Text(loc("home.add_first_card")).font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(AppTheme.bg)
                .padding(.horizontal, 36).padding(.vertical, 16)
                .background(AppTheme.accent, in: Capsule())
                .shadow(color: AppTheme.accent.opacity(0.65), radius: 18, y: 6)
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 8)
        .onAppear { pulse = true }
    }
}

struct TappableSetupStep: View {
    let number: Int
    let icon: String
    let title: String
    let subtitle: String
    let isActive: Bool
    let isDone: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isDone ? AppTheme.accent : isActive ? AppTheme.accent.opacity(0.15) : AppTheme.cardDark)
                    .frame(width: 36, height: 36)
                    .overlay(Circle().stroke(isActive || isDone ? AppTheme.accent.opacity(0.5) : AppTheme.cardMid, lineWidth: 1))
                if isDone {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(AppTheme.bg)
                } else {
                    Image(systemName: icon).font(.system(size: 14))
                        .foregroundStyle(isActive ? AppTheme.accent : AppTheme.textSecondary.opacity(0.5))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? AppTheme.textPrimary : AppTheme.textSecondary.opacity(0.5))
                Text(subtitle).font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary.opacity(isActive ? 0.8 : 0.4))
            }
            Spacer()
            if isActive {
                ZStack {
                    Circle().fill(AppTheme.accent).frame(width: 28, height: 28)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(AppTheme.bg)
                }
            } else if isDone {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(AppTheme.accent)
            } else {
                Circle().fill(AppTheme.cardMid).frame(width: 28, height: 28)
                    .overlay(Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary.opacity(0.4)))
            }
        }
        .padding(14)
        .background(isActive ? AppTheme.accent.opacity(0.07) : AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isActive ? AppTheme.accent.opacity(0.25) : Color.clear, lineWidth: 1))
    }
}


// MARK: - Smart Insight Banner

struct SmartInsightBanner: View {
    let insight: SmartInsight
    var tappable: Bool = false
    /// Optional handler for the action CTA. If insight has an action and
    /// this closure is provided, a button renders below the body. Caller
    /// is responsible for routing (open settings, open goals, etc.) — the
    /// engine stays UI-free.
    var onAction: ((SmartInsightAction.Kind) -> Void)? = nil
    @State private var appeared = false
    /// Local hide state — set when user dismisses via long-press menu.
    /// The engine's persistent dismissal kicks in next render via
    /// `notDismissed`; this state just removes the banner instantly.
    @State private var isDismissed = false
    /// Coaching topic shown for first-time viewers of this insight category.
    /// Resolved on appear; nil = user has seen this kind before, hide panel.
    @State private var coachingTopic: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(insight.color.opacity(0.15)).frame(width: 40, height: 40)
                    Image(systemName: insight.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(insight.color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(loc("home.smart_insight"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(insight.color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(insight.color.opacity(0.15), in: Capsule())
                        // Confidence badge — only show for low/medium, since
                        // high is the default and badging it everywhere would
                        // add noise. Medium = "we have a hunch", low = "data
                        // is too thin to be sure".
                        if insight.confidence != .high {
                            HStack(spacing: 3) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 9))
                                Text(insight.confidence == .low
                                     ? loc("insight.confidence.low")
                                     : loc("insight.confidence.medium"))
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(AppTheme.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AppTheme.cardMid.opacity(0.4), in: Capsule())
                        }
                    }
                    Text(insight.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(insight.body)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineSpacing(1)
                }
                Spacer()
                if tappable && insight.action == nil {
                    // Chevron only when the whole banner is tappable AND
                    // there's no action button — otherwise the banner shows
                    // its own primary action (less ambiguous).
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                }
            }
            // First-time coaching — explains what the insight category
            // means to a beginner. Compact panel below the body, with a
            // "Got it" tap to dismiss permanently. Power users (already-
            // seen) skip this entirely.
            if let topic = coachingTopic {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(loc("coaching.\(topic).body"))
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineSpacing(2)
                        Button {
                            HapticManager.shared.tap()
                            SmartBudgetManager.shared.markCoachingSeen(topic)
                            withAnimation { coachingTopic = nil }
                        } label: {
                            Text(loc("coaching.got_it"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.orange)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(AppTheme.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.orange.opacity(0.2), lineWidth: 1))
            }

            // Action CTA — drives the user toward a concrete next step
            // instead of leaving them to guess. Stop propagation with
            // PlainButtonStyle so tapping the button doesn't also fire
            // the parent banner's tap gesture (when wrapped in a Button).
            if let action = insight.action, let handler = onAction {
                Button {
                    HapticManager.shared.tap()
                    handler(action.kind)
                } label: {
                    HStack(spacing: 6) {
                        Text(action.label)
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(insight.color)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(insight.color.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(insight.color.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(insight.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(insight.color.opacity(0.2), lineWidth: 1))
        .opacity(isDismissed ? 0 : (appeared ? 1 : 0))
        .frame(maxHeight: isDismissed ? 0 : nil)
        .onAppear {
            withAnimation(.spring(response: 0.5)) { appeared = true }
            // Resolve coaching topic once on appear so the panel doesn't
            // flicker after user dismisses it (state persists for this view).
            coachingTopic = SmartBudgetManager.shared.coachingTopic(for: insight)
        }
        // Long-press to dismiss. Persisted via SmartBudgetManager — same
        // insight type won't reappear this month. Discoverability is
        // moderate (no visible affordance) but matches iOS conventions
        // for "less prominent secondary actions".
        .contextMenu {
            Button(role: .destructive) {
                HapticManager.shared.tap()
                SmartBudgetManager.shared.dismissInsight(insight)
                withAnimation(.easeOut(duration: 0.25)) {
                    isDismissed = true
                }
            } label: {
                Label(loc("insight.action.dismiss"), systemImage: "eye.slash")
            }
        }
    }
}

// MARK: - Recurring Reminder Banner

// Upcoming DECLARED recurring charge (from Monthly Expenses). Unlike the
// detected-pattern banner below, this is a schedule the user created — a
// certainty. It answers "why will my balance drop?" before it happens.
struct DeclaredRecurringBanner: View {
    let expense: RecurringExpense
    @State private var appeared = false

    private var days: Int { RecurringDateEngine.daysUntil(dayOfMonth: expense.dayOfMonth) }
    private var whenText: String {
        if days <= 0 { return loc("recurring.due_today") }
        if days == 1 { return loc("recurring.due_tomorrow") }
        return String(format: loc("recurring.due_in"), days)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(expense.category.color.opacity(0.15)).frame(width: 40, height: 40)
                Image(systemName: expense.category.icon)
                    .font(.system(size: 16)).foregroundStyle(expense.category.color)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(loc("home.declared_recurring_badge"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(expense.category.color)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(expense.category.color.opacity(0.15), in: Capsule())
                    if days <= 0 {
                        Text(loc("tx.due_today"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppTheme.red)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AppTheme.red.opacity(0.15), in: Capsule())
                    }
                }
                Text("\(expense.label) · \(CurrencyManager.shared.formatted(expense.amount, currency: expense.currency))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                Text("\(whenText) · " + loc(expense.autoRecord ? "home.declared_auto_on" : "home.declared_auto_off"))
                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
        }
        .padding(12)
        .background(expense.category.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(expense.category.color.opacity(0.2), lineWidth: 1))
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.5)) { appeared = true } }
    }
}

struct RecurringReminderBanner: View {
    let pattern: SmartBudgetManager.RecurringPattern
    /// Called after the user hides this detected pattern, so Home can recompute.
    var onDismiss: (() -> Void)? = nil
    @State private var appeared = false

    private var daysUntil: Int {
        max(Calendar.current.dateComponents([.day], from: Date(), to: pattern.nextExpected).day ?? 0, 0)
    }

    /// A fixed bill/subscription vs a frequent discretionary habit — drives all
    /// the labels, colors, and copy so a warteg run never reads like a CC bill.
    private var isBill: Bool { pattern.kind == .bill }
    /// Bills keep the neutral blue "reminder" look; habits borrow the category
    /// color + icon so they clearly read as "your food/transport spending".
    private var tint: Color { isBill ? AppTheme.blue : pattern.category.color }
    private var iconName: String { isBill ? "arrow.clockwise.circle.fill" : pattern.category.icon }
    private var badgeText: String { isBill ? loc("tx.recurring") : loc("recurring.badge.habit") }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 40, height: 40)
                Image(systemName: iconName)
                    .font(.system(size: 18)).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(badgeText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(tint.opacity(0.15), in: Capsule())
                    Text(pattern.frequencyLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                    // "Due today" only makes sense for a bill — a habit isn't due.
                    if isBill && daysUntil == 0 {
                        Text(loc("tx.due_today"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppTheme.red)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AppTheme.red.opacity(0.15), in: Capsule())
                    }
                }
                // Merchant name gets the whole line. Appending the cadence here
                // ate the width and truncated BOTH ("makan malam hangry
                // nashville · ti…"), hiding the very thing that explains the
                // flag — so the cadence moved up beside the badge instead.
                Text(pattern.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                // Detail — bills get a "due" prediction; habits are framed as an
                // average spend, no due-date pressure.
                let amountStr = CurrencyManager.shared.formatted(pattern.amount, currency: pattern.currency)
                Text(detailText(amountStr))
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
                // One-line explainer so first-time users aren't confused.
                Text(isBill ? loc("recurring.help.bill") : loc("recurring.help.habit"))
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // Dismiss — hides this auto-detected pattern. It's derived from your
            // transactions (not a schedule you can delete), so this is the only
            // way to stop it reappearing.
            if let onDismiss {
                Button {
                    HapticManager.shared.tap()
                    SmartBudgetManager.shared.dismissRecurring(name: pattern.name)
                    withAnimation(.spring(response: 0.4)) { onDismiss() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(AppTheme.cardMid, in: Circle())
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(12)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.2), lineWidth: 1))
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.5)) { appeared = true } }
    }

    private func detailText(_ amountStr: String) -> String {
        if !isBill {
            // Habit: an average per-visit spend, not a payment due.
            return String(format: loc("recurring.detail_habit"), amountStr)
        }
        return daysUntil == 0
            ? String(format: loc("recurring.detail_today"), amountStr)
            : String(format: loc("recurring.detail"), amountStr, daysUntil)
    }
}

// MARK: - Setup Salary Banner

struct SetupSalaryBanner: View {
    @Binding var showAddSalary: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(AppTheme.blue.opacity(0.15)).frame(width: 42, height: 42)
                Image(systemName: "banknote").font(.system(size: 18)).foregroundStyle(AppTheme.blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("home.setup_salary"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Text(loc("home.setup_salary_sub"))
                    .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Button {
                HapticManager.shared.tap()
                showAddSalary = true
            } label: {
                Text(loc("home.set_up"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.bg)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(AppTheme.blue, in: Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(14)
        .background(AppTheme.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.blue.opacity(0.2), lineWidth: 1))
    }
}


// MARK: - Pinned Goal Banner

struct PinnedGoalBanner: View {
    let goal: SavingsGoal
    var tappable: Bool = false
    @State private var appeared = false

    private var progress: Double { goal.targetAmount > 0 ? min(goal.savedAmount / goal.targetAmount, 1.0) : 0 }
    private var remaining: Double { max(goal.targetAmount - goal.savedAmount, 0) }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                // Emoji + progress ring
                ZStack {
                    Circle()
                        .stroke(AppTheme.cardMid, lineWidth: 3)
                        .frame(width: 44, height: 44)
                    Circle()
                        .trim(from: 0, to: appeared ? progress : 0)
                        .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 1.0, dampingFraction: 0.8).delay(0.2), value: appeared)
                    Text(goal.emoji).font(.system(size: 20))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(goal.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.accent.opacity(0.7))
                    }
                    Text(String(format: loc("home.progress_to_go"),
                                Int(progress * 100),
                                CurrencyManager.shared.formatted(remaining, currency: goal.currency)))
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Text("\(CurrencyManager.shared.formatted(goal.savedAmount, currency: goal.currency))")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                    if tappable {
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }

            // Progress bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(AppTheme.cardMid).frame(height: 5)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [AppTheme.accent, AppTheme.accent.opacity(0.6)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * (appeared ? progress : 0), height: 5)
                        .animation(.spring(response: 1.0, dampingFraction: 0.8).delay(0.2), value: appeared)
                }
            }
            .frame(height: 5)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(AppTheme.accent.opacity(0.2), lineWidth: 1))
        .onAppear { appeared = true }
    }
}

// MARK: - Negative Balance Banner

struct NegativeBalanceBanner: View {
    let balance: Double
    var currency: String = CurrencyManager.shared.preferredCurrency

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(AppTheme.red.opacity(0.15)).frame(width: 42, height: 42)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18)).foregroundStyle(AppTheme.red)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("home.negative"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.red)
                Text(String(
                    format: loc("balance.review"),
                    CurrencyManager.shared.formatted(
                        abs(balance),
                        currency: currency
                    )
                ))
                    .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .background(AppTheme.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.red.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Salary Reminder Banner

struct SalaryReminderBanner: View {
    let schedule: SalarySchedule
    var tappable: Bool = false
    @State private var pulsing = false

    private var daysLeft: Int { SalaryDateEngine.daysUntilPay(dayOfMonth: schedule.dayOfMonth) }
    private var nextDate: Date { SalaryDateEngine.nextPayDate(dayOfMonth: schedule.dayOfMonth) }
    private var adjusted: Bool { SalaryDateEngine.wasAdjusted(intended: schedule.dayOfMonth, actual: nextDate) }

    private var urgency: BannerUrgency {
        if daysLeft == 0 { return .today }
        if daysLeft <= 3 { return .soon }
        if daysLeft <= 7 { return .week }
        return .normal
    }

    enum BannerUrgency {
        case today, soon, week, normal
        var color: Color {
            switch self {
            case .today:  return AppTheme.accent
            case .soon:   return AppTheme.orange
            case .week:   return AppTheme.blue
            case .normal: return Color(hex: "#5B6F6B")
            }
        }
        var icon: String {
            switch self {
            case .today:  return "banknote.fill"
            case .soon:   return "clock.fill"
            case .week:   return "calendar.badge.clock"
            case .normal: return "calendar"
            }
        }
    }

    private var daysLabel: String {
        switch daysLeft {
        case 0:  return loc("home.today_payday")
        case 1:  return loc("home.tomorrow_payday")
        default: return String(format: loc("home.left_payday"), daysLeft)
        }
    }

    private var formattedAmount: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.groupingSeparator = ","
        return "\(schedule.currency) \(f.string(from: NSNumber(value: schedule.amount)) ?? "")"
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if urgency == .today || urgency == .soon {
                    Circle().stroke(urgency.color.opacity(0.3), lineWidth: 1)
                        .frame(width: 50, height: 50)
                        .scaleEffect(pulsing ? 1.3 : 1)
                        .opacity(pulsing ? 0 : 0.6)
                        .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: pulsing)
                }
                Circle().fill(urgency.color.opacity(0.15)).frame(width: 40, height: 40)
                Image(systemName: urgency.icon).font(.system(size: 18)).foregroundStyle(urgency.color)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(daysLabel).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    if adjusted {
                        Text(loc("home.adjusted")).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppTheme.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AppTheme.orange.opacity(0.15), in: Capsule())
                    }
                }
                Text("\(schedule.label) - \(formattedAmount)").font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                let df: DateFormatter = {
                    let f = DateFormatter()
                    f.locale = LanguageManager.shared.currentLocale
                    f.dateFormat = DateFormatter.dateFormat(fromTemplate: "EEEEdMMMM", options: 0, locale: LanguageManager.shared.currentLocale)
                    return f
                }()
                Text(df.string(from: nextDate))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(urgency.color)
            }
            Spacer()
            HStack(spacing: 6) {
                VStack(spacing: 1) {
                    if daysLeft == 0 {
                        Text(loc("home.now")).font(.system(size: 11, weight: .black)).foregroundStyle(urgency.color)
                    } else {
                        Text("\(daysLeft)").font(.system(size: 20, weight: .bold)).foregroundStyle(urgency.color)
                        Text(loc("home.days")).font(.system(size: 9, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .frame(width: 44)
                if tappable {
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        .padding(14)
        .background(urgency.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(urgency.color.opacity(0.2), lineWidth: 1))
        .onAppear { pulsing = true }
    }
}

// MARK: - Home Header

struct HomeHeader: View {
    let vm: AppViewModel
    @Binding var showSearch: Bool
    @Binding var showNotifications: Bool
    private var notifMgr: NotificationManager { NotificationManager.shared }

    private var savedName: String { Keychain.load(key: "user_name") ?? "User" }
    private var initials: String {
        savedName.split(separator: " ").prefix(2)
            .compactMap { $0.first }.map(String.init).joined().uppercased()
    }
    private var profileImage: UIImage? {
        guard let data = UserDefaults.standard.data(forKey: "profile_photo") else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [AppTheme.cardMid, AppTheme.cardDark],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 46, height: 46)
                    .overlay(Circle().stroke(AppTheme.accent.opacity(0.25), lineWidth: 1))
                if let img = profileImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(Circle())
                } else {
                    Image("DiPoMascot")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 50, height: 50)
                        .clipShape(Circle())
//                    DiPoLogo(size: 46, showBackground: true)
//                        .clipShape(Circle())
                }
            }
            .shadow(color: AppTheme.accent.opacity(0.2), radius: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(loc("home.greeting")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                Text(savedName).font(.system(size: 17, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
            }
            Spacer()
            HStack(spacing: 14) {
                Button { HapticManager.shared.tap(); showSearch = true } label: {
                    ZStack {
                        Circle().fill(AppTheme.cardDark).frame(width: 42, height: 42)
                        Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .buttonStyle(ScaleButtonStyle())

                Button { HapticManager.shared.tap(); showNotifications = true } label: {
                    ZStack(alignment: .topTrailing) {
                        ZStack {
                            Circle().fill(AppTheme.cardDark).frame(width: 42, height: 42)
                            Image(systemName: notifMgr.hasUnread ? "bell.badge.fill" : "bell")
                                .font(.system(size: 17))
                                .foregroundStyle(notifMgr.hasUnread ? AppTheme.accent : AppTheme.textSecondary)
                        }
                        if notifMgr.unreadCount > 0 {
                            ZStack {
                                Circle().fill(AppTheme.red).frame(width: 18, height: 18)
                                Text(notifMgr.unreadCount > 9 ? "9+" : "\(notifMgr.unreadCount)")
                                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            }
                            .offset(x: 4, y: -4)
                        }
                    }
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
    }
}


// MARK: - Card Carousel

struct CardCarousel: View {
    @Bindable var vm: AppViewModel
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        VStack(spacing: 12) {
            TabView(selection: Binding(
                get: { vm.selectedCardIndex },
                set: { vm.selectCard($0) }
            )) {
                ForEach(Array(vm.cards.enumerated()), id: \.element.id) { index, card in
                    BankCardView(card: card)
                        .padding(.horizontal, 22)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 190)

            HStack(spacing: 5) {
                ForEach(0..<max(vm.cards.count, 1), id: \.self) { i in
                    Capsule()
                        .fill(i == vm.selectedCardIndex ? AppTheme.accent : AppTheme.textSecondary.opacity(0.35))
                        .frame(width: i == vm.selectedCardIndex ? 22 : 6, height: 6)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: vm.selectedCardIndex)
                }
            }
        }
    }
}

// MARK: - Bank Card View

struct BankCardView: View {
    @Bindable var card: BankCard
    @State private var isPressed = false
    /// Drives the balance count-up. Starts at 0 and animates to the real
    /// balance on appear; re-counts smoothly whenever the balance changes.
    @State private var animatedBalance: Double = 0

    private var cardCurrency: String {
        card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
    }

    /// Lifetime total (seed + every tx). Kept around because the negative-
    /// balance warning logic on Home reads from the underlying card
    /// computation — that warning is about overall solvency, not periodic
    /// flow, so it should stay cumulative.
    private var lifetimeBalance: Double {
        let liveBalance = card.transactions.reduce(0.0) { sum, tx in
            sum + CurrencyManager.shared.convert(tx.amount, from: tx.currency, to: cardCurrency)
        }
        return card.balance + liveBalance
    }

    /// The number actually shown on the card face. Shows the card's TOTAL
    /// balance (seed + every transaction, converted to the card currency) so
    /// it matches the Cards tab exactly and can legitimately go negative —
    /// a month-scoped figure hid overspending by resetting to 0 each month.
    /// The Statistics tab remains month-scoped for period analysis.
    // Credit cards show what's OWED, not a cash balance.
    private var totalBalance: Double { card.isCreditCard ? card.owedBalance() : lifetimeBalance }
    private var network: CardNetwork { CardNetwork.detect(from: card.cardNumber) }

    private var formattedBalance: String {
        let abs = Swift.abs(totalBalance)
        return (totalBalance < 0 ? "-" : "") + CurrencyManager.shared.formatted(abs, currency: cardCurrency)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(
                    colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))

            GeometryReader { g in
                Path { p in
                    p.move(to: .init(x: g.size.width * 0.32, y: 0))
                    p.addCurve(
                        to: .init(x: g.size.width, y: g.size.height * 0.7),
                        control1: .init(x: g.size.width * 0.74, y: -12),
                        control2: .init(x: g.size.width + 8, y: g.size.height * 0.32)
                    )
                    p.addLine(to: .init(x: g.size.width, y: 0))
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [network.accentColor.opacity(0.3), network.accentColor.opacity(0.05)],
                    startPoint: .top, endPoint: .bottom
                ))
            }
            .clipShape(RoundedRectangle(cornerRadius: 22))

            SparklineView().frame(width: 100, height: 28).offset(x: 18, y: 72).opacity(0.45)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if card.isDigitalWallet {
                        Image(systemName: "apps.iphone")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        Image(systemName: "wave.3.right")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    if card.isDigitalWallet, let wp = WalletProvider(rawValue: card.walletProvider) {
                        HStack(spacing: 4) {
                            Image(systemName: wp.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                            Text(loc("cards.digital_wallet"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    } else {
                        CardNetworkLogo(network: network)
                    }
                }
                Spacer()
                Text(card.holderName).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                // Phone or card number — inline eye toggle on the right
                HStack(spacing: 6) {
                    if card.isDigitalWallet {
                        Text(card.displayPhone)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.65))
                    } else {
                        Text(card.displayNumber)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    Button {
                        HapticManager.shared.tap()
                        card.isHidden.toggle()
                    } label: {
                        Image(systemName: card.isHidden ? "eye.slash" : "eye")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
                .padding(.top, 2)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Total balance (matches the Cards tab). No month
                        // suffix — this is the card's running balance, not a
                        // periodic figure.
                        Text(card.isCreditCard ? loc("cc.owed") : loc("home.balance_total"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                        // Hidden → static dots. Visible → CountUpText that
                        // rolls the number up on appear and re-counts on
                        // change. `.id(card.id)` resets the count-up when
                        // the carousel swaps to a different card so each
                        // card animates its own balance in.
                        Group {
                            if card.isHidden {
                                Text("••••••")
                            } else {
                                CountUpText(value: animatedBalance, currency: cardCurrency)
                            }
                        }
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(totalBalance < 0 ? AppTheme.red : .white)
                        .onAppear {
                            // Count up from 0 → balance on first display.
                            withAnimation(.easeOut(duration: 0.9)) {
                                animatedBalance = totalBalance
                            }
                        }
                        .onChange(of: totalBalance) { _, newValue in
                            // Re-count when a tx changes the balance.
                            withAnimation(.easeOut(duration: 0.55)) {
                                animatedBalance = newValue
                            }
                        }
                        if totalBalance < 0 && !card.isHidden {
                            Text(loc("home.negative")).font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AppTheme.red.opacity(0.9))
                        }
                    }
                    Spacer()
                    if !card.isDigitalWallet {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(loc("cards.expires")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                            Text(card.expireDate).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        }
                    }
                }
                .padding(.top, 10)
            }
            .padding(20)
        }
        .frame(height: 182)
        .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { p in
            isPressed = p
            if p { HapticManager.shared.tap() }
        }, perform: {})
    }
}

// MARK: - Sparkline

struct SparklineView: View {
    private let points: [Double] = [0.3, 0.5, 0.4, 0.7, 0.55, 0.8, 0.65]
    @State private var progress: Double = 0
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let step = w / Double(points.count - 1)
            Path { path in
                for (i, pt) in points.enumerated() {
                    let x = Double(i) * step; let y = h - pt * h
                    if i == 0 { path.move(to: .init(x: x, y: y)) }
                    else {
                        let prev = points[i-1]; let px = Double(i-1) * step; let py = h - prev * h
                        path.addCurve(to: .init(x: x, y: y),
                                      control1: .init(x: px + step*0.5, y: py),
                                      control2: .init(x: x - step*0.5, y: y))
                    }
                }
            }
            .trim(from: 0, to: progress)
            .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .onAppear { withAnimation(.easeOut(duration: 1.2).delay(0.4)) { progress = 1 } }
    }
}

// MARK: - Quick Actions

struct CategoryFilterBar: View {
    @Binding var selectedFilter: TxCategory?

    // Derive directly from TxCategory so labels auto-localize.
    // Only the subset relevant to expense/home-screen filtering.
    private let filterCategories: [TxCategory] = [
        .shopping, .food, .travel, .bills,
        .transport, .health, .commitment, .investment, .debtPayment, .salary, .other
    ]

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        if isPad {
            HStack(spacing: 0) {
                ForEach(filterCategories, id: \.self) { cat in
                    filterButton(cat).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 32)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(filterCategories, id: \.self) { cat in
                        filterButton(cat).frame(width: 64)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func filterButton(_ cat: TxCategory) -> some View {
        let isActive = selectedFilter == cat
        Button {
            HapticManager.shared.tap()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedFilter = isActive ? nil : cat
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isActive ? cat.color.opacity(0.18) : AppTheme.cardDark)
                        .frame(width: 58, height: 58)
                        .overlay(RoundedRectangle(cornerRadius: 16)
                            .stroke(isActive ? cat.color.opacity(0.6) : Color.clear, lineWidth: 1.5))
                    Image(systemName: cat.icon)
                        .font(.system(size: 22))
                        .foregroundStyle(isActive ? cat.color : AppTheme.textPrimary)
                        .scaleEffect(isActive ? 1.1 : 1)
                }
                Text(cat.shortLabel)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? cat.color : AppTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(ScaleButtonStyle())
    }
}


// MARK: - Transaction Section (grouped by date)

struct TransactionSection: View {
    let transactions: [TxRecord]       // per-card transactions
    let cards: [BankCard]
    var showViewAll: Bool = false
    var allTransactions: [TxRecord] = []
    var categoryFilter: TxCategory? = nil
    var onClearFilter: (() -> Void)? = nil
    @State private var showAll        = false
    @State private var showAllCards   = false
    @State private var selectedTx: TxRecord? = nil
    @State private var pendingDelete: TxRecord? = nil
    @Environment(\.modelContext) private var context

    /// Bridges the optional `pendingDelete` to the Bool the confirmation dialog
    /// needs; clearing it on dismiss cancels the pending delete.
    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
    }

    // Home shows the most RECENT activity across all time (newest first),
    // capped to a handful of rows below. It deliberately does NOT filter to
    // the current calendar month: doing so left Home looking empty on the 1st
    // of a new month even when the card had plenty of recent history (the
    // card's "this month" figure and the Statistics tab stay month-scoped —
    // this list is just a recent-activity preview). Full searchable history
    // lives behind "View all".
    private var recentTransactions: [TxRecord] {
        transactions.sorted { $0.date > $1.date }
    }

    // Apply category filter on top of the recent-activity window.
    private var filtered: [TxRecord] {
        let base = recentTransactions
        guard let filter = categoryFilter else { return base }
        return base.filter { $0.category == filter }
    }

    // Group by calendar day. `txs` is the displayed (row-capped) slice, but
    // `total` is the FULL day total across all filtered transactions — so the
    // day header always shows the real amount, and "See more" only reveals
    // more rows for detail (it never changes the header total).
    private var grouped: [(key: String, date: Date, txs: [TxRecord], total: Double)] {
        let cal = Calendar.current
        let locale = LanguageManager.shared.currentLocale
        // Real per-day totals from ALL filtered transactions (not the visible prefix).
        var fullByDay: [Date: Double] = [:]
        for tx in filtered { fullByDay[cal.startOfDay(for: tx.date), default: 0] += tx.amount }

        var dict: [Date: [TxRecord]] = [:]
        let displaySource = showAll ? Array(filtered.prefix(20)) : Array(filtered.prefix(6))
        for tx in displaySource {
            let day = cal.startOfDay(for: tx.date)
            dict[day, default: []].append(tx)
        }
        return dict.keys.sorted(by: >).map { day in
            let label: String
            if cal.isDateInToday(day)          { label = loc("common.today") }
            else if cal.isDateInYesterday(day) { label = loc("common.yesterday") }
            else {
                let df = DateFormatter()
                df.locale = locale
                df.dateFormat = DateFormatter.dateFormat(fromTemplate: "EEEEdMMM", options: 0, locale: locale)
                label = df.string(from: day)
            }
            return (key: label, date: day,
                    txs: (dict[day] ?? []).sorted { $0.date > $1.date },
                    total: fullByDay[day] ?? 0)
        }
    }

    /// tx.id → owning card, built ONCE. The old `cardFor` scanned every card's
    /// transactions per row (O(rows × total-tx)); this makes the per-row lookup
    /// O(1). Empty for single-card users (the row falls back to the only card).
    private var cardLookup: [UUID: BankCard] {
        guard cards.count > 1 else { return [:] }
        var map: [UUID: BankCard] = [:]
        for card in cards { for tx in card.transactions { map[tx.id] = card } }
        return map
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(loc("home.transactions"))
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Spacer()
                HStack(spacing: 12) {
                    // Only offer "See more" when there's actually more to
                    // reveal beyond the default 6 rows this month.
                    if filtered.count > 6 {
                        Button {
                            HapticManager.shared.tap()
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showAll.toggle() }
                        } label: {
                            Text(showAll ? loc("home.show_less") : loc("home.see_more"))
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    if showViewAll {
                        Button {
                            HapticManager.shared.tap()
                            showAllCards = true
                        } label: {
                            Text(loc("home.view_all"))
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.accent)
                        }
                    }
                }
            }
            .padding(.bottom, 8)

            // Active filter chip with clear button
            if let filter = categoryFilter {
                HStack(spacing: 8) {
                    Image(systemName: filter.icon).font(.system(size: 12)).foregroundStyle(filter.color)
                    Text(String(format: loc("home.filtered"), filter.displayLabel))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(filter.color)
                    Spacer()
                    Button {
                        HapticManager.shared.tap()
                        onClearFilter?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(filter.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(filter.color.opacity(0.2), lineWidth: 1))
                .padding(.bottom, 10)
                .transition(.opacity)
            }

            if filtered.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: categoryFilter != nil ? "line.3.horizontal.decrease.circle" : "tray")
                        .font(.system(size: 32)).foregroundStyle(AppTheme.textSecondary)
                    Text(categoryFilter != nil
                         ? String(format: loc("home.no_cat_tx"), categoryFilter!.displayLabel)
                         : loc("home.no_tx_card"))
                        .font(.system(size: 14)).foregroundStyle(AppTheme.textSecondary)
                    Text(categoryFilter != nil ? loc("home.try_diff_cat") : loc("home.tap_plus"))
                        .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary.opacity(0.7))

                    // Direct CTA — without this the user sees the empty
                    // state but has to know that the central "+" tab opens
                    // Add Transaction. Surfacing the action inline removes
                    // that guesswork and matches the pattern used by Wishlist
                    // / Debt empty states.
                    if categoryFilter == nil {
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
                }
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 20) {
                    // Build the tx→card index once for this render, not per row.
                    let cardIndex = cardLookup
                    ForEach(grouped, id: \.key) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            // Date header with the REAL daily total (all txs that
                            // day, not just the visible rows).
                            let dayTotal = group.total
                            HStack {
                                Text(group.key)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppTheme.textSecondary)
                                Spacer()
                                Text(dayTotal >= 0
                                     ? "+\(CurrencyManager.shared.formatted(dayTotal, currency: group.txs.first?.currency ?? CurrencyManager.shared.preferredCurrency))"
                                     : CurrencyManager.shared.formatted(dayTotal, currency: group.txs.first?.currency ?? CurrencyManager.shared.preferredCurrency))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(dayTotal >= 0 ? AppTheme.accent.opacity(0.7) : AppTheme.red.opacity(0.7))
                            }

                            VStack(spacing: 10) {
                                ForEach(group.txs) { tx in
                                    SwipeToDeleteRow(
                                        onTap: { selectedTx = tx },
                                        onDelete: { pendingDelete = tx }
                                    ) {
                                        TxRow(tx: tx, sourceCard: cardIndex[tx.id] ?? cards.first, showCard: cards.count > 1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(loc("tx.delete_prompt"), isPresented: deleteDialogBinding, titleVisibility: .visible) {
            Button(loc("common.delete"), role: .destructive) {
                if let tx = pendingDelete {
                    deleteTransactionWithGoalRollback(tx, context: context)
                    try? context.save()
                    HapticManager.shared.warning()
                }
                pendingDelete = nil
            }
            Button(loc("common.cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(loc("tx.delete_confirm"))
        }
        .sheet(item: $selectedTx) { tx in
            TransactionDetailSheet(tx: tx)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showAllCards) {
            AllTransactionsSheet(transactions: allTransactions, cards: cards)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }
}

// MARK: - All Transactions Sheet (cross-card combined view)

struct AllTransactionsSheet: View {
    let transactions: [TxRecord]
    let cards: [BankCard]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var selectedTx: TxRecord? = nil
    @State private var pendingDelete: TxRecord? = nil

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
    }

    private var grouped: [(key: String, date: Date, txs: [TxRecord])] {
        let cal = Calendar.current
        let locale = LanguageManager.shared.currentLocale
        // One formatter for the whole grouping pass — allocating it per day (the
        // full history can be dozens of days) hitched every re-render.
        let df = DateFormatter()
        df.locale = locale
        df.dateFormat = DateFormatter.dateFormat(fromTemplate: "EEEEdMMM", options: 0, locale: locale)
        var dict: [Date: [TxRecord]] = [:]
        for tx in transactions {
            let day = cal.startOfDay(for: tx.date)
            dict[day, default: []].append(tx)
        }
        return dict.keys.sorted(by: >).map { day in
            let label: String
            if cal.isDateInToday(day)          { label = loc("common.today") }
            else if cal.isDateInYesterday(day) { label = loc("common.yesterday") }
            else                               { label = df.string(from: day) }
            return (key: label, date: day, txs: (dict[day] ?? []).sorted { $0.date > $1.date })
        }
    }

    /// tx.id → owning card, built ONCE per render (this sheet spans all cards).
    /// Replaces the per-row O(cards × total-tx) scan with an O(1) lookup.
    private var cardLookup: [UUID: BankCard] {
        var map: [UUID: BankCard] = [:]
        for card in cards { for tx in card.transactions { map[tx.id] = card } }
        return map
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                if transactions.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray").font(.system(size: 40)).foregroundStyle(AppTheme.textSecondary)
                        Text(loc("tx.no_transactions")).font(.system(size: 16)).foregroundStyle(AppTheme.textSecondary)
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        // LazyVStack: this sheet lists the ENTIRE history, so
                        // rows must render on demand — a plain VStack built every
                        // row up front and lagged badly with many transactions.
                        LazyVStack(spacing: 20) {
                            // tx→card index built once, not per row.
                            let cardIndex = cardLookup
                            ForEach(grouped, id: \.key) { group in
                                VStack(alignment: .leading, spacing: 10) {
                                    // This sheet shows ALL rows (no prefix cap), so the
                                    // visible txs already equal the full day.
                                    // Convert before summing, and label with the
                                    // PREFERRED currency. Adding raw amounts and
                                    // then borrowing the first transaction's
                                    // currency turned a day holding both IDR and
                                    // USD rows into a single nonsense figure.
                                    let dayCurrency = CurrencyManager.shared.preferredCurrency
                                    let dayTotal = group.txs.reduce(0.0) { sum, tx in
                                        sum + CurrencyManager.shared.convert(
                                            tx.amount,
                                            from: tx.currency.isEmpty ? dayCurrency : tx.currency,
                                            to: dayCurrency)
                                    }
                                    HStack {
                                        Text(group.key)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(AppTheme.textSecondary)
                                        Spacer()
                                        Text(dayTotal >= 0
                                             ? "+\(CurrencyManager.shared.formatted(dayTotal, currency: dayCurrency))"
                                             : CurrencyManager.shared.formatted(dayTotal, currency: dayCurrency))
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(dayTotal >= 0 ? AppTheme.accent.opacity(0.7) : AppTheme.red.opacity(0.7))
                                    }
                                    VStack(spacing: 10) {
                                        ForEach(group.txs) { tx in
                                            SwipeToDeleteRow(
                                                onTap: { selectedTx = tx },
                                                onDelete: { pendingDelete = tx }
                                            ) {
                                                TxRow(tx: tx, sourceCard: cardIndex[tx.id] ?? cards.first, showCard: cards.count > 1, animateEntrance: false)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 8)
                        .padding(.bottom, 40)
                    }
                }
            }
            .confirmationDialog(loc("tx.delete_prompt"), isPresented: deleteDialogBinding, titleVisibility: .visible) {
                Button(loc("common.delete"), role: .destructive) {
                    if let tx = pendingDelete {
                        deleteTransactionWithGoalRollback(tx, context: context)
                        try? context.save()
                        HapticManager.shared.warning()
                    }
                    pendingDelete = nil
                }
                Button(loc("common.cancel"), role: .cancel) { pendingDelete = nil }
            } message: {
                Text(loc("tx.delete_confirm"))
            }
            .navigationTitle(loc("tx.all"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.done")) { dismiss() }.foregroundStyle(AppTheme.accent)
                }
            }
        }
        .sheet(item: $selectedTx) { tx in
            TransactionDetailSheet(tx: tx)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }
}

// MARK: - Swipe-to-Delete Row

/// Reusable swipe-to-delete wrapper for rows rendered inside a `ScrollView`
/// (where SwiftUI's native `List.swipeActions` isn't available). Swipe a row
/// left to reveal a Delete button; tap it to fire `onDelete`. Tapping the row
/// while closed runs `onTap` (open detail); tapping while open just closes it.
///
/// The drag only engages on horizontal-dominant movement, so vertical
/// scrolling stays smooth. Pairs with a single confirmation dialog at the list
/// level so an accidental swipe can't delete financial data in one motion.
// Swipe-to-delete row modeled on the iOS Mail / Phone (Calls) behavior:
//   • the row tracks the finger 1:1 while dragging (no animation lag),
//   • the red action STRETCHES with the swipe and its icon nudges,
//   • a FULL swipe past `fullSwipeThreshold` deletes on release (with a
//     confirming haptic the moment you cross it),
//   • a short swipe snaps open to a fixed Delete button; tapping it deletes,
//   • everything springs on release; vertical drags still scroll the list.
struct SwipeToDeleteRow<Content: View>: View {
    var onTap: () -> Void
    var onDelete: () -> Void
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0
    @State private var gestureStart: CGFloat? = nil
    @State private var crossedFull = false

    private let actionWidth: CGFloat = 88
    private let openThreshold: CGFloat = 44
    private let fullSwipeThreshold: CGFloat = 230   // drag this far → delete on release

    /// Positive width of the red action currently revealed.
    private var revealed: CGFloat { max(0, -offset) }
    private var isFullSwipe: Bool { revealed >= fullSwipeThreshold }
    /// 0→1 as the swipe grows to the resting open width. Drives the circular
    /// delete button's spring-in (scale + fade), iOS Notes-style.
    private var revealProgress: CGFloat { min(revealed / actionWidth, 1) }

    var body: some View {
        ZStack(alignment: .trailing) {
            // iOS-style delete: a single round red button with a "Delete"
            // label, sitting on the PLAIN list background — no red wash/slab
            // behind it. It springs in (scale + fade) as the row slides and
            // pops slightly larger once you cross the full-swipe threshold. A
            // long swipe still deletes on release; a short swipe rests open so
            // you can tap the button.
            if revealed > 0 {
                Button {
                    HapticManager.shared.tap()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { offset = 0 }
                    onDelete()
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .fill(AppTheme.red)
                                .frame(width: 44, height: 44)
                                .shadow(color: AppTheme.red.opacity(0.22), radius: 4, y: 2)
                            Image(systemName: "trash.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        Text(loc("common.delete"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.red)
                    }
                    .scaleEffect(isFullSwipe ? 1.15 : max(revealProgress, 0.4))
                    .opacity(min(Double(revealProgress) * 1.7, 1))
                    .animation(.spring(response: 0.32, dampingFraction: 0.55), value: isFullSwipe)
                }
                .buttonStyle(.plain)
                .frame(width: min(revealed, actionWidth))
            }

            content
                // Opaque background so the red action is hidden when closed.
                .background(AppTheme.bg)
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 16)
                        .onChanged { value in
                            // Engage only on horizontal-dominant drags (or when
                            // already open) so vertical scrolling stays smooth.
                            if gestureStart == nil {
                                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                                gestureStart = offset
                            }
                            guard let start = gestureStart else { return }
                            var next = start + value.translation.width
                            if next > 0 { next = 0 }                       // no right-swipe
                            if next < -actionWidth {                        // rubber-band past the button
                                next = -actionWidth - (-(next) - actionWidth) * 0.45
                            }
                            offset = next
                            // Confirming haptic the instant you cross into full-swipe.
                            if revealed >= fullSwipeThreshold, !crossedFull {
                                crossedFull = true; HapticManager.shared.tap()
                            } else if revealed < fullSwipeThreshold, crossedFull {
                                crossedFull = false
                            }
                        }
                        .onEnded { _ in
                            gestureStart = nil
                            let didFull = revealed >= fullSwipeThreshold
                            crossedFull = false
                            if didFull {
                                HapticManager.shared.warning()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 }
                                onDelete()
                            } else {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                                    offset = revealed >= openThreshold ? -actionWidth : 0
                                }
                            }
                        }
                )
                .onTapGesture {
                    if offset != 0 {
                        withAnimation(.spring(response: 0.3)) { offset = 0 }
                    } else {
                        onTap()
                    }
                }
        }
    }
}

struct TxRow: View {
    let tx: TxRecord
    var sourceCard: BankCard? = nil
    var showCard: Bool = false
    /// Entrance animation is nice on the short Home list, but in a long
    /// scrolling history it re-fires on EVERY row as it scrolls into view
    /// (LazyVStack re-runs `onAppear`), stacking dozens of springs → jank.
    /// Long lists pass `false`.
    var animateEntrance: Bool = true
    @State private var appeared = false

    /// Reused across rows — allocating a DateFormatter per row (per render) was
    /// a measurable scroll cost with a long history.
    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter(); df.dateStyle = .none; df.timeStyle = .short
        return df
    }()
    private var timeOnly: String {
        let f = TxRow.timeFormatter
        let loc = LanguageManager.shared.currentLocale
        if f.locale != loc { f.locale = loc }
        return f.string(from: tx.date)
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color(hex: tx.iconBgHex)).frame(width: 44, height: 44)
                Text(tx.icon)
                    .font(.system(size: tx.icon.count == 1 ? 16 : 18)).foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tx.name)
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                    // Subtype badge — small inline marker showing this tx is
                    // a refund or transfer. Without this, users can't tell
                    // at a glance which tx is treated specially by the
                    // engine; they'd have to tap each one to check. Hidden
                    // for .normal which is the default and would just add
                    // noise to most rows.
                    if tx.txSubtype != .normal {
                        HStack(spacing: 3) {
                            Image(systemName: tx.txSubtype.icon)
                                .font(.system(size: 8, weight: .semibold))
                            Text(tx.txSubtype.displayLabel)
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(AppTheme.orange)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(AppTheme.orange.opacity(0.15), in: Capsule())
                    }
                    // Auto-posted marker — a recurring charge or salary credit
                    // the engine created. Answers "where did my balance go?"
                    // right in the list instead of looking like a manual entry.
                    if tx.notes == "tx.note.recurring_auto" || tx.notes == "tx.note.salary_auto" {
                        let isSalary = tx.notes == "tx.note.salary_auto"
                        HStack(spacing: 3) {
                            Image(systemName: isSalary ? "banknote" : "arrow.clockwise")
                                .font(.system(size: 8, weight: .semibold))
                            Text(loc(isSalary ? "tx.badge.auto_salary" : "tx.badge.auto_recurring"))
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(isSalary ? AppTheme.accent : AppTheme.blue)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background((isSalary ? AppTheme.accent : AppTheme.blue).opacity(0.13), in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text(timeOnly)
                        .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    // Source of fund badge — shown when user has multiple cards
                    if showCard, let card = sourceCard {
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(LinearGradient(
                                    colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                                    startPoint: .leading, endPoint: .trailing))
                                .frame(width: 12, height: 8)
                            Text("••\(card.cardNumber.suffix(2))")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(AppTheme.cardMid, in: Capsule())
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(tx.amount >= 0
                     ? "+\(CurrencyManager.shared.formatted(tx.amount, currency: tx.currency))"
                     : CurrencyManager.shared.formatted(tx.amount, currency: tx.currency))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tx.amount >= 0 ? AppTheme.green : AppTheme.textPrimary)
                Text(tx.displayType)
                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
            }
        }
        .opacity(animateEntrance ? (appeared ? 1 : 0) : 1)
        .offset(x: animateEntrance ? (appeared ? 0 : 20) : 0)
        .onAppear {
            guard animateEntrance, !appeared else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { appeared = true }
        }
    }
}
