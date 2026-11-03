import XCTest
@testable import DiPo

/// Credit packs: two consumables sold through RevenueCat's "ai_credits"
/// offering. The app only buys; the Worker adds the credits once RevenueCat
/// tells it, so the product table here has to match the Worker's.
@MainActor
final class CreditPacksTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
    }

    /// The App Store Connect Product IDs, and the Worker's CREDIT_PACKS
    /// (dipo-backend, src/purchases.js).
    func testThePacksAreTheStoreProducts() {
        XCTAssertEqual(CreditPacks.credits, [
            "com.fahmiaquinas.DiPo.credits30": 30,
            "com.fahmiaquinas.DiPo.credits100": 100,
        ])
        XCTAssertEqual(CreditPacks.offeringID, "ai_credits")
    }

    func testSmallestFirstAndTheLargerChosen() {
        let packs = [CreditPack(id: "b", credits: 100, price: "Rp 39.000"),
                     CreditPack(id: "a", credits: 30, price: "Rp 15.000")]
        XCTAssertEqual(CreditPacks.sorted(packs).map(\.credits), [30, 100])
        XCTAssertEqual(CreditPacks.defaultChoice(packs), "b")
        XCTAssertNil(CreditPacks.defaultChoice([]))
    }

    func testBuyLabelInWords() {
        let pack = CreditPack(id: "x", credits: 100, price: "Rp 39.000")
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(CreditPacks.buyLabel(pack), "Beli 100 kredit · Rp 39.000")
        }
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(CreditPacks.buyLabel(pack), "Buy 100 credits · Rp 39.000")
        }
    }

    func testStringsInBothLanguages() {
        let keys = ["packs.title", "packs.sub", "packs.left", "packs.pack", "packs.buy", "packs.bought",
                    "packs.add", "packs.footer", "packs.unavailable", "packs.retry",
                    "packs.err.signin", "packs.err.generic"]
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                for k in keys { XCTAssertNotEqual(loc(k), k, "\(k) in \(lang)") }
            }
        }
    }

    /// A purchase made while RevenueCat doesn't know who is buying would
    /// belong to no DiPo account, and the credits would go nowhere.
    func testNoPurchaseWithoutASignedInUser() throws {
        let src = try source("DiPo/CreditPacks.swift")
        XCTAssertTrue(src.contains("guard !Purchases.shared.isAnonymous"))
    }

    /// The app never adds credits itself: it only buys and reads the balance.
    func testTheAppNeverWritesCredits() throws {
        let src = try source("DiPo/CreditPacks.swift")
        for write in ["user_credit_packs", "user_credits", "credit_purchases", "Firestore"] {
            XCTAssertFalse(src.contains(write), write)
        }
    }

    /// One green button on the sheet: Buy.
    func testOneGreenButton() throws {
        XCTAssertEqual(try source("DiPo/CreditPacks.swift").components(separatedBy: "accentFill").count - 1, 1)
    }

    /// Where credits run low or out, the way to a pack is there.
    func testOfferedWhereCreditsRunOut() throws {
        XCTAssertTrue(try source("AIChatView.swift").contains("BuyCreditsSheet("))
        XCTAssertTrue(try source("DiPo/DebtAnalysis.swift").contains("BuyCreditsSheet("))
    }
}
