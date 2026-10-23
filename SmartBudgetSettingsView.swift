import SwiftUI
import SwiftData


// MARK: - Smart Budget Settings Sheet

struct SmartBudgetSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @Query(sort: \SalarySchedule.createdAt) private var schedules: [SalarySchedule]
    @Query private var cardConfigs: [CardBudgetConfig]
    @Query private var recurringPlans: [RecurringExpense]

    @State private var isEnabled    = SmartBudgetManager.shared.isEnabled
    @State private var dailyPct     = Self.pct(SmartBudgetManager.shared.dailyRatio)
    @State private var lifestylePct = Self.pct(SmartBudgetManager.shared.lifestyleRatio)
    @State private var investPct    = Self.pct(SmartBudgetManager.shared.investDebtRatio)
    @State private var selectedTab  = BudgetTab.overview
    @State private var selectedCardID: String? = nil
    /// When true, edits in Settings tab apply to the selected card only.
    /// When false, edits go to global defaults (used when no card is selected
    /// or when the user explicitly chooses "Default for all cards").
    @State private var editingPerCard: Bool = false
    @State private var showSalarySetup = false
    @State private var showRecommendation = false
    /// The preset the user explicitly tapped. Tracked by identity (not by
    /// ratios) so that two presets sharing the same split — e.g. Student Saver
    /// and Mortgage Payer are both 50/20/30 — never light up together. nil
    /// means "no preset is the active choice" (custom/manual ratios).
    @State private var selectedPreset: BudgetProfile? = nil
    /// Daily rollup buckets, read instead of scanning every transaction. Seeded
    /// from the shared store on appear and refreshed when the ledger changes, so
    /// a body evaluation never rebuilds (which would mutate the store mid-render).
    @State private var rollupBuckets: [DailyBucket] = []

    enum BudgetTab: String, CaseIterable {
        case overview, settings, simulate
        /// Was rendered straight from `rawValue`, so these two tab labels stayed
        /// English no matter which language the app was in.
        var titleKey: String {
            switch self {
            case .overview: return "budget.tab_overview"
            case .settings: return "budget.tab_settings"
            case .simulate: return "budget.tab_simulate"
            }
        }
    }

    /// Ratio (0…1) to whole percent. Both the editor's initial load and the
    /// baseline it is later compared against MUST use this — when one rounded
    /// and the other truncated, a stored 0.29 read back as 29 here and 28
    /// there, so Save lit up on a screen the user had not touched.
    private static func pct(_ ratio: Double) -> Int { Int((ratio * 100).rounded()) }

    private var totalPct: Int { dailyPct + lifestylePct + investPct }
    private var isBalanced: Bool { totalPct == 100 }
    
    /// Existing per-card config for the currently selected card (nil if none yet).
    private var selectedCardConfig: CardBudgetConfig? {
        guard let id = selectedCardID else { return nil }
        return cardConfigs.first(where: { $0.cardID == id })
    }
    
    /// What the ratios *should* be after saving — either per-card config or global.
    private var currentBaselineRatios: (daily: Int, lifestyle: Int, investDebt: Int) {
        if editingPerCard, let cfg = selectedCardConfig {
            return (Self.pct(cfg.dailyRatio),
                    Self.pct(cfg.lifestyleRatio),
                    Self.pct(cfg.investDebtRatio))
        }
        return (Self.pct(SmartBudgetManager.shared.dailyRatio),
                Self.pct(SmartBudgetManager.shared.lifestyleRatio),
                Self.pct(SmartBudgetManager.shared.investDebtRatio))
    }

    private var hasChanges: Bool {
        if isEnabled != SmartBudgetManager.shared.isEnabled { return true }
        // Choosing a specific card with no override yet is itself a change:
        // the user is explicitly pinning this card's budget so it stops
        // following the global default. This must be savable even when the
        // ratios happen to equal the current global default — otherwise the
        // card silently keeps inheriting global and "can't be saved".
        if editingPerCard, selectedCardID != nil, selectedCardConfig == nil { return true }
        let baseline = currentBaselineRatios
        return dailyPct != baseline.daily ||
               lifestylePct != baseline.lifestyle ||
               investPct != baseline.investDebt
    }

    private var canSave: Bool {
        guard hasChanges else { return false }
        return isEnabled ? isBalanced : true
    }

    private var cardCurrency: String {
        selectedCard?.resolvedCurrency ?? CurrencyManager.shared.preferredCurrency
    }

    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v.rounded(), currency: cardCurrency)
    }

    /// True when income is derived from transactions rather than a salary schedule
    private var incomeIsFromTransactions: Bool { !income.fromSchedule }

    /// Income plus the money in the person chose to add to this period.
    private var monthlyIncome: Double { statedIncome + extraFunds }

    /// Money in that isn't income but was added to this period's budget —
    /// the main card's pot only, and only rows the person switched on.
    private var extraFunds: Double {
        guard budgetCardIDs != nil else { return 0 }
        return ExtraFunds.total(in: budgetTx, from: periodStart, to: periodEnd, currency: cardCurrency)
    }

    /// The salary landing on the main card, or the income logged this period
    /// when there is none — `MainCard.budgetIncome`, the rule Home, the
    /// purchase warning and the alerts use. Zero hides the amounts and asks
    /// for income instead.
    private var income: (amount: Double, fromSchedule: Bool) {
        MainCard.budgetIncome(schedules: schedules, transactions: budgetTx,
                              from: periodStart, to: periodEnd, currency: cardCurrency)
    }

    private var statedIncome: Double { income.amount }

    /// Transactions filtered to the selected main card (or all cards if nil)
    private var budgetTx: [TxRecord] {
        if let id = selectedCardID, let card = cards.first(where: { $0.id.uuidString == id }) {
            // The main card brings the cards it pays bills from, and what was
            // bought on a credit card (MainCard.creditCardSpending).
            return MainCard.isMain(card) ? MainCard.budgetSpendingTransactions(in: cards) : card.transactions
        }
        return cards.flatMap { $0.transactions }
    }

    /// The cards the rollup is read over: the main card, its bill cards and
    /// the credit cards whose purchases count here. nil for any other card,
    /// which is read on its own.
    private var budgetCardIDs: Set<String>? {
        guard let id = selectedCardID, id == MainCard.id else { return nil }
        return MainCard.budgetSpendingCardIDs(in: cards)
    }

    /// The first active monthly bill charged to a card this budget does not
    /// count — kos paid from BCA while the budget reads BRI. Offered as a
    /// one-tap fix rather than left as a silent gap.
    private var billOutside: (plan: RecurringExpense, card: BankCard)? {
        guard MainCard.resolve(in: cards) != nil else { return nil }
        let eligible = MainCard.billEligible(cards)
        for plan in recurringPlans.filter(\.isActive).sorted(by: { $0.amount > $1.amount }) {
            guard let id = plan.cardID, let card = eligible.first(where: { $0.id == id }),
                  !MainCard.isBillCard(card) else { continue }
            return (plan, card)
        }
        return nil
    }

    /// Monthly expenses due before the period ends and not recorded yet, on
    /// the cards this budget reads. Each group takes its share out of what it
    /// has left, so payday no longer shows money that kos and the transfer
    /// home have already claimed.
    private var scheduled: [ScheduledBill] {
        guard let id = selectedCardID else { return [] }
        return ScheduledBills.upcoming(plans: recurringPlans, cards: cards,
                                       cardIDs: budgetCardIDs ?? [id],
                                       periodStart: periodStart, periodEnd: periodEnd,
                                       currency: cardCurrency)
    }

    /// Monthly expenses that read like an investment but are filed where they
    /// count as spending — offered a move on the Savings & debt screen.
    private var misfiledInvestments: [RecurringExpense] {
        guard let id = selectedCardID else { return [] }
        return ScheduledBills.looksLikeInvestment(recurringPlans, cardIDs: budgetCardIDs ?? [id])
    }

    /// Selected card object for display
    private var selectedCard: BankCard? {
        guard let id = selectedCardID else { return nil }
        return cards.first(where: { $0.id.uuidString == id })
    }

    /// Day-of-month the salary lands on. Anchors the budget period to the pay
    /// cycle — the payday Home, Statistics and the alerts anchor on, so the
    /// period here is theirs. Picking among schedules linked to this card by id
    /// first could anchor on a different salary from the one Home used.
    private var payCycleDay: Int? { MainCard.payDay(schedules) }

    /// Whether spending is measured over the pay cycle (a salary schedule exists).
    private var usesPayCycle: Bool { payCycleDay != nil }

    /// Start of the budget period. With a salary schedule, spending is measured
    /// over the PAY CYCLE (payday → today) instead of the calendar month — so
    /// "spent vs budget" reflects the actual salary period. This matters when
    /// payday is late in the month (e.g. the 25th): early in the new calendar
    /// month almost nothing is "spent yet", which understated usage badly.
    /// Falls back to the 1st of the month when there's no schedule.
    private var periodStart: Date {
        if let c = cycle { return c.start }
        let cal = Calendar.current
        return cal.safeDate(from: cal.dateComponents([.year, .month], from: Date()))
    }

    /// The running pay cycle — opened on the day the salary landed and closed
    /// at the next payday — the same window Statistics and Home measure.
    private var cycle: (start: Date, end: Date)? {
        guard let day = payCycleDay else { return nil }
        return StatPeriod.cycle(payDay: day, salaryDates: StatPeriod.salaryDates(on: selectedCard))
    }

    /// Where the budget window ends: the next payday, or the 1st of next month.
    private var periodEnd: Date {
        cycle?.end ?? Calendar.current.safeDate(byAdding: .month, value: 1, to: periodStart)
    }

    /// The whole budget window, payday to the day before the next one. It
    /// used to end at today ("Sep 25 – Oct 6"), which read as a short period
    /// that had already ended.
    private var periodLabel: String {
        if let c = cycle {
            let f = DateFormatter()
            f.locale = LanguageManager.shared.currentLocale
            f.dateFormat = DateFormatter.dateFormat(fromTemplate: "dMMM", options: 0, locale: f.locale)
            let lastDay = Calendar.current.safeDate(byAdding: .day, value: -1, to: c.end)
            return "\(f.string(from: c.start)) – \(f.string(from: lastDay))"
        }
        return Date().formatted(.dateTime.month(.wide).year())
    }

    /// "Day 12 of 28" while the window runs.
    private var periodDayLine: String? {
        let d = StatPeriod.cycleDay((periodStart, periodEnd))
        return String(format: loc("stats.day_of"), d.day, d.of)
    }

    /// Total transactions across cards — the cheap change-signal that tells the
    /// rollup cache whether it must recompute (mirrors StatisticsView.statTxCount).
    private var totalTxCount: Int { cards.reduce(0) { $0 + $1.transactions.count } }

    // ── Bills paid from other cards ──────────────────────────────────────
    //
    // Someone who pays kos from BCA and tops BCA up from the main card each
    // month spends the main card's money there — but the budget read only the
    // main card, so the kos was in no budget at all, and an over-generous
    // top-up was in none either. Picking BCA here reads both cards as one pot:
    // what is spent on either counts, and what moves between them does not.
    @ViewBuilder
    private var billCardsSection: some View {
        let eligible = MainCard.billEligible(cards)
        if !eligible.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(loc("budget.bill_cards_title"))
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(.horizontal, 22)
                Text(loc("budget.bill_cards_hint"))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22)
                CardChipPicker(cards: eligible,
                               isSelected: { MainCard.isBillCard($0) },
                               onSelect: { card in
                                   MainCard.setBillCard(card, !MainCard.isBillCard(card))
                                   LedgerRevision.shared.bump()
                               })
                if let gap = billOutside {
                    let money = CurrencyManager.shared.formatted(gap.plan.amount, currency: gap.plan.currency)
                    VStack(alignment: .leading, spacing: 8) {
                        Label(String(format: loc("budget.bill_outside"),
                                     gap.plan.label, money, gap.card.pickerLabel),
                              systemImage: "info.circle.fill")
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(AppTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            HapticManager.shared.tap()
                            MainCard.setBillCard(gap.card, true)
                            LedgerRevision.shared.bump()
                        } label: {
                            Text(String(format: loc("budget.bill_outside_add"), gap.card.pickerLabel))
                                .font(.system(.caption, weight: .bold))
                                .foregroundStyle(AppTheme.onVividFill)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(AppTheme.accentFill, in: Capsule())
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.md))
                    .padding(.horizontal, 22)
                }
            }
            .padding(.bottom, 6)
        }
    }

    /// Refresh the local buckets from the shared store, recomputing only when the
    /// ledger changed. Called from lifecycle hooks, never from a body read.
    private func refreshRollup() {
        rollupBuckets = RollupStore.shared.rebuildIfStale(context: context, txCount: totalTxCount)
    }

    /// What each group has taken this period, refunds given back — the rule
    /// Statistics uses. Statistics counts the pot's cash, so purchases on a
    /// credit card are here and not there until the bill is paid.
    private func groupSpent(_ grp: BudgetGroup) -> Double {
        SmartBudgetManager.shared.spent(in: grp, buckets: rollupBuckets,
                                        targetCurrency: cardCurrency,
                                        periodStart: periodStart,
                                        cardID: selectedCardID,
                                        cardIDs: budgetCardIDs)
    }

    // Groups past their LIMIT. Only Needs and Wants have one: Savings & debt is
    // a target to reach, and going past it is the point, not a warning.
    private var overGroups: [(group: BudgetGroup, spent: Double, limit: Double, ratio: Double)] {
        guard monthlyIncome > 0 else { return [] }
        let r = SmartBudgetManager.shared.ratios(forCardID: selectedCardID, configs: cardConfigs)
        return BudgetGroup.allCases.filter(\.isCeiling).compactMap { grp in
            let s = groupSpent(grp)
            let ratio: Double = {
                switch grp {
                case .daily:      return r.daily
                case .lifestyle:  return r.lifestyle
                case .investDebt: return r.investDebt
                }
            }()
            let l = monthlyIncome * ratio
            guard s > l else { return nil }
            return (grp, s, l, ratio)
        }
    }

    /// Savings & debt once it has reached its target: worth saying, in green.
    private var investAhead: (spent: Double, ratio: Double)? {
        guard monthlyIncome > 0 else { return nil }
        let ratio = SmartBudgetManager.shared.ratio(for: .investDebt, cardID: selectedCardID, configs: cardConfigs)
        let s = groupSpent(.investDebt)
        guard ratio > 0, s >= monthlyIncome * ratio else { return nil }
        return (s, ratio)
    }

    var body: some View {
        PremiumGate(feature: .smartBudget) {
        FeatureStack { pushed in
            ZStack { AppTheme.bg.ignoresSafeArea()
                VStack(spacing: 0) {

                    // Master toggle
                    HStack(spacing: 14) {
                        // The app's green, like every other on/off feature. A
                        // purple brain made this read as a separate AI product
                        // bolted on, not DiPo's own budget.
                        Image(systemName: "chart.pie.fill")
                            .font(.system(.title3, weight: .semibold))
                            .foregroundStyle(isEnabled ? AppTheme.onVividFill : AppTheme.textSecondary)
                            .frame(width: 46, height: 46)
                            .background(isEnabled ? AppTheme.accentFill : AppTheme.cardMid,
                                        in: RoundedRectangle(cornerRadius: AppRadius.sm))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc("profile.budget")).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                            Text(loc("budget.sub")).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        DiPoSwitch(isOn: $isEnabled, onIcon: "checkmark", offIcon: "xmark")
                            .onChange(of: isEnabled) { _, on in
                                if on {
                                    // Force user to choose a card before proceeding
                                    if selectedCardID == nil {
                                        withAnimation(.spring(response: 0.3)) { selectedTab = .settings }
                                    }
                                }
                            }
                    }
                    .padding(16)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                                        .padding(.horizontal, 22).padding(.top, 16)

                    // Over-budget alerts
                    if isEnabled && (!overGroups.isEmpty || investAhead != nil) {
                        VStack(spacing: 8) {
                            ForEach(overGroups, id: \.group.rawValue) { item in
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle().fill(AppTheme.red.opacity(0.15)).frame(width: 36, height: 36)
                                        Image(systemName: "exclamationmark.triangle.fill").font(.system(.subheadline)).foregroundStyle(AppTheme.red)
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(String(format: loc("budget.over_budget"), item.group.label))
                                            .font(.system(.footnote, weight: .bold)).foregroundStyle(AppTheme.red)
                                        // In money. "62% of your pay used, 12% past the 50%
                                        // limit" asked the reader to tell a share of income
                                        // from a share of the limit.
                                        Text(String(format: loc("budget.over_detail"),
                                                    money(item.spent), money(item.limit), money(item.spent - item.limit)))
                                            .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                }
                                .padding(12)
                                .background(AppTheme.red.opacity(0.07), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                                .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).stroke(AppTheme.red.opacity(0.22), lineWidth: 1))
                            }
                            if let ahead = investAhead {
                                let goal = monthlyIncome * ahead.ratio
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle().fill(AppTheme.accent.opacity(0.15)).frame(width: 36, height: 36)
                                        Image(systemName: "checkmark.seal.fill").font(.system(.subheadline)).foregroundStyle(AppTheme.accent)
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(String(format: loc("budget.ahead_title"), BudgetGroup.investDebt.label))
                                            .font(.system(.footnote, weight: .bold)).foregroundStyle(AppTheme.accent)
                                        Text(ahead.spent - goal >= 0.5
                                             ? String(format: loc("budget.ahead_detail"),
                                                      money(ahead.spent), money(ahead.spent - goal), money(goal))
                                             : String(format: loc("budget.met_detail"), money(ahead.spent)))
                                            .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                }
                                .padding(12)
                                .background(AppTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                            }
                        }
                        .padding(.horizontal, 22).padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if isEnabled {
                        Picker("", selection: $selectedTab) {
                            ForEach(BudgetTab.allCases, id: \.self) { Text(loc($0.titleKey)).tag($0) }
                        }
                        .pickerStyle(.segmented).padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 4)
                    }

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 20) {
                            if isEnabled {
                                switch selectedTab {
                                case .overview: overviewTab
                                case .settings: settingsTab
                                // Take-home pay and pension growth live here,
                                // not in Debts & Credits. They answer income and
                                // cash-flow questions, which is what this screen
                                // is already about — a salary calculator filed
                                // under "what you owe" is somewhere nobody
                                // would think to look.
                                case .simulate:
                                    PlannerView(embedded: true, tools: [.takeHome, .jht])
                                }
                            }
                            Spacer(minLength: 40)
                        }.padding(.top, 12)
                        .containerRelativeFrame(.horizontal)
                    }
                }
            }
            .navigationTitle(loc("profile.budget")).navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                // Pushed, the back button is the way out: unsaved edits live only
                // in this screen's state and leave with it.
                if !pushed {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) {
                        // Revert local state to whatever was the active baseline
                        // (per-card config if editingPerCard, else global)
                        isEnabled = SmartBudgetManager.shared.isEnabled
                        let baseline = currentBaselineRatios
                        dailyPct      = baseline.daily
                        lifestylePct  = baseline.lifestyle
                        investPct     = baseline.investDebt
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.textSecondary)
                }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(loc("common.save")) {
                        guard canSave else { return }
                        SmartBudgetManager.shared.isEnabled = isEnabled
                        
                        if editingPerCard, let cardID = selectedCardID {
                            // Save to per-card config (upsert)
                            if let existing = cardConfigs.first(where: { $0.cardID == cardID }) {
                                existing.dailyRatio      = Double(dailyPct) / 100
                                existing.lifestyleRatio  = Double(lifestylePct) / 100
                                existing.investDebtRatio = Double(investPct) / 100
                                existing.updatedAt       = .now
                            } else {
                                let cfg = CardBudgetConfig(
                                    cardID: cardID,
                                    dailyRatio: Double(dailyPct) / 100,
                                    lifestyleRatio: Double(lifestylePct) / 100,
                                    investDebtRatio: Double(investPct) / 100
                                )
                                context.insert(cfg)
                            }
                            try? context.save()
                        } else {
                            // Save to global defaults
                            SmartBudgetManager.shared.dailyRatio      = Double(dailyPct) / 100
                            SmartBudgetManager.shared.lifestyleRatio  = Double(lifestylePct) / 100
                            SmartBudgetManager.shared.investDebtRatio = Double(investPct) / 100
                        }
                        
                        HapticManager.shared.success()
                        dismiss()
                    }
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(canSave ? AppTheme.accent : AppTheme.textSecondary.opacity(0.4))
                    .disabled(!canSave)
                }
            }
        }
        .animation(.spring(response: 0.35), value: overGroups.count)
        .onAppear {
            // The budget's subject, not a browsing choice. Falls back to the
            // first card only so the Overview preview still renders for someone
            // who has not picked an anchor yet.
            selectedCardID = MainCard.id ?? cards.first?.id.uuidString
            // Edit the override when the main card has one, the global ratios
            // otherwise — which is exactly what `ratios(forCardID:)` reads back,
            // so what is edited here is always what is in force.
            editingPerCard = selectedCardConfig != nil

            // Load the ratios of whichever target that turned out to be.
            //
            // The @State above initialises from the GLOBAL ratios, because a
            // property initialiser cannot know which card is the anchor yet. So
            // when the main card had its own override, this screen opened
            // showing global values while Save wrote to the card — meaning
            // opening the screen and tapping Save without touching anything
            // silently replaced the user's custom split with the defaults.
            //
            // That is the second, independent cause of "my ratios keep going
            // back to 50/30/20". The first was `save()` running mid-`load()`;
            // fixing that did not fix this, because they are different paths to
            // the same symptom.
            let live = SmartBudgetManager.shared.ratios(forCardID: selectedCardID,
                                                        configs: cardConfigs)
            dailyPct     = Self.pct(live.daily)
            lifestylePct = Self.pct(live.lifestyle)
            investPct    = Self.pct(live.investDebt)

            // Highlight whichever preset matches the loaded ratios.
            reconcileSelectedPreset()

            // Seed the rollup buckets the over-budget list reads from.
            refreshRollup()
        }
        // Keep the buckets fresh if a transaction is added/removed while the
        // sheet is open (e.g. via a deep link), so the over-budget list can't
        // read a stale figure.
        .onChange(of: totalTxCount) { _, _ in refreshRollup() }
        // Any ratio change that isn't a preset tap (manual +/-, numeric quick
        // presets, switching cards) keeps the highlighted preset in sync. The
        // reconcile is a no-op when an explicitly-tapped preset still matches.
        .onChange(of: dailyPct)     { _, _ in reconcileSelectedPreset() }
        .onChange(of: lifestylePct) { _, _ in reconcileSelectedPreset() }
        .onChange(of: investPct)    { _, _ in reconcileSelectedPreset() }
        .sheet(isPresented: $showSalarySetup) {
            SalaryView()
                // Presented from here, so a sheet — even when this screen was pushed.
                .environment(\.pushedFeature, false)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showRecommendation) {
            SmartRecommendationView(onApply: {
                // Sync the editor to what was just applied. Read through
                // `ratios(forCardID:)` rather than the globals directly: the
                // apply step also updates the selected card's override, and
                // this screen may be showing that card — reading globals here
                // made an applied plan look like it hadn't landed.
                isEnabled = true
                let applied = SmartBudgetManager.shared.ratios(forCardID: selectedCardID, configs: cardConfigs)
                dailyPct     = Self.pct(applied.daily)
                lifestylePct = Self.pct(applied.lifestyle)
                investPct    = Self.pct(applied.investDebt)
                reconcileSelectedPreset()
            })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        }
        .trackScreen(.smartBudgetSettings)
    }

    // MARK: - Overview Tab

    @ViewBuilder private var overviewTab: some View {
        // Guard: user must pick a card before seeing the overview
        if selectedCardID == nil {
            VStack(spacing: 16) {
                Image(systemName: "creditcard.trianglebadge.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(AppTheme.orange)
                Text(loc("budget.choose_card"))
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(loc("budget.card_hint"))
                    .font(.system(.subheadline))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    HapticManager.shared.tap()
                    withAnimation(.spring(response: 0.3)) { selectedTab = .settings }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3").font(.system(.subheadline))
                        Text(loc("budget.go_settings")).font(.system(.subheadline, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.onVividFill)
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(.top, 40)
        } else {

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(usesPayCycle ? loc("stats.period.pay_cycle") : loc("budget.this_month"))
                    .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                Text(periodLabel)
                    .font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                if let line = periodDayLine {
                    Text(line).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                }
            }
            Spacer()
            if monthlyIncome > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(incomeIsFromTransactions ? loc("budget.from_tx") : loc("budget.from_salary")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                    // The card's currency, which the income is in. The app's
                    // own currency printed a dollar card's $1.000 as "Rp 1.000".
                    Text(CurrencyManager.shared.formatted(monthlyIncome, currency: cardCurrency))
                        .font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.accent)
                    if extraFunds >= 0.5 {
                        Text(String(format: loc("budget.extra_included"),
                                    CurrencyManager.shared.formatted(extraFunds, currency: cardCurrency)))
                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle").font(.system(.caption)).foregroundStyle(AppTheme.orange)
                    Text(loc("budget.log_income")).font(.system(.caption)).foregroundStyle(AppTheme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 22)

        if monthlyIncome > 0 {
            let bills = scheduled
            let misfiled = misfiledInvestments
            ForEach(BudgetGroup.allCases, id: \.rawValue) { grp in
                BudgetGroupCard(group: grp, budgetTx: budgetTx, income: monthlyIncome, currency: cardCurrency, cardID: selectedCardID, configs: cardConfigs, periodStart: periodStart, periodEnd: periodEnd,
                                bills: ScheduledBills.bills(bills, in: grp),
                                misfiled: grp == .investDebt ? misfiled : [])
                    .padding(.horizontal, 22)
            }
        } else {
            // No income this month → budget limits would all be 0 and useless.
            // Prompt the user to set up their salary instead of showing empty
            // budget bars. (Smart Budget = income × ratio, so it needs income.)
            SalarySetupCTA(message: loc("salary.cta.budget")) {
                showSalarySetup = true
            }
            .padding(.horizontal, 22)
        }
        } // end else (card selected)
    }

    // MARK: - Settings Tab

    @ViewBuilder private var settingsTab: some View {
        // ── DiPo's Recommendation — AI-analyzed personalized budget ───────
        // Opens a full confirmation screen that reads the user's real
        // transactions and proposes a smarter split + saving/investing plan.
        Button {
            HapticManager.shared.tap()
            showRecommendation = true
        } label: {
            // A green-tinted card rather than a purple gradient: it is the most
            // useful thing on this tab, and it should look like DiPo, not an ad.
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(AppTheme.onVividFill)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("reco.cta_title")).font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                    Text(loc("reco.cta_sub")).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
            }
            .padding(14)
            .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(ScaleButtonStyle())
        .padding(.horizontal, 22)
        .padding(.bottom, 6)

        // ── Profile Presets — quick-pick lifestyle templates ─────────────
        // The default 50/30/20 doesn't fit everyone (mahasiswa kost-an,
        // freelancer with variable income, KPR payer all need different
        // shapes). This gallery lets the user pick a template that matches
        // their situation in one tap; tapping applies the ratios immediately
        // and the edit fields update to match. Custom is always available
        // as the fallback for users who want to tune manually.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(loc("budget.preset.section_title"))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .padding(.horizontal, 22)

            Text(loc("budget.preset.section_sub"))
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 22)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(BudgetProfile.allCases) { preset in
                        BudgetPresetCard(
                            preset: preset,
                            isSelected: isPresetSelected(preset),
                            onSelect: { applyPreset(preset) }
                        )
                    }
                }
                .padding(.horizontal, 22)
            }
        }
        .padding(.bottom, 16)

        // ── Which card this budget governs ────────────────────────────────
        //
        // This used to be a row of chips: "Default (all cards)" plus one per
        // card, each editable. That stopped being true when the anchor arrived.
        // Every consumer now reads `ratios(forCardID: budgetCardID)`, so ratios
        // saved against any other card were stored, shown as configured, and
        // never applied — a setting that looks like it works and does nothing.
        //
        // One target, resolved from the main card, and named rather than
        // chosen. Changing it is a Wallet decision, not a budget-screen one.
        if let main = MainCard.resolve(in: cards) {
            HStack(spacing: 10) {
                LinearGradient(colors: [Color(hex: main.gradientStart), Color(hex: main.gradientEnd)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: 4, height: 30)
                    .clipShape(Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("budget.applies_to"))
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .tracking(0.5)
                    Text(main.isDigitalWallet && !main.walletProvider.isEmpty
                         ? main.walletProvider
                         : (main.holderName.isEmpty ? loc("wallet.untitled") : main.holderName))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(loc("main.badge"))
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(AppTheme.accent.opacity(0.15), in: Capsule())
                    .lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .padding(.horizontal, 22)
            .padding(.bottom, 4)

            // Said where the budget's scope is named, for anyone with a credit
            // card: its purchases count when made, and paying the bill doesn't
            // count them again.
            if cards.contains(where: \.isCreditCard) {
                Label(loc("budget.credit_cards_counted"), systemImage: "creditcard")
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 6)
            }

            billCardsSection
        }

        // ── Budget Allocation ─────────────────────────────────────────────
        VStack(spacing: 6) {
            HStack {
                Text(loc("budget.allocation")).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text("\(totalPct)% / 100%").font(.system(.footnote, weight: .bold)).foregroundStyle(isBalanced ? AppTheme.accent : AppTheme.red)
            }.padding(.horizontal, 22)
            if !isBalanced {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(.caption)).foregroundStyle(AppTheme.orange)
                    Text(String(format: loc("budget.ratio_warning"), totalPct)).font(.system(.caption)).foregroundStyle(AppTheme.orange)
                }.padding(.horizontal, 22)
            }
        }
        BudgetRatioCard(group: .daily,      pct: $dailyPct,     otherTotal: lifestylePct + investPct).padding(.horizontal, 22)
        BudgetRatioCard(group: .lifestyle,  pct: $lifestylePct, otherTotal: dailyPct + investPct).padding(.horizontal, 22)
        BudgetRatioCard(group: .investDebt, pct: $investPct,     otherTotal: dailyPct + lifestylePct).padding(.horizontal, 22)

        // NOTE: the numeric "quick presets" row that used to sit here was
        // removed — the Profile Presets gallery above this section already
        // offers the same splits with better labels, and two preset pickers on
        // one screen left the user unsure which one was authoritative.

        VStack(alignment: .leading, spacing: 10) {
            Text(loc("budget.whats_in")).font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textSecondary).padding(.horizontal, 22)
            ForEach(BudgetGroup.allCases, id: \.rawValue) { grp in
                HStack(spacing: 10) {
                    Image(systemName: grp.icon).font(.system(.subheadline)).foregroundStyle(grp.color).frame(width: 28)
                    Text(grp.label).font(.system(.footnote, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    // Use displayLabel (localized) instead of rawValue (English-only)
                    Text(SmartBudgetManager.shared.categories(for: grp).map { $0.displayLabel }.joined(separator: ", "))
                        .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary).multilineTextAlignment(.trailing)
                }.padding(.horizontal, 22)
            }
        }
        
        // ── Reset per-card override (only shown when this card has a saved config)
        if editingPerCard, selectedCardConfig != nil {
            Button {
                HapticManager.shared.tap()
                if let cfg = selectedCardConfig {
                    context.delete(cfg)
                    try? context.save()
                }
                // Switch back to global view
                editingPerCard = false
                dailyPct      = Self.pct(SmartBudgetManager.shared.dailyRatio)
                lifestylePct  = Self.pct(SmartBudgetManager.shared.lifestyleRatio)
                investPct     = Self.pct(SmartBudgetManager.shared.investDebtRatio)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward.circle").font(.system(.subheadline))
                    Text(loc("budget.reset_to_default"))
                        .font(.system(.subheadline, weight: .semibold))
                }
                .foregroundStyle(AppTheme.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(AppTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).stroke(AppTheme.red.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 22)
            .padding(.top, 8)
        }
    }

    // MARK: - Profile Preset Helpers

    /// Whether a preset's ratios equal the current editor values. Pure ratio
    /// test — used only as a tie-broken fallback by `reconcileSelectedPreset`,
    /// never directly for highlighting (two presets can share a ratio).
    private func ratiosMatch(_ preset: BudgetProfile) -> Bool {
        let r = preset.ratios
        return Self.pct(r.daily)      == dailyPct
            && Self.pct(r.lifestyle)  == lifestylePct
            && Self.pct(r.investDebt) == investPct
    }

    /// Highlight rule for a preset card: a preset is "selected" only when it
    /// is the exact one the user chose (identity match). This guarantees at
    /// most one card is ever highlighted, even when several presets share the
    /// same 50/20/30 split.
    private func isPresetSelected(_ preset: BudgetProfile) -> Bool {
        selectedPreset == preset
    }

    /// Keeps `selectedPreset` consistent after any ratio change that did NOT
    /// come from tapping a preset card (manual +/-, the numeric quick presets,
    /// switching cards, first appear). If the user's explicitly-chosen preset
    /// still matches the current ratios we keep it (preserves the Mortgage-vs-
    /// Student identity); otherwise we fall back to the first preset whose
    /// ratios match, or nil when nothing matches (truly custom).
    private func reconcileSelectedPreset() {
        if let sel = selectedPreset, ratiosMatch(sel) { return }
        selectedPreset = BudgetProfile.allCases.first(where: ratiosMatch)
    }

    /// Tap handler for a preset card. Records the explicit identity and loads
    /// the preset's ratios into the editor (doesn't persist yet — user still
    /// has to tap Save). This matches the rest of the form which is also
    /// unsaved-on-edit, so the preset behaves like any other ratio change.
    private func applyPreset(_ preset: BudgetProfile) {
        HapticManager.shared.tap()
        let r = preset.ratios
        selectedPreset = preset
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            dailyPct      = Self.pct(r.daily)
            lifestylePct  = Self.pct(r.lifestyle)
            investPct     = Self.pct(r.investDebt)
        }
    }
}

// MARK: - Budget Preset Card

/// One card in the horizontal preset gallery. Compact: icon, name, ratios.
/// Tap = apply preset to editor. Active preset gets a colored border so
/// the user can confirm what's currently loaded.
struct BudgetPresetCard: View {
    let preset: BudgetProfile
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: preset.icon)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(preset.color)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(.subheadline))
                            .foregroundStyle(preset.color)
                    }
                }
                Text(preset.displayName)
                    .font(.system(.footnote, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                // Ratio summary — at a glance "this preset is 50/30/20"
                Text("\(BudgetGroup.pct(preset.ratios.daily))/\(BudgetGroup.pct(preset.ratios.lifestyle))/\(BudgetGroup.pct(preset.ratios.investDebt))")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(preset.color)
                Text(preset.tagline)
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(width: 160, height: 120, alignment: .topLeading)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(isSelected ? preset.color : AppTheme.cardMid.opacity(0.4),
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Budget Ratio Card

struct BudgetRatioCard: View {
    let group: BudgetGroup
    @Binding var pct: Int
    let otherTotal: Int

    private var maxAllowed: Int { max(100 - otherTotal, 0) }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: group.icon)
                        .font(.system(.subheadline))
                        .foregroundStyle(group.color)
                    Text(group.label)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Button {
                        if pct > 0 { pct -= 5; HapticManager.shared.tap() }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(.caption, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .frame(width: 32, height: 32)
                            .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.xs))
                    }
.accessibilityLabel(loc("a11y.decrease"))
                    Text("\(pct)%")
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(group.color)
                        .frame(width: 50, alignment: .center)
                        .contentTransition(.numericText())
                    Button {
                        if pct < maxAllowed { pct += 5; HapticManager.shared.tap() }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(.caption, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .frame(width: 32, height: 32)
                            .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.xs))
                    }
.accessibilityLabel(loc("a11y.increase"))
                }
            }

            // Progress bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(AppTheme.cardMid).frame(height: 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(group.color)
                        .frame(width: g.size.width * CGFloat(pct) / 100, height: 8)
                        .animation(.spring(response: 0.35), value: pct)
                }
            }
            .frame(height: 8)
        }
        .padding(14)
        // No tinted border: the group's colour is already on its icon, figure
        // and bar. A coloured outline on every card said nothing new.
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }
}

// MARK: - Budget Group Card

struct BudgetGroupCard: View {
    let group: BudgetGroup
    let budgetTx: [TxRecord]
    let income: Double
    let currency: String
    /// Card whose budget is being previewed. Drives per-card ratio lookup so
    /// a saved CardBudgetConfig override is reflected here (nil = global).
    var cardID: String? = nil
    var configs: [CardBudgetConfig] = []
    /// Start of the budget window (pay-cycle aware). Defaults to the 1st of the
    /// month so any legacy call site keeps calendar-month behavior.
    var periodStart: Date = Calendar.current.safeDate(from: Calendar.current.dateComponents([.year, .month], from: Date()))
    /// Next payday (or the 1st of next month) — passed on so the detail
    /// screen counts the days actually left.
    var periodEnd: Date? = nil
    /// This group's monthly expenses still to come this period.
    var bills: [ScheduledBill] = []
    /// Savings & debt only: monthly expenses that read like an investment but
    /// count as spending.
    var misfiled: [RecurringExpense] = []
    @State private var animatedProgress: Double = 0

    private var monthStart: Date { periodStart }
    private var groupTx: [TxRecord] { BudgetGroupMath.rows(group, in: budgetTx, from: monthStart) }
    private var spent: Double  { BudgetGroupMath.spent(groupTx, currency: currency) }
    private var ratio: Double  { SmartBudgetManager.shared.ratio(for: group, cardID: cardID, configs: configs) }
    private var limit: Double  { income * ratio }
    private var progress: Double { limit > 0 ? min(spent / limit, 1.5) : 0 }
    /// Past a LIMIT (Needs, Wants) — Savings & debt has a target instead.
    private var isOver: Bool   { group.isCeiling && spent > limit && limit > 0 }
    /// Savings & debt at or past its target.
    private var isAhead: Bool  { !group.isCeiling && spent >= limit && limit > 0 }
    private var targetPct: Int { BudgetGroup.pct(ratio) }
    private var billsTotal: Double { bills.reduce(0.0) { $0 + $1.amount } }
    /// Share of the limit the bills still to come take, after what is spent.
    private var billsShare: Double { limit > 0 ? billsTotal / limit : 0 }
    /// Not over yet, but the bills still to come will take it there.
    private var willGoOver: Bool { group.isCeiling && !isOver && limit > 0 && spent + billsTotal > limit }
    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v.rounded(), currency: currency) }

    /// One line under the figures: what the bills still to come leave.
    private var billsLine: String? {
        guard billsTotal >= 0.5, limit > 0 else { return nil }
        if group.isCeiling {
            if willGoOver {
                return String(format: loc("budget.bills_card_over"), money(billsTotal), group.label,
                              money(spent + billsTotal - limit))
            }
            guard !isOver else { return nil }
            return String(format: loc("budget.bills_card_left"), money(billsTotal),
                          money(max(limit - spent - billsTotal, 0)))
        }
        guard !isAhead else { return nil }
        if spent + billsTotal >= limit { return String(format: loc("budget.bills_card_reach"), money(billsTotal)) }
        return String(format: loc("budget.bills_card_to_go"), money(billsTotal),
                      money(max(limit - spent - billsTotal, 0)))
    }

    var body: some View {
        NavigationLink(destination: BudgetGroupDetailView(group: group, budgetTx: budgetTx, income: income, currency: currency, cardID: cardID, configs: configs, periodStart: periodStart, periodEnd: periodEnd, bills: bills, misfiled: misfiled)) {
            VStack(spacing: 12) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: group.icon).font(.system(.subheadline)).foregroundStyle(group.color)
                        Text(group.label).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    }
                    Spacer()
                    // What happened, in words: "62% / 50%" was two shares of
                    // income side by side with nothing saying which was which.
                    if isOver {
                        Text(String(format: loc("budget.over_short"),
                                    CurrencyManager.shared.formatted((spent - limit).rounded(), currency: currency)))
                            .font(.system(.caption2, weight: .bold)).foregroundStyle(AppTheme.red)
                            .lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(AppTheme.red.opacity(0.12), in: Capsule())
                    } else if willGoOver {
                        // Not over yet: orange, and in the future tense.
                        Text(String(format: loc("budget.will_go_over_short"), money(spent + billsTotal - limit)))
                            .font(.system(.caption2, weight: .bold)).foregroundStyle(AppTheme.orange)
                            .lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(AppTheme.orange.opacity(0.12), in: Capsule())
                    } else if isAhead {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark").font(.system(.caption2, weight: .heavy))
                            Text(loc("budget.on_target"))
                        }
                        .font(.system(.caption2, weight: .bold)).foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(AppTheme.accent.opacity(0.12), in: Capsule())
                    }
                    Image(systemName: "chevron.right").font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(AppTheme.cardMid).frame(height: 7)
                        // The bills still to come, after what is spent: the part
                        // of the limit already claimed. Orange when they will
                        // take the group past it.
                        if billsShare > 0, !isOver {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(willGoOver ? AppTheme.orange.opacity(0.5) : group.color.opacity(0.35))
                                .frame(width: g.size.width * min(CGFloat(animatedProgress + billsShare), 1.0), height: 7)
                        }
                        RoundedRectangle(cornerRadius: 4).fill(isOver ? AppTheme.red : group.color)
                            .frame(width: g.size.width * min(CGFloat(animatedProgress), 1.0), height: 7)
                    }
                }.frame(height: 7)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc("budget.spent")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                        Text(CurrencyManager.shared.formatted(spent, currency: currency))
                            .font(.system(.subheadline, weight: .bold)).foregroundStyle(isOver ? AppTheme.red : AppTheme.textPrimary)
                    }
                    Spacer()
                    if limit > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: loc(group.isCeiling ? "budget.target_label" : "budget.goal_label"), targetPct)).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                            Text(CurrencyManager.shared.formatted(limit, currency: currency))
                                .font(.system(.subheadline, weight: .bold)).foregroundStyle(group.color)
                        }
                    }
                }
                if let line = billsLine {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "calendar.badge.clock").font(.system(.caption))
                            .foregroundStyle(willGoOver ? AppTheme.orange : group.color)
                        Text(line).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
                if !groupTx.isEmpty {
                    Divider().background(AppTheme.cardMid)
                    VStack(spacing: 8) {
                        ForEach(groupTx.prefix(2)) { tx in
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: AppRadius.sm).fill(tx.displayIconBg).frame(width: 30, height: 30)
                                    Text(tx.icon).font(.system(size: tx.icon.count == 1 ? 12 : 15)).foregroundStyle(.white)
                                }
                                Text(tx.name).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                                Spacer()
                                Text(BudgetGroupMath.amountLabel(tx))
                                    .font(.system(.caption, weight: .semibold))
                                    .foregroundStyle(BudgetGroupMath.isRefund(tx) ? AppTheme.accent : AppTheme.textSecondary)
                            }
                        }
                        if groupTx.count > 2 { Text(String(format: loc("common.plus_more"), groupTx.count - 2)).font(.system(.caption2)).foregroundStyle(group.color).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle").font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        Text(loc("budget.none_yet")).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            // Outlined only when over budget — the one state worth a border.
            .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).stroke(isOver ? AppTheme.red.opacity(0.35) : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .onAppear { withAnimation(.easeInOut(duration: 1.0).delay(0.15)) { animatedProgress = progress } }
    }
}

// MARK: - Budget Group Detail View

struct BudgetGroupDetailView: View {
    let group: BudgetGroup
    let budgetTx: [TxRecord]
    let income: Double
    let currency: String
    /// Card whose budget is shown — drives per-card ratio (nil = global).
    var cardID: String? = nil
    var configs: [CardBudgetConfig] = []
    /// Start of the budget window (pay-cycle aware). Defaults to month start.
    var periodStart: Date = Calendar.current.safeDate(from: Calendar.current.dateComponents([.year, .month], from: Date()))
    /// The next payday (or the 1st of next month). "Start plus one month" was
    /// the 25th when the salary lands on Friday the 23rd: two days too many.
    var periodEnd: Date? = nil
    /// This group's monthly expenses still to come this period: taken out of
    /// what is left, and listed so the figure can be checked.
    var bills: [ScheduledBill] = []
    /// Savings & debt only: monthly expenses that read like an investment but
    /// are filed where they count as spending.
    var misfiled: [RecurringExpense] = []
    @Environment(\.modelContext) private var context
    /// Plans moved from here, hidden at once rather than when the list above
    /// next recomputes.
    @State private var moved: Set<UUID> = []

    private var cal: Calendar  { Calendar.current }
    private var monthStart: Date { periodStart }
    private var windowEnd: Date { periodEnd ?? cal.safeDate(byAdding: .month, value: 1, to: periodStart) }
    /// Days remaining until the window ends. Pay-cycle aware, so the
    /// "remaining/day" hint paces against days left until the next payday
    /// rather than the calendar month-end.
    private var daysLeft: Int { StatPeriod.daysLeft(in: (periodStart, windowEnd)) }
    private var primary: String  { currency }
    private func fmt(_ amount: Double) -> String {
        CurrencyManager.shared.formatted(amount, currency: primary)
    }

    private var groupTx: [TxRecord] { BudgetGroupMath.rows(group, in: budgetTx, from: monthStart) }
    private var spent: Double    { BudgetGroupMath.spent(groupTx, currency: currency) }
    private var ratio: Double    { SmartBudgetManager.shared.ratio(for: group, cardID: cardID, configs: configs) }
    private var limit: Double    { income * ratio }
    /// Past a LIMIT. Savings & debt has a target, which it can only be short
    /// of or ahead of — never "over".
    private var isOver: Bool     { group.isCeiling && spent > limit && limit > 0 }
    private var isAhead: Bool    { !group.isCeiling && spent >= limit && limit > 0 }
    private var billsTotal: Double { bills.reduce(0.0) { $0 + $1.amount } }
    /// What is left once the bills still to come are paid — under a limit,
    /// what can still be spent; under a target, what is still to be put aside.
    private var remaining: Double { max(limit - spent - billsTotal, 0) }
    /// Not over yet, but the bills still to come will take it there.
    private var willGoOver: Bool { group.isCeiling && !isOver && limit > 0 && spent + billsTotal > limit }
    /// Short of the target, with enough planned to reach it.
    private var plannedToReach: Bool { !group.isCeiling && !isAhead && limit > 0 && spent + billsTotal >= limit }
    private var overAmt: Double  { max(spent - limit, 0) }
    private var actualPct: Int   { BudgetGroup.pct(spent, of: income) }
    private var targetPct: Int   { BudgetGroup.pct(ratio) }
    private var overPct: Int     { BudgetGroup.pct(overAmt, of: income) }
    /// Everything spent this period, every group — Statistics' figure.
    private var totalSpent: Double {
        BudgetGroup.allCases.reduce(0.0) {
            $0 + BudgetGroupMath.spent(BudgetGroupMath.rows($1, in: budgetTx, from: monthStart), currency: currency)
        }
    }

    private var catBreakdown: [(cat: TxCategory, amount: Double)] {
        SmartBudgetManager.shared.categories(for: group).compactMap { cat in
            let a = BudgetGroupMath.spent(groupTx.filter { $0.category == cat }, currency: currency)
            return a > 0 ? (cat, a) : nil
        }.sorted { $0.amount > $1.amount }
    }
    private var grouped: [(label: String, date: Date, txs: [TxRecord])] {
        var dict: [Date: [TxRecord]] = [:]
        for tx in groupTx { let d = cal.startOfDay(for: tx.date); dict[d, default: []].append(tx) }
        return dict.keys.sorted(by: >).map { d in
            let lbl = cal.isDateInToday(d) ? loc("common.today")
                    : cal.isDateInYesterday(d) ? loc("common.yesterday")
                    // The app's language, not the phone's: `formatted` printed
                    // "Wednesday, 21 Oct" on an Indonesian screen.
                    : DateFormatterCache.template("EEEEdMMM").string(from: d)
            return (lbl, d, (dict[d] ?? []).sorted { $0.date > $1.date })
        }
    }

    /// The sentence under the bar, in money. It was three percentages —
    /// "62% of your pay used, 12% past the 50% limit" — two of them shares of
    /// income and one a share of the limit, with nothing saying which.
    private var statusLine: String {
        if isOver { return String(format: loc("budget.over_detail"), fmt(spent), fmt(limit), fmt(overAmt)) }
        if isAhead {
            // Ahead of target is good — unless everything spent this period has
            // already run past the pay, when the extra came out of the balance.
            let base = overAmt >= 0.5
                ? String(format: loc("budget.ahead_detail"), fmt(spent), fmt(overAmt), fmt(limit))
                : String(format: loc("budget.met_detail"), fmt(spent))
            guard income > 0, totalSpent > income else { return base }
            return base + " " + String(format: loc("budget.ahead_but_over"), fmt(totalSpent), fmt(income))
        }
        if !group.isCeiling { return String(format: loc("budget.goal_progress"), fmt(spent), fmt(limit)) }
        return String(format: loc("budget.under_detail"), fmt(spent), fmt(limit))
    }

    private var thirdLabelKey: String {
        if isOver { return "budget.over_by" }
        if isAhead { return "budget.ahead_by" }
        return group.isCeiling ? "budget.left" : "budget.to_go"
    }

    /// What the rest of the period asks for: a daily pace under a limit, or
    /// the amount still to put aside to reach a target.
    ///
    /// Today counts — nothing spent yet today comes out of this money too —
    /// and the last day is named, so the count can be checked on a calendar.
    /// "For the 33 days left" read as 33 days after today, and payday is 32
    /// days away.
    private var paceNote: String? {
        guard limit > 0, remaining > 0, daysLeft > 0 else { return nil }
        let lastDay = StatPeriod.lastDayLabel(before: windowEnd)
        if group.isCeiling {
            guard !isOver else { return nil }
            return String(format: loc("budget.pace_hint"), fmt(remaining / Double(daysLeft)), daysLeft, lastDay)
        }
        return String(format: loc("budget.goal_pace"), fmt(remaining), lastDay)
    }

    /// What the monthly expenses still to come do to the figures above.
    private var billsNote: String? {
        guard billsTotal >= 0.5, limit > 0 else { return nil }
        if group.isCeiling {
            if isOver { return String(format: loc("budget.bills_more_over"), fmt(billsTotal)) }
            if willGoOver {
                return String(format: loc("budget.bills_will_over"), fmt(billsTotal), group.label,
                              fmt(spent + billsTotal - limit))
            }
            return String(format: loc("budget.bills_taken_out"), fmt(billsTotal))
        }
        if isAhead { return nil }
        return String(format: loc(plannedToReach ? "budget.bills_reach" : "budget.bills_planned"), fmt(billsTotal))
    }

    /// Moves a monthly expense into Investment, with what it already charged
    /// this period, so the move shows here now rather than next month.
    private func moveToInvestment(_ plan: RecurringExpense) {
        let key = RecurringHistory.normalized(plan.label)
        let cards = (try? context.fetch(FetchDescriptor<BankCard>())) ?? []
        for card in cards where card.id == plan.cardID {
            for tx in card.transactions
            where tx.notes == "tx.note.recurring_auto" && tx.date >= periodStart
                && RecurringHistory.normalized(tx.name) == key {
                tx.category = .investment
                tx.iconBgHex = TxCategory.investment.iconBg
            }
        }
        plan.category = .investment
        try? context.save()
        // A re-filed row keeps the transaction count, the only change the
        // rollup cache notices on its own.
        RollupStore.shared.rebuild(context: context)
        LedgerRevision.shared.bump()
        HapticManager.shared.success()
        withAnimation(.spring(response: 0.3)) { _ = moved.insert(plan.id) }
    }

    /// A monthly expense that reads like an investment but is filed as
    /// spending — "Gold invest" under Commitment, so it counted as a Need and
    /// never reached this target.
    @ViewBuilder private var misfiledHints: some View {
        ForEach(misfiled.filter { !moved.contains($0.id) }, id: \.id) { plan in
            VStack(alignment: .leading, spacing: 8) {
                Label(String(format: loc("budget.misfiled_investment"), plan.label,
                             CurrencyManager.shared.formatted(plan.amount, currency: plan.currency),
                             plan.category.displayLabel,
                             SmartBudgetManager.shared.group(for: plan.category)?.label ?? plan.category.displayLabel),
                      systemImage: "info.circle.fill")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { moveToInvestment(plan) } label: {
                    Text(String(format: loc("budget.misfiled_move"), TxCategory.investment.displayLabel))
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(AppTheme.accentFill, in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.md))
            .padding(.horizontal, 22)
        }
    }

    /// The monthly expenses taken out above, each with its day, so "Left"
    /// can be checked line by line.
    @ViewBuilder private var billsList: some View {
        if !bills.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(loc("budget.bills_title")).font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Text(fmt(billsTotal)).font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.horizontal, 22)
                VStack(spacing: 0) {
                    ForEach(bills) { bill in
                        HStack(spacing: 14) {
                            Image(systemName: bill.category.icon)
                                .font(.system(.subheadline)).foregroundStyle(bill.category.color)
                                .frame(width: 40, height: 40)
                                .background(bill.category.color.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(bill.label).font(.system(.subheadline, weight: .medium))
                                    .foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                                Text(DateFormatterCache.template("EEEEdMMM").string(from: bill.due))
                                    .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                // A bill in another currency is converted at today's
                                // rate, so its rupiah figure is an estimate.
                                if bill.planCurrency.uppercased() != currency.uppercased() {
                                    Text("≈ " + fmt(bill.amount)).font(.system(.subheadline, weight: .semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                    Text(CurrencyManager.shared.formatted(bill.planAmount, currency: bill.planCurrency))
                                        .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                } else {
                                    Text(fmt(bill.amount)).font(.system(.subheadline, weight: .semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                }
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        if bill.id != bills.last?.id { Divider().background(AppTheme.cardMid).padding(.horizontal, 16) }
                    }
                }
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .padding(.horizontal, 22)
                Text(loc("budget.bills_foot"))
                    .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22)
            }
        }
    }

    // MARK: - Budget Bar
    //
    // The track is scaled to max(spent, limit), so the bar never just "pegs at
    // full" the moment you go 1% over — it shows the budgeted part in the group
    // colour and the overspill in red, with a tick marking exactly where the
    // limit sits. Under budget, the right edge of the track IS the limit.
    private var barScale: Double { max(spent + billsTotal, limit, 1) }
    /// Share of the track occupied by spending that is still inside the limit.
    private var withinFraction: Double { min(spent, limit) / barScale }
    /// Share of the track occupied by the overspill (0 when under budget).
    private var overFraction: Double { max(spent - limit, 0) / barScale }
    /// The monthly expenses still to come, after what is spent: the part
    /// inside the limit, and the part that will run past it.
    private var billsWithinFraction: Double { min(billsTotal, max(limit - spent, 0)) / barScale }
    private var billsPastFraction: Double { max(billsTotal - max(limit - spent, 0), 0) / barScale }
    /// Where the limit tick sits along the track.
    private var limitFraction: Double { limit / barScale }
    /// The tick is drawn once something — spent or still to come — reaches it.
    private var showsLimitTick: Bool { isOver || isAhead || willGoOver || plannedToReach }
    /// Percentage of the budget consumed (can exceed 100).
    private var usedOfBudgetPct: Int { limit > 0 ? Int(((spent / limit) * 100).rounded()) : 0 }

    private var budgetBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { g in
                    let W = g.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.cardMid).frame(height: 12)

                        HStack(spacing: 0) {
                            Capsule()
                                .fill(LinearGradient(colors: [group.color.opacity(0.75), group.color],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: W * CGFloat(withinFraction))
                            if overFraction > 0 {
                                // Past a limit warms to red; past a target is
                                // more of the good thing, in the group's colour.
                                Capsule()
                                    .fill(LinearGradient(colors: group.isCeiling ? [AppTheme.orange, AppTheme.red]
                                                                                 : [group.color, group.color.opacity(0.75)],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: W * CGFloat(overFraction))
                            }
                            // Still to come: paler, so it reads as claimed,
                            // not spent. What will run past a limit is orange.
                            if billsWithinFraction > 0 {
                                Rectangle().fill(group.color.opacity(0.35))
                                    .frame(width: W * CGFloat(billsWithinFraction))
                            }
                            if billsPastFraction > 0 {
                                Rectangle().fill(group.isCeiling ? AppTheme.orange.opacity(0.55) : group.color.opacity(0.35))
                                    .frame(width: W * CGFloat(billsPastFraction))
                            }
                        }
                        .frame(height: 12)
                        .clipShape(Capsule())

                        // Limit tick — drawn once spending, or what is still
                        // to come, reaches it.
                        if showsLimitTick {
                            Capsule().fill(Color.white.opacity(0.92))
                                .frame(width: 2.5, height: 20)
                                .shadow(color: .black.opacity(0.4), radius: 2)
                                .offset(x: W * CGFloat(limitFraction) - 1.25)
                        }
                    }
                    .frame(height: 20)
                }
                .frame(height: 20)

                // Caption anchored under the limit tick.
                if showsLimitTick {
                    GeometryReader { g in
                        Text(loc(group.isCeiling ? "budget.limit_marker" : "budget.target_marker"))
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .offset(x: max(min(g.size.width * CGFloat(limitFraction) - 12, g.size.width - 30), 0))
                    }
                    .frame(height: 11)
                }
            }
            Text("\(usedOfBudgetPct)%")
                .font(.system(.subheadline, weight: .heavy))
                .foregroundStyle(isOver ? AppTheme.red : group.color)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 46, alignment: .trailing)
        }
    }

    /// One stacked bar showing how the group's spending splits across categories.
    private var compositionStrip: some View {
        GeometryReader { g in
            let gaps = CGFloat(max(catBreakdown.count - 1, 0)) * 2
            let usable = max(g.size.width - gaps, 1)
            HStack(spacing: 2) {
                ForEach(catBreakdown, id: \.cat) { item in
                    Capsule()
                        .fill(item.cat.color)
                        .frame(width: max(usable * CGFloat(item.amount / max(spent, 1)), 3))
                }
            }
            .frame(height: 8)
        }
        .frame(height: 8)
    }

    var body: some View {
        ZStack { AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    // Hero summary card
                    VStack(spacing: 0) {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: AppRadius.md).fill(isOver ? AppTheme.red.opacity(0.12) : group.color.opacity(0.12)).frame(width: 52, height: 52)
                                Image(systemName: group.icon).font(.system(.title2)).foregroundStyle(isOver ? AppTheme.red : group.color)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.label).font(.system(.body, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                // Category names in the app's language. `rawValue` is the stored English
                                // key, so the Indonesian screen read "Food & Drinks · Transport · Bills".
                                Text(SmartBudgetManager.shared.categories(for: group).map(\.displayLabel).joined(separator: ", ")).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                            }
                            Spacer()
                            if isOver {
                                VStack(spacing: 2) {
                                    Image(systemName: "exclamationmark.triangle.fill").font(.system(.caption)).foregroundStyle(AppTheme.red)
                                    Text(loc("budget.over_badge")).font(.system(.caption2, weight: .bold)).foregroundStyle(AppTheme.red)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(AppTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                            } else if isAhead {
                                VStack(spacing: 2) {
                                    Image(systemName: "checkmark.seal.fill").font(.system(.caption)).foregroundStyle(AppTheme.accent)
                                    Text(loc("budget.on_target")).font(.system(.caption2, weight: .bold)).foregroundStyle(AppTheme.accent)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(AppTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                            }
                        }
                        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)

                        budgetBar
                            .padding(.horizontal, 18)

                        HStack(alignment: .top) {
                            HStack(alignment: .top, spacing: 5) {
                                Circle().fill(isOver ? AppTheme.red : group.color).frame(width: 6, height: 6).padding(.top, 4)
                                Text(statusLine)
                                    .font(.system(.caption2, weight: .medium))
                                    .foregroundStyle(isOver ? AppTheme.red : isAhead ? AppTheme.accent : AppTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 10)
                            Text(groupTx.count == 1
                                 ? loc("budget.tx_count_one")
                                 : String(format: loc("budget.tx_count"), groupTx.count))
                                .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                // Was a bare .fixedSize(), which locks BOTH axes:
                                // the text refused to wrap AND refused to shrink.
                                // Next to the long left-hand sentence that pushed
                                // the HStack's minimum width past the screen, so
                                // the whole card — and with it the page — became
                                // wider than the display and drifted sideways.
                                // Locking only the vertical axis keeps it on one
                                // line's worth of height while still yielding
                                // horizontally.
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                        }
                        .padding(.horizontal, 18).padding(.top, 10)

                        Divider().background(AppTheme.cardMid).padding(.horizontal, 18).padding(.vertical, 14)

                        HStack(spacing: 0) {
                            VStack(spacing: 5) {
                                HStack(spacing: 4) { Circle().fill(isOver ? AppTheme.red : AppTheme.textSecondary).frame(width: 6, height: 6); Text(loc("budget.spent")).font(.system(.caption2, weight: .medium)).foregroundStyle(AppTheme.textSecondary) }
                                Text(fmt(spent)).font(.system(.subheadline, weight: .bold)).foregroundStyle(isOver ? AppTheme.red : AppTheme.textPrimary).minimumScaleFactor(0.6).lineLimit(1)
                                Text(String(format: loc("budget.pct_income"), actualPct)).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                            Rectangle().fill(AppTheme.cardMid).frame(width: 1, height: 52)
                            VStack(spacing: 5) {
                                HStack(spacing: 4) { Circle().fill(group.color).frame(width: 6, height: 6); Text(loc(group.isCeiling ? "budget.limit_marker" : "budget.target")).font(.system(.caption2, weight: .medium)).foregroundStyle(AppTheme.textSecondary) }
                                Text(limit > 0 ? fmt(limit) : "—").font(.system(.subheadline, weight: .bold)).foregroundStyle(group.color).minimumScaleFactor(0.6).lineLimit(1)
                                Text(String(format: loc("budget.pct_income"), targetPct)).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                            Rectangle().fill(AppTheme.cardMid).frame(width: 1, height: 52)
                            VStack(spacing: 5) {
                                HStack(spacing: 4) { Circle().fill(isOver ? AppTheme.red : AppTheme.accent).frame(width: 6, height: 6); Text(loc(thirdLabelKey)).font(.system(.caption2, weight: .medium)).foregroundStyle(AppTheme.textSecondary) }
                                Text(isOver || isAhead ? fmt(overAmt) : fmt(remaining)).font(.system(.subheadline, weight: .bold)).foregroundStyle(isOver ? AppTheme.red : AppTheme.accent).minimumScaleFactor(0.6).lineLimit(1)
                                // A share of income like the two columns beside it.
                                // "+12%" read as 12% of the limit.
                                Text(String(format: loc("budget.pct_income"), isOver || isAhead ? overPct : BudgetGroup.pct(remaining, of: income))).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .padding(.horizontal, 10).padding(.bottom, 14)

                        if let note = billsNote {
                            Divider().background(AppTheme.cardMid).padding(.horizontal, 18)
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "calendar.badge.clock").font(.system(.caption))
                                    .foregroundStyle(isOver || willGoOver ? AppTheme.orange : group.color)
                                Text(note)
                                    .font(.system(.caption, weight: .medium))
                                    .foregroundStyle(willGoOver ? AppTheme.orange : AppTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }.padding(.horizontal, 18).padding(.vertical, 12)
                        }

                        if let note = paceNote {
                            Divider().background(AppTheme.cardMid).padding(.horizontal, 18)
                            HStack(spacing: 8) {
                                Image(systemName: "calendar").font(.system(.caption)).foregroundStyle(group.color)
                                Text(note)
                                    .font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }.padding(.horizontal, 18).padding(.vertical, 12)
                        }
                    }
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).stroke(isOver ? AppTheme.red.opacity(0.3) : Color.clear, lineWidth: 1.5))
                    .padding(.horizontal, 22)

                    misfiledHints
                    billsList

                    // Category breakdown — every number here is a share of THIS
                    // group's spending, so the bars and the % labels agree.
                    if !catBreakdown.isEmpty && income > 0 {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(loc("tx.by_category")).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary).padding(.horizontal, 22)

                            compositionStrip.padding(.horizontal, 22)

                            VStack(spacing: 14) {
                                ForEach(catBreakdown, id: \.cat) { item in
                                    let share = item.amount / max(spent, 1)
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: AppRadius.sm).fill(item.cat.color.opacity(0.14)).frame(width: 36, height: 36)
                                            Image(systemName: item.cat.icon).font(.system(.subheadline)).foregroundStyle(item.cat.color)
                                        }
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                Text(item.cat.displayLabel).font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                                Text("\(Int((share * 100).rounded()))%")
                                                    .font(.system(.caption2, weight: .bold)).foregroundStyle(item.cat.color)
                                                Spacer(minLength: 6)
                                                Text(fmt(item.amount)).font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                                    .lineLimit(1).minimumScaleFactor(0.7)
                                            }
                                            GeometryReader { g in
                                                ZStack(alignment: .leading) {
                                                    Capsule().fill(AppTheme.cardMid).frame(height: 5)
                                                    Capsule()
                                                        .fill(LinearGradient(colors: [item.cat.color.opacity(0.75), item.cat.color],
                                                                             startPoint: .leading, endPoint: .trailing))
                                                        .frame(width: max(g.size.width * CGFloat(share), share > 0 ? 5 : 0), height: 5)
                                                }
                                            }.frame(height: 5)
                                        }
                                    }.padding(.horizontal, 22)
                                }
                            }
                        }
                    }

                    // Transactions
                    if !grouped.isEmpty {
                        // ✅ Capture computed properties before nested closures to avoid scope issues
                        let currencyCode = primary
                        
                        VStack(alignment: .leading, spacing: 16) {
                            Text(loc("home.transactions")).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary).padding(.horizontal, 22)
                            VStack(spacing: 12) {
                                ForEach(grouped, id: \.date) { grp in
                                    VStack(alignment: .leading, spacing: 8) {
                                        let dayTotal = BudgetGroupMath.spent(grp.txs, currency: currency)
                                        HStack {
                                            Text(grp.label).font(.system(.caption, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                                            Spacer()
                                            Text(CurrencyManager.shared.formatted(dayTotal, currency: currencyCode)).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.red.opacity(0.7))
                                        }.padding(.horizontal, 22)
                                        VStack(spacing: 0) {
                                            ForEach(grp.txs) { tx in
                                                let converted = CurrencyManager.shared.convert(abs(tx.amount), from: tx.currency, to: currency)
                                                HStack(spacing: 14) {
                                                    ZStack {
                                                        RoundedRectangle(cornerRadius: AppRadius.sm).fill(tx.displayIconBg).frame(width: 44, height: 44)
                                                        Text(tx.icon).font(.system(size: tx.icon.count == 1 ? 16 : 20)).foregroundStyle(.white)
                                                    }
                                                    VStack(alignment: .leading, spacing: 3) {
                                                        Text(tx.name).font(.system(.subheadline, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                                                        HStack(spacing: 6) {
                                                            Text(tx.date.formatted(date: .omitted, time: .shortened)).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                                            Text(tx.category.displayLabel).font(.system(.caption2, weight: .semibold)).foregroundStyle(tx.category.color)
                                                                .padding(.horizontal, 7).padding(.vertical, 2).background(tx.category.color.opacity(0.12), in: Capsule())
                                                        }
                                                    }
                                                    Spacer()
                                                    VStack(alignment: .trailing, spacing: 2) {
                                                        Text(BudgetGroupMath.amountLabel(tx)).font(.system(.subheadline, weight: .semibold)).foregroundStyle(BudgetGroupMath.isRefund(tx) ? AppTheme.accent : AppTheme.textPrimary)
                                                        if tx.currency.uppercased() != currencyCode.uppercased() {
                                                            Text("≈ \(CurrencyManager.shared.formatted(converted, currency: currencyCode))").font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                                        }
                                                        // Per-transaction "% of income" removed — a single tx is a
                                                        // tiny fraction of monthly income, so it always rounded to
                                                        // "0% of income" and just looked broken. The category
                                                        // breakdown above already shows a meaningful % of income.
                                                    }
                                                }
                                                .padding(.horizontal, 16).padding(.vertical, 12)
                                                if tx.id != grp.txs.last?.id { Divider().background(AppTheme.cardMid).padding(.horizontal, 16) }
                                            }
                                        }
                                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md)).padding(.horizontal, 22)
                                    }
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(AppTheme.textSecondary)
                            Text(loc("budget.no_spending")).font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                        }.padding(.top, 32)
                    }
                    Spacer(minLength: 40)
                }.padding(.top, 16)
                .containerRelativeFrame(.horizontal)
            }
        }
        .navigationTitle(group.label).navigationBarTitleDisplayMode(.large)
        .toolbarBackground(AppTheme.bg, for: .navigationBar)
    }
}


// MARK: - Group arithmetic, one rule

/// What a budget group took over a window, under the rule Statistics uses:
/// outflows count, a refund gives its amount back, transfers are money moving
/// between your own accounts. The card and its detail screen each summed only
/// outflows, so a refunded purchase stayed in "Wants" while Statistics had
/// already taken it out.
enum BudgetGroupMath {
    /// The group's rows from `start` on — outflows and refunds — newest first.
    static func rows(_ group: BudgetGroup, in txs: [TxRecord], from start: Date) -> [TxRecord] {
        let cats = Set(SmartBudgetManager.shared.categories(for: group))
        return txs.filter { (tx: TxRecord) -> Bool in
            guard tx.date >= start, tx.txSubtype != TxSubtype.transfer, cats.contains(tx.category) else { return false }
            return tx.amount < 0 || tx.txSubtype == TxSubtype.refund
        }
        .sorted { $0.date > $1.date }
    }

    /// Outflows less refunds, in `currency`, never below zero.
    static func spent(_ rows: [TxRecord], currency: String) -> Double {
        let cm = CurrencyManager.shared
        let net = rows.reduce(0.0) { (sum: Double, tx: TxRecord) -> Double in
            let amt = cm.convert(abs(tx.amount), from: tx.currency.isEmpty ? currency : tx.currency, to: currency)
            if tx.txSubtype == TxSubtype.refund { return sum - amt }
            return tx.amount < 0 ? sum + amt : sum
        }
        return max(net, 0)
    }

    /// A row's amount as listed: a refund shows what came back, with "+".
    static func amountLabel(_ tx: TxRecord) -> String {
        let text = CurrencyManager.shared.formatted(abs(tx.amount), currency: tx.currency)
        return tx.txSubtype == TxSubtype.refund ? "+" + text : text
    }

    static func isRefund(_ tx: TxRecord) -> Bool { tx.txSubtype == TxSubtype.refund }
}
