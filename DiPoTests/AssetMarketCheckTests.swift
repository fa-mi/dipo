import XCTest
import SwiftData
@testable import DiPo

/// Asset values: shown rounded, checked against real listings with one tap,
/// and a reminder from DiPo when a value has gone unchecked too long.
@MainActor
final class AssetMarketCheckTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    private let day: TimeInterval = 86_400
    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func asset(_ kind: AssetKind, _ name: String, _ price: Double, bought: Date,
                       added: Date? = nil) -> PhysicalAsset {
        let a = PhysicalAsset(kind: kind, name: name, currency: "IDR", purchasePrice: price, purchaseDate: bought)
        a.createdAt = added ?? bought
        container.mainContext.insert(a)
        return a
    }

    // MARK: Rounding

    func testEstimatesRoundTheWayPricesAreQuoted() {
        XCTAssertEqual(AssetValuation.rounded(103_962_044), 104_000_000)
        XCTAssertEqual(AssetValuation.rounded(119_556_350), 119_500_000)
        XCTAssertEqual(AssetValuation.rounded(19_521_151), 19_500_000)
        XCTAssertEqual(AssetValuation.rounded(12_151_660), 12_150_000)
        XCTAssertEqual(AssetValuation.rounded(2_351_234), 2_350_000)
        // Scales with the value, so a dollar price keeps its meaning.
        XCTAssertEqual(AssetValuation.rounded(1_234.56), 1_235)
        XCTAssertEqual(AssetValuation.rounded(0), 0)
    }

    /// What the user typed shows as typed, until the curve moves it half a step.
    func testATypedValueShowsAsTyped() {
        XCTAssertEqual(AssetValuation.rounded(105_540_000, keeping: 105_550_000), 105_550_000)
        XCTAssertEqual(AssetValuation.rounded(105_000_000, keeping: 105_550_000), 105_000_000)

        let bike = asset(.motorcycle, "Vario", 25_000_000, bought: date(2023, 6, 1))
        bike.manualValue = 19_850_000
        bike.manualValueDate = date(2026, 10, 1)
        XCTAssertEqual(bike.value(at: date(2026, 10, 2)), 19_850_000)
    }

    /// The Brio from the screenshot: Rp 103.962.044 in the sheet and
    /// Rp 103.962.049 in the list. Now one figure, wherever it is read.
    func testTheSameAssetReadsTheSameEverywhere() throws {
        let brio = asset(.car, "Honda Brio RS", 175_000_000, bought: date(2017, 1, 5))
        let now = date(2026, 10, 15)
        let range = try XCTUnwrap(brio.marketRange(at: now))
        XCTAssertEqual(range.lowerBound, 104_000_000)
        XCTAssertEqual(range.upperBound, 119_500_000)
        XCTAssertEqual(brio.value(at: now), range.lowerBound)
        XCTAssertEqual(brio.value(at: now.addingTimeInterval(5)), brio.value(at: now), "a moment later, the same")
        // The summary adds up what the rows show.
        let vario = asset(.motorcycle, "Vario 125", 25_000_000, bought: date(2023, 6, 1))
        let s = AssetSummary.of([brio, vario], currency: "IDR", now: now)
        XCTAssertEqual(s.totalValue, brio.value(at: now) + vario.value(at: now))
    }

    // MARK: The link

    func testTheSearchNamesTheYearForAVehicle() {
        let bought = date(2017, 1, 5)
        XCTAssertEqual(AssetMarketCheck.query(name: " Honda Brio RS ", kind: .car, purchaseDate: bought, cal: cal),
                       "Honda Brio RS 2017")
        XCTAssertEqual(AssetMarketCheck.query(name: "Brio RS 2016", kind: .car, purchaseDate: bought, cal: cal),
                       "Brio RS 2016", "the name's own year wins")
        XCTAssertEqual(AssetMarketCheck.query(name: "Macbook Pro M3", kind: .electronics, purchaseDate: bought, cal: cal),
                       "Macbook Pro M3")
        XCTAssertEqual(AssetMarketCheck.query(name: "   ", kind: .car, purchaseDate: bought, cal: cal), "")
    }

    /// Bought second-hand, the purchase year isn't the vehicle's year, and a
    /// wrong year finds the wrong cars: the search uses the name alone.
    func testAUsedVehicleIsSearchedByTheYearInItsName() throws {
        let bought = date(2020, 3, 1)
        XCTAssertEqual(AssetMarketCheck.query(name: "Honda Brio RS", kind: .car, purchaseDate: bought,
                                              boughtUsed: true, cal: cal), "Honda Brio RS")
        XCTAssertEqual(AssetMarketCheck.query(name: "Honda Brio RS 2015", kind: .car, purchaseDate: bought,
                                              boughtUsed: true, cal: cal), "Honda Brio RS 2015")
        let link = try XCTUnwrap(AssetMarketCheck.link(name: "Brio RS 2015", kind: .car, purchaseDate: bought,
                                                        boughtUsed: true, currency: "IDR", cal: cal))
        XCTAssertEqual(link.url.absoluteString, "https://www.olx.co.id/mobil-bekas_c198/q-brio-rs-2015")
        XCTAssertTrue(AssetMarketCheck.nameHasYear("Brio RS 2015"))
        XCTAssertFalse(AssetMarketCheck.nameHasYear("Brio RS"))
        XCTAssertFalse(AssetMarketCheck.nameHasYear("iPhone 13 128GB"))
    }

    func testVehiclesInRupiahGoToOLXsUsedCategories() throws {
        let car = try XCTUnwrap(AssetMarketCheck.link(name: "Honda Brio RS", kind: .car,
                                                       purchaseDate: date(2017, 1, 5), currency: "IDR", cal: cal))
        XCTAssertEqual(car.site, .olx)
        XCTAssertEqual(car.url.absoluteString, "https://www.olx.co.id/mobil-bekas_c198/q-honda-brio-rs-2017")
        let bike = try XCTUnwrap(AssetMarketCheck.link(name: "Vario 125", kind: .motorcycle,
                                                        purchaseDate: date(2023, 6, 1), currency: "IDR", cal: cal))
        XCTAssertEqual(bike.url.absoluteString, "https://www.olx.co.id/motor-bekas_c200/q-vario-125-2023")
    }

    func testEverythingElseIsAWebSearch() throws {
        let (macLink, houseLink) = LanguageManager.shared.withLanguage(.indonesian) {
            (AssetMarketCheck.link(name: "Macbook Pro M3", kind: .electronics,
                                   purchaseDate: date(2024, 2, 1), currency: "IDR", cal: cal),
             AssetMarketCheck.link(name: "Rumah Bogor", kind: .house,
                                   purchaseDate: date(2020, 1, 1), currency: "IDR", cal: cal))
        }
        let mac = try XCTUnwrap(macLink)
        XCTAssertEqual(mac.site, .web)
        XCTAssertEqual(mac.url.absoluteString, "https://www.google.com/search?q=Macbook%20Pro%20M3%20harga%20bekas")
        XCTAssertTrue(try XCTUnwrap(houseLink).url.absoluteString.hasSuffix("harga%20pasaran"))
        // Another currency is another country's market: not OLX Indonesia.
        let usd = try XCTUnwrap(AssetMarketCheck.link(name: "Civic", kind: .car, purchaseDate: date(2020, 1, 1),
                                                       currency: "USD", cal: cal))
        XCTAssertEqual(usd.site, .web)
        XCTAssertNil(AssetMarketCheck.link(name: "", kind: .car, purchaseDate: .now, currency: "IDR"))
    }

    /// The name is the user's to write. Whatever is in it stays a search
    /// term: it cannot reach another site, path or parameter.
    func testANameCannotBendTheURL() throws {
        XCTAssertEqual(AssetMarketCheck.olxSlug("  Vario 125 (2023)!! "), "vario-125-2023")
        XCTAssertEqual(AssetMarketCheck.olxSlug("a/../b?x=1#y&z%2F"), "a-b-x-1-y-z-2f")
        XCTAssertEqual(AssetMarketCheck.olxSlug("車"), "")

        let olx = try XCTUnwrap(AssetMarketCheck.link(name: "Brio/../../evil?x=1#frag", kind: .car,
                                                       purchaseDate: date(2017, 1, 5), currency: "IDR", cal: cal))
        XCTAssertEqual(olx.url.host, "www.olx.co.id")
        XCTAssertEqual(olx.url.path, "/mobil-bekas_c198/q-brio-evil-x-1-frag-2017")
        XCTAssertNil(olx.url.query)
        XCTAssertNil(olx.url.fragment)

        let web = try XCTUnwrap(AssetMarketCheck.link(name: "TV & soundbar + #1", kind: .electronics,
                                                       purchaseDate: .now, currency: "IDR"))
        XCTAssertEqual(web.url.host, "www.google.com")
        XCTAssertNil(web.url.fragment)
        let items = URLComponents(url: web.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["q"], "one parameter, whatever the name holds")
        XCTAssertTrue(items.first?.value?.hasPrefix("TV & soundbar + #1 ") ?? false)

        // No Latin letters or digits: nothing for OLX's path, so the web.
        let other = try XCTUnwrap(AssetMarketCheck.link(name: "車", kind: .car, purchaseDate: .now, currency: "IDR"))
        XCTAssertEqual(other.site, .web)
    }

    // MARK: When to look again

    func testAValueIsDueAfterHalfAYearOrAYear() {
        let checked = date(2026, 1, 1)
        XCTAssertFalse(AssetMarketCheck.isDue(kind: .motorcycle, lastChecked: checked, now: checked + 181 * day))
        XCTAssertTrue(AssetMarketCheck.isDue(kind: .motorcycle, lastChecked: checked, now: checked + 182 * day))
        XCTAssertTrue(AssetMarketCheck.isDue(kind: .electronics, lastChecked: checked, now: checked + 200 * day))
        // House, land and the rest move slowly: once a year.
        XCTAssertFalse(AssetMarketCheck.isDue(kind: .house, lastChecked: checked, now: checked + 364 * day))
        XCTAssertTrue(AssetMarketCheck.isDue(kind: .land, lastChecked: checked, now: checked + 365 * day))
    }

    /// The clock starts when the asset is added (the user saw DiPo's estimate
    /// then), and again whenever they enter a value.
    func testTheClockRunsFromTheLastLook() {
        let added = date(2026, 9, 1)
        let brio = asset(.car, "Brio", 175_000_000, bought: date(2017, 1, 5), added: added)
        XCTAssertEqual(brio.lastMarketCheck, added, "bought in 2017, but added just now: not due yet")
        XCTAssertFalse(brio.isMarketCheckDue(now: date(2026, 10, 15)))
        XCTAssertTrue(brio.isMarketCheckDue(now: date(2027, 3, 3)))

        brio.manualValue = 101_000_000
        brio.manualValueDate = date(2027, 3, 1)
        XCTAssertEqual(brio.lastMarketCheck, date(2027, 3, 1))
        XCTAssertFalse(brio.isMarketCheckDue(now: date(2027, 3, 3)))
    }

    func testDueAssetsAreNamedOldestLookFirst() {
        let now = date(2027, 6, 1)
        _ = asset(.motorcycle, "Vario", 25_000_000, bought: date(2023, 6, 1), added: date(2026, 11, 1))
        _ = asset(.car, "Brio", 175_000_000, bought: date(2017, 1, 5), added: date(2026, 9, 1))
        _ = asset(.electronics, "Macbook", 30_000_000, bought: date(2025, 1, 1), added: date(2027, 5, 1))
        let all = (try? container.mainContext.fetch(FetchDescriptor<PhysicalAsset>())) ?? []
        XCTAssertEqual(AssetMarketCheck.due(all, now: now), ["Brio", "Vario"])
    }

    func testSeenOnceDiPoLeavesItForAMonth() {
        let now = date(2027, 6, 1)
        let until = AssetMarketCheck.snoozed(from: now)
        XCTAssertTrue(AssetMarketCheck.isSnoozed(until: until, now: now + 29 * day))
        XCTAssertFalse(AssetMarketCheck.isSnoozed(until: until, now: now + 30 * day))
        XCTAssertFalse(AssetMarketCheck.isSnoozed(until: 0, now: now), "never seen")
    }

    // MARK: DiPo

    func testDiPoNamesTheAssetAfterMoneyAndDates() {
        LanguageManager.shared.withLanguage(.indonesian) {
            let one = DiPoNudge.all(unread: 0, bill: nil, daysToPayday: 2, payDate: .now,
                                    assetCheck: ["Honda Brio RS"], questWaiting: true)
            XCTAssertEqual(one.map(\.action), [.salary, .assetCheck, .quest])
            XCTAssertEqual(one[1].rowTitle, "Cek lagi harga Honda Brio RS")
            XCTAssertEqual(one[1].rowDetail, loc("dipo.asset_check_detail"))
            let two = DiPoNudge.all(unread: 0, bill: nil, daysToPayday: nil, payDate: nil,
                                    assetCheck: ["Brio", "Vario"])
            XCTAssertEqual(two.first?.rowTitle, "Cek lagi harga 2 aset")
        }
        XCTAssertTrue(DiPoNudge.all(unread: 0, bill: nil, daysToPayday: nil, payDate: nil, assetCheck: []).isEmpty)
    }

    func testStringsInBothLanguages() {
        let keys = ["asset.market.olx", "asset.market.web", "asset.market.sub", "asset.market.due",
                    "asset.market.yours", "asset.market.search_used", "asset.market.search_price",
                    "asset.check_due", "dipo.sfx.asset_check", "dipo.asset_check_one", "dipo.asset_check_many",
                    "dipo.asset_check_body", "dipo.asset_check_detail", "dipo.link.assets"]
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                for k in keys { XCTAssertNotEqual(loc(k), k, "\(k) in \(lang)") }
            }
        }
    }
}
