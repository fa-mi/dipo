import SwiftUI
import SwiftData

// MARK: - Receivables (Piutang)
//
// DiPo tracked only debts the user OWES. The other direction — money lent to
// someone else — was invisible, which quietly understated net worth: the cash
// left the account and nothing recorded that it was coming back.
//
// Money modelling, which is the part that has to be right:
//
//   • Lending is NOT spending. The rupiah moved from an account into a claim;
//     total wealth is unchanged. So the outflow is recorded with subtype
//     `.transfer`, which DiPo already defines as "shouldn't count as income OR
//     expense for budgeting math". Booking it as an expense would make a month
//     where you helped a friend look like a month you overspent.
//
//   • Repayment is likewise not income. Same subtype, opposite sign.
//
//   • The outstanding balance counts toward net worth as an asset, mirroring
//     how DebtRecord counts against it.
@Model
final class Receivable {
    var id: UUID
    /// Who owes the money. Not a contact reference — DiPo asks for no address
    /// book permission and a typed name is enough to answer "who owes me".
    var personName: String
    var amount: Double
    var currency: String
    var lentAt: Date
    /// Optional soft deadline. Zero-date means "no date agreed", which is the
    /// honest default for lending between friends.
    var dueDate: Date?
    var notes: String
    var isSettled: Bool
    var createdAt: Date

    init(personName: String, amount: Double,
         currency: String = CurrencyManager.shared.preferredCurrency,
         lentAt: Date = .now, dueDate: Date? = nil, notes: String = "") {
        self.id = UUID()
        self.personName = personName
        self.amount = amount
        self.currency = currency
        self.lentAt = lentAt
        self.dueDate = dueDate
        self.notes = notes
        self.isSettled = false
        self.createdAt = .now
    }
}

// MARK: - Balance math
//
// Repayments live as linked transactions rather than a stored counter, for the
// same reason DebtRecord moved that way: deleting the transaction must undo the
// repayment. A stored number silently drifts out of step with the ledger.
extension Receivable {

    /// Sum of repayments recorded against this receivable, in its own currency.
    func repaidAmount(from transactions: [TxRecord]) -> Double {
        let key = id.uuidString
        var total: Double = 0
        for tx in transactions where tx.linkedReceivableID == key {
            // Repayments are positive (money coming back in).
            total += CurrencyManager.shared.convert(abs(tx.amount),
                                                    from: tx.currency.isEmpty ? currency : tx.currency,
                                                    to: currency)
        }
        return total
    }

    func outstanding(from transactions: [TxRecord]) -> Double {
        max(amount - repaidAmount(from: transactions), 0)
    }

    func progress(from transactions: [TxRecord]) -> Double {
        guard amount > 0 else { return 1 }
        return min(repaidAmount(from: transactions) / amount, 1)
    }

    /// What this claim contributes to net worth. A settled receivable
    /// contributes nothing — the money is back in an account and counting both
    /// would double it.
    func netWorthContribution(from transactions: [TxRecord]) -> Double {
        isSettled ? 0 : outstanding(from: transactions)
    }

    var isOverdue: Bool {
        guard !isSettled, let due = dueDate else { return false }
        return Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: .now)
    }
}

// MARK: - View Model

@Observable
final class ReceivableViewModel {
    var showAddSheet = false
    var editing: Receivable? = nil
    var formName = ""
    var formAmount = ""
    var formCurrency = CurrencyManager.shared.preferredCurrency
    var formNotes = ""
    var formHasDueDate = false
    var formDueDate = Calendar.current.safeDate(byAdding: .month, value: 1, to: .now)
    var formCardID: UUID? = nil
    /// Whether to post the cash outflow. Off when the user lent cash that DiPo
    /// never tracked in the first place — forcing a transaction then would
    /// invent a withdrawal that never happened.
    var formRecordOutflow = true
    var formError: String? = nil

    var currencies: [String] { CurrencyManager.supportedCurrencies.map(\.code) }

    func resetForm() {
        formName = ""; formAmount = ""; formNotes = ""
        formCurrency = CurrencyManager.shared.preferredCurrency
        formHasDueDate = false
        formDueDate = Calendar.current.safeDate(byAdding: .month, value: 1, to: .now)
        formCardID = nil; formRecordOutflow = true; formError = nil
        editing = nil
    }

    func loadForEdit(_ r: Receivable) {
        formName = r.personName
        formAmount = String(r.amount)
        formCurrency = r.currency
        formNotes = r.notes
        formHasDueDate = r.dueDate != nil
        formDueDate = r.dueDate ?? .now
        // Editing never re-posts the outflow — that transaction already exists.
        formRecordOutflow = false
        editing = r
        showAddSheet = true
    }

    func validate() -> Bool {
        guard !formName.trimmingCharacters(in: .whitespaces).isEmpty else {
            formError = loc("receivable.error_name"); return false
        }
        guard let a = Double(formAmount), a > 0 else {
            formError = loc("receivable.error_amount"); return false
        }
        formError = nil
        return true
    }
}

// MARK: - Main View

struct ReceivablesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Receivable.createdAt, order: .reverse) private var receivables: [Receivable]
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @State private var vm = ReceivableViewModel()
    @State private var repaying: Receivable? = nil
    @State private var appeared = false
    /// True when shown as a segment inside ObligationsView, which already owns
    /// the navigation chrome. A nested NavigationStack there would give the
    /// screen two title bars and two Done buttons.
    var embedded: Bool = false

    private var allTx: [TxRecord] { cards.flatMap(\.transactions) }
    private var outstandingList: [Receivable] { receivables.filter { !$0.isSettled } }
    private var settledList: [Receivable] { receivables.filter(\.isSettled) }

    private var totalOutstanding: Double {
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        return outstandingList.reduce(0.0) {
            $0 + cm.convert($1.outstanding(from: allTx), from: $1.currency, to: pref)
        }
    }

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack {
                content
                    .navigationTitle(loc("receivable.nav"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(AppTheme.bg, for: .navigationBar)
                    .doneToolbar { dismiss() }
            }
        }
    }

    private var content: some View {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        // The hub already shows the obligation totals; a second
                        // summary directly beneath it would just repeat itself.
                        if !embedded && !outstandingList.isEmpty { summaryCard }
                        addButton
                        if receivables.isEmpty {
                            emptyState
                        } else {
                            VStack(spacing: 12) {
                                ForEach(outstandingList) { r in row(r) }
                            }
                            .padding(.horizontal, 22)

                            if !settledList.isEmpty {
                                Text(loc("receivable.settled_section"))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 22).padding(.top, 8)
                                VStack(spacing: 12) {
                                    ForEach(settledList) { r in row(r) }
                                }
                                .padding(.horizontal, 22)
                            }
                        }
                        Spacer(minLength: 40)
                    }
                    .padding(.top, 12)
                }
            }
            .onAppear { withAnimation(.spring(response: 0.5)) { appeared = true } }
            .sheet(isPresented: $vm.showAddSheet, onDismiss: { vm.resetForm() }) {
                ReceivableFormSheet(vm: vm, cards: cards, context: context)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
            }
            .sheet(item: $repaying) { r in
                RepaymentSheet(receivable: r, cards: cards, allTx: allTx, context: context)
                    .presentationDetents([.height(460)])
                    .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
            }
    }

    private var summaryCard: some View {
        VStack(spacing: 6) {
            Text(loc("receivable.total_outstanding"))
                .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
            Text(CurrencyManager.shared.formatted(totalOutstanding,
                                                  currency: CurrencyManager.shared.preferredCurrency))
                .font(.system(size: 30, weight: .bold)).foregroundStyle(AppTheme.accent)
            Text(String(format: loc("receivable.people_count"), outstandingList.count))
                .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
    }

    private var addButton: some View {
        Button {
            HapticManager.shared.tap()
            vm.resetForm()
            vm.formCardID = cards.first?.id
            vm.showAddSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").font(.system(size: 14))
                Text(loc("receivable.add")).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(AppTheme.accent)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(ScaleButtonStyle())
        .padding(.horizontal, 22)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 34)).foregroundStyle(AppTheme.textSecondary.opacity(0.5))
            Text(loc("receivable.empty_title"))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
            Text(loc("receivable.empty_sub"))
                .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .padding(.top, 40)
    }

    private func row(_ r: Receivable) -> some View {
        let repaid = r.repaidAmount(from: allTx)
        let left = r.outstanding(from: allTx)
        let pct = r.progress(from: allTx)
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill((r.isSettled ? AppTheme.accent : AppTheme.blue).opacity(0.15))
                        .frame(width: 40, height: 40)
                    Text(String(r.personName.prefix(1).uppercased()))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(r.isSettled ? AppTheme.accent : AppTheme.blue)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(r.personName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                        if r.isOverdue {
                            Text(loc("receivable.overdue"))
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(AppTheme.red)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(AppTheme.red.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(r.isSettled
                         ? loc("receivable.settled")
                         : String(format: loc("receivable.of_total"),
                                  CurrencyManager.shared.formatted(repaid, currency: r.currency),
                                  CurrencyManager.shared.formatted(r.amount, currency: r.currency)))
                        .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Text(CurrencyManager.shared.formatted(left, currency: r.currency))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(r.isSettled ? AppTheme.textSecondary : AppTheme.textPrimary)
            }

            if !r.isSettled {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.cardMid).frame(height: 5)
                        Capsule().fill(AppTheme.accent).frame(width: geo.size.width * pct, height: 5)
                    }
                }
                .frame(height: 5)

                HStack(spacing: 8) {
                    Button {
                        HapticManager.shared.tap(); repaying = r
                    } label: {
                        Text(loc("receivable.record_repayment"))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.accent)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    Button {
                        HapticManager.shared.success()
                        r.isSettled = true
                        try? context.save()
                    } label: {
                        Text(loc("receivable.mark_settled"))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .contextMenu {
            Button { vm.loadForEdit(r) } label: { Label(loc("action.edit"), systemImage: "pencil") }
            if r.isSettled {
                Button { r.isSettled = false; try? context.save() } label: {
                    Label(loc("receivable.reopen"), systemImage: "arrow.uturn.backward")
                }
            }
            Button(role: .destructive) {
                context.delete(r); try? context.save()
            } label: { Label(loc("action.delete"), systemImage: "trash") }
        }
    }
}

// MARK: - Add / Edit Form

struct ReceivableFormSheet: View {
    @Bindable var vm: ReceivableViewModel
    let cards: [BankCard]
    let context: ModelContext
    @Environment(\.dismiss) private var dismiss

    private var isEditing: Bool { vm.editing != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        SheetField(label: loc("receivable.person"),
                                   placeholder: loc("receivable.person_ph"),
                                   text: $vm.formName)

                        VStack(spacing: 8) {
                            Text(loc("receivable.amount")).font(.system(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            HStack(spacing: 10) {
                                Menu {
                                    ForEach(vm.currencies, id: \.self) { c in
                                        Button(c) { HapticManager.shared.tap(); vm.formCurrency = c }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(vm.formCurrency).font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 14)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                }
                                TextField("0", text: $vm.formAmount)
                                    .font(.system(size: 22, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                    .keyboardType(.decimalPad)
                                    .padding(.horizontal, 16).padding(.vertical, 14)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                            }
                            .padding(.horizontal, 22)
                        }

                        // Optional deadline — lending between friends usually
                        // has none, and a forced date would be fiction.
                        VStack(spacing: 10) {
                            Toggle(isOn: $vm.formHasDueDate) {
                                Text(loc("receivable.set_due")).font(.system(size: 14))
                                    .foregroundStyle(AppTheme.textPrimary)
                            }
                            .tint(AppTheme.accent)
                            if vm.formHasDueDate {
                                DatePicker("", selection: $vm.formDueDate, displayedComponents: .date)
                                    .datePickerStyle(.compact).labelsHidden().tint(AppTheme.accent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 22)

                        if !isEditing {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: $vm.formRecordOutflow) {
                                    Text(loc("receivable.record_outflow")).font(.system(size: 14))
                                        .foregroundStyle(AppTheme.textPrimary)
                                }
                                .tint(AppTheme.accent)
                                Text(loc("receivable.record_outflow_hint"))
                                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if vm.formRecordOutflow {
                                    CardPickerSection(selectedCardID: $vm.formCardID,
                                                      titleKey: "receivable.from_card")
                                }
                            }
                            .padding(.horizontal, 22)
                        }

                        SheetField(label: loc("receivable.notes"),
                                   placeholder: loc("receivable.notes_ph"),
                                   text: $vm.formNotes)

                        if let err = vm.formError {
                            Text(err).font(.system(size: 12)).foregroundStyle(AppTheme.red)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                        }

                        Button {
                            guard vm.validate() else { HapticManager.shared.warning(); return }
                            save()
                        } label: {
                            Text(loc("action.save")).font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .padding(.horizontal, 22)
                        Spacer(minLength: 30)
                    }
                    .padding(.top, 14)
                }
            }
            .navigationTitle(loc(isEditing ? "receivable.edit_title" : "receivable.add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
    }

    private func save() {
        let amount = Double(vm.formAmount) ?? 0
        let name = vm.formName.trimmingCharacters(in: .whitespaces)

        if let r = vm.editing {
            r.personName = name
            r.amount = amount
            r.currency = vm.formCurrency
            r.notes = vm.formNotes
            r.dueDate = vm.formHasDueDate ? vm.formDueDate : nil
        } else {
            let r = Receivable(personName: name, amount: amount, currency: vm.formCurrency,
                               dueDate: vm.formHasDueDate ? vm.formDueDate : nil,
                               notes: vm.formNotes)
            context.insert(r)

            // The cash actually left an account, so record it — but as a
            // TRANSFER, not an expense. Lending doesn't reduce wealth, it
            // changes its shape, and booking it as spending would make a
            // generous month look like an undisciplined one.
            if vm.formRecordOutflow,
               let cardID = vm.formCardID,
               let card = cards.first(where: { $0.id == cardID }) {
                let tx = TxRecord(
                    name: String(format: loc("receivable.tx_lent"), name),
                    date: .now, amount: -abs(amount),
                    type: "tx.type.purchase",
                    icon: String(name.prefix(2).uppercased()),
                    iconBgHex: TxCategory.other.iconBg,
                    category: .other, currency: vm.formCurrency,
                    notes: "tx.note.receivable_lent",
                    subtype: .transfer
                )
                tx.linkedReceivableID = r.id.uuidString
                context.insert(tx)
                card.transactions.append(tx)
            }
        }
        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}

// MARK: - Repayment

struct RepaymentSheet: View {
    let receivable: Receivable
    let cards: [BankCard]
    let allTx: [TxRecord]
    let context: ModelContext
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var cardID: UUID? = nil

    private var remaining: Double { receivable.outstanding(from: allTx) }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        VStack(spacing: 4) {
                            Text(loc("receivable.remaining"))
                                .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                            Text(CurrencyManager.shared.formatted(remaining, currency: receivable.currency))
                                .font(.system(size: 26, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                        }
                        .padding(.top, 8)

                        TextField("0", text: $amountText)
                            .font(.system(size: 22, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                            .keyboardType(.decimalPad).multilineTextAlignment(.center)
                            .padding(.vertical, 14)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 22)

                        Button {
                            amountText = String(remaining)
                        } label: {
                            Text(loc("receivable.pay_full")).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppTheme.accent)
                        }
                        .buttonStyle(.plain)

                        CardPickerSection(selectedCardID: $cardID, titleKey: "receivable.to_card")
                            .padding(.horizontal, 22)

                        Button {
                            record()
                        } label: {
                            Text(loc("receivable.record_repayment"))
                                .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
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
            .navigationTitle(receivable.personName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
            .onAppear { if cardID == nil { cardID = cards.first?.id } }
        }
    }

    private var canSave: Bool {
        guard let a = Double(amountText), a > 0, cardID != nil else { return false }
        return true
    }

    private func record() {
        guard let amount = Double(amountText), amount > 0,
              let id = cardID, let card = cards.first(where: { $0.id == id }) else { return }

        // Money returning is not new income — same `.transfer` reasoning as the
        // outflow. Counting it as income would inflate every earnings figure.
        let tx = TxRecord(
            name: String(format: loc("receivable.tx_repaid"), receivable.personName),
            date: .now, amount: abs(amount),
            type: "tx.type.income",
            icon: String(receivable.personName.prefix(2).uppercased()),
            iconBgHex: TxCategory.incomeOther.iconBg,
            category: .incomeOther, currency: receivable.currency,
            notes: "tx.note.receivable_repaid",
            subtype: .transfer
        )
        tx.linkedReceivableID = receivable.id.uuidString
        context.insert(tx)
        card.transactions.append(tx)

        // Close it out automatically when the balance reaches zero, so the user
        // isn't left with a settled claim still listed as outstanding.
        if amount >= remaining - 0.01 { receivable.isSettled = true }

        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}
