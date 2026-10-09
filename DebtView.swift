import UserNotifications
import SwiftUI
import SwiftData

// MARK: - Debt View (main screen)

struct DebtView: View {
    @Environment(\.modelContext) private var context
    @Query private var debts: [DebtRecord]
    @Query(sort: \SalarySchedule.createdAt) private var salaries: [SalarySchedule]
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    /// Direct tx query — fires onChange whenever a tx is added/deleted from
    /// anywhere in the app (Home, detail sheet, etc). Without this, deleting
    /// a debt-payment tx from Home would not propagate back to debt balances
    /// because @Query on parent BankCard doesn't observe child tx mutations.
    @Query private var allTransactions: [TxRecord]

    @State private var vm = DebtViewModel()
    @State private var appeared = false
    @State private var simulatorDebt: DebtRecord? = nil
    @State private var showSalarySetup = false
    @State private var showAllDebts = false
    @State private var showAddCreditCard = false
    @State private var editingCreditCard: BankCard? = nil
    @State private var logSpendCard: BankCard? = nil
    @State private var payingCard: BankCard? = nil
    @State private var deletingCard: BankCard? = nil
    @State private var payingDebt: DebtRecord? = nil
    @Query private var installments: [CardInstallment]
    @Query private var recurrings: [RecurringExpense]
    @Query private var budgetConfigs: [CardBudgetConfig]
    /// Inside ObligationsView the hub owns the header and the Simulate tab, so
    /// this view drops its own duplicate simulator button.
    var embedded: Bool = false
    /// Fixed obligations, shown next to the health score rather than as a
    /// separate verdict above it. Two health readings on one screen, computed
    /// differently, is worse than one — especially when they disagree.

    /// Credit cards are liability accounts — they live here in the Debt Tracker
    /// (the single door for creating one), sorted by amount owed.
    private var creditCards: [BankCard] {
        cards.filter { $0.isCreditCard }.sorted { $0.owedBalance() > $1.owedBalance() }
    }

    /// Max debts shown inline before collapsing behind "See all".
    private let debtPreviewLimit = 5

    /// Monthly income in the preferred currency.
    ///
    /// Priority:
    ///   1. Active salary schedule(s) — the user's STATED monthly income. This
    ///      is the signal even before payday lands this month, so the Debt
    ///      Tracker stops showing "set up income" all month until the salary tx
    ///      is auto-credited (a late-month payday like the 25th made income read
    ///      as 0 for most of the month).
    ///   2. Extra income transactions this month (bonus/freelance) are ADDED —
    ///      excluding the salary category to avoid double-counting once the
    ///      scheduled salary is auto-credited.
    ///   3. No schedule → fall back to all income transactions this month.
    /// Every figure on this screen is read from the main card.
    ///
    /// It used to sum every account while taking its RATIOS from the main card
    /// — an allowance computed on one account's income compared against
    /// spending from nine. That is how this screen came to announce Rp 19,1jt
    /// of overspending for a cycle that finished ahead. Same anchor as
    /// Statistics, Smart Budget and the alerts, so the four cannot disagree.
    private var scopedTx: [TxRecord] {
        MainCard.potTransactions(in: cards) ?? cards.flatMap { $0.transactions }
    }

    private var monthlyIncome: Double {
        let cal = Calendar.current
        let monthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: Date()))
        let pref = CurrencyManager.shared.preferredCurrency
        let conv: (TxRecord) -> Double = { tx in
            let c = tx.currency.isEmpty ? pref : tx.currency
            return CurrencyManager.shared.convert(tx.amount, from: c, to: pref)
        }
        let thisMonthIncome = scopedTx
            .filter { $0.amount > 0 && $0.txSubtype != .transfer && $0.date >= monthStart }

        let activeSalaries = MainCard.salaries(salaries)
        guard !activeSalaries.isEmpty else {
            // No schedule — use whatever income was actually logged.
            return thisMonthIncome.reduce(0) { $0 + conv($1) }
        }
        let scheduled = activeSalaries.reduce(0.0) {
            $0 + CurrencyManager.shared.convert($1.amount, from: $1.currency, to: pref)
        }
        // Deliberately NOT adding this month's other income.
        //
        // This used to be `scheduled + everything else positive logged this
        // month`, which meant a bonus, a THR, a reimbursement or a refund all
        // inflated "monthly income" — and every ratio built on it. A user
        // earning Rp 10jt saw Rp 25,75jt here and was told the whole lot was
        // safe to spend. A one-off payment is not a monthly income, and an
        // allocation plan is a statement about a repeatable month.
        //
        // `thisMonthIncome` still drives the no-schedule fallback above, where
        // logged income is the only signal available.
        return scheduled
    }

    private var monthlyExpenses: Double {
        let allTx = scopedTx
        let cal = Calendar.current
        let now = Date()
        let pref = CurrencyManager.shared.preferredCurrency
        // Exclude debt payments — they are already factored into safeSpendingBudget
        // via recommendedMonthlyDebtPayment, so including them would double-count
        // The PAY CYCLE, not the calendar month.
        //
        // Everything else on this screen — the budget, the ratios, the health
        // score — is measured per pay cycle. This one filtered by calendar
        // month, so for a payday on the 25th it summed parts of TWO cycles and
        // compared that against one cycle's budget. On this user's data that
        // read Rp 25,4jt of "monthly" spending against a Rp 6,3jt allowance and
        // announced Rp 19,1jt of overspending, for a cycle that actually
        // finished Rp 748k ahead.
        let cycleStart: Date = {
            guard let day = MainCard.payDay(salaries) else {
                return cal.safeDate(from: cal.dateComponents([.year, .month], from: now))
            }
            return StatPeriod.cycle(payDay: day,
                                    salaryDates: StatPeriod.salaryDates(on: MainCard.resolve(in: cards))).start
        }()
        return FinancialHealthEngine.planSpending(allTx, from: cycleStart, currency: pref)
    }
    
    /// Total cash on hand right now across all cards, in preferred currency.
    /// Used as a fallback context: if recommended debt payment exceeds this
    /// month's salary, the user needs to know whether they can cover it from
    /// existing balance — paying debt isn't only a salary game.
    private var totalBalance: Double {
        let pref = CurrencyManager.shared.preferredCurrency
        return cards.reduce(0) { sum, card in
            sum + CurrencyManager.shared.convert(card.balance, from: card.resolvedCurrency, to: pref)
        }
    }

    /// Declared recurring outgoings — the same set the obligation card counts.
    private var monthlyCommitments: Double {
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        return recurrings.filter(\.isActive).reduce(0.0) {
            $0 + cm.convert($1.amount, from: $1.currency, to: pref)
        }
    }

    /// The Invest & Debt ratio actually in force — the card's override when it
    /// has one, the global setting otherwise.
    private var liveInvestDebtRatio: Double {
        SmartBudgetManager.shared.ratio(for: .investDebt,
                                        cardID: SmartBudgetManager.shared.budgetCardID,
                                        configs: budgetConfigs)
    }

    /// Non-salary income received in the current cycle.
    private var extraIncomeThisCycle: Double {
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        guard let day = MainCard.payDay(salaries) else { return 0 }
        let start = StatPeriod.cycle(payDay: day,
                                     salaryDates: StatPeriod.salaryDates(on: MainCard.resolve(in: cards))).start
        return scopedTx
            .filter { $0.date >= start && $0.amount > 0 && $0.txSubtype != .transfer
                      && $0.category != .salary
                      && $0.category != .investment && $0.category != .debtPayment }
            .reduce(0.0) { $0 + cm.convert($1.amount, from: $1.currency.isEmpty ? pref : $1.currency, to: pref) }
    }

    /// A credit-card debt recorded by hand is the same balance the card
    /// already carries; counting both would double it. Same rule as
    /// `ObligationLoad.cardPayments`.
    private var cardDebtRecorded: Bool {
        debts.contains { $0.isActive && !$0.manuallyClosed && $0.type == DebtType.creditCard.rawValue }
    }

    /// What the credit cards are owed, in the preferred currency.
    private var cardOwed: Double {
        guard !cardDebtRecorded else { return 0 }
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        return creditCards.reduce(0.0) { $0 + cm.convert($1.totalOwed(installments), from: $1.resolvedCurrency, to: pref) }
    }

    private var engine: FinancialHealthEngine {
        var e = FinancialHealthEngine(monthlyIncome: monthlyIncome,
                                      debts: debts,
                                      monthlyExpenses: monthlyExpenses,
                                      fixedCommitments: monthlyCommitments,
                                      investDebtRatio: liveInvestDebtRatio,
                                      extraIncomeThisCycle: extraIncomeThisCycle)
        e.cardOwed = cardOwed
        e.cardMonthly = ObligationLoad.cardPayments(cards: cards, installments: installments, debts: debts,
                                                    currency: CurrencyManager.shared.preferredCurrency)
        return e
    }
    
    /// Recomputes each debt's `currentBalance` from its linked payment transactions.
    /// This is the rollback mechanism: when the user deletes a debt-payment tx from
    /// Home (or anywhere else), the debt's stored balance no longer matches reality.
    /// Calling this on appear / on tx-count-change brings them back in sync.
    ///
    /// Note: only debts that have at least one linked tx ever recorded against them
    /// are touched — debts with no linked txs (e.g. created before this feature, or
    /// with payments made through other channels) keep their manually-entered balance.
    private func syncDebtBalances() {
        let linkedDebtIDs = Set(allTransactions.compactMap { $0.linkedDebtID.isEmpty ? nil : $0.linkedDebtID })
        var didChange = false
        for debt in debts {
            // User explicitly closed this debt via "Mark as paid" — don't let
            // tx-derived recompute resurrect it.
            if debt.manuallyClosed { continue }
            let hasLinkedTx = linkedDebtIDs.contains(debt.id.uuidString)
            // Only sync if debt has linked txs OR has previously been synced.
            // hasBeenTracked flag prevents accidentally overwriting manual edits.
            guard hasLinkedTx || debt.hasBeenTracked else { continue }
            
            let trueBalance = debt.effectiveBalance(from: allTransactions)
            if abs(debt.currentBalance - trueBalance) > 0.01 {
                debt.currentBalance = trueBalance
                // Re-activate if user deleted a payment that had marked it paid
                if trueBalance > 0 && !debt.isActive {
                    debt.isActive = true
                }
                didChange = true
            }
            if hasLinkedTx && !debt.hasBeenTracked {
                debt.hasBeenTracked = true
                didChange = true
            }
        }
        if didChange { try? context.save() }
    }

    var body: some View {
        // Self-gate, like Wishlist and Smart Budget settings. Today every entry
        // point happens to be blocked (the Profile row is a
        // PremiumLockedFeatureLink, and the Home insight that routes here only
        // exists when `hasActiveBudget` is true), but a screen that relies
        // entirely on its callers to protect it is one new navigation path away
        // from leaking. It also covers a subscription lapsing while the sheet
        // is already open.
        PremiumGate(feature: .smartDebt) {
            debtContent
        }
        .trackScreen(.debts)
    }

    private var activeDebts: [DebtRecord] { debts.filter(\.isActive) }

    /// When the last active debt is paid off at its minimum — nil when any of
    /// them never would be (a payment below its interest).
    private var debtFreeDate: Date? {
        let dates = activeDebts.compactMap(\.payoffDate)
        guard !dates.isEmpty, dates.count == activeDebts.count else { return nil }
        return dates.max()
    }

    // The screen reads top to bottom as: how much do I owe and is it OK, what
    // is due now, each debt, which to pay first, and where the salary goes.
    // It opened on a score out of 100, a four-way allocation, a warning, an
    // urgent list and then the debts — five verdicts before the thing itself.
    private var debtContent: some View {
        ZStack { AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    // A card balance alone is enough to show the summary.
                    if debts.isEmpty && cardOwed < 0.5 {
                        DebtEmptyState(vm: vm)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    } else {
                        DebtSummaryCard(engine: engine,
                                        monthlyIncome: monthlyIncome,
                                        cardOwed: cardOwed,
                                        debtFreeDate: debtFreeDate,
                                        showSimulator: !embedded && !activeDebts.isEmpty,
                                        onAdd: { HapticManager.shared.tap(); vm.resetForm(); vm.showAddSheet = true },
                                        onSimulate: { HapticManager.shared.tap(); simulatorDebt = activeDebts.first })

                        if engine.isOverspending {
                            InlineBanner(tone: .warning,
                                         message: String(format: loc(engine.hasAnyDebt ? "debt.reduce_expenses"
                                                                                       : "debt.reduce_spending_plan"),
                                                         CurrencyManager.shared.formatted(engine.overspendAmount,
                                                                                          currency: CurrencyManager.shared.preferredCurrency)))
                        }

                        if !engine.urgentDebts.isEmpty {
                            DueSoonCard(debts: engine.urgentDebts) { payingDebt = $0 }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(loc("debt.your_debts"))
                                    .font(.system(.body, weight: .bold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                Text(String(format: loc("debt.active_count"), activeDebts.count))
                                    .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                            }
                            ForEach(Array(engine.avalancheOrder.prefix(debtPreviewLimit).enumerated()), id: \.element.id) { i, debt in
                                DebtCard(debt: debt, priority: i + 1,
                                         payFirst: i == 0 && activeDebts.count > 1, vm: vm)
                            }
                            if engine.avalancheOrder.count > debtPreviewLimit {
                                Button { HapticManager.shared.tap(); showAllDebts = true } label: {
                                    SeeAllLabel(count: engine.avalancheOrder.count)
                                }
                                .buttonStyle(ScaleButtonStyle())
                            }
                        }

                        if activeDebts.count > 1 {
                            PayoffStrategyCard(engine: engine)
                        }

                        // Everything below needs an income to be measured against.
                        if monthlyIncome > 0 {
                            AllocationCard(engine: engine, monthlyIncome: monthlyIncome, totalBalance: totalBalance)
                        } else if !activeDebts.isEmpty {
                            SalarySetupCTA(message: loc("salary.cta.debt")) { showSalarySetup = true }
                        }
                    }

                    // Credit cards show regardless — someone may track only a card.
                    creditCardSection
                        .padding(.top, 6)

                    Spacer(minLength: 120)
                }
                .padding(.horizontal, 22)
                .padding(.top, embedded ? 4 : 20)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)
                .animation(AppMotion.appear, value: appeared)
                .containerRelativeFrame(.horizontal)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { appeared = true }
            DebtNotificationScheduler.scheduleAll(debts: debts)
            // Sync each debt's stored currentBalance against the actual linked
            // payment txs in the DB. This catches the case where a user deleted
            // a payment tx from Home — without this sync the debt would still
            // show "paid off" progress that no longer matches reality.
            syncDebtBalances()
        }
        .onChange(of: debts) { _, newDebts in
            // Reschedule notifications whenever debts change
            DebtNotificationScheduler.scheduleAll(debts: newDebts)
        }
        .onChange(of: allTransactions.count) { _, _ in
            // Any tx added or deleted ANYWHERE (Home, detail sheets, etc) →
            // re-sync debt balances so progress stays in lockstep with the DB.
            // This is the rollback hook for "user deleted a debt-payment tx".
            syncDebtBalances()
        }
        .sheet(isPresented: $vm.showAddSheet, onDismiss: { vm.resetForm() }) {
            DebtFormSheet(vm: vm)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .sheet(item: $payingDebt) { debt in
            DebtPaymentSheet(debt: debt)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(item: $simulatorDebt) { debt in
            PayoffSimulatorSheet(debt: debt, allDebts: debts.filter { $0.isActive }, income: monthlyIncome)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .sheet(isPresented: $showSalarySetup) {
            SalaryView()
                .environment(\.pushedFeature, false)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showAllDebts) {
            AllDebtsView(order: engine.avalancheOrder, vm: vm)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showAddCreditCard) {
            CreditCardFormSheet(editCard: nil)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .sheet(item: $editingCreditCard) { card in
            CreditCardFormSheet(editCard: card)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .sheet(item: $payingCard) { card in
            CreditCardPaymentSheet(creditCard: card, cards: cards, context: context)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .confirmSheet(item: $deletingCard,
                      icon: "creditcard.fill",
                      title: { _ in loc("cc.delete_title") },
                      message: { _ in loc("cc.delete_msg") },
                      confirmLabel: loc("action.delete")) { c in
            // Installments belong to the card; orphaning them would leave
            // phantom principal locking a limit that no longer exists.
            for inst in installments where inst.cardID == c.id { context.delete(inst) }
            context.delete(c)
            try? context.save()
        }
        .sheet(item: $logSpendCard) { card in
            // Cross-link: log a purchase on THIS credit card. Lock the card —
            // the flow is "spend on this card", so swiping to another would log
            // the purchase on the wrong account.
            AddTransactionSheet(vm: txViewModel(), preselectedCardID: card.id,
                                lockToPreselectedCard: true)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
    }

    /// Lightweight AppViewModel carrying the live card list into the add-tx form.
    private func txViewModel() -> AppViewModel {
        let vm = AppViewModel()
        vm.cards = cards
        return vm
    }

    // MARK: - Credit Cards Section

    @ViewBuilder private var creditCardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(loc("cc.section_title")).font(.system(.body, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Button { HapticManager.shared.tap(); showAddCreditCard = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(.caption, weight: .bold))
                        Text(loc("cc.add")).font(.system(.footnote, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(AppTheme.cardDark, in: Capsule())
                }.buttonStyle(ScaleButtonStyle())
            }

            if creditCards.isEmpty {
                Text(loc("cc.section_empty"))
                    .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(creditCards) { card in
                    VStack(spacing: 10) {
                        CreditCardLiabilityRow(card: card,
                                               installments: installments,
                                               onEdit: { editingCreditCard = card },
                                               onLogSpend: { logSpendCard = card },
                                               onPay: { payingCard = card },
                                               onDelete: { deletingCard = card })
                        // Right under the card, so a purchase just logged is
                        // the first thing below what it changed.
                        CardHistorySection(card: card)
                        InstallmentSection(card: card, installments: installments, context: context)
                    }
                }
            }
        }
    }
}
