import Foundation

// MARK: - Net worth
//
// Home's "Kekayaan bersih" line and the web dashboard's "Hartamu hari ini"
// are one figure, so they come from one function. It was Home's own private
// arithmetic until the dashboard needed it; a second copy would drift, and
// the big screen would show a different total from the phone.
//
// Net worth = cash + savings goals + receivables + investments + physical
// assets − liabilities. Every part is converted to `currency` first.

struct NetWorthParts: Equatable {
    var balance = 0.0, goals = 0.0, receivables = 0.0, investments = 0.0, assets = 0.0, liabilities = 0.0
    /// The part of `liabilities` owed on credit cards (0 when a card is
    /// also recorded as a debt, which is then counted once, as a debt).
    var cardOwed = 0.0
    var total: Double { balance + goals + receivables + investments + assets - liabilities }
}

enum NetWorth {

    @MainActor
    static func parts(cards: [BankCard], goals: [SavingsGoal], receivables: [Receivable],
                      holdings: [InvestmentHolding], assets: [PhysicalAsset],
                      debts: [DebtRecord], installments: [CardInstallment],
                      currency pref: String, now: Date = .now) -> NetWorthParts {
        let cm = CurrencyManager.shared
        let tx = cards.flatMap(\.transactions)
        let activeDebts = debts.filter { $0.isActive }

        // Cash only — credit cards are liabilities, not money you hold. They
        // must never inflate the total balance.
        //
        // Every amount is converted to the preferred currency first. Summing
        // raw values added a USD card's balance to an IDR one as if they were
        // the same unit — and since the liabilities DID convert, net worth
        // silently mixed converted debts with unconverted cash.
        let balance = cards.filter { !$0.isCreditCard }.reduce(0.0) { sum, card in
            let cur = card.resolvedCurrency
            let txSum = card.transactions.reduce(0.0) { acc, t in
                acc + cm.convert(t.amount, from: t.currency.isEmpty ? cur : t.currency, to: pref)
            }
            return sum + cm.convert(card.balance, from: cur, to: pref) + txSum
        }

        // Credit-card owed + active debt balances. A card also recorded as a
        // debt by hand is the same money; count it once, as the Debts screen does.
        let cardRecorded = activeDebts.contains { !$0.manuallyClosed && $0.type == DebtType.creditCard.rawValue }
        let cardOwed = cardRecorded ? 0 : cards.filter { $0.isCreditCard }
            .reduce(0.0) { $0 + cm.convert($1.totalOwed(installments), from: $1.resolvedCurrency, to: pref) }
        let owedOnDebts = activeDebts.reduce(0.0) { $0 + cm.convert($1.currentBalance, from: $1.currency, to: pref) }

        // Money already set aside in savings goals. This is the user's money —
        // leaving it out made someone with Rp 30M saved and Rp 12M of
        // installments look bankrupt. Only what is provably NOT still sitting
        // in a tracked account counts (see `netWorthContribution`), so the
        // same rupiah is never counted twice.
        let saved = goals.filter { !$0.isCompleted }.reduce(0.0) {
            $0 + cm.convert($1.netWorthContribution(from: tx), from: $1.currency, to: pref)
        }

        // Money other people owe the user. An outstanding claim is an asset in
        // exactly the way a debt is a liability.
        let lent = receivables.filter { !$0.isSettled }.reduce(0.0) {
            $0 + cm.convert($1.netWorthContribution(from: tx), from: $1.currency, to: pref)
        }

        // Current market value of every holding (Royal; empty otherwise).
        let invested = holdings.reduce(0.0) {
            $0 + cm.convert($1.stats().marketValue, from: $1.currency, to: pref)
        }

        // Estimated value of the house, land, vehicles and electronics (Royal).
        let things = AssetSummary.of(assets, currency: pref, now: now).totalValue

        return NetWorthParts(balance: balance, goals: saved, receivables: lent,
                             investments: invested, assets: things,
                             liabilities: cardOwed + owedOnDebts, cardOwed: cardOwed)
    }
}
