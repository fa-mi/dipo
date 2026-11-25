import XCTest
import SwiftData
@testable import DiPo

/// The main card's period note ends with the balance, and with bill cards
/// (Smart Budget → "Tagihan yang dibayar dari kartu lain") that balance is
/// the pot's: the main card plus the cards it pays bills from. Said as
/// "Saldo masih …" under the main card, the sum read as that card's own
/// balance and didn't match it. The sentence now names the cards it adds.
@MainActor
final class PotBalanceNameTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func card(_ name: String, _ number: String) -> BankCard {
        let c = BankCard(holderName: name, cardNumber: number, balance: 0, expireDate: "11/29",
                         gradientStart: "#000000", gradientEnd: "#000000", sortOrder: 0, currency: "IDR")
        container.mainContext.insert(c)
        return c
    }

    /// Cards named after their holder read by their bank, in the pot's order.
    func testThePotIsSaidByItsCards() {
        let pot = [card("Budi Santoso BRI", "0000000000000001"),
                   card("Budi Santoso BCA", "0000000000000002"),
                   card("Budi Santoso Mandiri", "0000000000000003")]
        XCTAssertEqual(BankCard.joinedNames(pot, among: pot), "BRI + BCA + Mandiri")
    }

    /// Two cards of one bank stay apart by their last four digits.
    func testTwoCardsOfOneBankKeepTheirDigits() {
        let pot = [card("Budi BRI", "0000000000001111"), card("Budi BRI", "0000000000002222")]
        let said = BankCard.joinedNames(pot, among: pot)
        XCTAssertTrue(said.contains("1111") && said.contains("2222"), said)
    }

    /// Both languages name the cards and then the amount.
    func testTheSentenceInBothLanguages() {
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(String(format: loc("home.balance_ok_pot"), "BRI + BCA", "Rp 100"),
                           "Saldo BRI + BCA masih Rp 100.")
        }
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(String(format: loc("home.balance_ok_pot"), "BRI + BCA", "Rp 100"),
                           "BRI + BCA together still hold Rp 100.")
        }
    }

    /// Home says the pot's cards when there is more than one, and the plain
    /// sentence when the card stands alone.
    func testHomeNamesThePotWhenItHasBillCards() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let home = try String(contentsOf: root.appendingPathComponent("HomeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("scope.count > 1"))
        XCTAssertTrue(home.contains("BankCard.joinedNames(scope, among: queriedCards)"))
        XCTAssertTrue(home.contains("loc(\"home.balance_ok\")"))
    }
}
