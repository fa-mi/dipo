import SwiftUI
import SwiftData

// MARK: - Shared form pieces
//
// Two entry shapes cover every instrument: UNIT-based (gold, stocks, mutual
// funds, crypto — you buy a quantity at a price) and AMOUNT-based (deposits and
// bonds — you put in a rupiah amount, the "price" is a ratio). Storing the
// amount-based ones as units == amount with a per-unit price of 1 keeps
// PortfolioEngine identical for both.

extension InvestmentType {
    /// True when the user thinks in a rupiah amount, not a quantity × price.
    var isAmountBased: Bool { self == .deposit || self == .bond || self == .pension }

    /// The value-per-rupiah an amount-based holding opens at: what it is worth
    /// now over what went in. Left empty, it is worth what went in — not
    /// nothing, which is how a bond saved without "Value now" showed Rp 0.
    func openingRatio(amount: Double, valueNow: Double) -> Double {
        guard !priceIsFixed, amount > 0, valueNow > 0 else { return 1 }
        return valueNow / amount
    }
}

// MARK: - Card top-up
//
// Investments are tracked standalone, but a purchase can optionally be funded
// from a card — the money really left that account. It's recorded in the
// Investment category, the way a savings-goal deposit is: that puts it in Smart
// Budget's "Invest & Debt" pot, which is what that pot is for. It used to be a
// transfer filed under Other, so investing never showed against the pot and a
// steady investor read as putting nothing aside. Daily and Lifestyle never see
// it, and the recommendation engine treats it as money set aside, not consumed.
// The lot keeps the transaction's id so deleting the lot reverses the outflow.

enum InvestmentCash {
    @MainActor @discardableResult
    static func recordOutflow(holding: InvestmentHolding, cost: Double, card: BankCard, date: Date) -> String {
        let amt = CurrencyManager.shared.convert(cost, from: holding.currency, to: card.resolvedCurrency)
        let tx = TxRecord(name: holding.name, date: date, amount: -abs(amt),
                          type: "tx.type.purchase", icon: holding.type.icon,
                          iconBgHex: TxCategory.investment.iconBg,
                          category: .investment, currency: card.resolvedCurrency,
                          notes: "tx.note.invest_buy")
        card.transactions.append(tx)
        return tx.id.uuidString
    }

    /// Purchases recorded before this changed are transfers under Other. Moves
    /// the ones DiPo itself made (linked from a lot) into Investment, once each:
    /// a transaction the user has since recategorised is left alone.
    @MainActor
    static func reclassifyLegacyOutflows(_ holdings: [InvestmentHolding], context: ModelContext) {
        let ids = Set(holdings.flatMap(\.lots).compactMap { UUID(uuidString: $0.linkedCardTxID) })
        guard !ids.isEmpty else { return }
        let d = FetchDescriptor<TxRecord>(predicate: #Predicate { $0.subtype == "transfer" })
        guard let txs = try? context.fetch(d) else { return }
        var changed = false
        for tx in txs where ids.contains(tx.id) && isLegacyOutflow(tx) {
            tx.category = .investment
            tx.txSubtype = .normal
            tx.notes = "tx.note.invest_buy"
            changed = true
        }
        guard changed else { return }
        try? context.save()
        // The rollup cache only notices a change in transaction COUNT, and
        // this keeps the count: rebuild so Smart Budget sees the move now.
        RollupStore.shared.rebuild(context: context)
    }

    /// The shape the old `recordOutflow` wrote: a transfer out, filed as Other.
    static func isLegacyOutflow(_ tx: TxRecord) -> Bool {
        tx.txSubtype == .transfer && tx.category == .other && tx.amount < 0
    }

    @MainActor
    static func reverse(_ txID: String, context: ModelContext) {
        guard !txID.isEmpty, let uuid = UUID(uuidString: txID) else { return }
        let d = FetchDescriptor<TxRecord>(predicate: #Predicate { $0.id == uuid })
        if let tx = try? context.fetch(d).first { context.delete(tx) }
    }
}

/// A row of card chips (plus "don't deduct") for funding a purchase. Each card
/// wears its own bank gradient so it reads like the card it is, not a word.
struct CardFundPicker: View {
    let cards: [BankCard]
    @Binding var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc("invest.fund_from")).font(.system(.caption, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    noneChip
                    ForEach(cards, id: \.id) { cardChip($0) }
                }
                .padding(.vertical, 3)   // breathing room for the selected ring
            }
        }
    }

    private var noneChip: some View {
        let on = selectedID == nil
        return Button { HapticManager.shared.tap(); selectedID = nil } label: {
            HStack(spacing: 9) {
                Image(systemName: "nosign")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(on ? AppTheme.accent : AppTheme.textSecondary)
                    .frame(width: 34, height: 24)
                    .background(AppTheme.cardMid.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                Text(loc("invest.fund_none"))
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(on ? AppTheme.textPrimary : AppTheme.textSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(on ? AppTheme.accent : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func cardChip(_ c: BankCard) -> some View {
        let on = selectedID == c.id.uuidString
        let g = BankIssuer.resolveGradient(issuerID: c.issuerID, cardNumber: c.cardNumber)
        let name = c.isDigitalWallet && !c.walletProvider.isEmpty ? c.walletProvider
                 : (c.holderName.isEmpty ? loc("card.untitled") : c.holderName)
        return Button { HapticManager.shared.tap(); selectedID = c.id.uuidString } label: {
            HStack(spacing: 9) {
                // A mini card face — the bank's gradient with a chip glint.
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Color(hex: g.start), Color(hex: g.end)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 24)
                    .overlay(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 1.5).fill(.white.opacity(0.55))
                            .frame(width: 7, height: 5).padding(4)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.15), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                    if !c.last4.isEmpty {
                        Text("•• \(c.last4)").font(.system(.caption2))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(on ? AppTheme.accent : Color.clear, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if on {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.accent)
                        .background(Circle().fill(AppTheme.bg).padding(-1))
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// A labelled numeric input styled like the rest of the app's forms, with an
/// optional currency prefix ("Rp") or unit suffix ("gr") sitting inside the box.
struct MoneyField: View {
    let label: String
    var placeholder: String = "0"
    var prefix: String? = nil
    var suffix: String? = nil
    var hint: String? = nil
    var bg: Color = AppTheme.cardDark
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
            HStack(spacing: 6) {
                if let prefix {
                    Text(prefix).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                }
                TextField(placeholder, text: $text)
                    .keyboardType(.decimalPad)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .focused($focused)
                if let suffix {
                    Text(suffix).font(.system(.caption, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(bg, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(focused ? AppTheme.accent.opacity(0.7) : Color.clear, lineWidth: 1.5))
            if let hint {
                Text(hint).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary.opacity(0.85))
                    // Wrap rather than widen: in a two-column row the hint's
                    // natural width is what decides the column's, and a long one
                    // squeezes whatever sits beside it.
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
        }
    }
}

struct PlainField: View {
    let label: String
    var placeholder: String = ""
    var bg: Color = AppTheme.cardDark
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
            TextField(placeholder, text: $text)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(bg, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(focused ? AppTheme.accent.opacity(0.7) : Color.clear, lineWidth: 1.5))
        }
    }
}

/// Parse a user-typed number — see InvestmentInput.number for the rules.
private func parseNumber(_ s: String) -> Double { InvestmentInput.number(s) }

// MARK: - Price mode, derived figures, gold check
//
// Unit-based instruments ask for a price, and the person may know it either
// per unit (a broker's "avg cost") or only as a total (a gold app's balance).
// Both are accepted; the lot always stores the per-unit price.

/// A row of capsule choices, the same look as the lot-kind picker.
private struct ChoiceChips<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option
    /// Fill of an unselected chip — the ground it sits on decides it.
    var idle: Color = AppTheme.bg
    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { o in
                Button {
                    HapticManager.shared.tap()
                    withAnimation(.spring(response: 0.3)) { selection = o }
                } label: {
                    Text(title(o))
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(selection == o ? AppTheme.onVividFill : AppTheme.textSecondary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background((selection == o ? AppTheme.accent : idle), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PriceModeChips: View {
    let unitLabel: String
    @Binding var mode: InvestmentInput.PriceMode
    var idle: Color = AppTheme.bg
    var options: [InvestmentInput.PriceMode] = InvestmentInput.PriceMode.standard
    var body: some View {
        ChoiceChips(options: options, title: {
            switch $0 {
            case .perUnit:      return String(format: loc("invest.price_mode.per_unit"), unitLabel)
            case .perHundredth: return loc("invest.price_mode.per_hundredth")
            case .total:        return loc("invest.price_mode.total")
            }
        }, selection: $mode, idle: idle)
    }
}

/// The other half of what was typed: the per-unit price behind a total, or
/// the total behind a per-unit price — so the figure the app will use is on
/// screen before it is saved.
private struct DerivedLine: View {
    let text: String
    var body: some View {
        Text(text).font(.system(.caption, weight: .medium))
            .foregroundStyle(AppTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shown when a per-gram gold price is off by an order of magnitude — most
/// often a total typed where a per-gram price belongs. It warns, never blocks.
private struct GoldPriceWarning: View {
    let perGram: Double
    let currency: String
    /// The one-tap fix, when there is one: switch the field to "Total", or put
    /// in the per-gram price the total works out to.
    var fixTitle: String? = nil
    var fix: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(.caption))
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: loc("invest.gold_price_warning"), investMoney(perGram, currency)))
                    .font(.system(.caption, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let fixTitle, let fix {
                    Button {
                        HapticManager.shared.tap()
                        withAnimation(.spring(response: 0.3)) { fix() }
                    } label: {
                        Text(fixTitle).font(.system(.caption, weight: .bold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(AppTheme.amber.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .foregroundStyle(AppTheme.amber)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(AppTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

/// A price a whole power of ten away from the one it should be near — a lost
/// decimal point ("22306" for $223.06). Like the gold check, it warns and
/// offers the likely price; it never blocks.
private struct PriceSlipWarning: View {
    let price: Double
    let suggestion: Double
    /// What the price was compared with, already worded: "the market price
    /// ($333.69)", "your average buy ($223.06)".
    let against: String
    let currency: String
    let fix: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(.caption))
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: loc("invest.price_slip"), investMoney(price, currency), against))
                    .font(.system(.caption, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    HapticManager.shared.tap()
                    withAnimation(.spring(response: 0.3)) { fix() }
                } label: {
                    Text(String(format: loc("invest.price_slip_fix"), investMoney(suggestion, currency)))
                        .font(.system(.caption, weight: .bold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(AppTheme.amber.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(AppTheme.amber)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(AppTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

/// "the market price ($333.69)" / "your average buy ($223.06)".
private func slipAgainst(_ key: String, _ v: Double, _ cur: String) -> String {
    String(format: loc(key), investMoney(v, cur))
}

/// The per-unit price behind a price field. A total paid includes the fee and
/// a total received is net of it, so the fee is taken out (or added back)
/// before spreading; the lot's cost then comes back to exactly the total.
private func lotUnitPrice(_ entered: Double, units: Double, fee: Double,
                          mode: InvestmentInput.PriceMode, isSell: Bool) -> Double {
    guard mode == .total else { return InvestmentInput.perUnitPrice(entered, units: units, mode: mode) }
    let gross = isSell ? entered + fee : max(entered - fee, 0)
    return InvestmentInput.perUnitPrice(gross, units: units, mode: .total)
}

// MARK: - Add holding (creates the holding + its first purchase)

struct AddHoldingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    let nextOrder: Int

    @State private var fundCardID: String? = nil
    @State private var type: InvestmentType = .gold
    @State private var name = ""
    @State private var symbol = ""
    @State private var units = ""
    @State private var buyPrice = ""
    @State private var fee = ""
    @State private var current = ""
    @State private var amount = ""       // amount-based
    @State private var currentValue = "" // amount-based
    @State private var date = Date()
    /// Gold apps show a rupiah total, brokers a per-share price; gold starts
    /// on the total because that is the number its apps put in front of you.
    @State private var priceMode: InvestmentInput.PriceMode = .total
    @State private var market: StockMarket = .idx
    @State private var goldSource: GoldSource = .savings
    @State private var goldIsOther = false
    /// The name the gold choice filled in, so a later choice can replace it
    /// without overwriting one the user typed.
    @State private var autoName = ""

    /// A stock is kept in its market's currency (a US share in dollars, as the
    /// broker shows it); everything else in the preferred currency.
    private var cur: String { type == .stock ? market.currency : CurrencyManager.shared.preferredCurrency }
    private var curSymbol: String { CurrencyManager.symbol(for: cur) }

    private var unitsValue: Double { parseNumber(units) }
    private var buyUnitPrice: Double {
        lotUnitPrice(parseNumber(buyPrice), units: unitsValue, fee: parseNumber(fee), mode: priceMode, isSell: false)
    }
    private var currentUnitPrice: Double {
        InvestmentInput.perUnitPrice(parseNumber(current), units: unitsValue, mode: priceMode)
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if type.isAmountBased { return parseNumber(amount) > 0 }
        return unitsValue > 0 && buyUnitPrice > 0
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    typePicker

                    // What it is — name + (for auto types) the lookup symbol.
                    groupCard {
                        if type == .gold && cur.uppercased() == "IDR" {
                            GoldSourcePicker(source: $goldSource, isOther: $goldIsOther)
                        }
                        PlainField(label: loc("invest.field.name"), placeholder: loc("invest.field.name_ph"),
                                   bg: AppTheme.bg, text: $name)
                        if type == .stock {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(loc("invest.market")).font(.system(.caption, weight: .medium))
                                    .foregroundStyle(AppTheme.textSecondary)
                                ChoiceChips(options: StockMarket.allCases,
                                            title: { loc("invest.market.\($0.rawValue)") },
                                            selection: $market)
                                if market == .us {
                                    Text(loc("invest.market.us_hint")).font(.system(.caption2))
                                        .foregroundStyle(AppTheme.textSecondary.opacity(0.85))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if type.supportsAutoPrice {
                            PlainField(label: loc("invest.field.symbol"),
                                       placeholder: loc(type == .stock && market == .us
                                                        ? "invest.field.symbol_ph_us" : "invest.field.symbol_ph"),
                                       bg: AppTheme.bg, text: $symbol)
                        }
                    }

                    // First purchase — what you put in, grouped in its own card.
                    groupCard {
                        sectionHeader(loc("invest.first_buy"))
                        if type.isAmountBased {
                            // An amount-based holding has no unit price: what goes in
                            // is the rupiah put in, and what it is worth now.
                            MoneyField(label: loc(type == .pension ? "invest.field.contributed" : "invest.field.amount"),
                                       prefix: curSymbol,
                                       hint: type == .pension ? loc("invest.field.contributed_hint") : nil,
                                       bg: AppTheme.bg, text: $amount)
                            if !type.priceIsFixed {
                                MoneyField(label: loc("invest.field.current_total"), prefix: curSymbol,
                                           hint: loc(type == .pension ? "invest.field.pension_value_hint"
                                                                      : "invest.field.current_total_hint"),
                                           bg: AppTheme.bg, text: $currentValue)
                            }
                        } else {
                            PriceModeChips(unitLabel: type.unitLabel, mode: $priceMode)
                            // Two columns of equal width, aligned at the top.
                            // Without the explicit width an HStack hands each
                            // child its IDEAL width, and the long hint under
                            // "how many" made that column half again as wide as
                            // the price beside it. Both carry a hint now, so the
                            // two input boxes sit on the same line as well.
                            HStack(alignment: .top, spacing: 12) {
                                MoneyField(label: loc("invest.field.units"), suffix: type.unitLabel,
                                           hint: loc("invest.field.units_hint"), bg: AppTheme.bg, text: $units)
                                    .frame(maxWidth: .infinity)
                                MoneyField(label: buyLabel, prefix: curSymbol,
                                           hint: loc(priceMode == .total ? "invest.field.total_paid_hint"
                                                                         : "invest.field.price_hint"),
                                           bg: AppTheme.bg, text: $buyPrice)
                                    .frame(maxWidth: .infinity)
                            }
                            MoneyField(label: loc("invest.field.fee"), prefix: curSymbol, bg: AppTheme.bg, text: $fee)
                            if let line = derivedLine(entered: parseNumber(buyPrice), unitPrice: buyUnitPrice) {
                                DerivedLine(text: line)
                            }
                            if type == .gold, InvestmentInput.goldPriceLooksWrong(perGram: buyUnitPrice, currency: cur) {
                                GoldPriceWarning(perGram: buyUnitPrice, currency: cur,
                                                 fixTitle: priceMode == .perUnit ? loc("invest.gold_as_total") : nil,
                                                 fix: { priceMode = .total })
                            }
                            // Auto-priced instruments fetch the current price themselves,
                            // so there's nothing to type — say so instead of asking.
                            if type.supportsAutoPrice {
                                autoNote
                            } else {
                                MoneyField(label: currentLabel,
                                           placeholder: buyPrice.isEmpty ? "0" : buyPrice, prefix: curSymbol,
                                           hint: currentHint, bg: AppTheme.bg, text: $current)
                                if parseNumber(current) > 0,
                                   let line = derivedLine(entered: parseNumber(current), unitPrice: currentUnitPrice) {
                                    DerivedLine(text: line)
                                }
                                if type == .gold, !current.isEmpty,
                                   InvestmentInput.goldPriceLooksWrong(perGram: currentUnitPrice, currency: cur) {
                                    GoldPriceWarning(perGram: currentUnitPrice, currency: cur,
                                                     fixTitle: priceMode == .perUnit ? loc("invest.gold_as_total") : nil,
                                                     fix: { priceMode = .total })
                                }
                                if type != .gold, priceMode == .perUnit, !current.isEmpty,
                                   let meant = InvestmentInput.priceSlip(currentUnitPrice, reference: buyUnitPrice) {
                                    PriceSlipWarning(price: currentUnitPrice, suggestion: meant,
                                                     against: slipAgainst("invest.slip_vs_buy", buyUnitPrice, cur),
                                                     currency: cur,
                                                     fix: { current = InvestmentInput.text(meant) })
                                }
                            }
                        }
                    }

                    if !cards.isEmpty {
                        CardFundPicker(cards: cards, selectedID: $fundCardID)
                    }

                    dateRow

                    Spacer(minLength: 20)
                }
                .padding(22)
                .containerRelativeFrame(.horizontal)
            }
            .background(AppTheme.bg)
            .navigationTitle(loc("invest.add_holding"))
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: type) { _, t in
                priceMode = t == .gold ? .total : .perUnit
                if t == .gold {
                    suggestGoldName()
                } else if name.trimmingCharacters(in: .whitespaces) == autoName {
                    name = ""; autoName = ""
                }
            }
            .onChange(of: goldSource) { _, _ in suggestGoldName() }
            .onChange(of: goldIsOther) { _, _ in suggestGoldName() }
            .onAppear { if type == .gold { suggestGoldName() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("invest.save")) { save() }
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(canSave ? AppTheme.accent : AppTheme.textSecondary)
                        .disabled(!canSave)
                }
            }
        }
    }

    /// "Emas Antam", "Perhiasan 70%"… — only into an empty name or one the
    /// previous choice filled. "Other" leaves it to the user.
    private func suggestGoldName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty || trimmed == autoName else { return }
        let suggestion: String
        if goldIsOther {
            suggestion = ""
        } else {
            switch goldSource {
            case .savings, .manual:    suggestion = loc("gold.name.savings")
            case .bar(let b):          suggestion = String(format: loc("gold.name.bar"), b.displayName)
            case .jewelry(let purity): suggestion = String(format: loc("gold.src.jewelry_n"),
                                                           GoldSource.purityLabel(purity))
            }
        }
        name = suggestion
        autoName = suggestion
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc("invest.field.type")).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
            // A 3-column grid shows every type at once — no cut-off horizontal scroll.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(InvestmentType.allCases, id: \.self) { t in
                    Button {
                        HapticManager.shared.tap()
                        withAnimation(.spring(response: 0.3)) { type = t }
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: t.icon).font(.system(.title3))
                                .foregroundStyle(type == t ? t.color : AppTheme.textSecondary)
                                .frame(width: 40, height: 40)
                                .background((type == t ? t.color.opacity(0.18) : AppTheme.cardMid.opacity(0.45)), in: Circle())
                            Text(t.displayName).font(.system(.caption2, weight: .semibold))
                                .foregroundStyle(type == t ? AppTheme.textPrimary : AppTheme.textSecondary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background((type == t ? t.color.opacity(0.08) : AppTheme.cardDark),
                                    in: RoundedRectangle(cornerRadius: AppRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                            .stroke(type == t ? t.color : Color.clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // A grouped card: fields sit on the screen ground inside an elevated card,
    // giving each logical section a clear boundary without nesting same-tone fills.
    @ViewBuilder
    private func groupCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t).font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
    }

    private var buyLabel: String {
        priceMode == .total ? loc("invest.field.total_paid")
            : String(format: loc("invest.field.price_per"), type.unitLabel)
    }

    private var currentLabel: String {
        priceMode == .total ? loc("invest.field.current_total")
            : String(format: loc("invest.field.current_per"), type.unitLabel)
    }

    private var currentHint: String {
        if priceMode == .total { return loc("invest.field.current_total_hint") }
        return loc(type == .gold ? "invest.gold_sell_hint" : "invest.field.current_hint")
    }

    /// "≈ Rp2.251.774 per gr" under a total, "Total ≈ Rp294.532" under a
    /// per-unit price; nothing until both the quantity and the price are in.
    private func derivedLine(entered: Double, unitPrice: Double) -> String? {
        guard unitsValue > 0, entered > 0, unitPrice > 0 else { return nil }
        if priceMode == .total {
            return String(format: loc("invest.derived_per_unit"), investMoney(unitPrice, cur), type.unitLabel)
        }
        return String(format: loc("invest.derived_total"), investMoney(unitsValue * unitPrice, cur))
    }

    private var autoNote: some View {
        HStack(spacing: 7) {
            Image(systemName: "bolt.fill").font(.system(.caption2, weight: .bold))
            Text(loc("invest.auto_price_note")).font(.system(.caption, weight: .medium))
        }
        .foregroundStyle(AppTheme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var dateRow: some View {
        HStack {
            Text(loc("invest.field.date")).font(.system(.subheadline, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            DatePicker("", selection: $date, in: ...Date(), displayedComponents: .date)
                .labelsHidden().tint(AppTheme.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func save() {
        let holdingUnits: Double
        let price: Double
        let lastPrice: Double
        if type.isAmountBased {
            let amt = parseNumber(amount)
            holdingUnits = amt
            price = 1
            lastPrice = type.openingRatio(amount: amt, valueNow: parseNumber(currentValue))
        } else {
            holdingUnits = unitsValue
            price = buyUnitPrice
            // Left empty, the current price defaults to the buy price.
            let c = parseNumber(current) > 0 ? currentUnitPrice : 0
            lastPrice = c > 0 ? c : price
        }
        let h = InvestmentHolding(type: type,
                                  name: name.trimmingCharacters(in: .whitespaces),
                                  symbol: symbol.trimmingCharacters(in: .whitespaces),
                                  currency: cur,
                                  lastPrice: lastPrice, prevClose: lastPrice,
                                  sortOrder: nextOrder)
        h.priceUpdatedAt = .now
        // Rupiah gold follows Pegadaian's daily price from the start (what
        // BRImo/Tring and Pegadaian show); it can be switched off on the
        // holding. The price typed here stands until the first refresh.
        if type == .gold { h.setGoldSource(goldSource) }
        h.pushPrice(price); h.pushPrice(lastPrice)   // seed the sparkline: buy → now
        context.insert(h)
        let lot = InvestmentLot(kind: .buy, date: date, units: holdingUnits,
                                pricePerUnit: price, fee: parseNumber(fee))
        // Optionally take the cost out of a card, as a transfer.
        if let id = fundCardID, let card = cards.first(where: { $0.id.uuidString == id }) {
            let cost = holdingUnits * price + parseNumber(fee)
            lot.linkedCardTxID = InvestmentCash.recordOutflow(holding: h, cost: cost, card: card, date: date)
        }
        h.lots.append(lot)
        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}

// MARK: - Add lot to an existing holding

struct AddLotSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @Bindable var holding: InvestmentHolding
    let initialKind: InvestmentLotKind

    @State private var fundCardID: String? = nil
    @State private var kind: InvestmentLotKind = .buy
    @State private var units = ""
    @State private var price = ""
    @State private var fee = ""
    @State private var amount = ""   // amount-based buy/sell, or cash for income/fee
    @State private var date = Date()
    @State private var note = ""
    @State private var priceMode: InvestmentInput.PriceMode = .perUnit

    private var cur: String { holding.currency }
    private var curSymbol: String { CurrencyManager.symbol(for: cur) }
    private var unitPrice: Double {
        lotUnitPrice(parseNumber(price), units: parseNumber(units), fee: parseNumber(fee),
                     mode: priceMode, isSell: kind == .sell)
    }
    private var availableKinds: [InvestmentLotKind] {
        var ks: [InvestmentLotKind] = [.buy]
        if holding.stats().unitsHeld > 0 { ks.append(.sell) }
        switch holding.type {
        case .stock, .mutualFund, .crypto: ks.append(.dividend)
        case .bond, .deposit: ks.append(.coupon)
        case .gold, .pension: break
        }
        ks.append(.fee)
        return ks
    }

    private var canSave: Bool {
        if kind.isCash { return parseNumber(amount) > 0 }
        if holding.type.isAmountBased { return parseNumber(amount) > 0 }
        return parseNumber(units) > 0 && unitPrice > 0
    }

    /// A sale is not a purchase: the field has to say which price it is asking
    /// for, or the number typed into "Harga beli" on the Jual tab is the wrong
    /// one entirely. It also says whether it wants one unit's price or the total.
    private var priceLabel: String {
        switch (priceMode, kind == .sell) {
        case (.total, false): return loc("invest.field.total_paid")
        case (.total, true):  return loc("invest.field.total_received")
        case (_, false):      return String(format: loc("invest.field.price_per"), holding.type.unitLabel)
        case (_, true):       return String(format: loc("invest.field.price_sell_per"), holding.type.unitLabel)
        }
    }

    private var derivedLine: String? {
        let u = parseNumber(units), entered = parseNumber(price)
        guard u > 0, entered > 0, unitPrice > 0 else { return nil }
        if priceMode == .total {
            return String(format: loc("invest.derived_per_unit"), investMoney(unitPrice, cur), holding.type.unitLabel)
        }
        return String(format: loc("invest.derived_total"), investMoney(u * unitPrice, cur))
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    kindPicker
                    if kind.isCash {
                        MoneyField(label: loc("invest.field.amount"), prefix: curSymbol, text: $amount)
                    } else if holding.type.isAmountBased {
                        MoneyField(label: loc("invest.field.amount"), prefix: curSymbol, text: $amount)
                    } else {
                        PriceModeChips(unitLabel: holding.type.unitLabel, mode: $priceMode, idle: AppTheme.cardDark)
                        HStack(alignment: .top, spacing: 12) {
                            MoneyField(label: loc("invest.field.units"), suffix: holding.type.unitLabel, text: $units)
                                .frame(maxWidth: .infinity)
                            MoneyField(label: priceLabel, prefix: curSymbol, text: $price)
                                .frame(maxWidth: .infinity)
                        }
                        MoneyField(label: loc("invest.field.fee"), prefix: curSymbol, text: $fee)
                        if let derivedLine { DerivedLine(text: derivedLine) }
                        if holding.type == .gold,
                           InvestmentInput.goldPriceLooksWrong(perGram: unitPrice, currency: cur) {
                            GoldPriceWarning(perGram: unitPrice, currency: cur,
                                             fixTitle: priceMode == .perUnit ? loc("invest.gold_as_total") : nil,
                                             fix: { priceMode = .total })
                        }
                        if holding.type != .gold, priceMode == .perUnit, !price.isEmpty,
                           let meant = InvestmentInput.priceSlip(unitPrice, reference: holding.lastPrice) {
                            PriceSlipWarning(price: unitPrice, suggestion: meant,
                                             against: slipAgainst("invest.slip_vs_market", holding.lastPrice, cur),
                                             currency: cur,
                                             fix: { price = InvestmentInput.text(meant) })
                        }
                    }
                    if kind == .buy && !cards.isEmpty {
                        CardFundPicker(cards: cards, selectedID: $fundCardID)
                    }
                    DatePicker(loc("invest.field.date"), selection: $date, in: ...Date(), displayedComponents: .date)
                        .font(.system(.subheadline, weight: .medium)).tint(AppTheme.accent)
                    PlainField(label: loc("invest.field.note"), text: $note)
                    Spacer(minLength: 20)
                }
                .padding(22)
                .containerRelativeFrame(.horizontal)
            }
            .background(AppTheme.bg)
            .navigationTitle(holding.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("invest.save")) { save() }
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(canSave ? AppTheme.accent : AppTheme.textSecondary)
                        .disabled(!canSave)
                }
            }
            .onAppear {
                kind = initialKind
                priceMode = holding.type == .gold ? .total : .perUnit
            }
        }
    }

    private var kindPicker: some View {
        HStack(spacing: 8) {
            ForEach(availableKinds) { k in
                Button {
                    HapticManager.shared.tap(); withAnimation(.spring(response: 0.3)) { kind = k }
                } label: {
                    Text(loc("invest.kind.\(k.rawValue)"))
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(kind == k ? AppTheme.onVividFill : AppTheme.textSecondary)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background((kind == k ? AppTheme.accent : AppTheme.cardDark), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func save() {
        let lot: InvestmentLot
        if kind.isCash {
            lot = InvestmentLot(kind: kind, date: date, cashAmount: parseNumber(amount), note: note)
        } else if holding.type.isAmountBased {
            lot = InvestmentLot(kind: kind, date: date, units: parseNumber(amount),
                                pricePerUnit: 1, note: note)
        } else {
            lot = InvestmentLot(kind: kind, date: date, units: parseNumber(units),
                                pricePerUnit: unitPrice, fee: parseNumber(fee), note: note)
        }
        // A buy can be funded from a card (transfer out).
        if kind == .buy, let id = fundCardID, let card = cards.first(where: { $0.id.uuidString == id }) {
            let cost = holding.type.isAmountBased
                ? parseNumber(amount)
                : parseNumber(units) * unitPrice + parseNumber(fee)
            lot.linkedCardTxID = InvestmentCash.recordOutflow(holding: holding, cost: cost, card: card, date: date)
        }
        holding.lots.append(lot)
        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}

// MARK: - Edit an existing lot (fix a typo in a recorded transaction)

struct EditLotSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @Bindable var holding: InvestmentHolding
    @Bindable var lot: InvestmentLot

    @State private var fundCardID: String? = nil
    @State private var units = ""
    @State private var price = ""
    @State private var fee = ""
    @State private var amount = ""   // amount-based buy/sell, or cash for income/fee
    @State private var date = Date()
    @State private var note = ""
    @State private var loaded = false

    private var cur: String { holding.currency }
    private var curSymbol: String { CurrencyManager.symbol(for: cur) }
    private var kind: InvestmentLotKind { lot.kind }

    private var canSave: Bool {
        if kind.isCash { return parseNumber(amount) > 0 }
        if holding.type.isAmountBased { return parseNumber(amount) > 0 }
        return parseNumber(units) > 0 && parseNumber(price) > 0
    }

    /// A sale is not a purchase: the field has to say which price it is asking
    /// for, or the number typed into "Harga beli" on the Jual tab is the wrong
    /// one entirely.
    private var priceLabel: String {
        String(format: loc(kind == .sell ? "invest.field.price_sell_per" : "invest.field.price_per"),
               holding.type.unitLabel)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    kindBadge
                    if kind.isCash {
                        MoneyField(label: loc("invest.field.amount"), prefix: curSymbol, text: $amount)
                    } else if holding.type.isAmountBased {
                        MoneyField(label: loc("invest.field.amount"), prefix: curSymbol, text: $amount)
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            MoneyField(label: loc("invest.field.units"), suffix: holding.type.unitLabel, text: $units)
                                .frame(maxWidth: .infinity)
                            MoneyField(label: priceLabel, prefix: curSymbol, text: $price)
                                .frame(maxWidth: .infinity)
                        }
                        MoneyField(label: loc("invest.field.fee"), prefix: curSymbol, text: $fee)
                        if parseNumber(units) > 0, parseNumber(price) > 0 {
                            DerivedLine(text: String(format: loc("invest.derived_total"),
                                                     investMoney(parseNumber(units) * parseNumber(price), cur)))
                        }
                        if holding.type == .gold,
                           InvestmentInput.goldPriceLooksWrong(perGram: parseNumber(price), currency: cur) {
                            GoldPriceWarning(perGram: parseNumber(price), currency: cur,
                                             fixTitle: totalFix.map { String(format: loc("invest.gold_use_per_gram"),
                                                                            investMoney($0, cur)) },
                                             fix: { if let v = totalFix { price = num(v) } })
                        }
                        if holding.type != .gold,
                           let meant = InvestmentInput.priceSlip(parseNumber(price), reference: holding.lastPrice) {
                            PriceSlipWarning(price: parseNumber(price), suggestion: meant,
                                             against: slipAgainst("invest.slip_vs_market", holding.lastPrice, cur),
                                             currency: cur,
                                             fix: { price = num(meant) })
                        }
                    }
                    if kind == .buy && !cards.isEmpty {
                        CardFundPicker(cards: cards, selectedID: $fundCardID)
                    }
                    DatePicker(loc("invest.field.date"), selection: $date, in: ...Date(), displayedComponents: .date)
                        .font(.system(.subheadline, weight: .medium)).tint(AppTheme.accent)
                    PlainField(label: loc("invest.field.note"), text: $note)
                    Spacer(minLength: 20)
                }
                .padding(22)
                .containerRelativeFrame(.horizontal)
            }
            .background(AppTheme.bg)
            .navigationTitle(loc("invest.edit_lot"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("invest.save")) { save() }
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(canSave ? AppTheme.accent : AppTheme.textSecondary)
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: preload)
        }
    }

    /// The kind is fixed on edit (changing buy↔sell would rewrite the maths and
    /// card funding) — show it as a read-only badge so the user knows what row
    /// they're fixing.
    private var kindBadge: some View {
        HStack(spacing: 7) {
            Image(systemName: "pencil").font(.system(.caption2, weight: .bold))
            Text(loc("invest.kind.\(lot.kindRaw)")).font(.system(.subheadline, weight: .semibold))
        }
        .foregroundStyle(AppTheme.textSecondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(AppTheme.cardDark, in: Capsule())
    }

    private func preload() {
        guard !loaded else { return }
        loaded = true
        date = lot.date
        note = lot.note
        if kind.isCash {
            amount = num(lot.cashAmount)
        } else if holding.type.isAmountBased {
            amount = num(lot.units)
        } else {
            units = num(lot.units)
            price = num(lot.pricePerUnit)
            fee = lot.fee > 0 ? num(lot.fee) : ""
        }
        // Pre-select the card that currently funds this lot, if any.
        if !lot.linkedCardTxID.isEmpty, let uuid = UUID(uuidString: lot.linkedCardTxID) {
            fundCardID = cards.first { c in c.transactions.contains { $0.id == uuid } }?.id.uuidString
        }
    }

    /// If the price field holds a total, the per-gram price it works out to —
    /// offered only when that one is plausible. A total paid includes the fee.
    private var totalFix: Double? {
        let u = parseNumber(units)
        guard u > 0 else { return nil }
        let v = lotUnitPrice(parseNumber(price), units: u, fee: parseNumber(fee),
                             mode: .total, isSell: kind == .sell).rounded()
        guard v > 0, !InvestmentInput.goldPriceLooksWrong(perGram: v, currency: cur) else { return nil }
        return v
    }

    /// Written so `parseNumber` reads it back unchanged (0.005 → "0,005").
    private func num(_ v: Double) -> String { InvestmentInput.text(v) }

    private func save() {
        if kind.isCash {
            lot.cashAmount = parseNumber(amount)
        } else if holding.type.isAmountBased {
            lot.units = parseNumber(amount)
            lot.pricePerUnit = 1
        } else {
            lot.units = parseNumber(units)
            lot.pricePerUnit = parseNumber(price)
            lot.fee = parseNumber(fee)
        }
        lot.date = date
        lot.note = note

        // Re-sync the card movement for buys: reverse the old one, then record a
        // fresh outflow if a card is (still) selected. Uniform across all cases —
        // same card, switched card, added, or removed.
        if kind == .buy {
            InvestmentCash.reverse(lot.linkedCardTxID, context: context)
            lot.linkedCardTxID = ""
            if let id = fundCardID, let card = cards.first(where: { $0.id.uuidString == id }) {
                let cost = holding.type.isAmountBased
                    ? parseNumber(amount)
                    : parseNumber(units) * parseNumber(price) + parseNumber(fee)
                lot.linkedCardTxID = InvestmentCash.recordOutflow(holding: holding, cost: cost, card: card, date: date)
            }
        }
        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}

// MARK: - Update current price

struct UpdatePriceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var holding: InvestmentHolding
    @State private var priceText = ""
    /// Unit-based holdings take one unit's price, what the whole balance is
    /// worth now (the figure a gold app shows first) or, for gold, the price
    /// per 0,01 gram exactly as BRImo/Tring and Pegadaian quote it.
    @State private var priceMode: InvestmentInput.PriceMode

    private var cur: String { holding.currency }
    private var amountBased: Bool { holding.type.isAmountBased }
    private var unitsHeld: Double { holding.stats().unitsHeld }
    /// Totals only make sense with something held to spread them over.
    private var offersTotal: Bool { !amountBased && unitsHeld > 0 }

    init(holding: InvestmentHolding) {
        _holding = Bindable(holding)
        _priceMode = State(initialValue: holding.type == .gold ? .perHundredth : .perUnit)
    }

    private var isGold: Bool { holding.type == .gold }
    private var modeOptions: [InvestmentInput.PriceMode] {
        isGold ? InvestmentInput.PriceMode.gold : InvestmentInput.PriceMode.standard
    }

    private var newUnitPrice: Double {
        let entered = parseNumber(priceText)
        if amountBased { return unitsHeld > 0 ? entered / unitsHeld : 1 }
        return InvestmentInput.perUnitPrice(entered, units: unitsHeld, mode: priceMode)
    }

    private var fieldHint: String? {
        guard isGold else { return nil }
        switch priceMode {
        case .perHundredth: return loc("invest.gold_hundredth_hint")
        case .perUnit:      return loc("invest.gold_sell_hint")
        case .total:        return loc("invest.field.current_total_hint")
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                if offersTotal || isGold {
                    PriceModeChips(unitLabel: holding.type.unitLabel, mode: $priceMode, idle: AppTheme.cardDark,
                                   options: offersTotal ? modeOptions : modeOptions.filter { $0 != .total })
                }
                MoneyField(label: fieldLabel, prefix: CurrencyManager.symbol(for: cur),
                           hint: fieldHint, text: $priceText)
                if !amountBased, parseNumber(priceText) > 0 {
                    // Both halves of what was typed: the price per gram it
                    // means, and what the whole balance is worth at it.
                    if priceMode != .perUnit {
                        DerivedLine(text: String(format: loc("invest.derived_per_unit"),
                                                 investMoney(newUnitPrice, cur), holding.type.unitLabel))
                    }
                    if priceMode != .total, unitsHeld > 0 {
                        DerivedLine(text: String(format: loc("invest.derived_total"),
                                                 investMoney(newUnitPrice * unitsHeld, cur)))
                    }
                }
                if !isGold, !amountBased, priceMode == .perUnit, !priceText.isEmpty,
                   let meant = InvestmentInput.priceSlip(newUnitPrice, reference: holding.stats().avgCost) {
                    PriceSlipWarning(price: newUnitPrice, suggestion: meant,
                                     against: slipAgainst("invest.slip_vs_avg", holding.stats().avgCost, cur),
                                     currency: cur,
                                     fix: { priceText = InvestmentInput.text(meant) })
                }
                if holding.type == .gold,
                   InvestmentInput.goldPriceLooksWrong(perGram: newUnitPrice, currency: cur) {
                    GoldPriceWarning(perGram: newUnitPrice, currency: cur,
                                     fixTitle: offersTotal && priceMode == .perUnit ? loc("invest.gold_as_total") : nil,
                                     fix: { priceMode = .total })
                }
                Spacer()
            }
            .padding(22)
            .background(AppTheme.bg)
            .navigationTitle(loc("invest.update_price"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("invest.save")) { save() }
                        .font(.system(.body, weight: .bold)).foregroundStyle(AppTheme.accent)
                        .disabled(newUnitPrice <= 0)
                }
            }
            .onAppear {
                if amountBased {
                    let shown = holding.stats().marketValue
                    if shown > 0 { priceText = InvestmentInput.text(shown.rounded()) }
                } else {
                    showLastPrice(in: priceMode)
                }
            }
            .onChange(of: priceMode) { _, mode in
                // Switch what is in the field along with its meaning.
                showLastPrice(in: mode)
            }
        }
    }

    /// The last price, written the way `mode` reads it. Keeps the cents of
    /// a dollar price (366,51, not 366).
    private func showLastPrice(in mode: InvestmentInput.PriceMode) {
        guard holding.lastPrice > 0 else { return }
        let v = InvestmentInput.entered(forUnitPrice: holding.lastPrice, units: unitsHeld, mode: mode)
        priceText = InvestmentInput.text(cur == "IDR" ? v.rounded() : (v * 100).rounded() / 100)
    }

    private var fieldLabel: String {
        if amountBased { return loc("invest.total_value") }
        switch priceMode {
        case .total:        return loc("invest.field.current_total")
        case .perHundredth: return loc("invest.field.current_per_hundredth")
        case .perUnit:
            return isGold ? loc("invest.field.gold_sell_per_gram")
                          : String(format: loc("invest.field.current_per"), holding.type.unitLabel)
        }
    }

    private func save() {
        let newPrice = newUnitPrice
        // Keep the last price as the previous close so "today" shows the move
        // since the user last updated it.
        holding.prevClose = holding.lastPrice > 0 ? holding.lastPrice : newPrice
        holding.lastPrice = newPrice
        holding.pushPrice(newPrice)
        holding.priceUpdatedAt = .now
        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}
