import SwiftUI
import SwiftData

// MARK: - Holding detail

/// The one sheet the detail screen presents, routed through a single binding so
/// stacked .sheet modifiers can't clobber one another.
private enum DetailSheet: Identifiable {
    case addLot(InvestmentLotKind)
    case editLot(InvestmentLot)
    case price
    case deleteLot(InvestmentLot)
    case deleteHolding
    var id: String {
        switch self {
        case .addLot(let k):    return "add-\(k.rawValue)"
        case .editLot(let l):   return "edit-\(l.id.uuidString)"
        case .price:            return "price"
        case .deleteLot(let l): return "del-\(l.id.uuidString)"
        case .deleteHolding:    return "del-holding"
        }
    }
}

struct HoldingDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var holding: InvestmentHolding

    @State private var sheet: DetailSheet? = nil

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
            // One sheet, enum-driven. Stacking several .sheet modifiers on one
            // view is a known SwiftUI footgun (later ones may silently fail to
            // present) — routing all of them through a single binding is reliable.
            .sheet(item: $sheet) { which in
                switch which {
                case .addLot(let kind):
                    AddLotSheet(holding: holding, initialKind: kind)
                        .presentationDetents([.large]).presentationDragIndicator(.visible)
                        .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
                case .editLot(let lot):
                    EditLotSheet(holding: holding, lot: lot)
                        .presentationDetents([.large]).presentationDragIndicator(.visible)
                        .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
                case .price:
                    UpdatePriceSheet(holding: holding)
                        .presentationDetents([.height(320)]).presentationDragIndicator(.visible)
                        .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
                case .deleteLot(let lot):
                    DangerConfirmSheet(icon: "trash.fill", tone: .danger,
                                       title: loc("invest.delete_lot"),
                                       message: loc("invest.delete_lot_msg"),
                                       confirmLabel: loc("invest.delete_lot"),
                                       onConfirm: { deleteLot(lot) })
                        .preferredColorScheme(appColorScheme())
                case .deleteHolding:
                    DangerConfirmSheet(icon: "trash.fill", tone: .danger,
                                       title: loc("invest.delete_holding"),
                                       message: loc("invest.delete_holding_msg"),
                                       confirmLabel: loc("invest.delete_holding"),
                                       onConfirm: deleteHolding)
                        .preferredColorScheme(appColorScheme())
                }
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
                Button(role: .destructive) { sheet = .deleteHolding } label: {
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
            actionButton(loc("invest.buy_more"), "plus", AppTheme.accent) { sheet = .addLot(.buy) }
            if s.unitsHeld > 0 {
                actionButton(loc("invest.sell"), "arrow.up.right", AppTheme.blue) { sheet = .addLot(.sell) }
            }
            if !holding.type.priceIsFixed {
                actionButton(loc("invest.update_price"), "arrow.triangle.2.circlepath", AppTheme.textSecondary) { sheet = .price }
            }
        }
    }

    private func deleteLot(_ lot: InvestmentLot) {
        InvestmentCash.reverse(lot.linkedCardTxID, context: context)
        context.delete(lot); try? context.save()
        HapticManager.shared.success()
    }

    private func deleteHolding() {
        for lot in holding.lots { InvestmentCash.reverse(lot.linkedCardTxID, context: context) }
        context.delete(holding); try? context.save()
        HapticManager.shared.success(); dismiss()
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
                    .foregroundStyle(AppTheme.textSecondary).frame(maxWidth: .infinity).padding(.vertical, 24)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            } else {
                // Each transaction is its own card: tap to edit, swipe left to
                // delete (which then asks for confirmation). Long-press offers both.
                let sorted = holding.lots.sorted { $0.date > $1.date }
                ForEach(sorted, id: \.id) { lot in
                    LotSwipeCard(
                        lot: lot, holding: holding,
                        onTap: { HapticManager.shared.tap(); sheet = .editLot(lot) },
                        onDelete: { sheet = .deleteLot(lot) }
                    )
                    .contextMenu {
                        Button { sheet = .editLot(lot) } label: {
                            Label(loc("invest.edit_lot"), systemImage: "pencil")
                        }
                        Button(role: .destructive) { sheet = .deleteLot(lot) } label: {
                            Label(loc("invest.delete_lot"), systemImage: "trash")
                        }
                    }
                }
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
            // Signals the row is tappable (opens Edit).
            Image(systemName: "chevron.right").font(.system(.caption2, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
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

// MARK: - Swipeable transaction card
//
// A self-contained rounded card: tap to edit, swipe left to delete. The red
// action sits UNDER the card sharing its rounded footprint, so sliding the card
// left reveals a clean rounded red edge — no clipping, no square corners.

private struct LotSwipeCard: View {
    let lot: InvestmentLot
    let holding: InvestmentHolding
    var onTap: () -> Void
    var onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var start: CGFloat? = nil
    @State private var crossedFull = false

    private let actionWidth: CGFloat = 84
    private let openThreshold: CGFloat = 44
    private let fullThreshold: CGFloat = 220
    private var revealed: CGFloat { max(0, -offset) }
    private var isFull: Bool { revealed >= fullThreshold }

    var body: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(AppTheme.red)
                .overlay(alignment: .trailing) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 }
                        onDelete()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "trash.fill").font(.system(.body, weight: .semibold))
                            Text(loc("common.delete")).font(.system(.caption2, weight: .bold))
                        }
                        .foregroundStyle(AppTheme.onVividFill)
                        .frame(width: actionWidth)
                        .scaleEffect(isFull ? 1.12 : 1)
                        .opacity(revealed > 6 ? 1 : 0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isFull)
                    }
                    .buttonStyle(.plain)
                }

            LotRow(lot: lot, holding: holding)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                .offset(x: offset)
                .gesture(drag)
                .onTapGesture {
                    if offset != 0 {
                        withAnimation(.spring(response: 0.3)) { offset = 0 }
                    } else {
                        onTap()
                    }
                }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { v in
                if start == nil {
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    start = offset
                }
                guard let s = start else { return }
                var next = s + v.translation.width
                if next > 0 { next = 0 }
                if next < -actionWidth {                       // rubber-band past the button
                    next = -actionWidth - (-(next) - actionWidth) * 0.45
                }
                offset = next
                if revealed >= fullThreshold, !crossedFull {
                    crossedFull = true; HapticManager.shared.tap()
                } else if revealed < fullThreshold, crossedFull {
                    crossedFull = false
                }
            }
            .onEnded { _ in
                start = nil
                let didFull = revealed >= fullThreshold
                crossedFull = false
                if didFull {
                    HapticManager.shared.warning()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 }
                    onDelete()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                        offset = revealed >= openThreshold ? -actionWidth : 0
                    }
                }
            }
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
