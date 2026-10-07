import SwiftUI

// MARK: - Confirm what DiPo understood
//
// Ask DiPo turns "kopi 25rb" into a transaction, but a misheard word or a
// guessed category should never land in the ledger unseen. Tapping "Add" on
// DiPo's card opens this sheet: amount, money in or out, name, category,
// date, the card it goes to, and a note — all as DiPo read them, all
// editable — and only "Save" writes anything.
//
// The card is chosen here, for this transaction, instead of once for the
// whole chat in a bar at the top that most people never looked at.

struct AIConfirmTxSheet: View {
    let tx: AIParsedTx
    let cards: [BankCard]
    /// The card used last time in this chat, so a run of entries stays put.
    let preferredCardID: UUID?
    var onSave: (AIParsedTx, BankCard) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amountText: String
    @State private var isExpense: Bool
    @State private var name: String
    @State private var category: TxCategory
    @State private var date: Date
    @State private var notes: String
    @State private var cardID: UUID?
    @FocusState private var focus: Field?

    private enum Field { case amount, name, notes }

    init(tx: AIParsedTx, cards: [BankCard], preferredCardID: UUID?, onSave: @escaping (AIParsedTx, BankCard) -> Void) {
        self.tx = tx
        self.cards = cards
        self.preferredCardID = preferredCardID
        self.onSave = onSave
        _amountText = State(initialValue: Self.plain(tx.amount))
        _isExpense = State(initialValue: tx.isExpense)
        _name = State(initialValue: tx.name)
        _category = State(initialValue: tx.category)
        _date = State(initialValue: tx.date)
        _notes = State(initialValue: tx.notes)
        _cardID = State(initialValue: preferredCardID.flatMap { id in cards.first { $0.id == id }?.id } ?? cards.first?.id)
    }

    private var amount: Double { NumberInput.amount(amountText) }
    private var card: BankCard? { cards.first { $0.id == cardID } }
    private var canSave: Bool {
        amount > 0 && !name.trimmingCharacters(in: .whitespaces).isEmpty && card != nil
    }

    /// Categories that fit the direction: spending ones for money out,
    /// income ones for money in.
    private var categories: [TxCategory] {
        let income: [TxCategory] = [.salary, .freelance, .business, .investment, .bonus, .gift, .incomeOther]
        return isExpense ? TxCategory.allCases.filter { !income.contains($0) } : income
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(loc("ai.confirm.intro"))
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // Amount and direction
                        VStack(spacing: 12) {
                            Picker("", selection: $isExpense) {
                                Text(loc("ai.confirm.out")).tag(true)
                                Text(loc("ai.confirm.in")).tag(false)
                            }
                            .pickerStyle(.segmented)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(tx.currency.isEmpty ? "Rp" : CurrencyManager.symbol(for: tx.currency))
                                    .font(.system(.title3, weight: .semibold))
                                    .foregroundStyle(AppTheme.textSecondary)
                                TextField("0", text: $amountText)
                                    .keyboardType(.decimalPad)
                                    .focused($focus, equals: .amount)
                                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(isExpense ? AppTheme.red : AppTheme.accent)
                            }
                        }
                        .padding(16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))

                        // Name, category, date
                        VStack(spacing: 0) {
                            row(loc("ai.confirm.name")) {
                                TextField(loc("ai.confirm.name"), text: $name)
                                    .focused($focus, equals: .name)
                                    .multilineTextAlignment(.trailing)
                            }
                            Divider().overlay(AppTheme.cardMid)
                            row(loc("ai.confirm.category")) {
                                Menu {
                                    ForEach(categories, id: \.self) { c in
                                        Button { category = c } label: { Label(c.displayLabel, systemImage: c.icon) }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: category.icon).foregroundStyle(category.color)
                                        Text(category.displayLabel).foregroundStyle(AppTheme.textPrimary)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                            }
                            Divider().overlay(AppTheme.cardMid)
                            row(loc("ai.confirm.date")) {
                                DatePicker("", selection: $date, in: ...Date.now.addingTimeInterval(86_400 * 365),
                                           displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))

                        // The card
                        VStack(alignment: .leading, spacing: 8) {
                            Text(loc("ai.confirm.card"))
                                .font(.system(.footnote, weight: .semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                            ForEach(cards) { c in
                                Button {
                                    HapticManager.shared.tap()
                                    cardID = c.id
                                } label: {
                                    CardListRow(card: c, selected: cardID == c.id, showsRadio: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Note
                        VStack(alignment: .leading, spacing: 8) {
                            Text(loc("ai.confirm.notes"))
                                .font(.system(.footnote, weight: .semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                            TextField(loc("ai.confirm.notes_placeholder"), text: $notes, axis: .vertical)
                                .focused($focus, equals: .notes)
                                .lineLimit(1...3)
                                .padding(14)
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 30)
                    .containerRelativeFrame(.horizontal)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(loc("ai.confirm.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("ai.confirm.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("ai.confirm.save")) { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
        }
        .onChange(of: isExpense) { _, _ in
            if !categories.contains(category) { category = categories.first ?? .other }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(.subheadline))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer(minLength: 8)
            content()
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
        }
        .frame(minHeight: 50)
    }

    private func save() {
        guard canSave, let card else { return }
        let edited = AIParsedTx(name: name.trimmingCharacters(in: .whitespaces), amount: amount, isExpense: isExpense,
                                category: category, currency: tx.currency, date: date,
                                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
        onSave(edited, card)
        dismiss()
    }

    /// "25000" rather than "25000.0", so the field reads like money.
    private static func plain(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(v)
    }
}
