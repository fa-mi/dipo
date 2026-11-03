import SwiftUI

// MARK: - Smart Recommendation Detail
//
// The "Your Personalized Recommendation" deep-dive reached via "View Details".
// Four tabs — Summary, Saving, Investment, Spending — break the engine's
// analysis into concrete plans (allocation donut, goal acceleration, auto-save,
// 10-year projection, spending mix). All numbers come from SmartRecommendation
// so this screen never recomputes; it just renders.

struct SmartRecommendationDetailView: View {
    let reco: SmartRecommendation
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable { case summary, saving, investment, spending
        var title: String {
            switch self {
            case .summary:    return loc("reco.tab.summary")
            case .saving:     return loc("reco.tab.saving")
            case .investment: return loc("reco.tab.investment")
            case .spending:   return loc("reco.tab.spending")
            }
        }
    }
    @State private var tab: Tab = .summary

    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: reco.currency)
    }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    tabBar
                    switch tab {
                    case .summary:    summaryTab
                    case .saving:     savingTab
                    case .investment: investmentTab
                    case .spending:   spendingTab
                    }
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 30)
                .containerRelativeFrame(.horizontal)
            }
        }
    }

    // MARK: Header + tabs

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { HapticManager.shared.tap(); dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(.callout, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 36, height: 36).background(AppTheme.cardDark, in: Circle())
            }
.accessibilityLabel(loc("a11y.back"))
.hitTarget(36)
            Text(loc("reco.detail_title")).font(.system(.title2, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
            Text(loc("reco.detail_sub")).font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
        }
    }

    /// The chosen tab in ink on one track, like the app's other switches.
    /// It was green, which says money coming in.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { t in
                let on = tab == t
                Button {
                    HapticManager.shared.tap()
                    withAnimation(.spring(response: 0.3)) { tab = t }
                } label: {
                    Text(t.title)
                        .font(.system(.caption, weight: on ? .bold : .medium))
                        .foregroundStyle(on ? AppTheme.cardDark : AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(on ? AppTheme.textPrimary : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(AppTheme.cardMid, in: Capsule())
    }

    // MARK: Summary

    /// 1. Where you stand — one sentence and the single number that matters.
    private var situationCard: some View {
        let positive = !reco.isDeficit
        let measured = { SmartRecommendationEngine.measuredValue($0, currency: reco.currency) }
        let headline = positive
            ? money(reco.recommendedMonthlySaving)
            : "-" + money(measured(reco.deficitAmount))
        return VStack(alignment: .leading, spacing: 8) {
            Text(loc("reco.sum.where_title"))
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Text(headline)
                .font(.system(.title, weight: .bold))
                // Ink for what can be put aside; red only for a shortfall.
                .foregroundStyle(positive ? AppTheme.textPrimary : AppTheme.red)
                .minimumScaleFactor(0.7).lineLimit(1)
            Text(positive
                 ? String(format: loc("reco.sum.where_surplus"), money(measured(reco.avgMonthlyExpense)))
                 : String(format: loc("reco.sum.where_deficit"),
                          money(measured(reco.avgMonthlyExpense)), money(reco.monthlyIncome)))
                .font(.system(.caption)).foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            if !reco.periodLabel.isEmpty {
                Label(reco.periodLabel, systemImage: "calendar")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The theme's own surface. The verdict's colour is on the figure; a
        // wash of it behind the card said the same thing again.
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    /// 2. What to do, in order. Same items as the main screen but numbered, so
    /// the plan reads as a sequence rather than a pile of suggestions.
    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("reco.sum.steps_title"))
                .font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
            ForEach(Array(reco.topItems.prefix(4).enumerated()), id: \.element.id) { idx, item in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(idx + 1)")
                        .font(.system(.caption, weight: .bold)).foregroundStyle(item.tint)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.subtitle)
                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    /// 3. Only the outcomes that actually have a value. A grid half-full of
    /// em-dashes reads as missing data, not as "not applicable yet".
    private var impactStats: [(value: String, label: String, tint: Color)] {
        var out: [(String, String, Color)] = []
        if reco.recommendedMonthlySaving > 0 {
            out.append((money(reco.recommendedMonthlySaving), loc("reco.impact.planned_saving"), AppTheme.textPrimary))
        }
        if reco.potentialCut > 0 {
            out.append((money(reco.potentialCut), loc("reco.impact.smarter"), AppTheme.orange))
        }
        if let m = reco.goalMonthsFaster, m > 0 {
            out.append((String(format: loc("debt.month"), m), loc("reco.impact.goal_faster"), AppTheme.blue))
        }
        if reco.investReturn10y > 0 {
            out.append((money(reco.investReturn10y), loc("reco.impact.invest_return"), AppTheme.purple))
        }
        return out
    }

    private var impactCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("reco.impact_title"))
                .font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
            Text(loc("reco.impact_intro"))
                .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
            ForEach(Array(impactStats.enumerated()), id: \.offset) { _, stat in
                HStack {
                    Text(stat.label)
                        .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 10)
                    Text(stat.value)
                        .font(.system(.subheadline, weight: .bold)).foregroundStyle(stat.tint)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var summaryTab: some View {
        VStack(spacing: 16) {
            // Read top-to-bottom as a story: where you are → what to do →
            // what changes. The old version opened with a 2×2 grid of stats
            // that were mostly "—" or "Rp 0" in deficit, which told the user
            // nothing and looked broken.
            situationCard
            stepsCard
            if !impactStats.isEmpty { impactCard }

            if !reco.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(loc("reco.why_title")).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    ForEach(Array(reco.reasons.enumerated()), id: \.offset) { _, reason in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(AppTheme.textSecondary).frame(width: 5, height: 5).padding(.top, 6)
                            Text(reason).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
            }
        }
    }

    // MARK: Saving

    private var savingTab: some View {
        VStack(spacing: 16) {
            card {
                Text(loc("reco.saving.plan")).font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                Text(loc("reco.saving.recommended")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(money(reco.recommendedMonthlySaving) + loc("reco.per_month"))
                        .font(.system(.title2, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    if reco.savingVsCurrentPct != 0 && !reco.isDeficit {
                        Text(String(format: loc("reco.vs_current"), reco.savingVsCurrentPct))
                            .font(.system(.caption2, weight: .bold)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
                if reco.isDeficit { deficitExplainer }
            }

            if !reco.savingAllocation.isEmpty {
                card {
                    Text(loc("reco.alloc_title")).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    HStack(spacing: 16) {
                        RecoDonutChart(slices: reco.savingAllocation,
                                       centerTitle: money(reco.recommendedMonthlySaving),
                                       centerSub: loc("reco.per_month_center"))
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(reco.savingAllocation) { s in
                                HStack(spacing: 8) {
                                    Circle().fill(s.color).frame(width: 8, height: 8)
                                    Text(s.label).font(.system(.caption)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("\(s.pct)%").font(.system(.caption, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                                }
                                Text(money(s.amount)).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }

            if let cur = reco.goalCurrentMonths, let new = reco.goalNewMonths, let name = reco.topGoalName {
                card {
                    Text(loc("reco.goal_accel")).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    Text(name).font(.system(.caption, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc("reco.goal_new")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                            Text(String(format: loc("debt.month"), new)).font(.system(.callout, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right").font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(loc("reco.goal_current")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                            Text(String(format: loc("debt.month"), cur)).font(.system(.callout, weight: .bold)).foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    if let faster = reco.goalMonthsFaster, faster > 0 {
                        Text(String(format: loc("reco.months_faster"), faster))
                            .font(.system(.caption2, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    }
                }
            }

            // Auto-save suggestion. A suggestion, not a setting: the switch
            // that sat here changed nothing — DiPo does not move money — and
            // in a deficit it offered to auto-save Rp 0.
            if reco.autoSaveAmount > 0 {
                card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc("reco.autosave_title")).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                        Text(String(format: loc("reco.autosave_body"), money(reco.autoSaveAmount)))
                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Why the plan allocates a share to Invest & debt while the suggested
    /// saving/investing figure is zero: that share is currently paying debt
    /// minimums, and setting money aside only becomes real once spending fits
    /// inside income. Without this the two numbers look like a bug.
    private var deficitExplainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(.caption2)).foregroundStyle(AppTheme.orange)
                Text(loc("reco.deficit_zero_title"))
                    .font(.system(.caption, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
            }
            Text(String(format: loc("reco.deficit_zero_body"),
                        Int((reco.recommendedRatios.investDebt * 100).rounded()),
                        money(reco.monthlyIncome * reco.recommendedRatios.investDebt),
                        money(SmartRecommendationEngine.measuredValue(reco.debtMinimumMonthly, currency: reco.currency)),
                        money(SmartRecommendationEngine.measuredValue(reco.deficitAmount, currency: reco.currency))))
                .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Investment

    private var investmentTab: some View {
        VStack(spacing: 16) {
            card {
                Text(loc("reco.invest.plan")).font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                Text(loc("reco.invest.suggested")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                Text(money(reco.suggestedInvestment) + loc("reco.per_month"))
                    .font(.system(.title2, weight: .bold)).foregroundStyle(AppTheme.purple)
                if reco.isDeficit { deficitExplainer }
            }
            card {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc("reco.invest.value10y")).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        Text(reco.investReturn10y > 0 ? money(reco.investReturn10y) : "—")
                            .font(.system(.title2, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                    }
                    Spacer()
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.system(.title)).foregroundStyle(AppTheme.purple)
                }
                Text(loc("reco.invest.note")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Spending

    private var spendingTab: some View {
        VStack(spacing: 16) {
            card {
                Text(loc("reco.spending.title")).font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                Text(loc("reco.spending.sub")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                if reco.spendingBreakdown.isEmpty {
                    Text(loc("reco.spending.empty")).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary).padding(.top, 4)
                } else {
                    VStack(spacing: 12) {
                        ForEach(reco.spendingBreakdown) { s in
                            VStack(spacing: 5) {
                                HStack {
                                    Circle().fill(s.color).frame(width: 8, height: 8)
                                    Text(s.label).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                                    Spacer()
                                    Text(money(s.amount)).font(.system(.caption, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                    Text("\(s.pct)%").font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary).frame(width: 34, alignment: .trailing)
                                }
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(AppTheme.cardMid).frame(height: 5)
                                        Capsule().fill(s.color).frame(width: g.size.width * CGFloat(s.pct) / 100, height: 5)
                                    }
                                }.frame(height: 5)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            if reco.potentialCut > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "scissors").font(.system(.subheadline)).foregroundStyle(AppTheme.orange)
                    Text(String(format: loc("reco.spending.cut"), money(reco.potentialCut)))
                        .font(.system(.caption)).foregroundStyle(AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
            }
        }
    }

    // MARK: Card helper

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

// MARK: - Donut

struct RecoDonutChart: View {
    let slices: [RecoSlice]
    let centerTitle: String
    let centerSub: String

    private struct Seg { let start: CGFloat; let end: CGFloat; let color: Color }
    private var segments: [Seg] {
        let total = max(slices.reduce(0.0) { $0 + Double($1.pct) }, 1)
        var acc: CGFloat = 0
        return slices.map { s in
            let frac = CGFloat(Double(s.pct) / total)
            let seg = Seg(start: acc, end: acc + frac, color: s.color)
            acc += frac
            return seg
        }
    }

    var body: some View {
        ZStack {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                Circle()
                    .trim(from: seg.start, to: seg.end)
                    .stroke(seg.color, style: StrokeStyle(lineWidth: 15, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 1) {
                Text(centerTitle).font(.system(.footnote, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text(centerSub).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
            }
            .padding(6)
        }
        .frame(width: 118, height: 118)
    }
}
