import XCTest
@testable import DiPo

/// What Apple Intelligence's on-device reading is held to before anyone sees
/// it. The model itself only runs on a phone that has it; these check the
/// rules its answers must pass, which run everywhere.
@MainActor
final class OnDeviceTxParserTests: XCTestCase {

    private func entry(_ name: String, _ amount: Double, expense: Bool = true,
                       _ category: TxCategory = .other) -> OnDeviceTxParser.Candidate {
        OnDeviceTxParser.Candidate(name: name, amount: amount, isExpense: expense, category: category)
    }

    // MARK: The numbers written in a message

    func testAmountsAreReadTheWayTheRulesReadThem() {
        XCTAssertEqual(LocalTxParser.amounts(in: "kopi 25rb dan parkir 5rb"), [25_000, 5_000])
        XCTAssertEqual(LocalTxParser.amounts(in: "Bayar kos Rp 1.250.000"), [1_250_000])
        XCTAssertEqual(LocalTxParser.amounts(in: "bensin 1,5jt"), [1_500_000])
        XCTAssertEqual(LocalTxParser.amounts(in: "Coffee 25K"), [25_000])
        XCTAssertEqual(LocalTxParser.amounts(in: "beli 2 kopi 50k"), [2, 50_000])
        XCTAssertEqual(LocalTxParser.amounts(in: "tadi gratis 0 rupiah"), [], "nothing at zero")
        XCTAssertEqual(LocalTxParser.amounts(in: "makan siang"), [])
    }

    /// The rules and the check share one number reader now; the rules read
    /// what they read before.
    func testTheRulesStillReadEntriesTheSameWay() throws {
        let r = try XCTUnwrap(LocalTxParser.parse("beli kopi 25rb dan parkir 5rb"))
        XCTAssertEqual(r.items.map(\.name), ["Kopi", "Parkir"])
        XCTAssertEqual(r.items.map(\.amount), [25_000, 5_000])
        XCTAssertEqual(r.items.map(\.category), [.food, .transport])
        XCTAssertEqual(LocalTxParser.parse("bayar kos 1.250.000")?.items.first?.amount, 1_250_000)
        XCTAssertNil(LocalTxParser.parse("berapa pengeluaran saya bulan ini"))
    }

    // MARK: What the model's reading has to pass

    /// Two things bought and the total beside them: the model splits out the
    /// two, and the total, though written, is not an entry.
    func testAReadingOfNumbersActuallyWrittenIsKept() throws {
        let text = "isi bensin full 150rb sama cuci motor 20rb, total 170rb"
        let result = try XCTUnwrap(OnDeviceTxParser.vetted(
            [entry("Bensin", 150_000, .transport), entry("Cuci  motor", 20_000, .transport)], text: text))
        XCTAssertEqual(result.items.map(\.name), ["Bensin", "Cuci motor"])
        XCTAssertEqual(result.items.map(\.amount), [150_000, 20_000])
        XCTAssertEqual(result.items.map(\.category), [.transport, .transport])
    }

    func testANumberTheModelWorkedOutRatherThanReadDropsTheReading() {
        XCTAssertNil(OnDeviceTxParser.vetted([entry("Bensin dan cuci", 170_000)],
                                             text: "bensin 150rb dan cuci motor 20rb"),
                     "a total that was never written")
        // "150" said for Rp 150.000 is common, but the model may not decide
        // that: what is written is what goes on the card, where it is checked.
        XCTAssertNil(OnDeviceTxParser.vetted([entry("Bensin", 150_000)], text: "isi bensin full 150"),
                     "150 written, 150.000 guessed")
        XCTAssertNotNil(OnDeviceTxParser.vetted([entry("Bensin", 150)], text: "isi bensin full 150"))
    }

    func testOneWrittenAmountCannotBeRecordedTwice() {
        XCTAssertNil(OnDeviceTxParser.vetted([entry("Kopi", 25_000), entry("Kopi lagi", 25_000)],
                                             text: "kopi 25rb"))
        XCTAssertNotNil(OnDeviceTxParser.vetted([entry("Kopi", 25_000), entry("Kopi lagi", 25_000)],
                                                text: "kopi 25rb terus kopi lagi 25rb"))
    }

    func testOneBadEntryDropsTheLot() {
        let text = "kopi 25rb dan parkir 5rb"
        XCTAssertNil(OnDeviceTxParser.vetted([entry("Kopi", 25_000), entry("  ", 5_000)], text: text))
        XCTAssertNil(OnDeviceTxParser.vetted([entry("Kopi", 25_000), entry("5.000", 5_000)], text: text))
        XCTAssertNil(OnDeviceTxParser.vetted([], text: text))
        XCTAssertNil(OnDeviceTxParser.vetted(Array(repeating: entry("Kopi", 1), count: 7),
                                             text: String(repeating: "kopi 1 ", count: 7)))
    }

    func testTheDirectionWinsOverTheCategory() throws {
        let text = "refund baju 20rb dan gaji 10jt"
        let result = try XCTUnwrap(OnDeviceTxParser.vetted(
            [entry("Refund baju", 20_000, expense: false, .shopping),
             entry("Gaji", 10_000_000, expense: true, .salary)], text: text))
        XCTAssertEqual(result.items[0].category, .incomeOther, "money in, not shopping")
        XCTAssertEqual(result.items[1].category, .other, "money out, not salary")
        XCTAssertEqual(result.items.map(\.isExpense), [false, true])
    }

    func testEveryKindTheModelPicksIsADiPoCategoryOnTheRightSide() {
        let income: Set<OnDeviceTxKind> = [.salary, .freelance, .business, .bonus, .gift, .otherIncome]
        for kind in OnDeviceTxKind.allCases {
            XCTAssertEqual(OnDeviceTxParser.category(of: kind).isIncomeCategory, income.contains(kind), "\(kind)")
        }
        XCTAssertEqual(OnDeviceTxParser.category(of: .rentOrFamily), .commitment)
    }

    // MARK: Questions stay with the server

    func testAQuestionWithAnAmountIsNotAnEntry() {
        for q in ["kalau beli HP 3jt cukup nggak sampai gajian", "Berapa sisa uangku bulan ini",
                  "should I pay 2jt now", "Kopi 25rb mahal ya?", "cukup ga 500rb seminggu"] {
            XCTAssertTrue(OnDeviceTxParser.isQuestion(q), q)
        }
        for entry in ["isi bensin full 150rb sama cuci motor 20rb", "Gaji masuk 10jt",
                      "makan siang di warteg 18rb"] {
            XCTAssertFalse(OnDeviceTxParser.isQuestion(entry), entry)
        }
    }
}
