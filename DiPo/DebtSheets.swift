import UserNotifications
import SwiftUI
import SwiftData

// Moved out of DebtView.swift, unchanged. The add/edit, payment and payoff-simulator sheets.

// MARK: - Debt Form Sheet

struct DebtFormSheet: View {
    @Bindable var vm: DebtViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            ZStack { AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        // Type picker
                        VStack(spacing: 8) {
                            Text(loc("debt.type")).font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(DebtType.allCases, id: \.self) { type in
                                        Button { HapticManager.shared.tap(); vm.formType = type } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: type.icon).font(.system(.footnote))
                                                Text(type.label).font(.system(.footnote, weight: .medium))
                                            }
                                            .foregroundStyle(vm.formType == type ? AppTheme.bg : AppTheme.textSecondary)
                                            .padding(.horizontal, 14).padding(.vertical, 9)
                                            .background(vm.formType == type ? type.color : AppTheme.cardDark, in: Capsule())
                                        }.buttonStyle(ScaleButtonStyle())
                                    }
                                }.padding(.horizontal, 22)
                            }
                        }
                        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 20)

                        SheetField(label: loc("savings.description"), placeholder: loc("debt.description_placeholder"), text: $vm.formName)
                            .opacity(appeared ? 1 : 0).animation(AppMotion.appear, value: appeared)

                        // Balance fields
                        HStack(spacing: 12) {
                            VStack(spacing: 8) {
                                Text(loc("cards.current_balance")).font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                TextField("0", text: $vm.formBalance).font(.system(.body, weight: .bold))
                                    .foregroundStyle(AppTheme.red).keyboardType(.decimalPad)
                                    .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                                    .onChange(of: vm.formBalance) { _, v in
                                        let n = v.replacingOccurrences(of: ",", with: ".")
                                        let f = n.filter { $0.isNumber || $0 == "." }
                                        if f != v { vm.formBalance = f }
                                    }
                                // Live formatted preview — helps user catch
                                // wrong digit count (typing 5000 vs 50000).
                                if let p = AmountInputHelper.preview(vm.formBalance, currency: vm.formCurrency) {
                                    Text(p)
                                        .font(.system(.caption2, weight: .medium))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            VStack(spacing: 8) {
                                Text(loc("debt.min_payment")).font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                TextField("0", text: $vm.formMinPayment).font(.system(.body, weight: .bold))
                                    .foregroundStyle(AppTheme.textPrimary).keyboardType(.decimalPad)
                                    .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                                    .onChange(of: vm.formMinPayment) { _, v in
                                        let n = v.replacingOccurrences(of: ",", with: ".")
                                        let f = n.filter { $0.isNumber || $0 == "." }
                                        if f != v { vm.formMinPayment = f }
                                    }
                                if let p = AmountInputHelper.preview(vm.formMinPayment, currency: vm.formCurrency) {
                                    Text(p)
                                        .font(.system(.caption2, weight: .medium))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0).animation(AppMotion.appear, value: appeared)

                        // Interest + Due day
                        HStack(spacing: 12) {
                            VStack(spacing: 8) {
                                Text(loc("debt.annual_int")).font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                TextField("0.0", text: $vm.formInterestRate).font(.system(.body, weight: .bold))
                                    .foregroundStyle(AppTheme.orange).keyboardType(.decimalPad)
                                    .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                                    .onChange(of: vm.formInterestRate) { _, v in
                                        // Normalize comma → dot for locales that use comma as decimal
                                        let normalized = v.replacingOccurrences(of: ",", with: ".")
                                        // Allow only digits and one dot
                                        let filtered = normalized.filter { $0.isNumber || $0 == "." }
                                        let dotCount = filtered.filter { $0 == "." }.count
                                        if dotCount > 1 {
                                            // Keep only first dot
                                            var seenDot = false
                                            vm.formInterestRate = String(filtered.filter { c in
                                                if c == "." { if seenDot { return false }; seenDot = true }
                                                return true
                                            })
                                        } else if filtered != v {
                                            vm.formInterestRate = filtered
                                        }
                                    }
                            }
                            VStack(spacing: 8) {
                                Text(loc("debt.due_day")).font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                // 44×44pt is Apple HIG's minimum tap target.
                                // Buttons were 36×36 — usable but missed
                                // accurately on smaller screens, especially
                                // for users with larger fingers / thumbs.
                                HStack(spacing: 0) {
                                    Button { HapticManager.shared.tap(); if vm.formDueDay > 1 { vm.formDueDay -= 1 } } label: {
                                        Image(systemName: "minus").font(.system(.subheadline, weight: .semibold))
                                            .foregroundStyle(AppTheme.textPrimary).frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
.accessibilityLabel(loc("a11y.earlier_day"))
                                    Text("\(vm.formDueDay)").font(.system(.body, weight: .bold)).foregroundStyle(AppTheme.textPrimary).frame(width: 40)
                                        .contentTransition(.numericText())
                                    Button { HapticManager.shared.tap(); if vm.formDueDay < 31 { vm.formDueDay += 1 } } label: {
                                        Image(systemName: "plus").font(.system(.subheadline, weight: .semibold))
                                            .foregroundStyle(AppTheme.textPrimary).frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
.accessibilityLabel(loc("a11y.later_day"))
                                }
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                            }
                        }
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0).animation(AppMotion.appear, value: appeared)

                        // Currency
                        VStack(spacing: 8) {
                            Text(loc("common.currency")).font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(vm.currencies, id: \.self) { c in
                                        Button { HapticManager.shared.tap(); vm.formCurrency = c } label: {
                                            Text(c).font(.system(.footnote, weight: .semibold))
                                                .foregroundStyle(vm.formCurrency == c ? AppTheme.onVividFill : AppTheme.textSecondary)
                                                .padding(.horizontal, 16).padding(.vertical, 8)
                                                .background(vm.formCurrency == c ? AppTheme.accentFill : AppTheme.cardDark, in: Capsule())
                                        }.buttonStyle(ScaleButtonStyle())
                                    }
                                }.padding(.horizontal, 22)
                            }
                        }
                        .opacity(appeared ? 1 : 0).animation(AppMotion.appear, value: appeared)

                        // Payoff preview
                        if let previewDebt = payoffPreviewDebt {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(loc("debt.payoff_preview")).font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                                HStack(spacing: 20) {
                                    if let m = previewDebt.monthsToPayoffMinimum {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(String(format: loc("debt.month"), m)).font(.system(.callout, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                            Text(loc("debt.at_min")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                        }
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(CurrencyManager.shared.formatted(previewDebt.totalInterestAtMinimum, currency: vm.formCurrency))
                                            .font(.system(.callout, weight: .bold)).foregroundStyle(AppTheme.orange)
                                        Text(loc("debt.total_int")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                            }
                            .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                            .padding(.horizontal, 22)
                            .opacity(appeared ? 1 : 0)
                        }

                        if let err = vm.formError {
                            InlineBanner(tone: .error, message: err)
                                .padding(.horizontal, 22)
                                .transition(.opacity)
                        }

                        // Form-validity: name + positive balance + positive
                        // Only `name` and `balance > 0` are strictly required.
                        // Minimum payment was previously gated to >0, but
                        // legit debts can have no fixed minimum (e.g., credit
                        // card before first statement, informal loan from
                        // family, fully-paid annuity installment). The engine
                        // handles min=0 gracefully — DTI calc just doesn't
                        // count it. Interest defaults to 0 for interest-free
                        // installments. Due day is always 1-31 so it can't
                        // be invalid. Same minimal-validation shape as
                        // WishlistView.
                        let canSave: Bool = {
                            let nameOK = !vm.formName.trimmingCharacters(in: .whitespaces).isEmpty
                            let balOK  = NumberInput.amount(vm.formBalance) > 0
                            return nameOK && balOK
                        }()
                        Button { save() } label: {
                            Text(vm.isEditing ? loc("general.edit") : loc("debt.add"))
                                .font(.system(.callout, weight: .bold))
                                .foregroundStyle(canSave ? .white : AppTheme.textSecondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(canSave ? AppTheme.red.opacity(0.9) : AppTheme.textSecondary.opacity(0.3), in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .disabled(!canSave)
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0).animation(AppMotion.appear, value: appeared)

                        Spacer(minLength: 40)
                    }.padding(.top, 8)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(vm.isEditing ? loc("debt.edit") : loc("debt.add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { HapticManager.shared.tap(); dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }

            }
        }
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) { appeared = true } }
    }

    /// A throwaway record for the payoff preview, once balance, minimum
    /// payment and rate are all filled in.
    private var payoffPreviewDebt: DebtRecord? {
        let bal = NumberInput.amount(vm.formBalance)
        let minPay = NumberInput.amount(vm.formMinPayment)
        guard bal > 0, minPay > 0, NumberInput.isNumber(vm.formInterestRate) else { return nil }
        return DebtRecord(name: "Preview", totalAmount: bal, currentBalance: bal,
                          minimumPayment: minPay, annualInterestRate: NumberInput.decimal(vm.formInterestRate),
                          dueDayOfMonth: 1)
    }

    private func save() {
        guard vm.validate() else { HapticManager.shared.error(); return }
        let bal   = NumberInput.amount(vm.formBalance)
        let min   = NumberInput.amount(vm.formMinPayment)
        let rate  = NumberInput.decimal(vm.formInterestRate)
        let typedTotal = NumberInput.amount(vm.formTotal)
        let total = typedTotal > 0 ? typedTotal : bal

        if let existing = vm.editingDebt {
            existing.name = vm.formName.trimmingCharacters(in: .whitespaces)
            existing.debtType = vm.formType; existing.currentBalance = bal
            existing.totalAmount = total; existing.minimumPayment = min
            existing.annualInterestRate = rate; existing.dueDayOfMonth = vm.formDueDay
            existing.currency = vm.formCurrency; existing.notes = vm.formNotes
            // Re-opening a previously closed debt with a real balance: clear the
            // manual-close flag and re-activate so it tracks normally again.
            if bal > 0 {
                existing.manuallyClosed = false
                existing.isActive = true
            }
        } else {
            let debt = DebtRecord(name: vm.formName.trimmingCharacters(in: .whitespaces),
                                  type: vm.formType.rawValue, totalAmount: total,
                                  currentBalance: bal, minimumPayment: min,
                                  annualInterestRate: rate, dueDayOfMonth: vm.formDueDay,
                                  currency: vm.formCurrency, notes: vm.formNotes)
            modelContext.insert(debt)
        }
        try? modelContext.save()
        HapticManager.shared.success()
        dismiss()
    }
}

// MARK: - Debt Payment Sheet

struct DebtPaymentSheet: View {
    @Bindable var debt: DebtRecord
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]

    @State private var amountText   = ""
    @State private var selectedCardIndex = 0
    @State private var note         = ""
    @State private var errorMsg: String? = nil

    private var amount: Double { NumberInput.amount(amountText) }

    private var selectedCard: BankCard? {
        guard !cards.isEmpty else { return nil }
        return cards[min(selectedCardIndex, cards.count - 1)]
    }

    private var activeCurrency: String {
        selectedCard.map { $0.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : $0.currency } ?? debt.currency
    }

    // Amount entered in card currency converted to debt currency
    private var amountInDebtCurrency: Double {
        CurrencyManager.shared.convert(amount, from: activeCurrency, to: debt.currency)
    }

    // Card raw balance in card's own currency
    private func cardRawBalance(_ card: BankCard) -> Double {
        let cardCur = card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
        return card.balance + card.transactions.reduce(0.0) { sum, tx in
            sum + CurrencyManager.shared.convert(tx.amount, from: tx.currency, to: cardCur)
        }
    }

    // Available balance in card currency
    private var availableBalance: Double { selectedCard.map { cardRawBalance($0) } ?? 0 }

    private var wouldGoNegative: Bool { amount > availableBalance }

    private var currencyMismatch: Bool {
        guard let card = selectedCard else { return false }
        let cardCur = card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
        return cardCur != debt.currency
    }

    private var isValid: Bool {
        amount > 0 && amountInDebtCurrency <= debt.currentBalance && !wouldGoNegative
    }

    var body: some View {
        VStack(spacing: 0) {
            // Handle
            RoundedRectangle(cornerRadius: 3)
                .fill(AppTheme.cardMid).frame(width: 36, height: 4).padding(.top, 12)

            // Debt summary
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.sm)
                        .fill(debt.debtType.color.opacity(0.15)).frame(width: 48, height: 48)
                    Image(systemName: debt.debtType.icon)
                        .font(.system(.title2)).foregroundStyle(debt.debtType.color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(debt.name).font(.system(.callout, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    Text(String(
                        format: loc("debt.balance"),
                        CurrencyManager.shared.formatted(
                            debt.currentBalance,
                            currency: debt.currency
                        )
                    ))
                        .font(.system(.footnote)).foregroundStyle(AppTheme.red)
                    Text(String(
                        format: loc("debt.minimum_payment"),
                        CurrencyManager.shared.formatted(
                            debt.minimumPayment,
                            currency: debt.currency
                        )
                    ))
                        .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 20)

            Divider().padding(.horizontal, 22)

            // Quick amounts
            VStack(spacing: 10) {
                Text(loc("debt.payment_amt")).font(.system(.footnote, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Minimum
                        QuickPayButton(
                            label: loc("debt.min_only"),
                            amount: debt.minimumPayment,
                            currency: debt.currency,
                            color: AppTheme.orange
                        ) { amountText = NumberInput.text(debt.minimumPayment) }

                        // Full balance
                        QuickPayButton(
                            label: loc("debt.payoff"),
                            amount: debt.currentBalance,
                            currency: debt.currency,
                            color: AppTheme.accent
                        ) { amountText = NumberInput.text(debt.currentBalance) }

                        // Double minimum
                        if debt.minimumPayment * 2 < debt.currentBalance {
                            QuickPayButton(
                                label: "2x min",
                                amount: debt.minimumPayment * 2,
                                currency: debt.currency,
                                color: AppTheme.blue
                            ) { amountText = NumberInput.text(debt.minimumPayment * 2) }
                        }
                    }
                    .padding(.horizontal, 22)
                }

                // Custom amount
                HStack(spacing: 8) {
                    Text(activeCurrency)
                        .font(.system(.body, weight: .bold)).foregroundStyle(debt.debtType.color)
                    TextField("0", text: $amountText)
                        .font(.system(.title, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                        .keyboardType(.decimalPad)
                }
                .padding(16)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(amount > 0 ? debt.debtType.color.opacity(0.4) : Color.clear, lineWidth: 1.5))
                .padding(.horizontal, 22)

                // Remaining after payment preview
                if amount > 0 && amountInDebtCurrency <= debt.currentBalance {
                    let remaining = debt.currentBalance - amountInDebtCurrency
                    HStack(spacing: 8) {
                        Image(systemName: remaining == 0 ? "checkmark.seal.fill" : "minus.circle")
                            .font(.system(.footnote))
                            .foregroundStyle(remaining == 0 ? AppTheme.accent : AppTheme.textSecondary)
                        Text(remaining == 0
                             ? String(format: loc("debt.payoff_full"), debt.name)
                             : String(format: loc("debt.remaining_amount"), CurrencyManager.shared.formatted(remaining, currency: debt.currency)))
                            .font(.system(.footnote))
                            .foregroundStyle(remaining == 0 ? AppTheme.accent : AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 22)
                    .transition(.opacity)
                }

                // Insufficient balance warning
                if amount > 0 && wouldGoNegative {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(.footnote)).foregroundStyle(AppTheme.red)
                        Text(String(format: loc("debt.insufficient_balance"), CurrencyManager.shared.formatted(availableBalance, currency: activeCurrency)))
                            .font(.system(.footnote)).foregroundStyle(AppTheme.red)
                    }
                    .padding(.horizontal, 22)
                    .transition(.opacity)
                }

                // Currency mismatch — show equivalent in debt currency
                if currencyMismatch && amount > 0 {
                    let cardCur = activeCurrency
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(.caption)).foregroundStyle(AppTheme.orange)
                        Text(String(format: loc("debt.approx_in"), CurrencyManager.shared.formatted(amountInDebtCurrency, currency: debt.currency), debt.currency))
                            .font(.system(.caption)).foregroundStyle(AppTheme.orange)
                        Text("(\(cardCur) → \(debt.currency))")
                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 22)
                    .transition(.opacity)
                }
            }

            // Card picker (deduct from which account)
            if cards.count > 1 {
                Divider().padding(.horizontal, 22).padding(.vertical, 4)
                VStack(spacing: 8) {
                    Text(loc("debt.pay_from")).font(.system(.footnote, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                                let network = CardNetwork.detect(from: card.cardNumber)
                                let cardCur = card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
                                let rawBal  = card.balance + card.transactions.reduce(0.0) { sum, tx in
                                    sum + CurrencyManager.shared.convert(tx.amount, from: tx.currency, to: cardCur)
                                }
                                let hasMismatch = cardCur != debt.currency
                                Button { HapticManager.shared.tap(); selectedCardIndex = i } label: {
                                    VStack(spacing: 4) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: AppRadius.xs)
                                                .fill(LinearGradient(
                                                    colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                                                    startPoint: .leading, endPoint: .trailing))
                                                .frame(width: 80, height: 48)
                                                .overlay(RoundedRectangle(cornerRadius: AppRadius.xs)
                                                    .stroke(selectedCardIndex == i ? AppTheme.accent : Color.clear, lineWidth: 2))
                                            VStack(spacing: 2) {
                                                Text(card.isDigitalWallet
                                                     ? (card.walletProvider.isEmpty ? loc("cards.wallet") : card.walletProvider)
                                                     : "•••• \(card.cardNumber.suffix(4))")
                                                    .font(.system(.caption2, weight: .semibold)).foregroundStyle(.white)
                                                Text(card.isDigitalWallet ? loc("cards.wallet") : network.name)
                                                    .font(.system(.caption2)).foregroundStyle(.white.opacity(0.6))
                                            }
                                        }
                                        Text(CurrencyManager.shared.formatted(rawBal, currency: cardCur))
                                            .font(.system(.caption2, weight: .medium))
                                            .foregroundStyle(selectedCardIndex == i ? AppTheme.accent : AppTheme.textSecondary)
                                        if hasMismatch {
                                            Text(loc("tx.auto_convert"))
                                                .font(.system(.caption2))
                                                .foregroundStyle(AppTheme.orange)
                                        }
                                    }
                                }
                                .buttonStyle(ScaleButtonStyle())
                            }
                        }
                        .padding(.horizontal, 22)
                    }
                }
            }

            Divider().padding(.horizontal, 22).padding(.top, 8)

            if let err = errorMsg {
                Text(err).font(.system(.footnote)).foregroundStyle(AppTheme.red).padding(.horizontal, 22)
            }

            // Pay button
            Button { makePayment() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "dollarsign.circle.fill").font(.system(.callout))
                    Text(amount > 0 ? String(format: loc("debt.pay"), CurrencyManager.shared.formatted(amount, currency: activeCurrency)) : loc("debt.enter_amount"))
                        .font(.system(.callout, weight: .bold))
                }
                .foregroundStyle(isValid ? .white : AppTheme.textSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(
                    isValid
                    ? AnyShapeStyle(LinearGradient(colors: [debt.debtType.color, debt.debtType.color.opacity(0.7)],
                                                   startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(AppTheme.cardMid),
                    in: RoundedRectangle(cornerRadius: AppRadius.lg)
                )
            }
            .buttonStyle(ScaleButtonStyle()).disabled(!isValid).padding(.horizontal, 22)
            .padding(.top, 8)

            Spacer()
        }
        .animation(.spring(response: 0.3), value: selectedCardIndex)
        .animation(.spring(response: 0.3), value: amount)
        // When user switches card, reset amount so they don't accidentally pay wrong amount in wrong currency
        .onChange(of: selectedCardIndex) { _, _ in amountText = "" }
    }

    private func makePayment() {
        guard isValid else {
            errorMsg = wouldGoNegative ? loc("debt.insufficient_balance_card") : loc("debt.enter_amount")
            HapticManager.shared.error(); return
        }
        guard !cards.isEmpty else { errorMsg = loc("debt.empty_card"); return }

        let card = cards[min(selectedCardIndex, cards.count - 1)]
        let cardCur = card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
        
        let source = CurrencyManager.shared.formatted(amount, currency: activeCurrency)
        let target = CurrencyManager.shared.formatted(amountInDebtCurrency, currency: debt.currency)

        // 1. Record expense on card in card's currency (amount is already in card currency)
        // ⚠️ NEVER store loc(...) output in SwiftData — it freezes the string in whichever
        // language was active at creation time, so switching languages later leaves old
        // transactions stuck in the old language. Store stable keys instead; translation
        // happens at render time via TxRecord.displayType / displayNotes.
        let tx = TxRecord(
            name: String(format: loc("debt.payment_name"), debt.name),
            date: .now,
            amount: -amount,
            type: "tx.type.debt_payment",   // stable key — resolved at display time
            icon: "💳",
            iconBgHex: TxCategory.debtPayment.iconBg,
            category: .debtPayment,
            currency: cardCur,
            notes: currencyMismatch
                ? String(
                    format: loc("tx.note.debt_payment_conversion"),
                    source,
                    target)   // pre-formatted (language at create time persists — known limitation for format-string notes)
                : "tx.note.debt_payment_auto",   // stable key
            linkedDebtID: debt.id.uuidString  // ← link tx to debt for auto-rollback on delete
        )
        card.transactions.append(tx)

        // 2. Sync currentBalance to match the new effective balance.
        // currentBalance is now a denormalized cache of effectiveBalance — kept
        // in sync here for any code path that still reads it directly. The UI
        // should prefer effectiveBalance() which is always correct.
        try? context.save()  // save tx first so it appears in subsequent fetch
        debt.currentBalance = max(debt.currentBalance - amountInDebtCurrency, 0)
        debt.hasBeenTracked = true  // mark this debt as managed by linked txs

        // 3. Mark paid if balance reaches zero
        if debt.currentBalance == 0 {
            debt.isActive = false
            HapticManager.shared.rigidImpact()
            ActionFeedbackCenter.shared.celebrateDebtPayoff(
                name: debt.name, total: debt.totalAmount, currency: debt.currency,
                since: debt.createdAt, monthlyFreed: debt.minimumPayment)
        } else {
            HapticManager.shared.success()
            ActionFeedbackCenter.shared.debtPaid(
                amount: amount, currency: activeCurrency, debtName: debt.name,
                remaining: debt.currentBalance, remainingCurrency: debt.currency)
        }

        try? context.save()
        dismiss()
    }
}

struct QuickPayButton: View {
    let label: String
    let amount: Double
    let currency: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: { HapticManager.shared.tap(); action() }) {
            VStack(spacing: 3) {
                Text(label).font(.system(.caption2, weight: .semibold)).foregroundStyle(color)
                Text(CurrencyManager.shared.formatted(amount, currency: currency))
                    .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(color.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Payoff Simulator Sheet

struct PayoffSimulatorSheet: View {
    let debt: DebtRecord
    let allDebts: [DebtRecord]
    let income: Double
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDebt: DebtRecord
    @State private var extraPayment: Double = 0
    @State private var extraPaymentText: String = ""

    init(debt: DebtRecord, allDebts: [DebtRecord], income: Double) {
        self.debt = debt
        self.allDebts = allDebts
        self.income = income
        self._selectedDebt = State(initialValue: debt)
    }

    private var currency: String { selectedDebt.currency }
    private var fmt: (Double) -> String { { CurrencyManager.shared.formatted($0, currency: currency) } }
    
    /// Renders a quick-add chip label like "+100rb" / "+1jt" (Indonesian) or
    /// "+100K" / "+1M" (English) using the app's currently-selected language
    /// rather than the device locale. Adds the "+" sign so it's clear these
    /// add to the existing extra-payment amount.
    private func quickChipLabel(_ amt: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = LanguageManager.shared.currentLocale
        formatter.usesGroupingSeparator = true
        // For values >= 1000, use compact notation in the right language.
        // We do this manually because NumberFormatter's compact style behaves
        // inconsistently across locales — explicit suffixes are predictable.
        let lang = LanguageManager.shared.current.rawValue
        let useID = (lang == "id")
        let suffix: (String, String) = useID ? ("rb", "jt") : ("K", "M")
        let absAmt = abs(amt)
        let label: String
        if absAmt >= 1_000_000 {
            let v = Double(absAmt) / 1_000_000
            label = (v.truncatingRemainder(dividingBy: 1) == 0)
                ? "\(Int(v))\(suffix.1)"
                : String(format: "%.1f%@", v, suffix.1)
        } else if absAmt >= 1_000 {
            let v = Double(absAmt) / 1_000
            label = (v.truncatingRemainder(dividingBy: 1) == 0)
                ? "\(Int(v))\(suffix.0)"
                : String(format: "%.1f%@", v, suffix.0)
        } else {
            label = "\(absAmt)"
        }
        return (amt >= 0 ? "+" : "-") + label
    }

    private var baseMonths: Int?    { selectedDebt.monthsToPayoff(monthlyPayment: selectedDebt.minimumPayment) }
    private var boostedMonths: Int? {
        guard extraPayment > 0 else { return baseMonths }
        return selectedDebt.monthsToPayoff(monthlyPayment: selectedDebt.minimumPayment + extraPayment)
    }
    private var monthsSaved: Int {
        guard let b = baseMonths, let bst = boostedMonths else { return 0 }
        return max(b - bst, 0)
    }
    private var interestSaved: Double {
        let baseInterest = (selectedDebt.minimumPayment * Double(baseMonths ?? 0)) - selectedDebt.currentBalance
        let boostedInterest = ((selectedDebt.minimumPayment + extraPayment) * Double(boostedMonths ?? 0)) - selectedDebt.currentBalance
        return max(baseInterest - boostedInterest, 0)
    }
    private var payoffDateBase: String {
        guard let m = baseMonths else { return "N/A" }
        let date = Calendar.current.safeDate(byAdding: .month, value: m, to: .now)
        let fmt = DateFormatter(); fmt.dateFormat = "MMM yyyy"
        return fmt.string(from: date)
    }
    private var payoffDateBoosted: String {
        guard let m = boostedMonths else { return "N/A" }
        let date = Calendar.current.safeDate(byAdding: .month, value: m, to: .now)
        let fmt = DateFormatter(); fmt.dateFormat = "MMM yyyy"
        return fmt.string(from: date)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {

                        // Debt picker
                        if allDebts.count > 1 {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(loc("debt.select_debt"))
                                    .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(allDebts) { d in
                                            Button {
                                                HapticManager.shared.tap()
                                                withAnimation(.spring(response: 0.3)) { selectedDebt = d }
                                            } label: {
                                                Text(d.name)
                                                    .font(.system(size: 13, weight: selectedDebt.id == d.id ? .semibold : .regular))
                                                    .foregroundStyle(selectedDebt.id == d.id ? AppTheme.onVividFill : AppTheme.textPrimary)
                                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                                    .background(selectedDebt.id == d.id ? AppTheme.accentFill : AppTheme.cardMid,
                                                                in: Capsule())
                                            }.buttonStyle(ScaleButtonStyle())
                                        }
                                    }.padding(.horizontal, 22)
                                }
                            }
                            .padding(.top, 4)
                        }

                        // Current debt summary
                        VStack(spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(selectedDebt.name)
                                        .font(.system(.callout, weight: .bold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                    HStack(spacing: 8) {
                                        Text(selectedDebt.debtType.label)
                                            .font(.system(.caption2))
                                            .foregroundStyle(AppTheme.textSecondary)
                                            .padding(.horizontal, 8).padding(.vertical, 3)
                                            .background(AppTheme.cardMid, in: Capsule())
                                        Text(String(
                                            format: loc("debt.apr"),
                                            selectedDebt.annualInterestRate
                                        ))
                                            .font(.system(.caption2, weight: .semibold))
                                            .foregroundStyle(AppTheme.red)
                                            .padding(.horizontal, 8).padding(.vertical, 3)
                                            .background(AppTheme.red.opacity(0.12), in: Capsule())
                                    }
                                }
                                Spacer()
                                Text(fmt(selectedDebt.currentBalance))
                                    .font(.system(.title3, weight: .bold))
                                    .foregroundStyle(AppTheme.red)
                            }
                        }
                        .padding(16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.red.opacity(0.2), lineWidth: 1))
                        .padding(.horizontal, 22)

                        // Extra payment input
                        VStack(alignment: .leading, spacing: 10) {
                            Text(String(format: loc("debt.extra_payment_count"), fmt(extraPayment)))
                                .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)

                            HStack(spacing: 12) {
                                Text(CurrencyManager.symbol(for: currency))
                                    .font(.system(.body, weight: .bold))
                                    .foregroundStyle(AppTheme.textSecondary)
                                TextField("0", text: $extraPaymentText)
                                    .font(.system(.title2, weight: .bold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .keyboardType(.numberPad)
                                    .onChange(of: extraPaymentText) { _, v in
                                        extraPayment = Double(v.filter { $0.isNumber }) ?? 0
                                    }
                            }
                            .padding(16)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))

                            // Quick add buttons.
                            // Amounts are scaled to the debt's currency so the
                            // chips stay sensible — adding "+1M" to a $1,000
                            // debt would be absurd, so for USD we offer
                            // +10/+25/+50/+100 instead. Compact-name notation
                            // ("K", "M", "rb", "jt") is rendered with the user's
                            // currently-selected language locale, not the device
                            // locale, so it matches the rest of the app's text.
                            HStack(spacing: 8) {
                                let quickAmounts: [Int] = {
                                    let cur = selectedDebt.currency.uppercased()
                                    if cur == "IDR" {
                                        return [100_000, 250_000, 500_000, 1_000_000]
                                    } else {
                                        // USD / EUR / similar — small unit currencies
                                        return [10, 25, 50, 100]
                                    }
                                }()
                                ForEach(quickAmounts, id: \.self) { amt in
                                    Button {
                                        HapticManager.shared.tap()
                                        extraPayment += Double(amt)
                                        extraPaymentText = String(Int(extraPayment))
                                    } label: {
                                        Text(quickChipLabel(amt))
                                            .font(.system(.caption, weight: .semibold))
                                            .foregroundStyle(AppTheme.accent)
                                            .padding(.horizontal, 10).padding(.vertical, 6)
                                            .background(AppTheme.accent.opacity(0.1), in: Capsule())
                                    }.buttonStyle(ScaleButtonStyle())
                                }
                                Spacer()
                                if extraPayment > 0 {
                                    Button {
                                        HapticManager.shared.tap()
                                        extraPayment = 0; extraPaymentText = ""
                                    } label: {
                                        Text(loc("notif.clear"))
                                            .font(.system(.caption))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 22)

                        // Results comparison
                        VStack(spacing: 12) {
                            HStack {
                                Text(loc("debt.payoff_proj"))
                                    .font(.system(.subheadline, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                if monthsSaved > 0 {
                                    Text(String(format: loc("debt.month_saved"), monthsSaved))
                                        .font(.system(.caption, weight: .bold))
                                        .foregroundStyle(AppTheme.accent)
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(AppTheme.accent.opacity(0.12), in: Capsule())
                                }
                            }

                            // Side-by-side comparison
                            HStack(spacing: 12) {
                                // Minimum only
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(loc("debt.min_only"))
                                        .font(.system(.caption, weight: .semibold))
                                        .foregroundStyle(AppTheme.textSecondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(String(
                                            format: loc("debt.amount_per_month"),
                                            fmt(selectedDebt.minimumPayment)
                                        ))
                                            .font(.system(.footnote, weight: .bold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                        if let m = baseMonths {
                                            Text(String(format: loc("debt.month"), m))
                                                .font(.system(.title3, weight: .bold))
                                                .foregroundStyle(AppTheme.red)
                                            Text(String(format: loc("debt.free_by"), payoffDateBase))
                                                .font(.system(.caption2))
                                                .foregroundStyle(AppTheme.textSecondary)
                                        } else {
                                            Text("∞")
                                                .font(.system(.title, weight: .bold))
                                                .foregroundStyle(AppTheme.red)
                                            Text(loc("debt.payment_lt_int"))
                                                .font(.system(.caption2))
                                                .foregroundStyle(AppTheme.red.opacity(0.8))
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                                .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.red.opacity(0.2), lineWidth: 1))

                                // With extra
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(loc("debt.with_extra"))
                                        .font(.system(.caption, weight: .semibold))
                                        .foregroundStyle(AppTheme.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(String(format: loc("debt.amount_per_month"), fmt(selectedDebt.minimumPayment + max(extraPayment, 0))))
                                            .font(.system(.footnote, weight: .bold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                        if let m = boostedMonths {
                                            Text(String(format: loc("debt.month"), m))
                                                .font(.system(.title3, weight: .bold))
                                                .foregroundStyle(AppTheme.accent)
                                            Text(String(format: loc("debt.free_by"), payoffDateBoosted))
                                                .font(.system(.caption2))
                                                .foregroundStyle(AppTheme.textSecondary)
                                        } else {
                                            Text(String(format: loc("debt.amount_per_month"), fmt(selectedDebt.minimumPayment)))
                                                .font(.system(.footnote))
                                                .foregroundStyle(AppTheme.textSecondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(AppTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: AppRadius.md))
                                .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.accent.opacity(0.3), lineWidth: 1))
                            }

                            // Interest saved banner
                            if interestSaved > 0 {
                                HStack(spacing: 10) {
                                    Image(systemName: "banknote.fill")
                                        .font(.system(.callout)).foregroundStyle(AppTheme.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(String(format: loc("debt.interest_saved"), fmt(interestSaved)))
                                            .font(.system(.footnote, weight: .semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                        Text(String(format: loc("debt.interest_saved"), fmt(extraPayment)))
                                            .font(.system(.caption2))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                    Spacer()
                                }
                                .padding(14)
                                .background(AppTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.md))
                                .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.accent.opacity(0.25), lineWidth: 1))
                            }
                        }
                        .padding(.horizontal, 22)

                        // Monthly interest cost note
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle").font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                            Text(String(format: loc("debt.monthly_interest"), fmt(selectedDebt.monthlyInterestCost)))
                                .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        }
                        .padding(.horizontal, 22)

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 8)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("debt.payoff_sim"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
    }
}
