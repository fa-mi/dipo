import Foundation

// MARK: - Money that moved but isn't income or spending
//
// Transfers stay out of income, spending and Smart Budget on purpose: a loan
// paid back to you is your own money returning, and paying a credit-card bill
// settles spending already counted when the card was used. Counting either
// would inflate the figures the budget and the advice are built on.
//
// But leaving them out entirely made them vanish from Statistics, and "where
// did Mom's Rp 5 jt go?" had no answer. So they are listed beside the
// breakdown — display only. Nothing here feeds a total, a ratio, Smart Budget
// or a recommendation.

enum NonFlowMovements {
    struct Row: Equatable {
        let label: String
        let amount: Double
        let count: Int
    }

    /// Movements for one side: `incoming` = money that came in without being
    /// income; otherwise money that went out without being spending.
    /// Moves between the user's own cards (both legs of a card transfer, and
    /// the credit card's side of a bill payment) are left out — they're the
    /// same rupiah seen twice.
    static func rows(_ txs: [TxRecord], incoming: Bool,
                     amount: (TxRecord) -> Double) -> [Row] {
        var byLabel: [String: (amount: Double, count: Int)] = [:]
        for tx in txs where tx.txSubtype == .transfer {
            guard incoming ? tx.amount > 0 : tx.amount < 0 else { continue }
            if isOwnAccountMove(tx, incoming: incoming) { continue }
            let label = self.label(for: tx)
            let v = abs(amount(tx))
            byLabel[label, default: (0, 0)].amount += v
            byLabel[label, default: (0, 0)].count += 1
        }
        return byLabel.filter { $0.value.amount > 0.5 }
            .map { Row(label: $0.key, amount: $0.value.amount, count: $0.value.count) }
            .sorted { $0.amount > $1.amount }
    }

    static func isOwnAccountMove(_ tx: TxRecord, incoming: Bool) -> Bool {
        if tx.icon == "⇄" { return true }                         // card-to-card transfer
        if tx.notes == "tx.note.cc_payment" && incoming { return true }  // the card's side of a bill payment
        return false
    }

    static func label(for tx: TxRecord) -> String {
        switch tx.notes {
        case "tx.note.cc_payment": return loc("stats.nonflow.cc_payment")
        default:                   return tx.name   // "Repaid by Mom", "Lent to Dad", or the user's own name
        }
    }
}
