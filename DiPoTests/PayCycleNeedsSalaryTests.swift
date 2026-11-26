import XCTest
@testable import DiPo

/// A period counted from payday needs a payday. Without a salary schedule,
/// "Pay cycle" would only repeat "This month" under a payday's name, so it
/// isn't offered, and a pay cycle chosen before the schedule was removed or
/// paused moves to this month instead of staying selected with no chip.
@MainActor
final class PayCycleNeedsSalaryTests: XCTestCase {

    func testOfferedOnlyWithASalarySchedule() {
        XCTAssertFalse(StatPeriod.offered(payDay: nil).contains(.payCycle))
        XCTAssertTrue(StatPeriod.offered(payDay: 25).contains(.payCycle))
        XCTAssertEqual(StatPeriod.offered(payDay: nil).count, StatPeriod.allCases.count - 1)
    }

    func testAChosenPayCycleFallsBackWithoutOne() {
        XCTAssertEqual(StatPeriod.payCycle.kept(payDay: nil), .thisMonth)
        XCTAssertEqual(StatPeriod.payCycle.kept(payDay: 25), .payCycle)
        for other in StatPeriod.allCases where other != .payCycle {
            XCTAssertEqual(other.kept(payDay: nil), other)
        }
    }

    /// Statistics offers its chips from the same rule, and moves off a pay
    /// cycle on appearing and when the schedule goes.
    func testStatisticsFollowsTheRule() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let figures = try String(contentsOf: root.appendingPathComponent("DiPo/StatisticsView+Figures.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(figures.contains("StatPeriod.offered(payDay: payCycleDay)"))
        let view = try String(contentsOf: root.appendingPathComponent("StatisticsView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains(".onChange(of: payCycleDay)"))
        XCTAssertTrue(view.contains("selectedPeriod = selectedPeriod.kept(payDay: payCycleDay)"))
    }

    /// "Done on purpose" says "this period", which is the pay period with a
    /// salary schedule and the month without one; never "pay period" alone.
    func testTheIntentSheetDoesNotPromiseAPayPeriod() {
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertFalse(loc("intent.apply_cycle").lowercased().contains("pay"))
            XCTAssertFalse(loc("intent.active_cycle").lowercased().contains("pay"))
        }
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertFalse(loc("intent.apply_cycle").lowercased().contains("gaji"))
            XCTAssertFalse(loc("intent.active_cycle").lowercased().contains("gaji"))
        }
    }
}
