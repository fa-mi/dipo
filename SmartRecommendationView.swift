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

    /// Called after the user taps "Apply" so the parent can refresh its state.
    var onApply: () -> Void = {}

    @State private var appeared = false
    @State private var animatedScore: Int = 0
    @State private var detailReco: SmartRecommendation? = nil

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

    private var reco: SmartRecommendation {
        SmartRecommendationEngine.analyze(
            transactions: allTx, monthlyIncome: monthlyIncome,
            goals: goals, debts: debts, currency: currency)
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
                 : String(format: loc("reco.subtitle"), r.dataMonths))
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Score card

    private func scoreCard(_ r: SmartRecommendation) -> some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().stroke(AppTheme.cardMid, lineWidth: 9).frame(width: 108, height: 108)
                Circle()
                    .trim(from: 0, to: appeared ? CGFloat(r.smartScore) / 100 : 0)
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .frame(width: 108, height: 108)
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 1.0, dampingFraction: 0.85), value: appeared)
                VStack(spacing: 1) {
                    Text("\(animatedScore)")
                        .font(.system(size: 30, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                        .contentTransition(.numericText())
                    Text(loc("reco.score_label")).font(.system(size: 9)).foregroundStyle(AppTheme.textSecondary)
                    Text(r.scoreLabel).font(.system(size: 9, weight: .semibold)).foregroundStyle(AppTheme.accent)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                metricRow("waveform.path.ecg", loc("reco.metric.balance"), r.spendingBalance)
                metricRow("lock.fill", loc("reco.metric.saving"), r.savingHabit)
                metricRow("chart.line.uptrend.xyaxis", loc("reco.metric.invest"), r.investmentPotential)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppTheme.cardMid.opacity(0.5), lineWidth: 1))
    }

    private func metricRow(_ icon: String, _ label: String, _ rating: RecoRating) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary).frame(width: 18)
            Text(label).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
            Spacer(minLength: 6)
            Text(rating.label).font(.system(size: 12, weight: .bold)).foregroundStyle(rating.color)
        }
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
