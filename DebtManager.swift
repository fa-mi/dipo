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
        monthsToPayoff(monthlyPayment: minimumPayment)
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
        return (minimumPayment * Double(m)) - currentBalance
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
        case .creditCard:  return "Credit Card"
        case .loan:        return "Loan"
        case .installment: return "Installment"
        case .other:       return "Other"
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
        case .creditCard:  return Color(hex: "#FF6B6B")
        case .loan:        return Color(hex: "#A78BFA")
        case .installment: return Color(hex: "#FB923C")
        case .other:       return Color(hex: "#8A9693")
        }
    }
}

// MARK: - Financial Health Engine

struct FinancialHealthEngine {

    // MARK: Inputs
    let monthlyIncome: Double
    let debts: [DebtRecord]
    let monthlyExpenses: Double

    // MARK: - Core Calculations

    /// Total active debt expressed in the user's preferred currency.
    /// Each debt carries its own currency (USD credit card vs IDR KPR), so we
    /// convert before summing — naive addition would mix units (Rp 500jt +
    /// $5k = "500,005,000" — nonsense).
    var totalDebt: Double {
        let pref = CurrencyManager.shared.preferredCurrency
        return debts.filter { $0.isActive }.reduce(0) {
            $0 + CurrencyManager.shared.convert($1.currentBalance, from: $1.currency, to: pref)
        }
    }
    var totalMinimumPayments: Double {
        let pref = CurrencyManager.shared.preferredCurrency
        return debts.filter { $0.isActive }.reduce(0) {
            $0 + CurrencyManager.shared.convert($1.minimumPayment, from: $1.currency, to: pref)
        }
    }
    var totalMonthlyInterest: Double {
        let pref = CurrencyManager.shared.preferredCurrency
        return debts.filter { $0.isActive }.reduce(0) {
            $0 + CurrencyManager.shared.convert($1.monthlyInterestCost, from: $1.currency, to: pref)
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

        // Base = minimum payments percentage
        let minPct = (totalMinimumPayments / monthlyIncome) * 100

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
        max(recommendedMonthlyDebtPayment - totalMinimumPayments, 0)
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
    var safeSpendingBudget: Double {
        monthlyIncome - recommendedMonthlyDebtPayment
    }

    /// Safe expense threshold (warning if expenses exceed this)
    var isOverspending: Bool { monthlyExpenses > safeSpendingBudget }

    /// How much over the safe budget
    var overspendAmount: Double { max(monthlyExpenses - safeSpendingBudget, 0) }

    // MARK: - Financial Health Score (0-100)

    var healthScore: Int {
        let activeDebts = debts.filter { $0.isActive }

        // If no income data at all, use a debt-only score
        // based purely on total debt load and interest rates
        if monthlyIncome <= 0 {
            if activeDebts.isEmpty { return 100 }
            // Score based on average interest rate and number of debts
            let avgAPR = activeDebts.reduce(0.0) { $0 + $1.annualInterestRate } / Double(activeDebts.count)
            let totalDebt = totalDebt
            var score = 100.0
            // Heavy penalty for high interest (e.g. 24% APR → -48 pts capped at -50)
            score -= min(avgAPR * 2.0, 50)
            // Penalty for having multiple debts
            score -= min(Double(activeDebts.count - 1) * 5, 20)
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
        case 80...100: return Color(hex: "#5EFFC8")
        case 60..<80:  return Color(hex: "#38BDF8")
        case 40..<60:  return Color(hex: "#FB923C")
        case 20..<40:  return Color(hex: "#FF6B6B")
        default:       return Color(hex: "#FF3366")
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
        formTotal = String(d.totalAmount); formBalance = String(d.currentBalance)
        formMinPayment = String(d.minimumPayment)
        formInterestRate = String(d.annualInterestRate)
        formDueDay = d.dueDayOfMonth; formCurrency = d.currency; formNotes = d.notes
        editingDebt = d
        showAddSheet = true
    }

    func validate() -> Bool {
        guard !formName.trimmingCharacters(in: .whitespaces).isEmpty else {
            formError = "Enter a name"; return false
        }
        let norm: (String) -> String = { $0.replacingOccurrences(of: ",", with: ".") }
        guard Double(norm(formBalance)) != nil else { formError = "Enter current balance"; return false }
        guard Double(norm(formMinPayment)) != nil else { formError = "Enter minimum payment"; return false }
        guard Double(norm(formInterestRate)) != nil else { formError = "Enter interest rate"; return false }
        formError = nil; return true
    }
}

// MARK: - Debt Notification Scheduler
// Schedules iOS local push notifications for upcoming debt due dates

import UserNotifications

struct DebtNotificationScheduler {

    static func scheduleAll(debts: [DebtRecord]) {
        let center = UNUserNotificationCenter.current()
        // Remove old debt notifications
        center.removePendingNotificationRequests(withIdentifiers:
            debts.map { "debt_\($0.id.uuidString)" })

        for debt in debts where debt.isActive {
            scheduleReminder(for: debt, daysBefore: 3)
            scheduleReminder(for: debt, daysBefore: 1)
            scheduleOnDueDay(for: debt)
        }
    }

    private static func scheduleReminder(for debt: DebtRecord, daysBefore: Int) {
        let cal = Calendar.current
        let now = Date()
        // Calculate next due date
        var components = cal.dateComponents([.year, .month], from: now)
        components.day = debt.dueDayOfMonth
        guard var dueDate = cal.date(from: components) else { return }
        if dueDate <= now { dueDate = cal.date(byAdding: .month, value: 1, to: dueDate) ?? dueDate }

        guard let reminderDate = cal.date(byAdding: .day, value: -daysBefore, to: dueDate),
              reminderDate > now else { return }

        let content = UNMutableNotificationContent()
        content.title = daysBefore == 1 ? "⚠️ Payment due tomorrow!" : "📅 Payment due in \(daysBefore) days"
        content.body = "\(debt.name): \(CurrencyManager.shared.formatted(debt.minimumPayment, currency: debt.currency)) due on the \(debt.dueDayOfMonth)th"
        content.sound = .dipo
        content.userInfo = ["debtId": debt.id.uuidString]

        var triggerComponents = cal.dateComponents([.year, .month, .day], from: reminderDate)
        triggerComponents.hour = 9
        triggerComponents.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
        let id = "debt_\(debt.id.uuidString)_\(daysBefore)d"
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private static func scheduleOnDueDay(for debt: DebtRecord) {
        let cal = Calendar.current
        let now = Date()
        var components = cal.dateComponents([.year, .month], from: now)
        components.day = debt.dueDayOfMonth
        guard var dueDate = cal.date(from: components) else { return }
        if dueDate <= now { dueDate = cal.date(byAdding: .month, value: 1, to: dueDate) ?? dueDate }

        let content = UNMutableNotificationContent()
        content.title = "🚨 Payment due TODAY"
        content.body = "\(debt.name): Pay \(CurrencyManager.shared.formatted(debt.minimumPayment, currency: debt.currency)) now to avoid late fees!"
        content.sound = .defaultCritical
        content.userInfo = ["debtId": debt.id.uuidString]

        var triggerComponents = cal.dateComponents([.year, .month, .day], from: dueDate)
        triggerComponents.hour = 8
        triggerComponents.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
        let id = "debt_\(debt.id.uuidString)_due"
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private static var center: UNUserNotificationCenter { .current() }
}
