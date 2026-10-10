import Foundation

// MARK: - What paid for the period, in the order it happened
//
// "Helped by Repaid by Mom" used to be worked out from the period's totals:
// spending past income, and some money in that wasn't income, so the one must
// have covered the other. That holds only when the money was already there.
// A salary used up on the 5th and a repayment arriving on the 20th read as the
// repayment covering the gap, though days 5 to 20 actually ran on the balance
// carried in.
//
// This walks the period in date order instead. Income pays first. Once it is
// used up, spending is paid by money in that isn't income — only money that
// has already arrived, oldest first — then by the balance carried in. Anything
// left after that is the account going below zero.
//
// Income first is deliberate, and the same order the budget uses: the salary
// is what comes back next month, so spending beyond it is shown as helped,
// rather than a one-off repayment quietly absorbing it.
//
// Only spending is paid for here: what the cash book counts as spent, debt
// payments included. Moves between the person's own accounts and money lent
// out are movements, not spending, and the cash book lists them on their own.

enum CoverTimeline {

    struct Source: Equatable {
        let label: String
        var amount: Double
    }

    struct Result: Equatable {
        /// The moment income stopped covering what went out. Nil when it
        /// covered everything.
        var incomeRanOutOn: Date? = nil
        /// Money in that isn't income, by label, in the order it was drawn on,
        /// with how much of each actually paid for spending.
        var coveredBy: [Source] = []
        /// Paid from the balance carried into the period.
        var fromSavings: Double = 0
        /// Paid by nothing: the balance went below zero.
        var uncovered: Double = 0

        var coveredTotal: Double { coveredBy.reduce(0) { $0 + $1.amount } }
        /// The source that paid most.
        var topSource: Source? { coveredBy.max { $0.amount < $1.amount } }
        /// Anything at all paid by something other than income.
        var isHelped: Bool { coveredTotal + fromSavings + uncovered >= 0.5 }
    }

    /// `start` is the balance carried in; only a positive one can pay.
    static func walk(_ txs: [TxRecord], start: Double, convert: (TxRecord) -> Double) -> Result {
        // On the same instant, money in before money out: a salary and a bill
        // posted at the same midnight are paid in that order.
        let ordered = txs.sorted { a, b in
            a.date != b.date ? a.date < b.date : (a.amount > 0 && b.amount <= 0)
        }

        var result = Result()
        var income = 0.0
        var arrived: [(label: String, left: Double)] = []
        var savings = max(start, 0)
        var used: [String: Double] = [:]
        var order: [String] = []

        for tx in ordered {
            let amount = abs(convert(tx))
            guard amount >= 0.005 else { continue }

            if tx.txSubtype == .refund || (tx.txSubtype == .normal && tx.amount > 0) {
                // A refund gives back what was spent; it pays like income.
                income += amount
                continue
            }
            if tx.txSubtype == .transfer {
                if tx.amount > 0, !NonFlowMovements.isOwnAccountMove(tx, incoming: true) {
                    arrived.append((NonFlowMovements.label(for: tx), amount))
                }
                continue
            }
            guard tx.amount < 0 else { continue }

            var cost = amount
            let fromIncome = min(cost, income)
            income -= fromIncome
            cost -= fromIncome
            guard cost >= 0.005 else { continue }
            if result.incomeRanOutOn == nil { result.incomeRanOutOn = tx.date }

            for i in arrived.indices where cost >= 0.005 && arrived[i].left >= 0.005 {
                let take = min(cost, arrived[i].left)
                arrived[i].left -= take
                cost -= take
                if used[arrived[i].label] == nil { order.append(arrived[i].label) }
                used[arrived[i].label, default: 0] += take
            }

            let fromSavings = min(cost, savings)
            savings -= fromSavings
            cost -= fromSavings
            result.fromSavings += fromSavings
            result.uncovered += cost
        }

        result.coveredBy = order.map { Source(label: $0, amount: used[$0] ?? 0) }
        return result
    }
}
