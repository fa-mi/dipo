import Foundation

// MARK: - The large widget's period
//
// The large Home Screen widget shows what Home's period card shows: what is
// left, the period line (living costs in ink, debt paid and money put away in
// blue, the rest empty) with today marked above it, the days to payday, the
// three categories the most went to, and the monthly expenses still due before
// payday.
//
// The widget is another process and can't read SwiftData or the app's
// helpers, so WidgetDataSync computes this once, with the same helpers Home
// uses, and writes it to the App Group as JSON under `storeKey`. The widget
// decodes it with a copy of these field names (DiPoWidget.swift,
// `WidgetPeriodDetail`); WidgetPeriodDetailTests pins them on this side.

struct WidgetPeriodDetail: Codable, Equatable {

    struct Category: Codable, Equatable {
        var label: String
        var amount: String
        /// This category's share of the period's spending, 0…1.
        var share: Double
        /// The category's circle colour (TxCategory.iconBg) and SF Symbol.
        var hex: String
        var symbol: String
    }

    struct Bill: Codable, Equatable {
        var label: String
        /// "27 Nov", in the app's language.
        var due: String
        var amount: String
    }

    /// Living costs as a share of income: the ink part of the line.
    var living: Double
    /// Debt paid and money put away, as a share of income: the blue part.
    var putAway: Double
    /// Where today sits in the period, 0…1; nil when nothing marks it.
    var today: Double?
    /// "6 hari lagi gajian"; nil without a salary schedule.
    var payday: String?
    /// At most three, largest first. Living categories only: debt paid and
    /// money put away are the blue part of the line, not where money went.
    var categories: [Category]
    /// At most three, earliest first.
    var bills: [Bill]

    var labelToday: String
    var labelTop: String
    var labelBills: String
    var labelNoBills: String

    static let storeKey = "widget.periodDetail"

    /// Categories kept apart from living costs, as on Home and Statistics.
    static let keptApart: Set<TxCategory> = [.debtPayment, .investment]

    /// Built from the same rows Home's period card reads (the pot's and the
    /// credit cards' purchases, since the period opened).
    ///
    /// - Parameters:
    ///   - spending: the period's rows, transfers included (they are skipped).
    ///   - income: the period's income, as the widget's other sizes show it.
    ///   - convert: a row's amount in `currency`, signed.
    static func make(spending: [TxRecord], income: Double,
                     period: (start: Date, end: Date)?, now: Date,
                     daysToPayday: Int?, bills: [ScheduledBill], currency: String,
                     convert: (TxRecord) -> Double) -> WidgetPeriodDetail {
        let money = { CurrencyManager.shared.formatted($0, currency: currency) }
        let living = StatisticsView.living(spending, convert: convert)
        let putAway = keptApart.reduce(0.0) { $0 + PeriodCashBook.categorySpend(spending, $1, convert: convert) }

        // Where the money went, by category, refunds netted: the categories
        // Statistics lists, without the kept-apart ones.
        var byCategory: [TxCategory: Double] = [:]
        for tx in spending where tx.txSubtype != .transfer && !keptApart.contains(tx.category) {
            let a = abs(convert(tx))
            if tx.txSubtype == .refund { byCategory[tx.category, default: 0] -= a }
            else if tx.amount < 0 { byCategory[tx.category, default: 0] += a }
        }
        let top = byCategory.filter { $0.value >= 0.5 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            .prefix(3)
        let categories = top.map { cat, amount in
            Category(label: cat.displayLabel, amount: money(amount),
                     share: living > 0 ? min(amount / living, 1) : 0,
                     hex: cat.iconBg, symbol: cat.icon)
        }

        let dueFormat = DateFormatterCache.template("dMMM")
        let billRows = bills.prefix(3).map {
            Bill(label: $0.label, due: dueFormat.string(from: $0.due), amount: money($0.amount))
        }

        let today: Double? = period.flatMap { p in
            let span = p.end.timeIntervalSince(p.start)
            guard span > 0 else { return nil }
            return min(max(now.timeIntervalSince(p.start) / span, 0), 1)
        }

        return WidgetPeriodDetail(
            living: income > 0 ? living / income : 0,
            putAway: income > 0 ? putAway / income : 0,
            today: today,
            payday: HomeTotalRow.paydayText(days: daysToPayday),
            categories: Array(categories),
            bills: Array(billRows),
            labelToday: loc("home.today_mark"),
            labelTop: loc("widget.large.top"),
            labelBills: loc("widget.large.bills"),
            labelNoBills: loc("widget.large.no_bills"))
    }
}
