import SwiftUI
import SwiftData

// MARK: - SwiftData Model
//
// A fixed monthly outgoing — rent/kos, subscriptions, a standing transfer to
// family. The income twin of this is `SalarySchedule`; this model mirrors it
// closely (same day-of-month + linked-card + autoRecord shape) so the two
// features feel identical, only the sign of the money differs.
@Model
final class RecurringExpense {
    var id: UUID
    var label: String
    var amount: Double
    var dayOfMonth: Int
    var currency: String
    /// Stored as the TxCategory rawValue (stable key) — same convention as TxRecord.
    var categoryRaw: String
    var isActive: Bool
    var cardID: UUID?
    var createdAt: Date
    /// Month/year this expense was last auto-charged, so the engine never
    /// double-charges within a single month.
    var lastChargedMonth: Int
    var lastChargedYear: Int
    /// When true the engine posts a debit transaction on the charge day. When
    /// false the expense is planning-only: it shows in the list and counts
    /// toward the monthly total, but records nothing (for bills paid from an
    /// account not tracked in DiPo).
    var autoRecord: Bool = true

    var category: TxCategory {
        get { TxCategory(rawValue: categoryRaw) ?? .commitment }
        set { categoryRaw = newValue.rawValue }
    }

    init(label: String, amount: Double, dayOfMonth: Int,
         category: TxCategory = .commitment,
         currency: String = CurrencyManager.shared.preferredCurrency,
         cardID: UUID? = nil) {
        self.id = UUID()
        self.label = label
        self.amount = amount
        self.dayOfMonth = dayOfMonth
        self.categoryRaw = category.rawValue
        self.currency = currency
        self.isActive = true
        self.cardID = cardID
        self.createdAt = .now
        self.lastChargedMonth = 0
        self.lastChargedYear = 0
        self.autoRecord = true
    }
}

// MARK: - Recurring Date Engine
//
// Unlike salary (which is pulled EARLIER to the nearest business day because
// banks pay ahead of weekends/holidays), a bill is due on its fixed calendar
// day. So this engine does no business-day adjustment — it just clamps the day
// to the length of the month (a "31st" bill lands on Feb 28/29).
struct RecurringDateEngine {

    static func dueDate(dayOfMonth: Int, month: Int, year: Int) -> Date {
        let cal = Calendar.current
        var comps = DateComponents(year: year, month: month, day: 1)
        let lastDay = cal.range(of: .day, in: .month, for: cal.safeDate(from: comps))?.count ?? 28
        comps.day = min(max(dayOfMonth, 1), lastDay)
        return cal.safeDate(from: comps)
    }

    static func nextDueDate(dayOfMonth: Int) -> Date {
        let cal = Calendar.current
        let now = Date()
        let m = cal.component(.month, from: now)
        let y = cal.component(.year, from: now)
        let thisMonth = dueDate(dayOfMonth: dayOfMonth, month: m, year: y)
        if thisMonth >= cal.startOfDay(for: now) { return thisMonth }
        let nm = m == 12 ? 1 : m + 1
        let ny = m == 12 ? y + 1 : y
        return dueDate(dayOfMonth: dayOfMonth, month: nm, year: ny)
    }

    static func daysUntil(dayOfMonth: Int) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: .now),
                                  to: nextDueDate(dayOfMonth: dayOfMonth)).day ?? 0
    }
}

// MARK: - Recurring Auto-Charge Engine
// Runs alongside SalaryCreditEngine on launch/foreground. For each active,
// auto-record expense whose charge day has arrived this month, posts a debit
// to the linked card exactly once.
struct RecurringExpenseEngine {

    @MainActor
    static func processIfNeeded(context: ModelContext) {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        let month = cal.component(.month, from: today)
        let year  = cal.component(.year,  from: today)

        guard let items = try? context.fetch(FetchDescriptor<RecurringExpense>()) else { return }
        guard let cards = try? context.fetch(FetchDescriptor<BankCard>(sortBy: [SortDescriptor(\.sortOrder)])),
              !cards.isEmpty else { return }

        var didCharge = false

        for e in items {
            guard e.isActive, e.autoRecord else { continue }
            if e.lastChargedMonth == month && e.lastChargedYear == year { continue }

            guard let cardID = e.cardID,
                  let card = cards.first(where: { $0.id == cardID }) else {
                print("[RecurringExpenseEngine] Skipping \(e.label) — no card linked")
                continue
            }

            // Catch up on months the app wasn't opened — same reasoning as the
            // salary engine. Missing a kos charge makes that cycle look cheap
            // and quietly flatters every ratio built on it. Bounded by the
            // plan's creation date, the last charge, and 12 months.
            for (m, y) in pendingMonths(for: e, currentMonth: month,
                                        currentYear: year, cal: cal) {
                let due = RecurringDateEngine.dueDate(dayOfMonth: e.dayOfMonth, month: m, year: y)
                guard today >= cal.startOfDay(for: due) else { continue }

                // Stable keys only (type/notes) — translated at display time,
                // never frozen into the DB. Same rule the salary engine follows.
                let tx = TxRecord(
                    name: e.label,
                    date: due,
                    amount: -abs(e.amount),
                    type: "tx.type.purchase",
                    icon: String(e.label.prefix(2).uppercased()),
                    iconBgHex: e.category.iconBg,
                    category: e.category,
                    currency: e.currency,
                    notes: "tx.note.recurring_auto"
                )
                // Insert BEFORE appending: TxRecord has no `inverse:` on the
                // relationship, so SwiftData won't always auto-persist a child
                // added only via the parent's array. Insert-then-append is safe.
                context.insert(tx)
                card.transactions.append(tx)

                // Stamp the month actually charged, not "now".
                e.lastChargedMonth = m
                e.lastChargedYear  = y
                didCharge = true

                print("[RecurringExpenseEngine] Charged \(e.currency) \(e.amount) for \(e.label) (\(m)/\(y))")
            }
        }

        if didCharge { try? context.save() }
    }

    /// Months still owing a charge, oldest first. Mirrors the salary engine's
    /// bounds so the two never drift apart.
    private static func pendingMonths(for e: RecurringExpense,
                                      currentMonth: Int, currentYear: Int,
                                      cal: Calendar) -> [(Int, Int)] {
        let createdM = cal.component(.month, from: e.createdAt)
        let createdY = cal.component(.year,  from: e.createdAt)

        var startM: Int, startY: Int
        if e.lastChargedYear > 0 {
            startM = e.lastChargedMonth + 1
            startY = e.lastChargedYear
            if startM > 12 { startM = 1; startY += 1 }
        } else {
            startM = createdM; startY = createdY
        }
        if startY < createdY || (startY == createdY && startM < createdM) {
            startM = createdM; startY = createdY
        }

        var out: [(Int, Int)] = []
        var m = startM, y = startY
        while (y < currentYear) || (y == currentYear && m <= currentMonth) {
            out.append((m, y))
            if out.count >= 12 { break }
            m += 1
            if m > 12 { m = 1; y += 1 }
        }
        return out
    }
}

// MARK: - ViewModel

@Observable
final class RecurringExpenseViewModel {
    var showAddSheet = false
    var editing: RecurringExpense? = nil
    var formLabel: String = ""
    var formAmount: String = ""
    var formDay: Int = 1
    var formCategory: TxCategory = .commitment
    var formCurrency: String = CurrencyManager.shared.preferredCurrency
    var formCardID: UUID? = nil
    var formAutoRecord: Bool = true
    var formError: String? = nil

    /// Expense-side categories offered in the picker (income kinds excluded).
    static let categories: [TxCategory] = [
        .commitment, .bills, .food, .transport, .shopping, .health, .travel, .other
    ]
    let currencies = ["USD", "IDR"]

    func resetForm() {
        formLabel = ""; formAmount = ""; formDay = 1
        formCategory = .commitment
        formCurrency = CurrencyManager.shared.preferredCurrency
        formCardID = nil; formAutoRecord = true; formError = nil
        editing = nil
    }

    func loadForEdit(_ e: RecurringExpense, cards: [BankCard]) {
        formLabel = e.label
        formAmount = String(e.amount)
        formDay = e.dayOfMonth
        formCategory = e.category
        formCardID = e.cardID
        formAutoRecord = e.autoRecord
        if let id = e.cardID, let card = cards.first(where: { $0.id == id }) {
            formCurrency = card.currency
        } else {
            formCurrency = e.currency
        }
        editing = e
        showAddSheet = true
    }

    func validate() -> Bool {
        guard !formLabel.trimmingCharacters(in: .whitespaces).isEmpty else {
            formError = loc("recurring.error_label"); return false
        }
        guard let amt = Double(formAmount), amt > 0 else {
            formError = loc("recurring.error_amount"); return false
        }
        guard formCardID != nil else {
            formError = loc("recurring.error_card"); return false
        }
        formError = nil
        return true
    }
}

// MARK: - Main View

struct RecurringExpensesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RecurringExpense.createdAt) private var expenses: [RecurringExpense]
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @State private var vm = RecurringExpenseViewModel()
    @State private var appeared = false
    @State private var showOrphanCleanup = false

    /// Max rows shown inline before collapsing behind "See all".
    static let previewLimit = 5

    /// Transactions the engine auto-posted (`notes == tx.note.recurring_auto`)
    /// whose schedule has since been deleted — deleting the schedule never
    /// removed them, so they linger and quietly inflate the budget. Matched by
    /// name against surviving schedules; anything without a match is orphaned.
    private var orphanedAutoCharges: [TxRecord] {
        let liveLabels = Set(expenses.map { $0.label.trimmingCharacters(in: .whitespaces).lowercased() })
        return cards.flatMap { $0.transactions }.filter { tx in
            tx.notes == "tx.note.recurring_auto"
            && !liveLabels.contains(tx.name.trimmingCharacters(in: .whitespaces).lowercased())
        }
        .sorted { $0.date > $1.date }
    }

    private var activeExpenses: [RecurringExpense] { expenses.filter { $0.isActive } }

    /// Sum of active expenses converted to the user's preferred currency.
    private var monthlyTotal: Double {
        let pref = CurrencyManager.shared.preferredCurrency
        return activeExpenses.reduce(0) {
            $0 + CurrencyManager.shared.convert($1.amount, from: $1.currency, to: pref)
        }
    }

    private var nextDue: RecurringExpense? {
        activeExpenses.min {
            RecurringDateEngine.daysUntil(dayOfMonth: $0.dayOfMonth)
              < RecurringDateEngine.daysUntil(dayOfMonth: $1.dayOfMonth)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        navBar
                            .padding(.horizontal, 22).padding(.top, 20)
                            .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : -12)

                        // Orphaned auto-charge cleanup — surfaces only when there
                        // are leftover transactions from deleted schedules.
                        if !orphanedAutoCharges.isEmpty {
                            Button {
                                HapticManager.shared.tap(); showOrphanCleanup = true
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "wand.and.stars.inverse").font(.system(size: 16)).foregroundStyle(AppTheme.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(String(format: loc("recurring.orphan_title"), orphanedAutoCharges.count))
                                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                        Text(loc("recurring.orphan_sub"))
                                            .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                                }
                                .padding(14)
                                .background(AppTheme.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.orange.opacity(0.25), lineWidth: 1))
                            }
                            .buttonStyle(ScaleButtonStyle())
                            .padding(.horizontal, 22).padding(.top, 14)
                        }

                        if !activeExpenses.isEmpty {
                            summaryCard
                                .padding(.horizontal, 22).padding(.top, 20)
                                .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 16)
                                .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.05), value: appeared)
                        }

                        if expenses.isEmpty {
                            emptyState.padding(.top, 56).opacity(appeared ? 1 : 0)
                        } else {
                            VStack(spacing: 14) {
                                // Overview shows at most `previewLimit`; the rest
                                // move to a dedicated full-list page.
                                ForEach(Array(expenses.prefix(Self.previewLimit).enumerated()), id: \.element.id) { i, e in
                                    RecurringExpenseRow(expense: e, cards: cards, vm: vm, context: context)
                                        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 20)
                                        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(Double(i) * 0.06), value: appeared)
                                }
                                if expenses.count > Self.previewLimit {
                                    NavigationLink {
                                        AllRecurringExpensesView(expenses: expenses, cards: cards, vm: vm)
                                    } label: {
                                        SeeAllLabel(count: expenses.count)
                                    }
                                }
                            }
                            .padding(.horizontal, 22).padding(.top, 20)
                        }
                        Spacer(minLength: 120)
                    }
                }
            }
            .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { appeared = true } }
            .sheet(isPresented: $vm.showAddSheet, onDismiss: { vm.resetForm() }) {
                RecurringFormSheet(vm: vm, context: context)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
                    .preferredColorScheme(appColorScheme())
            }
            .sheet(isPresented: $showOrphanCleanup) {
                OrphanedAutoChargesView(orphans: orphanedAutoCharges)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
                    .preferredColorScheme(appColorScheme())
            }
        }
    }

    private var navBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("recurring.title")).font(.system(size: 24, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                Text(loc("recurring.sub")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Button {
                HapticManager.shared.tap(); vm.resetForm(); vm.showAddSheet = true
            } label: {
                ZStack {
                    Circle().fill(cards.isEmpty ? AppTheme.cardMid : AppTheme.accent)
                        .frame(width: 42, height: 42)
                        .shadow(color: cards.isEmpty ? .clear : AppTheme.accent.opacity(0.4), radius: 10, y: 4)
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(cards.isEmpty ? AppTheme.textSecondary : AppTheme.bg)
                }
            }
            .disabled(cards.isEmpty).buttonStyle(ScaleButtonStyle())
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc("recurring.total")).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                    Text(CurrencyManager.shared.formatted(monthlyTotal, currency: CurrencyManager.shared.preferredCurrency))
                        .font(.system(size: 26, weight: .heavy)).foregroundStyle(AppTheme.textPrimary)
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(AppTheme.accent.opacity(0.12)).frame(width: 52, height: 52)
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 22)).foregroundStyle(AppTheme.accent)
                }
            }
            .padding(18)

            if let n = nextDue {
                Divider().background(AppTheme.cardMid).padding(.horizontal, 18)
                HStack(spacing: 10) {
                    Image(systemName: "calendar").font(.system(size: 13)).foregroundStyle(AppTheme.accent)
                    Text(loc("recurring.next")).font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                    Text(n.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                    Spacer()
                    Text(dueLabel(for: n.dayOfMonth)).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.accent)
                }
                .padding(.horizontal, 18).padding(.vertical, 13)
            }
        }
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppTheme.accent.opacity(0.18), lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(AppTheme.cardDark).frame(width: 88, height: 88)
                    .overlay(Circle().stroke(AppTheme.accent.opacity(0.2), lineWidth: 1))
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 34)).foregroundStyle(AppTheme.accent)
            }
            VStack(spacing: 8) {
                Text(loc("recurring.none_title")).font(.system(size: 18, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Text(cards.isEmpty ? loc("recurring.none_needs_card") : loc("recurring.none_sub"))
                    .font(.system(size: 14)).foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
            }
            if !cards.isEmpty {
                Button {
                    HapticManager.shared.tap(); vm.resetForm(); vm.showAddSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                        Text(loc("recurring.add")).font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.bg).padding(.horizontal, 32).padding(.vertical, 14)
                    .background(AppTheme.accent, in: Capsule())
                    .shadow(color: AppTheme.accent.opacity(0.35), radius: 12, y: 6)
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(.horizontal, 40)
    }

    /// "Today" / "Tomorrow" / "in N days" for the summary + rows.
    func dueLabel(for day: Int) -> String {
        let d = RecurringDateEngine.daysUntil(dayOfMonth: day)
        if d <= 0 { return loc("recurring.due_today") }
        if d == 1 { return loc("recurring.due_tomorrow") }
        return String(format: loc("recurring.due_in"), d)
    }
}

// MARK: - Row

struct RecurringExpenseRow: View {
    let expense: RecurringExpense
    let cards: [BankCard]
    @Bindable var vm: RecurringExpenseViewModel
    let context: ModelContext

    private var due: Int { RecurringDateEngine.daysUntil(dayOfMonth: expense.dayOfMonth) }
    private var dueLabel: String {
        if due <= 0 { return loc("recurring.due_today") }
        if due == 1 { return loc("recurring.due_tomorrow") }
        return String(format: loc("recurring.due_in"), due)
    }

    var body: some View {
        Button {
            HapticManager.shared.tap()
            vm.loadForEdit(expense, cards: cards)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(expense.category.color.opacity(0.14)).frame(width: 46, height: 46)
                    Image(systemName: expense.category.icon).font(.system(size: 19)).foregroundStyle(expense.category.color)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(expense.label).font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(expense.isActive ? AppTheme.textPrimary : AppTheme.textSecondary)
                            .lineLimit(1)
                        if !expense.autoRecord {
                            Text(loc("recurring.manual_badge")).font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AppTheme.textSecondary)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(AppTheme.cardMid, in: Capsule())
                        }
                    }
                    HStack(spacing: 8) {
                        Text(String(format: loc("recurring.day_of"), expense.dayOfMonth))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                        Circle().fill(AppTheme.textSecondary.opacity(0.4)).frame(width: 3, height: 3)
                        Text(expense.isActive ? dueLabel : loc("recurring.paused"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(expense.isActive ? AppTheme.accent : AppTheme.textSecondary)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(CurrencyManager.shared.formatted(expense.amount, currency: expense.currency))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(expense.isActive ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Menu {
                        Button { HapticManager.shared.tap(); vm.loadForEdit(expense, cards: cards) } label: {
                            Label(loc("common.edit"), systemImage: "pencil")
                        }
                        Button {
                            HapticManager.shared.tap()
                            expense.isActive.toggle(); try? context.save()
                        } label: {
                            Label(expense.isActive ? loc("recurring.pause") : loc("recurring.resume"),
                                  systemImage: expense.isActive ? "pause.circle" : "play.circle")
                        }
                        Button(role: .destructive) {
                            HapticManager.shared.tap()
                            context.delete(expense); try? context.save()
                        } label: {
                            Label(loc("recurring.delete"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(AppTheme.cardMid, in: Circle())
                    }
                }
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.cardMid.opacity(0.5), lineWidth: 1))
            .opacity(expense.isActive ? 1 : 0.7)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Form Sheet

struct RecurringFormSheet: View {
    @Bindable var vm: RecurringExpenseViewModel
    let context: ModelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @State private var appeared = false

    private var isEditing: Bool { vm.editing != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        SheetField(label: loc("recurring.label"),
                                   placeholder: loc("recurring.label_ph"),
                                   text: $vm.formLabel)

                        // Amount + currency (currency locks to the card's currency)
                        VStack(spacing: 8) {
                            Text(loc("recurring.amount")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            HStack(spacing: 10) {
                                if let cardID = vm.formCardID, let card = cards.first(where: { $0.id == cardID }) {
                                    HStack(spacing: 6) {
                                        Text(card.currency).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 14)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                } else {
                                    Menu {
                                        ForEach(vm.currencies, id: \.self) { c in
                                            Button(c) { HapticManager.shared.tap(); vm.formCurrency = c }
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text(vm.formCurrency).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                                        }
                                        .padding(.horizontal, 14).padding(.vertical, 14)
                                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                    }
                                }
                                TextField("0", text: $vm.formAmount)
                                    .font(.system(size: 22, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                    .keyboardType(.decimalPad)
                                    .padding(.horizontal, 16).padding(.vertical, 14)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal, 22)
                        }

                        // Category picker
                        VStack(spacing: 8) {
                            Text(loc("recurring.category")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(RecurringExpenseViewModel.categories, id: \.self) { cat in
                                        let selected = vm.formCategory == cat
                                        Button {
                                            HapticManager.shared.tap(); vm.formCategory = cat
                                        } label: {
                                            HStack(spacing: 7) {
                                                Image(systemName: cat.icon).font(.system(size: 13))
                                                Text(cat.displayLabel).font(.system(size: 13, weight: .semibold))
                                            }
                                            .foregroundStyle(selected ? AppTheme.bg : cat.color)
                                            .padding(.horizontal, 14).padding(.vertical, 10)
                                            .background(selected ? cat.color : cat.color.opacity(0.12), in: Capsule())
                                        }
                                        .buttonStyle(ScaleButtonStyle())
                                    }
                                }
                                .padding(.horizontal, 22)
                            }
                        }

                        // Charge day stepper
                        VStack(spacing: 8) {
                            Text(loc("recurring.due_day")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(String(format: loc("recurring.day_of"), vm.formDay))
                                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                    Text(loc("recurring.due_day_sub")).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                                }
                                Spacer()
                                HStack(spacing: 0) {
                                    Button { HapticManager.shared.tap(); if vm.formDay > 1 { vm.formDay -= 1 } } label: {
                                        Image(systemName: "minus").font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary).frame(width: 40, height: 40)
                                    }
                                    Text("\(vm.formDay)").font(.system(size: 20, weight: .bold)).foregroundStyle(AppTheme.accent).frame(width: 44).contentTransition(.numericText())
                                    Button { HapticManager.shared.tap(); if vm.formDay < 31 { vm.formDay += 1 } } label: {
                                        Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary).frame(width: 40, height: 40)
                                    }
                                }
                                .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .padding(16)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 22)
                        }

                        // Card picker — REQUIRED: which card gets charged
                        VStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(AppTheme.orange)
                                Text(loc("recurring.choose_card")).font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.orange)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            CardPickerSection(selectedCardID: $vm.formCardID, titleKey: "recurring.charge_to")
                        }
                        .onChange(of: vm.formCardID) { _, newID in
                            if let id = newID, let card = cards.first(where: { $0.id == id }) { vm.formCurrency = card.currency }
                        }

                        // Auto-record toggle
                        HStack(spacing: 12) {
                            Image(systemName: "wand.and.stars").font(.system(size: 16)).foregroundStyle(AppTheme.accent)
                                .frame(width: 36, height: 36).background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc("recurring.autorecord_label")).font(.system(size: 14, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                                Text(loc("recurring.autorecord_sub")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                            }
                            Spacer()
                            Toggle("", isOn: $vm.formAutoRecord).labelsHidden().tint(AppTheme.accent)
                        }
                        .padding(14)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 22)

                        if let err = vm.formError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13))
                                Text(err).font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(AppTheme.red)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                        }

                        saveButton.padding(.top, 4)
                        Spacer(minLength: 40)
                    }
                    .padding(.top, 12)
                }
            }
            .navigationTitle(isEditing ? loc("recurring.edit_title") : loc("recurring.new_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
            }
            .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true } }
        }
    }

    private var saveButton: some View {
        Button {
            guard vm.validate() else { HapticManager.shared.error(); return }
            save()
        } label: {
            Text(loc("recurring.save")).font(.system(size: 16, weight: .bold))
                .foregroundStyle(AppTheme.bg).frame(maxWidth: .infinity).padding(.vertical, 17)
                .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(ScaleButtonStyle())
        .padding(.horizontal, 22)
    }

    private func save() {
        let amount = Double(vm.formAmount) ?? 0
        if let e = vm.editing {
            e.label = vm.formLabel.trimmingCharacters(in: .whitespaces)
            e.amount = amount
            e.dayOfMonth = vm.formDay
            e.category = vm.formCategory
            e.currency = vm.formCurrency
            e.cardID = vm.formCardID
            e.autoRecord = vm.formAutoRecord
        } else {
            let e = RecurringExpense(
                label: vm.formLabel.trimmingCharacters(in: .whitespaces),
                amount: amount, dayOfMonth: vm.formDay,
                category: vm.formCategory, currency: vm.formCurrency, cardID: vm.formCardID)
            e.autoRecord = vm.formAutoRecord
            context.insert(e)
        }
        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}

// MARK: - All Recurring Expenses (full-list page)
//
// Reached from the "See all" row when there are more than a few recurring
// expenses. Rows are self-contained (they drive edit/pause/delete via the
// shared view-model), so this page just lays them all out in a lazy stack.
struct AllRecurringExpensesView: View {
    let expenses: [RecurringExpense]
    let cards: [BankCard]
    @Bindable var vm: RecurringExpenseViewModel
    @Environment(\.modelContext) private var context

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 14) {
                    ForEach(expenses) { e in
                        RecurringExpenseRow(expense: e, cards: cards, vm: vm, context: context)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
        }
        .navigationTitle(loc("recurring.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Orphaned Auto-Charge Cleanup
//
// Lists transactions the recurring engine auto-created whose schedule was later
// deleted, and removes the ones the user confirms. Deleting a schedule never
// removed its past charges, so they linger and inflate the budget until wiped
// here (which also restores the card balance).
struct OrphanedAutoChargesView: View {
    let orphans: [TxRecord]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var selected: Set<UUID> = []
    @State private var appeared = false

    private var chosen: [TxRecord] { orphans.filter { selected.contains($0.id) } }
    private var chosenTotal: Double {
        chosen.reduce(0) { $0 + CurrencyManager.shared.convert(abs($1.amount),
                                                               from: $1.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : $1.currency,
                                                               to: CurrencyManager.shared.preferredCurrency) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                if orphans.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(AppTheme.accent)
                        Text(loc("recurring.orphan_none")).font(.system(size: 16)).foregroundStyle(AppTheme.textSecondary)
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            Text(loc("recurring.orphan_explain"))
                                .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22).padding(.bottom, 4)
                            ForEach(orphans) { tx in
                                row(tx)
                            }
                            .padding(.horizontal, 22)
                            Spacer(minLength: 100)
                        }
                        .padding(.top, 8)
                    }
                    VStack { Spacer(); deleteButton }
                }
            }
            .navigationTitle(loc("recurring.orphan_nav"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.done")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
            }
            .onAppear {
                if !appeared { selected = Set(orphans.map(\.id)); appeared = true }  // pre-select all
            }
        }
    }

    private func row(_ tx: TxRecord) -> some View {
        let isOn = selected.contains(tx.id)
        return Button {
            HapticManager.shared.tap()
            if isOn { selected.remove(tx.id) } else { selected.insert(tx.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(isOn ? AppTheme.red : AppTheme.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tx.name).font(.system(size: 14, weight: .medium)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                    Text(tx.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Text(CurrencyManager.shared.formatted(abs(tx.amount), currency: tx.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : tx.currency))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
            }
            .padding(12)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var deleteButton: some View {
        Button {
            HapticManager.shared.warning()
            for tx in chosen { context.delete(tx) }
            try? context.save()
            dismiss()
        } label: {
            Text(String(format: loc("recurring.orphan_delete"), chosen.count,
                        CurrencyManager.shared.formatted(chosenTotal, currency: CurrencyManager.shared.preferredCurrency)))
                .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(chosen.isEmpty ? AppTheme.cardMid : AppTheme.red, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(chosen.isEmpty)
        .padding(.horizontal, 22).padding(.bottom, 20)
    }
}
