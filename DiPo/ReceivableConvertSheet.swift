import SwiftUI
import SwiftData

// MARK: - Make a row a loan, or mark it as money paid back
//
// Opened from a transaction's detail. The rules live in ReceivableConversion;
// this is only the asking: who, which claim, and — when the claim already
// exists — whether this row is already counted in it.

struct ReceivableConvertSheet: View {
    enum Mode: Identifiable {
        case lend, repay
        var id: Self { self }
    }

    let tx: TxRecord
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Receivable.createdAt, order: .reverse) private var receivables: [Receivable]
    @Query private var cards: [BankCard]

    @State private var attach = false
    @State private var personName = ""
    @State private var pickedID: UUID? = nil
    @State private var addToAmount = true
    @State private var didSetUp = false

    private var allTx: [TxRecord] { cards.flatMap(\.transactions) }
    private var open: [Receivable] { receivables.filter { !$0.isSettled } }
    private var picked: Receivable? { open.first { $0.id == pickedID } }
    private var rowCurrency: String {
        tx.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : tx.currency
    }

    private func money(_ v: Double, _ currency: String) -> String {
        CurrencyManager.shared.formatted(v, currency: currency)
    }
    /// The row's amount in the claim's currency.
    private func rowAmount(in r: Receivable) -> Double {
        CurrencyManager.shared.convert(abs(tx.amount), from: rowCurrency, to: r.currency)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        rowSummary
                        Text(loc(mode == .lend ? "loan.intro_lend" : "loan.intro_repay"))
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if mode == .lend {
                            lendForm
                        } else {
                            repayForm
                        }
                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 22).padding(.top, 8)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { apply() } label: {
                    Text(loc(mode == .lend ? "loan.confirm_lend" : "loan.confirm_repay"))
                        .font(.system(.callout, weight: .bold))
                        .foregroundStyle(canApply ? AppTheme.onVividFill : AppTheme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(canApply ? AppTheme.accentFill : AppTheme.cardMid,
                                    in: RoundedRectangle(cornerRadius: AppRadius.lg))
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(!canApply)
                .padding(.horizontal, 22).padding(.bottom, 10)
                .background(AppTheme.bg)
            }
            .navigationTitle(loc(mode == .lend ? "loan.title_lend" : "loan.title_repay"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.close")) { HapticManager.shared.tap(); dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .onAppear(perform: setUp)
        }
    }

    // MARK: Parts

    private var rowSummary: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tx.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(2)
                Text(tx.displayDate)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 8)
            Text((tx.amount < 0 ? "-" : "+") + money(abs(tx.amount), rowCurrency))
                .font(.system(.subheadline, weight: .bold))
                .foregroundStyle(tx.amount < 0 ? AppTheme.flowOut : AppTheme.flowIn)
                .monospacedDigit()
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    @ViewBuilder
    private var lendForm: some View {
        if !open.isEmpty {
            HStack(spacing: 6) {
                modeChip(loc("loan.new"), on: !attach) { attach = false }
                modeChip(loc("loan.existing"), on: attach) { attach = true }
            }
        }
        if attach && !open.isEmpty {
            FormSectionLabel(text: loc("loan.pick"))
            receivableList
            if let r = picked {
                FormSectionLabel(text: loc("loan.counted_q"))
                optionRow(loc("loan.included"),
                          String(format: loc("loan.included_sub"), money(r.amount, r.currency)),
                          on: !addToAmount) { addToAmount = false }
                optionRow(loc("loan.add"),
                          String(format: loc("loan.add_sub"), money(r.amount + rowAmount(in: r), r.currency)),
                          on: addToAmount) { addToAmount = true }
            }
        } else {
            FormSectionLabel(text: loc("loan.who"))
            TextField(loc("receivable.person_ph"), text: $personName)
                .font(.system(.body, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
    }

    @ViewBuilder
    private var repayForm: some View {
        if open.isEmpty {
            Label(loc("loan.none_open"), systemImage: "info.circle")
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            FormSectionLabel(text: loc("loan.pick_repay"))
            receivableList
            if let r = picked {
                let left = r.outstanding(from: allTx) - rowAmount(in: r)
                Group {
                    if left > 0.01 {
                        Text(String(format: loc("loan.after_left"), money(left, r.currency)))
                    } else if left < -0.5 {
                        Text(String(format: loc("loan.after_over"), money(-left, r.currency)))
                    } else {
                        Text(loc("loan.after_settled"))
                    }
                }
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var receivableList: some View {
        VStack(spacing: 8) {
            ForEach(open) { r in
                let on = r.id == pickedID
                Button {
                    HapticManager.shared.select()
                    pickedID = r.id
                    addToAmount = ReceivableConversion.addsToAmountByDefault(tx, receivable: r)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.personName)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(String(format: loc("loan.outstanding_of"),
                                        money(r.outstanding(from: allTx), r.currency),
                                        money(r.amount, r.currency)))
                                .font(.system(.caption))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(.title3))
                            .foregroundStyle(on ? AppTheme.accent : AppTheme.textSecondary.opacity(0.5))
                    }
                    .padding(14)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(on ? AppTheme.accent : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func modeChip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.select()
            action()
        } label: {
            Text(title)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(on ? AppTheme.onVividFill : AppTheme.textSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(on ? AppTheme.accentFill : AppTheme.cardMid, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func optionRow(_ title: String, _ sub: String, on: Bool,
                           action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.select()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(.body))
                    .foregroundStyle(on ? AppTheme.accent : AppTheme.textSecondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(sub)
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(.plain)
    }

    // MARK: Logic

    private func setUp() {
        guard !didSetUp else { return }
        didSetUp = true
        personName = ReceivableConversion.guessName(from: tx.name)
        if let match = ReceivableConversion.likelyMatch(for: tx.name, in: open) {
            pickedID = match.id
            attach = mode == .lend
            addToAmount = ReceivableConversion.addsToAmountByDefault(tx, receivable: match)
        } else if mode == .repay, open.count == 1 {
            pickedID = open.first?.id
        }
    }

    private var canApply: Bool {
        switch mode {
        case .lend:
            return attach && !open.isEmpty
                ? picked != nil
                : !personName.trimmingCharacters(in: .whitespaces).isEmpty
        case .repay:
            return picked != nil
        }
    }

    private func apply() {
        guard canApply else { return }
        switch mode {
        case .lend:
            if attach, let r = picked {
                ReceivableConversion.lendAttach(tx, to: r, addToAmount: addToAmount)
            } else {
                ReceivableConversion.lendNew(tx, personName: personName, context: context)
            }
        case .repay:
            guard let r = picked else { return }
            ReceivableConversion.repay(tx, to: r, allTx: allTx)
        }
        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}
