import SwiftUI
import SwiftData

// MARK: - Investment menu (Royal)
//
// Reached by push from the Plan tab, and only when the row unlocked it — so
// every view here assumes Royal. The screens are thin: PortfolioEngine does the
// maths, these just present value, cost, and profit/loss with colour and a
// little motion so a number that moved reads as having moved.

// MARK: Formatting helpers (file-private to avoid clashing with app-wide ones)

func investMoney(_ v: Double, _ cur: String) -> String {
    CurrencyManager.shared.formatted(v, currency: cur)
}
/// A gain/loss figure with an explicit sign, so −0 never shows as a bare 0.
func investSigned(_ v: Double, _ cur: String) -> String {
    (v >= 0 ? "+" : "−") + CurrencyManager.shared.formatted(abs(v), currency: cur)
}
func investPct(_ p: Double) -> String {
    String(format: "%@%.2f%%", p >= 0 ? "+" : "−", abs(p) * 100)
}
/// Units with just enough precision: whole where whole, up to 4 dp for grams/coins.
func investUnits(_ v: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.minimumFractionDigits = 0
    f.maximumFractionDigits = (v == v.rounded()) ? 0 : 4
    f.groupingSeparator = "."
    f.decimalSeparator = ","
    return f.string(from: v as NSNumber) ?? "\(v)"
}
func investPLColor(_ v: Double) -> Color { v >= 0 ? AppTheme.accent : AppTheme.red }

// MARK: - Root

struct InvestmentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \InvestmentHolding.sortOrder) private var holdings: [InvestmentHolding]
    @State private var showAdd = false
    @State private var appeared = false
    @State private var didAutoRefresh = false
    @State private var refreshing = false

    private var pref: String { CurrencyManager.shared.preferredCurrency }
    private var hasAutoPriced: Bool {
        holdings.contains { $0.type.supportsAutoPrice && !$0.manualPrice && !$0.symbol.isEmpty }
    }

    private func doRefresh(announce: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        let r = await PriceService.refresh(holdings, context: context)
        // Let the spin be seen even when the feed answers instantly, so a refresh
        // reads as something that happened rather than a dead tap.
        try? await Task.sleep(nanoseconds: 450_000_000)
        refreshing = false
        guard announce else { return }
        HapticManager.shared.success()
        // Say what actually happened: a fetch that returns the same last price
        // (market closed, no trades) is NOT an update, and claiming otherwise
        // leaves the user hunting for a number that never moved.
        if r.changed > 0 {
            ActionFeedbackCenter.shared.show(
                icon: "checkmark.circle.fill", tint: AppTheme.accent,
                title: loc("invest.refresh_done"),
                detail: String(format: loc("invest.refresh_count"), r.changed))
        } else {
            ActionFeedbackCenter.shared.show(
                icon: "clock.arrow.circlepath", tint: AppTheme.textSecondary,
                title: loc("invest.refresh_nochange"),
                detail: r.checked > 0 ? loc("invest.refresh_uptodate") : loc("invest.refresh_none"))
        }
    }

    private var totals: PortfolioTotals {
        let cm = CurrencyManager.shared
        let entries = holdings.map { (type: $0.typeRaw, currency: $0.currency, stats: $0.stats()) }
        return PortfolioEngine.portfolio(entries, targetCurrency: pref,
                                         convert: { cm.convert($0, from: $1, to: $2) })
    }

    var body: some View {
        FeatureStack { pushed in
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        header.padding(.top, 20)

                        if holdings.isEmpty {
                            InvestEmptyState { showAdd = true }.padding(.top, 30)
                        } else {
                            PortfolioOverviewCard(totals: totals, currency: pref)
                            VStack(spacing: 10) {
                                ForEach(holdings) { h in
                                    // Push as a PlanRoute value so it appends to the tab's
                                    // typed path; a value-less link crashes the nav path.
                                    NavigationLink(value: PlanRoute.holding(h)) {
                                        HoldingRow(holding: h, displayCurrency: pref)
                                    }
                                    .buttonStyle(ScaleButtonStyle())
                                }
                            }
                        }
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 22)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                }
                .refreshable { await doRefresh(announce: true) }
            }
            .featureBar(pushed: pushed)
            .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true } }
            // Pull the latest crypto/stock prices once when the menu opens.
            .task {
                guard !didAutoRefresh else { return }
                didAutoRefresh = true
                await doRefresh()
            }
            .sheet(isPresented: $showAdd) {
                AddHoldingSheet(nextOrder: (holdings.map(\.sortOrder).max() ?? -1) + 1)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("premium.feature.investments"))
                    .font(.system(.title, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("premium.feature.investments_desc"))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if hasAutoPriced {
                Button {
                    HapticManager.shared.tap()
                    Task { await doRefresh(announce: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 40, height: 40)
                        .background(AppTheme.cardDark, in: Circle())
                        .rotationEffect(.degrees(refreshing ? 360 : 0))
                        .animation(refreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                                   value: refreshing)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(refreshing)
            }
            if !holdings.isEmpty {
                Button {
                    HapticManager.shared.tap(); showAdd = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .frame(width: 40, height: 40)
                        .background(AppTheme.accent, in: Circle())
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
    }
}

// MARK: - Overview

struct PortfolioOverviewCard: View {
    let totals: PortfolioTotals
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(loc("invest.total_value"))
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(investMoney(totals.marketValue, currency))
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.7).lineLimit(1)
            }

            HStack(spacing: 10) {
                figure(loc("invest.pl"),
                       investSigned(totals.unrealizedPL, currency) + "  " + investPct(totals.unrealizedPct),
                       investPLColor(totals.unrealizedPL), arrowUp: totals.unrealizedPL >= 0)
                Rectangle().fill(AppTheme.cardMid).frame(width: 1, height: 34)
                figure(loc("invest.today"),
                       investSigned(totals.todayChange, currency),
                       investPLColor(totals.todayChange), arrowUp: totals.todayChange >= 0)
            }

            HStack(spacing: 14) {
                mini(loc("invest.invested"), investMoney(totals.costBasis, currency), AppTheme.textPrimary)
                if abs(totals.realizedPL) > 0.5 {
                    mini(loc("invest.realized"), investSigned(totals.realizedPL, currency), investPLColor(totals.realizedPL))
                }
                if totals.income > 0.5 {
                    mini(loc("invest.income"), investMoney(totals.income, currency), AppTheme.accent)
                }
            }

            if totals.valueByType.count > 1 {
                AllocationBar(valueByType: totals.valueByType, total: totals.marketValue)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let tint = investPLColor(totals.unrealizedPL)
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(AppTheme.cardDark)
                .overlay {
                    // A soft glow in the holding's fortune colour — green when up,
                    // red when down — for a premium, at-a-glance read.
                    LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.04), .clear],
                                   startPoint: .topTrailing, endPoint: .bottomLeading)
                }
                .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).stroke(tint.opacity(0.18), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        }
    }

    private func figure(_ label: String, _ value: String, _ tint: Color, arrowUp: Bool? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
            HStack(spacing: 3) {
                if let arrowUp {
                    Image(systemName: arrowUp ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(.caption2, weight: .bold)).foregroundStyle(tint)
                }
                Text(value).font(.system(.subheadline, weight: .bold)).foregroundStyle(tint)
                    .contentTransition(.numericText()).minimumScaleFactor(0.7).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mini(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
            Text(value).font(.system(.caption, weight: .semibold)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A slim stacked bar of the portfolio split by instrument type, with a legend.
struct AllocationBar: View {
    let valueByType: [String: Double]
    let total: Double

    private var slices: [(type: InvestmentType, value: Double)] {
        valueByType.compactMap { key, v in
            InvestmentType(rawValue: key).map { ($0, v) }
        }
        .filter { $0.value > 0 }
        .sorted { $0.value > $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc("invest.allocation"))
                .font(.system(.caption2, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(slices, id: \.type) { s in
                        s.type.color
                            .frame(width: max(2, g.size.width * (total > 0 ? s.value / total : 0)))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            FlowLegend(slices: slices, total: total)
        }
    }
}

private struct FlowLegend: View {
    let slices: [(type: InvestmentType, value: Double)]
    let total: Double
    var body: some View {
        HStack(spacing: 12) {
            ForEach(slices.prefix(4), id: \.type) { s in
                HStack(spacing: 5) {
                    Circle().fill(s.type.color).frame(width: 8, height: 8)
                    Text(s.type.displayName).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                    Text("\(Int((total > 0 ? s.value / total : 0) * 100))%")
                        .font(.system(.caption2, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Holding row

struct HoldingRow: View {
    let holding: InvestmentHolding
    let displayCurrency: String

    var body: some View {
        let s = holding.stats()
        HStack(spacing: 12) {
            Image(systemName: holding.type.icon)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(holding.type.color)
                .frame(width: 44, height: 44)
                .background(holding.type.color.opacity(0.15), in: RoundedRectangle(cornerRadius: AppRadius.md))
            VStack(alignment: .leading, spacing: 3) {
                Text(holding.name).font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                Text(subtitle).font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(investMoney(convertedValue(s), displayCurrency))
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
                // The up/down badge — the one thing the user checks first.
                HStack(spacing: 3) {
                    Image(systemName: s.unrealizedPL >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(.caption2, weight: .bold))
                    Text(investPct(s.unrealizedPct)).font(.system(.caption2, weight: .bold))
                }
                .foregroundStyle(investPLColor(s.unrealizedPL))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(investPLColor(s.unrealizedPL).opacity(0.14), in: Capsule())
            }
        }
        .padding(12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    /// "Stocks · Auto · BBRI" — type, whether the price is live or hand-kept, and
    /// the lookup symbol, matching how portfolio apps label a row.
    private var subtitle: String {
        var parts = [holding.type.displayName]
        if holding.type.supportsAutoPrice {
            parts.append(holding.manualPrice ? loc("invest.manual") : loc("invest.auto"))
        }
        if !holding.symbol.isEmpty { parts.append(holding.symbol.uppercased()) }
        return parts.joined(separator: " · ")
    }

    private func convertedValue(_ s: HoldingStats) -> Double {
        holding.currency == displayCurrency
            ? s.marketValue
            : CurrencyManager.shared.convert(s.marketValue, from: holding.currency, to: displayCurrency)
    }
}

// MARK: - Sparkline

/// A tiny price trail. Green when the holding is up, red when down. Renders only
/// with two or more points — otherwise there is no trend to draw.
struct MiniSparkline: View {
    let values: [Double]
    let up: Bool

    var body: some View {
        GeometryReader { g in
            if values.count >= 2, let lo = values.min(), let hi = values.max() {
                let range = hi - lo
                let stroke = up ? AppTheme.accent : AppTheme.red
                let pts: [CGPoint] = values.enumerated().map { i, v in
                    let x = g.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = range > 0 ? g.size.height * (1 - CGFloat((v - lo) / range)) : g.size.height / 2
                    return CGPoint(x: x, y: y)
                }
                ZStack {
                    // Faint fill under the line for a little depth.
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: g.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(stroke.opacity(0.12))
                    Path { p in
                        p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(stroke, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}
