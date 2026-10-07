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
    @Query(filter: #Predicate<Receivable> { !$0.isSettled }) private var receivables: [Receivable]
    /// Per-card budget configurations. Each row stores Smart Budget ratios for
    /// one card; cards without a config row use SmartBudgetManager's global
    /// defaults. Looked up by `cardID == BankCard.id.uuidString`.
    @Query private var cardBudgetConfigs: [CardBudgetConfig]
    /// For the Net Worth line: liabilities = credit-card owed + active debts.
    @Query(filter: #Predicate<DebtRecord> { $0.isActive }) private var activeDebts: [DebtRecord]
    /// Instalment principal counts as owed. Without it net worth read as if a
    /// 12-month instalment were not debt at all until each charge posted.
    @Query private var installments: [CardInstallment]
    @Query private var investmentHoldings: [InvestmentHolding]
    @Query private var physicalAssets: [PhysicalAsset]
    /// Declared Monthly Expenses — surfaced on Home when a charge is imminent,
    /// so the balance drop never comes as a surprise.
    @Query private var recurringExpenses: [RecurringExpense]

    /// The next DECLARED recurring charge due within 3 days (soonest first).
    private var upcomingDeclaredRecurring: RecurringExpense? {
        recurringExpenses
            .filter { $0.isActive && !$0.isChargedForCurrentDue }
            .map { ($0, RecurringDateEngine.daysUntil(dayOfMonth: $0.dayOfMonth)) }
            .filter { $0.1 <= 3 }
            .min { $0.1 < $1.1 }?.0
    }
    // Observed so HomeView re-renders whenever budgetCardID changes
    @State private var budgetManager = SmartBudgetManager.shared
    /// Held in @State so SwiftUI observes plan changes — reading the singleton
    /// inline inside a computed property registers no dependency, so the net
    /// worth chip would linger after a subscription lapsed until a redraw.
    @State private var premiumMgr = PremiumManager.shared

    @State private var showSearch           = false
    @State private var showNotifications    = false
    @State private var showAskDiPo          = false
    @State private var showDiPoPaywall      = false
    @State private var showAddCard          = false
    @State private var showAddSalary        = false
    @State private var categoryFilter: TxCategory? = nil
    /// Home showed every banner that had something to say — up to nine
    /// full-width cards before the user reached their own money. Each was
    /// individually reasonable; nothing ranked them, so everything shouted and
    /// nothing was heard. Now only the most urgent gets a card and the rest
    /// collapse behind one quiet row.
    /// Income and expense for the selected card this month, derived ONCE and
    /// held. Computing them inside the card's body would re-walk that card's
    /// whole history on every body pass — the exact pattern that made the
    /// transaction list stall. Refreshed from the same places the insight
    /// cache is refreshed.
    /// Net worth and its parts, refreshed on save rather than per render (see
    /// `onStoreChange`): each part reads the whole history.
    @State private var worth = NetWorthParts()
    @State private var monthIncome: Double = 0
    @State private var monthExpense: Double = 0
    @State private var flowPeriodLabel: String = ""
    @State private var showAllAttention = false
    @State private var showGoalDetail: SavingsGoal? = nil
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
            .reduce(0.0) { $0 + cm.convert($1.totalOwed(installments), from: $1.resolvedCurrency, to: pref) }
        let debt = activeDebts.reduce(0.0) { $0 + cm.convert($1.currentBalance, from: $1.currency, to: pref) }
        return cc + debt
    }

    /// Net worth aggregates data from two Royal-only features — savings goals
    /// and debt tracking. The chip had no entitlement check at all, so a user
    /// who lapsed from Royal (or restored a backup made on Royal) kept seeing
    /// both figures spelled out. Require access to BOTH sources it reads.
    private var canSeeNetWorth: Bool {
        premiumMgr.canAccess(.savingsGoals) && premiumMgr.canAccess(.smartDebt)
    }

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

    /// Money other people owe the user. An outstanding claim is an asset in
    /// exactly the way a debt is a liability; leaving it out understated the
    /// net worth of anyone who had lent money out.
    private var receivableAssets: Double {
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        let tx = vm.cards.flatMap(\.transactions)
        return receivables.reduce(0.0) {
            $0 + cm.convert($1.netWorthContribution(from: tx), from: $1.currency, to: pref)
        }
    }

    /// Current market value of every investment holding, in the preferred
    /// currency. Royal-only, so a free user's query is empty and this is 0.
    private var investmentValue: Double {
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        return investmentHoldings.reduce(0.0) {
            $0 + cm.convert($1.stats().marketValue, from: $1.currency, to: pref)
        }
    }

    /// Estimated value of the house, land, vehicles and electronics (Royal).
    private var physicalAssetValue: Double {
        AssetSummary.of(physicalAssets, currency: CurrencyManager.shared.preferredCurrency).totalValue
    }

    /// Net worth = cash + savings goals + receivables + investments + physical
    /// assets − liabilities.
    struct NetWorthParts: Equatable {
        var balance = 0.0, goals = 0.0, receivables = 0.0, investments = 0.0, assets = 0.0, liabilities = 0.0
        var total: Double { balance + goals + receivables + investments + assets - liabilities }
    }

    private func recomputeNetWorth() {
        let parts = NetWorthParts(balance: totalBalance, goals: goalSavings, receivables: receivableAssets,
                                  investments: investmentValue, assets: physicalAssetValue,
                                  liabilities: totalLiabilities)
        if parts != worth { worth = parts }
    }

    // Transactions for the currently selected card only
    private var selectedCard: BankCard? {
        guard !queriedCards.isEmpty else { return nil }
        let idx = min(vm.selectedCardIndex, queriedCards.count - 1)
        return queriedCards[idx]
    }

    /// Unsorted on purpose — `TransactionSection` orders these itself, and
    /// sorting here as well meant the same array was sorted twice on every
    /// body pass. This is the section's only consumer.
    private var selectedCardTransactions: [TxRecord] {
        selectedCard?.transactions ?? []
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

    /// The card "Wawasan Cerdas" insights are computed for: the MAIN card.
    ///
    /// It used to follow the carousel — swipe to a card, see that card's
    /// insights. That reads well and stopped being true the moment income was
    /// anchored: swiping to a second account measured THAT card's spending
    /// against the main card's salary, so the allowances belonged to one
    /// account and the spending to another. The carousel still swipes for
    /// balance and transactions; the budget block does not follow it, because a
    /// budget is a statement about one pot of money.
    ///
    /// nil only when there are no cards, where downstream props fall back to
    /// aggregate/preferred-currency defaults.
    private var budgetCard: BankCard? {
        MainCard.resolve(in: queriedCards) ?? selectedCard
    }
    
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
            let active = MainCard.salaries(salarySchedules)
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
                .filter { $0.amount > 0 && $0.txSubtype == TxSubtype.normal && $0.date >= monthStart }
                .reduce(0.0) { $0 + conv($1) }
        }
        
        // Aggregate mode: prefer scheduled salary, otherwise sum all positive tx
        // Convert — a USD freelance schedule beside an IDR salary was being
        // added as a bare number, so budgets were sized off a nonsense income.
        let scheduled = MainCard.salaries(salarySchedules)
            .reduce(0.0) { $0 + CurrencyManager.shared.toPreferred($1.amount, from: $1.currency) }
        if scheduled > 0 { return scheduled }
        let everyTx: [TxRecord] = vm.cards.flatMap { $0.transactions }
        let received: [TxRecord] = everyTx.filter { (tx: TxRecord) -> Bool in
            tx.amount > 0 && tx.txSubtype == TxSubtype.normal && tx.date >= monthStart
        }
        return received.reduce(0.0) { (sum: Double, tx: TxRecord) -> Double in
            sum + CurrencyManager.shared.toPreferred(tx.amount, from: tx.currency)
        }
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
    /// One linear pass over the selected card's transactions, converted into
    /// that card's currency — the same conversion the card face and the list
    /// use, so the three figures on this screen cannot contradict each other.
    ///
    /// The window is the PAY CYCLE, the same one Smart Budget and the Home
    /// insights already use. For someone paid on the 25th a calendar month is
    /// the wrong unit twice over: on the 3rd it shows three days of spending
    /// and no salary, and it splits one paycheque's spending across two months.
    /// No salary schedule → no cycle to speak of, so it falls back to the month.
    private func recomputeMonthFlow() {
        let cal = Calendar.current
        let windowStart: Date
        if let payDay = MainCard.payDay(salarySchedules) {
            // The cycle Statistics and Smart Budget use: opened on the day the
            // salary landed on the main card.
            windowStart = StatPeriod.cycle(payDay: payDay,
                                           salaryDates: StatPeriod.salaryDates(on: budgetCard)).start
            let df = DateFormatter()
            df.locale = LanguageManager.shared.currentLocale
            df.setLocalizedDateFormatFromTemplate("d MMM")
            flowPeriodLabel = String(format: loc("home.since_payday"), df.string(from: windowStart))
        } else {
            windowStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: Date()))
            flowPeriodLabel = loc("home.this_month")
        }

        guard let card = selectedCard else { monthIncome = 0; monthExpense = 0; return }
        let cur = card.resolvedCurrency
        // Read the pre-aggregated daily buckets instead of scanning the card's
        // whole ledger (see RollupEngine). This runs on the tx-count / balance /
        // payday change signals — off the render path — so keeping the cache
        // fresh here is safe. Statistics' rules: income is real income only and
        // a refund takes back its expense. Counting a refund as income here
        // made Home's two figures disagree with Statistics' for the same days.
        let buckets = RollupStore.shared.rebuildIfStale(context: context, txCount: totalTxCount)
        let window = RollupEngine.buckets(buckets, cardID: card.id.uuidString, from: windowStart)
        let totals = RollupEngine.totals(for: window, targetCurrency: cur,
                                         convert: { CurrencyManager.shared.convert($0, from: $1, to: $2) })
        monthIncome = totals.income
        monthExpense = max(totals.expenses, 0)
    }

    private func recomputeHomeInsights() {
        guard SmartBudgetManager.shared.hasActiveBudget else {
            cachedInsights = []; cachedAnomalies = []; cachedRecurring = []
            return
        }
        let tx = budgetTransactions
        // Scope insights to the PAY CYCLE (same window the Smart Budget screen
        // uses) so Home and Smart Budget can't disagree about being over budget.
        let payDay = MainCard.payDay(salarySchedules)
        let cycle = payDay.map {
            StatPeriod.cycle(payDay: $0, salaryDates: StatPeriod.salaryDates(on: budgetCard))
        }
        let cycleStart = cycle?.start
        // Where this period's spending is heading — Statistics' own projection,
        // so the warning here quotes the figure that screen shows.
        let projected: Double? = {
            guard let day = payDay, let card = budgetCard else { return nil }
            return StatisticsView.projectedCycleSpend(card: card, payDay: day,
                                                      recurrings: recurringExpenses,
                                                      currency: budgetCurrency)
        }()
        // Debt still due each month, so the surplus advice can put it before
        // investing: debt minimums plus credit-card instalments and minimums,
        // the same figure the Fixed Monthly Payments card counts.
        let cm = CurrencyManager.shared
        SmartBudgetManager.shared.debtDueMonthly =
            activeDebts.filter { !$0.manuallyClosed }
                .reduce(0.0) { $0 + cm.convert($1.minimumPayment, from: $1.currency, to: budgetCurrency) }
            + ObligationLoad.cardPayments(cards: vm.cards, installments: installments,
                                          debts: activeDebts, currency: budgetCurrency)
        cachedInsights = SmartBudgetManager.shared.evaluateAll(
            allTransactions: tx, income: totalMonthlyIncome,
            cardID: budgetCard?.id.uuidString, configs: cardBudgetConfigs,
            targetCurrency: budgetCurrency, goals: activeGoals,
            periodStart: cycleStart, periodEnd: cycle?.end,
            projectedSpend: projected)
        // Same `cycleStart` the insights above use — without it this ran on
        // calendar months and contradicted the card directly beside it.
        cachedAnomalies = SmartBudgetManager.shared.spendingAnomalies(
            allTransactions: tx, periodStart: cycleStart)
        cachedRecurring = SmartBudgetManager.shared.detectRecurring(allTransactions: tx)
    }

    /// Everything on Home with something to say, most urgent first.
    ///
    /// `rank` is urgency × actionability: a negative balance is both, a pinned
    /// savings goal is neither. The ranks are unique and the order below IS the
    /// policy — it is meant to be read as one list and argued with as one list,
    /// rather than being implied by where each banner happened to sit in the
    /// view hierarchy.
    private var attentionItems: [HomeAttentionItem] {
        var items: [HomeAttentionItem] = []

        if selectedCardBalance < 0 {
            items.append(.init(id: "negative", rank: 0, view: AnyView(
                NegativeBalanceBanner(balance: selectedCardBalance,
                                      currency: selectedCardCurrency))))
        }
        if !hasSalary {
            items.append(.init(id: "setup-salary", rank: 1, view: AnyView(
                SetupSalaryBanner(showAddSalary: $showAddSalary))))
        }
        // Smart Insights and anomalies are no longer banners here: DiPo says
        // them in his card above the transaction list (DiPoTalk.swift).
        // A declared schedule is a certainty; the detected pattern below is a
        // guess. Certainty outranks guess.
        if let due = upcomingDeclaredRecurring {
            items.append(.init(id: "declared-recurring", rank: 4, view: AnyView(
                DeclaredRecurringBanner(expense: due))))
        }
        // Payday is status, not a task — it ranks below anything asking for a
        // decision.
        if let salary = nearestSalary {
            items.append(.init(id: "payday", rank: 5, view: AnyView(
                Button { HapticManager.shared.tap(); vm.open(PlanRoute.salary) } label: {
                    SalaryReminderBanner(schedule: salary, tappable: true)
                }
                .buttonStyle(ScaleButtonStyle()))))
        }
        if let next = cachedRecurring.first(where: { $0.isDueSoon }) {
            items.append(.init(id: "recurring", rank: 6, view: AnyView(
                RecurringReminderBanner(pattern: next,
                                        onDismiss: { recomputeHomeInsights() }))))
        }
        if let pinned = pinnedGoals.first {
            items.append(.init(id: "goal-\(pinned.id)", rank: 8, view: AnyView(
                Button { HapticManager.shared.tap(); vm.open(PlanRoute.goals) } label: {
                    PinnedGoalBanner(goal: pinned, tappable: true)
                }
                .buttonStyle(ScaleButtonStyle()))))
        }
        return items.sorted { $0.rank < $1.rank }
    }

    private static let topAnchor = "home.top"

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {

                    // Header always visible
                    HomeHeader(vm: vm, showSearch: $showSearch, showNotifications: $showNotifications)
                        .id(Self.topAnchor)
                        .padding(.horizontal, 22)
                        .padding(.top, 18)
                        .opacity(headerAppeared ? 1 : 0)
                        .offset(y: headerAppeared ? 0 : -16)
                        .animation(AppMotion.appear, value: headerAppeared)

                    if !hasCards {
                        NoCardState(showAddCard: $showAddCard, showAddSalary: $showAddSalary)
                            .padding(.top, 40)
                                                        .opacity(contentAppeared ? 1 : 0)
                            .offset(y: contentAppeared ? 0 : 30)
                            .animation(AppMotion.appear, value: contentAppeared)

                    } else {
                        // One attention slot. Candidates are ranked by how
                        // urgent and how actionable they are; only the winner
                        // gets a card. The rest sit behind a single row so
                        // nothing is lost — it just stops competing.
                        let attention = attentionItems
                        if let top = attention.first {
                            top.view
                                .padding(.horizontal, 22)
                                .padding(.top, 14)
                                .transition(.move(edge: .top).combined(with: .opacity))

                            if showAllAttention {
                                ForEach(attention.dropFirst()) { item in
                                    item.view
                                        .padding(.horizontal, 22)
                                        .padding(.top, 8)
                                        .transition(.move(edge: .top).combined(with: .opacity))
                                }
                            }

                            if attention.count > 1 {
                                Button {
                                    HapticManager.shared.tap()
                                    withAnimation(AppMotion.appear) { showAllAttention.toggle() }
                                } label: {
                                    MoreAttentionRow(count: attention.count - 1,
                                                     expanded: showAllAttention)
                                }
                                .buttonStyle(ScaleButtonStyle())
                                .padding(.horizontal, 22)
                                .padding(.top, 8)
                            }
                        }

                        // Card Carousel — capped width on iPad
                        CardCarousel(vm: vm)
                                                        .padding(.top, 18)
                            .opacity(contentAppeared ? 1 : 0)
                            .scaleEffect(contentAppeared ? 1 : 0.94)
                            .animation(AppMotion.appear, value: contentAppeared)

                        // What came in and what went out this pay cycle. The card
                        // above says where the money stands; this says which
                        // direction it has been moving to get there.
                        MonthFlowCard(income: monthIncome,
                                      expense: monthExpense,
                                      currency: selectedCard?.resolvedCurrency
                                                ?? CurrencyManager.shared.preferredCurrency,
                                      periodLabel: flowPeriodLabel,
                                      isHidden: selectedCard?.isHidden ?? false)
                            .padding(.horizontal, 22)
                            .padding(.top, 14)
                            .opacity(contentAppeared ? 1 : 0)
                            .offset(y: contentAppeared ? 0 : 18)
                            .animation(AppMotion.appear, value: contentAppeared)

                        // Net Worth — cash minus liabilities. Only shown when the
                        // user actually has liabilities (credit cards / debts),
                        // otherwise it's just the cash total again.
                        if worth.liabilities > 0.5 && canSeeNetWorth {
                            let netWorth = worth.total
                            let fmt = { (v: Double) in CurrencyManager.shared.formatted(v, currency: CurrencyManager.shared.preferredCurrency) }
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 10) {
                                    Image(systemName: "chart.pie.fill").font(.system(.footnote)).foregroundStyle(AppTheme.purple)
                                    Text(loc("home.net_worth")).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                                    Spacer()
                                    Text((netWorth < 0 ? "-" : "") + fmt(Swift.abs(netWorth)))
                                        .font(.system(.subheadline, weight: .bold))
                                        .foregroundStyle(netWorth >= 0 ? AppTheme.textPrimary : AppTheme.red)
                                        // Roll the digits when a transaction
                                        // moves this. Seeing the figure change
                                        // is what links the action just taken
                                        // to its effect on net worth.
                                        .contentTransition(.numericText())
                                        .animation(.easeOut(duration: 0.45), value: netWorth)
                                }
                                // Spell out the arithmetic — a bare "net worth"
                                // figure (especially a negative one) is alarming
                                // and unreadable without its parts.
                                Text(worth.goals > 0.5
                                     ? String(format: loc("home.net_worth_breakdown_savings"),
                                              fmt(worth.balance), fmt(worth.goals), fmt(worth.liabilities))
                                     : String(format: loc("home.net_worth_breakdown"),
                                              fmt(worth.balance), fmt(worth.liabilities)))
                                    .font(.system(.caption2))
                                    .foregroundStyle(AppTheme.textSecondary.opacity(0.75))
                                    .fixedSize(horizontal: false, vertical: true)
                                // Investments live in their own menu, so name their
                                // share of net worth here rather than leaving the
                                // total unexplained.
                                if worth.investments > 0.5 {
                                    Text(String(format: loc("invest.networth_line"), fmt(worth.investments)))
                                        .font(.system(.caption2, weight: .medium))
                                        .foregroundStyle(AppTheme.accent)
                                }
                                if worth.assets > 0.5 {
                                    Text(String(format: loc("asset.networth_line"), fmt(worth.assets)))
                                        .font(.system(.caption2, weight: .medium))
                                        .foregroundStyle(AppTheme.teal)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.purple.opacity(0.15), lineWidth: 1))
                            .padding(.horizontal, 22).padding(.top, 12)
                            .opacity(contentAppeared ? 1 : 0)
                        }

                        // Category filter — grid on iPad, scroll on iPhone
                        CategoryFilterBar(selectedFilter: $categoryFilter)
                                                        .padding(.top, 22)
                            .opacity(contentAppeared ? 1 : 0)
                            .offset(y: contentAppeared ? 0 : 20)
                            .animation(AppMotion.appear, value: contentAppeared)

                        // Above the list it is about, and only ever one line
                        // unless it has a question to ask.
                        // DiPo, talking: unread notifications, then the Smart
                        // Insights, then today's check-in underneath.
                        VStack(alignment: .leading, spacing: 4) {
                            DiPoTalkCard(lines: dipoLines, isRoyal: dipoIsRoyal,
                                         onAction: handleDiPo,
                                         onAsk: { showAskDiPo = true })
                            DailyCheckInCard(embedded: true)
                        }
                        .padding(14)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        .padding(.horizontal, 22).padding(.top, 18)

                        TransactionSection(
                            transactions: selectedCardTransactions,
                            cards: queriedCards,
                            categoryFilter: categoryFilter,
                            onClearFilter: { withAnimation { categoryFilter = nil } },
                            sourceCard: selectedCard,
                            onOpenSearch: { HapticManager.shared.tap(); showSearch = true }
                        )
                        .id(vm.selectedCardIndex)
                        // The list reads as one surface now instead of floating
                        // loose on the page — it is a single thing ("what you
                        // spent") and its edges should say so.
                        .padding(16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
                        .padding(.top, 24)
                        .padding(.horizontal, 22)
                                                .opacity(contentAppeared ? 1 : 0)
                        .offset(y: contentAppeared ? 0 : 24)
                        .animation(AppMotion.appear, value: contentAppeared)
                    }

                    Spacer(minLength: 120)
                }
                // Centred AND capped. Without the cap the column simply
                // stretched to 626 pt on the Duo's inner display.
                .phoneWidthCapped()
                // Pin the column to the scroll view's OWN width. Under iOS 26 a
                // vertical ScrollView proposes an unbounded width to its content,
                // so every `.frame(maxWidth: .infinity)` child (the income/expense
                // card, the category row) expanded to its ideal size instead of
                // the viewport — the column grew past the screen and the whole
                // page could be dragged sideways. This clamps it to the container.
                .containerRelativeFrame(.horizontal)
            }
            // Tapping Home while already on Home brings the page back to the top.
            .onChange(of: vm.homeScrollToTop) { _, _ in
                withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
                    proxy.scrollTo(Self.topAnchor, anchor: .top)
                }
            }
            }

            // Receipt scan moved into AddTransactionSheet as an entry button at
            // the top of the form — discoverable in the same place users go to
            // record any expense, instead of a separate floating button.
        }
        .onChange(of: vm.selectedCardIndex) { _, _ in
            withAnimation(.spring(response: 0.3)) { categoryFilter = nil }
            recomputeHomeInsights()
            recomputeMonthFlow()
        }
        // Recompute memoized insights only when their inputs actually change —
        // not on every render. Keeps Home smooth as transactions pile up.
        .onChange(of: totalTxCount)            { _, _ in recomputeHomeInsights(); recomputeMonthFlow() }
        .onStoreChange(perform: recomputeNetWorth)
        // Editing an existing amount changes no COUNT, so the tx-count trigger
        // above misses it — the card face would move while income/expense sat
        // on a stale figure. The balance is already computed each body pass, so
        // watching it costs nothing and catches every edit that moves money.
        .onChange(of: selectedCardBalance)     { _, _ in recomputeMonthFlow() }
        // Setting up or moving the salary schedule moves where the cycle starts.
        .onChange(of: MainCard.payDay(salarySchedules)) { _, _ in recomputeMonthFlow() }
        .onChange(of: budgetManager.isEnabled) { _, _ in recomputeHomeInsights() }
        .onChange(of: budgetManager.dailyRatio)     { _, _ in recomputeHomeInsights() }
        .onChange(of: budgetManager.lifestyleRatio) { _, _ in recomputeHomeInsights() }
        .onChange(of: budgetManager.investDebtRatio){ _, _ in recomputeHomeInsights() }
        .trackScreen(.home)
        .onAppear {
            headerAppeared  = true
            contentAppeared = true
            // Open on the main card. The carousel remembers wherever it was
            // last swiped, which meant Home could greet the user with a card
            // that no other screen is talking about — the balance in front of
            // them belonged to one account while every insight below it
            // described another. Swiping away from it is still free; this only
            // sets where "no choice yet" lands.
            if let main = MainCard.resolve(in: queriedCards),
               let idx = queriedCards.firstIndex(where: { $0.id == main.id }) {
                vm.selectedCardIndex = idx
            }
            // Once: card payments that paid off a carried balance were filed
            // as transfers; re-file that part as the debt payment it was.
            CardPaymentDebt.reclassifyPastPayments(cards: queriedCards, context: context)
            recomputeHomeInsights()
            recomputeMonthFlow()
        }
        // A main card chosen in Wallet moves Home with it, rather than leaving
        // the two disagreeing until the next launch.
        .onChange(of: budgetManager.budgetCardID) { _, _ in
            if let main = MainCard.resolve(in: queriedCards),
               let idx = queriedCards.firstIndex(where: { $0.id == main.id }) {
                withAnimation(.spring(response: 0.4)) { vm.selectedCardIndex = idx }
            }
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
        .sheet(isPresented: $showAskDiPo) {
            AIChatView()
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showDiPoPaywall) {
            PaywallView()
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
    }

    /// Route handler for `SmartInsight.action`. Each kind opens the matching
    /// feature in its own tab — this lives on HomeView (not the engine) because
    /// the engine is intentionally UI-agnostic.
    // MARK: DiPo

    private var dipoIsRoyal: Bool { premiumMgr.canAccess(.aiAdvisor) }

    private var dipoLines: [DiPoLine] {
        DiPoScript.lines(unread: NotificationManager.shared.unreadCount,
                         insights: cachedInsights + cachedAnomalies,
                         isRoyal: dipoIsRoyal)
    }

    private func handleDiPo(_ action: DiPoLine.Action) {
        switch action {
        case .notifications:       showNotifications = true
        case .insight(let kind?):  routeInsightAction(kind)
        case .insight(nil):        vm.open(PlanRoute.budget)
        case .royal:               showDiPoPaywall = true
        case .none:                break
        }
    }

    private func routeInsightAction(_ kind: SmartInsightAction.Kind) {
        switch kind {
        case .openBudgetSettings: vm.open(PlanRoute.budget)
        case .openSavingsGoals:   vm.open(PlanRoute.goals)
        case .openDebt:           vm.open(PlanRoute.obligations)
        case .acknowledge:        break  // banner state managed elsewhere
        }
    }
}
