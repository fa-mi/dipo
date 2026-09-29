import SwiftUI
import SwiftData

// Moved out of UtilityViews.swift, unchanged.

// MARK: - Transaction Detail + Edit Sheet

struct TransactionDetailSheet: View {
    @Bindable var tx: TxRecord
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var editName = ""
    @State private var editAmount = ""
    @State private var editCurrency = CurrencyManager.shared.preferredCurrency
    @State private var editType: EditType = .expense
    @State private var editCategory: TxCategory = .other
    @State private var editDate = Date()
    @State private var editNotes = ""
    /// Non-nil while the delete confirmation is up. Holds the tx so the sheet
    /// is the same `DeleteTransactionSheet` the swipe gesture opens.
    @State private var pendingDelete: TxRecord? = nil
    
    /// History the rhythm is measured over: every transaction on this card, not
    /// just this one. Cadence is a property of a habit, not of a purchase.
    @Query private var allCards: [BankCard]
    private var detailHistory: [TxRecord] {
        allCards.first { $0.transactions.contains(where: { $0.id == tx.id }) }?.transactions ?? []
    }

    /// Built once when the sheet opens, not on every body evaluation — the
    /// model takes medians across the whole card history, which is a full pass
    /// and has no business running as a side effect of a redraw.
    @State private var cachedRhythm = SpendingRhythm(history: []) { _ in 0 }

    private func explanationKey(for v: SpendingRhythm.Verdict) -> String {
        switch v {
        case .episodicCategory: return "tx.rhythm_why_episodic"
        case .outlier:          return "tx.rhythm_why_outlier"
        case .dayToDay:         return "tx.rhythm_why_daily"
        case .userMarked:       return "tx.rhythm_why_daily"
        }
    }

    private func overrideChip(_ title: String, value: Bool?) -> some View {
        let on = tx.oneOffOverride == value
        return Button {
            HapticManager.shared.tap()
            tx.oneOffOverride = value
            try? context.save()
        } label: {
            Text(title)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(on ? AppTheme.onVividFill : AppTheme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(on ? AppTheme.accentFill : AppTheme.cardMid, in: Capsule())
        }
        .buttonStyle(ScaleButtonStyle())
    }

    /// Locale-aware short time formatter (e.g. "12:30 PM" / "12.30")
    static func shortTimeString(from date: Date) -> String {
        let df = DateFormatter()
        df.locale = LanguageManager.shared.currentLocale
        df.timeStyle = .short
        df.dateStyle = .none
        return df.string(from: date)
    }

    enum EditType: String, CaseIterable {
        case expense = "Expense"
        case income  = "Income"
        /// Used only as a solid fill (the type capsule, the Record button), so
        /// it takes the fill tokens. Reading `AppTheme.red` here is what
        /// dragged the light-mode button from salmon to a hard red when `red`
        /// was darkened for TEXT legibility — a change the fill never needed.
        var color: Color { self == .expense ? AppTheme.redFill : AppTheme.accentFill }
        /// Same glyphs as the create form's type picker.
        var icon: String { self == .expense ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }

        /// Localized label for the segmented picker. The rawValue stays English
        /// since it's used purely internally (Hashable for ForEach); it never
        /// reaches the UI.
        var localizedLabel: String {
            switch self {
            case .expense: return loc("tx.type.purchase")
            case .income:  return loc("tx.type.income")
            }
        }
    }

    private var formattedAmount: String {
        CurrencyManager.shared.formatted(abs(tx.amount), currency: tx.currency)
    }

    private var convertedLabel: String {
        let pref = CurrencyManager.shared.preferredCurrency
        let other = tx.currency == pref ? "USD" : pref
        let converted = CurrencyManager.shared.convert(abs(tx.amount), from: tx.currency, to: other)
        return "= \(CurrencyManager.shared.formatted(converted, currency: other))"
    }

    /// Categories valid for the current edit type. Mirrors AddTransactionSheet
    /// exactly so editing feels identical to creating: pick Income and you only
    /// see income categories, pick Expense and only expense ones — never the
    /// two mixed together.
    private var availableCategories: [TxCategory] {
        switch editType {
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
    
    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        if isEditing {
                            editForm
                        } else {
                            detailView
                        }
                    }
                    .padding(.top, 8)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(isEditing ? loc("tx.edit.title") : loc("tx.detail.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEditing ? loc("common.cancel") : loc("common.close")) {
                        if isEditing {
                            withAnimation { isEditing = false }
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundStyle(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    // While editing, Save lives at the bottom of the form, as it
                    // does when creating — not in two places at once.
                    if !isEditing {
                        Button {
                            loadEditState()
                            withAnimation { isEditing = true }
                        } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(AppTheme.accent)
                        }
.accessibilityLabel(loc("common.edit"))
                    }
                }
            }
        }
        .onAppear {
            cachedRhythm = SpendingRhythm(history: detailHistory) { t in
                CurrencyManager.shared.convert(
                    t.amount,
                    from: t.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : t.currency,
                    to: CurrencyManager.shared.preferredCurrency)
            }
        }
        .sheet(item: $pendingDelete) { pending in
            DeleteTransactionSheet(
                tx: pending,
                card: allCards.first { $0.transactions.contains(where: { $0.id == pending.id }) },
                onConfirm: {
                    pendingDelete = nil
                    dismiss()
                    // Delete once both sheets have gone: deleting first leaves the
                    // closing detail sheet re-rendering a detached model.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        deleteTransactionWithGoalRollback(pending, context: context)
                        try? context.save()
                        HapticManager.shared.success()
                    }
                },
                onCancel: { pendingDelete = nil })
            .preferredColorScheme(appColorScheme())
        }
        .trackScreen(.transactionDetail)
    }

    /// A short, stable handle for one transaction, taken from the id it already
    /// has. Printed on the ticket so a person can point at a row when they ask
    /// about it instead of describing "the coffee one, on Tuesday, I think".
    private var reference: String {
        "TRX-" + tx.id.uuidString.prefix(8)
    }

    /// One line of particulars. No rules between rows: on a ticket the columns
    /// do that work, and a divider every 30pt turns paper back into a table.
    private func ticketRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 7)
    }

    // MARK: Detail view

    var detailView: some View {
        VStack(spacing: 20) {
            // The transaction as the object it already is: one purchase, one
            // moment, one piece of paper. Everything the stack of cards showed
            // is still here — the same facts, printed rather than filed.
            TicketCard {
                VStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppRadius.lg)
                            .fill(tx.displayIconBg)
                            .frame(width: 64, height: 64)
                        Text(tx.icon)
                            .font(.system(size: tx.icon.count == 1 ? 24 : 30))
                            .foregroundStyle(.white)
                    }

                    // Subtype badge — appears above the amount when the tx has
                    // been marked as Refund or Transfer. Visual cue that this tx
                    // is treated specially in budget calculations (refund
                    // subtracts from bucket; transfer is ignored entirely).
                    if tx.txSubtype != .normal {
                        HStack(spacing: 5) {
                            Image(systemName: tx.txSubtype.icon)
                                .font(.system(.caption2, weight: .semibold)).imageScale(.small)
                            Text(tx.txSubtype.displayLabel)
                                .font(.system(.caption2, weight: .bold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(AppTheme.orange)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(AppTheme.orange.opacity(0.15), in: Capsule())
                        .fixedSize()
                    }

                    Text(tx.amount >= 0 ? "+\(formattedAmount)" : "-\(formattedAmount)")
                        .font(.system(.largeTitle, weight: .bold))
                        // The same money-in / money-out pair as Home's flow card.
                        .foregroundStyle(tx.amount >= 0 ? AppTheme.flowIn : AppTheme.flowOut)
                        .lineLimit(1).minimumScaleFactor(0.6)

                    Text(tx.name)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if tx.isFXConverted {
                        // Settled row: show what was declared and the rate applied
                        // on the charge day. This deliberately REPLACES the live
                        // conversion below — re-converting an amount that was
                        // already converted once would print a figure that
                        // contradicts the one actually posted to the balance.
                        VStack(spacing: 4) {
                            Text(String(format: loc("tx.fx_original"),
                                        CurrencyManager.shared.formatted(abs(tx.fxOriginalAmount),
                                                                         currency: tx.fxOriginalCurrency)))
                                .font(.system(.subheadline))
                                .foregroundStyle(AppTheme.textSecondary)
                            Text(String(format: loc("tx.fx_rate_used"),
                                        CurrencyManager.symbol(for: tx.fxOriginalCurrency),
                                        CurrencyManager.shared.formatted(tx.fxRate, currency: tx.currency)))
                                .font(.system(.caption2))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    } else {
                        Text(convertedLabel)
                            .font(.system(.subheadline))
                            .foregroundStyle(AppTheme.textSecondary)

                        if CurrencyManager.shared.isLoading {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.7).tint(AppTheme.textSecondary)
                                Text(loc("common.updating_rate")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                            }
                        } else if let updated = CurrencyManager.shared.lastUpdated {
                            Text(String(format: loc("common.rate_as_of"),
                                        CurrencyManager.shared.rateLabel,
                                        Self.shortTimeString(from: updated)))
                                .font(.system(.caption2))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }
            } particulars: {
                VStack(spacing: 0) {
                    ticketRow(loc("common.date"), tx.displayDate)
                    ticketRow(loc("common.category"), tx.category.displayLabel)
                    ticketRow(loc("common.type"), tx.displayType)
                    ticketRow(loc("common.currency"), tx.currency)
                    if !tx.notes.isEmpty {
                        ticketRow(loc("common.notes"), tx.displayNotes)
                    }
                    ticketRow(loc("tx.reference"), reference)

                    TicketBarcode(id: tx.id)
                        .padding(.top, 14)
                    Text(reference)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)

            // The engine's call on whether this is day-to-day spending, and a
            // way to disagree with it.
            //
            // Shown rather than hidden, because a number that quietly excludes
            // some of your spending is a number you cannot check. And the
            // correction is three-state on purpose: "automatic" has to remain
            // reachable, or the first tap is irreversible and people stop
            // tapping.
            if tx.amount < 0, tx.txSubtype != .transfer,
               !StatisticsView.fixedMonthlyCats.contains(tx.category) {
                let amount = abs(CurrencyManager.shared.convert(
                    tx.amount, from: tx.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : tx.currency,
                    to: CurrencyManager.shared.preferredCurrency))
                let auto = cachedRhythm.autoVerdict(for: tx, amount: amount)

                VStack(alignment: .leading, spacing: 10) {
                    Text(loc("tx.rhythm_title"))
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .tracking(0.6)

                    Text(loc(explanationKey(for: auto)))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        overrideChip(loc("tx.rhythm_auto"),   value: nil)
                        overrideChip(loc("tx.rhythm_daily"),  value: false)
                        overrideChip(loc("tx.rhythm_irreg"),  value: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .padding(.horizontal, 22)
            }

            // Refund/transfer tagging was removed — if a transaction was a
            // refund, the user simply deletes it (the money came back, so the
            // expense shouldn't exist). Transfers are still created/tagged by
            // the dedicated Transfer feature; they just don't expose a manual
            // tag/reset control here.

            // Delete button
            Button {
                HapticManager.shared.warning()
                pendingDelete = tx
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "trash").font(.system(.callout))
                    Text(loc("tx.delete")).font(.system(.subheadline, weight: .semibold))
                }
                .foregroundStyle(AppTheme.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(AppTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.md))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.red.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
    }

    // MARK: Edit form

    /// Built from the same parts as the create form — amount hero, icon
    /// fields, category tiles, split date and time, one primary button — so
    /// editing a transaction looks and behaves like making one.
    var editForm: some View {
        VStack(spacing: 20) {
            HStack(spacing: 0) {
                ForEach(EditType.allCases, id: \.self) { type in
                    Button {
                        HapticManager.shared.select()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { editType = type }
                        // Keep category valid for the new type — an expense
                        // category left selected after switching to Income (or
                        // vice-versa) would save a nonsensical pairing.
                        if !availableCategories.contains(editCategory) {
                            editCategory = type == .expense ? .shopping : .salary
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: type.icon).font(.system(.subheadline))
                            Text(type.localizedLabel).font(.system(.subheadline, weight: .semibold))
                        }
                        .foregroundStyle(editType == type ? AppTheme.onVividFill : AppTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background {
                            if editType == type {
                                Capsule().fill(type.color)
                            }
                        }
                    }
                }
            }
            .padding(4)
            .background(AppTheme.cardDark, in: Capsule())
            .padding(.horizontal, 22)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    // Currency is locked while editing. The stored amount is IN
                    // this currency, so changing it after the fact would
                    // silently rewrite what hits the card balance.
                    HStack(spacing: 6) {
                        Text(CurrencyManager.symbol(for: editCurrency))
                            .font(.system(.subheadline, weight: .bold))
                            .foregroundStyle(AppTheme.accent)
                        Text(editCurrency)
                            .font(.system(.footnote, weight: .medium))
                        Image(systemName: "lock.fill")
                            .font(.system(.caption2)).imageScale(.small)
                    }
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.md))

                    TextField("0", text: $editAmount)
                        .font(.system(.largeTitle, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .keyboardType(.decimalPad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))

                // Same single helper line as the create form: echo the typed
                // digits back formatted, so a missing zero is caught here.
                if let p = AmountInputHelper.preview(editAmount, currency: editCurrency) {
                    Text(p)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.horizontal, 22)

            IconField(label: loc("tx.name_label"),
                      icon: "textformat",
                      placeholder: loc("tx.name_placeholder"),
                      text: $editName)
                .padding(.horizontal, 22)

            VStack(alignment: .leading, spacing: 10) {
                FormSectionLabel(text: loc("common.category"))
                    .padding(.horizontal, 22)
                CategoryTilePicker(categories: availableCategories, selection: $editCategory)
            }

            VStack(alignment: .leading, spacing: 10) {
                FormSectionLabel(text: loc("tx.date_time"))
                DateTimeFields(date: $editDate)
            }
            .padding(.horizontal, 22)

            IconField(label: loc("tx.notes"),
                      icon: "text.alignleft",
                      placeholder: loc("tx.notes_placeholder"),
                      text: $editNotes,
                      optionalHint: loc("common.optional"))
                .padding(.horizontal, 22)

            Button { saveEdits() } label: {
                let canSave = NumberInput.amount(editAmount) > 0
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(.body))
                    Text(loc("common.save")).font(.system(.callout, weight: .bold))
                }
                .foregroundStyle(canSave ? AppTheme.onVividFill : AppTheme.textSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 17)
                .background(canSave ? editType.color : AppTheme.textSecondary.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(NumberInput.amount(editAmount) <= 0)
            .padding(.horizontal, 22)
            .padding(.top, 4)

            Spacer(minLength: 40)
        }
    }

    private func loadEditState() {
        editName     = tx.name
        // "20000", not "20000.0" — the hero field shows this at 34pt.
        let a = abs(tx.amount)
        editAmount   = NumberInput.text(a)
        editCurrency = tx.currency
        editType     = tx.amount >= 0 ? .income : .expense
        editCategory = tx.category
        editDate     = tx.date
        editNotes    = tx.notes
    }

    private func saveEdits() {
        let amt = NumberInput.amount(editAmount)
        guard amt > 0 else { return }
        tx.name      = editName.trimmingCharacters(in: .whitespaces)
        tx.amount    = editType == .expense ? -abs(amt) : abs(amt)
        tx.currency  = editCurrency
        tx.category  = editCategory
        tx.iconBgHex = editCategory.iconBg
        tx.date      = editDate
        tx.notes     = editNotes
        tx.type      = editType == .expense ? "tx.type.purchase" : "tx.type.income"
        try? context.save()
        HapticManager.shared.success()
        withAnimation { isEditing = false }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(value).font(.system(.subheadline, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}
