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
                    Image(systemName: "creditcard.fill").font(.system(size: 18)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                        Text(loc("cc.badge")).font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppTheme.purple)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AppTheme.purple.opacity(0.15), in: Capsule())
                    }
                    if !card.last4.isEmpty {
                        Text("•••• \(card.last4)").font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
                Spacer()
                Menu {
                    if let onLogSpend {
                        Button { HapticManager.shared.tap(); onLogSpend() } label: {
                            Label(loc("cc.log_spend"), systemImage: "cart.badge.plus")
                        }
                    }
                    if let onPay {
                        Button { HapticManager.shared.tap(); onPay() } label: {
                            Label(loc("cc.pay_bill"), systemImage: "arrow.left.arrow.right")
                        }
                    }
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
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary).frame(width: 28, height: 28)
                        .background(AppTheme.cardMid, in: Circle())
                }
            }

            // Owed / limit
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("cc.owed")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    Text(card.formattedOwed).font(.system(size: 18, weight: .bold)).foregroundStyle(AppTheme.red)
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(loc("cc.available")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    Text(card.formattedAvailable).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.accent)
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
            }

            // Utilization bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.cardMid).frame(height: 6)
                    Capsule()
                        .fill(card.creditUtilization > 0.7 ? AppTheme.red : AppTheme.purple)
                        .frame(width: g.size.width * CGFloat(card.creditUtilization), height: 6)
                }
            }.frame(height: 6)

            Text(String(format: loc("cc.limit_of"), card.formattedBalanceLimit))
                .font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.purple.opacity(0.18), lineWidth: 1))
    }
}

private extension BankCard {
    var formattedBalanceLimit: String {
        CurrencyManager.shared.formatted(creditLimit, currency: resolvedCurrency)
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
                            Text(loc("cards.number")).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            TextField("•••• •••• •••• ••••", text: $displayNumber)
                                .keyboardType(.numberPad)
                                .onChange(of: displayNumber) { _, v in
                                    let digits = String(v.filter(\.isNumber).prefix(16))
                                    cardNumber = digits
                                    displayNumber = digits.enumerated().map { $0.offset > 0 && $0.offset % 4 == 0 ? " \($0.element)" : String($0.element) }.joined()
                                }
                                .font(.system(size: 15)).padding(14)
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                .padding(.horizontal, 22)
                        }

                        amountField(label: loc("cc.limit"), text: $limitText)
                        amountField(label: loc("cc.current_owed"), text: $owedText)

                        // First-run explainer
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill").font(.system(size: 15)).foregroundStyle(AppTheme.purple)
                            Text(loc("cc.explainer")).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
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
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
            HStack(spacing: 10) {
                Text(currency).font(.system(size: 15, weight: .bold)).foregroundStyle(AppTheme.purple)
                    .frame(width: 54, height: 52).background(AppTheme.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                TextField("0", text: text)
                    .font(.system(size: 20, weight: .bold)).keyboardType(.decimalPad)
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
            Text(loc("cc.save")).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
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
                            Text(loc("cc.owed")).font(.system(size: 12))
                                .foregroundStyle(AppTheme.textSecondary)
                            Text(creditCard.formattedOwed)
                                .font(.system(size: 26, weight: .bold)).foregroundStyle(AppTheme.red)
                        }
                        .padding(.top, 8)

                        TextField("0", text: $amountText)
                            .font(.system(size: 22, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                            .keyboardType(.decimalPad).multilineTextAlignment(.center)
                            .padding(.vertical, 14)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 22)

                        Button { amountText = String(format: "%.0f", owed) } label: {
                            Text(loc("cc.pay_full")).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppTheme.accent)
                        }
                        .buttonStyle(.plain)

                        CardPickerSection(selectedCardID: $fromCardID, titleKey: "cc.pay_from")
                            .padding(.horizontal, 22)

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill").font(.system(size: 12))
                                .foregroundStyle(AppTheme.textSecondary)
                            Text(loc("cc.pay_hint"))
                                .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 22)

                        Button { record() } label: {
                            Text(loc("cc.pay_bill")).font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 15)
                                .background(canSave ? AppTheme.accent : AppTheme.cardMid,
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
