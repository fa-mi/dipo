import Foundation

// MARK: - When the money owed to you comes back
//
// Money others owe the user isn't income and may never come, so the verdict
// on the Debts screen never counts it. What the screen can show is what
// changes if it does come, and goes where Smart Budget says: loans at the
// Financial ladder's costly rate or more, dearest first, then card balances
// carried over from earlier bills — the order whose first entry
// `FinancialHealthEngine.payFirst` names. Whatever is left is a buffer;
// 0% instalments and cheap debt are paid on schedule, never early.
//
// Pure: DebtView gathers the debts, this decides. Pinned by OwedBackPlanTests.

struct OwedBackPlan: Equatable {
    /// A debt worth clearing early, in the preferred currency.
    struct Costly: Equatable {
        enum Kind: Equatable {
            case loan(annualRate: Double)
            /// A card balance carried over from earlier bills.
            case card
        }
        let id: UUID
        let name: String
        let kind: Kind
        let balance: Double
        /// A loan's monthly payment, which ends only once it is cleared. A
        /// card's is a share of the carried balance and falls with every
        /// rupiah paid, so this is unused for cards.
        var minimum: Double = 0
    }

    struct Payoff: Equatable {
        let debt: Costly
        let paid: Double
        var cleared: Bool { paid >= debt.balance - 0.5 }
    }

    let owedBack: Double
    let payoffs: [Payoff]
    /// What is left once every dear balance is cleared: a buffer.
    let leftOver: Double
    /// The reading from today's records.
    let before: DebtAffordability
    /// The same month with the cleared payments gone.
    let after: DebtAffordability

    /// Smart Budget's order: dear loans by rate, then carried card balances,
    /// the largest first.
    static func order(_ costly: [Costly]) -> [Costly] {
        let loans = costly.filter { $0.kind != .card }.sorted { rate($0) > rate($1) }
        let cards = costly.filter { $0.kind == .card }.sorted { $0.balance > $1.balance }
        return (loans + cards).filter { $0.balance >= 0.5 }
    }

    private static func rate(_ c: Costly) -> Double {
        if case .loan(let r) = c.kind { return r }
        return 0
    }

    /// Nil with nothing owed back, no income to weigh a month against, or
    /// nothing owed that is worth clearing early.
    static func make(owedBack: Double, costly: [Costly], totalDebt: Double,
                     reading: DebtAffordability) -> OwedBackPlan? {
        guard owedBack >= 0.5, reading.verdict != nil else { return nil }
        var left = owedBack
        var freed = 0.0
        var payoffs: [Payoff] = []
        for debt in order(costly) where left >= 0.5 {
            let payoff = Payoff(debt: debt, paid: min(left, debt.balance))
            left -= payoff.paid
            payoffs.append(payoff)
            switch debt.kind {
            case .loan: if payoff.cleared { freed += debt.minimum }
            case .card: freed += payoff.paid * ObligationLoad.cardMinimumShare
            }
        }
        guard !payoffs.isEmpty else { return nil }
        let paid = owedBack - left
        let after = DebtAffordability(monthlyIncome: reading.monthlyIncome,
                                      monthlySpending: reading.monthlySpending,
                                      monthlyPayments: max(reading.monthlyPayments - freed, 0),
                                      hasDebt: totalDebt - paid >= 0.5)
        return OwedBackPlan(owedBack: owedBack, payoffs: payoffs, leftOver: max(left, 0),
                            before: reading, after: after)
    }

    /// Under the before and after: what stops, and what a usual month looks
    /// like then. When the month is still short, it says so, and why — the
    /// money comes once, the gap comes every month.
    func note(currency: String) -> String {
        let m = { (v: Double) in CurrencyManager.shared.formatted(v, currency: currency) }
        var parts = [loc(payoffs.contains(where: \.cleared) ? "debt.owed_back.interest" : "debt.owed_back.interest_less")]
        switch after.verdict {
        case .heavy?:
            parts.append(String(format: loc("debt.owed_back.still_short"), m(-after.left)))
        case .tight?, .safe?:
            if before.verdict == .heavy {
                parts.append(String(format: loc("debt.owed_back.closes"), m(after.left)))
            } else if after.verdict != before.verdict {
                parts.append(String(format: loc("debt.owed_back.spare"), m(after.left)))
            }
        case nil:
            break
        }
        return parts.joined(separator: " ")
    }
}

extension OwedBackPlan {
    /// The debts worth clearing early, from the records: loans at the costly
    /// rate or more, and each card's balance carried over from earlier bills
    /// — unless a card debt is recorded by hand, which is that same balance
    /// and counts once, as a loan.
    static func costly(debts: [DebtRecord], cards: [BankCard], currency: String, now: Date = .now) -> [Costly] {
        let cm = CurrencyManager.shared
        let loans = debts.filter {
            $0.isActive && !$0.manuallyClosed && $0.currentBalance > 0
                && $0.annualInterestRate >= FinancialLadder.costlyRate
        }.map {
            Costly(id: $0.id, name: $0.name, kind: .loan(annualRate: $0.annualInterestRate),
                   balance: cm.convert($0.currentBalance, from: $0.currency, to: currency),
                   minimum: cm.convert($0.effectiveMinimumPayment, from: $0.currency, to: currency))
        }
        let cardDebtRecorded = debts.contains {
            $0.isActive && !$0.manuallyClosed && $0.type == DebtType.creditCard.rawValue
        }
        guard !cardDebtRecorded else { return loans }
        return loans + ObligationLoad.carriedByCard(cards: cards, currency: currency, now: now).map {
            Costly(id: $0.card.id, name: $0.card.holderName.isEmpty ? loc("cc.title") : $0.card.holderName,
                   kind: .card, balance: $0.carried)
        }
    }

    /// Where `amount` just received would go first, and how much of it.
    static func firstPayoff(of amount: Double, costly: [Costly]) -> Payoff? {
        guard amount >= 0.5, let debt = order(costly).first else { return nil }
        return Payoff(debt: debt, paid: min(amount, debt.balance))
    }
}

extension DebtAffordability {
    /// The verdict's word alone — "Too heavy" — or, with nothing owed,
    /// "No debt left".
    var verdictLabel: String? {
        guard hasDebt else { return loc("debt.owed_back.debt_free") }
        switch verdict {
        case .safe?:  return loc("debt.afford.safe")
        case .tight?: return loc("debt.afford.tight")
        case .heavy?: return loc("debt.afford.heavy")
        case nil:     return nil
        }
    }
}
