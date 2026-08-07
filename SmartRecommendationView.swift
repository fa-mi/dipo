import SwiftUI
import SwiftData

// MARK: - Smart Recommendation View
//
// The "DiPo recommends a smarter way for you" confirmation screen. It runs the
// SmartRecommendationEngine over the user's real transactions and presents a
// Smart Score, three health ratings, the top actionable recommendations, and a
// one-tap "Apply" that writes the suggested budget split. Honest about data:
// with little history it shows a "preliminary" banner instead of pretending.

struct SmartRecommendationView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @Query(sort: \SalarySchedule.createdAt) private var salaries: [SalarySchedule]
    @Query private var goals: [SavingsGoal]
    @Query private var debts: [DebtRecord]
    @Query private var recurringExpenses: [RecurringExpense]
    @Query private var cardBudgetConfigs: [CardBudgetConfig]
    @Query private var cycleIntents: [CycleIntent]
    @Environment(\.modelContext) private var context

    /// Called after the user taps "Apply" so the parent can refresh its state.
    var onApply: () -> Void = {}

    @State private var appeared = false
    @State private var animatedScore: Int = 0
    @State private var detailReco: SmartRecommendation? = nil
    @State private var scoreDetail: SmartRecommendation? = nil
    @State private var showBriefing = false
    @State private var showIntents = false

    /// Entry to the cross-feature "advisor" analysis (transactions + debts +
    /// credit cards + goals + recurring, with the WHY spelled out).
    private var deepAnalysisButton: some View {
        Button {
            HapticManager.shared.tap(); showBriefing = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("brief.title")).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    Text(loc("brief.entry_sub")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
            }
            .padding(14)
            .background(AppTheme.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.purple.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    /// Entry to declaring deliberate choices. Shows what's already respected,
    /// so the user can see the engine isn't judging them for it.
    private func intentButton(_ r: SmartRecommendation) -> some View {
        Button {
            HapticManager.shared.tap(); showIntents = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: r.declaredIntents.isEmpty ? "hand.raised.fill" : "checkmark.seal.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(r.declaredIntents.isEmpty ? AppTheme.blue : AppTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc(r.declaredIntents.isEmpty ? "reco.intent_cta" : "reco.intent_active"))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    Text(r.declaredIntents.isEmpty
                         ? loc("reco.intent_cta_sub")
                         : r.declaredIntents.map(\.label).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(14)
            .background((r.declaredIntents.isEmpty ? AppTheme.blue : AppTheme.accent).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke((r.declaredIntents.isEmpty ? AppTheme.blue : AppTheme.accent).opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private var currency: String { CurrencyManager.shared.preferredCurrency }

    /// Best-known monthly income: active salary schedules, else derived from
    /// this history's positive (non-transfer) transactions.
    private var monthlyIncome: Double {
        let cm = CurrencyManager.shared
        let active = salaries.filter { $0.isActive }
        if !active.isEmpty {
            return active.reduce(0.0) { $0 + cm.convert($1.amount, from: $1.currency, to: currency) }
        }
        let months = max(SmartBudgetManager.shared.dataMonthsAvailable(allTransactions: allTx), 1)
        let inc = allTx.filter { $0.amount > 0 && $0.txSubtype != .transfer }
            .reduce(0.0) { $0 + cm.convert($1.amount, from: $1.currency.isEmpty ? currency : $1.currency, to: currency) }
        return inc / Double(months)
    }

    private var allTx: [TxRecord] { cards.flatMap { $0.transactions } }

    /// Start of the cycle the score describes (the last complete one when the
    /// current cycle is only days old — matching `currentCycleSnapshot`).
    private var judgedCycleStart: Date {
        let cal = Calendar.current
        let now = Date()
        guard let day = salaries.first(where: { $0.isActive })?.dayOfMonth else {
            return cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        }
        let current = StatPeriod.payCycleRange(payDay: day).start
        let elapsed = cal.dateComponents([.day], from: current, to: now).day ?? 0
        if elapsed < 7, let dayBefore = cal.date(byAdding: .day, value: -1, to: current) {
            return StatPeriod.payCycleRange(payDay: day, now: dayBefore).start
        }
        return current
    }
    private var judgedCycleKey: String { ISO8601DateFormatter.dayString(from: judgedCycleStart) }
    private var activeIntents: CycleIntentSet {
        CycleIntentSet.resolve(cycleIntents, cycleKey: judgedCycleKey)
    }

    /// Current pay-cycle actuals per budget group — so the score/ratings reflect
    /// the same reality as the Smart Budget screen (over budget = not "Great").
    private var currentCycleSnapshot: RecoCycleSnapshot? {
        guard monthlyIncome > 0 else { return nil }
        let cal = Calendar.current
        let now = Date()

        // Which cycle should the SCORE judge? The current one is right until it's
        // barely begun: on payday the fresh cycle has ~zero spending, which would
        // score a false "Great 92" and forget that LAST cycle went over budget.
        // So while the current cycle is too young to be representative (< 7 days
        // in), judge on the LAST COMPLETE cycle instead — that's the real recent
        // habit the user is asking about.
        let payDay = salaries.first(where: { $0.isActive })?.dayOfMonth
        var start: Date
        var end: Date = now
        if let day = payDay {
            let current = StatPeriod.payCycleRange(payDay: day).start
            let elapsed = cal.dateComponents([.day], from: current, to: now).day ?? 0
            if elapsed < 7,
               let dayBefore = cal.date(byAdding: .day, value: -1, to: current) {
                // Previous complete cycle: [prevStart, currentStart).
                start = StatPeriod.payCycleRange(payDay: day, now: dayBefore).start
                end = current
            } else {
                start = current
            }
        } else {
            start = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        }

        // Scope to the SAME transactions the Smart Budget screen measures: when a
        // main budget card is set it counts only that card, so scoring across all
        // cards would let the score contradict the budget screen it mirrors.
        let scopedTx: [TxRecord] = {
            if let id = SmartBudgetManager.shared.budgetCardID,
               let card = cards.first(where: { $0.id.uuidString == id }) {
                return card.transactions
            }
            return allTx
        }()
        let windowTx = scopedTx.filter { $0.date >= start && $0.date < end && $0.amount < 0 && $0.txSubtype != .transfer }
        let mgr = SmartBudgetManager.shared
        // `periodStart` is required: without it `spent()` re-filters to the
        // calendar month and would clip the earlier part of the pay cycle
        // (e.g. Jun 25–30 dropped from a Jun 25–Jul 21 cycle).
        // Biggest consumption category this cycle, with how many transactions
        // built it up — a pile of small buys reads very differently from one
        // large purchase, and that changes the advice.
        // Only VARIABLE consumption — pointing at a fixed category (rent/kos in
        // Bills) as "the biggest driver to trim" is useless advice: it's
        // contractual. The trim card should name spending the user can change.
        let consumptionCats = Set(mgr.categories(for: .daily) + mgr.categories(for: .lifestyle))
            .filter { !SmartBudgetManager.isFixedCategory($0) }
        var byCat: [TxCategory: (total: Double, count: Int)] = [:]
        for tx in windowTx where consumptionCats.contains(tx.category) {
            let amt = CurrencyManager.shared.convert(abs(tx.amount),
                                                     from: tx.currency.isEmpty ? currency : tx.currency,
                                                     to: currency)
            let cur = byCat[tx.category] ?? (0, 0)
            byCat[tx.category] = (cur.total + amt, cur.count + 1)
        }
        let top = byCat.max { $0.value.total < $1.value.total }

        // Money moved into savings goals this cycle — direct evidence of a
        // saving habit, independent of how much income happened to be left.
        let savingsDeposits = windowTx
            .filter { !$0.linkedGoalID.isEmpty && $0.amount < 0 }
            .reduce(0.0) { $0 + CurrencyManager.shared.convert(
                abs($1.amount), from: $1.currency.isEmpty ? currency : $1.currency, to: currency) }

        return RecoCycleSnapshot(
            daily:      mgr.spent(in: .daily,      transactions: windowTx, targetCurrency: currency, periodStart: start),
            lifestyle:  mgr.spent(in: .lifestyle,  transactions: windowTx, targetCurrency: currency, periodStart: start),
            investDebt: mgr.spent(in: .investDebt, transactions: windowTx, targetCurrency: currency, periodStart: start),
            savingsDeposits: savingsDeposits,
            income:     monthlyIncome,
            topCategory:       top?.key.displayLabel,
            topCategoryAmount: top?.value.total ?? 0,
            topCategoryCount:  top?.value.count ?? 0)
    }

    /// Active declared commitments (Monthly Expenses), normalised to the
    /// preferred currency, largest first — the exact fixed costs the user set up.
    private var activeRecurring: [(label: String, amount: Double)] {
        recurringExpenses.filter { $0.isActive }
            .map { ($0.label, CurrencyManager.shared.convert($0.amount, from: $0.currency, to: currency)) }
            .sorted { $0.amount > $1.amount }
    }

    /// Total owed across credit-card accounts + an estimated 10% minimum
    /// payment (typical Indonesian CC minimum) — folded into the debt picture.
    private var creditCardOwed: Double {
        cards.filter { $0.isCreditCard }
            .reduce(0.0) { $0 + CurrencyManager.shared.convert($1.owedBalance(), from: $1.resolvedCurrency, to: currency) }
    }

    private var reco: SmartRecommendation {
        SmartRecommendationEngine.analyze(
            transactions: allTx, monthlyIncome: monthlyIncome,
            goals: goals, debts: debts, currency: currency,
            currentCycle: currentCycleSnapshot,
            recurringMonthly: activeRecurring.reduce(0) { $0 + $1.amount },
            recurringLabels: activeRecurring.map(\.label),
            creditCardOwed: creditCardOwed,
            creditCardMinPayment: creditCardOwed * 0.10,
            salaryDayOfMonth: salaries.first(where: { $0.isActive })?.dayOfMonth,
            recurrings: recurringExpenses,
            intents: activeIntents)
    }

    var body: some View {
        let r = reco
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    header
                    titleBlock(r)
                    scoreCard(r)
                    analyzedBanner(r)
                    deepAnalysisButton
                    intentButton(r)
                    recommendationsSection(r)
                    if !r.reasons.isEmpty { whySection(r) }
                    privacyNote
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { appeared = true }
            // Count the score up on first display.
            let target = r.smartScore
            withAnimation(.easeOut(duration: 1.0)) { animatedScore = target }
        }
        .sheet(isPresented: $showIntents) {
            CycleIntentView(cycleKey: judgedCycleKey, cycleLabel: reco.periodLabel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showBriefing) {
            FinancialBriefingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(item: $scoreDetail) { snapshot in
            ScoreDetailSheet(reco: snapshot, tint: scoreTint(snapshot.smartScore),
                             details: metricDetails(snapshot))
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(item: $detailReco) { snapshot in
            SmartRecommendationDetailView(reco: snapshot)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { HapticManager.shared.tap(); dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 36, height: 36).background(AppTheme.cardDark, in: Circle())
            }
            Spacer()
            Text(loc("profile.budget")).font(.system(size: 16, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.system(size: 9, weight: .bold))
                Text(loc("reco.ai_powered")).font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(AppTheme.purple)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(AppTheme.purple.opacity(0.12), in: Capsule())
            Spacer()
            Color.clear.frame(width: 36, height: 36) // balances the back button
        }
    }

    private func titleBlock(_ r: SmartRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc("reco.title"))
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(r.isPreliminary
                 ? loc("reco.subtitle_preliminary")
                 : String(format: loc(r.dataMonths == 1 ? "reco.subtitle_one" : "reco.subtitle"), r.dataMonths))
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
            // Exact analysis window, pay-cycle aligned — the user should never
            // wonder WHICH month of their life these numbers describe.
            if !r.periodLabel.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "calendar").font(.system(size: 10, weight: .semibold))
                    Text(r.periodLabel).font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(AppTheme.purple)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(AppTheme.purple.opacity(0.12), in: Capsule())
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Score card

    /// Ring/label colour must MATCH the score. A 34 drawn in the same green as
    /// a 92 tells the user they're fine when they aren't.
    private func scoreTint(_ score: Int) -> Color {
        switch score {
        case 80...:   return AppTheme.accent
        case 60..<80: return AppTheme.blue
        case 40..<60: return AppTheme.orange
        default:      return AppTheme.red
        }
    }

    private func scoreCard(_ r: SmartRecommendation) -> some View {
        let tint = scoreTint(r.smartScore)
        return HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().stroke(AppTheme.cardMid, lineWidth: 9)
                Circle()
                    .trim(from: 0, to: appeared ? CGFloat(r.smartScore) / 100 : 0)
                    .stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 1.0, dampingFraction: 0.85), value: appeared)
                VStack(spacing: 0) {
                    Text("\(animatedScore)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                        .contentTransition(.numericText())
                        .monospacedDigit()          // digits never shift the centre
                    Text(loc("reco.score_label"))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .textCase(.uppercase)
                        .kerning(0.4)
                }
            }
            // Fixed square: the ring is the visual anchor, so its size must not
            // depend on the label text inside it.
            .frame(width: 104, height: 104)

            VStack(alignment: .leading, spacing: 0) {
                // Verdict lives OUTSIDE the ring — inside, a long label like
                // "Perlu perbaikan" wrapped and pushed the number off-centre.
                HStack(spacing: 6) {
                    Text(r.scoreLabel)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tint)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.bottom, 10)

                // Short labels: the full names ("Kebiasaan Menabung") could not
                // fit beside a verdict without truncating, so the compact card
                // shows the short form and the tap target explains the rest.
                ForEach(Array(metricDetails(r).enumerated()), id: \.element.id) { idx, m in
                    if idx > 0 {
                        Divider().background(AppTheme.cardMid.opacity(0.6)).padding(.vertical, 7)
                    }
                    metricRow(m)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppTheme.cardMid.opacity(0.5), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture {
            HapticManager.shared.tap()
            scoreDetail = r
        }
        .accessibilityHint(loc("reco.tap_for_detail"))
    }

    /// Engine-provided explanations, with a fallback for recommendations built
    /// before `metricDetails` existed so the card never renders empty.
    private func metricDetails(_ r: SmartRecommendation) -> [RecoMetricDetail] {
        guard r.metricDetails.isEmpty else { return r.metricDetails }
        return [
            RecoMetricDetail(icon: "waveform.path.ecg", shortLabel: loc("reco.metric.balance_short"),
                             fullLabel: loc("reco.metric.balance"), rating: r.spendingBalance,
                             measured: "", explanation: ""),
            RecoMetricDetail(icon: "lock.fill", shortLabel: loc("reco.metric.saving_short"),
                             fullLabel: loc("reco.metric.saving"), rating: r.savingHabit,
                             measured: "", explanation: ""),
            RecoMetricDetail(icon: "chart.line.uptrend.xyaxis", shortLabel: loc("reco.metric.invest_short"),
                             fullLabel: loc("reco.metric.invest"), rating: r.investmentPotential,
                             measured: "", explanation: ""),
        ]
    }

    /// One health metric: short label left, verdict right. Both fit on a single
    /// line at full size now that the labels are short, so nothing truncates.
    private func metricRow(_ m: RecoMetricDetail) -> some View {
        HStack(spacing: 8) {
            Image(systemName: m.icon)
                .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                .frame(width: 16, alignment: .center)
            Text(m.shortLabel)
                .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(m.rating.label)
                .font(.system(size: 12, weight: .bold)).foregroundStyle(m.rating.color)
                .lineLimit(1)
        }
        .frame(height: 18)
    }

    // MARK: Analyzed banner

    private func analyzedBanner(_ r: SmartRecommendation) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(r.isPreliminary
                     ? loc("reco.analyzed_preliminary")
                     : String(format: loc("reco.analyzed"), r.transactionsAnalyzed))
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ConfidenceBadge(confidence: r.confidence)
            }
            Spacer(minLength: 0)
            Image(systemName: "brain.head.profile")
                .font(.system(size: 26)).foregroundStyle(AppTheme.purple)
        }
        .padding(14)
        .background(AppTheme.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Recommendations

    private func recommendationsSection(_ r: SmartRecommendation) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text(loc("reco.top_recommendations")).font(.system(size: 15, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Button {
                    HapticManager.shared.tap()
                    detailReco = r
                } label: {
                    HStack(spacing: 3) {
                        Text(loc("reco.view_details")).font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.purple)
                }
            }
            ForEach(r.topItems) { item in
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11).fill(item.tint.opacity(0.15)).frame(width: 40, height: 40)
                        Image(systemName: item.icon).font(.system(size: 16)).foregroundStyle(item.tint)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.subtitle).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Text(item.badge)
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(item.badgeTint)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(item.badgeTint.opacity(0.12), in: Capsule())
                }
                .padding(12)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.cardMid.opacity(0.4), lineWidth: 1))
            }

            // What "Apply" will actually set — the recommended split, visible
            // BEFORE the button instead of silently written after the tap.
            ratioPreview(r)

            // Apply / Customize
            Button {
                HapticManager.shared.success()
                apply(r)
            } label: {
                Text(loc("reco.apply"))
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(
                        LinearGradient(colors: [AppTheme.purple, AppTheme.purple.opacity(0.75)],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: AppTheme.purple.opacity(0.35), radius: 12, y: 6)
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.top, 4)

            Button {
                HapticManager.shared.tap(); dismiss()
            } label: {
                Text(loc("reco.customize"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.purple)
            }
        }
    }

    /// The recommended daily/lifestyle/invest-debt split as a segmented bar
    /// with per-bucket % and Rp amounts. This is exactly what Apply writes.
    private func ratioPreview(_ r: SmartRecommendation) -> some View {
        let cm = CurrencyManager.shared
        let buckets: [(String, Double, Color)] = [
            (loc("brief.alloc.daily"),      r.recommendedRatios.daily,      AppTheme.accent),
            (loc("brief.alloc.lifestyle"),  r.recommendedRatios.lifestyle,  AppTheme.orange),
            (loc("brief.alloc.investdebt"), r.recommendedRatios.investDebt, AppTheme.purple),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text(loc("reco.split_header"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { _, b in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(b.2.opacity(0.85))
                            .frame(width: max(geo.size.width * b.1 - 3, 8))
                    }
                }
            }
            .frame(height: 10)
            VStack(spacing: 6) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { _, b in
                    HStack(spacing: 8) {
                        Circle().fill(b.2).frame(width: 7, height: 7)
                        Text(b.0).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                        Spacer()
                        Text("\(Int((b.1 * 100).rounded()))%")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(b.2)
                        if r.monthlyIncome > 0 {
                            Text(cm.formatted(r.monthlyIncome * b.1, currency: r.currency))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(minWidth: 86, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.cardMid.opacity(0.4), lineWidth: 1))
        .padding(.top, 4)
    }

    private func whySection(_ r: SmartRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc("reco.why_title")).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
            ForEach(Array(r.reasons.enumerated()), id: \.offset) { _, reason in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkle").font(.system(size: 11)).foregroundStyle(AppTheme.purple).padding(.top, 2)
                    Text(reason).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
    }

    private var privacyNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill").font(.system(size: 16)).foregroundStyle(AppTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("reco.privacy_title")).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Text(loc("reco.privacy_body")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Apply

    private func apply(_ r: SmartRecommendation) {
        let sb = SmartBudgetManager.shared
        sb.isEnabled = true
        sb.dailyRatio      = r.recommendedRatios.daily
        sb.lifestyleRatio  = r.recommendedRatios.lifestyle
        sb.investDebtRatio = r.recommendedRatios.investDebt

        // Writing only the GLOBAL ratios silently did nothing for anyone with a
        // per-card override: `ratios(forCardID:configs:)` prefers the card's
        // CardBudgetConfig, so a card still on 50/30/20 kept ignoring the plan
        // the user just accepted. Overrides that already exist must be brought
        // along, otherwise "Apply" is a no-op exactly where budgets are tracked.
        //
        // Scope: the card the budget follows when one is set (that's the card
        // this recommendation was computed against); otherwise every existing
        // override, since the plan is meant to replace them all.
        let targets: [CardBudgetConfig] = {
            if let id = sb.budgetCardID {
                return cardBudgetConfigs.filter { $0.cardID == id }
            }
            return cardBudgetConfigs
        }()
        for cfg in targets {
            cfg.dailyRatio      = r.recommendedRatios.daily
            cfg.lifestyleRatio  = r.recommendedRatios.lifestyle
            cfg.investDebtRatio = r.recommendedRatios.investDebt
            cfg.updatedAt = .now
        }
        // A tracked card with no override yet needs one, or the global ratios
        // would apply today and be overwritten the moment the user opens
        // per-card settings and saves.
        if let id = sb.budgetCardID, targets.isEmpty {
            context.insert(CardBudgetConfig(cardID: id,
                                            dailyRatio: r.recommendedRatios.daily,
                                            lifestyleRatio: r.recommendedRatios.lifestyle,
                                            investDebtRatio: r.recommendedRatios.investDebt))
        }
        try? context.save()

        onApply()
        dismiss()
    }
}

/// Small confidence chip reused on the analyzed banner.
struct ConfidenceBadge: View {
    let confidence: InsightConfidence
    private var text: String {
        switch confidence {
        case .high:   return loc("reco.confidence.high")
        case .medium: return loc("reco.confidence.medium")
        case .low:    return loc("reco.confidence.low")
        }
    }
    private var tint: Color {
        switch confidence {
        case .high:   return AppTheme.accent
        case .medium: return AppTheme.blue
        case .low:    return AppTheme.orange
        }
    }
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle.fill").font(.system(size: 8))
            Text(text).font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Score Detail Sheet
//
// Answers the question the compact card can't: WHY is a metric "Weak"? Each
// row shows the full label, the verdict, the measured figure it came from, and
// what would move it. Opened by tapping the score card.
struct ScoreDetailSheet: View {
    let reco: SmartRecommendation
    let tint: Color
    let details: [RecoMetricDetail]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                // Centred header with real breathing room. The side-by-side
                // version put the ring under the sheet's drag indicator, so it
                // read as clipped and cramped the title beside it.
                VStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(AppTheme.cardMid, lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: CGFloat(reco.smartScore) / 100)
                            .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text("\(reco.smartScore)")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.textPrimary)
                                .monospacedDigit()
                            Text(reco.scoreLabel)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(tint)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .padding(.horizontal, 6)
                        }
                    }
                    .frame(width: 96, height: 96)

                    VStack(spacing: 5) {
                        Text(loc("reco.score_detail_title"))
                            .font(.system(size: 19, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                        Text(loc("reco.score_detail_sub"))
                            .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if !reco.periodLabel.isEmpty {
                            Text(reco.periodLabel)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.purple)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(AppTheme.purple.opacity(0.12), in: Capsule())
                                .padding(.top, 2)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
                .padding(.bottom, 6)

                ForEach(details) { m in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Image(systemName: m.icon)
                                .font(.system(size: 13)).foregroundStyle(m.rating.color)
                                .frame(width: 18)
                            // Full label here — the sheet has the width the
                            // compact card doesn't.
                            Text(m.fullLabel)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(m.rating.label)
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(m.rating.color)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(m.rating.color.opacity(0.13), in: Capsule())
                        }
                        if !m.measured.isEmpty {
                            Text(m.measured)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppTheme.textPrimary.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !m.explanation.isEmpty {
                            Text(m.explanation)
                                .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18)
                        .stroke(m.rating.color.opacity(0.22), lineWidth: 1))
                }

                Text(loc("brief.disclaimer"))
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 20)
        }
        .background(AppTheme.bg)
    }
}
