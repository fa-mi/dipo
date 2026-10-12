import Foundation

// MARK: - Statistics' headline, for the web dashboard
//
// The dashboard's hero still read the period the way the phone stopped
// reading it: income minus everything that went out, a credit-card payment
// included, under "Over budget this cycle" in red. Fahmi's Rp 3,9 jt card
// payment made a healthy card look like trouble on the big screen while the
// phone said "Safe until payday".
//
// The phone now opens on whether the money lasts to payday, the balance, what
// payday should find, living costs against income with debt paid kept apart,
// and a cash book that adds up to the balance. This builds that same headline
// for the sync — the figures, and the sentences in both languages, from the
// functions Statistics itself uses (PeriodCashBook and its words). The web
// prints it and decides nothing.
//
// Only for the running pay cycle, which is what the dashboard's hero covers.

enum WebPeriodView {

    /// The pay cycle being read: where it opened, how far in it is, and the
    /// projection and comparison Statistics shows for it.
    struct Cycle {
        let start: Date
        let now: Date
        let progress: (elapsed: Int, total: Int)?
        /// `StatisticsView.projectedCycleSpend`; nil before anything is spent.
        let projected: Double?
        /// Spending over the same days of the previous cycle.
        let previousSpent: Double?
    }

    /// Statistics' `cashBook` for a caller that is not the screen: the pot's
    /// balance when the cycle opened, every row in it since, and the money in
    /// the person added to this period's budget. `pot` is the main card first,
    /// then the cards it pays bills from.
    static func book(pot: [BankCard], from start: Date, to end: Date, currency: String,
                     extraIDs: [String] = SmartBudgetManager.shared.extraFundTxIDs) -> PeriodCashBook? {
        guard let main = pot.first else { return nil }
        let convert = converter(main: main, currency: currency)
        let cm = CurrencyManager.shared
        // Summed over the pot, as `periodStartBalance` is: money moved between
        // its cards cancels out.
        let opening = pot.reduce(0.0) { sum, card in
            let seed = cm.convert(card.balance, from: card.resolvedCurrency, to: currency)
            let before = card.transactions.filter { $0.date < start }.reduce(0.0) { $0 + convert($1) }
            return sum + seed + before
        }
        let window = pot.flatMap(\.transactions).filter { $0.date >= start && $0.date <= end }
        var book = PeriodCashBook.build(window, start: opening, convert: convert)
        book.extraFunds = ExtraFunds.total(in: window, from: .distantPast, currency: currency, ids: extraIDs)
        return book
    }

    /// The headline as the dashboard reads it. Nil without a main card.
    static func payload(pot: [BankCard], cards: [BankCard], cycle: Cycle, currency: String,
                        extraIDs: [String] = SmartBudgetManager.shared.extraFundTxIDs) -> [String: Any]? {
        guard let main = pot.first,
              let book = Self.book(pot: pot, from: cycle.start, to: cycle.now, currency: currency,
                                   extraIDs: extraIDs)
        else { return nil }

        let cal = Calendar.current
        // As `paydayOutlook`: the next payday is the cycle's length on from
        // its first day.
        let outlook: (payday: Date, end: Double)? = {
            guard let projected = cycle.projected, let p = cycle.progress,
                  let payday = cal.date(byAdding: .day, value: p.total, to: cal.startOfDay(for: cycle.start))
            else { return nil }
            return (payday, book.endAtPayday(projected: projected))
        }()
        // Red only when the balance is on course to run out.
        let danger = (outlook?.end ?? book.end) < 0.5
        let change: Double? = cycle.previousSpent.flatMap { prev in
            prev > 0 ? (book.spent - prev) / prev * 100 : nil
        }
        let window = pot.flatMap(\.transactions).filter { $0.date >= cycle.start && $0.date <= cycle.now }
        let ownLines = OwnMoves.lines(window, scope: pot, cards: cards,
                                      convert: converter(main: main, currency: currency))

        func inLanguage(_ language: LanguageManager.Language) -> [String: Any] {
            LanguageManager.shared.withLanguage(language) {
                Self.words(book, main: main, pot: pot, cycle: cycle, outlook: outlook, change: change,
                           ownLines: ownLines, currency: currency, language: language)
            }
        }

        var out: [String: Any] = [
            "balance":     book.end,
            "start":       book.start,
            "income":      book.income,
            "living":      book.living,
            "debtPaid":    book.debtPaid,
            "invested":    book.invested,
            "extraFunds":  book.extraFunds,
            "livingFunds": book.livingFunds,
            "livingRatio": book.livingRatio,
            "over":        book.livingNet < -0.5,
            "danger":      danger,
            "en":          inLanguage(.english),
            "id":          inLanguage(.indonesian),
        ]
        if let p = cycle.progress, p.total > 0 {
            out["timeMarker"] = Double(p.elapsed) / Double(p.total)
            out["elapsedDays"] = p.elapsed
            out["totalDays"] = p.total
        }
        // The balance day by day, for the dashboard's line.
        let path = trail(window, start: book.start, from: cycle.start, to: cycle.now,
                         convert: converter(main: main, currency: currency))
        out["trail"] = path.balances
        out["marks"] = path.marks
        if let outlook {
            out["paydayISO"] = ISO8601DateFormatter().string(from: outlook.payday)
            out["atPayday"] = outlook.end
            out["safe"] = outlook.end >= 0.5
        }
        if let pace = PeriodCashBook.paceSentence(projected: cycle.projected, book: book,
                                                  livingFunds: book.livingFunds, money: { _ in "" }) {
            out["paceOk"] = pace.ok
        }
        if let change, abs(change) >= 1 { out["change"] = change }
        return out
    }

    // MARK: Pieces

    struct MarkKey: Hashable {
        let day: Int
        let kind: String
    }

    /// The longest trail sent: two months of days, well past any pay cycle.
    static let maxTrailDays = 62

    /// The pot's balance at the end of each day from `from` to `to`, oldest
    /// first, ending on the balance at `to` — the line the dashboard draws.
    /// With the days money came in or went to a debt, so the line's jumps
    /// can be named: salary, money in that isn't income, a card paid down.
    /// Kinds only, no names.
    static func trail(_ window: [TxRecord], start: Double, from: Date, to: Date,
                      convert: (TxRecord) -> Double,
                      calendar: Calendar = .current) -> (balances: [Double], marks: [[String: Any]]) {
        let first = calendar.startOfDay(for: from)
        let span = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: to)).day ?? 0
        let days = min(max(span + 1, 1), maxTrailDays)
        var moved = Array(repeating: 0.0, count: days)
        var marks: [MarkKey: Double] = [:]
        for tx in window where tx.date <= to {
            let raw = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: tx.date)).day ?? 0
            let i = min(max(raw, 0), days - 1)
            let v = convert(tx)
            moved[i] += v
            let kind: String?
            if tx.txSubtype == .normal && tx.amount > 0 {
                kind = "income"
            } else if tx.txSubtype == .transfer && tx.amount > 0
                        && !NonFlowMovements.isOwnAccountMove(tx, incoming: true) {
                kind = "in"
            } else if tx.category == .debtPayment && tx.amount < 0 && tx.txSubtype != .transfer {
                kind = "debt"
            } else {
                kind = nil
            }
            if let kind { marks[MarkKey(day: i, kind: kind), default: 0] += abs(v) }
        }
        var running = start
        var balances: [Double] = []
        for m in moved {
            running += m
            balances.append(running)
        }
        let order = ["income": 0, "in": 1, "debt": 2]
        let markRows: [[String: Any]] = marks
            .filter { $0.value >= 0.5 }
            .sorted { a, b in
                a.key.day != b.key.day ? a.key.day < b.key.day : (order[a.key.kind] ?? 9) < (order[b.key.kind] ?? 9)
            }
            .map { m -> [String: Any] in ["day": m.key.day, "kind": m.key.kind, "amount": m.value] }
        return (balances, markRows)
    }

    /// A row's amount in `currency`; a legacy row with no currency is in the
    /// main card's, as `cycleFigures` reads it.
    static func converter(main: BankCard, currency: String) -> (TxRecord) -> Double {
        { tx in
            CurrencyManager.shared.convert(tx.amount, from: tx.currency.isEmpty ? main.resolvedCurrency : tx.currency,
                                           to: currency)
        }
    }

    /// "d MMM" in the language being written, not the phone's.
    static func dayFormatter(_ language: LanguageManager.Language) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: language == .indonesian ? "id_ID" : "en_US")
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }

    /// Every sentence and book line, in the language `loc()` currently
    /// resolves to. Called inside `withLanguage`.
    static func words(_ book: PeriodCashBook, main: BankCard, pot: [BankCard], cycle: Cycle,
                      outlook: (payday: Date, end: Double)?, change: Double?,
                      ownLines: [OwnMoves.Line], currency: String,
                      language: LanguageManager.Language) -> [String: Any] {
        let money: (Double) -> String = { CurrencyManager.shared.formatted($0, currency: currency) }
        let signed: (Double) -> String = { ($0 < -0.5 ? "−" : "") + money(abs($0)) }
        let formatter = dayFormatter(language)
        let day: (Date) -> String = { formatter.string(from: $0) }

        var w: [String: Any] = [
            "balanceLabel": loc("stats.balance_now"),
            "lines":        lines(book, cycle: cycle, ownLines: ownLines, money: money, day: day),
        ]
        if let outlook {
            w["pill"] = String(format: loc(outlook.end >= 0.5 ? "stats.safe_until" : "stats.risk_until"),
                               day(outlook.payday))
            w["atPayday"] = String(format: loc("stats.at_payday"), signed(outlook.end))
        }
        if book.livingFunds > 0 {
            w["living"] = book.livingSentence(money: money)
            w["pct"] = String(format: loc("stats.pct_of_income"), PeriodCashBook.usedPct(ratio: book.livingRatio))
            if let change, abs(change) >= 1 {
                w["change"] = String(format: loc("stats.vs_last_period"), String(format: "%.0f%%", abs(change)))
            }
        }
        if let debt = book.debtSentence(money: money) { w["debt"] = debt }
        if let pace = PeriodCashBook.paceSentence(projected: cycle.projected, book: book,
                                                  livingFunds: book.livingFunds, money: money) {
            w["pace"] = pace.text
        } else if book.livingFunds <= 0 {
            w["noIncome"] = loc("stats.no_income_hint")
        }
        if let cover = book.coverSentence(money: money, day: day) { w["cover"] = cover }
        // A debit account can't open below zero; a negative opening is money
        // in that was never logged.
        if book.start < -0.5, !main.isCreditCard {
            w["negStart"] = String(format: loc("stats.book_neg_start"), day(cycle.start))
        }
        if pot.count > 1 {
            w["scope"] = String(format: loc("stats.with_bill_cards"),
                                pot.dropFirst().map(\.pickerLabel).joined(separator: ", "))
        }
        return w
    }

    /// The cash book, line by line, as `cashBookView` lays it out. `amount`
    /// is a magnitude with `op` carrying its direction, except the opening
    /// balance, which can itself be below zero.
    static func lines(_ book: PeriodCashBook, cycle: Cycle, ownLines: [OwnMoves.Line],
                      money: (Double) -> String, day: (Date) -> String) -> [[String: Any]] {
        func line(_ op: String, _ label: String, _ amount: Double, caption: String? = nil,
                  tone: String? = nil, total: Bool = false) -> [String: Any] {
            var l: [String: Any] = ["op": op, "label": label, "amount": amount]
            if let caption { l["caption"] = caption }
            if let tone { l["tone"] = tone }
            if total { l["total"] = true }
            return l
        }

        var out: [[String: Any]] = [
            line("", String(format: loc("stats.book_start"), day(cycle.start)), book.start),
            line("+", loc("stats.recon_income"), book.income),
        ]
        for row in PeriodCashBook.shownRows(book.otherIn) {
            out.append(line("+", row.label, row.amount, caption: loc("stats.book_not_income"), tone: "accent"))
        }
        out.append(line("−", loc("stats.book_living"), book.living))
        if book.debtPaid >= 0.5 {
            out.append(line("−", loc("stats.book_debt"), book.debtPaid,
                            caption: loc("stats.book_debt_note"), tone: "blue"))
        }
        if book.invested >= 0.5 {
            out.append(line("−", loc("stats.book_invest"), book.invested, tone: "blue"))
        }
        for row in PeriodCashBook.shownRows(book.otherOut) {
            out.append(line("−", row.label, row.amount, caption: loc("stats.book_not_spending")))
        }
        if abs(book.ownMoves) >= 0.5 {
            var own = line(book.ownMoves < 0 ? "−" : "+", loc("stats.book_own_moves"), abs(book.ownMoves))
            // Which card, which way, and what came into the other card just
            // before — the breakdown the phone opens on a tap.
            if !ownLines.isEmpty {
                own["details"] = ownLines.map { l -> [String: Any] in
                    [
                        "label":    String(format: loc(l.incoming ? "stats.own_from" : "stats.own_to"), l.label),
                        "amount":   l.amount,
                        "incoming": l.incoming,
                        "sources":  l.sources.map {
                            String(format: loc("stats.own_source"), $0.name, money($0.amount), day($0.date))
                        },
                    ]
                }
            }
            out.append(own)
        }
        out.append(line("=", loc("stats.card_balance_now"), book.end, total: true))
        return out
    }
}
