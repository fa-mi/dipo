import SwiftUI
import SwiftData

// MARK: - Statistics View

struct StatisticsView: View {
    @State var statsVM: StatsViewModel
    @Bindable var appVM: AppViewModel

    /// Written out rather than synthesized: the stored properties are no longer
    /// private (the extensions in DiPo/StatisticsView+*.swift need them), and
    /// a synthesized memberwise init would change shape with them. This keeps
    /// `StatisticsView(statsVM:appVM:)` exactly as it was.
    init(statsVM: StatsViewModel, appVM: AppViewModel) {
        _statsVM = State(wrappedValue: statsVM)
        _appVM = Bindable(wrappedValue: appVM)
    }
    @Query var cardBudgetConfigs: [CardBudgetConfig]
    @Query(sort: \SalarySchedule.createdAt) var salarySchedules: [SalarySchedule]
    @Query var recurringPlans: [RecurringExpense]
    @Query var savingsGoals: [SavingsGoal]
    /// The days the user answered as spend-free. Without them a week's quiet
    /// days cannot be told from its unrecorded ones.
    @Query var checkIns: [DayCheckIn]
    @State var selectedPeriod: StatPeriod = .thisMonth
    /// Held in @State so SwiftUI observes plan changes; reading
    /// `PremiumManager.shared` inline inside `body` registers no dependency,
    /// leaving a user who just upgraded stuck behind the blur until they
    /// navigate away and back.
    @State var premiumMgr = PremiumManager.shared
    /// Guards the one-time "default to pay cycle" so it can't override a manual
    /// period choice on later re-appears.
    @State var didDefaultPeriod = false
    // Memoized heavy derivations. `filteredTx` was recomputed by EVERY derived
    // property (income, expenses, weekly avg, categories, list) — the date
    // filter ran ~6× per render. `netWorthTrend` scans all tx across 6 buckets.
    // We now compute both once, only when inputs change (see recomputeStats).
    @State var cachedFilteredTx: [TxRecord] = []
    @State var cachedRhythm = SpendingRhythm(history: []) { _ in 0 }
    @State var cachedFigures = SpendingFigures()
    @State var cachedNetWorthTrend: [CycleTrendPoint] = []
    @State var customStart: Date = Calendar.current.safeDate(byAdding: .month, value: -1, to: Date())
    @State var customEnd: Date = Date()
    @State var showCustomPicker = false
    @State var selectedCardID: String? = nil // Kept only as a recompute trigger; the card itself comes from MainCard.
    /// Observed so switching the main card in the Wallet redraws this screen.
    @State var sb = SmartBudgetManager.shared
    @State var showExportSheet = false
    @State var showAllCategories = false
    /// The card whose balance is being matched to the bank, from the cash
    /// book's negative-opening hint.
    @State var matchBalanceCard: BankCard? = nil
    /// The slice picked in the ring. Held here rather than inside the chart so
    /// the figure beside it can follow the same choice.
    @State var donutSelection: String? = nil
    /// Which day of the Weekly page is open, and which of its rows was tapped.
    @State var expandedDay: Date? = nil
    /// Category filter on the cycle page. Cleared whenever a different cycle opens.
    /// `others` is the tail below the top four, kept as its own case so the chips
    /// stay a single row and the totals still reconcile: all = top four + others.
    enum CycleFilter: Hashable {
        case all
        case category(TxCategory)
        case others
    }
    @State var cycleFilter: CycleFilter = .all
    @State var weekFilter: CycleFilter = .all

    // MARK: - Layout
    //
    // The screen answers four questions, in the order a person asks them, and
    // nothing else: how much has gone out and am I fine, where did it go, what
    // is worth knowing, and is this more than usual. It used to stack nine
    // cards — a cash-flow card, a net card with a balance reconciliation, a net
    // trend, commitments priced in goal-time, a weekly-rate card with an audit,
    // a donut, patterns — which were each right and together unreadable. The
    // working behind the numbers moved one tap away, to Full analysis.

    /// Top categories shown before "Show all".
    static let categoryPreview = 5
    func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: displayCurrency)
    }

    var body: some View {
        NavigationStack(path: $appVM.statsPath) {
            mainPage
                .navigationTitle(loc("stats.title"))
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: StatsRoute.self) { route in
                    switch route {
                    case .analysis: fullAnalysis
                    case .weekly:   weeklyDetail
                    case .trends:   trendsDetail
                    case .cycle(let s, let e, let label):
                        cycleDetail(start: s, end: e, label: label)
                    }
                }
        }
        .onAppear {
            statsVM.animateIn()
            // Default the period to the pay cycle (payday → today) when the
            // user has a salary schedule — their financial month runs from
            // payday, not the calendar 1st. One-time so it never overrides a
            // manual choice.
            if !didDefaultPeriod {
                didDefaultPeriod = true
                if payCycleDay != nil { selectedPeriod = .payCycle }
            }
            selectedCardID = MainCard.reconcile(cards: appVM.cards)?.id.uuidString
            recomputeStats()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                statsVM.categories = realCategories
            }
        }
        // Re-running reconcile when activity first appears catches a first card
        // added after this tab mounted — otherwise the screen reports Rp 0 with
        // the data sitting right there. Keyed by `count` so it doesn't churn.
        .onChange(of: cardsWithActivity.count) { _, _ in
            selectedCardID = MainCard.reconcile(cards: appVM.cards)?.id.uuidString
        }
        .onChange(of: sb.budgetCardID) { _, newID in
            selectedCardID = newID
        }
        .trackScreen(.statistics)
        .onChange(of: statsVM.selectedStatTab) { _, _ in
            statsVM.selectedSliceIndex = nil
            showAllCategories = false
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: selectedPeriod) { _, _ in
            statsVM.selectedSliceIndex = nil
            selectedCardID = MainCard.reconcile(cards: appVM.cards)?.id.uuidString
            recomputeStats()
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: selectedCardID) { _, _ in
            statsVM.selectedSliceIndex = nil
            recomputeStats()
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: customStart) { _, _ in
            recomputeStats()
            withAnimation { statsVM.categories = realCategories }
        }
        .onChange(of: customEnd) { _, _ in
            recomputeStats()
            withAnimation { statsVM.categories = realCategories }
        }
        // A tx added/removed anywhere → refresh the memoized derivations.
        .onChange(of: statTxCount) { _, _ in
            recomputeStats()
            withAnimation { statsVM.categories = realCategories }
        }
        .sheet(item: $matchBalanceCard) { card in
            MatchBalanceSheet(card: card)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
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
                budgetIncome: budgetInsightIncome,
                expenses: filteredExpenses,
                // The typical week is a Royal note, so it is withheld from the
                // export itself, not just hidden in the layout. Categories are
                // on the free screen, so they travel for everyone.
                weeklyAverage: premiumMgr.canAccess(.smartBudget) ? weeklyAverage : 0,
                topCategories: topCategories,
                transactions: filteredTx,
                currency: displayCurrency,
                configs: cardBudgetConfigs,
                previousExpenses: previousPeriodExpenses
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.bg)
            .preferredColorScheme(appColorScheme())
        }
    }

}

// MARK: - Mini bar chart
//
// Seven-ish bars with their labels — the shape of a week or of the months, at
// tile size. The tallest bar (or the current one) is the only one at full
// strength, so the eye lands on the answer rather than reading every column.

struct MiniBars: View {
    let values: [Double]
    let labels: [String]
    let tint: Color
    var highlightLast: Bool = false
    var height: CGFloat = 36
    /// Capped so a chart with only three bars draws bars, not lozenges.
    var maxBarWidth: CGFloat = 22

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        let hotIndex = highlightLast
            ? values.count - 1
            : (values.firstIndex(of: values.max() ?? 0) ?? -1)
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(i == hotIndex ? tint : tint.opacity(0.28))
                        // A floor of 3pt so an empty day still reads as a day.
                        .frame(height: max(CGFloat(v / peak) * height, 3))
                        .frame(maxWidth: maxBarWidth)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack(spacing: 4) {
                ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
                    Text(l)
                        .font(.system(size: 9, weight: i == hotIndex ? .bold : .medium))
                        .foregroundStyle(i == hotIndex ? AppTheme.textPrimary
                                                       : AppTheme.textSecondary.opacity(0.8))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
