import XCTest
import SwiftData
@testable import DiPo

/// One payment told by two apps, or one move told from both ends, is flagged
/// on both rows and never merged: two coffees at the same price are real too.
@MainActor
final class PendingTwinsTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    override func tearDownWithError() throws {
        container = nil
    }

    private func row(_ amount: Double, at minutes: Double, currency: String = "IDR",
                     source: PendingSource = .notification) -> PendingTransaction {
        let item = PendingTransaction(name: "Row", amount: amount, currency: currency, source: source)
        item.capturedAt = start.addingTimeInterval(minutes * 60)
        container.mainContext.insert(item)
        return item
    }

    /// ShopeePay and Shopee both announcing one payment.
    func testOnePaymentToldTwice() {
        let a = row(-45_000, at: 0), b = row(-45_000, at: 0.5), other = row(-12_000, at: 1)
        let rows = [a, b, other]
        XCTAssertEqual(PendingTwins.kind(of: a, among: rows), .repeated)
        XCTAssertEqual(PendingTwins.kind(of: b, among: rows), .repeated)
        XCTAssertNil(PendingTwins.kind(of: other, among: rows))
    }

    /// A top-up told by the bank (out) and by the wallet (in).
    func testAMoveBetweenOwnCards() {
        let out = row(-100_000, at: 0), into = row(100_000, at: 1)
        XCTAssertEqual(PendingTwins.kind(of: out, among: [out, into]), .crossed)
        XCTAssertEqual(PendingTwins.kind(of: into, among: [out, into]), .crossed)
    }

    func testCrossedOutranksRepeated() {
        let out = row(-100_000, at: 0), outAgain = row(-100_000, at: 0.2), into = row(100_000, at: 1)
        XCTAssertEqual(PendingTwins.kind(of: out, among: [out, outAgain, into]), .crossed)
    }

    func testFarApartOrDifferentMoneyIsNoTwin() {
        let a = row(-45_000, at: 0)
        XCTAssertNil(PendingTwins.kind(of: a, among: [a, row(-45_000, at: 11)]), "Eleven minutes apart.")
        XCTAssertNil(PendingTwins.kind(of: a, among: [a, row(-45_000, at: 1, currency: "USD")]))
        XCTAssertNil(PendingTwins.kind(of: a, among: [a, row(-45_500, at: 1)]))
        XCTAssertNil(PendingTwins.kind(of: a, among: [a]), "A row is not its own twin.")
    }

    /// A held bill carries its own note about the row it matched.
    func testAHeldBillIsLeftOut() {
        let bill = row(-150_000, at: 0, source: .recurring), paid = row(-150_000, at: 1)
        XCTAssertNil(PendingTwins.kind(of: bill, among: [bill, paid]))
        XCTAssertNil(PendingTwins.kind(of: paid, among: [bill, paid]))
    }
}
