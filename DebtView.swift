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
    @State private var simulatorDebt: DebtRecord? = nil
    @State private var showSalarySetup = false
    @State private var showAllDebts = false
    @State private var showAddCreditCard = false
    /// A credit card's own page: spending, its bill, history, instalments.
    @State private var openCard: BankCard? = nil
    @State private var payingDebt: DebtRecord? = nil
    @State private var showOwedBack = false
    @State private var showAnalysis = false
    @State private var showAdvice = false
    /// Which debt goes first: 0 highest interest, 1 smallest balance. Kept
    /// on this device, like other choices about one screen; it sets the
    /// pay-first box and the order of the rows.
    @AppStorage("debt_payoff_strategy") private var strategy = 0
    @Query private var installments: [CardInstallment]
    @Query private var recurrings: [RecurringExpense]
    @Query private var receivables: [Receivable]
    @Query private var goals: [SavingsGoal]
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

    /// Monthly income in the preferred currency — the income Smart Budget
    /// budgets, which its savings & debt share is a share of. Whether a usual
    /// month carries the payments is weighed on the Financial ladder's
    /// figures instead (see `affordability`).
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
    /// Read from the main card.
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
                                      investDebtRatio: liveInvestDebtRatio)
        e.cardOwed = cardOwed
        e.cardCarried = cardDebtRecorded ? 0
            : ObligationLoad.cardCarried(cards: cards, currency: CurrencyManager.shared.preferredCurrency)
        e.cardMonthly = ObligationLoad.cardPayments(cards: cards, installments: installments, debts: debts,
                                                    currency: CurrencyManager.shared.preferredCurrency)
        return e
    }

    /// What others still owe the user, in the preferred currency.
    private var owedToYou: Double {
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        return receivables.filter { !$0.isSettled }.reduce(0.0) {
            $0 + cm.convert($1.outstanding(from: allTransactions), from: $1.currency, to: pref)
        }
    }

    /// What the money owed back would clear if it came back and went where
    /// Smart Budget says, and what the month would look like then.
    private func owedBack(_ e: FinancialHealthEngine, _ reading: DebtAffordability) -> OwedBackPlan? {
        let costly = OwedBackPlan.costly(debts: debts, cards: cards, currency: CurrencyManager.shared.preferredCurrency)
        return OwedBackPlan.make(owedBack: owedToYou, costly: costly, totalDebt: e.totalDebt, reading: reading)
    }

    /// Smart Budget's advice, told how a usual month really goes and what is
    /// owed back.
    private func advice(_ e: FinancialHealthEngine, _ reading: DebtAffordability) -> DebtFirstAdvice {
        var a = e.debtFirst
        a.monthLeft = reading.verdict == nil ? nil : reading.left
        a.owedToYou = owedToYou
        return a
    }

    /// The figures DiPo AI's debt analysis is written from — the ones this
    /// screen shows, computed the same way.
    private func analysisSnapshot(_ e: FinancialHealthEngine, _ reading: DebtAffordability) -> String {
        let sb = SmartBudgetManager.shared
        return DebtAnalysisSnapshot.build(.init(
            cards: cards, installments: installments, debts: debts, receivables: receivables,
            salaries: salaries, recurrings: recurrings, goals: goals,
            reading: reading, advice: advice(e, reading),
            budget: sb.ratios(forCardID: sb.budgetCardID, configs: budgetConfigs),
            currency: CurrencyManager.shared.preferredCurrency))
    }

    /// Whether a usual month carries `e`'s payments. Read from the Financial
    /// ladder's figures — every account, the income that keeps coming, the
    /// median of the last complete months — so the two screens agree, and
    /// never from how this pay period is going, which is Statistics' question.
    private func affordability(_ e: FinancialHealthEngine) -> DebtAffordability {
        DebtAffordability.usualMonth(cards: cards, debts: debts, salaries: salaries, installments: installments,
                                     commitments: monthlyCommitments, payments: e.totalEffectiveMinimums,
                                     hasDebt: e.hasAnyDebt, currency: CurrencyManager.shared.preferredCurrency)
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

    /// The active debts in the chosen payoff order.
    private func order(_ e: FinancialHealthEngine) -> [DebtRecord] {
        strategy == 1 ? e.snowballOrder : e.avalancheOrder
    }

    /// Debts with a payment recorded this month.
    private var paidThisMonth: Set<String> { DebtDue.paidThisMonth(allTransactions) }

    // The page reads top to bottom as: how much do I owe and can a usual
    // month carry it; which debt to pay first, with the page's one green
    // button; the other debts; the credit cards; then the tools, one row
    // each. It was a stack of cards with six green buttons: a summary with
    // icon tiles and a tinted verdict, "Due soon" with a Pay per row, a card
    // per debt with its own Pay, the payoff order, Smart Budget, the analysis,
    // and each credit card with its history and instalments underneath.
    private var debtContent: some View {
        ZStack { AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                // Worked out once a pass: each reads every account's history.
                let e = engine
                let reading = affordability(e)
                VStack(alignment: .leading, spacing: 0) {
                    // A card balance alone is enough to show the total.
                    if debts.isEmpty && cardOwed < 0.5 {
                        DebtEmptyState(vm: vm)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    } else {
                        DebtTotalHeader(engine: e,
                                        affordability: reading,
                                        cardOwed: cardOwed,
                                        debtFreeDate: debtFreeDate,
                                        onAdd: { HapticManager.shared.tap(); vm.resetForm(); vm.showAddSheet = true })
                        debtsSection(e)
                    }

                    // Credit cards show regardless — someone may track only a card.
                    creditCardSection
                        .padding(.top, 26)

                    if !(debts.isEmpty && cardOwed < 0.5) {
                        toolsSection(e, reading: reading)
                            .padding(.top, 18)
                    }

                    Spacer(minLength: 120)
                }
                .padding(.horizontal, 22)
                .padding(.top, embedded ? 8 : 20)
                .containerRelativeFrame(.horizontal)
            }
        }
        .onAppear {
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
            AllDebtsView(order: order(engine), paid: paidThisMonth, vm: vm)
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
        .sheet(item: $openCard) { card in
            CreditCardDetailSheet(card: card, installments: installments, cards: cards)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
    }

    // MARK: - Debts

    /// The pay-first box, then the other debts as rows under the payoff order.
    @ViewBuilder
    private func debtsSection(_ e: FinancialHealthEngine) -> some View {
        let ordered = order(e)
        let paid = paidThisMonth
        if let first = DebtPayFirst.pick(ordered, due: { DebtDue.of($0, paid: paid) }) {
            let due = DebtDue.of(first, paid: paid)
            DebtPayFirstBox(debt: first, due: due,
                            reason: DebtPayFirst.reason(first, due: due, byInterest: strategy == 0,
                                                        count: ordered.count),
                            vm: vm,
                            onPay: { payingDebt = first })
                .padding(.top, 20)

            let rest = ordered.filter { $0.id != first.id }
            if !rest.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(loc("debt.other_debts"))
                            .font(.system(.body, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                        Text(verbatim: "\(rest.count)")
                            .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                    }
                    DebtStrategyPicker(strategy: $strategy)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    ForEach(Array(rest.prefix(debtPreviewLimit).enumerated()), id: \.element.id) { i, debt in
                        if i > 0 { DebtHairline() }
                        DebtRow(debt: debt, due: DebtDue.of(debt, paid: paid), vm: vm)
                    }
                    if rest.count > debtPreviewLimit {
                        DebtHairline()
                        DebtLinkRow(icon: "list.bullet", title: String(format: loc("savings.see_all"), ordered.count)) {
                            showAllDebts = true
                        }
                    }
                }
                .padding(.top, 26)
            }
        }
    }

    // MARK: - Tools

    /// One row each: what the money owed back would clear, the analysis,
    /// the payoff simulator and Smart Budget's advice. Each opens its own page.
    @ViewBuilder
    private func toolsSection(_ e: FinancialHealthEngine, reading: DebtAffordability) -> some View {
        let plan = owedBack(e, reading)
        let rows = toolRows(e, reading: reading, plan: plan)
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    DebtHairline()
                    row
                }
            }
            .sheet(isPresented: $showOwedBack) {
                if let plan {
                    DebtToolSheet(title: loc("debt.owed_back.nav")) { OwedBackBlock(plan: plan) }
                }
            }
            .sheet(isPresented: $showAnalysis) {
                DebtToolSheet(title: loc("analysis.title")) {
                    DebtAnalysisCard { analysisSnapshot(e, reading) }
                }
            }
            .sheet(isPresented: $showAdvice) {
                DebtToolSheet(title: loc("debt.first.header")) {
                    DebtFirstCard(advice: advice(e, reading))
                }
            }
        }
    }

    private func toolRows(_ e: FinancialHealthEngine, reading: DebtAffordability,
                          plan: OwedBackPlan?) -> [DebtLinkRow] {
        let money = { (v: Double) in
            CurrencyManager.shared.formatted(v, currency: CurrencyManager.shared.preferredCurrency)
        }
        var rows: [DebtLinkRow] = []
        if let plan {
            let cleared = plan.payoffs.filter(\.cleared).map(\.debt.name)
            rows.append(DebtLinkRow(
                icon: "arrow.uturn.backward", tint: AppTheme.accent,
                title: String(format: loc("debt.owed_back.title"), money(plan.owedBack)),
                detail: cleared.isEmpty ? nil
                    : String(format: loc("debt.owed_back.clears"), cleared.joined(separator: ", ")),
                action: { showOwedBack = true }))
        }
        if monthlyIncome > 0 && e.hasAnyDebt {
            rows.append(DebtLinkRow(icon: "sparkles", tint: AppTheme.accent,
                                    title: loc("analysis.title"), detail: loc("analysis.sub"),
                                    action: { showAnalysis = true }))
        }
        if !embedded && !activeDebts.isEmpty {
            rows.append(DebtLinkRow(icon: "chart.line.uptrend.xyaxis", title: loc("debt.simulate_row"),
                                    action: { simulatorDebt = activeDebts.first }))
        }
        if monthlyIncome > 0 && e.hasAnyDebt {
            rows.append(DebtLinkRow(icon: "lightbulb", tint: AppTheme.orange,
                                    title: loc("debt.first.header"), detail: advice(e, reading).title(),
                                    action: { showAdvice = true }))
        } else if monthlyIncome <= 0 && !activeDebts.isEmpty {
            rows.append(DebtLinkRow(icon: "banknote", tint: AppTheme.blue,
                                    title: loc("salary.cta.title"), detail: loc("salary.cta.debt"),
                                    action: { showSalarySetup = true }))
        }
        return rows
    }

    // MARK: - Credit Cards Section

    @ViewBuilder private var creditCardSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text(loc("cc.section_title")).font(.system(.body, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Button { HapticManager.shared.tap(); showAddCreditCard = true } label: {
                    Image(systemName: "plus")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(width: 40, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel(loc("cc.add"))
            }

            if creditCards.isEmpty {
                Text(loc("cc.section_empty"))
                    .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } else {
                ForEach(Array(creditCards.enumerated()), id: \.element.id) { i, card in
                    if i > 0 { DebtHairline() }
                    CreditCardPlainRow(card: card, installments: installments) { openCard = card }
                }
            }
        }
    }
}
