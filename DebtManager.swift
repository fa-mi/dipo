import SwiftUI
import SwiftData

// MARK: - Debt SwiftData Model

@Model
final class DebtRecord {
    var id: UUID
    var name: String
    var type: String              // "credit_card", "loan", "installment", "other"
    var totalAmount: Double       // Original debt amount
    var currentBalance: Double    // What's still owed
    var minimumPayment: Double    // Required minimum per month
    var annualInterestRate: Double // e.g. 24.0 for 24% APR
    var dueDayOfMonth: Int        // Payment due date
    var currency: String
    var isActive: Bool
    var createdAt: Date
    var notes: String
    /// Flag set to true the first time a linked payment tx is recorded against
    /// this debt. Used by sync logic to know whether currentBalance is being
    /// managed via tracked transactions (auto-rollback on delete) or manually
    /// (preserve user edits). Default false ensures old data without linked
    /// payments keeps existing behavior.
    var hasBeenTracked: Bool = false

    /// Set when the user taps "Mark as paid" to close a debt outright. Without
    /// it, `syncDebtBalances()` would recompute `currentBalance` from the
    /// linked payment transactions on the next view and *resurrect* a debt the
    /// user explicitly closed (any debt that ever had a tracked payment).
    /// Default false keeps existing data behaving as before.
    var manuallyClosed: Bool = false

    init(name: String, type: String = "credit_card",
         totalAmount: Double, currentBalance: Double,
         minimumPayment: Double, annualInterestRate: Double,
         dueDayOfMonth: Int, currency: String = CurrencyManager.shared.preferredCurrency, notes: String = "") {
        self.id = UUID()
        self.name = name
        self.type = type
        self.totalAmount = totalAmount
        self.currentBalance = currentBalance
        self.minimumPayment = minimumPayment
        self.annualInterestRate = annualInterestRate
        self.dueDayOfMonth = dueDayOfMonth
        self.currency = currency
        self.isActive = true
        self.createdAt = .now
        self.notes = notes
    }

    var debtType: DebtType {
        get { DebtType(rawValue: type) ?? .other }
        set { type = newValue.rawValue }
    }

    var monthlyInterestRate: Double { annualInterestRate / 12.0 / 100.0 }

    var monthlyInterestCost: Double { currentBalance * monthlyInterestRate }

    /// Minimum payment to use for *planning* (salary allocation, months-to-
    /// payoff, reminders). Users very often leave `minimumPayment` at 0 —
    /// especially for 0% APR installments (Kredivo, Akulaku, Home Credit) that
    /// don't print a formal minimum. Taking that 0 literally makes the whole
    /// planner recommend paying nothing toward a real outstanding balance,
    /// which is the opposite of what a debt tracker should do. When no minimum
    /// is set we derive a sensible one from the balance:
    ///   • interest-bearing: cover the monthly interest + 1% of principal
    ///     (typical credit-card minimum — guarantees the balance shrinks)
    ///   • 0% APR: clear the balance over ~12 months (reasonable default
    ///     horizon when the real term is unknown)
    /// Returns 0 only when nothing is actually owed.
    var effectiveMinimumPayment: Double {
        if minimumPayment > 0 { return minimumPayment }
        guard currentBalance > 0 else { return 0 }
        let derived = annualInterestRate > 0
            ? monthlyInterestCost + currentBalance * 0.01
            : currentBalance / 12.0
        // Never suggest paying more than what's still owed.
        return min(derived, currentBalance)
    }

    /// True when `effectiveMinimumPayment` is app-derived (user left the
    /// minimum at 0). UI uses this to label the figure "Suggested" rather than
    /// misrepresenting it as a lender-required minimum.
    var isMinimumDerived: Bool { minimumPayment <= 0 && currentBalance > 0 }
    
    /// Sums all linked debt-payment transactions across all cards. Converts each
    /// payment to this debt's currency. This is the single source of truth for
    /// "how much has been paid" — kept as a function so callers must pass in the
    /// transactions they have access to (no global lookup from inside the model).
    func totalPaidFrom(_ allTransactions: [TxRecord]) -> Double {
        let idStr = id.uuidString
        return allTransactions
            .filter { $0.linkedDebtID == idStr && $0.amount < 0 }
            .reduce(0.0) { sum, tx in
                let txCur = tx.currency.isEmpty ? currency : tx.currency
                return sum + CurrencyManager.shared.convert(abs(tx.amount), from: txCur, to: currency)
            }
    }
    
    /// The TRUE balance: original amount minus all linked payments still in the DB.
    /// When a payment tx is deleted, this automatically reflects the rollback —
    /// no manual sync needed. This is what should be displayed in the UI.
    func effectiveBalance(from allTransactions: [TxRecord]) -> Double {
        max(0, totalAmount - totalPaidFrom(allTransactions))
    }
    
    /// Months to payoff at minimum payment (returns nil if payment < interest
    /// or input is invalid). Delegates to `monthsToPayoff(monthlyPayment:)` so
    /// both paths share the same defensive guards and 0% APR handling.
    var monthsToPayoffMinimum: Int? {
        monthsToPayoff(monthlyPayment: effectiveMinimumPayment)
    }

    /// Months to payoff at a given monthly payment. Returns nil for any invalid
    /// input (zero/negative payment, zero/negative balance, payment ≤ monthly
    /// interest, or any calculation producing NaN/infinity). Callers render "N/A"
    /// for nil — crashing the app on edge inputs is never acceptable here.
    ///
    /// Previous crash: `Int(ceil(currentBalance / 0))` = `Int(.infinity)` when a
    /// 0% APR debt had minimumPayment = 0 and the simulator was opened.
    func monthsToPayoff(monthlyPayment: Double) -> Int? {
        // Invalid inputs → nil. Without these guards, the math below can produce
        // .infinity or .nan, which fatal-errors when cast to Int.
        guard monthlyPayment > 0, currentBalance > 0 else { return nil }

        let r = monthlyInterestRate

        // Zero-interest case (common for Indonesian installment plans like
        // Akulaku, Kredivo, Home Credit). Safe now that monthlyPayment > 0.
        if r == 0 {
            let months = ceil(currentBalance / monthlyPayment)
            guard months.isFinite, months < Double(Int.max) else { return nil }
            return Int(months)
        }

        // Payment must exceed the monthly interest charge, otherwise the debt
        // never decreases → log(≤0) = NaN/-infinity.
        guard monthlyPayment > currentBalance * r else { return nil }

        let months = -log(1 - currentBalance * r / monthlyPayment) / log(1 + r)

        // Final safety net: when monthlyPayment is only fractionally above the
        // interest cost, `months` can overflow Int even though each intermediate
        // step was finite. isFinite + range check guarantees the Int cast is safe.
        guard months.isFinite, months >= 0, months < Double(Int.max) else { return nil }

        return Int(ceil(months))
    }

    /// Total interest paid at minimum payment
    var totalInterestAtMinimum: Double {
        guard let m = monthsToPayoffMinimum else { return currentBalance * 0.5 }
        return (effectiveMinimumPayment * Double(m)) - currentBalance
    }

    var payoffDate: Date? {
        guard let months = monthsToPayoffMinimum else { return nil }
        return Calendar.current.date(byAdding: .month, value: months, to: .now)
    }

    var percentagePaid: Double {
        guard totalAmount > 0 else { return 0 }
        return min(max(((totalAmount - currentBalance) / totalAmount) * 100, 0), 100)
    }
}

enum DebtType: String, CaseIterable {
    case creditCard  = "credit_card"
    case loan        = "loan"
    case installment = "installment"
    case other       = "other"

    var label: String {
        switch self {
        // Was hardcoded English on every debt card, in both languages.
        case .creditCard:  return loc("debt.type.credit_card")
        case .loan:        return loc("debt.type.loan")
        case .installment: return loc("debt.type.installment")
        case .other:       return loc("debt.type.other")
        }
    }

    var icon: String {
        switch self {
        case .creditCard:  return "creditcard.fill"
        case .loan:        return "building.columns.fill"
        case .installment: return "cart.fill"
        case .other:       return "banknote.fill"
        }
    }

    var color: Color {
        switch self {
        // Credit card = purple, as its badge is everywhere else in the app.
        case .creditCard:  return AppTheme.purple
        case .loan:        return AppTheme.blue
        case .installment: return AppTheme.orange
        case .other:       return AppTheme.textSecondary
        }
    }
}

// MARK: - Financial Health Engine

/// What the Debts screen knows about the debts themselves: what is owed, what
/// it asks for each month, which to pay first, and what Smart Budget advises
/// doing with its savings & debt share.
///
/// It used to score "financial health" out of 100, and the score took points
/// off for this pay period's spending. The screen showed "Very healthy" and,
/// right under it, a warning that the period was Rp 1.175.718 over plan —
/// and a four-way split of the salary that is Smart Budget's own screen. How
/// a pay period is going is Statistics' question. Whether a usual month can
/// carry these payments is `DebtAffordability`; this engine no longer reads
/// spending at all.
struct FinancialHealthEngine {

    // MARK: Inputs
    let monthlyIncome: Double
    let debts: [DebtRecord]
    /// Smart Budget's Invest & Debt share, PASSED IN rather than read from the
    /// singleton — the ratio can be overridden per card, and reading the global
    /// one makes those overrides invisible exactly where they matter most.
    /// Default matches the app's own starting ratio for callers that predate it.
    var investDebtRatio: Double = 0.20
    /// Owed on credit cards, in the preferred currency, and what they ask for
    /// each month (instalments plus the minimum on a carried balance). Cards
    /// are accounts, not DebtRecords, so this engine used to miss them
    /// entirely: Rp 8 jt on a card read as "Total you owe Rp 0 — no active
    /// debts". The caller leaves both at zero when a credit-card debt is
    /// already recorded by hand, which would be the same money twice.
    var cardOwed: Double = 0
    var cardMonthly: Double = 0
    /// Of `cardOwed`, what is carried over from earlier bills — the part
    /// charged interest, and the part the monthly payment is worked out on.
    /// The rest is this month's and last month's shopping, not yet due.
    var cardCarried: Double = 0

    // MARK: - Core Calculations

    /// Total active debt expressed in the user's preferred currency.
    /// Each debt carries its own currency (USD credit card vs IDR KPR), so we
    /// convert before summing — naive addition would mix units (Rp 500jt +
    /// $5k = "500,005,000" — nonsense).
    var totalDebt: Double {
        let pref = CurrencyManager.shared.preferredCurrency
        return debts.filter { $0.isActive }.reduce(cardOwed) {
            $0 + CurrencyManager.shared.convert($1.currentBalance, from: $1.currency, to: pref)
        }
    }
    var totalMinimumPayments: Double {
        let pref = CurrencyManager.shared.preferredCurrency
        return debts.filter { $0.isActive }.reduce(cardMonthly) {
            $0 + CurrencyManager.shared.convert($1.minimumPayment, from: $1.currency, to: pref)
        }
    }

    /// Anything owed at all — a recorded debt or a card balance.
    var hasAnyDebt: Bool { debts.contains(where: \.isActive) || cardOwed >= 0.5 }

    /// Sum of each active debt's *effective* minimum (the planning figure that
    /// never collapses to 0 while a balance is still owed) — "Pay each month"
    /// on the screen, and the payments `DebtAffordability` weighs. DTI
    /// deliberately keeps using `totalMinimumPayments` (the *real* contractual
    /// obligation).
    var totalEffectiveMinimums: Double {
        let pref = CurrencyManager.shared.preferredCurrency
        return debts.filter { $0.isActive }.reduce(cardMonthly) {
            $0 + CurrencyManager.shared.convert($1.effectiveMinimumPayment, from: $1.currency, to: pref)
        }
    }

    /// Debt-to-Income Ratio (monthly debt payments / monthly income)
    var dtiRatio: Double {
        guard monthlyIncome > 0 else { return 0 }
        return (totalMinimumPayments / monthlyIncome) * 100
    }

    /// AVALANCHE ORDER: highest interest rate first (saves most money)
    var avalancheOrder: [DebtRecord] {
        debts.filter { $0.isActive }.sorted { $0.annualInterestRate > $1.annualInterestRate }
    }

    /// SNOWBALL ORDER: smallest balance first (psychological wins)
    var snowballOrder: [DebtRecord] {
        debts.filter { $0.isActive }.sorted { $0.currentBalance < $1.currentBalance }
    }

    // MARK: - Smart Budget: debt before saving

    /// Smart Budget's savings & debt share of the month. Debt payments come
    /// OUT of it — they do not sit beside it.
    var savingsAndDebtShare: Double { monthlyIncome * investDebtRatio }

    /// The debt to clear before saving or investing, by the Financial
    /// ladder's rule: the dearest debt at `FinancialLadder.costlyRate` a year
    /// or more, else a card balance carried over from earlier bills. Nil when
    /// nothing owed charges that much — then saving alongside is fine.
    var payFirst: DebtFirstAdvice.Target? {
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        if let d = avalancheOrder.first(where: { !$0.manuallyClosed && $0.currentBalance > 0
                                                 && $0.annualInterestRate >= FinancialLadder.costlyRate }) {
            return .debt(name: d.name, annualRate: d.annualInterestRate,
                         balance: cm.convert(d.currentBalance, from: d.currency, to: pref),
                         minimum: cm.convert(d.effectiveMinimumPayment, from: d.currency, to: pref))
        }
        return cardCarried >= 0.5 ? .card(carried: cardCarried) : nil
    }

    /// What Smart Budget advises doing with its savings & debt share.
    var debtFirst: DebtFirstAdvice {
        DebtFirstAdvice(share: savingsAndDebtShare, ratio: investDebtRatio,
                        minimums: totalEffectiveMinimums, target: payFirst,
                        cardRecentOnly: cardOwed >= 0.5 && cardCarried < 0.5)
    }

    var urgentDebts: [DebtRecord] {
        let cal = Calendar.current
        let today = cal.component(.day, from: .now)
        return debts.filter { $0.isActive && abs($0.dueDayOfMonth - today) <= 5 }
    }
}

// MARK: - Debt ViewModel

@Observable
final class DebtViewModel {
    var showAddSheet     = false
    var editingDebt: DebtRecord? = nil
    var formName         = ""
    var formType         = DebtType.creditCard
    var formTotal        = ""
    var formBalance      = ""
    var formMinPayment   = ""
    var formInterestRate = ""
    var formDueDay       = 15
    var formCurrency     = CurrencyManager.shared.preferredCurrency
    var formNotes        = ""
    var formError: String? = nil

    let currencies = ["USD", "IDR"]

    var isEditing: Bool { editingDebt != nil }

    func resetForm() {
        formName = ""; formTotal = ""; formBalance = ""
        formMinPayment = ""; formInterestRate = ""
        formDueDay = 15; formCurrency = CurrencyManager.shared.preferredCurrency; formNotes = ""
        formType = .creditCard; formError = nil
        editingDebt = nil
    }

    func loadForEdit(_ d: DebtRecord) {
        formName = d.name; formType = d.debtType
        formTotal = NumberInput.text(d.totalAmount); formBalance = NumberInput.text(d.currentBalance)
        formMinPayment = NumberInput.text(d.minimumPayment)
        formInterestRate = NumberInput.text(d.annualInterestRate)
        formDueDay = d.dueDayOfMonth; formCurrency = d.currency; formNotes = d.notes
        editingDebt = d
        showAddSheet = true
    }

    func validate() -> Bool {
        guard !formName.trimmingCharacters(in: .whitespaces).isEmpty else {
            formError = loc("debt.error.name"); return false
        }
        guard NumberInput.isNumber(formBalance) else { formError = loc("debt.error.balance"); return false }
        guard NumberInput.isNumber(formMinPayment) else { formError = loc("debt.error.min_payment"); return false }
        guard NumberInput.isNumber(formInterestRate) else { formError = loc("debt.error.rate"); return false }
        formError = nil; return true
    }
}

// MARK: - Debt Notification Scheduler
//
// The device-side timeline for debt due dates: pushes scheduled ahead of
// time (3 days, 1 day, the morning of), so they fire whether or not DiPo is
// opened in between. The Notifications inbox entry, with its advice, comes
// from NotificationManager.scheduleDebtReminders, which calls this too and
// no longer pushes on its own, so a due date is announced once.
//
// It used to push in English whatever the app language, ignore the "Debt due
// dates" switch and the Royal gate, keep reminding for debts already paid off,
// and never cancel a deleted debt's reminders (it removed "debt_<id>", while
// the requests were "debt_<id>_3d", "_1d" and "_due").

import UserNotifications

struct DebtNotificationScheduler {

    /// One scheduled push, built on the main actor and handed to the
    /// notification center as plain values.
    struct Planned: Sendable {
        let id: String
        let title: String
        let body: String
        let debtId: String
        let fire: DateComponents
    }

    static let idPrefix = "debt_"

    static func scheduleAll(debts: [DebtRecord]) {
        let enabled = NotificationPreferences.shared.isEnabled(.debt)
            && PremiumManager.shared.canAccess(.smartDebt)
        let planned = enabled ? plan(debts: debts, now: .now, cal: .current) : []
        Task {
            let center = UNUserNotificationCenter.current()
            // Everything DiPo scheduled for debts before, including debts that
            // have since been deleted or paid off.
            let stale = await center.pendingNotificationRequests()
                .map(\.identifier).filter { $0.hasPrefix(idPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            for p in planned {
                let content = UNMutableNotificationContent()
                content.title = p.title
                content.body = p.body
                content.sound = .dipo
                content.userInfo = ["debtId": p.debtId]
                let trigger = UNCalendarNotificationTrigger(dateMatching: p.fire, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: p.id, content: content, trigger: trigger))
            }
        }
    }

    /// The pushes still ahead for every debt that is still owed.
    static func plan(debts: [DebtRecord], now: Date, cal: Calendar) -> [Planned] {
        var out: [Planned] = []
        for debt in debts where debt.isActive && !debt.manuallyClosed && debt.currentBalance > 0 {
            let due = nextDueDate(day: debt.dueDayOfMonth, onOrAfter: now, cal: cal)
            let dayOfMonth = cal.component(.day, from: due)
            let amount = CurrencyManager.shared.formatted(debt.effectiveMinimumPayment, currency: debt.currency)
            let id = debt.id.uuidString
            let steps: [(suffix: String, daysBefore: Int, hour: Int, title: String, body: String)] = [
                ("3d", 3, 9, String(format: loc("notif.debt_due_in_days_title"), 3),
                 String(format: loc("notif.debt_due_body"), debt.name, amount, dayOfMonth)),
                ("1d", 1, 9, loc("notif.debt_due_tomorrow_title"),
                 String(format: loc("notif.debt_due_body"), debt.name, amount, dayOfMonth)),
                ("due", 0, 8, loc("notif.debt_due_today_title"),
                 String(format: loc("notif.debt_due_today_body"), debt.name, amount)),
            ]
            for step in steps {
                let day = cal.date(byAdding: .day, value: -step.daysBefore, to: due) ?? due
                var fire = cal.dateComponents([.year, .month, .day], from: day)
                fire.hour = step.hour
                fire.minute = 0
                guard let when = cal.date(from: fire), when > now else { continue }
                out.append(Planned(id: "\(idPrefix)\(id)_\(step.suffix)", title: step.title,
                                   body: step.body, debtId: id, fire: fire))
            }
        }
        return out
    }

    /// The next time `day` comes round, today included. A due day past the
    /// end of a month (31 in April, 29–31 in February) falls on that month's
    /// last day instead of spilling into the next month.
    static func nextDueDate(day: Int, onOrAfter now: Date, cal: Calendar) -> Date {
        let today = cal.startOfDay(for: now)
        func due(inMonthOf date: Date) -> Date {
            let start = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
            let length = cal.range(of: .day, in: .month, for: start)?.count ?? 28
            return cal.date(byAdding: .day, value: min(max(day, 1), length) - 1, to: start) ?? start
        }
        let thisMonth = due(inMonthOf: today)
        if thisMonth >= today { return thisMonth }
        let nextMonth = cal.date(byAdding: .month, value: 1, to: today) ?? today
        return due(inMonthOf: nextMonth)
    }
}
