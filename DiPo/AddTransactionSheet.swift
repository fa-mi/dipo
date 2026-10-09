import SwiftUI
import SwiftData

// Moved out of UtilityViews.swift, unchanged.

// MARK: - Add Transaction Sheet (updated with IDR/USD)

struct AddTransactionSheet: View {
    let vm: AppViewModel
    var preselectedCategory: TxCategory? = nil
    /// Pre-select a specific card (e.g. "Log a purchase" from a credit card).
    var preselectedCardID: UUID? = nil
    /// Lock the card to `preselectedCardID` so it can't be swiped away. Set by the
    /// credit-card "Log a purchase" entry: that flow exists to record a spend on
    /// THAT card, so letting the user swipe to another card silently logs the
    /// purchase somewhere else. Off for the generic add-transaction entry, where
    /// preselect is only a starting point the user is free to change.
    var lockToPreselectedCard: Bool = false
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var activeDebts: [DebtRecord]
    @Query(sort: \SalarySchedule.createdAt) private var salarySchedules: [SalarySchedule]
    @Query private var cardBudgetConfigs: [CardBudgetConfig]
    /// Whole history, used to learn how THIS user categorises merchants.
    @Query private var allTransactions: [TxRecord]
    @Query private var allInstallments: [CardInstallment]

    @State private var txType: AddTxType = .expense
    @State private var name: String = ""
    @State private var amountText: String = ""
    @State private var currency: String = CurrencyManager.shared.preferredCurrency
    @State private var selectedCategory: TxCategory = .shopping
    @State private var selectedDate: Date = .now
    @State private var selectedCardIndex: Int = 0
    @State private var selectedDebtID: UUID? = nil
    @State private var notes: String = ""
    @State private var showError = false
    @State private var saveInPreferred = false
    @State private var showBudgetAlert = false
    @State private var pendingBudgetAlert: BudgetAlert? = nil
    @State private var showCreditLimitAlert = false
    @State private var creditOverConfirmed = false
    @State private var showConversionPaywall = false
    /// Receipt scanner moved here from the Home FAB. Royal-only feature; tapping
    /// shows the paywall first when the user lacks access.
    @State private var showScanFlow: Bool = false
    @State private var showScanPaywall: Bool = false
    // Subtype is intentionally NOT a field on the create form — assigning
    // refund/transfer to a brand-new tx without a parent is rare and
    // confusing. Instead, the user creates a normal tx, then taps it in
    // the list to access "Mark as Refund/Transfer" actions where the
    // intent is clear (this existing tx came back / this is a movement).
    // See TransactionDetailSheet's subtypeActions section.
    /// Observe PremiumManager so the currency menu, scan-receipt entry, and
    /// effectiveCurrency/effectiveAmount logic re-render when the user
    /// upgrades/downgrades while this sheet is open. Without this, finishing
    /// a purchase in the paywall presented from inside the sheet leaves the
    /// menu stuck in its locked state — user has to dismiss and re-open.
    @State private var pm = PremiumManager.shared

    private var monthlyIncome: Double {
        // Budget limits are based on STATED monthly income, exactly like the
        // Smart Budget screen ("From salary schedule"). This used to add any
        // extra income logged this calendar month, which silently raised the
        // limit here (Rp 5.057.500) while Smart Budget still showed Rp 5.000.000
        // — two different "budget exceeded" thresholds for the same budget.
        let cur = MainCard.resolve(in: vm.cards)?.resolvedCurrency ?? preferredCurrency
        let scheduled = MainCard.salaries(salarySchedules).reduce(0.0) {
            $0 + CurrencyManager.shared.convert($1.amount, from: $1.currency, to: cur)
        }
        if scheduled > 0 { return scheduled }
        // No schedule → fall back to income actually received this month.
        let cal = Calendar.current
        let monthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: Date()))
        let source: [TxRecord] = MainCard.potTransactions(in: vm.cards) ?? allCardTransactions
        let received: [TxRecord] = source.filter { (tx: TxRecord) -> Bool in
            tx.amount > 0 && tx.txSubtype == TxSubtype.normal && tx.date >= monthStart
        }
        return received.reduce(0.0) { (sum: Double, tx: TxRecord) -> Double in
            sum + CurrencyManager.shared.convert(tx.amount, from: tx.currency, to: cur)
        }
    }

    private var allCardTransactions: [TxRecord] {
        vm.cards.flatMap { $0.transactions }
    }

    private var preferredCurrency: String { CurrencyManager.shared.preferredCurrency }

    /// Mata uang dari kartu yang sedang dipilih — ini yang jadi acuan konversi,
    /// bukan preferredCurrency global. Bug lama pakai preferredCurrency sehingga
    /// konversi salah ketika kartu punya currency berbeda dari setting user.
    private var selectedCardCurrency: String {
        guard !vm.cards.isEmpty else { return preferredCurrency }
        let card = vm.cards[min(selectedCardIndex, vm.cards.count - 1)]
        return card.currency.isEmpty ? preferredCurrency : card.currency
    }

    /// Bug 2 fix: bandingkan dengan kartu yang dipilih, bukan preferredCurrency.
    /// Sebelumnya: currency != preferredCurrency
    /// Sesudah:    currency != selectedCardCurrency
    /// Efek: panel "Konversi Cerdas" muncul kapanpun mata uang transaksi ≠ kartu.
    private var isForeignCurrency: Bool { currency != selectedCardCurrency }

    /// Bug 1+2 fix: konversi ke mata uang kartu, bukan preferredCurrency.
    private var convertedAmount: Double {
        CurrencyManager.shared.convert(amount, from: currency, to: selectedCardCurrency)
    }

    /// Bug 1 fix: ketika mata uang transaksi berbeda dari kartu, SELALU konversi.
    /// saveInPreferred dipakai hanya ketika currencies sama (sebagai opsional).
    ///
    /// Premium gate (defense-in-depth): if the user lacks Smart Conversion
    /// access, we never trigger the converter at the save layer — even if
    /// `currency` drifted away from `selectedCardCurrency` during a race
    /// between init and onAppear, or via some future code path. The menu
    /// itself is also gated (it shows the paywall instead), so in practice
    /// these branches never differ. This guard is the last line of defense.
    private var effectiveCurrency: String {
        if !PremiumManager.shared.canAccess(.smartConversion) {
            return selectedCardCurrency
        }
        return isForeignCurrency ? selectedCardCurrency : (saveInPreferred ? selectedCardCurrency : currency)
    }
    private var effectiveAmount: Double {
        if !PremiumManager.shared.canAccess(.smartConversion) {
            // Free users have currency forced to card currency above; the
            // typed amount is therefore already in the right unit and needs
            // no conversion.
            return amount
        }
        return isForeignCurrency ? convertedAmount : (saveInPreferred ? convertedAmount : amount)
    }

    /// Bug 3 fix: jumlahkan semua transaksi dengan konversi mata uang yang benar.
    /// Sebelumnya: card.transactions.reduce(0) { $0 + $1.amount } — tidak konversi!
    ///   Kartu IDR dengan tx +5.000.000 IDR dan +1.000 USD → salah jadi 5.001.000.
    /// Sesudah: tiap tx dikonversi ke mata uang kartu sebelum dijumlahkan,
    ///   sama persis dengan liveTransactionBalance() di BankCardHelpers.
    /// A credit card cannot receive income. Money arriving on one is a bill
    /// payment or a refund, which have their own flows — and logging it as
    /// Income here would count toward reported income (StatisticsView sums
    /// `amount > 0`), inflating what the user appears to earn.
    private var selectedIsCredit: Bool { selectedCardOrNil?.isCreditCard == true }

    private var selectedCardOrNil: BankCard? {
        guard !vm.cards.isEmpty else { return nil }
        return vm.cards[min(selectedCardIndex, vm.cards.count - 1)]
    }

    private var selectedCardBalance: Double {
        guard !vm.cards.isEmpty else { return 0 }
        let card = vm.cards[min(selectedCardIndex, vm.cards.count - 1)]
        let cardCur = card.currency.isEmpty ? preferredCurrency : card.currency
        let txBalance = card.transactions.reduce(0.0) { sum, tx in
            sum + CurrencyManager.shared.convert(tx.amount, from: tx.currency, to: cardCur)
        }
        return card.balance + txBalance
    }

    /// Bug 3 fix: bandingkan dalam mata uang kartu secara konsisten.
    /// Sebelumnya: selectedCardBalance (salah) - effectiveAmount (kadang IDR, kadang USD)
    /// Sesudah:    selalu konversi ke selectedCardCurrency sebelum dibandingkan.
    private var wouldGoNegative: Bool {
        guard txType == .expense, amount > 0 else { return false }
        // A credit card holds no cash, so `balance` is meaningless for it —
        // spending room is limit minus what is owed. Blocking here compared
        // the purchase against a leftover cash figure and refused perfectly
        // affordable purchases on a card with millions of rupiah of credit
        // still free. The real ceiling is enforced in `saveTransaction()`,
        // which warns and still lets the user proceed the way an issuer does.
        if let card = selectedCardOrNil, card.isCreditCard { return false }
        let amountInCardCurrency: Double
        if saveInPreferred {
            // sudah dikonversi ke selectedCardCurrency
            amountInCardCurrency = convertedAmount
        } else {
            // konversi amount ke selectedCardCurrency untuk perbandingan
            amountInCardCurrency = CurrencyManager.shared.convert(
                amount, from: currency, to: selectedCardCurrency
            )
        }
        return selectedCardBalance - amountInCardCurrency < 0
    }
    private var availableCategories: [TxCategory] {
        switch txType {
        // `.debtPayment` belongs here. Without it, someone paying off a credit
        // card by hand had no honest option and reached for "Other" — which is
        // how a Rp 1.000.000 debt repayment ended up inside this user's daily
        // spending pattern, month after month. The two menu flows (Debt Tracker
        // and the CC bill screen) always categorised it correctly; the manual
        // path was the one with no right answer.
        case .expense: return [.shopping, .food, .travel, .bills, .transport,
                               .health, .commitment, .investment, .debtPayment, .other]
        case .income:  return [.salary, .freelance, .business, .investment, .bonus, .gift, .incomeOther]
        }
    }

    enum AddTxType: String, CaseIterable {
        case expense
        case income
        
        var title: String {
                switch self {
                case .expense: return loc("tx.expense")
                case .income:  return loc("tx.income")
                }
            }

        /// Used only as a solid fill (the type capsule, the Record button), so
        /// it takes the fill tokens. Reading `AppTheme.red` here is what
        /// dragged the light-mode button from salmon to a hard red when `red`
        /// was darkened for TEXT legibility — a change the fill never needed.
        var color: Color { self == .expense ? AppTheme.redFill : AppTheme.accentFill }
        var icon: String { self == .expense ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }
    }

    var amount: Double { NumberInput.amount(amountText) }
    var isValid: Bool  { !name.trimmingCharacters(in: .whitespaces).isEmpty && amount > 0 }

    @ViewBuilder
    var currencyButtonLabel: some View {
        HStack(spacing: 6) {
            Text(CurrencyManager.symbol(for: currency))
                .font(.system(.subheadline, weight: .bold))
                .foregroundStyle(AppTheme.accent)
            Text(currency)
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(.caption2)).imageScale(.small)
                .foregroundStyle(AppTheme.textSecondary)
        }
        // `cardMid`, not `cardDark`: this pill now sits INSIDE the amount card,
        // and cardDark on cardDark is white on white in light mode.
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.accent.opacity(0.3), lineWidth: 1))
    }

    var convertedPreview: String {
        guard amount > 0, currency != CurrencyManager.shared.preferredCurrency else { return "" }
        let pref = CurrencyManager.shared.preferredCurrency
        let conv = CurrencyManager.shared.convert(amount, from: currency, to: pref)
        return String(format: loc("tx.converted_in"),
                      CurrencyManager.shared.formatted(conv, currency: pref), pref)
    }

    // MARK: - Form sections
    //
    // `body` used to be one ~560-line expression, and Swift's type checker had
    // started refusing it outright ("unable to type-check this expression in
    // reasonable time") whenever anything else was added. Naming each section
    // fixes that, and it means the order of the form — what the user meets
    // first, second, third — is readable in ten lines instead of six hundred.

    /// Scanning fills the whole form in one shot, so it belongs above the form,
    /// before anyone starts typing a thing they would then have to undo.
    @ViewBuilder
    private var scanEntrySection: some View {
        if !vm.cards.isEmpty && txType == .expense {
            Button {
                HapticManager.shared.tap()
                if PremiumManager.shared.canAccess(.scanReceipt) {
                    showScanFlow = true
                } else {
                    showScanPaywall = true
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppRadius.sm)
                            .fill(AppTheme.accent.opacity(0.14))
                            .frame(width: 38, height: 38)
                        Image(systemName: "doc.text.viewfinder")
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(loc("receipt.entry.title"))
                                .font(.system(.subheadline, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                            if !PremiumManager.shared.canAccess(.scanReceipt) {
                                Image(systemName: "crown.fill")
                                    .font(.system(.caption2, weight: .bold)).imageScale(.small)
                                    .foregroundStyle(AppTheme.onVividFill)
                                    .padding(3)
                                    .background(PremiumPlan.royal.color, in: Circle())
                            }
                        }
                        Text(loc("receipt.entry.subtitle"))
                            .font(.system(.caption2))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(12)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppTheme.accent.opacity(0.22), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 22)
        }
    }

    private var typeSection: some View {
        HStack(spacing: 0) {
            ForEach(AddTxType.allCases, id: \.self) { type in
                let blocked = (type == .income && selectedIsCredit)
                Button {
                    HapticManager.shared.select()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { txType = type }
                    if !availableCategories.contains(selectedCategory) {
                        selectedCategory = type == .expense ? .shopping : .salary
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: type.icon).font(.system(.subheadline))
                        Text(type.title).font(.system(.subheadline, weight: .semibold))
                    }
                    .foregroundStyle(txType == type ? AppTheme.onVividFill
                                     : AppTheme.textSecondary.opacity(blocked ? 0.35 : 1))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background {
                        if txType == type {
                            Capsule().fill(type.color)
                        }
                    }
                }
                .disabled(blocked)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: txType)
            }
        }
        .padding(4)
        .background(AppTheme.cardDark, in: Capsule())
        .padding(.horizontal, 22)
    }

    /// The amount is the reason this screen exists, so it gets the largest type
    /// on it and shares a single surface with the currency it is denominated in
    /// — the two were previously separate boxes, which read as two questions.
    @ViewBuilder
    private var amountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if PremiumManager.shared.canAccess(.smartConversion) {
                    Menu {
                        ForEach(CurrencyManager.supportedCurrencies, id: \.code) { c in
                            Button {
                                HapticManager.shared.tap()
                                currency = c.code
                            } label: {
                                Label("\(c.flag) \(c.code) — \(c.name)",
                                      systemImage: currency == c.code ? "checkmark" : "")
                            }
                        }
                    } label: {
                        currencyButtonLabel
                    }
                } else {
                    Button { HapticManager.shared.tap(); showConversionPaywall = true } label: {
                        currencyButtonLabel
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "lock.fill")
                                    .font(.system(.caption2, weight: .bold)).imageScale(.small)
                                    .foregroundStyle(AppTheme.onVividFill)
                                    .padding(3)
                                    .background(PremiumPlan.royal.color, in: Circle())
                                    .offset(x: 4, y: -4)
                            }
                    }
                    .buttonStyle(.plain)
                }

                TextField("0", text: $amountText)
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .keyboardType(.decimalPad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))

            // One quiet line under the field, not three. Whichever of these is
            // true is the one worth reading: a cross-currency result beats a
            // formatting echo, and both beat the bare rate.
            Group {
                if !convertedPreview.isEmpty {
                    Text(convertedPreview)
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                } else if let p = AmountInputHelper.preview(amountText, currency: currency) {
                    // Echo "5000000" back as "Rp 5.000.000" so a digit-count
                    // typo is caught before it is saved, not after.
                    Text(p)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    Text(CurrencyManager.shared.rateLabel)
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if amount > 0 && isForeignCurrency {
                conversionPanel
            }
        }
        .padding(.horizontal, 22)
    }

    private var conversionPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(AppTheme.accent.opacity(0.12)).frame(width: 36, height: 36)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("tx.smart_convert"))
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(String(format: loc("tx.save_in_currency"), selectedCardCurrency))
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                // Locked ON: a transaction in a currency the card does not hold
                // MUST be converted, or the balance stops meaning anything.
                Text(loc("tx.required"))
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(AppTheme.accent.opacity(0.12), in: Capsule())
            }

            if saveInPreferred {
                Divider().background(AppTheme.cardMid)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc("tx.you_entered"))
                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                        Text(CurrencyManager.shared.formatted(amount, currency: currency))
                            .font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                    }
                    Image(systemName: "arrow.right")
                        .font(.system(.caption)).foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc("tx.saved_as"))
                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                        Text(CurrencyManager.shared.formatted(convertedAmount, currency: selectedCardCurrency))
                            .font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.accent)
                    }
                    Spacer()
                }
                Text(CurrencyManager.shared.rateLabel)
                    .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(AppTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
            .stroke(AppTheme.accent.opacity(saveInPreferred ? 0.4 : 0.15), lineWidth: 1))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: saveInPreferred)
    }

    @ViewBuilder
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconField(label: loc("tx.name_label"),
                      icon: "textformat",
                      placeholder: selectedCategory == .debtPayment
                          ? loc("tx.debt_placeholder")
                          : loc("tx.name_placeholder"),
                      text: $name)
                .onChange(of: name) { _, newName in
                    // The user's own history first, the shipped keyword map
                    // second — what this person actually does beats a guess.
                    if txType == .expense,
                       let suggested = CategorySuggestionHint.autoPick(
                            for: newName, transactions: allTransactions,
                            categories: availableCategories) {
                        // Without animation: this follows the typing keystroke
                        // by keystroke, and a spring on every guess set tiles,
                        // labels and the hint line moving under the words the
                        // user was still writing.
                        selectedCategory = suggested
                    }
                }

            if txType == .expense {
                CategorySuggestionHint(name: name, transactions: allTransactions,
                                       categories: availableCategories,
                                       selection: $selectedCategory)
            }
        }
        .padding(.horizontal, 22)
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormSectionLabel(text: loc("common.category"))
                .padding(.horizontal, 22)
            CategoryTilePicker(categories: availableCategories, selection: $selectedCategory)
        }
    }

    /// Always shown, even with a single card: "which account does this land
    /// on" is worth answering before saving, not only when there is a choice.
    @ViewBuilder
    private var cardSection: some View {
        if !vm.cards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                FormSectionLabel(text: loc("debt.card"))
                    .padding(.horizontal, 22)
                // For a credit card the face states the room left on the limit,
                // not what is owed — at the moment of spending, that is the
                // number that matters.
                CardSwipePicker(cards: vm.cards, selectedIndex: $selectedCardIndex,
                                locked: lockToPreselectedCard) { card in
                    card.isCreditCard
                        ? (loc("cc.available"),
                           CurrencyManager.shared.formatted(card.availableCredit(allInstallments),
                                                            currency: card.resolvedCurrency))
                        : (loc("home.balance_total"), card.formattedBalance)
                }
                // Say WHY the card can't be changed here, so a locked picker reads
                // as intentional rather than broken.
                if lockToPreselectedCard {
                    Label(loc("tx.card_locked_cc"), systemImage: "lock.fill")
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 22)
                }
            }
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormSectionLabel(text: loc("tx.date_time"))
            DateTimeFields(date: $selectedDate)
        }
        .padding(.horizontal, 22)
    }

    private var notesSection: some View {
        IconField(label: loc("tx.notes"),
                  icon: "text.alignleft",
                  placeholder: loc("tx.notes_placeholder"),
                  text: $notes,
                  optionalHint: loc("common.optional"))
            .padding(.horizontal, 22)
    }

    @ViewBuilder
    private var warningSection: some View {
        let negative = wouldGoNegative && !vm.cards.isEmpty && txType == .expense
        // Guarded as a whole. An empty VStack still counts as a child, so the
        // parent's 20pt spacing landed on both sides of nothing.
        if selectedIsCredit || vm.cards.isEmpty || negative || showError {
        VStack(spacing: 10) {
            // A disabled control with no explanation reads as a bug. Name the
            // reason, and point at the flow that does handle money arriving on
            // a credit card.
            if selectedIsCredit {
                InlineBanner(tone: .info, message: loc("tx.credit_no_income"))
            }
            if vm.cards.isEmpty {
                InlineBanner(tone: .warning, message: loc("common.add_card_tx"))
            }
            if wouldGoNegative && !vm.cards.isEmpty && txType == .expense {
                let msg = loc("tx.insufficient") + "\n"
                    + String(format: loc("tx.available_balance"),
                             CurrencyManager.shared.formatted(Swift.abs(selectedCardBalance),
                                                              currency: selectedCardCurrency))
                InlineBanner(tone: .error, message: msg)
            }
            if showError {
                InlineBanner(tone: .error, message: loc("tx.valid_error"))
            }
        }
        .padding(.horizontal, 22)
        }
    }

    private var submitSection: some View {
        // No Cancel under Save: the toolbar already has one, and a second exit
        // a thumb's width below the primary action is a mis-tap waiting to
        // throw away a filled-in form.
        VStack(spacing: 6) {
            Button { saveTransaction() } label: {
                // Computed once for both fill and label: the old code styled the
                // label `AppTheme.bg` unconditionally, so a disabled button was
                // light text on a light grey fill — effectively invisible.
                let canSubmit = isValid && !(wouldGoNegative && txType == .expense)
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(.body))
                    Text(String(format: loc("tx.add_type"), txType.title))
                        .font(.system(.callout, weight: .bold))
                }
                .foregroundStyle(canSubmit ? AppTheme.onVividFill : AppTheme.textSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 17)
                .background(canSubmit ? txType.color : AppTheme.textSecondary.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!isValid || vm.cards.isEmpty || (wouldGoNegative && txType == .expense))
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
    }

    var body: some View {
        // Touch pm.plan so SwiftUI's @Observable tracking registers this body
        // as a dependent of PremiumManager.shared. After a successful upgrade
        // the body re-evaluates and the locked currency-menu / scan-receipt
        // entry refresh without needing the user to re-open the sheet.
        let _ = pm.plan
        return NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        scanEntrySection
                        typeSection
                        amountSection
                        nameSection
                        categorySection
                        cardSection
                        dateSection
                        notesSection
                        warningSection
                        submitSection

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 6)
                    .containerRelativeFrame(.horizontal)
                    // No entrance animation. The sheet already carries the form
                    // up; fading and lifting the content inside it as well made
                    // every label drift into place a beat after the sheet had
                    // landed, which read as the screen glitching, not as polish.
                    // Content arriving is not a change the user caused, and
                    // AppMotion reserves motion for those.
                    // These two were previously attached to the card picker and
                    // so only ran when the user owned more than one card. The
                    // currency rule is not about how many cards exist.
                    .onChange(of: selectedCardIndex) { _, i in
                        guard i < vm.cards.count else { return }
                        let card = vm.cards[i]
                        currency = card.currency.isEmpty
                            ? CurrencyManager.shared.preferredCurrency
                            : card.currency
                        saveInPreferred = false   // a newly picked card matches its own currency
                        // Switching to a credit card while Income is selected
                        // would leave the form on a type its own picker now
                        // refuses to let you select.
                        if card.isCreditCard, txType == .income {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                txType = .expense
                            }
                            if !availableCategories.contains(selectedCategory) {
                                selectedCategory = .shopping
                            }
                        }
                    }
                    .onChange(of: currency) { _, newCur in
                        // Without this a USD amount could be saved onto an IDR
                        // card unconverted, and the balance stops adding up.
                        withAnimation(.spring(response: 0.3)) {
                            saveInPreferred = newCur != selectedCardCurrency
                        }
                    }
                }
            }
            .navigationTitle(loc("tx.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { HapticManager.shared.tap(); dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        .onAppear {
            CurrencyManager.shared.fetchRate()
            // Start on the card the user was viewing on home, or a specific
            // card if the caller asked for one (e.g. "Log a purchase" on a CC).
            if let id = preselectedCardID, let idx = vm.cards.firstIndex(where: { $0.id == id }) {
                selectedCardIndex = idx
            } else {
                selectedCardIndex = min(vm.selectedCardIndex, max(vm.cards.count - 1, 0))
            }
            // Init currency from that card
            if !vm.cards.isEmpty {
                let card = vm.cards[min(selectedCardIndex, vm.cards.count - 1)]
                let cardCur = card.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : card.currency
                currency = cardCur
            }
            if let pre = preselectedCategory {
                selectedCategory = pre
                if pre == .debtPayment { txType = .expense }
            }
        }
        .sheet(isPresented: $showConversionPaywall) {
            PaywallView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        // Receipt scan flow — full screen so the camera has the whole canvas.
        // We pass the currently-selected card's currency so the parser can
        // disambiguate ambiguous amounts (e.g., "150" → IDR vs USD).
        .fullScreenCover(isPresented: $showScanFlow) {
            ReceiptScanFlow(
                cardCurrency: selectedCardCurrency,
                onCompleted: {
                    // Scan flow saved the tx directly. Dismiss the parent
                    // AddTransactionSheet so the user lands back on Home with
                    // the new tx visible.
                    dismiss()
                }
            )
            .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showScanPaywall) {
            PaywallView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .confirmSheet(isPresented: $showBudgetAlert,
                      icon: pendingBudgetAlert?.isExceeded == true
                          ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.67percent",
                      tone: .warning,
                      title: pendingBudgetAlert?.isExceeded == true
                          ? loc("tx.budget_exceed") : loc("tx.approach_limit"),
                      message: budgetAlertMessage,
                      confirmLabel: loc("tx.add_anyway")) { commitTransaction() }
        .confirmSheet(isPresented: $showCreditLimitAlert,
                      icon: "creditcard.trianglebadge.exclamationmark",
                      tone: .warning,
                      title: loc("cc.over_limit_title"),
                      message: creditOverMessage,
                      confirmLabel: loc("tx.add_anyway")) {
            creditOverConfirmed = true
            saveTransaction()
        }
        .trackScreen(.addTransaction)
    }

    private var budgetAlertMessage: String {
        guard let alert = pendingBudgetAlert else { return "" }
        let pref = CurrencyManager.shared.preferredCurrency
        if alert.isExceeded {
            return String(format: loc("tx.budget_over_msg"), alert.displayLabel.lowercased(),
                          CurrencyManager.shared.formatted(alert.over, currency: pref),
                          CurrencyManager.shared.formatted(alert.limit, currency: pref))
        }
        return String(format: loc("tx.budget_approach_msg"), alert.displayLabel.lowercased(),
                      CurrencyManager.shared.formatted(alert.limit, currency: pref),
                      CurrencyManager.shared.formatted(alert.limit - alert.spent, currency: pref))
    }

    private var creditOverMessage: String {
        guard vm.cards.indices.contains(selectedCardIndex) else { return "" }
        let card = vm.cards[selectedCardIndex]
        return String(format: loc("cc.over_limit_msg"),
                      CurrencyManager.shared.formatted(card.availableCredit(allInstallments),
                                                       currency: card.resolvedCurrency))
    }

    private func saveTransaction() {
        guard isValid else { HapticManager.shared.error(); withAnimation { showError = true }; return }
        guard !vm.cards.isEmpty else {
            HapticManager.shared.error(); withAnimation { showError = true }; return
        }

        // Credit-limit check — spending on a credit card that would blow past
        // its limit. Warns once; "Add anyway" proceeds (issuers do allow small
        // over-limit spend). Only for expenses on a credit card.
        if txType == .expense, vm.cards.indices.contains(selectedCardIndex) {
            let card = vm.cards[selectedCardIndex]
            if card.isCreditCard, card.creditLimit > 0, !creditOverConfirmed {
                let addInCardCur = CurrencyManager.shared.convert(abs(effectiveAmount), from: effectiveCurrency, to: card.resolvedCurrency)
                // `totalOwed` counts instalment principal; `owedBalance()` does
                // not, so this used to let a purchase through that the card had
                // no room for once running instalments were taken into account.
                if card.totalOwed(allInstallments) + addInCardCur > card.creditLimit {
                    showCreditLimitAlert = true
                    HapticManager.shared.warning()
                    return
                }
            }
        }

        // Smart budget check — only for expenses
        // The budget follows the main card, so only spending on it can push a
        // group past its limit. This used to sum every card against the main
        // card's pay, and the global split rather than the card's own.
        let budgetCard = MainCard.resolve(in: vm.cards)
        // A bill card's spending is the main card's money too.
        if txType == .expense, let main = budgetCard,
           let picked = selectedCardOrNil, picked.id == main.id || MainCard.isBillCard(picked) {
            // Pay-cycle scoped, the same window the Smart Budget screen uses — a
            // calendar month understates spend before payday, so the warning
            // wouldn't fire even when already over.
            let cycleStart: Date? = MainCard.payDay(salarySchedules).map {
                StatPeriod.cycle(payDay: $0, salaryDates: StatPeriod.salaryDates(on: main)).start
            }
            if let alert = SmartBudgetManager.shared.wouldExceed(
                category: selectedCategory,
                amount: CurrencyManager.shared.convert(abs(effectiveAmount), from: effectiveCurrency,
                                                       to: main.resolvedCurrency),
                currency: main.resolvedCurrency,
                transactions: MainCard.budgetTransactions(in: vm.cards),
                // Plus money in added to this period's budget, as Smart Budget shows it.
                income: monthlyIncome + ExtraFunds.total(
                    in: MainCard.budgetTransactions(in: vm.cards),
                    from: cycleStart ?? Calendar.current.safeDate(
                        from: Calendar.current.dateComponents([.year, .month], from: Date())),
                    currency: main.resolvedCurrency),
                periodStart: cycleStart,
                cardID: main.id.uuidString,
                configs: cardBudgetConfigs
            ) {
                pendingBudgetAlert = alert
                showBudgetAlert = true
                HapticManager.shared.warning()
                return
            }
        }

        commitTransaction()
    }

    private func commitTransaction() {
        let finalAmount = txType == .expense ? -abs(effectiveAmount) : abs(effectiveAmount)
        // Stable keys stored in DB — never loc() at creation time.
        // TransactionDetailSheet renders via tx.displayType which translates at display time.
        let txType_str  = selectedCategory == .debtPayment ? "tx.type.debt_payment"
                        : txType == .expense ? "tx.type.purchase" : "tx.type.income"

        let record = TxRecord(
            name: name.trimmingCharacters(in: .whitespaces),
            date: selectedDate, amount: finalAmount,
            type: txType_str,
            icon: String(name.prefix(2).uppercased()),
            iconBgHex: selectedCategory.iconBg,
            category: selectedCategory, currency: effectiveCurrency, notes: notes
            // subtype defaults to .normal at the model level — refund/transfer
            // are assigned later via TransactionDetailSheet's "Mark as ..."
            // actions, where the intent (this past tx came back / is a
            // transfer) makes sense in context.
        )
        vm.cards[selectedCardIndex].transactions.append(record)
        // Confirm the RESULT, not just "saved" — the amount and where it went.
        ActionFeedbackCenter.shared.transactionSaved(
            amount: record.amount, currency: record.currency,
            category: record.category,
            cardLabel: vm.cards[selectedCardIndex].pickerLabel)

        // Auto-reduce linked debt balance.
        // Convert the payment amount into the debt's currency before
        // subtracting. Without this, paying a USD-denominated debt with an
        // IDR card would subtract 750_000 (IDR) directly from a $1_000 USD
        // balance — wiping the debt incorrectly. We use effectiveAmount/
        // effectiveCurrency (i.e., what was actually written to the tx
        // record) so the deduction stays consistent with the saved tx.
        if selectedCategory == .debtPayment,
           let debtID = selectedDebtID,
           let debt = activeDebts.first(where: { $0.id == debtID }) {
            let paidInDebtCurrency = CurrencyManager.shared.convert(
                abs(effectiveAmount), from: effectiveCurrency, to: debt.currency
            )
            debt.currentBalance = max(debt.currentBalance - paidInDebtCurrency, 0)
            if debt.currentBalance == 0 {
                debt.isActive = false
                HapticManager.shared.rigidImpact()
            }
        }

        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}
