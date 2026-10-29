import XCTest
import SwiftData
@testable import DiPo

/// DiPo Navigasi: a savings goal as the destination, the monthly set-aside as
/// the route, each pay cycle a turn.
@MainActor
final class NavigasiTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private let cal = Calendar(identifier: .gregorian)

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// A pay cycle opened by a salary on `start`.
    private func payCycle(from start: Date) -> Navigasi.Cycle {
        Navigasi.Cycle(start: start, end: cal.date(byAdding: .month, value: 1, to: start)!, fromPayday: true)
    }

    private func spend(_ amount: Double, _ category: TxCategory, _ date: Date,
                       subtype: TxSubtype = .normal, goal: SavingsGoal? = nil) -> TxRecord {
        TxRecord(name: "x", date: date, amount: amount, type: "tx.type.purchase", icon: "circle",
                 iconBgHex: category.iconBg, category: category, currency: "IDR",
                 linkedGoalID: goal?.id.uuidString ?? "", subtype: subtype)
    }

    // MARK: Arrival

    /// While the plan is kept the arrival holds still: before the set-aside,
    /// after it, and into the next cycle.
    func testTheArrivalHoldsStillWhileThePlanIsKept() {
        let october = payCycle(from: day(2026, 10, 25))
        XCTAssertEqual(Navigasi.arrival(remaining: 10_000_000, monthly: 2_000_000, stillThisCycle: 2_000_000,
                                        cycle: october, now: day(2026, 10, 26), calendar: cal),
                       day(2027, 2, 25))
        XCTAssertEqual(Navigasi.arrival(remaining: 8_000_000, monthly: 2_000_000, stillThisCycle: 0,
                                        cycle: october, now: day(2026, 11, 3), calendar: cal),
                       day(2027, 2, 25), "set aside: the same day")
        let november = payCycle(from: day(2026, 11, 25))
        XCTAssertEqual(Navigasi.arrival(remaining: 8_000_000, monthly: 2_000_000, stillThisCycle: 2_000_000,
                                        cycle: november, now: day(2026, 11, 25), calendar: cal),
                       day(2027, 2, 25), "and in the next cycle")
    }

    func testAMissedSetAsideMovesItAMonth() {
        let november = payCycle(from: day(2026, 11, 25))
        XCTAssertEqual(Navigasi.arrival(remaining: 10_000_000, monthly: 2_000_000, stillThisCycle: 2_000_000,
                                        cycle: november, now: day(2026, 11, 25), calendar: cal),
                       day(2027, 3, 25))
    }

    /// 5,70 at 1,14 a month divides to a hair over 5: five cycles, not six.
    func testAWholeNumberOfCyclesIsNotOneMore() {
        let october = payCycle(from: day(2026, 10, 25))
        XCTAssertEqual(Navigasi.arrival(remaining: 5.70, monthly: 1.14, stillThisCycle: 0,
                                        cycle: october, now: day(2026, 10, 26), calendar: cal),
                       day(2027, 3, 25))
    }

    func testDurationsInBothLanguages() {
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(Navigasi.duration(months: 49), "4 thn 1 bln")
            XCTAssertEqual(Navigasi.duration(months: 10), "10 bln")
            XCTAssertEqual(Navigasi.duration(months: 24), "2 thn")
            XCTAssertEqual(Navigasi.duration(months: 0), "bulan ini")
        }
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(Navigasi.duration(months: 14), "1 yr 2 mo")
        }
        XCTAssertEqual(Navigasi.monthsUntil(day(2030, 12, 25), from: day(2026, 11, 2), calendar: cal), 49)
        XCTAssertEqual(Navigasi.monthsUntil(day(2026, 11, 2), from: day(2030, 12, 25), calendar: cal), 0,
                       "never negative")
    }

    // MARK: Where the trip stands

    func testOffRouteAWeekAfterPayday() {
        let october = payCycle(from: day(2026, 10, 25))
        let early = Navigasi.leg(monthly: 2_000_000, acceptedCycle: nil, remaining: 9_500_000, setAside: 500_000,
                                 cycle: october, now: day(2026, 10, 28), calendar: cal)
        XCTAssertEqual(early, .setAside(1_500_000), "three days in: still in good time")
        let late = Navigasi.leg(monthly: 2_000_000, acceptedCycle: nil, remaining: 9_500_000, setAside: 500_000,
                                cycle: october, now: day(2026, 11, 2), calendar: cal)
        XCTAssertEqual(late, .behind(short: 1_500_000, arrival: day(2027, 3, 25)),
                       "a week in and short: a month later without the rest")
    }

    /// Short by too little to move the month: no warning at all.
    func testAShortfallThatMovesNothingIsNotOffRoute() {
        let october = payCycle(from: day(2026, 10, 25))
        let leg = Navigasi.leg(monthly: 2_000_000, acceptedCycle: nil, remaining: 9_100_000, setAside: 1_900_000,
                               cycle: october, now: day(2026, 11, 10), calendar: cal)
        XCTAssertEqual(leg, .setAside(100_000))
    }

    func testTakingTheLaterArrivalStopsTheWarningForTheCycle() {
        let october = payCycle(from: day(2026, 10, 25))
        let leg = Navigasi.leg(monthly: 2_000_000, acceptedCycle: october.key, remaining: 9_500_000,
                               setAside: 500_000, cycle: october, now: day(2026, 11, 2), calendar: cal)
        XCTAssertEqual(leg, .accepted(arrival: day(2027, 3, 25)))
        let november = payCycle(from: day(2026, 11, 25))
        let next = Navigasi.leg(monthly: 2_000_000, acceptedCycle: october.key, remaining: 9_500_000,
                                setAside: 0, cycle: november, now: day(2026, 12, 3), calendar: cal)
        if case .behind = next {} else { XCTFail("a new cycle says it again: \(next)") }
    }

    func testDoneArrivedAndTheLastStretch() {
        let october = payCycle(from: day(2026, 10, 25))
        XCTAssertEqual(Navigasi.leg(monthly: 2_000_000, acceptedCycle: nil, remaining: 8_000_000, setAside: 2_000_000,
                                    cycle: october, now: day(2026, 11, 10), calendar: cal), .done)
        XCTAssertEqual(Navigasi.leg(monthly: 2_000_000, acceptedCycle: nil, remaining: 0.5, setAside: 0,
                                    cycle: october, now: day(2026, 11, 10), calendar: cal), .arrived)
        XCTAssertEqual(Navigasi.leg(monthly: 2_000_000, acceptedCycle: nil, remaining: 1_200_000, setAside: 0,
                                    cycle: october, now: day(2026, 10, 26), calendar: cal), .setAside(1_200_000),
                       "the last set-aside is what is left, not a whole month's")
    }

    /// Without a salary the cycle is the month, and a set-aside still short in
    /// its last ten days is a missed turn.
    func testAMonthWithoutASalary() {
        let october = Navigasi.month(of: day(2026, 10, 12), calendar: cal)
        XCTAssertEqual(october.start, day(2026, 10, 1))
        XCTAssertEqual(october.end, day(2026, 11, 1))
        XCTAssertFalse(october.fromPayday)
        XCTAssertFalse(Navigasi.isLate(october, now: day(2026, 10, 21), calendar: cal))
        XCTAssertTrue(Navigasi.isLate(october, now: day(2026, 10, 22), calendar: cal))
    }

    // MARK: Routes

    /// The goal's plan, the amount that gets there by its date, and the plan
    /// plus what shopping gives up — earliest first.
    func testRoutesEarliestFirst() {
        let october = payCycle(from: day(2026, 10, 25))
        let toll = Navigasi.Toll(categoryRaw: TxCategory.shopping.rawValue, cut: 1_000_000, average: 1_800_000)
        let routes = Navigasi.routes(remaining: 123_700_000, plan: 2_000_000, targetDate: day(2031, 6, 1),
                                     toll: toll, setAside: 0, cycle: october, now: day(2026, 10, 26),
                                     currency: "IDR", calendar: cal)
        XCTAssertEqual(routes.map(\.kind), [.toll, .onTime, .plan])
        XCTAssertEqual(routes.map(\.monthly), [3_000_000, 2_250_000, 2_000_000])
        XCTAssertEqual(routes.map(\.arrival), [day(2030, 3, 25), day(2031, 4, 25), day(2031, 11, 25)])
        XCTAssertEqual(routes.first?.toll, toll)
        XCTAssertTrue(routes[1].arrival <= day(2031, 6, 1), "on time is by the date")

        // A plan within 5% of what the date needs is on time already.
        let close = Navigasi.routes(remaining: 123_700_000, plan: 2_000_000, targetDate: day(2031, 10, 1),
                                    toll: nil, setAside: 0, cycle: october, now: day(2026, 10, 26),
                                    currency: "IDR", calendar: cal)
        XCTAssertEqual(close.map(\.kind), [.plan])
    }

    func testNoPlanAndNoDateGetsDiPosPick() {
        let october = payCycle(from: day(2026, 10, 25))
        let routes = Navigasi.routes(remaining: 12_000_000, plan: 0, targetDate: nil, toll: nil, setAside: 0,
                                     cycle: october, now: day(2026, 10, 26), currency: "IDR", calendar: cal)
        XCTAssertEqual(routes.map(\.kind), [.suggested])
        XCTAssertEqual(routes.first?.monthly, 1_000_000, "a year's worth a month, as the goal card suggests")
        XCTAssertEqual(routes.first?.arrival, day(2027, 9, 25))
    }

    func testATollThatSavesNoTimeIsNoRoute() {
        let october = payCycle(from: day(2026, 10, 25))
        let toll = Navigasi.Toll(categoryRaw: TxCategory.shopping.rawValue, cut: 500_000, average: 1_800_000)
        let routes = Navigasi.routes(remaining: 1_500_000, plan: 2_000_000, targetDate: nil, toll: toll,
                                     setAside: 0, cycle: october, now: day(2026, 10, 26), currency: "IDR",
                                     calendar: cal)
        XCTAssertEqual(routes.map(\.kind), [.plan])
    }

    func testATypedAmountIsARouteToo() {
        let october = payCycle(from: day(2026, 10, 25))
        let route = Navigasi.custom(2_500_000, remaining: 10_000_000, setAside: 0, cycle: october,
                                    now: day(2026, 10, 26), calendar: cal)
        XCTAssertEqual(route?.kind, .custom)
        XCTAssertEqual(route?.arrival, day(2027, 1, 25))
        XCTAssertNil(Navigasi.custom(0, remaining: 10_000_000, setAside: 0, cycle: october, now: day(2026, 10, 26)))
    }

    func testAmountsToSay() {
        XCTAssertEqual(Navigasi.niceUp(2_061_667, currency: "IDR"), 2_100_000)
        XCTAssertEqual(Navigasi.niceUp(2_100_000, currency: "IDR"), 2_100_000, "already round stays")
        XCTAssertEqual(Navigasi.niceUp(41.2, currency: "USD"), 42)
        XCTAssertEqual(Navigasi.nice(540_000, currency: "IDR"), 550_000)
    }

    // MARK: The toll

    /// Shopping, not food, and not a transfer; averaged over the months with
    /// any spending, this month left out.
    func testTheTollComesFromWantsNotNeeds() throws {
        var tx: [TxRecord] = []
        for month in [7, 8, 9] {
            tx.append(spend(-1_800_000, .shopping, day(2026, month, 10)))
            tx.append(spend(-5_000_000, .food, day(2026, month, 12)))
        }
        tx.append(spend(-600_000, .travel, day(2026, 8, 3)))
        tx.append(spend(-9_000_000, .shopping, day(2026, 9, 20), subtype: .transfer))
        tx.append(spend(-7_000_000, .shopping, day(2026, 10, 2)))
        let toll = try XCTUnwrap(Navigasi.toll(transactions: tx, currency: "IDR", now: day(2026, 10, 15), calendar: cal))
        XCTAssertEqual(toll.category, .shopping)
        XCTAssertEqual(toll.average, 1_800_000, accuracy: 1)
        XCTAssertEqual(toll.cut, 550_000)
        XCTAssertEqual(toll.limit, 1_250_000, accuracy: 1)

        let little = [spend(-150_000, .shopping, day(2026, 9, 5))]
        XCTAssertNil(Navigasi.toll(transactions: little, currency: "IDR", now: day(2026, 10, 15), calendar: cal),
                     "too little to be worth cutting")
    }

    // MARK: Set aside this cycle

    /// Deposits into the goal since the cycle began, and for a goal kept in
    /// shares, what was paid for units bought since — not a price moving.
    func testWhatThisCycleSetAside() throws {
        let goal = SavingsGoal(name: "Trip to Mecca", emoji: "✈️", targetAmount: 150_000_000)
        context.insert(goal)
        let start = day(2026, 10, 25)
        let before = spend(-2_000_000, .investment, day(2026, 10, 20), goal: goal)
        let inCycle = spend(-1_500_000, .investment, day(2026, 10, 26), goal: goal)
        let otherGoal = spend(-3_000_000, .investment, day(2026, 10, 27))
        otherGoal.linkedGoalID = UUID().uuidString

        let shares = InvestmentHolding(type: .stock, name: "BBRI", symbol: "BBRI", currency: "IDR",
                                       lastPrice: 4_000, prevClose: 4_000)
        context.insert(shares)
        let lots = [InvestmentLot(kind: .buy, date: day(2026, 10, 1), units: 100, pricePerUnit: 3_900),
                    InvestmentLot(kind: .buy, date: day(2026, 10, 28), units: 500, pricePerUnit: 4_000),
                    InvestmentLot(kind: .sell, date: day(2026, 10, 29), units: 50, pricePerUnit: 4_100)]
        for lot in lots {
            context.insert(lot)
            shares.lots.append(lot)
        }
        goal.keep(in: [shares])
        try context.save()

        XCTAssertEqual(Navigasi.setAside(to: goal, transactions: [before, inCycle, otherGoal], since: start),
                       1_500_000 + 2_000_000, accuracy: 0.5)
    }

    // MARK: The trip, kept

    func testATripSurvivesBeingStored() {
        let trip = Navigasi.Trip(goalID: UUID(),
                                 toll: Navigasi.Toll(categoryRaw: TxCategory.shopping.rawValue, cut: 550_000,
                                                     average: 1_800_000),
                                 startedAt: day(2026, 10, 26), acceptedCycle: "2026-10-25")
        XCTAssertEqual(Navigasi.Trip.decode(trip.encoded), trip)
        XCTAssertNil(Navigasi.Trip.decode(Data()))
        XCTAssertNil(Navigasi.Trip.decode(Data("nonsense".utf8)))
    }

    // MARK: DiPo on Home

    /// DiPo mentions the trip only when there is something to do: the
    /// set-aside in the first days of a cycle, and off route.
    func testDiPoSpeaksOnlyWhenThereIsATurn() {
        let goal = SavingsGoal(name: "Trip to Mecca", emoji: "✈️", targetAmount: 150_000_000,
                               savedAmount: 26_300_000, monthlyContribution: 3_000_000)
        context.insert(goal)
        let october = payCycle(from: day(2026, 10, 25))
        let trip = Navigasi.Trip(goalID: goal.id, toll: nil, startedAt: day(2026, 10, 1), acceptedCycle: nil)
        LanguageManager.shared.withLanguage(.indonesian) {
            let due = Navigasi.Status(trip: trip, cycle: october, setAside: 0, leg: .setAside(3_000_000),
                                      arrival: day(2030, 12, 25))
            let soon = Navigasi.nudge(due, goal: goal, now: day(2026, 10, 26), calendar: cal)
            XCTAssertEqual(soon?.title, "Sisihkan Rp 3.000.000 ke ✈️ Trip to Mecca")
            XCTAssertEqual(soon?.worry, false)
            XCTAssertNil(Navigasi.nudge(due, goal: goal, now: day(2026, 11, 2), calendar: cal),
                         "a week in, a set-aside still to make is not news on Home")

            let behind = Navigasi.Status(trip: trip, cycle: october, setAside: 500_000,
                                         leg: .behind(short: 2_500_000, arrival: day(2031, 1, 25)),
                                         arrival: day(2030, 12, 25))
            let off = Navigasi.nudge(behind, goal: goal, now: day(2026, 11, 2), calendar: cal)
            XCTAssertEqual(off?.title, "Keluar jalur: kurang Rp 2.500.000")
            XCTAssertEqual(off?.worry, true)
            XCTAssertTrue(off?.detail.contains("✈️ Trip to Mecca") ?? false)

            let done = Navigasi.Status(trip: trip, cycle: october, setAside: 3_000_000, leg: .done,
                                       arrival: day(2030, 12, 25))
            XCTAssertNil(Navigasi.nudge(done, goal: goal, now: day(2026, 10, 26), calendar: cal))
        }
    }

    func testTheNudgeHasAPlainIconAndOpensTheTrip() {
        let navi = DiPoNudge.Navi(id: "navi", title: "t", detail: "d", worry: false)
        let all = DiPoNudge.all(unread: 0, bill: nil, daysToPayday: nil, payDate: nil, navigation: navi)
        XCTAssertEqual(all.map(\.action), [.navigation])
        XCTAssertEqual(all.first?.rowTitle, "t")
    }

    // MARK: Words

    func testEveryWordInBothLanguages() {
        let keys = ["navi.title", "navi.addons", "navi.addon_sub", "navi.addon_note", "navi.status_pick",
                    "navi.status_on", "navi.status_behind", "navi.go_here", "navi.go_here_sub", "navi.where_to",
                    "navi.where_to_sub", "navi.no_goals", "navi.make_goal", "navi.of_target", "navi.choose_route",
                    "navi.route.plan", "navi.route.on_time", "navi.route.suggested", "navi.route.custom",
                    "navi.fastest", "navi.per_month", "navi.toll_note", "navi.replaces", "navi.custom_label",
                    "navi.start", "navi.here", "navi.set_aside", "navi.set_aside_payday", "navi.set_aside_month",
                    "navi.set_aside_now", "navi.in_days", "navi.tomorrow", "navi.next_payday", "navi.next_month",
                    "navi.bill_before", "navi.bill_then", "navi.off_route", "navi.off_route_sub", "navi.without",
                    "navi.which_way", "navi.back_on", "navi.new_route", "navi.new_route_taken", "navi.arrive",
                    "navi.to_go", "navi.end", "navi.end_title", "navi.end_msg", "navi.change_route",
                    "navi.arrived", "navi.arrived_sub", "navi.finish", "navi.toll_payday", "navi.toll_month",
                    "navi.toll_of", "navi.listen", "navi.dur_ym", "navi.dur_y", "navi.dur_m", "navi.dur_now",
                    "navi.nudge_set_aside", "navi.nudge_keep", "navi.nudge_behind", "navi.nudge_without",
                    "navi.sfx", "navi.link"]
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in keys { XCTAssertNotEqual(loc(key), key, "\(key) in \(language)") }
                let note = String(format: loc("navi.toll_note"), "Belanja", "Rp 1.800.000", "Rp 550.000", "1 thn")
                XCTAssertTrue(note.contains("Rp 1.800.000") && note.contains("Rp 550.000") && note.contains("1 thn"), note)
            }
        }
    }
}
