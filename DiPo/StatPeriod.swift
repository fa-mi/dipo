import SwiftUI
import SwiftData

// Moved out of StatisticsView.swift, unchanged. Used by a dozen screens, so it lives on its own.

// MARK: - Statistics Date Period

enum StatPeriod: String, CaseIterable {
    case thisMonth  = "This Month"
    case lastMonth  = "Last month"
    case payCycle   = "Pay cycle"
    case last3      = "3 months"
    case last6      = "6 months"
    case thisYear   = "This year"
    case allTime    = "All time"
    case custom     = "Custom"

    /// Localized label for UI. rawValue stays English for internal logic.
    var title: String {
        switch self {
        case .thisMonth:  return loc("stats.period.this_month")
        case .lastMonth:  return loc("stats.period.last_month")
        case .payCycle:   return loc("stats.period.pay_cycle")
        case .last3:      return loc("stats.period.3months")
        case .last6:      return loc("stats.period.6months")
        case .thisYear:   return loc("stats.period.this_year")
        case .allTime:    return loc("stats.period.all_time")
        case .custom:     return loc("stats.period.custom")
        }
    }

    func dateRange() -> (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .thisMonth:
            let start = cal.safeDate(from: cal.dateComponents([.year, .month], from: now))
            return (start, now)
        case .lastMonth:
            let thisMonthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: now))
            let start = cal.safeDate(byAdding: .month, value: -1, to: thisMonthStart)
            return (start, thisMonthStart)
        case .payCycle:
            // Fallback anchor = 1st of month. The view overrides this with the
            // real payday via `StatPeriod.payCycleRange(payDay:)`; this branch
            // only runs if there's no active salary schedule to anchor on.
            let start = cal.safeDate(from: cal.dateComponents([.year, .month], from: now))
            return (start, now)
        case .last3:
            return (cal.safeDate(byAdding: .month, value: -3, to: now), now)
        case .last6:
            return (cal.safeDate(byAdding: .month, value: -6, to: now), now)
        case .thisYear:
            let start = cal.safeDate(from: cal.dateComponents([.year], from: now))
            return (start, now)
        case .allTime:
            return (Date.distantPast, now)
        case .custom:
            return (now, now) // overridden by custom state
        }
    }

    /// Pay-cycle window (payday → now) anchored on a day-of-month. e.g. payday
    /// 25 → the current cycle runs from the 25th of this-or-last month up to
    /// today. Months without the exact day are handled by clamping the anchor
    /// to the 28th so short months never skip it (fine for the common 1–28
    /// paydays).
    /// Snaps a computed cycle start onto the salary transaction that actually
    /// opened it, when one sits within a day or two.
    ///
    /// A SAFETY NET, not a fix for a known defect — worth saying plainly,
    /// because it was added on a wrong premise. It looked like the engine's
    /// computed payday and the recorded salary disagreed, but that came from
    /// reading exported UTC timestamps as local dates: a salary at 00:00 WIB
    /// exports as 17:00 UTC the previous day. Read in the device's own zone,
    /// `SalaryDateEngine.actualPayDate` matches every recorded salary exactly.
    ///
    /// What it still guards is real: a hand-entered salary landing a day off the
    /// scheduled one, which would otherwise fall outside its own cycle. The
    /// tolerance is deliberately tight — wide enough for that, too narrow to
    /// grab an unrelated salary-category row and move the boundary onto it.
    static func anchoredStart(_ computed: Date, salaryDates: [Date],
                              toleranceDays: Int = 2) -> Date {
        let cal = Calendar.current
        let base = cal.startOfDay(for: computed)
        var best: Date? = nil
        var bestGap = Int.max
        for raw in salaryDates {
            let d = cal.startOfDay(for: raw)
            let gap = abs(cal.dateComponents([.day], from: d, to: base).day ?? .max)
            if gap <= toleranceDays, gap < bestGap { bestGap = gap; best = d }
        }
        return best ?? base
    }

    static func payCycleRange(payDay: Int, now: Date = Date()) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let month = cal.component(.month, from: today)
        let year  = cal.component(.year,  from: today)

        // Anchor on the ACTUAL pay date — the same business-day-adjusted date
        // the payday banner shows. Using the raw day-of-month meant that when
        // payday fell on a weekend and the salary was pulled earlier (e.g. paid
        // Fri 24th for a 25th payday), the budget cycle did NOT roll over on the
        // day you were actually paid: the new salary landed inside the OLD
        // cycle, so Home said "Payday is TODAY" while the budget still showed
        // last cycle's spending.
        let thisMonthPay = cal.startOfDay(
            for: SalaryDateEngine.actualPayDate(dayOfMonth: payDay, month: month, year: year))
        if today >= thisMonthPay { return (thisMonthPay, now) }

        let prevMonth = month == 1 ? 12 : month - 1
        let prevYear  = month == 1 ? year - 1 : year
        let lastPay = cal.startOfDay(
            for: SalaryDateEngine.actualPayDate(dayOfMonth: payDay, month: prevMonth, year: prevYear))
        return (lastPay, now)
    }

    // MARK: The pay cycle, one definition
    //
    // Home, Statistics, Smart Budget, the score and the full explanation each
    // worked out the cycle themselves: some snapped the start onto the day the
    // salary actually landed and some did not, and most ended it "start plus
    // one month" — the 25th — when the next salary lands on Friday the 23rd.
    // The same screen then counted different days left from the next one, and
    // a salary paid a day early opened the new cycle on one screen only.

    /// The scheduled payday (business-day adjusted, start of day) `months`
    /// after the one in `month`'s calendar month.
    private static func scheduledPayday(_ payDay: Int, monthsAfter months: Int, from month: Date) -> Date {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month], from: month)
        let first = cal.safeDate(from: DateComponents(year: c.year, month: c.month, day: 1))
        let target = cal.safeDate(byAdding: .month, value: months, to: first)
        let t = cal.dateComponents([.year, .month], from: target)
        return cal.startOfDay(for: SalaryDateEngine.actualPayDate(
            dayOfMonth: payDay, month: t.month ?? 1, year: t.year ?? 2000))
    }

    /// Where the pay cycle `offset` cycles from the running one begins: 0 is
    /// the running cycle's start, 1 the next payday, -1 the previous start.
    /// Each boundary is snapped onto the salary that actually opened it, and a
    /// salary that has already landed early opens its cycle on that day.
    static func cycleBoundary(offset: Int, payDay: Int, salaryDates: [Date],
                              now: Date = Date()) -> Date {
        let today = Calendar.current.startOfDay(for: now)
        // The scheduled payday that opened the running cycle, unsnapped. Its
        // month — not the snapped date's — is what later paydays count from,
        // or a salary landing on the 31st for a payday on the 1st would put
        // the next one a month late.
        var base = payCycleRange(payDay: payDay, now: now).start
        let next = scheduledPayday(payDay, monthsAfter: 1, from: base)
        if anchoredStart(next, salaryDates: salaryDates) <= today { base = next }
        return anchoredStart(scheduledPayday(payDay, monthsAfter: offset, from: base),
                             salaryDates: salaryDates)
    }

    /// The running pay cycle as [start, end): from the day the salary landed
    /// to the next payday.
    static func cycle(payDay: Int, salaryDates: [Date], now: Date = Date()) -> (start: Date, end: Date) {
        let start = cycleBoundary(offset: 0, payDay: payDay, salaryDates: salaryDates, now: now)
        let end = cycleBoundary(offset: 1, payDay: payDay, salaryDates: salaryDates, now: now)
        return (start, max(end, start.addingTimeInterval(86_400)))
    }

    /// Day N of M for a running cycle — today counted, the next payday not.
    static func cycleDay(_ cycle: (start: Date, end: Date), now: Date = Date()) -> (day: Int, of: Int) {
        let cal = Calendar.current
        let total = max(cal.dateComponents([.day], from: cycle.start, to: cycle.end).day ?? 30, 1)
        let day = (cal.dateComponents([.day], from: cycle.start, to: cal.startOfDay(for: now)).day ?? 0) + 1
        return (min(max(day, 1), total), total)
    }

    /// Days still to run in the cycle, today included.
    static func daysLeft(in cycle: (start: Date, end: Date), now: Date = Date()) -> Int {
        let cal = Calendar.current
        return max(cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cycle.end).day ?? 0, 0)
    }

    /// Dates the salary landed on `card` — what cycle boundaries snap onto.
    static func salaryDates(on card: BankCard?) -> [Date] {
        (card?.transactions ?? []).filter { $0.category == .salary && $0.amount > 0 }.map(\.date)
    }
}
