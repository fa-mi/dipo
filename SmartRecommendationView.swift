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

    /// The analysis, computed once and held.
    ///
    /// `body` used to call the engine directly — and `integrityFindings` and
    /// `windfallReview` twice each — so every redraw (a score count-up tick, a
    /// row expanding) re-ran the full analysis over the whole history. It is
    /// recomputed only when its inputs change: on appear, and after the user
    /// marks planned spending.
    @State private var analysis: SmartRecommendation? = nil
    @State private var findings: [IntegrityFinding] = []
    @State private var windfall: WindfallReview? = nil

    private func refresh() {
        let r = reco
        analysis = r
        findings = integrityFindings
        windfall = windfallReview
        withAnimation(.easeOut(duration: 1.0)) { animatedScore = r.smartScore }
    }

    private var currency: String { CurrencyManager.shared.preferredCurrency }

    /// Best-known monthly income: active salary schedules, else derived from
    /// this history's positive (non-transfer) transactions.
    /// Average monthly income across the analysed history — everything that
    /// actually arrived, not just the salary line.
    ///
    /// This drove "Where you stand", and taking the schedule alone is what
    /// produced "you spent Rp 18,8jt against Rp 10jt of income, −Rp 8,8jt". Over
    /// the same two cycles Rp 39,15jt actually came in, so the real figure was
    /// +Rp 760k. A verdict on a period that has already happened has to count
    /// the money that was there; a bonus you received and spent is not a deficit.
    ///
    /// The salary schedule stays as a FLOOR, so a stretch with no logged income
    /// yet doesn't collapse the denominator.
    /// The income every ratio on this screen is built from.
    ///
    /// This used to be `max(averagedLogged, scheduled)`, and both halves of
    /// that were wrong.
    ///
    /// The `max` meant a single good month decided the plan. On this user's
    /// data one bonus month of Rp 26.750.000 lifted the mean to Rp 25.157.692
    /// against a Rp 10.000.000 salary, so the screen recommended a lifestyle
    /// budget of Rp 8.601.317 a month — money that does not arrive again. A
    /// plan built on income you received once is not a plan.
    ///
    /// So: a salary schedule IS the income when one exists. That is what a
    /// schedule means — the amount that recurs. Logged income includes
    /// everything that does not.
    ///
    /// Without a schedule there is no declaration to trust, so it falls back to
    /// what was actually received — but by the MEDIAN month rather than the
    /// mean, because the whole point is to not let one windfall set the
    /// baseline. Median of these months is Rp 13.115.000 where the mean is
    /// Rp 25.157.692.
    private var monthlyIncome: Double {
        let cm = CurrencyManager.shared
        let scheduled = MainCard.salaries(salaries)
            .reduce(0.0) { $0 + cm.convert($1.amount, from: $1.currency, to: currency) }
        if scheduled > 0 { return scheduled }

        let cal = Calendar.current
        var byMonth: [DateComponents: Double] = [:]
        for tx in allTx where tx.amount > 0 && tx.txSubtype != .transfer {
            let key = cal.dateComponents([.year, .month], from: tx.date)
            byMonth[key, default: 0] += cm.convert(
                tx.amount, from: tx.currency.isEmpty ? currency : tx.currency, to: currency)
        }
        let months = byMonth.values.sorted()
        guard !months.isEmpty else { return 0 }
        let mid = months.count / 2
        return months.count % 2 == 0 ? (months[mid - 1] + months[mid]) / 2 : months[mid]
    }

    /// Scoped to the main card, like every other figure in the app. This screen
    /// was still summing all nine accounts.
    private var allTx: [TxRecord] {
        MainCard.resolve(in: cards)?.transactions ?? cards.flatMap { $0.transactions }
    }

    /// Records whose shape suggests they don't describe what actually happened.
    /// Every ratio on this screen is built from them, so the caveat belongs
    /// here rather than buried in a settings screen.
    /// What happened to income beyond the salary in the judged cycle — the
    /// question a cash-flow line cannot answer.
    private var windfallReview: WindfallReview? {
        let cal = Calendar.current
        let start = judgedCycleStart
        let end = cal.safeDate(byAdding: .month, value: 1, to: start)
        let cycleTx = allTx.filter { $0.date >= start && $0.date < end }
        guard !cycleTx.isEmpty else { return nil }
        return WindfallReview.build(cycleTransactions: cycleTx, currency: currency)
    }

    private var integrityFindings: [IntegrityFinding] {
        DataIntegrityCheck.run(transactions: allTx, debts: debts, recurrings: recurringExpenses)
    }

    /// Start of the cycle the score describes (the last complete one when the
    /// current cycle is only days old — matching `currentCycleSnapshot`).
    /// Dates the salary actually landed, newest-relevant first.
    private var salaryTxDates: [Date] {
        allTx.filter { $0.category == .salary && $0.amount > 0 }.map(\.date)
    }

    private var judgedCycleStart: Date {
        let cal = Calendar.current
        let now = Date()
        guard let day = salaries.first(where: { $0.isActive })?.dayOfMonth else {
            return cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        }
        let current = StatPeriod.anchoredStart(StatPeriod.payCycleRange(payDay: day).start,
                                               salaryDates: salaryTxDates)
        let elapsed = cal.dateComponents([.day], from: current, to: now).day ?? 0
        if elapsed < 7, let dayBefore = cal.date(byAdding: .day, value: -1, to: current) {
            return StatPeriod.anchoredStart(StatPeriod.payCycleRange(payDay: day, now: dayBefore).start,
                                            salaryDates: salaryTxDates)
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
            let current = StatPeriod.anchoredStart(StatPeriod.payCycleRange(payDay: day).start,
                                                   salaryDates: salaryTxDates)
            let elapsed = cal.dateComponents([.day], from: current, to: now).day ?? 0
            if elapsed < 7,
               let dayBefore = cal.date(byAdding: .day, value: -1, to: current) {
                // Previous complete cycle: [prevStart, currentStart).
                start = StatPeriod.anchoredStart(StatPeriod.payCycleRange(payDay: day, now: dayBefore).start,
                                                 salaryDates: salaryTxDates)
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

        // Income ACTUALLY received in this cycle — not the salary schedule.
        //
        // The schedule was the wrong denominator for a backward-looking
        // analysis. A cycle where a bonus arrived and was partly spent got
        // measured against salary alone: living costs came out at 256% of
        // "income" and the cycle read as Rp 16,8jt overspent when the real gap
        // was Rp 9,08jt. The spending side was exact; only the denominator
        // pretended half the money never existed.
        //
        // This is deliberately the OPPOSITE call from the allocation plan in
        // Debt Tracker. That one looks FORWARD and must not raise next month's
        // budget because a bonus landed once. This looks BACKWARD at what
        // actually happened, where ignoring money that genuinely arrived is
        // simply wrong.
        //
        // `max` with the schedule keeps a mid-cycle view sane: before payday
        // lands, actual income is near zero and every ratio would explode.
        let receivedIncome = scopedTx
            .filter { $0.date >= start && $0.date < end && $0.amount > 0 && $0.txSubtype != .transfer }
            .reduce(0.0) { $0 + CurrencyManager.shared.convert(
                $1.amount, from: $1.currency.isEmpty ? currency : $1.currency, to: currency) }

        return RecoCycleSnapshot(
            daily:      mgr.spent(in: .daily,      transactions: windowTx, targetCurrency: currency, periodStart: start),
            lifestyle:  mgr.spent(in: .lifestyle,  transactions: windowTx, targetCurrency: currency, periodStart: start),
            investDebt: mgr.spent(in: .investDebt, transactions: windowTx, targetCurrency: currency, periodStart: start),
            savingsDeposits: savingsDeposits,
            income:     max(receivedIncome, monthlyIncome),
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
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            if let r = analysis {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        header
                        verdictCard(r)

                        // Right under the score, because the score is built on
                        // these records. (Both cards used to add their own 22pt
                        // on top of this stack's 20pt, so they sat visibly
                        // narrower than every other card on the screen.)
                        if !findings.isEmpty {
                            DataIntegrityCard(findings: findings)
                        }
                        if let w = windfall, w.isRelevant {
                            WindfallCard(review: w)
                        }

                        actionsSection(r)
                        planCard(r)
                        moreSection(r)
                        if !r.reasons.isEmpty { whySection(r) }
                        privacyNote
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 30)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                }
            } else {
                ProgressView().tint(AppTheme.accent)
            }
        }
        .onAppear {
            if analysis == nil { refresh() }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { appeared = true }
        }
        .onChange(of: cycleIntents.count) { _, _ in refresh() }
        .sheet(isPresented: $showIntents, onDismiss: { refresh() }) {
            CycleIntentView(cycleKey: judgedCycleKey, cycleLabel: analysis?.periodLabel ?? "")
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
        .trackScreen(.budgetRecommendation)
    }

    // MARK: Header

    /// Just the screen's name. The "AI Powered" badge and the headline "DiPo
    /// recommends a smarter way for you" filled the first screen with claims;
    /// the verdict card below says something about the user instead.
    private var header: some View {
        HStack {
            Button { HapticManager.shared.tap(); dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(.callout, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 36, height: 36).background(AppTheme.cardDark, in: Circle())
            }
            .accessibilityLabel(loc("a11y.back"))
            .hitTarget(36)
            Spacer()
            Text(loc("profile.budget"))
                .font(.system(.body, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
    }

    // MARK: Verdict

    /// Ring and verdict share one colour, and it must MATCH the score — a 27
    /// drawn in the same green as a 92 tells the user they are fine.
    private func scoreTint(_ score: Int) -> Color {
        switch score {
        case 80...:   return AppTheme.accent
        case 60..<80: return AppTheme.blue
        case 40..<60: return AppTheme.orange
        default:      return AppTheme.red
        }
    }

    /// Where the user stands, in one card: the score, the verdict in words,
    /// what it was measured on, and the three parts it is made of.
    private func verdictCard(_ r: SmartRecommendation) -> some View {
        let tint = scoreTint(r.smartScore)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(AppTheme.cardMid, lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: appeared ? CGFloat(r.smartScore) / 100 : 0)
                        .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 1.0, dampingFraction: 0.85), value: appeared)
                    VStack(spacing: -2) {
                        Text("\(animatedScore)")
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .contentTransition(.numericText())
                            .monospacedDigit()
                        Text("/100")
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 4) {
                    Text(loc("reco.score_label"))
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(r.scoreLabel)
                        .font(.system(.title2, weight: .bold))
                        .foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(r.isPreliminary
                         ? loc("reco.subtitle_preliminary")
                         : String(format: loc("reco.based_on"), r.transactionsAnalyzed))
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                ForEach(metricDetails(r)) { m in metricTile(m) }
            }

            VStack(alignment: .leading, spacing: 10) {
                if !r.periodLabel.isEmpty {
                    Label(r.periodLabel, systemImage: "calendar")
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                HStack {
                    ConfidenceBadge(confidence: r.confidence)
                    Spacer()
                    HStack(spacing: 3) {
                        Text(loc("reco.score_detail_title"))
                            .font(.system(.footnote, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(.caption2, weight: .bold)).imageScale(.small)
                    }
                    .foregroundStyle(AppTheme.textPrimary)
                }
            }
        }
        .padding(18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.xl))
        .onTapGesture {
            HapticManager.shared.tap()
            scoreDetail = r
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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

    /// One part of the score as a tile: what it is, and how it did. Three
    /// equal tiles read as three parts of one whole; the old divided list read
    /// as a table to be parsed.
    private func metricTile(_ m: RecoMetricDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: m.icon)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(m.rating.color)
            Text(m.shortLabel)
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(m.rating.label)
                .font(.system(.subheadline, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(m.rating.color.opacity(0.10), in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    // MARK: What to do

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, weight: .bold))
            .foregroundStyle(AppTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The recommendations as one list, in the engine's priority order. They
    /// were separate bordered cards, which gave four suggestions the visual
    /// weight of four unrelated alerts.
    private func actionsSection(_ r: SmartRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(loc("reco.top_recommendations"))
            VStack(spacing: 0) {
                ForEach(Array(r.topItems.enumerated()), id: \.element.id) { i, item in
                    if i > 0 {
                        Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 66)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.system(.callout, weight: .semibold))
                            .foregroundStyle(item.tint)
                            .frame(width: 40, height: 40)
                            .background(item.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(item.subtitle)
                                .font(.system(.caption))
                                .foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 6)
                        if !item.badge.isEmpty {
                            Text(item.badge)
                                .font(.system(.caption2, weight: .bold))
                                .foregroundStyle(item.badgeTint)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(item.badgeTint.opacity(0.12), in: Capsule())
                                .fixedSize()
                        }
                    }
                    .padding(14)
                }
            }
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
    }

    // MARK: Plan

    /// What "Use this plan" will set, shown before the button rather than
    /// silently written after it — and the buttons live on the same card, so
    /// the choice is made looking at what is being chosen.
    ///
    /// Bucket colours come from `BudgetGroup.color`, the same as the Smart
    /// Budget screen. This card had its own mapping (green/orange/purple) for
    /// buckets that are blue/purple/green one screen back.
    private func planCard(_ r: SmartRecommendation) -> some View {
        let cm = CurrencyManager.shared
        let buckets: [(BudgetGroup, Double)] = [
            (.daily, r.recommendedRatios.daily),
            (.lifestyle, r.recommendedRatios.lifestyle),
            (.investDebt, r.recommendedRatios.investDebt),
        ]
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle(loc("reco.split_header"))

            GeometryReader { geo in
                HStack(spacing: 4) {
                    ForEach(buckets, id: \.0.rawValue) { b in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(b.0.color)
                            .frame(width: max((geo.size.width - 8) * b.1, 8))
                    }
                }
            }
            .frame(height: 12)

            VStack(spacing: 10) {
                ForEach(buckets, id: \.0.rawValue) { b in
                    HStack(spacing: 10) {
                        Circle().fill(b.0.color).frame(width: 9, height: 9)
                        Text(b.0.label)
                            .font(.system(.subheadline))
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                        if r.monthlyIncome > 0 {
                            Text(cm.formatted(r.monthlyIncome * b.1, currency: r.currency))
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        Text("\(Int((b.1 * 100).rounded()))%")
                            .font(.system(.footnote, weight: .bold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }
            }

            VStack(spacing: 4) {
                Button {
                    HapticManager.shared.success()
                    apply(r)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").font(.system(.body))
                        Text(loc("reco.apply")).font(.system(.callout, weight: .bold))
                    }
                    .foregroundStyle(AppTheme.onVividFill)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                }
                .buttonStyle(ScaleButtonStyle())

                Button {
                    HapticManager.shared.tap(); dismiss()
                } label: {
                    Text(loc("reco.customize"))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
            }
            .padding(.top, 4)
        }
        .padding(18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }

    // MARK: More

    /// Three ways to go deeper, as one list. They were three stacked banners,
    /// each in its own colour (purple, blue or green) with its own border.
    private func moreSection(_ r: SmartRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(loc("reco.more_title"))
            VStack(spacing: 0) {
                linkRow(icon: "list.bullet.rectangle.portrait", tint: AppTheme.blue,
                        title: loc("reco.view_details"), detail: nil) {
                    detailReco = r
                }
                divider
                linkRow(icon: "text.magnifyingglass", tint: AppTheme.purple,
                        title: loc("brief.title"), detail: loc("brief.entry_sub")) {
                    showBriefing = true
                }
                divider
                linkRow(icon: r.declaredIntents.isEmpty ? "hand.raised.fill" : "checkmark.seal.fill",
                        tint: r.declaredIntents.isEmpty ? AppTheme.orange : AppTheme.accent,
                        title: loc(r.declaredIntents.isEmpty ? "reco.intent_cta" : "reco.intent_active"),
                        detail: r.declaredIntents.isEmpty
                            ? loc("reco.intent_cta_sub")
                            : r.declaredIntents.map(\.label).joined(separator: " · ")) {
                    showIntents = true
                }
            }
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
    }

    private var divider: some View {
        Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 62)
    }

    private func linkRow(icon: String, tint: Color, title: String, detail: String?,
                         action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.tap(); action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail)
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func whySection(_ r: SmartRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(loc("reco.why_title"))
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(r.reasons.enumerated()), id: \.offset) { _, reason in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(AppTheme.textSecondary.opacity(0.6)).frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 4 }
                        Text(reason)
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
    }

    /// A footnote, not a card: it reassures, it is not a feature to look at.
    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("reco.privacy_title"))
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(loc("reco.privacy_body"))
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
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

        ActionFeedbackCenter.shared.budgetApplied(
            daily: Int((r.recommendedRatios.daily * 100).rounded()),
            lifestyle: Int((r.recommendedRatios.lifestyle * 100).rounded()),
            investDebt: Int((r.recommendedRatios.investDebt * 100).rounded()))
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
            Image(systemName: "info.circle.fill").font(.system(.caption2)).imageScale(.small)
            Text(text).font(.system(.caption2, weight: .semibold))
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
                                .font(.system(.title, design: .rounded, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .monospacedDigit()
                            Text(reco.scoreLabel)
                                .font(.system(.caption2, weight: .semibold))
                                .foregroundStyle(tint)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .padding(.horizontal, 6)
                        }
                    }
                    .frame(width: 96, height: 96)

                    VStack(spacing: 5) {
                        Text(loc("reco.score_detail_title"))
                            .font(.system(.title3, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                        Text(loc("reco.score_detail_sub"))
                            .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if !reco.periodLabel.isEmpty {
                            Label(reco.periodLabel, systemImage: "calendar")
                                .font(.system(.caption2, weight: .semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(AppTheme.cardMid.opacity(0.7), in: Capsule())
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
                                .font(.system(.footnote)).foregroundStyle(m.rating.color)
                                .frame(width: 18)
                            // Full label here — the sheet has the width the
                            // compact card doesn't.
                            Text(m.fullLabel)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(m.rating.label)
                                .font(.system(.caption, weight: .bold)).foregroundStyle(m.rating.color)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(m.rating.color.opacity(0.13), in: Capsule())
                        }
                        if !m.measured.isEmpty {
                            Text(m.measured)
                                .font(.system(.caption, weight: .medium))
                                .foregroundStyle(AppTheme.textPrimary.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !m.explanation.isEmpty {
                            Text(m.explanation)
                                .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.lg)
                        .stroke(m.rating.color.opacity(0.22), lineWidth: 1))
                }

                Text(loc("brief.disclaimer"))
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 20)
        }
        .background(AppTheme.bg)
    }
}
