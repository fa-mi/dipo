import SwiftUI
import SwiftData

// MARK: - The review sheet
//
// Opens over whatever the user was doing, once, when there is something to
// review. Three gestures and one button: swipe a row away, tap it to correct
// it, submit the rest.

struct PendingInboxSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \PendingTransaction.capturedAt, order: .reverse) private var pending: [PendingTransaction]
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]

    @State private var editing: PendingTransaction?
    @State private var submitting = false

    /// Rows that cannot be submitted because nothing says which card they came
    /// from. Named rather than silently skipped — a submit that quietly leaves
    /// two rows behind looks like a bug.
    private var unassigned: [PendingTransaction] { pending.filter { $0.cardID == nil } }
    private var ready: [PendingTransaction] { pending.filter { $0.cardID != nil } }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                if pending.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(loc("pending.intro"))
                                .font(.system(.footnote))
                                .foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 22).padding(.top, 6)

                            VStack(spacing: 10) {
                                ForEach(pending) { item in
                                    SwipeToDeleteRow(
                                        onTap: { HapticManager.shared.tap(); editing = item },
                                        onDelete: { remove(item) }
                                    ) {
                                        row(item)
                                    }
                                }
                            }
                            .padding(.horizontal, 22)

                            if !unassigned.isEmpty {
                                Label(String(format: loc("pending.needs_card"), unassigned.count),
                                      systemImage: "creditcard.trianglebadge.exclamationmark")
                                    .font(.system(.caption))
                                    .foregroundStyle(AppTheme.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 22)
                            }

                            Spacer(minLength: 90)
                        }
                        .containerRelativeFrame(.horizontal)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { submitBar }
            .navigationTitle(loc("pending.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.close")) { HapticManager.shared.tap(); dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .sheet(item: $editing) { item in
                PendingRowEditor(item: item, cards: cards)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
                    .preferredColorScheme(appColorScheme())
            }
        }
    }

    // MARK: Row

    private func row(_ item: PendingTransaction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            rowLine(item)
            // A held bill says what it was matched against, or the two
            // gestures would mean nothing.
            if item.source == .recurring {
                Label(RecurringManualMatch.holdNote(for: item, context: context),
                      systemImage: "questionmark.circle.fill")
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: AppRadius.sm))
            }
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private func rowLine(_ item: PendingTransaction) -> some View {
        let card = cards.first { $0.id == item.cardID }
        return HStack(spacing: 12) {
            Image(systemName: item.category.icon)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(hex: item.category.iconBg), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name.isEmpty ? loc("pending.unnamed") : item.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: item.source.icon)
                        .font(.system(.caption2)).imageScale(.small)
                    Text(loc(item.source.labelKey))
                    Text("·")
                    Text(DateFormatterCache.styles(date: .medium, time: .short).string(from: item.date))
                }
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.85)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(CurrencyManager.shared.formatted(item.amount, currency: item.currency))
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(item.isExpense ? AppTheme.flowOut : AppTheme.flowIn)
                    .lineLimit(1).minimumScaleFactor(0.7)
                // The card is the field a reader most often has to fix, so it is
                // on the row rather than hidden behind a tap.
                Text(card?.pickerLabel ?? loc("pending.no_card"))
                    .font(.system(.caption2))
                    .foregroundStyle(card == nil ? AppTheme.orange : AppTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(.largeTitle)).foregroundStyle(AppTheme.textSecondary)
            Text(loc("pending.empty"))
                .font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var submitBar: some View {
        VStack(spacing: 0) {
            Button {
                submitAll()
            } label: {
                HStack(spacing: 10) {
                    if submitting { ProgressView().tint(AppTheme.onVividFill).scaleEffect(0.9) }
                    else { Image(systemName: "checkmark.circle.fill").font(.system(.body)) }
                    Text(ready.isEmpty ? loc("pending.nothing_to_submit")
                                       : String(format: loc("pending.submit"), ready.count))
                        .font(.system(.callout, weight: .bold))
                }
                .foregroundStyle(ready.isEmpty ? AppTheme.textSecondary : AppTheme.onVividFill)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(ready.isEmpty ? AppTheme.cardMid : AppTheme.accentFill,
                            in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(ready.isEmpty || submitting)
            .padding(.horizontal, 22).padding(.bottom, 10)
        }
        .background(AppTheme.bg)
    }

    // MARK: Actions

    private func remove(_ item: PendingTransaction) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            context.delete(item)
        }
        try? context.save()
        HapticManager.shared.tap()
    }

    private func submitAll() {
        submitting = true
        var committed = 0
        for item in ready where PendingInbox.commit(item, cards: cards, context: context) {
            committed += 1
        }
        try? context.save()
        submitting = false
        HapticManager.shared.success()
        // Only leave when nothing is left to decide. Rows without a card stay,
        // and so does the sheet, or the user would never learn they were skipped.
        if pending.isEmpty { dismiss() }
    }
}

// MARK: - Correcting one row

struct PendingRowEditor: View {
    @Bindable var item: PendingTransaction
    let cards: [BankCard]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var amountText = ""
    @State private var isExpense = true

    private var expenseCategories: [TxCategory] {
        [.shopping, .food, .travel, .bills, .transport, .health, .commitment, .debtPayment, .other]
    }
    private var incomeCategories: [TxCategory] {
        [.salary, .freelance, .business, .investment, .bonus, .gift, .incomeOther]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        IconField(label: loc("common.name"), icon: "textformat",
                                  placeholder: loc("tx.name_placeholder"), text: $item.name)

                        VStack(alignment: .leading, spacing: 8) {
                            FormSectionLabel(text: loc("common.amount"))
                            HStack(spacing: 10) {
                                directionChip(loc("tx.expense"), expense: true)
                                directionChip(loc("tx.income"), expense: false)
                            }
                            HStack(spacing: 8) {
                                Text(CurrencyManager.symbol(for: item.currency))
                                    .font(.system(.subheadline, weight: .bold))
                                    .foregroundStyle(AppTheme.textSecondary)
                                TextField("0", text: $amountText)
                                    .keyboardType(.decimalPad)
                                    .font(.system(.title3, weight: .bold))
                                    .foregroundStyle(AppTheme.textPrimary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            FormSectionLabel(text: loc("common.category"))
                            CategoryTilePicker(
                                categories: isExpense ? expenseCategories : incomeCategories,
                                selection: Binding(get: { item.category },
                                                   set: { item.category = $0 }))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            FormSectionLabel(text: loc("pending.which_card"))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(cards, id: \.id) { cardChip($0) }
                                }
                                .padding(.vertical, 3)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            FormSectionLabel(text: loc("tx.date_time"))
                            DateTimeFields(date: $item.date)
                        }

                        if item.source == .recurring {
                            // rawText is the matched row's id here, not words.
                            Label(RecurringManualMatch.holdNote(for: item, context: context),
                                  systemImage: "questionmark.circle.fill")
                                .font(.system(.footnote))
                                .foregroundStyle(AppTheme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppTheme.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: AppRadius.md))
                        } else if !item.rawText.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                FormSectionLabel(text: loc("pending.read_from"))
                                Text(item.rawText)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                            }
                        }

                        Spacer(minLength: 30)
                    }
                    .padding(.horizontal, 22).padding(.top, 10)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("pending.edit_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("common.done")) { save() }
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                }
            }
        }
        .onAppear {
            amountText = String(format: "%.0f", abs(item.amount))
            isExpense = item.isExpense
        }
    }

    private func directionChip(_ title: String, expense: Bool) -> some View {
        let on = isExpense == expense
        return Button {
            HapticManager.shared.select()
            withAnimation(.spring(response: 0.3)) { isExpense = expense }
            // Keep the category valid for the new direction.
            let list = expense ? expenseCategories : incomeCategories
            if !list.contains(item.category) { item.category = expense ? .shopping : .salary }
        } label: {
            Text(title)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(on ? AppTheme.onVividFill : AppTheme.textSecondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(on ? (expense ? AppTheme.redFill : AppTheme.accentFill) : AppTheme.cardDark,
                            in: Capsule())
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func cardChip(_ card: BankCard) -> some View {
        let on = item.cardID == card.id
        return Button {
            HapticManager.shared.tap()
            item.cardID = card.id
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Color(hex: card.gradientStart),
                                                  Color(hex: card.gradientEnd)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 34, height: 24)
                Text(card.pickerLabel)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(on ? AppTheme.textPrimary : AppTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(on ? AppTheme.accent : Color.clear, lineWidth: 2))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func save() {
        let typed = NumberInput.amount(amountText)
        let magnitude = NumberInput.isNumber(amountText) ? typed : abs(item.amount)
        item.amount = isExpense ? -magnitude : magnitude
        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}
