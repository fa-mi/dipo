import Foundation

// MARK: - The Statistics headline, in words
//
// The sentences under the balance on Statistics — living costs against
// income, the debt box, when income ran out and what paid after it, where the
// period is heading — built from the cash book and two formatters. The screen
// and the web dashboard both read them from here, so the laptop says what the
// phone says, word for word, in either language. A second copy of these rules
// in JavaScript is how the two screens started quoting different numbers
// before.

extension PeriodCashBook {

    /// What living costs are measured against: income, plus any money in the
    /// person added to this period's budget.
    var livingFunds: Double { income + extraFunds }

    /// Living costs over that, for the gauge.
    var livingRatio: Double { livingFunds > 0 ? living / livingFunds : 0 }

    /// Share of income spent on living, as on Home: past 100 when living costs
    /// pass income, and held below 100 until the income is actually all gone.
    static func usedPct(ratio: Double) -> Int {
        let pct = Int((ratio * 100).rounded())
        return ratio < 1 ? min(pct, 99) : max(pct, 100)
    }

    /// The balance payday should find: today's, less the spending still to
    /// come at the current pace. Money in or out that is not income or
    /// spending can't be foreseen and isn't guessed at.
    func endAtPayday(projected: Double) -> Double {
        end - max(projected - spent, 0)
    }

    /// "Spending & bills Rp X — still Rp Y under your income.", then what was
    /// added to the budget and, when living costs passed income, what paid
    /// for the gap.
    func livingSentence(money: (Double) -> String) -> String {
        let over = livingNet < -0.5
        var text = String(format: loc(over ? "stats.living_over" : "stats.living_under"),
                          money(living), money(abs(livingNet)))
        if extraFunds >= 0.5 {
            text += " " + String(format: loc("stats.extra_included"), money(extraFunds))
        }
        if over, let why = overspend(deficit: -livingNet) {
            switch why {
            case .coveredBy(let label, let amount):
                text += " " + String(format: loc("stats.over_covered"), label, money(amount))
            case .partly(let label, let amount):
                text += " " + String(format: loc("stats.over_partly"), label, money(amount))
            case .savings:
                text += " " + loc("stats.over_saved")
            case .plain:
                break
            }
        }
        return text
    }

    /// Debt paid down and money put away — named as what they are rather than
    /// counted as overspending — and, when income alone didn't cover the
    /// period, what helped. Nil when nothing went to either.
    func debtSentence(money: (Double) -> String) -> String? {
        guard debtPaid >= 0.5 || invested >= 0.5 else { return nil }
        var parts: [String] = []
        if debtPaid >= 0.5 { parts.append(String(format: loc("stats.debt_box"), money(debtPaid))) }
        if invested >= 0.5 { parts.append(String(format: loc("stats.invest_box"), money(invested))) }
        if let top = cover.topSource, top.amount >= 0.5 {
            parts.append(String(format: loc("stats.debt_helped"), top.label, money(top.amount)))
        }
        return parts.joined(separator: " ")
    }

    /// When income ran out, and what paid after that — in the order it
    /// happened. Nil while income covered everything.
    func coverSentence(money: (Double) -> String, day: (Date) -> String) -> String? {
        let c = cover
        guard c.isHelped else { return nil }
        var paid = c.coveredBy.filter { $0.amount >= 0.5 }
            .map { String(format: loc("stats.cover_source"), $0.label, money($0.amount)) }
        if c.fromSavings >= 0.5 { paid.append(String(format: loc("stats.cover_savings"), money(c.fromSavings))) }
        if c.uncovered >= 0.5 { paid.append(String(format: loc("stats.cover_short"), money(c.uncovered))) }
        let list = paid.joined(separator: ", ")
        guard let ranOut = c.incomeRanOutOn, income >= 0.5 else {
            return String(format: loc("stats.cover_no_income"), list)
        }
        return String(format: loc("stats.cover_ran_out"), day(ranOut), list)
    }

    /// One sentence on where a running period is heading, for living costs.
    /// Debt paid and money put away so far are taken out of the projection,
    /// or a card payment would read as a pace of overspending. Nil without a
    /// projection or anything to hold it against.
    static func paceSentence(projected: Double?, book: PeriodCashBook?, livingFunds: Double,
                             money: (Double) -> String) -> (ok: Bool, text: String)? {
        guard let projected, livingFunds > 0 else { return nil }
        let living = max(projected - (book.map { $0.debtPaid + $0.invested } ?? 0), 0)
        if living <= livingFunds {
            return (true, String(format: loc("stats.pace_safe"), money(living)))
        }
        return (false, String(format: loc("stats.pace_over"), money(living), money(living - livingFunds)))
    }

    /// Up to two named rows a side; the rest folded into "and N more".
    static func shownRows(_ rows: [NonFlowMovements.Row]) -> [(label: String, amount: Double)] {
        let shown = rows.count > 3 ? Array(rows.prefix(2)) : rows
        var out: [(label: String, amount: Double)] = shown.map { (label: $0.label, amount: $0.amount) }
        if rows.count > 3 {
            let rest = rows.dropFirst(2)
            out.append((label: String(format: loc("stats.nonflow.more"), rest.count),
                        amount: rest.reduce(0.0) { $0 + $1.amount }))
        }
        return out
    }
}
