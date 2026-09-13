import SwiftUI
import SwiftData

// MARK: - Credit Card feature
//
// A credit card is a BankCard with `isCreditCard = true`. It's created only from
// the Debt Tracker (the single door), tracked as a liability (owed/limit), yet
// still appears in the transaction "source of fund" picker so purchases can be
// logged against it — spending raises `owed` instead of reducing cash.

// MARK: - Liability row (shown in Debt Tracker)

struct CreditCardLiabilityRow: View {
    let card: BankCard
    /// Instalments running on this card. Without them the row reported only
    /// `owedBalance()` — logged transactions — while `InstallmentSection`
    /// listed the very instalments it excluded directly underneath, so one
    /// screen showed a debt and denied it in the same breath.
    var installments: [CardInstallment] = []
    var onEdit: () -> Void
    /// Cross-link to log a purchase on this card (wired in F3).
    var onLogSpend: (() -> Void)? = nil
    /// Record a bill payment against this card.
    var onPay: (() -> Void)? = nil
    /// Delete the card. This row was the ONLY place a credit card was listed,
    /// and it offered no way to remove one — the Cards manager's trash button
    /// lives on a different row type. So a credit card, once created, could not
    /// be deleted from anywhere in the app.
    var onDelete: (() -> Void)? = nil

    /// `prominent` marks the one that adds debt — the commoner action, and the
    /// one worth reaching for first.
    @ViewBuilder
    private func cardAction(_ title: String, icon: String,
                            prominent: Bool, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.tap(); action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(.caption, weight: .semibold))
                Text(title).font(.system(.caption, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(prominent ? AppTheme.onVividFill : AppTheme.purple)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                if prominent {
                    Capsule().fill(AppTheme.accentFill)
                } else {
                    Capsule().fill(AppTheme.purple.opacity(0.12))
                        .overlay(Capsule().stroke(AppTheme.purple.opacity(0.3), lineWidth: 1))
                }
            }
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private var owed: Double { card.totalOwed(installments) }
    private var util: Double { card.utilisation(installments) }
    private var owedFmt: String {
        CurrencyManager.shared.formatted(owed, currency: card.resolvedCurrency)
    }
    private var availableFmt: String {
        CurrencyManager.shared.formatted(card.availableCredit(installments),
                                         currency: card.resolvedCurrency)
    }

    private var issuer: BankIssuer? { BankIssuer.find(card.issuerID.isEmpty ? nil : card.issuerID) }
    private var title: String {
        if !card.holderName.isEmpty { return card.holderName }
        return issuer?.name ?? loc("cc.default_name")
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 46, height: 46)
                    Image(systemName: "creditcard.fill").font(.system(.body)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                        Text(loc("cc.badge")).font(.system(.caption2, weight: .bold))
                            .foregroundStyle(AppTheme.purple)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AppTheme.purple.opacity(0.15), in: Capsule())
                    }
                    if !card.last4.isEmpty {
                        Text("•••• \(card.last4)").font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
                Spacer()
                Menu {
                    Button { HapticManager.shared.tap(); onEdit() } label: {
                        Label(loc("common.edit"), systemImage: "pencil")
                    }
                    if let onDelete {
                        Divider()
                        Button(role: .destructive) { HapticManager.shared.warning(); onDelete() } label: {
                            Label(loc("action.delete"), systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary).frame(width: 28, height: 28)
                        .background(AppTheme.cardMid, in: Circle())
                }
            }

            // Owed / limit
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("cc.owed")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                    Text(owedFmt).font(.system(.body, weight: .bold)).foregroundStyle(AppTheme.red)
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(loc("cc.available")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                    Text(availableFmt).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.accent)
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
            }

            CreditLimitBar(used: owed,
                           limit: card.creditLimit,
                           currency: card.resolvedCurrency)

            if onLogSpend != nil || onPay != nil {
                HStack(spacing: 9) {
                    if let onLogSpend {
                        cardAction(loc("cc.log_spend"), icon: "cart.badge.plus",
                                   prominent: true, action: onLogSpend)
                    }
                    if let onPay {
                        cardAction(loc("cc.pay_bill"), icon: "arrow.left.arrow.right",
                                   prominent: false, action: onPay)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.purple.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - Limit bar

/// How much of the credit line is spoken for.
///
/// Replaces a flat 6pt progress strip. The spent portion is solid and the
/// remainder is hatched, so "used" and "still available" are told apart by
/// texture as well as by colour — the two halves of the bar were previously
/// distinguished by fill alone, which made the figure easy to misread at a
/// glance on a dark ground.
struct CreditLimitBar: View {
    let used: Double
    let limit: Double
    let currency: String

    private var progress: Double {
        guard limit > 0 else { return 0 }
        return min(max(used / limit, 0), 1)
    }
    /// Above ~70% is where scoring models start treating utilisation as a risk
    /// signal, so that is where the bar stops being decorative.
    private var isHot: Bool { progress > 0.7 }
    private var tint: Color { isHot ? AppTheme.red : AppTheme.purple }

    private let barHeight: CGFloat = 12

    var body: some View {
        VStack(spacing: 9) {
            GeometryReader { g in
                let w = g.size.width
                let fill = max(w * progress, progress > 0 ? barHeight : 0)

                ZStack(alignment: .leading) {
                    // Remainder — hatched, reading as "not yet spent".
                    Canvas { ctx, size in
                        let step: CGFloat = 7
                        var x: CGFloat = -size.height
                        while x < size.width + size.height {
                            var line = Path()
                            line.move(to: CGPoint(x: x, y: size.height))
                            line.addLine(to: CGPoint(x: x + size.height, y: 0))
                            ctx.stroke(line, with: .color(tint.opacity(0.28)), lineWidth: 2)
                            x += step
                        }
                    }
                    .frame(height: barHeight)
                    .background(AppTheme.cardMid)
                    .clipShape(Capsule())

                    Capsule()
                        .fill(tint)
                        .frame(width: fill, height: barHeight)

                    // Knob marks the exact position the way the reference does,
                    // and gives the eye something to land on when the fill is
                    // short enough to be hard to measure.
                    if progress > 0 {
                        Circle()
                            .fill(AppTheme.cardDark)
                            .frame(width: barHeight + 6, height: barHeight + 6)
                            .overlay(Circle().stroke(tint, lineWidth: 3))
                            .offset(x: min(max(fill - (barHeight + 6) / 2, 0), w - (barHeight + 6)))
                    }
                }
                .frame(height: barHeight + 6)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: barHeight + 6)

            HStack(spacing: 8) {
                Text(loc("cc.limit_used"))
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer(minLength: 8)
                Text(CurrencyManager.shared.formatted(used, currency: currency))
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(isHot ? AppTheme.red : AppTheme.textPrimary)
                    .monospacedDigit()
                Text("/ " + CurrencyManager.shared.formatted(limit, currency: currency))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }
}

// MARK: - Create / edit form

struct CreditCardFormSheet: View {
    let editCard: BankCard?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]

    @State private var name = ""
    @State private var cardNumber = ""
    @State private var displayNumber = ""
    @State private var limitText = ""
    @State private var owedText = ""
    @State private var currency = CurrencyManager.shared.preferredCurrency
    @State private var showExplainer = false
    @State private var appeared = false

    private var isEditing: Bool { editCard != nil }
    private var gradient: BankGradient {
        BankIssuer.resolveGradient(issuerID: nil, cardNumber: cardNumber.isEmpty ? "5" : cardNumber)
    }
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (Double(limitText) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        // Live preview
                        CardPreviewMini(
                            holderName: name.isEmpty ? loc("cc.default_name") : name,
                            number: displayNumber.isEmpty ? "•••• •••• •••• ••••" : displayNumber,
                            expire: "", network: .unknown,
                            gradientStart: gradient.start, gradientEnd: gradient.end)
                        .padding(.horizontal, 22).padding(.top, 8)

                        SheetField(label: loc("cc.name"), placeholder: loc("cc.name_ph"), text: $name)

                        VStack(spacing: 8) {
                            Text(loc("cards.number")).font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            TextField("•••• •••• •••• ••••", text: $displayNumber)
                                .keyboardType(.numberPad)
                                .onChange(of: displayNumber) { _, v in
                                    let digits = String(v.filter(\.isNumber).prefix(16))
                                    cardNumber = digits
                                    displayNumber = digits.enumerated().map { $0.offset > 0 && $0.offset % 4 == 0 ? " \($0.element)" : String($0.element) }.joined()
                                }
                                .font(.system(.subheadline)).padding(14)
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                .padding(.horizontal, 22)
                        }

                        amountField(label: loc("cc.limit"), text: $limitText)
                        amountField(label: loc("cc.current_owed"), text: $owedText)

                        // First-run explainer
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill").font(.system(.subheadline)).foregroundStyle(AppTheme.purple)
                            Text(loc("cc.explainer")).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14).background(AppTheme.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 22)

                        saveButton
                        Spacer(minLength: 30)
                    }
                    .padding(.top, 6)
                }
            }
            .navigationTitle(isEditing ? loc("cc.edit_title") : loc("cc.new_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
            }
            .onAppear {
                if let c = editCard {
                    name = c.holderName
                    let d = c.cardNumber.filter(\.isNumber)
                    cardNumber = d
                    displayNumber = d.enumerated().map { $0.offset > 0 && $0.offset % 4 == 0 ? " \($0.element)" : String($0.element) }.joined()
                    limitText = String(Int(c.creditLimit))
                    owedText = String(Int(c.owedBalance()))
                    currency = c.resolvedCurrency
                }
            }
        }
    }

    private func amountField(label: String, text: Binding<String>) -> some View {
        VStack(spacing: 8) {
            Text(label).font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
            HStack(spacing: 10) {
                Text(currency).font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.purple)
                    .frame(width: 54, height: 52).background(AppTheme.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                TextField("0", text: text)
                    .font(.system(.title3, weight: .bold)).keyboardType(.decimalPad)
                    .padding(.horizontal, 14).frame(height: 52)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
            }.padding(.horizontal, 22)
        }
    }

    private var saveButton: some View {
        Button {
            guard isValid else { HapticManager.shared.error(); return }
            save()
        } label: {
            Text(loc("cc.save")).font(.system(.callout, weight: .bold)).foregroundStyle(AppTheme.onVividFill)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(isValid ? AppTheme.purple : AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(ScaleButtonStyle()).disabled(!isValid).padding(.horizontal, 22)
    }

    private func save() {
        let limit = Double(limitText) ?? 0
        let owed = Double(owedText) ?? 0
        let g = gradient
        if let card = editCard {
            card.holderName = name.trimmingCharacters(in: .whitespaces)
            card.cardNumber = cardNumber
            card.creditLimit = limit
            // Re-baseline: owed becomes the entered value as of now.
            card.openingOwed = owed
            card.creditSince = Date()
            card.gradientStart = g.start; card.gradientEnd = g.end
            card.issuerID = BankIssuer.detect(from: cardNumber)?.id ?? ""
        } else {
            let card = BankCard(
                holderName: name.trimmingCharacters(in: .whitespaces),
                cardNumber: cardNumber, balance: 0, expireDate: "",
                gradientStart: g.start, gradientEnd: g.end,
                sortOrder: cards.count, currency: currency)
            card.isCreditCard = true
            card.creditLimit = limit
            card.openingOwed = owed
            card.creditSince = Date()
            card.issuerID = BankIssuer.detect(from: cardNumber)?.id ?? ""
            context.insert(card)
        }
        try? context.save()
        HapticManager.shared.success()
        ActionFeedbackCenter.shared.cardSaved(
            name: name.trimmingCharacters(in: .whitespaces), isUpdate: editCard != nil)
        dismiss()
    }
}

// MARK: - Credit Card Bill Payment
//
// Paying a credit card bill is a TRANSFER, not an expense. The spending already
// happened when each purchase was logged on the card; treating the payment as a
// second expense would count the same rupiah twice and make any month where you
// clear a balance look catastrophic.
//
// So two transactions are written, both `.transfer`:
//   • negative on the cash account the money leaves
//   • positive on the credit card, which reduces `owedBalance()` — that figure
//     is openingOwed minus the sum of movements, so a credit lowers it
struct CreditCardPaymentSheet: View {
    let creditCard: BankCard
    let cards: [BankCard]
    let context: ModelContext
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var fromCardID: UUID? = nil

    private var owed: Double { creditCard.owedBalance() }
    private var cashCards: [BankCard] { cards.filter { !$0.isCreditCard } }

    private var canSave: Bool {
        guard let a = Double(amountText), a > 0, fromCardID != nil else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        VStack(spacing: 4) {
                            Text(loc("cc.owed")).font(.system(.caption))
                                .foregroundStyle(AppTheme.textSecondary)
                            Text(creditCard.formattedOwed)
                                .font(.system(.title, weight: .bold)).foregroundStyle(AppTheme.red)
                        }
                        .padding(.top, 8)

                        TextField("0", text: $amountText)
                            .font(.system(.title2, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                            .keyboardType(.decimalPad).multilineTextAlignment(.center)
                            .padding(.vertical, 14)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 22)

                        Button { amountText = String(format: "%.0f", owed) } label: {
                            Text(loc("cc.pay_full")).font(.system(.caption, weight: .semibold))
                                .foregroundStyle(AppTheme.accent)
                        }
                        .buttonStyle(.plain)

                        CardPickerSection(selectedCardID: $fromCardID, titleKey: "cc.pay_from")
                            .padding(.horizontal, 22)

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill").font(.system(.caption))
                                .foregroundStyle(AppTheme.textSecondary)
                            Text(loc("cc.pay_hint"))
                                .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 22)

                        Button { record() } label: {
                            Text(loc("cc.pay_bill")).font(.system(.callout, weight: .bold))
                                .foregroundStyle(canSave ? AppTheme.onVividFill : AppTheme.textSecondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 15)
                                .background(canSave ? AppTheme.accentFill : AppTheme.cardMid,
                                            in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .disabled(!canSave)
                        .padding(.horizontal, 22)
                        Spacer(minLength: 20)
                    }
                }
            }
            .navigationTitle(loc("cc.pay_bill"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
            .onAppear { if fromCardID == nil { fromCardID = cashCards.first?.id } }
        }
    }

    private func record() {
        guard let amount = Double(amountText), amount > 0,
              let id = fromCardID, let source = cards.first(where: { $0.id == id }) else { return }
        let ccName = creditCard.holderName.isEmpty ? loc("cc.title") : creditCard.holderName

        let out = TxRecord(
            name: String(format: loc("cc.tx_payment_out"), ccName),
            date: .now, amount: -abs(amount), type: "tx.type.purchase",
            icon: "CC", iconBgHex: TxCategory.other.iconBg,
            category: .other, currency: source.resolvedCurrency,
            notes: "tx.note.cc_payment", subtype: .transfer)
        context.insert(out)
        source.transactions.append(out)

        let credit = TxRecord(
            name: String(format: loc("cc.tx_payment_in"), ccName),
            date: .now, amount: abs(amount), type: "tx.type.income",
            icon: "CC", iconBgHex: TxCategory.other.iconBg,
            category: .other, currency: creditCard.resolvedCurrency,
            notes: "tx.note.cc_payment", subtype: .transfer)
        context.insert(credit)
        creditCard.transactions.append(credit)

        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}
