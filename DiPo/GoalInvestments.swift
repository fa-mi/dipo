import SwiftUI
import SwiftData

// MARK: - A savings goal kept in investments
//
// Fahmi's trip to Mecca is saved in BBRI shares, at two brokers. The goal said
// Rp 30.500.000, typed in once, while the shares sat on the Investments screen
// at their market value: the goal never moved with the price, and Home added
// the same money to net worth twice.
//
// A goal can now be kept in investments. Each holding belongs to one goal at
// most (`InvestmentHolding.goal`), and the goal counts its holdings at today's
// price on top of the cash it holds itself (`savedAmount`). Because that value
// moves:
//   • the goal shows what the holdings cost beside what they are worth;
//   • its date is estimated from today's value and the monthly plan, with no
//     guess at a return — that would be investment advice;
//   • reaching the target on today's price is not finishing it: prices can
//     fall back, so the goal is done when the person says so;
//   • within two years of its date, it says what a 20% fall would take off.
//
// Net worth counts the holdings once, on its investments line; the goal adds
// only its cash (`netWorthContribution`).

extension InvestmentType {
    /// A price that can move a long way in a few months: shares, funds, coins.
    var swings: Bool { self == .stock || self == .mutualFund || self == .crypto }
}

extension SavingsGoal {
    private func inGoalCurrency(_ value: Double, of holding: InvestmentHolding) -> Double {
        CurrencyManager.shared.convert(value, from: holding.currency, to: currency)
    }

    var isInvested: Bool { !holdings.isEmpty }

    /// "Stocks" when every holding is one kind, "Investments" otherwise.
    var investedKindLabel: String {
        let kinds = Set(holdings.map(\.type))
        if kinds.count == 1, let kind = kinds.first { return kind.displayName }
        return loc("savings.invest_kinds")
    }

    /// The holdings at today's price, in the goal's currency.
    var investedValue: Double {
        holdings.reduce(0) { $0 + inGoalCurrency($1.stats().marketValue, of: $1) }
    }

    /// What the units still held cost, in the goal's currency.
    var investedCost: Double {
        holdings.reduce(0) { $0 + inGoalCurrency($1.stats().costBasis, of: $1) }
    }

    /// Everything in the goal: its cash, and its investments at today's price.
    var currentValue: Double { savedAmount + investedValue }

    /// The part of `investedValue` whose price swings.
    var swingingValue: Double {
        holdings.filter(\.type.swings).reduce(0) { $0 + inGoalCurrency($1.stats().marketValue, of: $1) }
    }

    /// At the target on today's price, with some of it in prices that can fall back.
    var reachedOnTodaysPrice: Bool { progress >= 1.0 && swingingValue > 0.5 }

    /// Within two years of the goal's date, what a 20% fall in its swinging
    /// prices would take off, and that date: the goal's own, or the one its
    /// monthly plan reaches. Nil further out, or with nothing that swings.
    func fallNote(now: Date = .now) -> (date: Date, loss: Double)? {
        guard swingingValue > 0.5, let date = targetDate ?? estimatedDate,
              let limit = Calendar.current.date(byAdding: .month, value: 24, to: now),
              date <= limit else { return nil }
        return (date, swingingValue * 0.2)
    }

    /// Keeps the goal in exactly `chosen`. A holding kept for another goal
    /// moves here; one no longer chosen is kept for no goal.
    func keep(in chosen: [InvestmentHolding]) {
        let ids = Set(chosen.map(\.id))
        for h in holdings where !ids.contains(h.id) { h.goal = nil }
        for h in chosen where h.goal?.id != id { h.goal = self }
    }
}

// MARK: - Fresh prices
//
// Prices were fetched only when the Investments screen opened, so a goal
// showed whatever they were then. The goals' screens now fetch the ones their
// goals count when they open, and every one of them on a pull.

enum GoalPrices {
    /// A quote older than this is fetched again when a goal is looked at. The
    /// stock feed runs about 15 minutes behind the market anyway.
    static let maxAge: TimeInterval = 15 * 60

    /// The auto-priced holdings among `holdings` whose price is older than
    /// `maxAge`, or was never fetched.
    static func stale(_ holdings: [InvestmentHolding], now: Date = .now) -> [InvestmentHolding] {
        holdings.filter { h in
            h.isAutoPriced && (h.priceUpdatedAt.map { now.timeIntervalSince($0) > maxAge } ?? true)
        }
    }

    /// Fetches the stale ones, or with `force` every auto-priced one. A
    /// failed fetch leaves the last price as it was.
    static func refresh(_ holdings: [InvestmentHolding], context: ModelContext, force: Bool = false) async {
        let targets = force ? holdings.filter(\.isAutoPriced) : stale(holdings)
        guard !targets.isEmpty else { return }
        await PriceService.refresh(targets, context: context)
    }
}

// MARK: - On the goal's screen

/// The goal's investments, what they are worth today against what they cost,
/// and the way to choose them. Shown to a Royal account that tracks
/// investments, or on a goal already kept in some.
struct GoalInvestmentsCard: View {
    let goal: SavingsGoal
    let onChoose: () -> Void

    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: goal.currency) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FormSectionLabel(text: loc("savings.invest_title"))
            if goal.isInvested {
                VStack(spacing: 10) {
                    ForEach(goal.holdings.sorted { $0.sortOrder < $1.sortOrder }) { h in
                        holdingRow(h)
                    }
                }
                Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1)
                figures
                if let note = goal.fallNote() {
                    Label(String(format: loc("savings.invest_fall"),
                                 note.date.formatted(.dateTime.month(.abbreviated).year()), money(note.loss)),
                          systemImage: "exclamationmark.triangle")
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(loc("savings.invest_how"))
                    .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(loc("savings.invest_empty"))
                    .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                HapticManager.shared.tap(); onChoose()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.system(.footnote, weight: .semibold))
                    Text(loc(goal.isInvested ? "savings.invest_change" : "savings.invest_choose"))
                        .font(.system(.subheadline, weight: .semibold))
                }
                .foregroundStyle(AppTheme.textPrimary)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(AppTheme.cardMid.opacity(0.7), in: RoundedRectangle(cornerRadius: AppRadius.md))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private func holdingRow(_ h: InvestmentHolding) -> some View {
        let value = CurrencyManager.shared.convert(h.stats().marketValue, from: h.currency, to: goal.currency)
        return HStack(spacing: 10) {
            Image(systemName: h.type.icon)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(h.type.color)
                .frame(width: 32, height: 32)
                .background(h.type.color.opacity(0.15), in: RoundedRectangle(cornerRadius: AppRadius.sm))
            VStack(alignment: .leading, spacing: 1) {
                Text(h.name).font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                Text(holdingSubtitle(h)).font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(money(value)).font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    /// When the oldest of the prices it counts was fetched.
    private var pricedAt: Date? {
        goal.holdings.filter(\.isAutoPriced).compactMap(\.priceUpdatedAt).min()
    }

    /// Worth today, what it cost, and the difference, as the Investments
    /// screen words them.
    private var figures: some View {
        let gain = goal.investedValue - goal.investedCost
        let pct = goal.investedCost > 0 ? gain / goal.investedCost : 0
        return VStack(spacing: 6) {
            figure(loc("savings.invest_worth"), money(goal.investedValue))
            figure(loc("savings.invest_cost"), money(goal.investedCost))
            if let t = pricedAt {
                figure(loc("invest.last_updated"), t.formatted(date: .abbreviated, time: .shortened))
            }
            HStack(spacing: 4) {
                Text(loc("invest.pl_short")).font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                Spacer(minLength: 8)
                if let arrow = investArrow(investTrendPct(pct)) {
                    Image(systemName: arrow).font(.system(size: 10, weight: .bold))
                }
                Text(investSigned(gain, goal.currency) + " · " + investPctAbs(pct))
                    .font(.system(.subheadline, weight: .semibold))
            }
            .foregroundStyle(investPLColorPct(pct))
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
            Spacer(minLength: 8)
            Text(value).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
        }
    }
}

/// "Stocks · BBRI" — the type and the symbol, as a holding is known.
func holdingSubtitle(_ h: InvestmentHolding) -> String {
    h.symbol.isEmpty ? h.type.displayName : h.type.displayName + " · " + h.symbol.uppercased()
}

// MARK: - Choosing them

/// Every holding, ticked when it is kept for this goal. One kept for another
/// goal says which, and choosing it moves it here.
struct GoalHoldingsPicker: View {
    let goal: SavingsGoal
    let holdings: [InvestmentHolding]
    /// After saving: whether the goal was kept in no investments before.
    let onSaved: (_ firstTime: Bool) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(loc("savings.invest_pick_sub"))
                            .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 0) {
                            ForEach(Array(holdings.enumerated()), id: \.element.id) { i, h in
                                if i > 0 {
                                    Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 58)
                                }
                                row(h)
                            }
                        }
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                    }
                    .padding(.horizontal, 22).padding(.vertical, 16)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("savings.invest_pick_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("common.save")) { save() }.fontWeight(.semibold)
                }
            }
        }
        .onAppear { chosen = Set(goal.holdings.map(\.id)) }
    }

    private func row(_ h: InvestmentHolding) -> some View {
        let on = chosen.contains(h.id)
        let elsewhere = h.goal.flatMap { $0.id == goal.id ? nil : $0 }
        let value = CurrencyManager.shared.convert(h.stats().marketValue, from: h.currency, to: goal.currency)
        return Button {
            HapticManager.shared.select()
            if on { chosen.remove(h.id) } else { chosen.insert(h.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: h.type.icon)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(h.type.color)
                    .frame(width: 34, height: 34)
                    .background(h.type.color.opacity(0.15), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.name).font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                    Text(holdingSubtitle(h) + " · " + CurrencyManager.shared.formatted(value, currency: goal.currency))
                        .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary).lineLimit(1)
                    if let other = elsewhere {
                        Text(String(format: loc("savings.invest_for_other"), other.emoji + " " + other.name))
                            .font(.system(.caption)).foregroundStyle(AppTheme.orange).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(.title3))
                    .foregroundStyle(on ? AppTheme.accent : AppTheme.textSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        let firstTime = !goal.isInvested && !chosen.isEmpty
        goal.keep(in: holdings.filter { chosen.contains($0.id) })
        try? context.save()
        HapticManager.shared.success()
        dismiss()
        onSaved(firstTime)
    }
}
