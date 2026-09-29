import SwiftUI
import SwiftData

// Moved out of StatisticsView.swift, unchanged. The cards the Statistics screen is built from.

// MARK: - Spending trend

/// Spending per period, the latest one highlighted, against the average of the
/// periods that have finished. Answers "is this more than usual" at a glance;
/// tapping opens the numbers behind every bar.
struct SpendingTrendCard: View {
    let trend: [CycleTrendPoint]
    let currency: String
    var byPayCycle: Bool = false
    @State private var showBreakdown = false
    @State private var appeared = false

    private var finished: [CycleTrendPoint] { trend.filter { !$0.isRunning && $0.expense > 0 } }
    private var average: Double? {
        guard !finished.isEmpty else { return nil }
        return finished.reduce(0) { $0 + $1.expense } / Double(finished.count)
    }
    private var peak: Double { max(trend.map(\.expense).max() ?? 0, average ?? 0, 1) }

    /// The bar colour answers one question: was this period above the usual
    /// line? Spending itself is not a failure, so the chart no longer paints
    /// every period in alarm red — a period that came in under the average now
    /// looks like what it is. Only the period being reported on is drawn at
    /// full strength; the ones behind it stay quiet so it reads as the subject.
    private func barColor(_ point: CycleTrendPoint, isLast: Bool) -> Color {
        let hot = average.map { point.expense > $0 } ?? false
        let base = hot ? AppTheme.orange : AppTheme.accent
        return isLast ? base : base.opacity(hot ? 0.34 : 0.22)
    }

    var body: some View {
        if trend.contains(where: { $0.expense > 0 }) {
            Button {
                HapticManager.shared.tap()
                showBreakdown = true
            } label: {
                content
            }
            .buttonStyle(ScaleButtonStyle())
            .sheet(isPresented: $showBreakdown) {
                CycleTrendBreakdown(trend: trend, currency: currency)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc(byPayCycle ? "stats.trend_title_cycle" : "stats.trend_title"))
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(loc("stats.trend_hint"))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer(minLength: 8)
                if let average {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(loc("stats.trend_average"))
                            .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        Text(CurrencyManager.shared.formatted(average, currency: currency))
                            .font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    }
                }
            }

            let chartH: CGFloat = 96
            ZStack(alignment: .bottom) {
                if let average {
                    // The usual level, so each bar reads as above or below it.
                    Rectangle()
                        .fill(AppTheme.textSecondary.opacity(0.45))
                        .frame(height: 1)
                        .padding(.bottom, chartH * CGFloat(average / peak))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(Array(trend.enumerated()), id: \.element.id) { i, point in
                        let isLast = i == trend.count - 1
                        let h = max(chartH * CGFloat(point.expense / peak), point.expense > 0 ? 4 : 2)
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(barColor(point, isLast: isLast))
                                .frame(height: appeared ? h : 2)
                                .animation(.spring(response: 0.6, dampingFraction: 0.8)
                                    .delay(Double(i) * 0.05), value: appeared)
                        }
                        .frame(maxWidth: .infinity, maxHeight: chartH, alignment: .bottom)
                    }
                }
            }
            .frame(height: chartH)

            HStack(spacing: 10) {
                ForEach(Array(trend.enumerated()), id: \.element.id) { i, point in
                    let isLast = i == trend.count - 1
                    Text(point.label)
                        .font(.system(.caption2, weight: isLast ? .bold : .regular))
                        .foregroundStyle(isLast ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        .onAppear { appeared = true }
    }
}

// MARK: - Summary Cards

struct NetBalanceSummary: View {
    let net: Double
    let income: Double
    let expenses: Double
    let currency: String
    /// The selected card's CUMULATIVE balance (what Home shows). Rendered as a
    /// footer so period-flow and account-stock sit side by side — users kept
    /// reading "Net this period" as the card balance and reporting a "bug".
    var cardBalanceNow: Double? = nil
    /// Balance at the period's start + net transfer movement — together with
    /// `net` they RECONCILE exactly to the card balance:
    /// start + net + transfers = balance. Nil hides the breakdown.
    var startBalance: Double? = nil
    var transferNet: Double? = nil
    /// Day N of M when the period is still running. Nil for finished periods.
    var progress: (elapsed: Int, total: Int)? = nil
    /// Spending over the same number of days one period ago.
    var previousExpenses: Double? = nil

    private func chip(_ icon: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(.caption2, weight: .bold)).imageScale(.small)
            Text(text).font(.system(.caption2, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private var spentPct: Double {
        guard income > 0 else { return 0 }
        return min((expenses / income) * 100, 100)
    }
    
    private var savedPct: Double {
        guard income > 0 else { return 0 }
        return max(0, 100 - (expenses / income) * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                // Spelled out so it isn't mistaken for the card's Balance on
                // Home: that one is the cumulative account balance, this is the
                // in/out flow for the selected period only.
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("stats.net_balance"))
                        .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                    Text(loc("stats.net_balance_sub"))
                        .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary.opacity(0.75))
                }
                Spacer()
                Text(net >= 0 ? "\(CurrencyManager.shared.formatted(net, currency: currency))"
                             : CurrencyManager.shared.formatted(net, currency: currency))
                    .font(.system(.callout, weight: .bold))
                    .foregroundStyle(net >= 0 ? AppTheme.accent : AppTheme.red)
                    .contentTransition(.numericText())
            }
            // Share of income spent, warming from green to red as it fills, with
            // a tick where TIME is: a bar ending past it is ahead of the calendar.
            SpendGauge(fraction: income > 0 ? expenses / income : 0,
                       timeMarker: progress.map { Double($0.elapsed) / Double($0.total) },
                       height: 8)
            HStack {
                Text(String(format: loc("stats.percentage_spent"), String(format: "%.0f", spentPct)))
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text(net >= 0
                     ? String(format: loc(progress == nil ? "stats.saved" : "stats.saved_sofar"),
                              String(format: "%.0f%%", savedPct))
                     : loc("stats.overspent"))
                    .font(.system(.caption2, weight: .medium))
                    .foregroundStyle(SpendGauge.tone(for: income > 0 ? expenses / income : 1))
            }

            // Two facts that make the percentages mean something: how far into
            // the period we are, and how this pace compares to last time.
            if progress != nil || previousExpenses != nil {
                HStack(spacing: 8) {
                    if let p = progress {
                        chip("clock", AppTheme.blue,
                             String(format: loc("stats.day_of"), p.elapsed, p.total))
                    }
                    if let prev = previousExpenses, prev > 0 {
                        let delta = (expenses - prev) / prev * 100
                        let up = delta >= 0
                        chip(up ? "arrow.up.right" : "arrow.down.right",
                             up ? AppTheme.orange : AppTheme.accent,
                             String(format: loc(up ? "stats.vs_prev_up" : "stats.vs_prev_down"),
                                    Int(abs(delta).rounded())))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }

            // Full reconciliation: start balance + net + transfers = today's
            // balance. Every rupiah between "net this period" and the card
            // balance is accounted for on screen.
            if let start = startBalance, let balance = cardBalanceNow {
                Divider().background(AppTheme.cardMid)
                VStack(spacing: 6) {
                    reconRow(loc("stats.recon_start"), start)
                    reconRow(loc("stats.net_balance"), net, signed: true)
                    if let transfers = transferNet, abs(transfers) > 0.5 {
                        reconRow(loc("stats.recon_transfers"), transfers, signed: true)
                    }
                    // When the period is still running, start + net + transfers
                    // lands exactly on today's balance. For a past period (e.g.
                    // "Last Month") it lands on that period's CLOSING balance —
                    // label whichever applies so the math always visibly closes.
                    let closing = start + net + (transferNet ?? 0)
                    let isToday = abs(closing - balance) < 1
                    Divider().background(AppTheme.cardMid.opacity(0.6))
                    HStack {
                        Text(loc(isToday ? "stats.card_balance_now" : "stats.recon_end"))
                            .font(.system(.caption2, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                        Spacer()
                        Text("= " + (closing < 0 ? "-" : "") + CurrencyManager.shared.formatted(abs(closing), currency: currency))
                            .font(.system(.caption, weight: .bold))
                            .foregroundStyle(closing >= 0 ? AppTheme.accent : AppTheme.red)
                    }
                }
            } else if let balance = cardBalanceNow {
                Divider().background(AppTheme.cardMid)
                HStack {
                    Text(loc("stats.card_balance_now"))
                        .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Text((balance < 0 ? "-" : "") + CurrencyManager.shared.formatted(abs(balance), currency: currency))
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(balance >= 0 ? AppTheme.textPrimary : AppTheme.red)
                }
            }
        }
        .padding(.vertical, 16).padding(.horizontal, 18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private func reconRow(_ label: String, _ value: Double, signed: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text((value < 0 ? "−" : signed ? "+" : "")
                 + CurrencyManager.shared.formatted(abs(value), currency: currency))
                .font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
        }
    }
}

// MARK: - Trend point

/// One bar of the trend, carrying the numbers behind it.
///
/// The chart used to hold only a label and a net figure, which meant the only
/// way to check it was to trust it. Keeping income, expense, the window and the
/// transaction count alongside lets the card open and show its own working.
struct CycleTrendPoint: Identifiable {
    let id = UUID()
    let label: String
    let start: Date
    let end: Date
    let income: Double
    let expense: Double
    let txCount: Int
    var net: Double { income - expense }
    /// A period that has not finished yet holds an incomplete total.
    var isRunning: Bool { end > Date() }
}

// MARK: - Smart Insights Card (Weekly Avg + Top Categories)

struct SmartInsightsCard: View {
    let weeklyAverage: Double
    /// What a day has to spend once the month's fixed costs are set aside.
    var dailyAllowance: Double? = nil
    /// Days that cost several times a typical one — reported, not averaged in.
    var irregular: (count: Int, total: Double) = (0, 0)
    let topCategories: [(category: TxCategory, amount: Double, percentage: Double)]
    let totalExpenses: Double
    let currency: String
    /// When the selected window is shorter than ~2 weeks the "per week" figure
    /// is extrapolated from very little data (e.g. a pay cycle only 8 days in)
    /// and reads much higher than a steady weekly pace. We keep showing it but
    /// flag it as a partial-period estimate so it isn't mistaken for a rate.
    var isPartialPeriod: Bool = false
    var periodDays: Int = 0
    /// Opens the audit. A figure that excludes some of your spending has to be
    /// traceable back to the transactions it did and did not use.
    var onAudit: (() -> Void)? = nil

    @State private var appeared = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(AppTheme.purple.opacity(0.15)).frame(width: 32, height: 32)
                    Image(systemName: "sparkles")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.purple)
                }
                Text(loc("stats.insights"))
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
            }
            
            // Weekly Average — hero metric
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.purple)
                    Text(loc("stats.weekly_avg"))
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                    if isPartialPeriod {
                        // Caveat chip — this window is too short for a stable
                        // weekly rate, so mark it as a partial estimate.
                        HStack(spacing: 3) {
                            Image(systemName: "info.circle.fill").font(.system(.caption2)).imageScale(.small)
                            Text(loc("stats.weekly_avg_partial_badge"))
                                .font(.system(.caption2, weight: .semibold))
                        }
                        .foregroundStyle(AppTheme.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(AppTheme.orange.opacity(0.12), in: Capsule())
                    }
                }
                Text(CurrencyManager.shared.formatted(weeklyAverage, currency: currency))
                    .font(.system(.title, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())
                Text(isPartialPeriod
                     ? String(format: loc("stats.weekly_avg_partial_sub"), periodDays)
                     : loc("stats.weekly_avg_sub"))
                    .font(.system(.caption2))
                    .foregroundStyle(isPartialPeriod ? AppTheme.orange.opacity(0.9) : AppTheme.textSecondary.opacity(0.8))

                // The figure only means something against what a day HAS.
                if let allowance = dailyAllowance, allowance > 0 {
                    let daily = weeklyAverage / 7
                    HStack(spacing: 5) {
                        Image(systemName: daily <= allowance ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(.caption2)).imageScale(.small)
                        Text(String(format: loc("stats.daily_vs_allowance"),
                                    CurrencyManager.shared.formatted(daily, currency: currency),
                                    CurrencyManager.shared.formatted(allowance, currency: currency)))
                            .font(.system(.caption2, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(daily <= allowance ? AppTheme.accent : AppTheme.orange)
                    .padding(.top, 2)
                }

                // The expensive days, named instead of smeared across the week.
                if let onAudit {
                    // Named, not just tappable. An invisible tap target on a
                    // number is a feature only its author knows about.
                    Button(action: onAudit) {
                        HStack(spacing: 4) {
                            Text(loc("audit.open"))
                                .font(.system(.caption2, weight: .semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(.caption2, weight: .bold)).imageScale(.small)
                        }
                        .foregroundStyle(AppTheme.purple)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .padding(.top, 2)
                }

                if irregular.count > 0 {
                    Text(String(format: loc(irregular.count == 1 ? "stats.oneoff_day" : "stats.oneoff_days"),
                                irregular.count,
                                CurrencyManager.shared.formatted(irregular.total, currency: currency)))
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                LinearGradient(
                    colors: [AppTheme.purple.opacity(0.18), AppTheme.purple.opacity(0.05)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: AppRadius.md)
            )
            
        }
        .padding(.vertical, 16).padding(.horizontal, 18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                appeared = true
            }
        }
    }
}

// MARK: - Trend breakdown
//
// The chart's own working, shown on tap.
//
// A bar is a conclusion; this is the arithmetic behind it — the exact window,
// how much came in, how much went out, how many rows were counted, and the
// subtraction. Nothing here is recomputed: it is the same numbers the bar was
// drawn from, which is the point. A figure you cannot check is one you can only
// take on trust, and trust is the wrong thing to ask for about someone's money.
struct CycleTrendBreakdown: View {
    let trend: [CycleTrendPoint]
    let currency: String
    @Environment(\.dismiss) private var dismiss

    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: currency)
    }
    private func range(_ p: CycleTrendPoint) -> String {
        let df = DateFormatter()
        df.locale = LanguageManager.shared.currentLocale
        df.dateFormat = DateFormatter.dateFormat(fromTemplate: "dMMM", options: 0,
                                                 locale: LanguageManager.shared.currentLocale)
        // The window is half-open, so the last day it covers is the day before
        // it ends — the same convention the period header uses.
        let last = Calendar.current.safeDate(byAdding: .day, value: -1, to: p.end)
        return "\(df.string(from: p.start)) – \(df.string(from: last))"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        Text(loc("stats.trend_detail_intro"))
                            .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)

                        ForEach(trend.reversed()) { p in
                            VStack(spacing: 9) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(p.label)
                                                .font(.system(.subheadline, weight: .bold))
                                                .foregroundStyle(AppTheme.textPrimary)
                                            if p.isRunning {
                                                Text(loc("stats.trend_running"))
                                                    .font(.system(.caption2, weight: .bold))
                                                    .foregroundStyle(AppTheme.orange)
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(AppTheme.orange.opacity(0.15), in: Capsule())
                                            }
                                        }
                                        Text(range(p))
                                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                    }
                                    Spacer()
                                    Text((p.net >= 0 ? "+" : "−") + money(abs(p.net)))
                                        .font(.system(.callout, weight: .bold))
                                        .foregroundStyle(p.net >= 0 ? AppTheme.accent : AppTheme.red)
                                }
                                Divider().overlay(AppTheme.cardMid)
                                row(loc("stats.income"), money(p.income), AppTheme.accent)
                                row(loc("stats.expenses"), "− " + money(p.expense), AppTheme.red)
                                row(loc("stats.trend_counted"),
                                    String(format: loc("search.results_count"), p.txCount),
                                    AppTheme.textSecondary)
                            }
                            .padding(14)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                            .padding(.horizontal, 22)
                        }

                        Text(loc("stats.trend_detail_note"))
                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22).padding(.top, 4)
                        Spacer(minLength: 30)
                    }
                    .padding(.top, 12)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("stats.trend_detail_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
    }

    private func row(_ l: String, _ v: String, _ tint: Color) -> some View {
        HStack {
            Text(l).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(v).font(.system(.caption, weight: .semibold)).foregroundStyle(tint)
        }
    }
}
