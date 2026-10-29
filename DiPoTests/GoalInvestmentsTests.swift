import XCTest
import SwiftData
@testable import DiPo

/// A savings goal kept in investments counts them at today's price.
///
/// Fahmi's trip to Mecca is saved in BBRI shares at two brokers. The goal said
/// Rp 30.500.000, typed in once, while the shares sat on the Investments
/// screen: the goal never moved with the price, and Home counted the same money
/// twice — once in the goal, once in the portfolio.
@MainActor
final class GoalInvestmentsTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func holding(_ name: String, _ type: InvestmentType = .stock,
                         units: Double, boughtAt: Double, price: Double) -> InvestmentHolding {
        let h = InvestmentHolding(type: type, name: name, symbol: "BBRI", currency: "IDR",
                                  lastPrice: price, prevClose: price)
        context.insert(h)
        let lot = InvestmentLot(kind: .buy, units: units, pricePerUnit: boughtAt)
        context.insert(lot)
        h.lots.append(lot)
        return h
    }

    private func mecca(saved: Double = 0, due: Date? = nil) -> SavingsGoal {
        let g = SavingsGoal(name: "Trip to Mecca", emoji: "✈️", targetAmount: 150_000_000, savedAmount: saved,
                            targetDate: due, monthlyContribution: 1_000_000)
        context.insert(g)
        return g
    }

    /// AJAIB: 10.000 shares bought at 3.900, now 2.628. BRIGHTS: 1.000 at 5.500, now 4.964.
    private func brokers() -> (ajaib: InvestmentHolding, brights: InvestmentHolding) {
        (holding("AJAIB", units: 10_000, boughtAt: 3_900, price: 2_628),
         holding("BRIGHTS", units: 1_000, boughtAt: 5_500, price: 4_964))
    }

    // MARK: Counting them

    func testAGoalKeptInSharesCountsThemAtTodaysPrice() throws {
        let goal = mecca()
        let b = brokers()
        goal.keep(in: [b.ajaib, b.brights])
        try context.save()

        XCTAssertTrue(goal.isInvested)
        XCTAssertEqual(goal.investedValue, 26_280_000 + 4_964_000, accuracy: 0.5)
        XCTAssertEqual(goal.investedCost, 39_000_000 + 5_500_000, accuracy: 0.5)
        XCTAssertEqual(goal.currentValue, 31_244_000, accuracy: 0.5)
        XCTAssertEqual(goal.progress, 31_244_000.0 / 150_000_000, accuracy: 1e-9)
        XCTAssertEqual(goal.remaining, 118_756_000, accuracy: 0.5)
        XCTAssertEqual(goal.monthsToGoal, 119, "from today's value and the monthly plan, no return guessed")
    }

    func testThePriceMovesTheGoal() throws {
        let goal = mecca()
        let b = brokers()
        goal.keep(in: [b.ajaib])
        try context.save()
        let before = goal.progress

        b.ajaib.lastPrice = 3_900
        XCTAssertEqual(goal.currentValue, 39_000_000, accuracy: 0.5)
        XCTAssertGreaterThan(goal.progress, before)
    }

    /// The goal's own cash and its investments add up; net worth takes only
    /// the cash from the goal, because the investments line already has them.
    func testCashAndInvestmentsAddUpButNetWorthCountsThemOnce() throws {
        let goal = mecca(saved: 5_000_000)
        let b = brokers()
        goal.keep(in: [b.ajaib])
        try context.save()

        XCTAssertEqual(goal.currentValue, 5_000_000 + 26_280_000, accuracy: 0.5)
        XCTAssertEqual(goal.netWorthContribution(from: []), 5_000_000, accuracy: 0.5)
    }

    // MARK: One goal per holding

    func testAHoldingIsKeptForOneGoalAtATime() throws {
        let trip = mecca()
        let house = SavingsGoal(name: "Rumah", emoji: "🏠", targetAmount: 300_000_000)
        context.insert(house)
        let b = brokers()
        trip.keep(in: [b.ajaib, b.brights])
        try context.save()

        house.keep(in: [b.ajaib])
        try context.save()

        XCTAssertTrue(b.ajaib.goal === house, "it moves")
        XCTAssertEqual(trip.holdings.map(\.name), ["BRIGHTS"])
        XCTAssertEqual(trip.investedValue, 4_964_000, accuracy: 0.5, "and stops counting for the goal it left")

        trip.keep(in: [])
        try context.save()
        XCTAssertNil(b.brights.goal)
        XCTAssertFalse(trip.isInvested)
    }

    func testDeletingTheGoalLeavesItsInvestments() throws {
        let goal = mecca()
        let b = brokers()
        goal.keep(in: [b.ajaib, b.brights])
        try context.save()

        context.delete(goal)
        try context.save()

        let left = try context.fetch(FetchDescriptor<InvestmentHolding>())
        XCTAssertEqual(left.count, 2)
        XCTAssertTrue(left.allSatisfy { $0.goal == nil })
    }

    func testDeletingAHoldingTakesItOffTheGoal() throws {
        let goal = mecca()
        let b = brokers()
        goal.keep(in: [b.ajaib, b.brights])
        try context.save()

        context.delete(b.ajaib)
        try context.save()

        XCTAssertEqual(goal.holdings.map(\.name), ["BRIGHTS"])
        XCTAssertEqual(goal.currentValue, 4_964_000, accuracy: 0.5)
    }

    // MARK: Prices that can fall back

    /// At the target on today's price is not the goal done: the card says so,
    /// and the goal waits to be marked done.
    func testReachingTheTargetOnTodaysPrice() throws {
        let goal = SavingsGoal(name: "Motor", emoji: "🛵", targetAmount: 25_000_000)
        context.insert(goal)
        let b = brokers()
        goal.keep(in: [b.ajaib])
        try context.save()

        XCTAssertTrue(goal.reachedOnTodaysPrice)
        XCTAssertFalse(goal.isCompleted)

        let gold = holding("Emas", .gold, units: 20, boughtAt: 1_500_000, price: 1_600_000)
        goal.keep(in: [gold])
        try context.save()
        XCTAssertEqual(goal.progress, 1, "gold alone reaches it too")
        XCTAssertFalse(goal.reachedOnTodaysPrice, "but gold isn't counted as a price that swings")
    }

    /// Within two years of its date, the goal says what a 20% fall would take
    /// off. Further out there is time for prices to come back.
    func testAFallIsSpelledOutNearTheDate() throws {
        let now = Date(timeIntervalSince1970: 1_793_232_000)   // 29 Oct 2026
        let soon = Calendar.current.date(byAdding: .month, value: 18, to: now)!
        let goal = mecca(due: soon)
        let b = brokers()
        goal.keep(in: [b.ajaib, b.brights])
        try context.save()

        let note = try XCTUnwrap(goal.fallNote(now: now))
        XCTAssertEqual(note.date, soon)
        XCTAssertEqual(note.loss, 31_244_000 * 0.2, accuracy: 0.5)

        goal.targetDate = Calendar.current.date(byAdding: .month, value: 36, to: now)
        XCTAssertNil(goal.fallNote(now: now), "three years out")

        goal.targetDate = nil
        XCTAssertNil(goal.fallNote(now: now), "no date of its own, and the plan reaches it in ten years")
    }

    // MARK: Backup

    /// A backup carries the goal a holding is kept for; one from before goals
    /// could be kept in investments reads as kept for none.
    func testABackupCarriesTheGoalAHoldingIsKeptFor() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = Data("""
            {"id":"\(UUID().uuidString)","typeRaw":"stock","name":"AJAIB","symbol":"BBRI","currency":"IDR",
             "createdAt":"2026-01-05T05:00:00Z","lastPrice":2628,"prevClose":2600,"manualPrice":false,
             "priceHistory":[],"sortOrder":0,"lots":[]}
            """.utf8)
        XCTAssertNil(try decoder.decode(BackupHolding.self, from: old).goalID)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let goalID = UUID()
        let h = BackupHolding(id: UUID().uuidString, typeRaw: "stock", name: "AJAIB", symbol: "BBRI", currency: "IDR",
                              createdAt: now(), lastPrice: 2_628, prevClose: 2_600, priceUpdatedAt: nil,
                              manualPrice: false, priceHistory: [], sortOrder: 0, lots: [], goalID: goalID)
        XCTAssertEqual(try decoder.decode(BackupHolding.self, from: encoder.encode(h)).goalID, goalID)
    }

    private func now() -> Date { Date(timeIntervalSince1970: 1_793_232_000) }

    // MARK: Words

    func testTheWordsAreInBothLanguages() {
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in ["savings.reached_today_price", "savings.invest_line", "savings.invest_title",
                            "savings.invest_empty", "savings.invest_choose", "savings.invest_change",
                            "savings.invest_worth", "savings.invest_cost", "savings.invest_how",
                            "savings.invest_fall", "savings.invest_pick_title", "savings.invest_pick_sub",
                            "savings.invest_for_other", "savings.invest_cash_title", "savings.invest_cash_msg",
                            "savings.invest_cash_yes", "savings.invest_cash_no", "savings.already_cash_hint",
                            "savings.invest_deposit_hint"] {
                    XCTAssertNotEqual(loc(key), key, "\(key) in \(language)")
                }
                let fall = String(format: loc("savings.invest_fall"), "Apr 2028", "Rp 6.248.800")
                XCTAssertTrue(fall.contains("Apr 2028") && fall.contains("Rp 6.248.800") && fall.contains("20%"), fall)
                let line = String(format: loc("savings.invest_line"), "Rp 31.244.000", "Rp 44.500.000")
                XCTAssertTrue(line.contains("Rp 31.244.000") && line.contains("Rp 44.500.000"), line)
            }
        }
    }
}
