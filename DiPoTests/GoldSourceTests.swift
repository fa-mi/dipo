import XCTest
@testable import DiPo

/// Which gold a holding is, and the buyback price it is valued at.
@MainActor
final class GoldSourceTests: XCTestCase {

    func testSymbolsRoundTrip() {
        let all: [GoldSource] = [.savings, .bar(.antam), .bar(.ubs), .bar(.galeri24), .bar(.lotusarchi),
                                 .jewelry(purity: 70), .jewelry(purity: 99), .manual]
        for source in all {
            XCTAssertEqual(GoldSource(symbol: source.symbol), source, source.symbol)
        }
        // Holdings saved before this follow Pegadaian or are kept by hand.
        XCTAssertEqual(GoldSource(symbol: "pegadaian"), .savings)
        XCTAssertEqual(GoldSource(symbol: ""), .manual)
        XCTAssertEqual(GoldSource(symbol: "Antam "), .bar(.antam))
        // A name typed by hand is never looked up.
        XCTAssertEqual(GoldSource(symbol: "dinar khoirur rooziqiin"), .manual)
        XCTAssertEqual(GoldSource(symbol: "perhiasan-0"), .manual)
    }

    private let pegadaian = PriceService.Quote(price: 2_200_000, prevClose: 2_190_000)

    func testABarUsesItsOwnPriceWhenThereIsOne() {
        let antam = PriceService.Quote(price: 2_233_000, prevClose: 2_236_000)
        let p = GoldPricing.price(for: .bar(.antam), quotes: ["antam": antam, "pegadaian": pegadaian])
        XCTAssertEqual(p, .init(price: 2_233_000, prevClose: 2_236_000, estimated: false))
    }

    func testABarWithoutItsOwnPriceFollowsPegadaianAsAnEstimate() {
        let p = GoldPricing.price(for: .bar(.ubs), quotes: ["pegadaian": pegadaian])
        XCTAssertEqual(p, .init(price: 2_200_000, prevClose: 2_190_000, estimated: true))
        XCTAssertNil(GoldPricing.price(for: .bar(.ubs), quotes: [:]), "nothing back, price stands")
    }

    func testJewelryIsPricedByContentLessTheShopCut() {
        let p = try! XCTUnwrap(GoldPricing.price(for: .jewelry(purity: 70), quotes: ["pegadaian": pegadaian]))
        XCTAssertEqual(p.price, 2_200_000 * 0.70 * 0.85, accuracy: 0.01)   // Rp 1.309.000 per gram
        XCTAssertTrue(p.estimated)
        XCTAssertNil(GoldPricing.price(for: .manual, quotes: ["pegadaian": pegadaian]))
    }

    func testEachSourceAsksForTheFeedsItNeeds() {
        XCTAssertEqual(GoldSource.savings.requestSymbols, ["pegadaian"])
        XCTAssertEqual(GoldSource.bar(.galeri24).requestSymbols, ["galeri24", "pegadaian"])
        XCTAssertEqual(GoldSource.jewelry(purity: 75).requestSymbols, ["pegadaian"])
        XCTAssertEqual(GoldSource.manual.requestSymbols, [])
    }

    /// Antam on the day of the screenshot: bought at Rp 2.580.000, buyback
    /// Rp 2.386.000 — the price has to rise about 8% to break even.
    func testBreakEvenIsTheRiseTheBuybackStillNeeds() {
        XCTAssertEqual(GoldPricing.riseToBreakEven(avgCost: 2_580_000, buyback: 2_386_000),
                       0.0813, accuracy: 0.0001)
        XCTAssertEqual(GoldPricing.riseToBreakEven(avgCost: 2_000_000, buyback: 2_386_000), 0)
    }

    func testChoosingASourceSetsTheFeed() {
        let h = InvestmentHolding(type: .gold, name: "Cincin", currency: "IDR")
        h.setGoldSource(.jewelry(purity: 70))
        XCTAssertEqual(h.symbol, "perhiasan-70")
        XCTAssertTrue(h.isAutoPriced)
        XCTAssertEqual(h.goldSource, .jewelry(purity: 70))
        h.setGoldSource(.manual)
        XCTAssertFalse(h.isAutoPriced)
        XCTAssertFalse(h.followsGoldFeed)
        // Only rupiah gold has a source.
        let usd = InvestmentHolding(type: .gold, name: "XAU", currency: "USD")
        usd.setGoldSource(.bar(.antam))
        XCTAssertEqual(usd.goldSource, .manual)
    }

    func testStringsInBothLanguages() {
        for key in ["gold.src.title", "gold.note.jewelry", "gold.breakeven_behind", "gold.estimate_bar",
                    "invest.gold_feed_on_src", "gold.purity.young"] {
            for lang in LanguageManager.Language.allCases {
                LanguageManager.shared.withLanguage(lang) {
                    XCTAssertNotEqual(loc(key), key, "\(lang) \(key)")
                }
            }
        }
    }
}
