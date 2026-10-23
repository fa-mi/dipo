import Foundation

// MARK: - Monthly expenses still to come
//
// Smart Budget counted only what had been recorded. On payday every group read
// "Rp 0 spent", and Needs offered Rp 196.970 a day for 33 days while kos, the
// transfer home and the subscriptions — Rp 3.936.000 between them — fell due
// before the next salary. That money was already spoken for; the screen said it
// was free.
//
// Monthly Expenses knows each of those charges and the day it falls on, so the
// budget takes them out of what is left as soon as the period opens. Once a
// charge is recorded it is spending like any other and drops off this list:
// nothing is counted twice.

/// One charge of a monthly expense, due before the budget period ends and not
/// recorded yet.
struct ScheduledBill: Identifiable, Equatable {
    let id: String
    let planID: UUID
    let label: String
    /// In the budget's currency.
    let amount: Double
    /// The plan's own amount and currency, shown beside a converted figure.
    let planAmount: Double
    let planCurrency: String
    let due: Date
    let category: TxCategory
}

enum ScheduledBills {

    /// Every charge of an active monthly expense paid from one of `cardIDs`,
    /// due from today until `periodEnd`, that has not been recorded — neither
    /// by DiPo on the due day nor by hand ahead of it. Earliest first.
    ///
    /// A pay period can be longer than a month: one that runs from 23 Oct to
    /// 24 Nov meets a bill due on the 24th twice, and both charges come out of
    /// this salary, so both are listed.
    ///
    /// `cardIDs` is the budget's pot (`MainCard.budgetSpendingCardIDs`): a
    /// bill paid from any other account never leaves this budget's money.
    static func upcoming(plans: [RecurringExpense], cards: [BankCard], cardIDs: Set<String>,
                         periodStart: Date, periodEnd: Date, currency: String,
                         now: Date = .now) -> [ScheduledBill] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let end = cal.startOfDay(for: periodEnd)
        guard end > today else { return [] }

        var charges: [(plan: RecurringExpense, card: BankCard, due: Date, month: Int, year: Int)] = []
        for plan in plans where plan.isActive && plan.amount > 0 {
            guard let id = plan.cardID, cardIDs.contains(id.uuidString),
                  let card = cards.first(where: { $0.id == id }) else { continue }
            // The engine never charges a due date from before the plan existed.
            let created = cal.startOfDay(for: plan.createdAt)
            // A pay period spans two or three calendar months at most.
            var month = cal.safeDate(from: cal.dateComponents([.year, .month], from: today))
            for _ in 0..<4 where month < end {
                let c = cal.dateComponents([.year, .month], from: month)
                let m = c.month ?? 1, y = c.year ?? 2000
                let due = cal.startOfDay(for: RecurringDateEngine.dueDate(dayOfMonth: plan.dayOfMonth,
                                                                          month: m, year: y))
                if due >= today, due < end, due >= created, !posted(plan, month: m, year: y) {
                    charges.append((plan: plan, card: card, due: due, month: m, year: y))
                }
                month = cal.safeDate(byAdding: .month, value: 1, to: month)
            }
        }

        // Earliest first, so a payment made by hand is matched to the first
        // bill it could be — and never to two of them.
        charges.sort { $0.due < $1.due }
        let cm = CurrencyManager.shared
        var claimed = Set<UUID>()
        var bills: [ScheduledBill] = []
        for c in charges {
            let cardCurrency = c.card.resolvedCurrency
            let planCurrency = c.plan.currency.isEmpty ? cardCurrency : c.plan.currency
            // Paid by hand already: the engine will hold this charge for the
            // user to confirm rather than record it, so it is spent, not due.
            let key = RecurringHistory.normalized(c.plan.label)
            let previous = c.card.transactions
                .filter { $0.notes == "tx.note.recurring_auto" && $0.date < c.due
                    && RecurringHistory.normalized($0.name) == key }
                .map(\.date).max()
            if let match = RecurringManualMatch.find(
                amount: cm.convert(abs(c.plan.amount), from: planCurrency, to: cardCurrency),
                currency: cardCurrency, planLabel: c.plan.label, planCategory: c.plan.category,
                due: c.due,
                from: RecurringManualMatch.windowStart(due: c.due, periodStart: periodStart,
                                                       previousCharge: previous, cal: cal),
                to: now, in: c.card.transactions, excluding: claimed) {
                claimed.insert(match.id)
                continue
            }
            bills.append(ScheduledBill(
                id: "\(c.plan.id.uuidString)-\(c.year)-\(c.month)",
                planID: c.plan.id,
                label: c.plan.label,
                amount: cm.convert(abs(c.plan.amount), from: planCurrency, to: currency),
                planAmount: abs(c.plan.amount),
                planCurrency: planCurrency,
                due: c.due,
                category: c.plan.category))
        }
        return bills
    }

    /// Whether DiPo has already recorded — or held for the user to confirm —
    /// the charge due in `month`/`year`. The engine stamps months in order,
    /// so a later stamp covers this one too.
    static func posted(_ plan: RecurringExpense, month: Int, year: Int) -> Bool {
        plan.autoRecord && plan.lastChargedYear * 12 + plan.lastChargedMonth >= year * 12 + month
    }

    /// The bills that fall in `group`.
    static func bills(_ bills: [ScheduledBill], in group: BudgetGroup) -> [ScheduledBill] {
        bills.filter { SmartBudgetManager.shared.group(for: $0.category) == group }
    }

    /// What the bills in `group` add up to, in the budget's currency.
    static func total(_ bills: [ScheduledBill], in group: BudgetGroup) -> Double {
        Self.bills(bills, in: group).reduce(0.0) { $0 + $1.amount }
    }

    /// `bills` without the one an entry being saved is likely paying by hand —
    /// the kos paid early — so the entry and the bill are not counted twice.
    /// The rule DiPo uses to hold a charge already paid by hand: the same
    /// amount, within 1% or Rp 1.000, and a category or a word that fits.
    /// `amount` is in the bills' currency.
    static func removingEntry(from bills: [ScheduledBill], amount: Double, name: String,
                              category: TxCategory, currency: String) -> [ScheduledBill] {
        let tolerance = max(abs(amount) * 0.01, currency == "IDR" ? 1_000 : 0.01)
        guard let i = bills.firstIndex(where: {
            abs($0.amount - abs(amount)) <= tolerance
                && RecurringManualMatch.couldBe(name: name, category: category,
                                                planLabel: $0.label, planCategory: $0.category)
        }) else { return bills }
        var rest = bills
        rest.remove(at: i)
        return rest
    }

    // MARK: Filed in the wrong group

    /// Words that name an investment or a saving in a plan's label, matched
    /// as whole words: "emas" inside "kemasan" is packaging. "gold" is left
    /// out because of Gold's Gym; "Gold invest" is caught by "invest".
    static let investmentWords: [String] = [
        "invest", "investasi", "investment", "reksadana", "reksa dana", "saham", "deposito",
        "nabung", "tabungan", "menabung", "saving", "savings", "emas", "logam mulia",
        "antam", "obligasi", "sbn", "sukuk", "crypto", "kripto", "bitcoin"
    ]

    /// An active plan that reads like an investment but is filed outside
    /// Savings & debt — "Gold invest" under Commitment, counted as a Need.
    /// Only plans on `cardIDs`, the budget's own money.
    static func looksLikeInvestment(_ plans: [RecurringExpense], cardIDs: Set<String>) -> [RecurringExpense] {
        plans.filter { plan in
            guard plan.isActive, let id = plan.cardID, cardIDs.contains(id.uuidString),
                  SmartBudgetManager.shared.group(for: plan.category) != .investDebt else { return false }
            let words = Set(SmartBudgetManager.normalizedMerchant(plan.label).split(separator: " ").map(String.init))
            let label = " " + SmartBudgetManager.normalizedMerchant(plan.label) + " "
            return investmentWords.contains { word in
                word.contains(" ") ? label.contains(" \(word) ") : words.contains(word)
            }
        }
    }
}
