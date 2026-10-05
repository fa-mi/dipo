import XCTest
import SwiftData
import UIKit
@testable import DiPo

/// Physical assets: their estimated value, the wear advice, and the yearly
/// tax reminders.
@MainActor
final class PhysicalAssetTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    private let year = 365.25 * 86_400
    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    /// Inserted, as the app's own assets always are.
    private func asset(_ kind: AssetKind, _ name: String, _ price: Double, bought: Date,
                       tax: Date? = nil) -> PhysicalAsset {
        let a = PhysicalAsset(kind: kind, name: name, currency: "IDR", purchasePrice: price,
                              purchaseDate: bought, taxDueDate: tax)
        container.mainContext.insert(a)
        return a
    }

    /// 10% in the first year, spread across it, then 6% a year.
    func testAMotorbikeDropsMostInItsFirstYearThenSlowly() {
        let bought = date(2023, 1, 1)
        let k = AssetKind.motorcycle
        let i = AssetValuation.Input(purchasePrice: 18_000_000, purchaseDate: bought,
                                     annualRate: k.defaultAnnualRate, firstYearDrop: k.firstYearDrop)
        XCTAssertEqual(AssetValuation.value(i, at: bought), 18_000_000, accuracy: 1)
        XCTAssertEqual(AssetValuation.value(i, at: bought.addingTimeInterval(0.5 * year)),
                       18_000_000 * 0.95, accuracy: 1)
        XCTAssertEqual(AssetValuation.value(i, at: bought.addingTimeInterval(2 * year)),
                       18_000_000 * 0.90 * 0.94, accuracy: 1)
        // Never worth nothing on paper.
        XCTAssertEqual(AssetValuation.value(i, at: bought.addingTimeInterval(80 * year)),
                       1_800_000, accuracy: 1)
    }

    /// Fitted to OLX listings (October 2026): a 2017 Brio at Rp 107–125 jt and
    /// a 2023 Vario 125 at Rp 20,4–21,8 jt. The estimate sits at or just under
    /// the cheapest listing, and the range reaches into them.
    func testEstimatesLandOnTheLowEndOfRealListings() throws {
        let now = date(2026, 10, 5)
        let brio = asset(.car, "Brio", 175_000_000, bought: date(2017, 6, 1))
        let vario = asset(.motorcycle, "Vario", 25_000_000, bought: date(2023, 6, 1))
        let brioRange = try XCTUnwrap(brio.marketRange(at: now))
        let varioRange = try XCTUnwrap(vario.marketRange(at: now))
        XCTAssertEqual(brioRange.lowerBound, 106_000_000, accuracy: 2_000_000)
        XCTAssertGreaterThan(brioRange.upperBound, 107_000_000)
        XCTAssertEqual(varioRange.lowerBound, 19_500_000, accuracy: 500_000)
        XCTAssertGreaterThan(varioRange.upperBound, 20_400_000)
        // Nothing sold second-hand, no range.
        XCTAssertNil(asset(.land, "Sawah", 100_000_000, bought: date(2020, 1, 1)).marketRange(at: now))
    }

    /// Nothing lets a user set the rate, so a stored one is only ever an older
    /// default: the estimate always follows the current curve.
    func testAStoredRateFollowsTheCurrentCurve() {
        let bike = asset(.motorcycle, "Beat", 18_000_000, bought: date(2024, 1, 1))
        for old in [-12.0, -5.0] {
            bike.annualRate = old
            XCTAssertEqual(bike.effectiveRate, AssetKind.motorcycle.defaultAnnualRate)
        }
    }

    /// Each curve, as a share of the price new, sits inside (or just under)
    /// the second-hand bands reported in 2025–26 — never above them.
    func testCurvesSitOnTheLowSideOfReportedMarketBands() {
        func share(_ k: AssetKind, years: Double) -> Double {
            let start = date(2020, 1, 1)
            let i = AssetValuation.Input(purchasePrice: 100, purchaseDate: start, annualRate: k.defaultAnnualRate,
                                         firstYearDrop: k.firstYearDrop)
            return AssetValuation.value(i, at: start.addingTimeInterval(years * year)) / 100
        }
        // (kind, years, band low, band high) — BeAT, Avanza/Brio, iPhone 13.
        let bands: [(AssetKind, Double, Double, Double)] = [
            (.motorcycle, 1, 0.86, 0.92), (.motorcycle, 3, 0.74, 0.80), (.motorcycle, 5, 0.66, 0.71),
            (.car, 3, 0.73, 0.84), (.car, 5, 0.72, 0.87), (.car, 7, 0.57, 0.70), (.car, 9.3, 0.58, 0.71),
            (.electronics, 4, 0.42, 0.54),
        ]
        for (kind, years, low, high) in bands {
            let v = share(kind, years: years)
            XCTAssertLessThanOrEqual(v, high, "\(kind) at \(years) yrs: \(v)")
            XCTAssertGreaterThanOrEqual(v, low - 0.05, "\(kind) at \(years) yrs: \(v)")
        }
    }

    func testLandGainsAndAUserValueBecomesTheNewStart() {
        let bought = date(2020, 6, 1)
        var i = AssetValuation.Input(purchasePrice: 100_000_000, purchaseDate: bought,
                                     annualRate: AssetKind.land.defaultAnnualRate)
        XCTAssertEqual(AssetValuation.value(i, at: bought.addingTimeInterval(year)), 103_000_000, accuracy: 1)
        let set = bought.addingTimeInterval(3 * year)
        i.manualValue = 150_000_000
        i.manualValueDate = set
        XCTAssertEqual(AssetValuation.value(i, at: set), 150_000_000, accuracy: 1)
        XCTAssertEqual(AssetValuation.value(i, at: set.addingTimeInterval(year)), 154_500_000, accuracy: 1)
    }

    func testWearCountsOnlyThingsThatGetReplaced() {
        let now = Date()
        let bike = asset(.motorcycle, "Beat", 18_000_000, bought: now)
        let house = asset(.house, "Rumah", 300_000_000, bought: now)
        let s = AssetSummary.of([bike, house], currency: "IDR", now: now)
        XCTAssertEqual(s.totalValue, 318_000_000, accuracy: 1)
        XCTAssertEqual(s.marketHigh, 18_000_000 * 1.15 + 300_000_000, accuracy: 1)
        XCTAssertEqual(s.monthlyWear, 18_000_000 * 0.10 / 12, accuracy: 1)   // first year: Rp 150rb
        XCTAssertEqual(s.wearingNames, ["Beat"])
        XCTAssertEqual(AssetAdvice.roundedMonthly(s.monthlyWear), 150_000)
    }

    func testSetAsideRoundsToSomethingMemorable() {
        XCTAssertEqual(AssetAdvice.roundedMonthly(43_000), 40_000)
        XCTAssertEqual(AssetAdvice.roundedMonthly(3_000), 10_000)
        XCTAssertEqual(AssetAdvice.roundedMonthly(1_260_000), 1_300_000)
        XCTAssertEqual(AssetAdvice.roundedMonthly(0), 0)
    }

    func testTaxComesRoundEveryYear() {
        let due = date(2024, 3, 15)
        XCTAssertEqual(cal.dateComponents([.year, .month, .day],
                                          from: AssetTaxReminders.nextOccurrence(of: due, onOrAfter: date(2026, 2, 1), cal: cal)),
                       DateComponents(year: 2026, month: 3, day: 15))
        XCTAssertEqual(cal.dateComponents([.year, .month, .day],
                                          from: AssetTaxReminders.nextOccurrence(of: due, onOrAfter: date(2026, 4, 1), cal: cal)),
                       DateComponents(year: 2027, month: 3, day: 15))
        // 29 February lands on the 28th in a common year.
        XCTAssertEqual(cal.dateComponents([.year, .month, .day],
                                          from: AssetTaxReminders.nextOccurrence(of: date(2024, 2, 29), onOrAfter: date(2026, 1, 1), cal: cal)),
                       DateComponents(year: 2026, month: 2, day: 28))
    }

    func testRemindersOnlyForAssetsWithATaxDate() {
        let bike = asset(.motorcycle, "Beat", 18_000_000, bought: date(2023, 1, 1), tax: date(2023, 9, 20))
        let phone = asset(.electronics, "HP", 3_000_000, bought: date(2025, 1, 1), tax: date(2025, 9, 20))
        let plan = AssetTaxReminders.plan(assets: [bike, phone], now: date(2026, 9, 1), cal: cal)
        XCTAssertEqual(plan.map(\.id), ["7d", "due"].map { "assettax_\(bike.id.uuidString)_\($0)" })
        XCTAssertEqual(plan.map { [$0.fire.month!, $0.fire.day!] }, [[9, 13], [9, 20]])
        XCTAssertTrue(plan.allSatisfy { $0.body.contains("Beat") })
    }

    func testStringsInBothLanguages() {
        for k in AssetKind.allCases { XCTAssertFalse(k.displayName.hasPrefix("asset."), "\(k)") }
        for key in ["premium.feature.assets", "premium.feature.assets_desc", "asset.replace_body",
                    "asset.networth_line", "notif.asset_tax_week_body", "reco.item.replace_title",
                    "asset.status.summary_one"] {
            XCTAssertNotEqual(loc(key), key, key)
        }
    }

    /// A misspelt or too-new SF Symbol draws nothing at all, silently.
    func testEveryKindIconIsARealSymbol() {
        for kind in AssetKind.allCases {
            XCTAssertNotNil(UIImage(systemName: kind.icon), "\(kind): \(kind.icon)")
        }
    }
}
