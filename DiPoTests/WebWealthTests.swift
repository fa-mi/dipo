import XCTest
import SwiftData
@testable import DiPo

/// The web dashboard's "Hartamu hari ini", "Investasimu" and "Barang
/// berhargamu" come from the phone (DiPo/WebWealth.swift). Their total is
/// Home's net worth, from the same function, and the snapshot carries only
/// what those sections print.
@MainActor
final class WebWealthTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private let cal = Calendar(identifier: .gregorian)

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    override func tearDownWithError() throws { container = nil }

    // MARK: Helpers (fictional figures)

    private var now: Date { day(2026, 11, 28) }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func cashCard(_ balance: Double) -> BankCard {
        let c = BankCard(holderName: "Kas", cardNumber: "4000000000001111", balance: balance,
                         expireDate: "11/29", gradientStart: "#000000", gradientEnd: "#111111",
                         sortOrder: 0, currency: "IDR")
        context.insert(c)
        return c
    }

    private func creditCard(owed: Double) -> BankCard {
        let c = BankCard(holderName: "Kartu", cardNumber: "4000000000002222", balance: 0,
                         expireDate: "11/29", gradientStart: "#000000", gradientEnd: "#111111",
                         sortOrder: 1, currency: "IDR")
        c.isCreditCard = true
        c.creditLimit = 20_000_000
        c.openingOwed = owed
        c.creditSince = .distantPast
        context.insert(c)
        return c
    }

    private func debt(_ left: Double, type: String = "loan") -> DebtRecord {
        let d = DebtRecord(name: "Pinjaman", type: type, totalAmount: left * 2, currentBalance: left,
                           minimumPayment: 0, annualInterestRate: 0, dueDayOfMonth: 5, currency: "IDR")
        context.insert(d)
        return d
    }

    private func holding(_ type: InvestmentType, name: String, symbol: String = "",
                         units: Double, buyAt: Double, price: Double,
                         income: Double = 0, priced: Date? = nil) -> InvestmentHolding {
        let h = InvestmentHolding(type: type, name: name, symbol: symbol, currency: "IDR", lastPrice: price)
        h.priceUpdatedAt = priced
        context.insert(h)
        let buy = InvestmentLot(kind: .buy, date: day(2025, 1, 10), units: units, pricePerUnit: buyAt,
                                note: "catatan beli rahasia")
        context.insert(buy)
        h.lots.append(buy)
        if income > 0 {
            let c = InvestmentLot(kind: .coupon, date: day(2026, 6, 1), cashAmount: income)
            context.insert(c)
            h.lots.append(c)
        }
        return h
    }

    private func asset(_ kind: AssetKind, name: String, paid: Double, bought: Date,
                       tax: Date? = nil, notes: String = "") -> PhysicalAsset {
        let a = PhysicalAsset(kind: kind, name: name, currency: "IDR", purchasePrice: paid,
                              purchaseDate: bought, taxDueDate: tax, notes: notes)
        context.insert(a)
        return a
    }

    private struct World {
        var cards: [BankCard] = []
        var goals: [SavingsGoal] = []
        var receivables: [Receivable] = []
        var holdings: [InvestmentHolding] = []
        var assets: [PhysicalAsset] = []
        var debts: [DebtRecord] = []
    }

    private func payload(_ w: World) -> [String: Any] {
        WebWealth.payload(cards: w.cards, goals: w.goals, receivables: w.receivables,
                          holdings: w.holdings, assets: w.assets, debts: w.debts, installments: [],
                          currency: "IDR", now: now, calendar: cal)
    }

    private func parts(_ w: World) -> NetWorthParts {
        NetWorth.parts(cards: w.cards, goals: w.goals, receivables: w.receivables,
                       holdings: w.holdings, assets: w.assets, debts: w.debts, installments: [],
                       currency: "IDR", now: now)
    }

    private func world() -> World {
        var w = World()
        w.cards = [cashCard(4_000_000), creditCard(owed: 1_500_000)]
        let goal = SavingsGoal(name: "Sekolah", targetAmount: 10_000_000, savedAmount: 2_000_000, currency: "IDR")
        context.insert(goal)
        w.goals = [goal]
        let r = Receivable(personName: "Tetangga", amount: 500_000, currency: "IDR")
        context.insert(r)
        w.receivables = [r]
        w.holdings = [
            holding(.gold, name: "Emas", units: 5, buyAt: 1_000_000, price: 1_200_000, priced: day(2026, 11, 27)),
            holding(.deposit, name: "Deposito", units: 3_000_000, buyAt: 1, price: 1, income: 60_000),
            holding(.stock, name: "Saham", symbol: "ZZZZ", units: 100, buyAt: 5_000, price: 4_000,
                    priced: day(2026, 9, 1)),
        ]
        w.assets = [
            asset(.land, name: "Kebun", paid: 20_000_000, bought: day(2020, 3, 1), tax: day(2024, 8, 31),
                  notes: "letak patok rahasia"),
            asset(.motorcycle, name: "Motor", paid: 15_000_000, bought: day(2026, 8, 1), tax: day(2025, 12, 9)),
        ]
        w.debts = [debt(3_000_000)]
        return w
    }

    // MARK: The figure is Home's

    func testTheTotalIsHomesNetWorth() {
        let w = world()
        let p = payload(w)
        let home = parts(w)
        XCTAssertEqual(p["net"] as? Double ?? .nan, home.total, accuracy: 0.5)
        XCTAssertEqual(p["cash"] as? Double ?? .nan, 4_000_000, accuracy: 0.5)
        XCTAssertEqual(p["savings"] as? Double ?? .nan, 2_000_000, accuracy: 0.5)
        XCTAssertEqual(p["lent"] as? Double ?? .nan, 500_000, accuracy: 0.5)
        // Gold 5 × 1,2 jt + deposit 3 jt + stock 100 × 4.000.
        XCTAssertEqual(p["investments"] as? Double ?? .nan, 9_400_000, accuracy: 0.5)
        XCTAssertEqual(p["owed"] as? Double ?? .nan, 4_500_000, accuracy: 0.5)
        XCTAssertEqual(p["cardOwed"] as? Double ?? .nan, 1_500_000, accuracy: 0.5)
        let assets = p["assets"] as? Double ?? .nan
        XCTAssertEqual(assets, w.assets.reduce(0) { $0 + $1.value(at: now) }, accuracy: 0.5)
        XCTAssertEqual(home.total, 4_000_000 + 2_000_000 + 500_000 + 9_400_000 + assets - 4_500_000, accuracy: 0.5)
    }

    /// A card also recorded by hand as a credit-card debt is the same money:
    /// counted once, as the debt, as on Home and the Debts screen.
    func testACardRecordedAsADebtCountsOnce() {
        var w = World()
        w.cards = [cashCard(1_000_000), creditCard(owed: 2_000_000)]
        w.debts = [debt(2_000_000, type: DebtType.creditCard.rawValue)]
        let p = payload(w)
        XCTAssertEqual(p["owed"] as? Double ?? .nan, 2_000_000, accuracy: 0.5)
        XCTAssertEqual(p["cardOwed"] as? Double ?? .nan, 0, accuracy: 0.5)
        XCTAssertEqual(p["net"] as? Double ?? .nan, -1_000_000, accuracy: 0.5)
    }

    /// Home and the sync both read NetWorth.parts; neither keeps its own sum.
    func testHomeAndTheSyncShareOneFunction() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let home = try String(contentsOf: root.appendingPathComponent("HomeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("NetWorth.parts("))
        XCTAssertFalse(home.contains("struct NetWorthParts"))
        let sync = try String(contentsOf: root.appendingPathComponent("WebSyncService.swift"), encoding: .utf8)
        XCTAssertTrue(sync.contains("out[\"wealth\"] = WebWealth.payload("))
    }

    // MARK: Only what the page prints

    func testCarriesOnlyWhatTheSectionsPrint() throws {
        let p = payload(world())
        XCTAssertEqual(Set(p.keys), ["net", "cash", "savings", "lent", "investments", "assets",
                                      "owed", "cardOwed", "holdings", "things"])
        let holdingKeys: Set<String> = ["name", "type", "value", "cost", "gain", "grams", "priceDate"]
        for row in p["holdings"] as? [[String: Any]] ?? [] {
            XCTAssertTrue(Set(row.keys).isSubset(of: holdingKeys), "\(row.keys)")
        }
        let thingKeys: Set<String> = ["name", "kind", "value", "paid", "year", "enteredMonth",
                                      "ratePct", "firstYearDropPct", "tax", "taxDue"]
        for row in p["things"] as? [[String: Any]] ?? [] {
            XCTAssertTrue(Set(row.keys).isSubset(of: thingKeys), "\(row.keys)")
        }
        XCTAssertTrue(JSONSerialization.isValidJSONObject(p))
        let text = String(decoding: try JSONSerialization.data(withJSONObject: p), as: UTF8.self)
        for secret in ["ZZZZ", "catatan beli rahasia", "letak patok rahasia", "Tetangga", "2026-08-01", "2020-03-01"] {
            XCTAssertFalse(text.contains(secret), "\(secret) must not reach the web")
        }
    }

    // MARK: Investments

    func testHoldingRows() {
        let rows = payload(world())["holdings"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.compactMap { $0["name"] as? String }, ["Emas", "Deposito", "Saham"], "largest first")

        let gold = rows[0]
        XCTAssertEqual(gold["type"] as? String, "gold")
        XCTAssertEqual(gold["value"] as? Double ?? .nan, 6_000_000, accuracy: 0.5)
        XCTAssertEqual(gold["cost"] as? Double ?? .nan, 5_000_000, accuracy: 0.5)
        XCTAssertEqual(gold["gain"] as? Double ?? .nan, 1_000_000, accuracy: 0.5)
        XCTAssertEqual(gold["grams"] as? Double ?? .nan, 5, accuracy: 1e-9)
        XCTAssertNil(gold["priceDate"], "priced yesterday")

        // A deposit's interest is what it made.
        let deposit = rows[1]
        XCTAssertEqual(deposit["gain"] as? Double ?? .nan, 60_000, accuracy: 0.5)
        XCTAssertNil(deposit["grams"])
        XCTAssertNil(deposit["priceDate"], "a deposit has no price to go stale")

        let stock = rows[2]
        XCTAssertEqual(stock["gain"] as? Double ?? .nan, -100_000, accuracy: 0.5)
        XCTAssertEqual(stock["priceDate"] as? String, "2026-09-01", "a price untouched for months is dated")
    }

    func testASoldOutHoldingIsNotARow() {
        let h = holding(.stock, name: "Terjual", units: 10, buyAt: 1_000, price: 1_200)
        let sell = InvestmentLot(kind: .sell, date: day(2026, 2, 1), units: 10, pricePerUnit: 1_100)
        context.insert(sell)
        h.lots.append(sell)
        XCTAssertTrue(WebWealth.holdingRows([h], currency: "IDR", now: now, calendar: cal).isEmpty)
    }

    // MARK: Belongings

    func testThingRows() {
        let rows = payload(world())["things"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.compactMap { $0["name"] as? String }, ["Kebun", "Motor"], "largest first")

        let land = rows[0]
        XCTAssertEqual(land["kind"] as? String, "land")
        XCTAssertEqual(land["year"] as? Int, 2020)
        XCTAssertEqual(land["paid"] as? Double ?? .nan, 20_000_000, accuracy: 0.5)
        XCTAssertEqual(land["ratePct"] as? Int, Int(AssetKind.land.defaultAnnualRate))
        XCTAssertNil(land["firstYearDropPct"])
        XCTAssertEqual(land["tax"] as? String, "pbb")
        XCTAssertEqual(land["taxDue"] as? String, "2027-08-31", "the next one, not the date first entered")

        // Bought four months ago: still in the year of the big drop.
        let motor = rows[1]
        XCTAssertEqual(motor["firstYearDropPct"] as? Int, Int(AssetKind.motorcycle.firstYearDrop))
        XCTAssertEqual(motor["ratePct"] as? Int, Int(AssetKind.motorcycle.defaultAnnualRate))
        XCTAssertEqual(motor["tax"] as? String, "stnk")
        XCTAssertEqual(motor["taxDue"] as? String, "2026-12-09")
    }

    func testAValueTheUserEnteredIsNamedNotARate() {
        let a = asset(.car, name: "Mobil", paid: 100_000_000, bought: day(2019, 5, 1))
        a.manualValue = 80_000_000
        a.manualValueDate = day(2026, 10, 3)
        let row = WebWealth.thingRows([a], currency: "IDR", now: now, calendar: cal)[0]
        XCTAssertEqual(row["enteredMonth"] as? String, "2026-10")
        XCTAssertNil(row["ratePct"])
        XCTAssertNil(row["firstYearDropPct"])
        XCTAssertEqual(row["value"] as? Double ?? .nan, a.value(at: now), accuracy: 0.5)
    }

    func testOnlyTaxedKindsCarryATax() {
        let phone = asset(.electronics, name: "HP", paid: 3_000_000, bought: day(2025, 1, 1), tax: day(2025, 6, 1))
        XCTAssertNil(WebWealth.thingRows([phone], currency: "IDR", now: now, calendar: cal)[0]["tax"])
        for kind in AssetKind.allCases {
            XCTAssertEqual(WebWealth.taxKey(kind) != nil, kind.taxLabel != nil, "\(kind)")
        }
    }

    func testAnEmptyWorldStillSendsTheFigure() {
        var w = World()
        w.cards = [cashCard(750_000)]
        let p = payload(w)
        XCTAssertEqual(p["net"] as? Double ?? .nan, 750_000, accuracy: 0.5)
        XCTAssertEqual((p["holdings"] as? [Any])?.count, 0)
        XCTAssertEqual((p["things"] as? [Any])?.count, 0)
    }
}
