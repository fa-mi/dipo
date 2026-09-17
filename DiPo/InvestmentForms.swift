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
    var isAmountBased: Bool { self == .deposit || self == .bond }
}

// MARK: - Card top-up
//
// Investments are tracked standalone, but a purchase can optionally be funded
// from a card — the money really left that account. It's recorded as a TRANSFER
// (not a spend): it moved into an asset, so it must not count against the budget.
// The lot keeps the transaction's id so deleting the lot reverses the outflow.

enum InvestmentCash {
    @MainActor @discardableResult
    static func recordOutflow(holding: InvestmentHolding, cost: Double, card: BankCard, date: Date) -> String {
        let amt = CurrencyManager.shared.convert(cost, from: holding.currency, to: card.resolvedCurrency)
        let tx = TxRecord(name: holding.name, date: date, amount: -abs(amt),
                          type: "tx.type.purchase", icon: holding.type.icon, iconBgHex: "#1DB87A",
                          category: .other, currency: card.resolvedCurrency, subtype: .transfer)
        card.transactions.append(tx)
        return tx.id.uuidString
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
private struct MoneyField: View {
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
            }
        }
    }
}

private struct PlainField: View {
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

/// Parse a user-typed number tolerantly (accepts "1.000.000" and "1,5").
private func parseNumber(_ s: String) -> Double {
    let cleaned = s.replacingOccurrences(of: " ", with: "")
    // If both separators present, assume "." thousands + "," decimal (id-ID).
    if cleaned.contains(",") && cleaned.contains(".") {
        return Double(cleaned.replacingOccurrences(of: ".", with: "")
                             .replacingOccurrences(of: ",", with: ".")) ?? 0
    }
    if cleaned.contains(",") {
        return Double(cleaned.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
    // Only dots: could be thousands ("1.000.000") or a decimal ("1.5"). Treat a
    // single dot with ≤2 trailing digits as decimal, otherwise thousands.
    let parts = cleaned.split(separator: ".")
    if parts.count == 2 && parts[1].count <= 2 { return Double(cleaned) ?? 0 }
    return Double(cleaned.replacingOccurrences(of: ".", with: "")) ?? 0
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

    private var cur: String { CurrencyManager.shared.preferredCurrency }
    private var curSymbol: String { cur == "IDR" ? "Rp" : cur }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if type.isAmountBased { return parseNumber(amount) > 0 }
        return parseNumber(units) > 0 && parseNumber(buyPrice) > 0
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    typePicker

                    // What it is — name + (for auto types) the lookup symbol.
                    groupCard {
                        PlainField(label: loc("invest.field.name"), placeholder: loc("invest.field.name_ph"),
                                   bg: AppTheme.bg, text: $name)
                        if type.supportsAutoPrice {
                            PlainField(label: loc("invest.field.symbol"), placeholder: loc("invest.field.symbol_ph"),
                                       bg: AppTheme.bg, text: $symbol)
                        }
                    }

                    // First purchase — what you put in, grouped in its own card.
                    groupCard {
                        sectionHeader(loc("invest.first_buy"))
                        if type.isAmountBased {
                            MoneyField(label: loc("invest.field.amount"), prefix: curSymbol, bg: AppTheme.bg, text: $amount)
                            if !type.priceIsFixed {
                                MoneyField(label: loc("invest.field.current"), prefix: curSymbol,
                                           hint: loc("invest.field.current_hint"), bg: AppTheme.bg, text: $currentValue)
                            }
                        } else {
                            HStack(spacing: 12) {
                                MoneyField(label: loc("invest.field.units"), suffix: type.unitLabel,
                                           hint: loc("invest.field.units_hint"), bg: AppTheme.bg, text: $units)
                                MoneyField(label: loc("invest.field.price"), prefix: curSymbol, bg: AppTheme.bg, text: $buyPrice)
                            }
                            MoneyField(label: loc("invest.field.fee"), prefix: curSymbol, bg: AppTheme.bg, text: $fee)
                            // Auto-priced instruments fetch the current price themselves,
                            // so there's nothing to type — say so instead of asking.
                            if type.supportsAutoPrice {
                                autoNote
                            } else {
                                MoneyField(label: loc("invest.field.current"),
                                           placeholder: buyPrice.isEmpty ? "0" : buyPrice, prefix: curSymbol,
                                           hint: loc("invest.field.current_hint"), bg: AppTheme.bg, text: $current)
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
            }
            .background(AppTheme.bg)
            .navigationTitle(loc("invest.add_holding"))
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
        }
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc("invest.field.type")).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
            // A 3-column grid shows all six at once — no cut-off horizontal scroll.
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
            lastPrice = type.priceIsFixed ? 1 : (amt > 0 ? parseNumber(currentValue) / amt : 1)
        } else {
            holdingUnits = parseNumber(units)
            price = parseNumber(buyPrice)
            let c = parseNumber(current)
            lastPrice = c > 0 ? c : price
        }
        let h = InvestmentHolding(type: type,
                                  name: name.trimmingCharacters(in: .whitespaces),
                                  symbol: symbol.trimmingCharacters(in: .whitespaces),
                                  currency: cur,
                                  lastPrice: lastPrice, prevClose: lastPrice,
                                  sortOrder: nextOrder)
        h.priceUpdatedAt = .now
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

    private var cur: String { holding.currency }
    private var curSymbol: String { cur == "IDR" ? "Rp" : cur }
    private var availableKinds: [InvestmentLotKind] {
        var ks: [InvestmentLotKind] = [.buy]
        if holding.stats().unitsHeld > 0 { ks.append(.sell) }
        switch holding.type {
        case .stock, .mutualFund, .crypto: ks.append(.dividend)
        case .bond, .deposit: ks.append(.coupon)
        case .gold: break
        }
        ks.append(.fee)
        return ks
    }

    private var canSave: Bool {
        if kind.isCash { return parseNumber(amount) > 0 }
        if holding.type.isAmountBased { return parseNumber(amount) > 0 }
        return parseNumber(units) > 0 && parseNumber(price) > 0
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
                        HStack(spacing: 12) {
                            MoneyField(label: loc("invest.field.units"), suffix: holding.type.unitLabel, text: $units)
                            MoneyField(label: loc("invest.field.price"), prefix: curSymbol, text: $price)
                        }
                        MoneyField(label: loc("invest.field.fee"), prefix: curSymbol, text: $fee)
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
            .onAppear { kind = initialKind }
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
                                pricePerUnit: parseNumber(price), fee: parseNumber(fee), note: note)
        }
        // A buy can be funded from a card (transfer out).
        if kind == .buy, let id = fundCardID, let card = cards.first(where: { $0.id.uuidString == id }) {
            let cost = holding.type.isAmountBased
                ? parseNumber(amount)
                : parseNumber(units) * parseNumber(price) + parseNumber(fee)
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
    private var curSymbol: String { cur == "IDR" ? "Rp" : cur }
    private var kind: InvestmentLotKind { lot.kind }

    private var canSave: Bool {
        if kind.isCash { return parseNumber(amount) > 0 }
        if holding.type.isAmountBased { return parseNumber(amount) > 0 }
        return parseNumber(units) > 0 && parseNumber(price) > 0
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
                        HStack(spacing: 12) {
                            MoneyField(label: loc("invest.field.units"), suffix: holding.type.unitLabel, text: $units)
                            MoneyField(label: loc("invest.field.price"), prefix: curSymbol, text: $price)
                        }
                        MoneyField(label: loc("invest.field.fee"), prefix: curSymbol, text: $fee)
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

    /// Whole numbers plain; fractional units use a comma decimal so `parseNumber`
    /// (id-ID) round-trips them (e.g. 0.005 → "0,005", not misread as thousands).
    private func num(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(v).replacingOccurrences(of: ".", with: ",")
    }

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

    private var cur: String { holding.currency }
    private var amountBased: Bool { holding.type.isAmountBased }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(amountBased ? loc("invest.total_value") : loc("invest.current_price"))
                    .font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                MoneyField(label: holding.name, prefix: holding.currency == "IDR" ? "Rp" : holding.currency, text: $priceText)
                Text(String(format: loc("invest.per_unit"), holding.type.unitLabel))
                    .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
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
                        .disabled(parseNumber(priceText) <= 0)
                }
            }
            .onAppear {
                let shown = amountBased ? holding.stats().marketValue : holding.lastPrice
                if shown > 0 { priceText = String(Int(shown)) }
            }
        }
    }

    private func save() {
        let entered = parseNumber(priceText)
        let newPrice: Double
        if amountBased {
            let units = holding.stats().unitsHeld
            newPrice = units > 0 ? entered / units : 1
        } else {
            newPrice = entered
        }
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
