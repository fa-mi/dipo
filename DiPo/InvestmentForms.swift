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

/// A labelled numeric input styled like the rest of the app's forms.
private struct MoneyField: View {
    let label: String
    var placeholder: String = "0"
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
            TextField(placeholder, text: $text)
                .keyboardType(.decimalPad)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
    }
}

private struct PlainField: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
            TextField(placeholder, text: $text)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
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
    let nextOrder: Int

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

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if type.isAmountBased { return parseNumber(amount) > 0 }
        return parseNumber(units) > 0 && parseNumber(buyPrice) > 0
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    typePicker
                    PlainField(label: loc("invest.field.name"), placeholder: loc("invest.field.name_ph"), text: $name)
                    if type.supportsAutoPrice {
                        PlainField(label: loc("invest.field.symbol"), placeholder: loc("invest.field.symbol_ph"), text: $symbol)
                    }

                    Text(loc("invest.first_buy")).font(.system(.body, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary).padding(.top, 4)

                    if type.isAmountBased {
                        MoneyField(label: loc("invest.field.amount"), text: $amount)
                        if !type.priceIsFixed {
                            MoneyField(label: loc("invest.field.current"), text: $currentValue)
                        }
                    } else {
                        HStack(spacing: 12) {
                            MoneyField(label: "\(loc("invest.field.units")) (\(type.unitLabel))", text: $units)
                            MoneyField(label: loc("invest.field.price"), text: $buyPrice)
                        }
                        HStack(spacing: 12) {
                            MoneyField(label: loc("invest.field.fee"), text: $fee)
                            MoneyField(label: loc("invest.field.current"), placeholder: buyPrice.isEmpty ? "0" : buyPrice, text: $current)
                        }
                    }

                    DatePicker(loc("invest.field.date"), selection: $date, in: ...Date(), displayedComponents: .date)
                        .font(.system(.subheadline, weight: .medium))
                        .tint(AppTheme.accent)

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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(InvestmentType.allCases, id: \.self) { t in
                        Button {
                            HapticManager.shared.tap()
                            withAnimation(.spring(response: 0.3)) { type = t }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: t.icon).font(.system(.title3))
                                Text(t.displayName).font(.system(.caption2, weight: .semibold)).lineLimit(1)
                            }
                            .foregroundStyle(type == t ? t.color : AppTheme.textSecondary)
                            .frame(width: 78, height: 64)
                            .background((type == t ? t.color.opacity(0.15) : AppTheme.cardDark),
                                        in: RoundedRectangle(cornerRadius: AppRadius.md))
                            .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                                .stroke(type == t ? t.color : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
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
        context.insert(h)
        let lot = InvestmentLot(kind: .buy, date: date, units: holdingUnits,
                                pricePerUnit: price, fee: parseNumber(fee))
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
    @Bindable var holding: InvestmentHolding
    let initialKind: InvestmentLotKind

    @State private var kind: InvestmentLotKind = .buy
    @State private var units = ""
    @State private var price = ""
    @State private var fee = ""
    @State private var amount = ""   // amount-based buy/sell, or cash for income/fee
    @State private var date = Date()
    @State private var note = ""

    private var cur: String { holding.currency }
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
                        MoneyField(label: loc("invest.field.amount"), text: $amount)
                    } else if holding.type.isAmountBased {
                        MoneyField(label: loc("invest.field.amount"), text: $amount)
                    } else {
                        HStack(spacing: 12) {
                            MoneyField(label: "\(loc("invest.field.units")) (\(holding.type.unitLabel))", text: $units)
                            MoneyField(label: loc("invest.field.price"), text: $price)
                        }
                        MoneyField(label: loc("invest.field.fee"), text: $fee)
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
        holding.lots.append(lot)
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
                MoneyField(label: holding.name, text: $priceText)
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
        holding.priceUpdatedAt = .now
        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}
