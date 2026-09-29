import XCTest
import SwiftData
@testable import DiPo

/// The pushes DiPo schedules ahead of a debt's due date: in the app's
/// language, on the right day, and only for money still owed.
@MainActor
final class DebtNotificationTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 7) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func ymd(_ d: Date) -> [Int] {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return [c.year!, c.month!, c.day!]
    }

    func testDueDayPastMonthEndLandsOnTheLastDay() {
        // Used to spill over: day 31 "in February" was 3 March.
        XCTAssertEqual(ymd(DebtNotificationScheduler.nextDueDate(day: 31, onOrAfter: date(2026, 2, 10), cal: cal)),
                       [2026, 2, 28])
        XCTAssertEqual(ymd(DebtNotificationScheduler.nextDueDate(day: 31, onOrAfter: date(2026, 4, 1), cal: cal)),
                       [2026, 4, 30])
    }

    func testTodayCountsAndAPassedDayMovesToNextMonth() {
        XCTAssertEqual(ymd(DebtNotificationScheduler.nextDueDate(day: 15, onOrAfter: date(2026, 9, 15, 20), cal: cal)),
                       [2026, 9, 15])
        XCTAssertEqual(ymd(DebtNotificationScheduler.nextDueDate(day: 5, onOrAfter: date(2026, 9, 29), cal: cal)),
                       [2026, 10, 5])
        XCTAssertEqual(ymd(DebtNotificationScheduler.nextDueDate(day: 30, onOrAfter: date(2026, 1, 31), cal: cal)),
                       [2026, 2, 28])
    }

    func testPlansThreeTranslatedPushesOnlyForDebtStillOwed() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        let container = try ModelContainer(for: schema,
                                           configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let owed = DebtRecord(name: "KUR", totalAmount: 10_000_000, currentBalance: 6_000_000,
                              minimumPayment: 500_000, annualInterestRate: 6, dueDayOfMonth: 10, currency: "IDR")
        let paid = DebtRecord(name: "Paylater", totalAmount: 1_000_000, currentBalance: 0,
                              minimumPayment: 100_000, annualInterestRate: 0, dueDayOfMonth: 10, currency: "IDR")
        let closed = DebtRecord(name: "Arisan", totalAmount: 1_000_000, currentBalance: 500_000,
                                minimumPayment: 100_000, annualInterestRate: 0, dueDayOfMonth: 10, currency: "IDR")
        closed.manuallyClosed = true
        [owed, paid, closed].forEach(context.insert)

        let plan = DebtNotificationScheduler.plan(debts: [owed, paid, closed], now: date(2026, 9, 1), cal: cal)
        XCTAssertEqual(plan.map(\.id), ["3d", "1d", "due"].map { "debt_\(owed.id.uuidString)_\($0)" })
        XCTAssertEqual(plan.map { [$0.fire.month!, $0.fire.day!] }, [[9, 7], [9, 9], [9, 10]])
        XCTAssertEqual(plan[1].title, loc("notif.debt_due_tomorrow_title"))
        XCTAssertEqual(plan[2].title, loc("notif.debt_due_today_title"))
        XCTAssertTrue(plan.allSatisfy { $0.body.contains("KUR") })

        // Two days before: the 3-day push is already behind us.
        let late = DebtNotificationScheduler.plan(debts: [owed], now: date(2026, 9, 8), cal: cal)
        XCTAssertEqual(late.map(\.id), ["1d", "due"].map { "debt_\(owed.id.uuidString)_\($0)" })
    }
}
