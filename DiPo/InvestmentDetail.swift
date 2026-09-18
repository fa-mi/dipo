import SwiftUI
import SwiftData

// MARK: - Holding detail

/// The one sheet the detail screen presents, routed through a single binding so
/// stacked .sheet modifiers can't clobber one another.
private enum DetailSheet: Identifiable {
    case addLot(InvestmentLotKind)
    case editLot(InvestmentLot)
    case price
    var id: String {
        switch self {
        case .addLot(let k):    return "add-\(k.rawValue)"
        case .editLot(let l):   return "edit-\(l.id.uuidString)"
        case .price:            return "price"
        }
    }
}

/// What a delete confirmation targets. Drives the centered modal.
private enum DeleteTarget: Identifiable {
    case lot(InvestmentLot)
    case holding
    var id: String {
        switch self {
        case .lot(let l): return "lot-\(l.id.uuidString)"
        case .holding:    return "holding"
        }
    }
    var title: String { loc(self.isLot ? "invest.delete_lot" : "invest.delete_holding") }
    var message: String { loc(self.isLot ? "invest.delete_lot_msg" : "invest.delete_holding_msg") }
    var confirmLabel: String { title }
    private var isLot: Bool { if case .lot = self { return true }; return false }
}

struct HoldingDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var holding: InvestmentHolding

    @State private var sheet: DetailSheet? = nil
    @State private var pendingDelete: DeleteTarget? = nil

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
                    .containerRelativeFrame(.horizontal)
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
                }
            }
            // Delete confirmation is a CENTERED modal, not a bottom sheet — no
            // leftover space above the home indicator, and it reads as a decision.
            .overlay {
                if let target = pendingDelete {
                    CenterConfirmModal(
                        title: target.title,
                        message: target.message,
                        confirmLabel: target.confirmLabel,
                        onConfirm: {
                            withAnimation(.easeOut(duration: 0.2)) { pendingDelete = nil }
                            switch target {
                            case .lot(let lot): deleteLot(lot)
                            case .holding:      deleteHolding()
                            }
                        },
                        onCancel: { withAnimation(.easeOut(duration: 0.2)) { pendingDelete = nil } }
                    )
                    .transition(.opacity)
                    .zIndex(10)
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
                Button(role: .destructive) {
                    withAnimation(.easeOut(duration: 0.2)) { pendingDelete = .holding }
                } label: {
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
                       investPLColor(s.unrealizedPL), trend: investTrend(s.unrealizedPL))
                if investTrend(s.todayChange) != 0 {
                    plChip(loc("invest.today") + " " + investSigned(s.todayChange, cur),
                           investPLColor(s.todayChange), trend: investTrend(s.todayChange))
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

    private func plChip(_ text: String, _ tint: Color, trend: Int) -> some View {
        HStack(spacing: 4) {
            if let arrow = investArrow(trend) {
                Image(systemName: arrow).font(.system(.caption2, weight: .bold))
            }
            Text(text).font(.system(.caption, weight: .bold))
        }
        .foregroundStyle(tint).padding(.horizontal, 10).padding(.vertical, 5)
        .background(tint.opacity(0.15), in: Capsule())
    }

    private var priceChartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc("invest.price_chart")).font(.system(.caption, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            MiniSparkline(values: holding.priceHistory, trend: investTrend(s.unrealizedPL)).frame(height: 70)
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
            // Proof the refresh ran even when the price itself didn't move.
            if let t = holding.priceUpdatedAt {
                rowDivider
                detailRow(loc("invest.last_updated"),
                          t.formatted(date: .abbreviated, time: .shortened))
            }
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
                actionButton(loc("invest.update_price_short"), "arrow.triangle.2.circlepath", AppTheme.textSecondary) { sheet = .price }
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
                Text(title).font(.system(.caption, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.95)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    // One card holding the transaction rows — same recipe as Home's list, so the
    // swipe reveals the SAME round red Delete button. Rows share the card's fill,
    // so they slide cleanly under it and the corners stay rounded (no clip needed).
    // Hairline dividers separate the header and each row so the list reads as one.
    private var lotsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc("invest.lots")).font(.system(.body, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                .padding(.bottom, 12)
            if holding.lots.isEmpty {
                Text(loc("invest.empty_lots")).font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary).frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                let sorted = holding.lots.sorted { $0.date > $1.date }
                ForEach(Array(sorted.enumerated()), id: \.element.id) { i, lot in
                    lotDivider   // line under the header, and between rows
                    // Tap to edit, swipe left for the round Delete (then confirm).
                    SwipeToDeleteRow(
                        onTap: { HapticManager.shared.tap(); sheet = .editLot(lot) },
                        onDelete: { withAnimation(.easeOut(duration: 0.2)) { pendingDelete = .lot(lot) } }
                    ) {
                        LotRow(lot: lot, holding: holding)
                    }
                    .contextMenu {
                        Button { sheet = .editLot(lot) } label: {
                            Label(loc("invest.edit_lot"), systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            withAnimation(.easeOut(duration: 0.2)) { pendingDelete = .lot(lot) }
                        } label: {
                            Label(loc("invest.delete_lot"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }

    private var lotDivider: some View {
        Rectangle().fill(AppTheme.cardMid.opacity(0.6)).frame(height: 1)
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
        // Vertical only — the enclosing card supplies the horizontal inset, so a
        // swipe slides the row cleanly under the card edge (same as Home's list).
        .padding(.vertical, 12)
        // The swipe action (44pt circle + its "Delete" caption) is taller than the
        // text; without this floor it grew the row and spilled over the dividers.
        .frame(minHeight: 76)
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

// MARK: - Centered confirm modal
//
// A decision that sits in the middle of the screen instead of a bottom sheet:
// no wasted space above the home indicator, and a dimmed backdrop that reads as
// "stop and choose". Tap the backdrop or Cancel to back out.

private struct CenterConfirmModal: View {
    let title: String
    let message: String
    let confirmLabel: String
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.5 : 0).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }
            card
                .scaleEffect(shown ? 1 : 0.9)
                .opacity(shown ? 1 : 0)
        }
        .onAppear {
            HapticManager.shared.warning()
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { shown = true }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(AppTheme.red.opacity(0.12)).frame(width: 76, height: 76)
                Circle().stroke(AppTheme.red.opacity(0.25), lineWidth: 1.5).frame(width: 76, height: 76)
                Image(systemName: "trash.fill").font(.system(size: 30, weight: .semibold)).foregroundStyle(AppTheme.red)
            }
            .padding(.top, 26)

            VStack(spacing: 8) {
                Text(title).font(.system(.title3, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary).multilineTextAlignment(.center)
                Text(message).font(.system(.subheadline))
                    .foregroundStyle(AppTheme.textSecondary).multilineTextAlignment(.center)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24).padding(.top, 16)

            VStack(spacing: 10) {
                Button { onConfirm() } label: {
                    Text(confirmLabel).font(.system(.body, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(AppTheme.red, in: RoundedRectangle(cornerRadius: AppRadius.md))
                }
                .buttonStyle(ScaleButtonStyle())
                Button { onCancel() } label: {
                    Text(loc("common.cancel")).font(.system(.body, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(AppTheme.bg, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.cardMid, lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 22)
        }
        .frame(maxWidth: 360)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(AppTheme.cardMid.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
        .padding(.horizontal, 36)
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
                    .fixedSize(horizontal: false, vertical: true)
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
