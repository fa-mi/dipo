import Foundation

// MARK: - The period as a cash book
//
// Three true numbers used to sit on screen without the arithmetic that joins
// them: "Left to spend Rp 0" in Statistics (income minus spending, clamped at
// zero), "Remaining −Rp 273.500" on Home (the same figure, unclamped) and a
// card balance of Rp 4.001.015. Read together they looked like a mistake. The
// balance was real — the salary was spent, and Mom's Rp 5 jt loan repayment,
// which is not income, was what was left.
//
// A cash book closes that gap the way a passbook or a warung's buku kas does:
// what was there at the start, what came in, what went out, what is there now.
// Every line is a figure DiPo already defines, and the lines add up to the
// balance by construction.
//
//   start + income + other money in − spent − other money out ± own moves = end
//
// Display only, like NonFlowMovements: nothing here feeds a ratio, Smart
// Budget or a recommendation.

struct PeriodCashBook: Equatable {
    /// Card balance when the period opened.
    var start: Double
    /// Real income only, as Statistics counts it.
    var income: Double
    /// Money in that is not income — a loan repaid, say — largest first.
    var otherIn: [NonFlowMovements.Row]
    /// Spending, refunds netted, as Statistics counts it. Includes the two
    /// below, which are spending only in the cash sense.
    var spent: Double
    /// Of `spent`: paying down debt — instalments, credit card bills. It clears
    /// what is owed; it buys nothing new. Shown on its own line, because folded
    /// into "spending" a Rp 3,9 jt card payment read as a month of overspending.
    var debtPaid: Double = 0
    /// Of `spent`: put into savings and investments.
    var invested: Double = 0
    /// Money out that is not spending — a credit card bill, lending — largest first.
    var otherOut: [NonFlowMovements.Row]
    /// Net of moves between the user's own cards and wallets. Signed.
    var ownMoves: Double

    /// Income minus spending — the period's own result.
    var net: Double { income - spent }
    /// Spending on living — everything but debt paid and money put away. The
    /// figure to hold against income when asking "am I living within it?".
    var living: Double { max(spent - debtPaid - invested, 0) }
    /// Income minus living. Positive: room left; negative: living past income.
    var livingNet: Double { income - living }
    var otherInTotal: Double { otherIn.reduce(0) { $0 + $1.amount } }
    var otherOutTotal: Double { otherOut.reduce(0) { $0 + $1.amount } }
    /// Balance at the end of the window. Equals the card balance for a window
    /// running to today.
    var end: Double { start + income + otherInTotal - spent - otherOutTotal + ownMoves }

    /// The book for `txs` (one card, one window), opened at `start`.
    static func build(_ txs: [TxRecord], start: Double,
                      convert: (TxRecord) -> Double) -> PeriodCashBook {
        let income = StatisticsView.income(txs, convert: convert)
        let spent = StatisticsView.expenses(txs, convert: convert)
        let transfers = txs.filter { $0.txSubtype == .transfer }.reduce(0.0) { $0 + convert($1) }
        let ins = NonFlowMovements.rows(txs, incoming: true, amount: convert)
        let outs = NonFlowMovements.rows(txs, incoming: false, amount: convert)
        // Whatever transfers are not listed as other money in or out moved
        // between the user's own accounts.
        let own = transfers - ins.reduce(0) { $0 + $1.amount } + outs.reduce(0) { $0 + $1.amount }
        return PeriodCashBook(start: start, income: income, otherIn: ins, spent: spent,
                              debtPaid: categorySpend(txs, .debtPayment, convert: convert),
                              invested: categorySpend(txs, .investment, convert: convert),
                              otherOut: outs, ownMoves: abs(own) < 0.5 ? 0 : own)
    }

    /// Spending in one category by Statistics' rules: transfers skipped, a
    /// refund taking back its amount. Never below zero.
    static func categorySpend(_ txs: [TxRecord], _ category: TxCategory,
                              convert: (TxRecord) -> Double) -> Double {
        let total = txs.filter { $0.category == category && $0.txSubtype != .transfer }
            .reduce(0.0) { sum, tx in
                let a = abs(convert(tx))
                if tx.txSubtype == .refund { return sum - a }
                return tx.amount < 0 ? sum + a : sum
            }
        return max(total, 0)
    }

    /// The book closed against a known end balance — for a window that runs to
    /// today, where the card's balance is the end. The start is what makes it add up.
    static func build(_ txs: [TxRecord], end: Double,
                      convert: (TxRecord) -> Double) -> PeriodCashBook {
        var book = build(txs, start: 0, convert: convert)
        book.start = end - book.end
        return book
    }

    // MARK: Why the balance is not what the result suggests

    enum Overspend: Equatable {
        /// Money that is not income covered the gap — named, with its amount.
        case coveredBy(label: String, amount: Double)
        /// It came out of what was on the card before the period.
        case savings
        /// Nothing to point at: the balance itself has run out.
        case plain
    }

    /// Nil unless spending passed income. `deficit` is passed in so a screen
    /// explains the exact figure it shows.
    func overspend(deficit: Double) -> Overspend? {
        guard deficit >= 0.5 else { return nil }
        guard end >= 0.5 else { return .plain }
        if otherInTotal >= deficit, let top = otherIn.first {
            return .coveredBy(label: top.label, amount: top.amount)
        }
        return start >= 0.5 ? .savings : .plain
    }
}
