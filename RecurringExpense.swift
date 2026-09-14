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

    /// Whether the charge for this plan's CURRENT due date has already posted.
    ///
    /// Compared against the month of the next due date, not against today. On
    /// the due day `nextDueDate` still returns today, so a bill charged this
    /// morning is "due in 0 days" for the rest of the day — which is why the
    /// Home banner kept promising to record a transaction it had already
    /// recorded, and why the spend projection risked counting it twice.
    ///
    /// Always false when `autoRecord` is off: nothing will post it, so the
    /// reminder is still owed and the projection still has to expect it.
    var isChargedForCurrentDue: Bool {
        guard autoRecord else { return false }
        let cal = Calendar.current
        let due = RecurringDateEngine.nextDueDate(dayOfMonth: dayOfMonth)
        return lastChargedYear  == cal.component(.year,  from: due)
            && lastChargedMonth == cal.component(.month, from: due)
    }
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
                // Never post a charge dated before the schedule existed.
                // pendingMonths bounds to the creation MONTH, not the creation
                // DAY — so a bill added on the 14th with a day-8 due date used
                // to charge immediately, back-dated to the 8th. Two harms: the
                // balance drops for a payment the user never authorised here,
                // and the row lands days up the ledger where nobody thinks to
                // look for it. A bill starts counting from its first due date
                // AFTER it was set up; anything earlier is history the user
                // enters by hand if they want it.
                guard due >= cal.startOfDay(for: e.createdAt) else { continue }

                // A bill declared in a currency other than its source card's is
                // converted ONCE, here, at the rate in force on the charge day,
                // and stored in the card's own currency. See the FX notes on
                // TxRecord for why the rate must be frozen rather than applied
                // when a screen happens to draw the row.
                //
                // The fallback matters as much as the conversion: `lastUpdated`
                // is nil only when no real rate has ever been fetched or cached,
                // meaning CurrencyManager is still on its hardcoded seed table.
                // Freezing an invented rate into the ledger forever is worse
                // than storing the original currency and letting display-time
                // conversion self-correct once real rates arrive.
                let cardCurrency = card.resolvedCurrency
                var txAmount   = -abs(e.amount)
                var txCurrency = e.currency
                var fxOriginal: Double = 0
                var fxOriginalCur = ""
                var fxRate: Double = 0

                if !e.currency.isEmpty, e.currency != cardCurrency,
                   CurrencyManager.shared.lastUpdated != nil {
                    let rate = CurrencyManager.shared.convert(1, from: e.currency, to: cardCurrency)
                    if rate > 0 {
                        fxOriginal    = -abs(e.amount)
                        fxOriginalCur = e.currency
                        fxRate        = rate
                        txAmount      = -abs(e.amount * rate)
                        txCurrency    = cardCurrency
                    }
                }

                // Stable keys only (type/notes) — translated at display time,
                // never frozen into the DB. Same rule the salary engine follows.
                let tx = TxRecord(
                    name: e.label,
                    date: due,
                    amount: txAmount,
                    type: "tx.type.purchase",
                    icon: String(e.label.prefix(2).uppercased()),
                    iconBgHex: e.category.iconBg,
                    category: e.category,
                    currency: txCurrency,
                    notes: "tx.note.recurring_auto",
                    fxOriginalAmount: fxOriginal,
                    fxOriginalCurrency: fxOriginalCur,
                    fxRate: fxRate
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
    /// Every currency the app can actually price and convert. Was hardcoded to
    /// ["USD", "IDR"] while CurrencyManager already fetched live rates for a
    /// dozen — so a euro or Singapore-dollar subscription had no way in even
    /// though the conversion behind it worked fine.
    var currencies: [String] { CurrencyManager.supportedCurrencies.map(\.code) }

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
        // Always the expense's OWN currency. This used to overwrite it with the
        // linked card's, so opening a $10 bill for edit showed "IDR 10" and
        // saving wrote that back — silently turning a ten-dollar subscription
        // into a ten-rupiah one. The card's currency is only a default for NEW
        // expenses, applied by the form's .onChange when a card is picked.
        formCurrency = e.currency
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

// MARK: - Charging rules that protect the balance

extension RecurringExpense {
    /// Mark every due date up to today as handled, so the next charge is the
    /// next one that falls due — never a catch-up.
    ///
    /// The engine charges each month since `lastCharged`, up to twelve. That is
    /// right for an app that simply was not opened; it was wrong for a bill the
    /// user had PAUSED. Resuming a bill paused for three months posted three
    /// back-dated charges the moment the app next ran, and turning auto-record
    /// off and on again did the same. Call this whenever charging restarts.
    func markCaughtUp(now: Date = .now) {
        let cal = Calendar.current
        let m = cal.component(.month, from: now)
        let y = cal.component(.year, from: now)
        let dueThisMonth = RecurringDateEngine.dueDate(dayOfMonth: dayOfMonth, month: m, year: y)
        // Due later this month (or today) → it still gets charged: stamp last
        // month. Already past → it passed while charging was off: stamp this one.
        let stamp: (Int, Int)
        if cal.startOfDay(for: dueThisMonth) >= cal.startOfDay(for: now) {
            stamp = m == 1 ? (12, y - 1) : (m - 1, y)
        } else {
            stamp = (m, y)
        }
        // Never move the stamp backwards: that would re-open a charged month.
        if stamp.1 * 12 + stamp.0 > lastChargedYear * 12 + lastChargedMonth {
            lastChargedMonth = stamp.0
            lastChargedYear  = stamp.1
        }
    }

    /// True when the charge for this calendar month has already been posted.
    var chargedThisMonth: Bool {
        let cal = Calendar.current
        let now = Date()
        return autoRecord
            && lastChargedMonth == cal.component(.month, from: now)
            && lastChargedYear  == cal.component(.year,  from: now)
    }
}

/// Transactions the engine posted for a bill, found the only way they can be:
/// by the auto-charge marker and the bill's name.
enum RecurringHistory {
    static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func charges(named label: String, in cards: [BankCard]) -> [(tx: TxRecord, card: BankCard)] {
        let key = normalized(label)
        return cards.flatMap { card in
            card.transactions
                .filter { $0.notes == "tx.note.recurring_auto" && normalized($0.name) == key }
                .map { ($0, card) }
        }
    }

    /// Names of deleted bills whose recorded payments the user chose to KEEP.
    /// Without this the clean-up banner reappeared right after the delete and
    /// offered, pre-selected, to erase payments the user had just said were real.
    private static let keptKey = "recurring.keptHistoryLabels"
    static var keptLabels: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: keptKey) ?? [])
    }
    static func keep(_ label: String) {
        var s = keptLabels; s.insert(normalized(label))
        UserDefaults.standard.set(Array(s), forKey: keptKey)
    }
    static func forget(_ label: String) {
        var s = keptLabels; s.remove(normalized(label))
        UserDefaults.standard.set(Array(s), forKey: keptKey)
    }
}

// MARK: - Main View

struct RecurringExpensesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RecurringExpense.createdAt) private var expenses: [RecurringExpense]
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    /// Needed only so the back-dated cleanup can also see phantom salary
    /// credits — the credit engine carried the identical month-granular bug.
    @Query private var salarySchedules: [SalarySchedule]
    @State private var vm = RecurringExpenseViewModel()
    @State private var appeared = false
    @State private var showOrphanCleanup = false
    @State private var showPhantomCleanup = false
    @State private var actionsFor: RecurringExpense? = nil

    /// Max rows shown inline before collapsing behind "See all".
    static let previewLimit = 6

    /// Auto-posted payments whose bill no longer exists, minus the ones the
    /// user already chose to keep when deleting that bill.
    private var orphanedAutoCharges: [TxRecord] {
        let liveLabels = Set(expenses.map { RecurringHistory.normalized($0.label) })
        let kept = RecurringHistory.keptLabels
        return cards.flatMap { $0.transactions }.filter { tx in
            let name = RecurringHistory.normalized(tx.name)
            return tx.notes == "tx.note.recurring_auto" && !liveLabels.contains(name) && !kept.contains(name)
        }
        .sorted { $0.date > $1.date }
    }

    /// Auto-created rows dated before their own schedule existed — leftovers
    /// from the month-granular catch-up bound both engines used to use.
    private var phantomAutoCharges: [PhantomAutoCharge] {
        PhantomAutoChargeFinder.find(cards: cards, expenses: expenses, salaries: salarySchedules)
    }

    private var activeExpenses: [RecurringExpense] { expenses.filter { $0.isActive } }

    /// Active bills soonest first, then paused ones — the list answers "what
    /// is coming", not "what did I add first".
    private var sortedExpenses: [RecurringExpense] {
        expenses.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            return RecurringDateEngine.daysUntil(dayOfMonth: a.dayOfMonth)
                 < RecurringDateEngine.daysUntil(dayOfMonth: b.dayOfMonth)
        }
    }

    private var pref: String { CurrencyManager.shared.preferredCurrency }
    private func inPref(_ e: RecurringExpense) -> Double {
        CurrencyManager.shared.convert(e.amount, from: e.currency, to: pref)
    }

    private var monthlyTotal: Double { activeExpenses.reduce(0) { $0 + inPref($1) } }

    /// What will still leave this calendar month: active bills whose due date
    /// is today or later and that have not posted yet.
    private var remainingThisMonth: Double {
        let cal = Calendar.current
        let now = Date()
        let m = cal.component(.month, from: now), y = cal.component(.year, from: now)
        return activeExpenses.filter { e in
            let due = RecurringDateEngine.dueDate(dayOfMonth: e.dayOfMonth, month: m, year: y)
            return cal.startOfDay(for: due) >= cal.startOfDay(for: now) && !e.chargedThisMonth
        }
        .reduce(0) { $0 + inPref($1) }
    }

    private var nextDue: RecurringExpense? { sortedExpenses.first(where: \.isActive) }

    var body: some View {
        FeatureStack { pushed in
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        header
                            .padding(.top, 20)

                        if !activeExpenses.isEmpty {
                            summaryCard
                        }

                        if !orphanedAutoCharges.isEmpty {
                            cleanupRow(icon: "tray.full.fill", tint: AppTheme.orange,
                                       title: String(format: loc("recurring.orphan_title"), orphanedAutoCharges.count),
                                       detail: loc("recurring.orphan_sub")) { showOrphanCleanup = true }
                        }
                        if !phantomAutoCharges.isEmpty {
                            cleanupRow(icon: "calendar.badge.exclamationmark", tint: AppTheme.red,
                                       title: String(format: loc("recurring.phantom_title"), phantomAutoCharges.count),
                                       detail: loc("recurring.phantom_sub")) { showPhantomCleanup = true }
                        }

                        if expenses.isEmpty {
                            emptyState.padding(.top, 36)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(loc("recurring.list_title"))
                                    .font(.system(.body, weight: .bold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                RecurringList(expenses: Array(sortedExpenses.prefix(Self.previewLimit)),
                                              onEdit: { vm.loadForEdit($0, cards: cards) },
                                              onMore: { HapticManager.shared.tap(); actionsFor = $0 })
                                if expenses.count > Self.previewLimit {
                                    NavigationLink {
                                        AllRecurringExpensesView(expenses: sortedExpenses, cards: cards, vm: vm)
                                    } label: {
                                        SeeAllLabel(count: expenses.count)
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 22)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                }
            }
            .featureBar(pushed: pushed)
            .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true } }
            .sheet(isPresented: $vm.showAddSheet, onDismiss: { vm.resetForm() }) {
                RecurringFormSheet(vm: vm, context: context)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
                    .preferredColorScheme(appColorScheme())
            }
            .recurringActions(for: $actionsFor, vm: vm, cards: cards)
            .sheet(isPresented: $showOrphanCleanup) {
                OrphanedAutoChargesView(orphans: orphanedAutoCharges)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
                    .preferredColorScheme(appColorScheme())
            }
            .sheet(isPresented: $showPhantomCleanup) {
                PhantomAutoChargesView(phantoms: phantomAutoCharges)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
                    .preferredColorScheme(appColorScheme())
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("recurring.title"))
                    .font(.system(.title, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("recurring.sub"))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            if !expenses.isEmpty {
                Button {
                    HapticManager.shared.tap(); vm.resetForm(); vm.showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(cards.isEmpty ? AppTheme.textSecondary : AppTheme.onVividFill)
                        .frame(width: 44, height: 44)
                        .background(cards.isEmpty ? AppTheme.cardMid : AppTheme.accentFill, in: Circle())
                }
                .accessibilityLabel(loc("a11y.add_recurring"))
                .disabled(cards.isEmpty)
                .buttonStyle(ScaleButtonStyle())
            }
        }
    }

    /// The month at a glance: what bills cost, what is still to leave this
    /// month, and what is next.
    private var summaryCard: some View {
        let cm = CurrencyManager.shared
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(loc("recurring.total"))
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(cm.formatted(monthlyTotal, currency: pref))
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text(String(format: loc("recurring.active_count"), activeExpenses.count))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            HStack(spacing: 10) {
                statTile(label: loc("recurring.remaining_month"),
                         value: cm.formatted(remainingThisMonth, currency: pref),
                         icon: "hourglass", tint: AppTheme.orange)
                if let n = nextDue {
                    statTile(label: loc("recurring.next"),
                             value: n.label,
                             caption: RecurringRowFormat.dueLabel(n),
                             icon: "calendar", tint: AppTheme.blue)
                }
            }
        }
        .padding(18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }

    private func statTile(label: String, value: String, caption: String? = nil,
                          icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: icon)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .labelStyle(TintedIconLabelStyle(tint: tint))
            Text(value)
                .font(.system(.subheadline, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.75)
            if let caption {
                Text(caption)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func cleanupRow(icon: String, tint: Color, title: String, detail: String,
                            action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.tap(); action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(detail)
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.14)).frame(width: 120, height: 120)
                Circle().fill(AppTheme.accentFill).frame(width: 76, height: 76)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(.title, weight: .semibold))
                    .foregroundStyle(AppTheme.onVividFill)
            }
            VStack(spacing: 8) {
                Text(loc("recurring.none_title"))
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(cards.isEmpty ? loc("recurring.none_needs_card") : loc("recurring.none_sub"))
                    .font(.system(.subheadline))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
            }
            if !cards.isEmpty {
                Button {
                    HapticManager.shared.tap(); vm.resetForm(); vm.showAddSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").font(.system(.body))
                        Text(loc("recurring.add")).font(.system(.callout, weight: .bold))
                    }
                    .foregroundStyle(AppTheme.onVividFill)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(.horizontal, 12)
    }
}

/// A label whose icon takes a colour of its own while the text keeps the
/// label's foreground style.
private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

// MARK: - Row

enum RecurringRowFormat {
    static func dueLabel(_ e: RecurringExpense) -> String {
        let d = RecurringDateEngine.daysUntil(dayOfMonth: e.dayOfMonth)
        if d <= 0 { return loc("recurring.due_today") }
        if d == 1 { return loc("recurring.due_tomorrow") }
        return String(format: loc("recurring.due_in"), d)
    }
}

/// Bills as one grouped list. Each row was its own bordered card with a
/// 28pt ⋯ menu squeezed under the amount.
struct RecurringList: View {
    let expenses: [RecurringExpense]
    let onEdit: (RecurringExpense) -> Void
    let onMore: (RecurringExpense) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(expenses.enumerated()), id: \.element.id) { i, e in
                if i > 0 {
                    Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 66)
                }
                RecurringExpenseRow(expense: e, onEdit: { onEdit(e) }, onMore: { onMore(e) })
            }
        }
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }
}

struct RecurringExpenseRow: View {
    let expense: RecurringExpense
    let onEdit: () -> Void
    let onMore: () -> Void

    var body: some View {
        let active = expense.isActive
        let days = RecurringDateEngine.daysUntil(dayOfMonth: expense.dayOfMonth)
        HStack(spacing: 12) {
            Button {
                HapticManager.shared.tap(); onEdit()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: expense.category.icon)
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(active ? expense.category.color : AppTheme.textSecondary)
                        .frame(width: 40, height: 40)
                        .background((active ? expense.category.color : AppTheme.textSecondary).opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: AppRadius.sm))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(expense.label)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(active ? AppTheme.textPrimary : AppTheme.textSecondary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(String(format: loc("recurring.day_of"), expense.dayOfMonth))
                            Text("·")
                            if !active {
                                Text(loc("recurring.paused"))
                            } else {
                                Text(RecurringRowFormat.dueLabel(expense))
                                    .foregroundStyle(days <= 0 ? AppTheme.accent : days <= 3 ? AppTheme.orange : AppTheme.textSecondary)
                                    .fontWeight(days <= 3 ? .semibold : .regular)
                            }
                            if !expense.autoRecord {
                                Text(loc("recurring.manual_badge"))
                                    .font(.system(.caption2, weight: .semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(AppTheme.cardMid.opacity(0.8), in: Capsule())
                            }
                        }
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(CurrencyManager.shared.formatted(expense.amount, currency: expense.currency))
                            .font(.system(.subheadline, weight: .bold))
                            .foregroundStyle(active ? AppTheme.textPrimary : AppTheme.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        if active && expense.chargedThisMonth {
                            Label(loc("recurring.charged_this_month"), systemImage: "checkmark.circle.fill")
                                .font(.system(.caption2, weight: .medium))
                                .foregroundStyle(AppTheme.textSecondary)
                                .labelStyle(TintedIconLabelStyle(tint: AppTheme.accent))
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.cardMid.opacity(0.7), in: Circle())
            }
            .accessibilityLabel(loc("a11y.more_actions"))
            .hitTarget(32)
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(14)
    }
}

// MARK: - Actions & delete

extension View {
    /// The ⋯ sheet and the delete confirmation for a bill, shared by the
    /// overview and the full list so both behave identically.
    func recurringActions(for target: Binding<RecurringExpense?>,
                          vm: RecurringExpenseViewModel,
                          cards: [BankCard]) -> some View {
        modifier(RecurringActionsModifier(target: target, vm: vm, cards: cards))
    }
}

private struct RecurringActionsModifier: ViewModifier {
    @Binding var target: RecurringExpense?
    let vm: RecurringExpenseViewModel
    let cards: [BankCard]
    @Environment(\.modelContext) private var context
    @Query private var allExpenses: [RecurringExpense]
    @State private var deleting: RecurringExpense? = nil

    func body(content: Content) -> some View {
        content
            .sheet(item: $target) { e in
                ActionListSheet(
                    icon: e.category.icon,
                    iconTint: e.category.color,
                    title: e.label,
                    subtitle: CurrencyManager.shared.formatted(e.amount, currency: e.currency)
                        + " · " + String(format: loc("recurring.day_of"), e.dayOfMonth),
                    items: [
                        ActionItem(icon: "pencil", title: loc("common.edit"), tint: AppTheme.blue) {
                            vm.loadForEdit(e, cards: cards)
                        },
                        ActionItem(icon: e.isActive ? "pause.fill" : "play.fill",
                                   title: loc(e.isActive ? "recurring.pause" : "recurring.resume"),
                                   detail: loc(e.isActive ? "recurring.act_pause_sub" : "recurring.act_resume_sub"),
                                   tint: AppTheme.orange) {
                            if !e.isActive { e.markCaughtUp() }
                            e.isActive.toggle()
                            try? context.save()
                            HapticManager.shared.success()
                        },
                        ActionItem(icon: "trash.fill", title: loc("recurring.delete"),
                                   detail: loc("recurring.act_delete_sub"), destructive: true) {
                            deleting = e
                        },
                    ])
                .preferredColorScheme(appColorScheme())
            }
            .sheet(item: $deleting) { e in
                let otherTotal = allExpenses
                    .filter { $0.isActive && $0.id != e.id }
                    .reduce(0.0) { $0 + CurrencyManager.shared.convert($1.amount, from: $1.currency,
                                                                      to: CurrencyManager.shared.preferredCurrency) }
                RecurringDeleteSheet(expense: e,
                                     charges: RecurringHistory.charges(named: e.label, in: cards).map(\.tx),
                                     newMonthlyTotal: otherTotal) { removeHistory in
                    let label = e.label
                    let history = RecurringHistory.charges(named: label, in: cards)
                    deleting = nil
                    // After the sheet has gone: it is still reading this model.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if removeHistory {
                            for (tx, card) in history {
                                card.transactions.removeAll { $0.id == tx.id }
                                context.delete(tx)
                            }
                        } else if !history.isEmpty {
                            RecurringHistory.keep(label)
                        }
                        context.delete(e)
                        try? context.save()
                        HapticManager.shared.success()
                        ActionFeedbackCenter.shared.removed(loc("recurring.deleted_toast"), detail: label)
                    }
                } onCancel: {
                    deleting = nil
                }
                .preferredColorScheme(appColorScheme())
            }
    }
}

/// Says, before anything is removed, what deleting a bill changes and what it
/// does not.
///
/// The answer to "does this affect my balance" is: not by itself. Payments
/// already recorded stay, because they happened. Only if the bill was never
/// really paid should they go too — and then the balance goes back up. That is
/// the user's call to make, so it is a switch here, off by default, rather
/// than a clean-up banner that appeared afterwards with every payment already
/// selected for deletion.
struct RecurringDeleteSheet: View {
    let expense: RecurringExpense
    let charges: [TxRecord]
    let newMonthlyTotal: Double
    let onConfirm: (_ removeHistory: Bool) -> Void
    let onCancel: () -> Void

    @State private var removeHistory = false
    @State private var contentHeight: CGFloat = 460

    private var cm: CurrencyManager { CurrencyManager.shared }
    private var pref: String { cm.preferredCurrency }
    private var historyTotal: Double {
        charges.reduce(0) { $0 + cm.convert(abs($1.amount), from: $1.currency.isEmpty ? pref : $1.currency, to: pref) }
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "trash.fill")
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(AppTheme.onVividFill)
                .frame(width: 56, height: 56)
                .background(AppTheme.red, in: Circle())
                .padding(.top, 8)

            Text(String(format: loc("recurring.delete_title"), expense.label))
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                note("calendar.badge.minus", AppTheme.orange,
                     expense.isActive && expense.autoRecord
                        ? String(format: loc("recurring.del_next"),
                                 RecurringDateEngine.nextDueDate(dayOfMonth: expense.dayOfMonth)
                                    .formatted(.dateTime.day().month(.abbreviated)))
                        : loc("recurring.del_next_manual"))
                if expense.isActive {
                    note("chart.bar.fill", AppTheme.blue,
                         String(format: loc("recurring.del_total"), cm.formatted(newMonthlyTotal, currency: pref)))
                }
                if charges.isEmpty {
                    note("checkmark.circle.fill", AppTheme.accent, loc("recurring.del_no_history"))
                } else if removeHistory {
                    note("arrow.uturn.backward.circle.fill", AppTheme.red,
                         String(format: loc("recurring.del_remove"), charges.count, cm.formatted(historyTotal, currency: pref)))
                } else {
                    note("checkmark.circle.fill", AppTheme.accent,
                         String(format: loc("recurring.del_keep"), charges.count))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            .animation(.easeOut(duration: 0.2), value: removeHistory)

            if !charges.isEmpty {
                Toggle(isOn: $removeHistory) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: loc("recurring.del_toggle"), charges.count))
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(loc("recurring.del_toggle_sub"))
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(AppTheme.red)
                .padding(14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }

            VStack(spacing: 10) {
                Button {
                    onConfirm(removeHistory)
                } label: {
                    Text(loc("common.delete"))
                        .font(.system(.callout, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(AppTheme.red, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                }
                .buttonStyle(ScaleButtonStyle())
                Button {
                    HapticManager.shared.tap(); onCancel()
                } label: {
                    Text(loc("tx.delete_keep"))
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 + 24 }
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.bg)
        .presentationCornerRadius(28)
        .onAppear { HapticManager.shared.warning() }
    }

    private func note(_ icon: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(.subheadline)).foregroundStyle(tint)
                .frame(width: 20)
            Text(text)
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Form Sheet

struct RecurringFormSheet: View {
    @Bindable var vm: RecurringExpenseViewModel
    let context: ModelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    // Needed to answer "what does this do to my plan" while the form is open.
    @Query private var allRecurrings: [RecurringExpense]
    @Query private var salarySchedules: [SalarySchedule]
    @Query private var savingsGoals: [SavingsGoal]
    @Query private var budgetConfigs: [CardBudgetConfig]
    @State private var appeared = false

    private var isEditing: Bool { vm.editing != nil }

    /// The consequence of saving this, computed live as the form is filled.
    private var impact: CommitmentImpact? {
        guard let amount = Double(vm.formAmount), amount > 0 else { return nil }
        let pref = CurrencyManager.shared.preferredCurrency
        let converted = CurrencyManager.shared.convert(amount, from: vm.formCurrency, to: pref)
        return CommitmentImpact.build(proposedAmount: converted,
                                      category: vm.formCategory,
                                      currency: pref,
                                      excludingPlanID: vm.editing?.id,
                                      recurrings: allRecurrings,
                                      salaries: salarySchedules,
                                      goals: savingsGoals,
                                      configs: budgetConfigs)
    }

    /// "≈ Rp 158.000 · $1 = Rp 15.800" when the bill's currency differs from
    /// the card it is paid from. nil when they match or nothing is usable yet.
    private var fxPreview: String? {
        guard let cardID = vm.formCardID,
              let card = cards.first(where: { $0.id == cardID }) else { return nil }
        let target = card.resolvedCurrency
        guard !vm.formCurrency.isEmpty, vm.formCurrency != target else { return nil }
        guard let amount = Double(vm.formAmount), amount > 0 else { return nil }
        let cm = CurrencyManager.shared
        let converted = cm.convert(amount, from: vm.formCurrency, to: target)
        let unitRate  = cm.convert(1, from: vm.formCurrency, to: target)
        return String(format: loc("recurring.fx_preview"),
                      cm.formatted(converted, currency: target),
                      CurrencyManager.symbol(for: vm.formCurrency),
                      cm.formatted(unitRate, currency: target))
    }

    private var dueThisMonth: Date {
        let cal = Calendar.current
        return RecurringDateEngine.dueDate(dayOfMonth: vm.formDay,
                                           month: cal.component(.month, from: .now),
                                           year: cal.component(.year, from: .now))
    }

    private var cardIndex: Binding<Int> {
        Binding(get: { cards.firstIndex { $0.id == vm.formCardID } ?? 0 },
                set: { i in if cards.indices.contains(i) { vm.formCardID = cards[i].id } })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        amountSection
                        IconField(label: loc("recurring.label"),
                                  icon: "text.cursor",
                                  placeholder: loc("recurring.label_ph"),
                                  text: $vm.formLabel)
                            .padding(.horizontal, 22)

                        VStack(alignment: .leading, spacing: 10) {
                            FormSectionLabel(text: loc("recurring.category"))
                                .padding(.horizontal, 22)
                            CategoryTilePicker(categories: RecurringExpenseViewModel.categories,
                                               selection: $vm.formCategory)
                        }

                        daySection
                        cardSection
                        autoRecordSection

                        if let err = vm.formError {
                            InlineBanner(tone: .error, message: err)
                                .padding(.horizontal, 22)
                        }

                        saveButton.padding(.top, 4)
                        Spacer(minLength: 30)
                    }
                    .padding(.top, 8)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                    .animation(AppMotion.appear, value: appeared)
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
            .onAppear {
                // The pager always shows a card, so something must be selected
                // to match it. Currency defaults to that card's for a new bill.
                if vm.formCardID == nil, let first = cards.first {
                    vm.formCardID = first.id
                    if !isEditing { vm.formCurrency = first.currency }
                }
                withAnimation { appeared = true }
            }
            .onChange(of: vm.formCardID) { _, newID in
                // Default only — a USD subscription paid from an IDR card is
                // normal, so the currency stays changeable afterwards.
                if !isEditing, let id = newID, let card = cards.first(where: { $0.id == id }) {
                    vm.formCurrency = card.currency
                }
            }
        }
    }

    private var amountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(vm.currencies, id: \.self) { c in
                        Button(c) { HapticManager.shared.tap(); vm.formCurrency = c }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(CurrencyManager.symbol(for: vm.formCurrency))
                            .font(.system(.subheadline, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(vm.formCurrency)
                            .font(.system(.footnote, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(.caption2)).imageScale(.small)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                }
                TextField("0", text: $vm.formAmount)
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .keyboardType(.decimalPad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))

            if let preview = fxPreview {
                Label(preview, systemImage: "arrow.left.arrow.right")
                    .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
            } else if let p = AmountInputHelper.preview(vm.formAmount, currency: vm.formCurrency) {
                Text(p).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
            }

            // What saving this does to the plan — shown before Save, while the
            // decision is still open.
            if let impact {
                CommitmentImpactPreview(impact: impact, currency: CurrencyManager.shared.preferredCurrency)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 22)
    }

    private var daySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormSectionLabel(text: loc("recurring.due_day"))
            VStack(spacing: 12) {
                PaydayGrid(day: $vm.formDay)
                Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1)
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .frame(width: 32, height: 32)
                        .background(AppTheme.accentFill, in: Circle())
                    Text(String(format: loc("recurring.this_month_on"),
                                dueThisMonth.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer(minLength: 0)
                }
                if vm.formDay >= 29 {
                    Label(loc("recurring.short_month_hint"), systemImage: "info.circle")
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .padding(.horizontal, 22)
    }

    @ViewBuilder
    private var cardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormSectionLabel(text: loc("recurring.charge_to"))
                .padding(.horizontal, 22)
            if cards.isEmpty {
                InlineBanner(tone: .warning, message: loc("recurring.none_needs_card"))
                    .padding(.horizontal, 22)
            } else {
                CardSwipePicker(cards: cards, selectedIndex: cardIndex) { card in
                    card.isCreditCard
                        ? (loc("cc.available"), card.formattedAvailable)
                        : (loc("home.balance_total"), card.formattedBalance)
                }
            }
        }
    }

    private var autoRecordSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(AppTheme.onVividFill)
                .frame(width: 36, height: 36)
                .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.sm))
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("recurring.autorecord_label"))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("recurring.autorecord_sub"))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Toggle("", isOn: $vm.formAutoRecord).labelsHidden().tint(AppTheme.accentFill)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .padding(.horizontal, 22)
    }

    private var saveButton: some View {
        Button {
            guard vm.validate() else { HapticManager.shared.error(); return }
            save()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(.body))
                Text(loc("recurring.save")).font(.system(.callout, weight: .bold))
            }
            .foregroundStyle(AppTheme.onVividFill)
            .frame(maxWidth: .infinity).padding(.vertical, 17)
            .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(ScaleButtonStyle())
        .padding(.horizontal, 22)
    }

    private func save() {
        let amount = Double(vm.formAmount) ?? 0
        let newLabel = vm.formLabel.trimmingCharacters(in: .whitespaces)
        if let e = vm.editing {
            // A rename carries the bill's recorded payments with it. They are
            // tied to the bill only by name, so renaming "Kos" to "Kos Jakarta"
            // used to leave every past payment looking like a leftover from a
            // deleted bill — and offered, pre-selected, for deletion.
            if RecurringHistory.normalized(e.label) != RecurringHistory.normalized(newLabel) {
                for (tx, _) in RecurringHistory.charges(named: e.label, in: cards) { tx.name = newLabel }
            }
            // Turning auto-record back on restarts charging from the next due
            // date. Otherwise every month it was off got charged at once.
            if !e.autoRecord && vm.formAutoRecord { e.markCaughtUp() }
            e.label = newLabel
            e.amount = amount
            e.dayOfMonth = vm.formDay
            e.category = vm.formCategory
            e.currency = vm.formCurrency
            e.cardID = vm.formCardID
            e.autoRecord = vm.formAutoRecord
        } else {
            let e = RecurringExpense(label: newLabel, amount: amount, dayOfMonth: vm.formDay,
                                     category: vm.formCategory, currency: vm.formCurrency, cardID: vm.formCardID)
            e.autoRecord = vm.formAutoRecord
            context.insert(e)
            // A bill with this name is live again, so its payments are not
            // leftovers of a deleted one any more.
            RecurringHistory.forget(newLabel)
        }
        try? context.save()
        HapticManager.shared.success()
        ActionFeedbackCenter.shared.recurringSaved(name: newLabel, amount: amount,
                                                   currency: vm.formCurrency, day: vm.formDay)
        dismiss()
    }
}

// MARK: - All Recurring Expenses (full-list page)

struct AllRecurringExpensesView: View {
    let expenses: [RecurringExpense]
    let cards: [BankCard]
    @Bindable var vm: RecurringExpenseViewModel
    @State private var actionsFor: RecurringExpense? = nil

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                RecurringList(expenses: expenses,
                              onEdit: { vm.loadForEdit($0, cards: cards) },
                              onMore: { HapticManager.shared.tap(); actionsFor = $0 })
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
            }
        }
        .recurringActions(for: $actionsFor, vm: vm, cards: cards)
        .navigationTitle(loc("recurring.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
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
                        Text(loc("recurring.orphan_none")).font(.system(.callout)).foregroundStyle(AppTheme.textSecondary)
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            Text(loc("recurring.orphan_explain"))
                                .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
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
            .doneToolbar { dismiss() }
            .onAppear {
                // Nothing pre-selected. These are payments DiPo recorded for a
                // real bill; most of them happened. Pre-selecting all of them
                // made "restore my balance" the default, which overstates it.
                if !appeared { appeared = true }
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
                    .font(.system(.title3)).foregroundStyle(isOn ? AppTheme.red : AppTheme.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tx.name).font(.system(.subheadline, weight: .medium)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                    Text(tx.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Text(CurrencyManager.shared.formatted(abs(tx.amount), currency: tx.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : tx.currency))
                    .font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
            }
            .padding(12)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
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
                .font(.system(.callout, weight: .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(chosen.isEmpty ? AppTheme.cardMid : AppTheme.red, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(chosen.isEmpty)
        .padding(.horizontal, 22).padding(.bottom, 20)
    }
}

// MARK: - Back-Dated Auto-Charge Cleanup
//
// One-shot repair for rows the auto-engines wrote for dates BEFORE their own
// schedule existed. Both `pendingMonths` implementations bounded catch-up to
// the creation MONTH rather than the creation DAY, so a bill added on the 14th
// with a day-8 due date posted a charge back-dated to the 8th — money that
// never moved through DiPo, filed on a date nobody thinks to check. Both
// engines now carry a day-level guard, but rows already written stay in the
// ledger and keep skewing the balance until they are removed here.
//
// Deliberately NOT the same set as OrphanedAutoChargesView above. That one
// handles charges whose schedule was DELETED; this one handles charges whose
// schedule is alive but younger than the charge. The two can never overlap —
// detecting a back-dated charge requires a live schedule to compare against.
struct PhantomAutoCharge: Identifiable {
    let tx: TxRecord
    let scheduleCreatedAt: Date
    /// Salary credits inflate the balance, recurring charges deflate it, so
    /// removal moves the number in opposite directions. The UI has to say which.
    let isIncome: Bool
    var id: UUID { tx.id }
}

enum PhantomAutoChargeFinder {
    /// Suffix SalaryCreditEngine appends when naming its transactions.
    private static let salarySuffix = " - Salary"

    static func find(cards: [BankCard],
                     expenses: [RecurringExpense],
                     salaries: [SalarySchedule]) -> [PhantomAutoCharge] {
        let cal = Calendar.current

        // Earliest creation date per label. When two schedules share a name we
        // keep the OLDEST: flagging a charge that some older schedule could
        // legitimately have produced is worse than missing one, because the
        // user acts on this list by deleting.
        var expenseCreated: [String: Date] = [:]
        for e in expenses {
            let key = e.label.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            let day = cal.startOfDay(for: e.createdAt)
            expenseCreated[key] = min(expenseCreated[key] ?? day, day)
        }
        var salaryCreated: [String: Date] = [:]
        for s in salaries {
            let key = s.label.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            let day = cal.startOfDay(for: s.createdAt)
            salaryCreated[key] = min(salaryCreated[key] ?? day, day)
        }

        var out: [PhantomAutoCharge] = []
        for card in cards {
            for tx in card.transactions {
                let isIncome: Bool
                let key: String
                switch tx.notes {
                case "tx.note.recurring_auto":
                    isIncome = false
                    key = tx.name.trimmingCharacters(in: .whitespaces).lowercased()
                case "tx.note.salary_auto":
                    isIncome = true
                    var name = tx.name
                    if name.hasSuffix(salarySuffix) { name.removeLast(salarySuffix.count) }
                    key = name.trimmingCharacters(in: .whitespaces).lowercased()
                default:
                    continue   // hand-entered rows are never touched
                }
                let table = isIncome ? salaryCreated : expenseCreated
                // No live schedule → orphan, which the other cleaner owns.
                guard let created = table[key] else { continue }
                guard tx.date < created else { continue }
                out.append(PhantomAutoCharge(tx: tx, scheduleCreatedAt: created, isIncome: isIncome))
            }
        }
        return out.sorted { $0.tx.date > $1.tx.date }
    }
}

struct PhantomAutoChargesView: View {
    let phantoms: [PhantomAutoCharge]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var selected: Set<UUID> = []
    @State private var appeared = false

    private var chosen: [PhantomAutoCharge] { phantoms.filter { selected.contains($0.id) } }

    /// Signed effect on the balance once the chosen rows are gone. Removing a
    /// phantom expense gives money back; removing a phantom salary takes it
    /// away. A single unsigned total would misstate half the cases.
    private var netEffect: Double {
        let pref = CurrencyManager.shared.preferredCurrency
        var total: Double = 0
        for p in chosen {
            let cur = p.tx.currency.isEmpty ? pref : p.tx.currency
            total -= CurrencyManager.shared.convert(p.tx.amount, from: cur, to: pref)
        }
        return total
    }

    private func dayText(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = LanguageManager.shared.currentLocale
        df.dateFormat = DateFormatter.dateFormat(fromTemplate: "d MMM yyyy", options: 0,
                                                 locale: LanguageManager.shared.currentLocale)
        return df.string(from: date)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                if phantoms.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(AppTheme.accent)
                        Text(loc("recurring.phantom_none")).font(.system(.callout)).foregroundStyle(AppTheme.textSecondary)
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            Text(loc("recurring.phantom_explain"))
                                .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22).padding(.bottom, 4)
                            ForEach(phantoms) { p in
                                row(p)
                            }
                            .padding(.horizontal, 22)
                            Spacer(minLength: 130)
                        }
                        .padding(.top, 8)
                    }
                    VStack { Spacer(); footer }
                }
            }
            .navigationTitle(loc("recurring.phantom_nav"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
            .onAppear {
                if !appeared { selected = Set(phantoms.map(\.id)); appeared = true }  // pre-select all
            }
        }
    }

    private func row(_ p: PhantomAutoCharge) -> some View {
        let isOn = selected.contains(p.id)
        let cur = p.tx.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : p.tx.currency
        return Button {
            HapticManager.shared.tap()
            if isOn { selected.remove(p.id) } else { selected.insert(p.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(.title3)).foregroundStyle(isOn ? AppTheme.red : AppTheme.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(p.tx.name)
                            .font(.system(.subheadline, weight: .medium)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                        if p.isIncome {
                            Text(loc("recurring.phantom_income_badge"))
                                .font(.system(.caption2, weight: .semibold))
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(AppTheme.accent.opacity(0.15), in: Capsule())
                        }
                    }
                    // The whole point of the row: the charge date sits before
                    // the schedule's own creation date. Show both, side by side.
                    Text(String(format: loc("recurring.phantom_row"),
                                dayText(p.tx.date), dayText(p.scheduleCreatedAt)))
                        .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Text(CurrencyManager.shared.formatted(abs(p.tx.amount), currency: cur))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(p.isIncome ? AppTheme.accent : AppTheme.textPrimary)
            }
            .padding(12)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if !chosen.isEmpty {
                let up = netEffect >= 0
                Text(String(format: loc(up ? "recurring.phantom_effect_up" : "recurring.phantom_effect_down"),
                            CurrencyManager.shared.formatted(abs(netEffect),
                                                             currency: CurrencyManager.shared.preferredCurrency)))
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(up ? AppTheme.accent : AppTheme.orange)
            }
            Button {
                HapticManager.shared.warning()
                for p in chosen { context.delete(p.tx) }
                try? context.save()
                dismiss()
            } label: {
                Text(String(format: loc("recurring.phantom_delete"), chosen.count))
                    .font(.system(.callout, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(chosen.isEmpty ? AppTheme.cardMid : AppTheme.red, in: RoundedRectangle(cornerRadius: AppRadius.md))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(chosen.isEmpty)
        }
        .padding(.horizontal, 22).padding(.bottom, 20)
    }
}
