import XCTest
@testable import DiPo

@MainActor
final class DiPoInterestTests: XCTestCase {

    private func tx(_ name: String, _ cat: TxCategory = .food, amount: Double = -25_000,
                    daysAgo: Double = 1) -> TxRecord {
        TxRecord(name: name, date: .now.addingTimeInterval(-daysAgo * 86_400), amount: amount,
                 type: "tx.type.purchase", icon: "circle", iconBgHex: cat.iconBg, category: cat,
                 currency: "IDR")
    }

    func testThreeCoffeesMakeAGuess() {
        let txs = [tx("Kopi Kenangan"), tx("Starbucks Latte"), tx("Es kopi susu")]
        XCTAssertEqual(DiPoInterest.nextGuess(in: txs, answered: []), .coffee)
    }

    func testTwoAreNotEnoughAndOldOnesDoNotCount() {
        let txs = [tx("Kopi Kenangan"), tx("Starbucks"), tx("Janji Jiwa", daysAgo: 90)]
        XCTAssertNil(DiPoInterest.nextGuess(in: txs, answered: []))
    }

    func testIncomeDoesNotCount() {
        let txs = (0..<4).map { _ in tx("Jual kopi", amount: 50_000) }
        XCTAssertNil(DiPoInterest.nextGuess(in: txs, answered: []))
    }

    func testTravelCategoryCountsWithoutKeywords() {
        let txs = (0..<3).map { _ in tx("Booking", .travel, amount: -900_000) }
        XCTAssertEqual(DiPoInterest.nextGuess(in: txs, answered: []), .travel)
    }

    func testAnsweredInterestIsNotAskedAgain() {
        let txs = (0..<3).map { _ in tx("Sewa lapangan futsal") } + (0..<4).map { _ in tx("Kopi") }
        XCTAssertEqual(DiPoInterest.nextGuess(in: txs, answered: []), .coffee, "the strongest first")
        XCTAssertEqual(DiPoInterest.nextGuess(in: txs, answered: [.coffee]), .sport)
        XCTAssertNil(DiPoInterest.nextGuess(in: txs, answered: [.coffee, .sport]))
    }

    func testContextLineNamesOnlyLikedInterests() {
        XCTAssertNil(DiPoInterestStore.contextLine([]))
        let line = DiPoInterestStore.contextLine([.travel, .coffee]) ?? ""
        XCTAssertTrue(line.contains("coffee") && line.contains("travelling"))
        XCTAssertFalse(line.contains("sport"))
    }

    func testNudgesComeAfterMoneyReminders() {
        let all = DiPoNudge.all(unread: 1, bill: nil, daysToPayday: nil, payDate: nil,
                                interestGuess: .coffee, interestTip: .travel)
        XCTAssertEqual(all.map(\.action), [.notifications, .interestGuess(.coffee), .interestTip(.travel)])
    }

    func testNewInterestsAreGuessedFromTheirOwnWords() {
        let farm = [tx("Pupuk urea 5kg"), tx("Bibit cabai"), tx("Pestisida")]
        XCTAssertEqual(DiPoInterest.nextGuess(in: farm, answered: []), .farming)
        let ride = [tx("Bengkel AHASS"), tx("Ganti oli"), tx("Servis motor")]
        XCTAssertEqual(DiPoInterest.nextGuess(in: ride, answered: []), .automotive)
        let giving = [tx("Zakat"), tx("Sedekah jumat"), tx("Tabungan kurban")]
        XCTAssertEqual(DiPoInterest.nextGuess(in: giving, answered: []), .faith)
    }

    /// A wallet top-up is not a game: "top up" alone must not count.
    func testAWalletTopUpIsNotAGame() {
        let txs = (0..<4).map { _ in tx("Top up GoPay") }
        XCTAssertNil(DiPoInterest.nextGuess(in: txs, answered: []))
    }

    func testCustomInterestsAreKeptTrimmedUniqueAndCapped() {
        let key = "dipo_interests_custom"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        XCTAssertTrue(DiPoInterestStore.addCustom("  Burung kicau "))
        XCTAssertFalse(DiPoInterestStore.addCustom("burung KICAU"), "no repeats")
        XCTAssertFalse(DiPoInterestStore.addCustom("   "), "nothing empty")
        XCTAssertEqual(DiPoInterestStore.custom, ["Burung kicau"])
        for n in ["Batik", "Kopi tubruk", "Wayang", "Catur"] { DiPoInterestStore.addCustom(n) }
        XCTAssertFalse(DiPoInterestStore.addCustom("Layangan"), "five at most")
        XCTAssertEqual(DiPoInterestStore.custom.count, DiPoInterestStore.customLimit)
        DiPoInterestStore.removeCustom("Batik")
        XCTAssertFalse(DiPoInterestStore.custom.contains("Batik"))
    }

    func testContextLineCarriesCustomInterests() {
        let line = DiPoInterestStore.contextLine([.coffee], custom: ["burung kicau"]) ?? ""
        XCTAssertTrue(line.contains("coffee") && line.contains("burung kicau"))
        XCTAssertNotNil(DiPoInterestStore.contextLine([], custom: ["batik"]))
    }

    func testACustomInterestGetsItsOwnIdea() {
        let all = DiPoNudge.all(unread: 0, bill: nil, daysToPayday: nil, payDate: nil,
                                customInterestTip: "burung kicau")
        XCTAssertEqual(all.map(\.action), [.customInterestTip("burung kicau")])
        XCTAssertNotEqual(loc("interest.custom.tip"), "interest.custom.tip")
        XCTAssertNotEqual(loc("interest.custom.prompt"), "interest.custom.prompt")
    }

    func testEveryInterestHasItsStrings() {
        for i in DiPoInterest.allCases {
            for key in ["interest.\(i.rawValue)", "interest.\(i.rawValue).ask",
                        "interest.\(i.rawValue).tip", "interest.\(i.rawValue).prompt"] {
                XCTAssertNotEqual(loc(key), key, "missing \(key)")
            }
        }
    }
}
