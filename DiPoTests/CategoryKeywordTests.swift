import XCTest
import SwiftData
@testable import DiPo

/// A short keyword is a word, not a run of letters: "Transport" was filed
/// under Health for the "sport" inside it, and "Kado istri" under Bills for
/// Tri, the phone network.
@MainActor
final class CategoryKeywordTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    override func tearDownWithError() throws {
        container = nil
    }

    private func category(_ name: String) -> TxCategory? {
        SmartBudgetManager.suggestCategory(for: name, txType: "Expense")
    }

    private func spent(_ name: String, _ category: TxCategory) -> TxRecord {
        let tx = TxRecord(name: name, date: .now, amount: -25_000, type: "tx.type.purchase", icon: "X",
                          iconBgHex: category.iconBg, category: category, currency: "IDR")
        container.mainContext.insert(tx)
        return tx
    }

    func testTransportIsTransport() {
        XCTAssertEqual(category("Transport"), .transport)
        XCTAssertEqual(category("Transportasi umum"), .transport)
        XCTAssertNil(category("Passport"))
    }

    /// Each of these was read through a short keyword inside one of its
    /// words: tri, kai, tol, incar, oyo, nasi, gas, bus, donat, ebay, bubur,
    /// air, uber, giant, mie.
    func testAShortKeywordInsideAnotherWordIsNoMatch() {
        for name in ["Kado istri", "Beli pakaian", "Beli botol minum", "Skincare", "Servis Toyota",
                     "Hari nasional", "Uang tugas", "Busana muslim", "Donation", "Kebayoran Baru",
                     "Cibubur Junction", "Repair motor", "Gubernur", "Sugianto", "Premier League"] {
            XCTAssertNil(category(name), name)
        }
    }

    func testAShortKeywordStillMatchesAsAWord() {
        XCTAssertEqual(category("Sports Station"), .health, "A plural is the same word.")
        XCTAssertEqual(category("Hotelnya"), .travel, "So is -nya.")
        XCTAssertEqual(category("Tol Cipularang"), .transport)
        XCTAssertEqual(category("E-toll"), .transport)
        XCTAssertEqual(category("Pulsa Tri"), .bills)
        XCTAssertEqual(category("KAI Access"), .transport)
        XCTAssertEqual(category("Nasi goreng"), .food)
        XCTAssertEqual(category("Mie ayam"), .food)
        XCTAssertEqual(category("Tagihan air"), .bills)
        XCTAssertEqual(category("Bayar RS"), .health)
        XCTAssertEqual(category("H&M"), .shopping)
        XCTAssertEqual(category("J.CO Donuts"), .food)
        XCTAssertEqual(category("Jus alpukat"), .food)
    }

    /// Six letters or more is a name distinctive enough to find anywhere.
    func testALongKeywordIsStillFoundInsideAWord() {
        XCTAssertEqual(category("SHOPEEPAY"), .shopping)
        XCTAssertEqual(category("McDonalds"), .food)
        XCTAssertEqual(category("Biaya berlangganan"), .bills)
    }

    /// These only ever matched through a short keyword inside them, so they
    /// have their own now.
    func testNamesThatMatchedFromInsideHaveTheirOwnKeyword() {
        XCTAssertEqual(category("Indomie goreng"), .food)
        XCTAssertEqual(category("Makanan kucing"), .food)
        XCTAssertEqual(category("Bakmie GM"), .food)
        XCTAssertEqual(category("Risoles"), .food)
        XCTAssertEqual(category("Busway"), .transport)
        XCTAssertEqual(category("Holycow Steakhouse"), .food)
    }

    /// BPJS was fuel, through BP.
    func testBPJSIsABill() {
        XCTAssertEqual(category("BPJS Kesehatan"), .bills)
        XCTAssertEqual(category("BP AKR"), .transport)
    }

    func testAnAirlineIsTravelAndAirIsStillWater() {
        for airline in ["Lion Air", "Batik Air", "Super Air Jet", "Air Asia", "AirAsia", "Pelita Air"] {
            XCTAssertEqual(category(airline), .travel, airline)
        }
        XCTAssertEqual(category("Tagihan air PDAM"), .bills)
    }

    /// The user's history is read by words the same way.
    func testAPastNameIsReadByWholeWords() {
        let transport = (0..<3).map { _ in spent("Transport", .transport) }
        XCTAssertNil(SmartBudgetManager.learnedCategory(for: "Sport", transactions: transport))
        let warkop = (0..<3).map { _ in spent("Warkop Pak Budi", .food) }
        XCTAssertEqual(SmartBudgetManager.learnedCategory(for: "Warkop Bu Ani", transactions: warkop)?.category,
                       .food)
    }

    /// Rows the old reading filed wrong are offered back, and only when
    /// today's reading names a different category.
    func testAMisfiledRowIsOfferedItsRightCategory() {
        XCTAssertEqual(SmartBudgetManager.misfiledFix(name: "Transport", category: .health), .transport)
        XCTAssertEqual(SmartBudgetManager.misfiledFix(name: "BPJS Kesehatan", category: .transport), .bills)
        XCTAssertNil(SmartBudgetManager.misfiledFix(name: "Kebaya pesta", category: .shopping),
                     "Nothing names it now, and the coincidence may be right.")
        XCTAssertNil(SmartBudgetManager.misfiledFix(name: "Indomaret", category: .shopping),
                     "No short keyword inside: the user's own choice.")
        XCTAssertNil(SmartBudgetManager.misfiledFix(name: "Sports Station", category: .health),
                     "Still read as a word today.")
        XCTAssertNil(SmartBudgetManager.misfiledFix(name: "Transport", category: .other))
    }

    /// Tidy holds both kinds: Other to place, and misfiled to put right.
    func testTidyOffersOtherRowsAndMisfiledOnes() {
        let misfiled = TidyCategoriesView.offer(for: spent("Transport", .health))
        XCTAssertEqual(misfiled?.category, .transport)
        XCTAssertEqual(misfiled?.was, .health)
        let uncategorised = TidyCategoriesView.offer(for: spent("Indomaret", .other))
        XCTAssertEqual(uncategorised?.category, .food)
        XCTAssertNil(uncategorised?.was)
        XCTAssertNil(TidyCategoriesView.offer(for: spent("Indomaret", .shopping)))
    }

    /// "AQUA BOTOL" under the shop's name was read as the toll road.
    func testAReceiptItemIsNotTakenForTheShop() {
        let text = """
        TOKO SUMBER REJEKI
        AQUA BOTOL 600ML 4.000
        TOTAL Rp 4.000
        """
        let r = ReceiptParser.parse(rawText: text, fallbackCurrency: "IDR")
        XCTAssertEqual(r.merchantName, "TOKO SUMBER REJEKI")
    }
}
