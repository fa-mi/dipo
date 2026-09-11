import XCTest
@testable import DiPo

// The anchor every calculation reads, and the two bugs that made it unusable:
// a launch-time wipe, and a save() that ran while load() was still assigning.
final class MainCardTests: XCTestCase {

    private func card(_ name: String, credit: Bool = false) -> BankCard {
        let c = BankCard(holderName: name, cardNumber: "5221845086220969", balance: 0,
                         expireDate: "11/29", gradientStart: "#000000", gradientEnd: "#111111",
                         sortOrder: 0, currency: "IDR")
        c.isCreditCard = credit
        return c
    }

    private func salary(_ amount: Double, day: Int, cardID: UUID?,
                        pinned: Bool = false, created: Date = .distantPast) -> SalarySchedule {
        let s = SalarySchedule(label: "s", amount: amount, dayOfMonth: day,
                               currency: "IDR", cardID: cardID)
        s.isPinned = pinned
        s.createdAt = created
        return s
    }

    override func setUp() {
        super.setUp()
        MainCard.id = nil
    }

    // MARK: Reconcile

    func testEmptyListNeverClearsTheChoice() {
        let a = card("A")
        MainCard.set(a)
        // The launch bug: `AppViewModel.cards` starts empty and fills in
        // asynchronously, so reconciling too early found no match for a valid
        // id and erased it — the gate reappeared on every single launch.
        MainCard.reconcile(cards: [])
        XCTAssertEqual(MainCard.id, a.id.uuidString)
    }

    func testDeletedCardIsCleared() {
        let a = card("A"), b = card("B"), c = card("C")
        MainCard.set(a)
        // A non-empty pool that genuinely lacks the card IS the delete case.
        MainCard.reconcile(cards: [b, c])
        XCTAssertNil(MainCard.id)
    }

    func testSingleEligibleCardIsAdopted() {
        let a = card("A")
        MainCard.reconcile(cards: [a])
        XCTAssertEqual(MainCard.id, a.id.uuidString)
        // Choosing from a list of one is ceremony, not consent.
        XCTAssertFalse(MainCard.needsChoice(cards: [a]))
    }

    func testCreditCardsAreNeverEligible() {
        let cc = card("CC", credit: true), debit = card("D")
        MainCard.set(cc)
        XCTAssertNil(MainCard.id)                       // refused outright
        MainCard.reconcile(cards: [cc, debit])
        XCTAssertEqual(MainCard.id, debit.id.uuidString) // only one real option
        XCTAssertFalse(MainCard.needsChoice(cards: [cc, cc]))  // nothing to ask
    }

    func testGateOnlyWhenThereIsARealChoice() {
        let a = card("A"), b = card("B")
        XCTAssertTrue(MainCard.needsChoice(cards: [a, b]))
        MainCard.set(a)
        XCTAssertFalse(MainCard.needsChoice(cards: [a, b]))
    }

    // MARK: Income scoping

    func testUnassignedSalariesCountAsHere() {
        let a = card("A")
        MainCard.set(a)
        let legacy = salary(10_000_000, day: 25, cardID: nil)
        // `cardID` is optional and old schedules have none. Excluding them
        // would drop a user's whole income to zero over a rule they never saw.
        XCTAssertEqual(MainCard.salaries([legacy]).count, 1)
        XCTAssertTrue(MainCard.salariesElsewhere([legacy]).isEmpty)
    }

    func testSecondJobOnAnotherCardIsExcludedAndDisclosed() {
        let a = card("A"), b = card("B")
        MainCard.set(a)
        let here = salary(10_000_000, day: 25, cardID: a.id)
        let there = salary(5_000_000, day: 10, cardID: b.id)
        XCTAssertEqual(MainCard.salaries([here, there]).map(\.amount), [10_000_000])
        XCTAssertEqual(MainCard.salariesElsewhere([here, there]).map(\.amount), [5_000_000])
    }

    func testEverythingElsewhereFallsBackRatherThanReportingZero() {
        let a = card("A"), b = card("B")
        MainCard.set(a)
        let there = salary(7_000_000, day: 10, cardID: b.id)
        // Zero income does not read as "your salary is elsewhere", it reads as
        // a broken app — allowances collapse and the score bottoms out.
        XCTAssertEqual(MainCard.salaries([there]).count, 1)
        // And nothing is "excluded", so nothing is disclosed as excluded.
        XCTAssertTrue(MainCard.salariesElsewhere([there]).isEmpty)
    }

    // MARK: Which payday anchors the cycle

    func testPinnedScheduleWinsOutright() {
        let big = salary(10_000_000, day: 25, cardID: nil)
        let side = salary(3_000_000, day: 5, cardID: nil, pinned: true)
        XCTAssertEqual(MainCard.anchor(among: [big, side])?.dayOfMonth, 5)
    }

    func testLargestWinsWhenNothingIsPinned() {
        let early = Date(timeIntervalSince1970: 0)
        let late = Date(timeIntervalSince1970: 10_000)
        let side = salary(3_000_000, day: 5, cardID: nil, created: early)
        let main = salary(10_000_000, day: 25, cardID: nil, created: late)
        // Entry order must not decide the cycle: five screens used to take
        // `.first` of differently-ordered arrays and disagreed with each other.
        XCTAssertEqual(MainCard.anchor(among: [side, main])?.dayOfMonth, 25)
        XCTAssertEqual(MainCard.anchor(among: [main, side])?.dayOfMonth, 25)
    }

    func testTiesBreakOnEarliestCreated() {
        let first = salary(5_000_000, day: 25, cardID: nil,
                           created: Date(timeIntervalSince1970: 0))
        let second = salary(5_000_000, day: 10, cardID: nil,
                            created: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(MainCard.anchor(among: [second, first])?.dayOfMonth, 25)
    }

    func testNoActiveSalaryHasNoPayday() {
        XCTAssertNil(MainCard.payDay([]))
    }
}
