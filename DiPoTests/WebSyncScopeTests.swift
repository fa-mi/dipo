import XCTest
import SwiftData
@testable import DiPo

/// Home adds up every card; the dashboard, like Statistics, reads the main
/// card and its bill cards. The sync names them so the page can say so.
@MainActor
final class WebSyncScopeTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var savedMain: String?
    private var savedBills: [String] = []

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        savedMain = MainCard.id
        savedBills = SmartBudgetManager.shared.billCardIDs
        MainCard.id = nil
        SmartBudgetManager.shared.billCardIDs = []
    }

    override func tearDown() {
        MainCard.id = savedMain
        SmartBudgetManager.shared.billCardIDs = savedBills
        super.tearDown()
    }

    private func card(_ holder: String, _ number: String) -> BankCard {
        let c = BankCard(holderName: holder, cardNumber: number, balance: 0, expireDate: "11/29",
                         gradientStart: "#000000", gradientEnd: "#111111", sortOrder: 0, currency: "IDR")
        context.insert(c)
        return c
    }

    func testTheMainCardAndItsBillCardsAreNamed() throws {
        let bri = card("BRI", "5221845086220969")
        let bca = card("Fahmi", "4111111111119331")
        let other = card("Mandiri", "4111111111111234")
        MainCard.set(bri)
        MainCard.setBillCard(bca, true)

        let scope = try XCTUnwrap(WebSyncService.scope(cards: [bri, bca, other]))
        XCTAssertEqual(scope["label"] as? String, "BRI ·· 0969")
        XCTAssertEqual(scope["billCards"] as? [String], ["Fahmi ·· 9331"], "a card it doesn't pay from is left out")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(scope))
    }

    func testNoMainCardSendsNothing() {
        let bri = card("BRI", "5221845086220969")
        XCTAssertNil(WebSyncService.scope(cards: [bri]))
    }

    /// The Sync screen's words: the two keys named as an account number and
    /// a PIN, three short steps, and every one in both languages.
    func testTheSyncScreenWordsExistInBothLanguages() {
        let keys = ["websync.header", "websync.login_title", "websync.id_label", "websync.id_like",
                    "websync.code_label", "websync.code_like", "websync.code_pending", "websync.code_hint",
                    "websync.how1", "websync.how2", "websync.how3", "websync.synced", "websync.valid_until"]
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in keys { XCTAssertNotEqual(loc(key), key, "\(key) in \(language)") }
                let how1 = String(format: loc("websync.how1"), loc("websync.action"))
                let parsed = (try? AttributedString(markdown: how1)) ?? AttributedString(how1)
                XCTAssertTrue(String(parsed.characters).contains(loc("websync.action")), how1)
                XCTAssertFalse(String(parsed.characters).contains("**"), "the bold marks are read, not printed")
                XCTAssertTrue(String(format: loc("websync.valid_until"), "22 Oct, 11:29").contains("22 Oct, 11:29"))
            }
        }
        for gone in ["websync.your_id", "websync.id_hint", "websync.step1t", "websync.next_step"] {
            XCTAssertEqual(loc(gone), gone, "\(gone) is no longer used")
        }
    }

    /// The headline names the main card on both screens.
    func testTheBalanceLabelSaysMainCard() {
        XCTAssertEqual(LanguageManager.shared.withLanguage(.english) { loc("stats.balance_now") },
                       "Main card balance now")
        XCTAssertEqual(LanguageManager.shared.withLanguage(.indonesian) { loc("stats.balance_now") },
                       "Saldo kartu utama sekarang")
    }
}
