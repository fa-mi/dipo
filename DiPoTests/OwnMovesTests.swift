import XCTest
import SwiftData
@testable import DiPo

/// "Between your own accounts +Rp 1.950.000", opened up: which card, which
/// way, and what came into the other card first.
@MainActor
final class OwnMovesTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func card(_ holder: String, _ number: String) -> BankCard {
        let c = BankCard(holderName: holder, cardNumber: number, balance: 0,
                         expireDate: "11/29", gradientStart: "#000000", gradientEnd: "#111111",
                         sortOrder: 0, currency: "IDR")
        context.insert(c)
        return c
    }

    private func day(_ m: Int, _ d: Int, _ h: Int = 10, _ min: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
    }

    private func row(_ name: String, _ amount: Double, _ date: Date, _ cat: TxCategory = .other,
                     subtype: TxSubtype = .normal, icon: String = "X", notes: String = "") -> TxRecord {
        let t = TxRecord(name: name, date: date, amount: amount,
                         type: amount < 0 ? "tx.type.purchase" : "tx.type.income", icon: icon,
                         iconBgHex: cat.iconBg, category: cat, currency: "IDR", notes: notes, subtype: subtype)
        context.insert(t)
        return t
    }

    /// Both legs of one card-to-card transfer, a moment apart, as the
    /// Transfer sheet writes them.
    private func move(_ amount: Double, from a: BankCard, to b: BankCard, at date: Date) {
        a.transactions.append(row("Transfer to \(b.last4)", -amount, date, subtype: .transfer, icon: "⇄"))
        b.transactions.append(row("Transfer from \(a.last4)", amount, date.addingTimeInterval(0.2),
                                  subtype: .transfer, icon: "⇄"))
    }

    /// Fahmi's period from 25 Sep: Rp 1.950.000 net, and Dad's Rp 2.500.000
    /// repayment arriving on BCA just before Rp 2.600.000 went to BRI.
    func testTheLineOpensIntoCardsAndNamesDadsRepayment() {
        let bri = card("Fahmi", "5221845086220969")
        let bca = card("Fahmi", "4111111111119331")
        let mandiri = card("Fahmi", "4111111111113661")
        let ovo = card("OVO", "")
        ovo.isDigitalWallet = true
        ovo.walletProvider = "OVO"

        move(50_000, from: bri, to: ovo, at: day(9, 28))
        move(400_000, from: bri, to: bca, at: day(10, 5))
        move(200_000, from: bri, to: mandiri, at: day(10, 5, 10, 5))
        bca.transactions.append(row("Repaid by Dad", 2_500_000, day(10, 8, 9), .incomeOther,
                                    subtype: .transfer, icon: "DA", notes: "tx.note.receivable_repaid"))
        bca.transactions.append(row("laundry", -62_000, day(10, 8, 9, 30), .bills))
        move(2_600_000, from: bca, to: bri, at: day(10, 8, 11))

        let window = bri.transactions.filter { $0.date >= day(9, 25, 0) }
        let lines = OwnMoves.lines(window, scope: [bri], cards: [bri, bca, mandiri, ovo], convert: { $0.amount })

        XCTAssertEqual(lines.map(\.incoming), [true, false, false, false], "money in first")
        XCTAssertEqual(lines.map(\.amount), [2_600_000, 400_000, 200_000, 50_000])
        XCTAssertEqual(lines.map(\.label), [bca.pickerLabel, bca.pickerLabel, mandiri.pickerLabel, "OVO"])
        let net = lines.reduce(0.0) { $0 + ($1.incoming ? $1.amount : -$1.amount) }
        XCTAssertEqual(net, 1_950_000, "adds up to the cash book's line")

        XCTAssertEqual(lines[0].sources.map(\.name), ["Repaid by Dad"],
                       "the BRI→BCA top-up and the laundry are not sources")
        XCTAssertEqual(lines[0].sources.first?.amount, 2_500_000)
        XCTAssertTrue(lines[1].sources.isEmpty, "only money coming in gets sources")
    }

    /// With BCA read together with BRI as a bill card, moves between them
    /// cancel out inside the pot and drop out of the breakdown.
    func testMovesInsideThePotAreLeftOut() {
        let bri = card("Fahmi", "5221845086220969")
        let bca = card("Fahmi", "4111111111119331")
        let ovo = card("OVO", "")
        move(400_000, from: bri, to: bca, at: day(10, 5))
        move(2_600_000, from: bca, to: bri, at: day(10, 8, 11))
        move(50_000, from: bri, to: ovo, at: day(9, 28))

        let window = (bri.transactions + bca.transactions).filter { $0.date >= day(9, 25, 0) }
        let lines = OwnMoves.lines(window, scope: [bri, bca], cards: [bri, bca, ovo], convert: { $0.amount })
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.incoming, false)
        XCTAssertEqual(lines.first?.amount, 50_000)
    }

    func testALegWhoseOtherHalfIsGoneKeepsItsOwnName() {
        let bri = card("Fahmi", "5221845086220969")
        bri.transactions.append(row("Transfer from DANA", 50_000, day(10, 1), subtype: .transfer, icon: "⇄"))
        let lines = OwnMoves.lines(bri.transactions, scope: [bri], cards: [bri], convert: { $0.amount })
        XCTAssertEqual(lines.map(\.label), ["Transfer from DANA"])
        XCTAssertTrue(lines[0].sources.isEmpty)
    }

    func testStringsExist() {
        for key in ["stats.own_from", "stats.own_to", "stats.own_source", "stats.own_show", "stats.own_hide"] {
            XCTAssertNotEqual(loc(key), key, "missing \(key)")
        }
    }
}
