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
    
    /// Percentage paid based on linked transactions. Always reflects the current
    /// state of the DB — deleted payments are auto-reverted.
    func effectivePercentagePaid(from allTransactions: [TxRecord]) -> Double {
        guard totalAmount > 0 else { return 0 }
        return min(max((totalPaidFrom(allTransactions) / totalAmount) * 100, 0), 100)
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

struct FinancialHealthEngine {

    // MARK: Inputs
    let monthlyIncome: Double
    let debts: [DebtRecord]
    let monthlyExpenses: Double
    /// Rent, subscriptions, standing transfers — money already spoken for
    /// before any decision is made this month. Defaults to zero so existing
    /// call sites keep their behaviour.
    var fixedCommitments: Double = 0
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

    /// Spending measured against `safeSpendingBudget`, from `start`.
    ///
    /// Left out, because the allowance already accounts for them: transfers,
    /// debt payments, money put into savings (the set-aside), and posted
    /// recurring bills (the plan total in `fixedCommitments`). Counting a
    /// posted bill here as well told Fahmi to cut Rp 3.880.707 when kos, the
    /// transfer to Mom and the subscriptions — Rp 3.805.000 posted — were
    /// simply counted twice; the honest gap was about Rp 76.000.
    static func planSpending(_ txs: [TxRecord], from start: Date, currency pref: String) -> Double {
        txs.filter {
            $0.amount < 0 &&
            $0.txSubtype != .transfer &&
            $0.category != .debtPayment &&
            $0.category != .investment &&
            $0.notes != "tx.note.recurring_auto" &&
            $0.date >= start
        }.reduce(0) { sum, tx in
            let txCur = tx.currency.isEmpty ? pref : tx.currency
            return sum + CurrencyManager.shared.convert(abs(tx.amount), from: txCur, to: pref)
        }
    }

    /// Anything owed at all — a recorded debt or a card balance.
    var hasAnyDebt: Bool { debts.contains(where: \.isActive) || cardOwed >= 0.5 }
    var totalMonthlyInterest: Double {
        let pref = CurrencyManager.shared.preferredCurrency
        return debts.filter { $0.isActive }.reduce(0) {
            $0 + CurrencyManager.shared.convert($1.monthlyInterestCost, from: $1.currency, to: pref)
        }
    }

    /// Sum of each active debt's *effective* minimum (the planning figure that
    /// never collapses to 0 while a balance is still owed). This is what the
    /// salary allocation recommendation is built on, so a debt with no user-set
    /// minimum still gets a sensible payoff allocation that shrinks as the
    /// balance is paid down. DTI deliberately keeps using `totalMinimumPayments`
    /// (the *real* contractual obligation) — DTI measures what you must pay, not
    /// what we advise.
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

    /// Remaining after minimum debt payments + expenses
    var discretionaryIncome: Double {
        monthlyIncome - totalMinimumPayments - monthlyExpenses
    }

    /// SMART FORMULA: Recommended % of salary to allocate to debt
    /// Based on: DTI severity + interest cost + payoff acceleration
    var recommendedDebtAllocationPercent: Double {
        guard monthlyIncome > 0 else { return 0 }

        // Base = effective minimum payments percentage. Using the *effective*
        // total (not the raw one) is what makes the plan recommend real
        // progress on debts whose minimum is 0 — and makes the recommendation
        // respond as the balance is paid down.
        let minPct = (totalEffectiveMinimums / monthlyIncome) * 100

        // Add buffer based on DTI severity
        let buffer: Double
        switch dtiRatio {
        case 0..<20:  buffer = 0       // Healthy — minimums are fine
        case 20..<35: buffer = 5       // Moderate — add 5% extra
        case 35..<50: buffer = 12      // Stressed — add 12% extra
        default:      buffer = 20      // Danger — add 20% extra
        }

        // Extra weight if high interest is eating income
        let interestWeight = min((totalMonthlyInterest / monthlyIncome) * 100 * 1.5, 15)

        return min(minPct + buffer + interestWeight, 70) // cap at 70%
    }

    /// Actual recommended monthly debt payment in currency
    var recommendedMonthlyDebtPayment: Double {
        (recommendedDebtAllocationPercent / 100) * monthlyIncome
    }

    /// Extra payment above minimums available to accelerate debt
    var extraPaymentAvailable: Double {
        max(recommendedMonthlyDebtPayment - totalEffectiveMinimums, 0)
    }

    /// AVALANCHE ORDER: highest interest rate first (saves most money)
    var avalancheOrder: [DebtRecord] {
        debts.filter { $0.isActive }.sorted { $0.annualInterestRate > $1.annualInterestRate }
    }

    /// SNOWBALL ORDER: smallest balance first (psychological wins)
    var snowballOrder: [DebtRecord] {
        debts.filter { $0.isActive }.sorted { $0.currentBalance < $1.currentBalance }
    }

    /// Recommended safe spending budget (after debt allocation)
    /// Smart Budget's Invest & Debt share. Debt payments come OUT of this
    /// bucket — they do not sit beside it.
    var investDebtAllowance: Double { monthlyIncome * investDebtRatio }

    /// Money that must leave the "spendable" pile before anything is called
    /// free: the whole Invest & Debt allocation, or the debt minimums if those
    /// are larger (a minimum has to be paid whatever the plan says).
    var setAside: Double { max(investDebtAllowance, recommendedMonthlyDebtPayment) }

    /// The part of the set-aside that isn't going to debt — savings and
    /// investing. With no debt this is the entire 20%, and it is emphatically
    /// not spending money.
    var toSaveOrInvest: Double { max(setAside - recommendedMonthlyDebtPayment, 0) }

    /// What is genuinely free to spend.
    ///
    /// Two things used to be missing here, and the second was the worse one.
    /// Fixed commitments were treated as discretionary, so a user with Rp 3,7jt
    /// of rent and subscriptions was told the whole Rp 10jt was theirs. And the
    /// Invest & Debt allocation was never set aside at all: with no active debt
    /// `recommendedMonthlyDebtPayment` is zero, so the 20% meant for saving and
    /// investing silently became spending money. The plan said 20% to the
    /// future and the number underneath handed it back.
    var safeSpendingBudget: Double {
        max(monthlyIncome - fixedCommitments - setAside, 0)
    }

    /// Share of income left free, for the allocation bar.
    var safeSpendingPercent: Double {
        guard monthlyIncome > 0 else { return 0 }
        return safeSpendingBudget / monthlyIncome * 100
    }

    var setAsidePercent: Double {
        guard monthlyIncome > 0 else { return 0 }
        return min(toSaveOrInvest / monthlyIncome * 100, 100)
    }

    /// Share of income taken by fixed commitments.
    var commitmentPercent: Double {
        guard monthlyIncome > 0 else { return 0 }
        return min(fixedCommitments / monthlyIncome * 100, 100)
    }

    /// Safe expense threshold (warning if expenses exceed this)
    /// Extra income that landed this cycle beyond the salary — a bonus, THR,
    /// a freelance payment. It funds spending as surely as salary does, so
    /// judging a cycle without it calls a bonus month a blowout.
    var extraIncomeThisCycle: Double = 0

    /// What was actually available to spend this cycle.
    var effectiveAllowance: Double { safeSpendingBudget + extraIncomeThisCycle }

    var isOverspending: Bool { monthlyExpenses > effectiveAllowance }

    /// How much over the safe budget
    var overspendAmount: Double { max(monthlyExpenses - effectiveAllowance, 0) }

    // MARK: - Financial Health Score (0-100)

    var healthScore: Int {
        let activeDebts = debts.filter { $0.isActive }

        // If no income data at all, use a debt-only score
        // based purely on total debt load and interest rates
        if monthlyIncome <= 0 {
            if activeDebts.isEmpty && cardOwed < 0.5 { return 100 }
            // Score based on average interest rate and number of debts
            let avgAPR = activeDebts.isEmpty ? 0
                : activeDebts.reduce(0.0) { $0 + $1.annualInterestRate } / Double(activeDebts.count)
            let totalDebt = totalDebt
            var score = 100.0
            // Heavy penalty for high interest (e.g. 24% APR → -48 pts capped at -50)
            score -= min(avgAPR * 2.0, 50)
            // Penalty for having multiple debts
            score -= min(Double(max(activeDebts.count - 1, 0)) * 5, 20)
            // Penalty for large absolute debt (rough heuristic: Rp 10M+ is significant)
            if totalDebt > 10_000_000 { score -= 10 }
            else if totalDebt > 1_000_000 { score -= 5 }
            return max(Int(score), 0)
        }

        var score = 100.0

        // DTI component (max -40 pts)
        let dtiPenalty = min(dtiRatio * 0.8, 40)
        score -= dtiPenalty

        // Overspending component (max -25 pts)
        if isOverspending && monthlyIncome > 0 {
            let overspendPct = (overspendAmount / monthlyIncome) * 100
            score -= min(overspendPct * 0.5, 25)
        }

        // High interest cost penalty (max -20 pts)
        if monthlyIncome > 0 {
            let interestPct = (totalMonthlyInterest / monthlyIncome) * 100
            score -= min(interestPct * 2, 20)
        }

        // No savings penalty (max -15 pts)
        if discretionaryIncome < 0 { score -= 15 }
        else if monthlyIncome > 0 {
            let savingsRate = (discretionaryIncome / monthlyIncome) * 100
            if savingsRate < 10 { score -= 8 }
        }

        return max(Int(score), 0)
    }

    var healthLabel: String {
        switch healthScore {
        case 80...100: return loc("debt.health.excellent")
        case 60..<80:  return loc("debt.health.good")
        case 40..<60:  return loc("debt.health.fair")
        case 20..<40:  return loc("debt.health.poor")
        default:       return loc("debt.health.critical")
        }
    }

    var healthColor: Color {
        switch healthScore {
        // Two reds for "poor" and "critical" were indistinguishable at a
        // glance; the label already says which. One red, adaptive hues.
        case 80...100: return AppTheme.accent
        case 60..<80:  return AppTheme.blue
        case 40..<60:  return AppTheme.orange
        default:       return AppTheme.red
        }
    }

    var healthIcon: String {
        switch healthScore {
        case 80...100: return "checkmark.seal.fill"
        case 60..<80:  return "chart.line.uptrend.xyaxis"
        case 40..<60:  return "exclamationmark.triangle.fill"
        default:       return "xmark.seal.fill"
        }
    }

    // MARK: - Smart Advice

    var primaryAdvice: String {
        if debts.filter({ $0.isActive }).isEmpty {
            // A card balance is still money owed.
            if cardOwed >= 0.5 {
                return String(format: loc("debt.advice.card_only"),
                              CurrencyManager.shared.formatted(cardOwed, currency: CurrencyManager.shared.preferredCurrency))
            }
            return loc("debt.advice.no_active")
        }
        if monthlyIncome <= 0 {
            if let highestInterest = avalancheOrder.first {
                return String(format: loc("debt.advice.no_salary_focus"),
                              highestInterest.name,
                              String(format: "%.1f", highestInterest.annualInterestRate))
            }
            return loc("debt.advice.no_salary")
        }
        if dtiRatio > 50 {
            return loc("debt.advice.dti_too_high")
        }
        if isOverspending {
            return String(format: loc("debt.advice.overspending"),
                          CurrencyManager.shared.formatted(overspendAmount, currency: CurrencyManager.shared.preferredCurrency))
        }
        if let highestInterest = avalancheOrder.first {
            // "Save the most interest" is meaningless when nothing charges
            // interest — give 0% APR debts a payoff-pace nudge instead.
            if highestInterest.annualInterestRate <= 0 {
                return String(format: loc("debt.advice.zero_interest_focus"),
                              highestInterest.name)
            }
            return String(format: loc("debt.advice.focus_extra"),
                          highestInterest.name,
                          String(format: "%.1f", highestInterest.annualInterestRate))
        }
        return String(format: loc("debt.advice.on_track"),
                      String(format: "%.0f", recommendedDebtAllocationPercent))
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
