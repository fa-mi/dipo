import XCTest
import SwiftUI
@testable import DiPo

/// Home's "This period" card: the line that took the hourglass's place. Its
/// figures add up to the one printed above it, today's mark sits where the
/// days say, and the line shows only when there is something to measure.
@MainActor
final class HomePeriodLineTests: XCTestCase {

    /// Rp 10 jt in, Rp 5.070.000 on living and Rp 3.030.000 to the cards:
    /// 81% used, 51 of it on living and 30 to debts.
    func testTheFiguresOfAPeriod() throws {
        let p = try XCTUnwrap(MonthFlowCard.percents(income: 10_000_000, expense: 8_100_000,
                                                     putAway: 3_030_000, extra: 0))
        XCTAssertEqual(p.used, 81)
        XCTAssertEqual(p.living, 51)
        XCTAssertEqual(p.putAway, 30)
    }

    /// Rounded apart, 50.5% and 30.5% would print 51 + 31 under an 81. The
    /// parts are cut from the rounded whole, so they always add up.
    func testThePartsAlwaysAddUpToTheWhole() throws {
        for living in stride(from: 0.0, through: 1_200.0, by: 7.3) {
            for put in stride(from: 0.0, through: 600.0, by: 11.9) {
                let p = try XCTUnwrap(MonthFlowCard.percents(income: 1_000, expense: living + put,
                                                             putAway: put, extra: 0))
                XCTAssertEqual(p.living + p.putAway, p.used, "living \(living), put away \(put)")
                XCTAssertGreaterThanOrEqual(p.putAway, 0)
            }
        }
        let edge = try XCTUnwrap(MonthFlowCard.percents(income: 1_000, expense: 810, putAway: 305, extra: 0))
        XCTAssertEqual(edge.used, 81)
        XCTAssertEqual(edge.living + edge.putAway, 81)
    }

    /// Money added to the period counts as the period's money; no income at
    /// all leaves nothing to measure, and the card shows its plain hairline.
    func testWhatTheLineMeasuresAgainst() throws {
        let added = try XCTUnwrap(MonthFlowCard.percents(income: 1_000_000, expense: 1_000_000,
                                                         putAway: 0, extra: 1_000_000))
        XCTAssertEqual(added.used, 50)
        XCTAssertNil(MonthFlowCard.percents(income: 0, expense: 250_000, putAway: 0, extra: 0))
        let over = try XCTUnwrap(MonthFlowCard.percents(income: 5_000_000, expense: 7_000_000,
                                                        putAway: 0, extra: 0))
        XCTAssertEqual(over.used, 140)
        XCTAssertEqual(over.living, 140)
        XCTAssertEqual(over.putAway, 0)
    }

    func testTodaysMark() {
        XCTAssertEqual(MonthFlowCard.todayMark(day: 22, of: 33), 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(MonthFlowCard.todayMark(day: 1, of: 31), 1.0 / 31.0, accuracy: 0.0001)
        XCTAssertEqual(MonthFlowCard.todayMark(day: 33, of: 33), 1)
        XCTAssertEqual(MonthFlowCard.todayMark(day: 40, of: 30), 1)
        XCTAssertEqual(MonthFlowCard.todayMark(day: 3, of: 0), 0)
    }

    /// The line and its key take room only when they are shown: with the
    /// balance hidden, or no income yet, the card keeps its one hairline.
    func testTheLineShowsOnlyWithSomethingToMeasure() throws {
        func height(_ card: MonthFlowCard) throws -> Int {
            let renderer = ImageRenderer(content: card.frame(width: 358))
            renderer.scale = 1
            return try XCTUnwrap(renderer.cgImage).height
        }
        func card(income: Double, hidden: Bool, day: (day: Int, of: Int)?) -> MonthFlowCard {
            MonthFlowCard(income: income, expense: 8_100_000, putAway: 3_030_000, currency: "IDR",
                          periodLabel: "Sejak gajian 23 Okt", cycleDay: day, isHidden: hidden)
        }
        let shown = try height(card(income: 10_000_000, hidden: false, day: (22, 33)))
        let hidden = try height(card(income: 10_000_000, hidden: true, day: (22, 33)))
        let noIncome = try height(card(income: 0, hidden: false, day: (22, 33)))
        XCTAssertGreaterThan(shown, hidden)
        XCTAssertGreaterThan(shown, noIncome)
        // Without a day the line still draws, without its mark.
        XCTAssertGreaterThan(try height(card(income: 10_000_000, hidden: false, day: nil)), hidden)
    }

    func testTheLinesWordsInBothLanguages() {
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(loc("home.used_short"), "Terpakai")
            XCTAssertEqual(loc("home.debts_and_savings"), "Utang & tabungan")
            XCTAssertEqual(loc("home.today_mark"), "Hari ini")
            XCTAssertEqual(String(format: loc("stats.day_of"), 22, 33), "Hari ke-22 dari 33")
        }
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(loc("home.used_short"), "Used")
            XCTAssertEqual(loc("home.debts_and_savings"), "Debts & savings")
            XCTAssertEqual(loc("home.today_mark"), "Today")
            XCTAssertEqual(String(format: loc("stats.day_of"), 22, 33), "Day 22 of 33")
        }
    }
}
