import SwiftUI
import SwiftData

// MARK: - Holding detail

struct HoldingDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var holding: InvestmentHolding

    @State private var addKind: InvestmentLotKind? = nil
    @State private var editLot: InvestmentLot? = nil
    @State private var showPrice = false
    @State private var confirmDeleteHolding = false

    private var s: HoldingStats { holding.stats() }
    private var cur: String { holding.currency }

    var body: some View {
        FeatureStack { pushed in
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        header.padding(.top, 20)
                        heroCard
                        if holding.priceHistory.count >= 2 { priceChartCard }
                        detailRows
                        actionRow
                        lotsSection
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 22)
                }
            }
            .featureBar(pushed: pushed)
            .sheet(item: $addKind) { kind in
                AddLotSheet(holding: holding, initialKind: kind)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
            }
            .sheet(item: $editLot) { lot in
                EditLotSheet(holding: holding, lot: lot)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
            }
            .sheet(isPresented: $showPrice) {
                UpdatePriceSheet(holding: holding)
                    .presentationDetents([.height(320)]).presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
            }
            .confirmationDialog(loc("invest.delete_holding"), isPresented: $confirmDeleteHolding, titleVisibility: .visible) {
                Button(loc("invest.delete_holding"), role: .destructive) {
                    for lot in holding.lots { InvestmentCash.reverse(lot.linkedCardTxID, context: context) }
                    context.delete(holding); try? context.save()
                    HapticManager.shared.success(); dismiss()
                }
                Button(loc("common.cancel"), role: .cancel) {}
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: holding.type.icon)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(holding.type.color)
                .frame(width: 46, height: 46)
                .background(holding.type.color.opacity(0.15), in: RoundedRectangle(cornerRadius: AppRadius.md))
            VStack(alignment: .leading, spacing: 3) {
                Text(holding.name).font(.system(.title3, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(holding.type.displayName)
                    Text("·")
                    Text(cadenceLabel)
                }
                .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 8)
            Menu {
                Button(role: .destructive) { confirmDeleteHolding = true } label: {
                    Label(loc("invest.delete_holding"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(.body, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary).frame(width: 40, height: 40)
                    .background(AppTheme.cardDark, in: Circle())
            }
        }
    }

    private var cadenceLabel: String {
        switch holding.type.cadence {
        case .live:  return loc("invest.cadence.live")
        case .daily: return loc("invest.cadence.daily")
        case .fixed: return loc("invest.cadence.fixed")
        }
    }

    private var heroCard: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(loc("invest.market_value")).font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(investMoney(s.marketValue, cur)).font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText()).minimumScaleFactor(0.6).lineLimit(1)
            }
            HStack(spacing: 8) {
                plChip(investSigned(s.unrealizedPL, cur) + " (" + investPct(s.unrealizedPct) + ")",
                       investPLColor(s.unrealizedPL), up: s.unrealizedPL >= 0)
                if s.todayChange != 0 {
                    plChip(loc("invest.today") + " " + investSigned(s.todayChange, cur),
                           investPLColor(s.todayChange), up: s.todayChange >= 0)
                }
            }
        }
        .frame(maxWidth: .infinity).padding(18)
        .background {
            let tint = investPLColor(s.unrealizedPL)
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(AppTheme.cardDark)
                .overlay { LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.04), .clear],
                                          startPoint: .topTrailing, endPoint: .bottomLeading) }
                .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).stroke(tint.opacity(0.18), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        }
    }

    private func plChip(_ text: String, _ tint: Color, up: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right").font(.system(.caption2, weight: .bold))
            Text(text).font(.system(.caption, weight: .bold))
        }
        .foregroundStyle(tint).padding(.horizontal, 10).padding(.vertical, 5)
        .background(tint.opacity(0.15), in: Capsule())
    }

    private var priceChartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc("invest.price_chart")).font(.system(.caption, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            MiniSparkline(values: holding.priceHistory, up: s.unrealizedPL >= 0).frame(height: 70)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private var detailRows: some View {
        let priceNow = holding.type.priceIsFixed ? investMoney(1, cur)
            : (holding.lastPrice > 0 ? investMoney(holding.lastPrice, cur) : "—")
        return VStack(spacing: 0) {
            detailRow(loc("invest.avg_cost"), s.avgCost > 0 ? investMoney(s.avgCost, cur) : "—")
            if !holding.type.priceIsFixed { rowDivider; detailRow(loc("invest.current_price"), priceNow) }
            rowDivider
            detailRow(loc("invest.volume"), "\(investUnits(s.unitsHeld)) \(holding.type.unitLabel)")
            if holding.type == .stock {
                rowDivider
                detailRow(loc("invest.lot"), "\(investUnits((s.unitsHeld / 100).rounded(.down))) Lot")
            }
            rowDivider
            detailRow(loc("invest.invested"), investMoney(s.costBasis, cur))
        }
        .padding(.vertical, 4)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private func detailRow(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(label).font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
            Spacer(minLength: 8)
            Text(value).font(.system(.subheadline, weight: .bold)).foregroundStyle(tint ?? AppTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var rowDivider: some View {
        Rectangle().fill(AppTheme.cardMid.opacity(0.6)).frame(height: 1).padding(.leading, 16)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            actionButton(loc("invest.buy_more"), "plus", AppTheme.accent) { addKind = .buy }
            if s.unitsHeld > 0 {
                actionButton(loc("invest.sell"), "arrow.up.right", AppTheme.blue) { addKind = .sell }
            }
            if !holding.type.priceIsFixed {
                actionButton(loc("invest.update_price"), "arrow.triangle.2.circlepath", AppTheme.textSecondary) { showPrice = true }
            }
        }
    }

    private func actionButton(_ title: String, _ icon: String, _ tint: Color, _ action: @escaping () -> Void) -> some View {
        Button { HapticManager.shared.tap(); action() } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(.caption, weight: .bold))
                Text(title).font(.system(.caption, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private var lotsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc("invest.lots")).font(.system(.body, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
            if holding.lots.isEmpty {
                Text(loc("invest.empty_lots")).font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary).frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    let sorted = holding.lots.sorted { $0.date > $1.date }
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { i, lot in
                        Button { HapticManager.shared.tap(); editLot = lot } label: {
                            LotRow(lot: lot, holding: holding)
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .contextMenu {
                            Button { editLot = lot } label: {
                                Label(loc("invest.edit_lot"), systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                InvestmentCash.reverse(lot.linkedCardTxID, context: context)
                                context.delete(lot); try? context.save(); HapticManager.shared.tap()
                            } label: { Label(loc("invest.delete_lot"), systemImage: "trash") }
                        }
                        if i < sorted.count - 1 {
                            Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 52)
                        }
                    }
                }
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
        }
    }
}

private struct LotRow: View {
    let lot: InvestmentLot
    let holding: InvestmentHolding

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(.caption, weight: .bold)).foregroundStyle(tint)
                .frame(width: 30, height: 30).background(tint.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(kindLabel).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Text(subtitle).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 8)
            Text(amountText).font(.system(.subheadline, weight: .bold)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(12)
    }

    private var tint: Color {
        switch lot.kind {
        case .buy:      return AppTheme.textPrimary
        case .sell:     return AppTheme.blue
        case .dividend, .coupon: return AppTheme.accent
        case .fee:      return AppTheme.red
        }
    }
    private var icon: String {
        switch lot.kind {
        case .buy: return "plus"
        case .sell: return "arrow.up.right"
        case .dividend, .coupon: return "arrow.down.left"
        case .fee: return "minus"
        }
    }
    private var kindLabel: String { loc("invest.kind.\(lot.kindRaw)") }
    private var subtitle: String {
        let d = lot.date.formatted(.dateTime.day().month(.abbreviated).year())
        if lot.kind.isCash { return d }
        return "\(investUnits(lot.units)) \(holding.type.unitLabel) · \(investMoney(lot.pricePerUnit, holding.currency))"
    }
    private var amountText: String {
        if lot.kind.isCash { return investMoney(lot.cashAmount, holding.currency) }
        let gross = lot.units * lot.pricePerUnit
        return investMoney(gross, holding.currency)
    }
}

// MARK: - Empty state

struct InvestEmptyState: View {
    let onAdd: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 96, height: 96)
                .background(AppTheme.accent.opacity(0.12), in: Circle())
            VStack(spacing: 6) {
                Text(loc("invest.empty_title")).font(.system(.title3, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("invest.empty_sub")).font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            Button { HapticManager.shared.tap(); onAdd() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text(loc("invest.add")).font(.system(.callout, weight: .bold))
                }
                .foregroundStyle(AppTheme.onVividFill)
                .padding(.horizontal, 22).padding(.vertical, 14)
                .background(AppTheme.accent, in: Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }
}
