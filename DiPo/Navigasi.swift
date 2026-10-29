import Foundation

// MARK: - DiPo Navigasi
//
// An add-on, off until it is switched on in Profile. One savings goal is the
// destination and the monthly set-aside is the route; each pay cycle is a
// turn. DiPo says what the next turn is (payday, then set aside; a bill that
// falls due before it), when the trip arrives, and — when a cycle's set-aside
// is still short a week after payday — that it is off route, with the date it
// arrives without the rest.
//
// The arrival is counted in pay cycles from the start of this one, so it
// holds still while the plan is kept and moves only when a set-aside is
// missed. A goal's own "reached around" estimate counts from today and drifts
// within a month; while a goal is navigated to, its screens use this one.
//
// The trip lives in UserDefaults, like Smart Budget's settings: it is a
// choice made on this phone, not a record. Its monthly amount is the goal's
// own `monthlyContribution`, kept in the store and in backups, so editing the
// goal's plan reroutes the trip.

enum Navigasi {

    /// Profile → Add-ons. Off until turned on; turning it off hides every
    /// entry and keeps the trip, so turning it on again picks it up.
    static let enabledKey = "addon_navigasi"
    /// The trip under way, as JSON. Removed when it ends and when another
    /// account signs in on this phone.
    static let tripKey = "navi_trip"

    // MARK: The trip

    /// What the faster route is paid for with: spending less in one category.
    struct Toll: Codable, Equatable {
        let categoryRaw: String
        /// Less to spend in it each month.
        let cut: Double
        /// What it took a month when the route was chosen.
        let average: Double

        var category: TxCategory? { TxCategory(rawValue: categoryRaw) }
        /// What the category may take each month on this route.
        var limit: Double { max(average - cut, 0) }
    }

    struct Trip: Codable, Equatable {
        var goalID: UUID
        var toll: Toll?
        var startedAt: Date
        /// The cycle (`Cycle.key`) in which the user took the later arrival
        /// rather than catching up. Off route stops being said until the next.
        var acceptedCycle: String?

        static func decode(_ data: Data) -> Trip? {
            data.isEmpty ? nil : try? JSONDecoder().decode(Trip.self, from: data)
        }

        var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    }

    // MARK: Pay cycles

    /// From one payday to the next, or the calendar month without a salary.
    struct Cycle: Equatable {
        let start: Date
        let end: Date
        /// Begins on payday, rather than on the 1st.
        let fromPayday: Bool

        /// The day it starts, as "2026-10-25".
        var key: String { DailyCheckIn.key(start) }
    }

    /// The calendar month `now` falls in.
    static func month(of now: Date, calendar cal: Calendar = .current) -> Cycle {
        let start = cal.dateInterval(of: .month, for: now)?.start ?? cal.startOfDay(for: now)
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? now
        return Cycle(start: start, end: end, fromPayday: false)
    }

    /// The pay cycle `now` falls in, as Home, Statistics and Smart Budget
    /// count it (StatPeriod): from the day the salary landed to the next payday.
    static func payCycle(payDay: Int, salaryDates: [Date], now: Date = .now) -> Cycle {
        let c = StatPeriod.cycle(payDay: payDay, salaryDates: salaryDates, now: now)
        return Cycle(start: c.start, end: c.end, fromPayday: true)
    }

    /// A week after payday, or the last ten days of a month without one: by
    /// then a set-aside still short is a missed turn, not a late one.
    static func isLate(_ cycle: Cycle, now: Date, calendar cal: Calendar = .current) -> Bool {
        let from = cycle.fromPayday
            ? cal.date(byAdding: .day, value: 7, to: cycle.start)
            : cal.date(byAdding: .day, value: -10, to: cycle.end)
        return now >= (from ?? cycle.end)
    }

    // MARK: Arrival

    /// When the goal is reached: what this cycle still has to set aside, then
    /// `monthly` every cycle after it. Nil without a monthly amount.
    static func arrival(remaining: Double, monthly: Double, stillThisCycle: Double,
                        cycle: Cycle, now: Date, calendar cal: Calendar = .current) -> Date? {
        guard monthly > 0 else { return nil }
        let after = max(remaining - stillThisCycle, 0)
        // A hair under, so 8.000.000 at 2.000.000 is four cycles and not five
        // when the division lands a rounding error above 4.
        let cycles = after < 1 ? 0 : Int((after / monthly - 1e-9).rounded(.up))
        guard cycles > 0 else { return max(now, cycle.start) }
        return cal.date(byAdding: .month, value: cycles, to: cycle.start)
    }

    /// Whole months from `now`'s month to `date`'s: "4 yr 1 mo" is 49.
    static func monthsUntil(_ date: Date, from now: Date, calendar cal: Calendar = .current) -> Int {
        let a = cal.dateInterval(of: .month, for: now)?.start ?? now
        let b = cal.dateInterval(of: .month, for: date)?.start ?? date
        return max(cal.dateComponents([.month], from: a, to: b).month ?? 0, 0)
    }

    // MARK: Routes

    struct Route: Equatable, Identifiable {
        enum Kind: String { case plan, onTime, suggested, toll, custom }
        let kind: Kind
        let monthly: Double
        let arrival: Date
        let toll: Toll?
        var id: String { kind.rawValue }
    }

    /// The ways to the goal, earliest first: the goal's own plan, the amount
    /// that gets there by its date, DiPo's suggestion when it has neither,
    /// and the first of those plus what one category gives up.
    ///
    /// `setAside` is what this cycle already put in: it counts toward the
    /// cycle's amount on every route.
    static func routes(remaining: Double, plan: Double, targetDate: Date?, toll: Toll?,
                       setAside: Double, cycle: Cycle, now: Date, currency: String,
                       calendar cal: Calendar = .current) -> [Route] {
        guard remaining >= 1 else { return [] }
        var candidates: [(kind: Route.Kind, monthly: Double, toll: Toll?)] = []
        if plan > 0 { candidates.append((.plan, plan, nil)) }

        var onTime: Double?
        if let target = targetDate, target > cycle.start {
            // Every cycle that starts by the date, this one included.
            let cycles = (cal.dateComponents([.month], from: cycle.start, to: target).month ?? 0) + 1
            let need = niceUp((remaining + setAside) / Double(cycles), currency: currency)
            if abs(need - plan) > max(plan * 0.05, smallStep(currency)) {
                candidates.append((.onTime, need, nil))
                onTime = need
            }
        }
        if plan <= 0 && onTime == nil {
            candidates.append((.suggested, max(nice(remaining / 12, currency: currency), smallStep(currency)), nil))
        }
        if let toll, let base = candidates.first?.monthly {
            candidates.append((.toll, base + toll.cut, toll))
        }

        var seen: Set<Double> = []
        var routes: [Route] = candidates.compactMap { c in
            guard c.monthly > 0, seen.insert(c.monthly).inserted,
                  let date = arrival(remaining: remaining, monthly: c.monthly,
                                     stillThisCycle: max(c.monthly - setAside, 0),
                                     cycle: cycle, now: now, calendar: cal)
            else { return nil }
            return Route(kind: c.kind, monthly: c.monthly, arrival: date, toll: c.toll)
        }
        // A toll that gets there no sooner than the route it is added to is
        // no route at all.
        if let base = routes.first, let toll = routes.first(where: { $0.kind == .toll }),
           monthsUntil(base.arrival, from: toll.arrival, calendar: cal) == 0 {
            routes.removeAll { $0.kind == .toll }
        }
        return routes.sorted { ($0.arrival, $0.monthly) < ($1.arrival, $1.monthly) }
    }

    /// The route for an amount the user types.
    static func custom(_ monthly: Double, remaining: Double, setAside: Double, cycle: Cycle,
                       now: Date, calendar cal: Calendar = .current) -> Route? {
        guard monthly > 0, let date = arrival(remaining: remaining, monthly: monthly,
                                               stillThisCycle: max(monthly - setAside, 0),
                                               cycle: cycle, now: now, calendar: cal)
        else { return nil }
        return Route(kind: .custom, monthly: monthly, arrival: date, toll: nil)
    }

    // MARK: The toll

    /// Where a faster route can come from: wants, not needs. Food is left out
    /// even when it is eating out — for many people it is the meal.
    static let tollCategories: [TxCategory] = [.shopping, .travel]

    /// The category among `tollCategories` with the most spent a month over
    /// the last three full months, and three tenths of it to give up — nil
    /// when nothing there is worth cutting.
    static func toll(transactions: [TxRecord], currency: String, now: Date,
                     calendar cal: Calendar = .current) -> Toll? {
        guard let thisMonth = cal.dateInterval(of: .month, for: now)?.start,
              let from = cal.date(byAdding: .month, value: -3, to: thisMonth) else { return nil }
        let spending = transactions.filter {
            $0.amount < 0 && $0.txSubtype == .normal && $0.date >= from && $0.date < thisMonth
        }
        // Over the months that have any spending at all, so a phone with one
        // month of history is not averaged over three.
        let months = Set(spending.map { cal.dateComponents([.year, .month], from: $0.date) }).count
        guard months > 0 else { return nil }
        let cm = CurrencyManager.shared
        let best = tollCategories.map { cat -> (TxCategory, Double) in
            let total = spending.filter { $0.category == cat }.reduce(0.0) {
                $0 + cm.convert(abs($1.amount), from: $1.currency.isEmpty ? currency : $1.currency, to: currency)
            }
            return (cat, total / Double(months))
        }.max { $0.1 < $1.1 }
        guard let best, best.1 >= minimumSpend(currency) else { return nil }
        let (category, average) = best
        let cut = nice(average * 0.3, currency: currency)
        guard cut >= smallStep(currency), cut < average else { return nil }
        return Toll(categoryRaw: category.rawValue, cut: cut,
                    average: SmartRecommendationEngine.measuredValue(average, currency: currency))
    }

    // MARK: Where the trip stands

    enum Leg: Equatable {
        /// The goal is reached.
        case arrived
        /// This much of the cycle's set-aside is still to make, in good time.
        case setAside(Double)
        /// The cycle's set-aside is made; the next turn is the next cycle.
        case done
        /// Late in the cycle and short by this much. Without it, the trip
        /// arrives on `arrival`, later than planned.
        case behind(short: Double, arrival: Date)
        /// Short this cycle, and the user took the later arrival.
        case accepted(arrival: Date)
    }

    /// Where the trip stands this cycle, at `monthly` a cycle.
    /// `acceptedCycle` is the trip's: the cycle the later arrival was taken in.
    static func leg(monthly: Double, acceptedCycle: String?, remaining: Double, setAside: Double,
                    cycle: Cycle, now: Date, calendar cal: Calendar = .current) -> Leg {
        guard remaining >= 1 else { return .arrived }
        // The last stretch can be less than a whole month's amount.
        let due = min(max(monthly - setAside, 0), remaining)
        guard due >= 1 else { return .done }
        let onRoute = arrival(remaining: remaining, monthly: monthly, stillThisCycle: due,
                              cycle: cycle, now: now, calendar: cal)
        let without = arrival(remaining: remaining, monthly: monthly, stillThisCycle: 0,
                              cycle: cycle, now: now, calendar: cal)
        guard let onRoute, let without else { return .setAside(due) }
        // Short by too little to move the month: nothing to warn about.
        let slips = monthsUntil(without, from: onRoute, calendar: cal) > 0
        if slips && acceptedCycle == cycle.key { return .accepted(arrival: without) }
        if slips && isLate(cycle, now: now, calendar: cal) { return .behind(short: due, arrival: without) }
        return .setAside(due)
    }

    // MARK: The trip, now

    /// The trip to its goal as it stands, worked out once for every screen
    /// that shows it: Navigasi, Plan's row, the goal's own screen and DiPo on
    /// Home.
    struct Status {
        let trip: Trip
        let cycle: Cycle
        /// Put in this cycle so far.
        let setAside: Double
        let leg: Leg
        /// When it arrives on the route it is on: the plan, or the later date
        /// once that was taken.
        let arrival: Date?
    }

    /// `payDay` and `salaryDates` are the main salary's, as MainCard and
    /// StatPeriod give them; without a salary the cycle is the month.
    static func status(of trip: Trip, goal: SavingsGoal, transactions: [TxRecord],
                       payDay: Int?, salaryDates: [Date], now: Date = .now) -> Status {
        let cycle = payDay.map { payCycle(payDay: $0, salaryDates: salaryDates, now: now) } ?? month(of: now)
        let put = setAside(to: goal, transactions: transactions, since: cycle.start)
        let monthly = goal.monthlyContribution
        let remaining = goal.isCompleted ? 0 : goal.remaining
        let stage = Self.leg(monthly: monthly, acceptedCycle: trip.acceptedCycle, remaining: remaining,
                             setAside: put, cycle: cycle, now: now)
        let eta: Date?
        switch stage {
        case .arrived:
            eta = now
        case .accepted(let later):
            eta = later
        case .setAside(let due), .behind(let due, _):
            eta = Self.arrival(remaining: remaining, monthly: monthly, stillThisCycle: due, cycle: cycle, now: now)
        case .done:
            eta = Self.arrival(remaining: remaining, monthly: monthly, stillThisCycle: 0, cycle: cycle, now: now)
        }
        return Status(trip: trip, cycle: cycle, setAside: put, leg: stage, arrival: eta)
    }

    /// The same, from what the screens query.
    static func status(of trip: Trip, goal: SavingsGoal, cards: [BankCard],
                       salaries: [SalarySchedule], now: Date = .now) -> Status {
        status(of: trip, goal: goal, transactions: cards.flatMap(\.transactions),
               payDay: MainCard.payDay(salaries),
               salaryDates: StatPeriod.salaryDates(on: MainCard.resolve(in: cards)), now: now)
    }

    /// What DiPo says on Home about the trip, only when there is a turn to
    /// take: the set-aside in the first days of a cycle, and off route.
    static func nudge(_ status: Status, goal: SavingsGoal, now: Date = .now,
                      calendar cal: Calendar = .current) -> DiPoNudge.Navi? {
        let cm = CurrencyManager.shared
        let name = "\(goal.emoji) \(goal.name)"
        switch status.leg {
        case .setAside(let due):
            let days = cal.dateComponents([.day], from: status.cycle.start, to: cal.startOfDay(for: now)).day ?? 0
            guard days <= DiPoNudge.window else { return nil }
            return DiPoNudge.Navi(
                id: "navi-set-\(status.cycle.key)",
                title: String(format: loc("navi.nudge_set_aside"), cm.formatted(due, currency: goal.currency), name),
                detail: status.arrival.map { String(format: loc("navi.nudge_keep"), monthYear($0)) } ?? "",
                worry: false)
        case .behind(let short, let later):
            return DiPoNudge.Navi(
                id: "navi-behind-\(status.cycle.key)",
                title: String(format: loc("navi.nudge_behind"), cm.formatted(short, currency: goal.currency)),
                detail: String(format: loc("navi.nudge_without"), name, monthYear(later)),
                worry: true)
        case .arrived, .done, .accepted:
            return nil
        }
    }

    // MARK: Words

    /// "Des 2030", in the app's language.
    static func monthYear(_ date: Date) -> String {
        DateFormatterCache.template("MMMyyyy").string(from: date)
    }

    /// "4 thn 1 bln", "10 bln", "1 thn"; "bulan ini" for none.
    static func duration(months: Int) -> String {
        let years = months / 12, rest = months % 12
        switch (years, rest) {
        case (0, 0): return loc("navi.dur_now")
        case (0, _): return String(format: loc("navi.dur_m"), rest)
        case (_, 0): return String(format: loc("navi.dur_y"), years)
        default:     return String(format: loc("navi.dur_ym"), years, rest)
        }
    }

    /// Put toward the goal since `start`: deposits into it, and for a goal
    /// kept in investments, what was paid for units bought in them. A price
    /// moving is not a set-aside, so value is not compared.
    static func setAside(to goal: SavingsGoal, transactions: [TxRecord], since start: Date) -> Double {
        let cm = CurrencyManager.shared
        let id = goal.id.uuidString
        let deposits = transactions
            .filter { $0.linkedGoalID == id && $0.amount < 0 && $0.date >= start }
            .reduce(0.0) {
                $0 + cm.convert(abs($1.amount), from: $1.currency.isEmpty ? goal.currency : $1.currency,
                                to: goal.currency)
            }
        let bought = goal.holdings.reduce(0.0) { sum, holding in
            let paid = holding.lots
                .filter { $0.kind == .buy && $0.date >= start }
                .reduce(0.0) { $0 + $1.units * $1.pricePerUnit + $1.fee }
            return sum + cm.convert(paid, from: holding.currency, to: goal.currency)
        }
        return deposits + bought
    }

    /// Spent in `category` since `start`, as money out of the person's pocket.
    static func spent(in category: TxCategory, transactions: [TxRecord], since start: Date,
                      currency: String) -> Double {
        let cm = CurrencyManager.shared
        return transactions
            .filter { $0.category == category && $0.amount < 0 && $0.txSubtype == .normal && $0.date >= start }
            .reduce(0.0) {
                $0 + cm.convert(abs($1.amount), from: $1.currency.isEmpty ? currency : $1.currency, to: currency)
            }
    }

    // MARK: Amounts

    /// The smallest amount worth a route of its own.
    private static func smallStep(_ currency: String) -> Double { currency == "IDR" ? 50_000 : 5 }
    private static func minimumSpend(_ currency: String) -> Double { currency == "IDR" ? 200_000 : 20 }

    /// A figure to say: Rp 1.237.400 is Rp 1.250.000. Whole units elsewhere.
    static func nice(_ v: Double, currency: String) -> Double {
        currency == "IDR" ? SmartRecommendationEngine.roundNice(v) : v.rounded()
    }

    /// Never below `v`, and in finer steps than `nice`: an amount that must
    /// get there on time, without arriving months early (Rp 2.061.667 is
    /// Rp 2.100.000, not Rp 2.250.000).
    static func niceUp(_ v: Double, currency: String) -> Double {
        guard currency == "IDR" else { return v.rounded(.up) }
        let step: Double
        switch v {
        case ..<100_000:    step = 5_000
        case ..<1_000_000:  step = 10_000
        case ..<10_000_000: step = 50_000
        default:            step = 100_000
        }
        return (v / step - 1e-9).rounded(.up) * step
    }
}
