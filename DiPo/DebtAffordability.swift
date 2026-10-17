import Foundation

// MARK: - Can a usual month carry these payments?
//
// The Debts screen answered this with a health score that took points off
// for THIS pay period's spending, and then, right under "Very healthy",
// warned that the period was Rp 1.175.718 over plan. How a pay period is
// going is Statistics' question. The Debts screen asks a different one: with
// what you usually spend in a month, can you carry what the debts ask for?
//
// So the reading is taken from a usual month — the Financial ladder's
// figures: income including side income that keeps coming, and the median
// of the last complete months of daily needs and lifestyle, on every
// account — never from how far into the period the user happens to be.
//
// Pure: the view gathers the figures, this decides. Pinned by DebtAffordabilityTests.

struct DebtAffordability: Equatable {
    /// What usually comes in a month.
    let monthlyIncome: Double
    /// What a usual month costs: daily needs and lifestyle, and never less
    /// than the bills declared as recurring.
    let monthlySpending: Double
    /// What the debts ask for each month — "Pay each month" on the screen.
    let monthlyPayments: Double
    /// Anything owed at all; with nothing owed there is nothing to weigh.
    var hasDebt: Bool = true

    enum Verdict: Equatable { case safe, tight, heavy }

    /// Under a tenth of income left after a usual month and the payments is a
    /// margin one surprise bill uses up — and then a payment is late.
    static let thinMargin = 0.10

    /// Left of a usual month's income once it is spent and the debts are paid.
    var left: Double { monthlyIncome - monthlySpending - monthlyPayments }
    var paymentShare: Double { monthlyIncome > 0 ? monthlyPayments / monthlyIncome : 0 }
    var marginIsThin: Bool { left < monthlyIncome * Self.thinMargin }
    /// Past the share of income banks hold every instalment to. The month may
    /// still close, but no lender would add to it, and neither should the user.
    var pastLenderLimit: Bool { paymentShare > LoanAffordability.lenderCeiling }

    /// Nil without an income to weigh against, or with nothing owed.
    var verdict: Verdict? {
        guard hasDebt, monthlyIncome > 0 else { return nil }
        if left < 0 { return .heavy }
        return marginIsThin || pastLenderLimit ? .tight : .safe
    }

    func title() -> String {
        guard hasDebt else { return loc("debt.advice.no_active") }
        guard let verdict else { return loc("debt.afford.unknown") }
        let label: String
        switch verdict {
        case .safe:  label = loc("debt.afford.safe")
        case .tight: label = loc("debt.afford.tight")
        case .heavy: label = loc("debt.afford.heavy")
        }
        return String(format: loc("debt.verdict_dti"), label, String(format: "%.0f", paymentShare * 100))
    }

    /// The sentence under the verdict: the usual month, the payments, and
    /// what is left of the income — the arithmetic behind the word above it.
    func detail(currency: String) -> String? {
        guard hasDebt else { return nil }
        guard let verdict else { return loc("debt.afford.no_income") }
        let m = { (v: Double) in CurrencyManager.shared.formatted(v, currency: currency) }
        // Nothing asked for each month: only new shopping on a card.
        let noPayments = monthlyPayments < 0.5
        switch verdict {
        case .heavy:
            return noPayments
                ? String(format: loc("debt.afford.nopay_heavy"), m(monthlySpending), m(-left), m(monthlyIncome))
                : String(format: loc("debt.afford.heavy_body"), m(monthlySpending), m(monthlyPayments),
                         m(-left), m(monthlyIncome))
        case .tight where !marginIsThin:
            return String(format: loc("debt.afford.tight_share"),
                          String(format: "%.0f%%", LoanAffordability.lenderCeiling * 100), m(left))
        case .tight, .safe:
            if noPayments {
                return String(format: loc("debt.afford.nopay_body"), m(monthlySpending), m(left), m(monthlyIncome))
            }
            return String(format: loc(verdict == .safe ? "debt.afford.safe_body" : "debt.afford.tight_body"),
                          m(monthlySpending), m(monthlyPayments), m(left), m(monthlyIncome))
        }
    }
}

extension DebtAffordability {
    /// The reading from the user's records: the Financial ladder's usual
    /// month — every account, the income that keeps coming, the median of
    /// the last complete months — against `payments`. The recurring bills
    /// declared in DiPo are the floor for spending, for a user who logs little.
    @MainActor
    static func usualMonth(cards: [BankCard], debts: [DebtRecord], salaries: [SalarySchedule],
                           installments: [CardInstallment], commitments: Double, payments: Double,
                           hasDebt: Bool, currency: String, now: Date = .now) -> DebtAffordability {
        let usual = LadderInputs.gather(cards: cards, debts: debts, holdings: [], goals: [], salaries: salaries,
                                        currency: currency, installments: installments, now: now)
        return DebtAffordability(monthlyIncome: usual.monthlyIncome,
                                 monthlySpending: max(usual.monthlyConsumption, commitments),
                                 monthlyPayments: payments, hasDebt: hasDebt)
    }
}

// MARK: - Smart Budget: clear dear debt before saving

/// Smart Budget sets aside a share of the month for savings & debt, and the
/// debt minimums come out of it. What happens to the rest is the advice:
/// while a debt charges more than any savings or investment reliably earns —
/// the Financial ladder's rule — the rest goes to that debt too, and saving
/// waits until it is cleared. Debt that charges little or nothing is paid on
/// schedule, and the rest is saved.
struct DebtFirstAdvice: Equatable {
    enum Target: Equatable {
        /// A credit-card balance carried over from earlier bills.
        case card(carried: Double)
        /// A recorded debt, in the preferred currency.
        case debt(name: String, annualRate: Double, balance: Double, minimum: Double)
    }

    /// Smart Budget's savings & debt share of the month.
    let share: Double
    /// That share as a fraction of income.
    let ratio: Double
    /// Every debt's monthly payment.
    let minimums: Double
    /// The debt to clear first; nil when nothing owed is dear.
    let target: Target?
    /// A card is owed only this month's and last month's shopping.
    var cardRecentOnly: Bool = false

    /// What is left of the share once the minimums are paid.
    var extra: Double { max(share - minimums, 0) }
    var noRoom: Bool { extra < 0.5 }

    func title() -> String {
        switch target {
        case .card:
            return loc("debt.first.title_card")
        case .debt(let name, _, _, _):
            return String(format: loc("debt.first.title_debt"), name)
        case nil:
            return loc(noRoom ? "debt.first.title_full" : "debt.first.title_ok")
        }
    }

    /// The share and, while a debt is dear, where all of it goes. Nil when the
    /// minimums take all of it — the body says so instead.
    func shareLine(currency: String) -> String? {
        guard !noRoom else { return nil }
        let line = String(format: loc("debt.first.share"),
                          CurrencyManager.shared.formatted(share, currency: currency),
                          String(format: "%.0f%%", ratio * 100))
        return target == nil ? line : line + " " + loc("debt.first.share_costly")
    }

    func body(currency: String, now: Date = .now, cal: Calendar = .current) -> String {
        let m = { (v: Double) in CurrencyManager.shared.formatted(v, currency: currency) }
        let recent = cardRecentOnly ? " " + loc("debt.first.card_recent") : ""
        switch target {
        case nil:
            return noRoom
                ? String(format: loc("debt.first.full"), m(minimums), m(share)) + recent
                : String(format: loc("debt.first.ok"), String(format: "%.0f%%", FinancialLadder.costlyRate)) + recent
        case .some(let target) where noRoom:
            let noun: String
            switch target {
            case .card:                  noun = loc("debt.first.card_noun")
            case .debt(let name, _, _, _): noun = name
            }
            return String(format: loc("debt.first.no_room"), m(minimums), m(share), noun)
        case .card(let carried):
            return String(format: loc("debt.first.why_card"), m(carried))
                + " " + String(format: loc("debt.first.back_to_saving"), m(extra))
        case .debt(let name, let rate, _, _):
            var out = String(format: loc("debt.first.why_debt"), name, Self.rate(rate))
            if let p = faster() {
                let date = { (months: Int) in
                    (cal.date(byAdding: .month, value: months, to: now) ?? now)
                        .formatted(.dateTime.month(.abbreviated).year())
                }
                if let slow = p.slow {
                    out += " " + String(format: loc("debt.first.faster"), date(p.fast.months), date(slow.months),
                                        m(slow.interest - p.fast.interest))
                } else {
                    out += " " + String(format: loc("debt.first.faster_never"), date(p.fast.months))
                }
            }
            return out + " " + String(format: loc("debt.first.back_to_saving"), m(extra))
        }
    }

    /// "36", or "24,5" — no ".0" on a whole rate.
    static func rate(_ r: Double) -> String {
        r.rounded() == r ? String(format: "%.0f", r) : String(format: "%.1f", r)
    }

    // MARK: Paying it off

    struct Payoff: Equatable {
        let months: Int
        let interest: Double
    }

    /// Month by month at a fixed payment: how long, and the interest paid on
    /// the way. Nil when the payment never gets ahead of the interest, or
    /// takes longer than `limit` months.
    static func payoff(balance: Double, annualRate: Double, payment: Double, limit: Int = 600) -> Payoff? {
        guard balance > 0, payment > 0, annualRate >= 0 else { return nil }
        let r = annualRate / 12 / 100
        var owed = balance, interest = 0.0, months = 0
        while owed > 0.005 {
            let charge = owed * r
            guard payment > charge, months < limit else { return nil }
            interest += charge
            owed += charge - payment
            months += 1
        }
        return Payoff(months: months, interest: interest)
    }

    /// The target debt paid with the rest of the share on top of its minimum,
    /// against its minimum alone — `slow` is nil when the minimum alone never
    /// clears it. Nil when there is no recorded debt to clear, no rest to add,
    /// or it would not end any sooner.
    func faster() -> (fast: Payoff, slow: Payoff?)? {
        guard case .debt(_, let rate, let balance, let minimum) = target, !noRoom,
              let fast = Self.payoff(balance: balance, annualRate: rate, payment: minimum + extra) else { return nil }
        let slow = Self.payoff(balance: balance, annualRate: rate, payment: minimum)
        if let slow, slow.months <= fast.months { return nil }
        return (fast, slow)
    }
}
