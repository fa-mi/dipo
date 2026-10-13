import SwiftUI
import SwiftData
import FirebaseAuth

// MARK: - One shared account
//
// The card, three actions (money in, money out, deposit from my own card), the
// month's budget, and every entry with who wrote it. Amounts out are plain
// text and amounts in are green, as in the person's own history: an expense
// is not a warning.

struct JointAccountDetailView: View {
    let accountID: String
    @Bindable var vm: AppViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var service = JointAccountService.shared
    @State private var entry: EntryRoute?
    @State private var showDeposit = false
    @State private var showSettings = false
    @State private var deleting: JointTx?
    @State private var seen = false
    /// Still no account after a few seconds: say so, instead of a spinner
    /// that never stops.
    @State private var slow = false

    struct EntryRoute: Identifiable {
        let kind: JointTx.Kind
        var id: String { kind.rawValue }
    }

    private var account: JointAccount? { service.account(accountID) }
    private var entries: [JointTx] { service.history[accountID] ?? [] }
    private var me: String? { Auth.auth().currentUser?.uid }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                if let account {
                    content(account)
                } else if slow {
                    waiting
                } else {
                    ProgressView().tint(AppTheme.accent)
                }
            }
            .navigationTitle(account.map { "\($0.emoji) \($0.name)" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.close")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        HapticManager.shared.tap()
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill").foregroundStyle(AppTheme.accent)
                    }
                    .accessibilityLabel(loc("joint.settings.title"))
                }
            }
        }
        // start() is idempotent; it only listens again when Firestore had
        // ended the listener (no signal, or refused before the rules were up).
        .onAppear { service.start(); service.watchHistory(accountID) }
        .onDisappear { service.stopHistory(accountID) }
        // Closed by the owner, or I was taken off it: nothing left to show.
        .onChange(of: account == nil) { _, gone in
            if !gone { seen = true } else if seen { dismiss() }
        }
        .task(id: slow) {
            if account != nil { seen = true; return }
            guard !slow else { return }
            try? await Task.sleep(for: .seconds(8))
            if account == nil { withAnimation { slow = true } }
        }
        .sheet(item: $entry) { route in
            if let account {
                JointEntrySheet(account: account, kind: route.kind)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
                    .preferredColorScheme(appColorScheme())
            }
        }
        .sheet(isPresented: $showDeposit) {
            if let account {
                JointDepositSheet(account: account, vm: vm)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
                    .preferredColorScheme(appColorScheme())
            }
        }
        .sheet(isPresented: $showSettings) {
            JointSettingsSheet(accountID: accountID)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .confirmationDialog(loc("joint.entry.delete_title"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible,
                            presenting: deleting) { tx in
            Button(loc("joint.entry.delete"), role: .destructive) {
                if let account { service.delete(tx, from: account) }
                HapticManager.shared.warning()
            }
            Button(loc("common.cancel"), role: .cancel) {}
        } message: { tx in
            Text(loc(tx.kind == .deposit ? "joint.entry.delete_deposit_msg" : "joint.entry.delete_msg"))
        }
        .trackScreen(.jointAccount)
    }

    /// The account isn't here yet: no connection, or the server turned it down.
    private var waiting: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(AppTheme.textSecondary)
            Text(loc("joint.waiting.title"))
                .font(.system(.headline))
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text(service.failure ?? loc("joint.waiting.body"))
                .font(.system(.subheadline))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            JointPrimaryButton(title: loc("joint.waiting.retry")) {
                service.failure = nil
                service.retry()
                withAnimation { slow = false }
            }
            .frame(maxWidth: 260)
        }
        .padding(28)
    }

    private func content(_ account: JointAccount) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                JointAccountCard(account: account,
                                 members: service.members[account.id] ?? [],
                                 memberLine: service.memberLine(account),
                                 spent: service.spentThisMonth(account.id),
                                 month: service.month)

                if let failure = service.failure {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppTheme.orange)
                        Text(failure)
                            .font(.system(.footnote, weight: .medium))
                            .foregroundStyle(AppTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { service.failure = nil } label: {
                            Image(systemName: "xmark").font(.system(.caption, weight: .bold))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .accessibilityLabel(loc("common.close"))
                    }
                    .padding(14)
                    .background(AppTheme.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: AppRadius.md))
                }

                if account.isActive {
                    HStack(spacing: 10) {
                        actionTile(icon: "arrow.down.left", title: loc("joint.action.in"), tint: AppTheme.accentFill) {
                            entry = EntryRoute(kind: .income)
                        }
                        actionTile(icon: "arrow.up.right", title: loc("joint.action.out"), tint: AppTheme.redFill) {
                            entry = EntryRoute(kind: .spend)
                        }
                        actionTile(icon: "arrow.left.arrow.right", title: loc("joint.action.deposit"), tint: AppTheme.blue) {
                            showDeposit = true
                        }
                    }
                } else {
                    JointInfo(icon: "hourglass", text: loc("joint.closing_note"), tint: AppTheme.orange)
                }

                budgetCard(account)
                history(account)
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .containerRelativeFrame(.horizontal)
        }
    }

    private func actionTile(icon: String, title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.tap()
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(.headline, weight: .bold))
                    .foregroundStyle(AppTheme.onVividFill)
                    .frame(width: 42, height: 42)
                    .background(tint, in: Circle())
                Text(title)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    // MARK: Budget

    @ViewBuilder
    private func budgetCard(_ account: JointAccount) -> some View {
        if account.monthlyBudget > 0 {
            let spent = service.spentThisMonth(account.id)
            let ratio = JointBudget.ratio(spent: spent, budget: account.monthlyBudget)
            let left = account.monthlyBudget - spent
            let tint = ratio >= 1 ? AppTheme.red : ratio >= 0.8 ? AppTheme.orange : AppTheme.accent
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: loc("joint.budget.title"), JointAccountCard.monthName(service.month)))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer(minLength: 8)
                    Text(String(format: loc(left >= 0 ? "joint.budget.left" : "joint.budget.over"),
                                JointMoney.text(left, currency: account.currency)))
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(left >= 0 ? AppTheme.textSecondary : tint)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.accentTrack)
                        Capsule().fill(tint).frame(width: g.size.width * min(ratio, 1))
                    }
                }
                .frame(height: 8)
                Text(String(format: loc("joint.budget.of"),
                            JointMoney.text(spent, currency: account.currency),
                            JointMoney.text(account.monthlyBudget, currency: account.currency),
                            Int((ratio * 100).rounded())))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(16)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        } else if account.isOwner(me) && account.isActive {
            Button {
                HapticManager.shared.tap()
                showSettings = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chart.pie.fill").foregroundStyle(AppTheme.accent)
                    Text(loc("joint.budget.set_cta"))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(16)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
            }
            .buttonStyle(ScaleButtonStyle())
        }
    }

    // MARK: History

    private struct Day: Identifiable {
        let id: Date
        let items: [JointTx]
    }

    private func days(_ entries: [JointTx]) -> [Day] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: entries) { cal.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            Day(id: day, items: (grouped[day] ?? []).sorted { $0.date > $1.date })
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return loc("joint.today") }
        if cal.isDateInYesterday(day) { return loc("joint.yesterday") }
        let f = DateFormatter()
        f.locale = LanguageManager.shared.currentLocale
        f.setLocalizedDateFormatFromTemplate(cal.isDate(day, equalTo: Date(), toGranularity: .year) ? "EEEEdMMMM" : "dMMMMyyyy")
        return f.string(from: day)
    }

    @ViewBuilder
    private func history(_ account: JointAccount) -> some View {
        if entries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 30))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(loc("joint.empty"))
                    .font(.system(.subheadline))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(28)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(days(entries)) { group in
                    Text(dayTitle(group.id))
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.top, 14).padding(.bottom, 4)
                    ForEach(group.items) { tx in
                        JointTxRow(tx: tx, currency: account.currency,
                                   author: service.name(of: tx.uid, in: account.id),
                                   mine: tx.uid == me)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .contextMenu {
                                if service.canDelete(tx, in: account) {
                                    Button(role: .destructive) { deleting = tx } label: {
                                        Label(loc("joint.entry.delete"), systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
                Text(loc("joint.entry.hold_hint"))
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.top, 10)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
    }
}

struct JointTxRow: View {
    let tx: JointTx
    let currency: String
    let author: String
    let mine: Bool

    private var icon: String {
        tx.kind == .deposit ? "arrow.left.arrow.right" : (tx.txCategory ?? .other).icon
    }
    private var tint: Color {
        tx.kind == .deposit ? AppTheme.blue : Color(hex: (tx.txCategory ?? .other).iconBg)
    }
    private var categoryLabel: String {
        tx.kind == .deposit ? loc("joint.entry.deposit_kind") : (tx.txCategory ?? .other).displayLabel
    }
    private var title: String {
        if tx.kind == .deposit {
            return tx.note.isEmpty ? loc("joint.entry.deposit_kind")
                                   : String(format: loc("joint.entry.deposit_from"), tx.note)
        }
        return tx.note.isEmpty ? categoryLabel : tx.note
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(tint, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(categoryLabel)
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(author)
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(mine ? AppTheme.blue : AppTheme.purple)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((mine ? AppTheme.blue : AppTheme.purple).opacity(0.14), in: Capsule())
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text((tx.amount >= 0 ? "+" : "−") + JointMoney.text(tx.amount, currency: currency))
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(tx.amount >= 0 ? AppTheme.green : AppTheme.textPrimary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Money in / money out

struct JointEntrySheet: View {
    let account: JointAccount

    @Environment(\.dismiss) private var dismiss
    @State private var service = JointAccountService.shared
    @State private var kind: JointTx.Kind
    @State private var category: TxCategory
    @State private var amountText = ""
    @State private var note = ""
    @State private var date = Date()
    @State private var saving = false

    static let spendCategories: [TxCategory] = [.food, .shopping, .bills, .transport, .health, .commitment, .travel, .other]
    static let incomeCategories: [TxCategory] = [.salary, .business, .freelance, .bonus, .gift, .incomeOther]

    init(account: JointAccount, kind: JointTx.Kind) {
        self.account = account
        _kind = State(initialValue: kind == .income ? .income : .spend)
        _category = State(initialValue: kind == .income ? .salary : .food)
    }

    private var categories: [TxCategory] { kind == .spend ? Self.spendCategories : Self.incomeCategories }
    private var amount: Int64 { JointMoney.toMinor(NumberInput.amount(amountText), currency: account.currency) }
    private var draft: JointDraft {
        JointDraft(kind: kind, amount: amount, category: category.rawValue, note: note, date: date)
    }

    /// What happens next, in one line: who hears about it, and what the budget becomes.
    private var preview: String? {
        guard amount > 0 else { return nil }
        var parts: [String] = []
        let me = Auth.auth().currentUser?.uid
        let others = (service.members[account.id] ?? []).filter { $0.id != me }.map(\.displayName).filter { !$0.isEmpty }
        if !others.isEmpty {
            parts.append(String(format: loc("joint.entry.will_notify"), others.joined(separator: ", ")))
        }
        let month = service.month
        if kind == .spend, account.monthlyBudget > 0, date >= month.start, date < month.end {
            let left = account.monthlyBudget - service.spentThisMonth(account.id) - amount
            parts.append(String(format: loc(left >= 0 ? "joint.entry.budget_after" : "joint.entry.budget_after_over"),
                                JointAccountCard.monthName(month), JointMoney.text(left, currency: account.currency)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        SlidingSegments(options: [JointTx.Kind.income, .spend], selection: kind, onSelect: { k in
                            kind = k
                            if !categories.contains(category) { category = categories[0] }
                        }) { option, on in
                            Text(loc(option == .income ? "joint.action.in" : "joint.action.out"))
                                .font(.system(.subheadline, weight: .bold))
                                .foregroundStyle(on ? AppTheme.onVividFill : AppTheme.textSecondary)
                        }

                        HStack(spacing: 10) {
                            Text(account.currency)
                                .font(.system(.subheadline, weight: .bold))
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 58, height: 60)
                                .background(AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: AppRadius.md))
                            TextField("0", text: $amountText)
                                .font(.system(.title, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .keyboardType(.decimalPad)
                                .padding(.horizontal, 16)
                                .frame(height: 60)
                                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                            ForEach(categories, id: \.self) { c in
                                categoryChip(c)
                            }
                        }

                        JointField(title: loc("joint.entry.note")) {
                            TextField(loc(kind == .spend ? "joint.entry.note_placeholder_out" : "joint.entry.note_placeholder_in"),
                                      text: $note)
                                .font(.system(.body))
                        }

                        DatePicker(loc("joint.entry.date"), selection: $date, in: ...Date(), displayedComponents: .date)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .tint(AppTheme.accent)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))

                        if let preview {
                            JointInfo(icon: "bell.fill", text: preview)
                        }

                        JointPrimaryButton(title: loc("common.save"), busy: saving, enabled: draft.isValid) {
                            save()
                        }
                    }
                    .padding(22)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(account.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
    }

    private func categoryChip(_ c: TxCategory) -> some View {
        let on = c == category
        let tint = Color(hex: c.iconBg)
        return Button {
            HapticManager.shared.tap()
            category = c
        } label: {
            HStack(spacing: 6) {
                Image(systemName: c.icon).font(.system(.caption, weight: .bold)).foregroundStyle(tint)
                Text(c.displayLabel)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(on ? tint.opacity(0.14) : AppTheme.cardDark, in: Capsule())
            .overlay(Capsule().stroke(on ? tint : .clear, lineWidth: 1.5))
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func save() {
        saving = true
        let draft = self.draft
        Task {
            let ok = await service.add(draft, to: account)
            saving = false
            if ok { HapticManager.shared.success(); dismiss() } else { HapticManager.shared.warning() }
        }
    }
}

// MARK: - Deposit from my own card

struct JointDepositSheet: View {
    let account: JointAccount
    @Bindable var vm: AppViewModel

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var service = JointAccountService.shared
    @State private var cardID: UUID?
    @State private var amountText = ""
    @State private var saving = false

    private var cards: [BankCard] { vm.cards.filter { !$0.isCreditCard } }
    private var card: BankCard? { cards.first { $0.id == cardID } ?? cards.first }
    private var amount: Double { NumberInput.amount(amountText) }
    private var balance: Double { card?.computedBalance() ?? 0 }
    private var insufficient: Bool { amount > balance + 0.0001 }
    private var sharedMinor: Int64 {
        guard let card else { return 0 }
        let converted = CurrencyManager.shared.convert(amount, from: card.resolvedCurrency, to: account.currency)
        return JointMoney.toMinor(converted, currency: account.currency)
    }
    private var canDeposit: Bool { card != nil && amount > 0 && !insufficient && sharedMinor > 0 }

    static func label(_ card: BankCard) -> String {
        if card.isDigitalWallet, !card.walletProvider.isEmpty { return card.walletProvider }
        let l4 = card.last4
        return l4.isEmpty ? (card.holderName.isEmpty ? loc("transfer.card") : card.holderName) : "•• \(l4)"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(loc("joint.deposit.sub"))
                            .font(.system(.subheadline))
                            .foregroundStyle(AppTheme.textSecondary)

                        if cards.isEmpty {
                            JointInfo(icon: "creditcard", text: loc("joint.deposit.no_cards"), tint: AppTheme.orange)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(cards) { c in cardTile(c) }
                                }
                                .padding(.vertical, 3)
                            }

                            HStack(spacing: 10) {
                                Text(card?.resolvedCurrency ?? "")
                                    .font(.system(.subheadline, weight: .bold))
                                    .foregroundStyle(AppTheme.accent)
                                    .frame(width: 58, height: 60)
                                    .background(AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: AppRadius.md))
                                TextField("0", text: $amountText)
                                    .font(.system(.title, weight: .bold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .keyboardType(.decimalPad)
                                    .padding(.horizontal, 16)
                                    .frame(height: 60)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                                    .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                                        .stroke(insufficient ? AppTheme.red.opacity(0.5) : .clear, lineWidth: 1))
                            }

                            if insufficient {
                                Text(loc("joint.deposit.insufficient"))
                                    .font(.system(.footnote, weight: .medium))
                                    .foregroundStyle(AppTheme.red)
                            }

                            if let card, amount > 0 {
                                flowPreview(card)
                            }

                            JointInfo(icon: "info.circle.fill", text: loc("joint.deposit.not_spending"))

                            JointPrimaryButton(
                                title: amount > 0
                                    ? String(format: loc("joint.deposit.button_amount"),
                                             CurrencyManager.shared.formatted(amount, currency: card?.resolvedCurrency ?? account.currency))
                                    : loc("joint.action.deposit"),
                                busy: saving, enabled: canDeposit) {
                                deposit()
                            }
                        }
                    }
                    .padding(22)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(String(format: loc("joint.deposit.title"), account.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
    }

    private func cardTile(_ c: BankCard) -> some View {
        let on = c.id == card?.id
        let network = CardNetwork.detect(from: c.cardNumber)
        let start = c.gradientStart.isEmpty ? network.gradientStart : c.gradientStart
        let end = c.gradientEnd.isEmpty ? network.gradientEnd : c.gradientEnd
        return Button {
            HapticManager.shared.tap()
            cardID = c.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.label(c))
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Text(c.formattedBalance)
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(14)
            .frame(width: 150, alignment: .leading)
            .background(LinearGradient(colors: [Color(hex: start), Color(hex: end)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(on ? AppTheme.accent : .clear, lineWidth: 3))
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Both balances after the move, so the person sees it is a move.
    private func flowPreview(_ card: BankCard) -> some View {
        let cardAfter = balance - amount
        let sharedAfter = account.balance + sharedMinor
        return HStack(spacing: 8) {
            VStack(spacing: 3) {
                Text(Self.label(card))
                    .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary).lineLimit(1)
                Text(CurrencyManager.shared.formatted(cardAfter, currency: card.resolvedCurrency))
                    .font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            Image(systemName: "arrow.right")
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(AppTheme.textSecondary)
            VStack(spacing: 3) {
                Text(account.name)
                    .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary).lineLimit(1)
                Text((sharedAfter < 0 ? "−" : "") + JointMoney.text(sharedAfter, currency: account.currency))
                    .font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .accessibilityElement(children: .combine)
    }

    private func deposit() {
        guard let card, canDeposit else { return }
        saving = true
        let label = Self.label(card)
        let amount = self.amount
        Task {
            let ok = await service.deposit(into: account, from: card, amount: amount, label: label, context: context)
            saving = false
            if ok { HapticManager.shared.success(); dismiss() } else { HapticManager.shared.warning() }
        }
    }
}
