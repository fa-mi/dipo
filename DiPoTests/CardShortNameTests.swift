import XCTest
import SwiftData
@testable import DiPo

/// The short names Statistics, the web dashboard and Siri give cards: what
/// tells a card from the user's others, and its last four digits.
@MainActor
final class CardShortNameTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func card(_ holder: String, _ number: String, issuer: String = "") -> BankCard {
        let c = BankCard(holderName: holder, cardNumber: number, balance: 0, expireDate: "11/29",
                         gradientStart: "#000000", gradientEnd: "#111111", sortOrder: 0, currency: "IDR")
        c.issuerID = issuer
        container.mainContext.insert(c)
        return c
    }

    private func wallet(_ provider: String, holder: String = "Fahmi Aquinas") -> BankCard {
        let w = BankCard(holderName: holder, cardNumber: provider, balance: 0, expireDate: "Digital",
                         gradientStart: "#00AED6", gradientEnd: "#006E8A", sortOrder: 0, currency: "IDR",
                         isDigitalWallet: true, walletProvider: provider)
        container.mainContext.insert(w)
        return w
    }

    /// Fahmi's Full analysis header read "Fahmi ••0969" and then "Fahmi
    /// Aquinas BCA ·· 9331, Fahmi Aquinas Mandiri ·· 3661".
    func testTheBankWrittenIntoTheNameIsWhatIsLeft() {
        let bri = card("Fahmi Aquinas BRI", "5221845086220969")
        let bca = card("Fahmi Aquinas BCA", "4111111111119331")
        let mandiri = card("Fahmi Aquinas Mandiri", "4111111111113661")
        let all = [wallet("GoPay"), bri, card("Tokopedia CC", "4111111111110000"), bca, mandiri]
        XCTAssertEqual([bri, bca, mandiri].map { $0.shortName(among: all) },
                       ["BRI ••0969", "BCA ••9331", "Mandiri ••3661"])
        // Case doesn't make a word different.
        let lower = card("fahmi aquinas BNI", "4111111111112222")
        XCTAssertEqual(lower.shortName(among: all + [lower]), "BNI ••2222")
    }

    func testABankChosenForTheCardWins() {
        let c = card("Fahmi Aquinas", "4111111111119331", issuer: "bca")
        XCTAssertEqual(c.shortName(among: [c]), "BCA ••9331")
    }

    func testANameThatIsAllSharedStaysWhole() {
        let a = card("Budi Santoso", "4111111111111111")
        let b = card("Budi Santoso", "4111111111112222")
        XCTAssertEqual(a.shortName(among: [a, b]), "Budi Santoso ••1111", "the digits tell these apart")
        let gaji = card("Budi Santoso Gaji", "4111111111113333")
        XCTAssertEqual(a.shortName(among: [a, gaji]), "Budi Santoso ••1111")
        XCTAssertEqual(gaji.shortName(among: [a, gaji]), "Gaji ••3333")
    }

    func testAloneACardKeepsItsWholeName() {
        let c = card("Fahmi Aquinas BRI", "5221845086220969")
        XCTAssertEqual(c.shortName(among: [c]), "Fahmi Aquinas BRI ••0969", "never compared with itself")
        XCTAssertEqual(c.shortName(among: [c, wallet("OVO", holder: "Fahmi Aquinas")]),
                       "Fahmi Aquinas BRI ••0969", "a wallet's holder isn't a card name")
    }

    func testWalletsGoByProviderAndUnnamedCardsSaySo() {
        let ovo = wallet("OVO")
        XCTAssertEqual(ovo.shortName(among: [ovo]), "OVO")
        let blank = card("", "4111111111114444")
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(blank.shortName(among: [blank]), "Card ••4444")
        }
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(blank.distinctName(among: [blank]), "Kartu")
        }
    }

    func testAStoredMaskedNumberStillGivesItsLastFour() {
        let c = card("Fahmi Aquinas BRI", CardNumber.stored("5221845086220969"))
        XCTAssertEqual(c.shortName(among: [c]), "Fahmi Aquinas BRI ••0969")
    }
}
