import Foundation

// MARK: - Money in that the person chose to budget with
//
// "Mom paid back Rp 5 jt and I used it for kos — does the budget see it?"
// Not by default. A repayment, a gift, a deposit coming back is not income,
// and counting it as income makes a lucky month look like a raise: the
// allowances grow, and next month they shrink back for no visible reason.
//
// But sometimes the person does mean to live on it this period. Then the
// honest thing is to let them say so, row by row, and to say back exactly
// what was added. Each flagged row adds its amount to this period's budget
// money — Smart Budget's income, Home's "left of income", Statistics'
// living box — and nothing else: it stays out of income totals and trends.
//
// Stored as a list of transaction ids (SmartBudgetManager.extraFundTxIDs),
// not on the row, so no schema change; backups carry the list.

enum ExtraFunds {

    /// Money in that isn't income and isn't the person's own money moving
    /// between their cards — the rows this choice makes sense for.
    static func canFlag(_ tx: TxRecord) -> Bool {
        tx.amount > 0 && tx.txSubtype == .transfer
            && !NonFlowMovements.isOwnAccountMove(tx, incoming: true)
    }

    static func isFlagged(_ tx: TxRecord) -> Bool {
        canFlag(tx) && SmartBudgetManager.shared.extraFundTxIDs.contains(tx.id.uuidString)
    }

    static func set(_ tx: TxRecord, _ on: Bool) {
        var ids = SmartBudgetManager.shared.extraFundTxIDs.filter { $0 != tx.id.uuidString }
        if on, canFlag(tx) { ids.append(tx.id.uuidString) }
        SmartBudgetManager.shared.extraFundTxIDs = ids
    }

    /// What the flagged rows in `txs` add to the budget from `start` (and
    /// before `end`, when given), in `currency`.
    static func total(in txs: [TxRecord], from start: Date, to end: Date? = nil,
                      currency: String, ids: [String] = SmartBudgetManager.shared.extraFundTxIDs) -> Double {
        guard !ids.isEmpty else { return 0 }
        let flagged = Set(ids)
        let cm = CurrencyManager.shared
        return txs.reduce(0.0) { sum, tx in
            guard tx.date >= start, end.map({ tx.date < $0 }) ?? true,
                  canFlag(tx), flagged.contains(tx.id.uuidString) else { return sum }
            return sum + cm.convert(tx.amount, from: tx.currency.isEmpty ? currency : tx.currency, to: currency)
        }
    }
}
