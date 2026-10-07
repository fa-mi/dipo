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

    func testEveryInterestHasItsStrings() {
        for i in DiPoInterest.allCases {
            for key in ["interest.\(i.rawValue)", "interest.\(i.rawValue).ask",
                        "interest.\(i.rawValue).tip", "interest.\(i.rawValue).prompt"] {
                XCTAssertNotEqual(loc(key), key, "missing \(key)")
            }
        }
    }
}
