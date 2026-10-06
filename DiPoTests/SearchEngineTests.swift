import XCTest
@testable import DiPo

/// Search runs once per question and hands back only the rows it shows.
@MainActor
final class SearchEngineTests: XCTestCase {

    private func tx(_ name: String, _ amount: Double, daysAgo: Double, _ cat: TxCategory = .food) -> TxRecord {
        TxRecord(name: name, date: Date().addingTimeInterval(-daysAgo * 86_400), amount: amount,
                 type: "tx.type.purchase", icon: "circle", iconBgHex: cat.iconBg, category: cat, currency: "IDR")
    }
    private let raw = { (t: TxRecord) in t.amount }

    func testNewestFirstGroupedByDayAndLimited() {
        let all = (0..<10).map { tx("Makan \($0)", -10_000, daysAgo: Double($0) / 2) }   // two a day
        let r = SearchEngine.run(all, query: "", range: nil, category: nil, sort: .newest, limit: 5, convert: raw)
        XCTAssertEqual(r.count, 10)
        XCTAssertEqual(r.hidden, 5)
        XCTAssertEqual(r.groups.flatMap(\.txs).map(\.name), ["Makan 0", "Makan 1", "Makan 2", "Makan 3", "Makan 4"])
        XCTAssertTrue(zip(r.groups, r.groups.dropFirst()).allSatisfy { $0.day > $1.day })
        XCTAssertEqual(r.total, -100_000, accuracy: 0.01)       // the total covers every match
    }

    func testQueryCategoryAndAmountOrder() {
        let all = [tx("Gaji", 4_000_000, daysAgo: 1, .salary), tx("Bensin", -50_000, daysAgo: 2, .transport),
                   tx("Makan", -20_000, daysAgo: 3), tx("Makan malam", -80_000, daysAgo: 4)]
        let q = SearchEngine.run(all, query: "makan", range: nil, category: nil, sort: .largest, limit: 10, convert: raw)
        XCTAssertEqual(q.groups.flatMap(\.txs).map(\.name), ["Makan malam", "Makan"])
        XCTAssertEqual(q.groups.count, 1, "by amount: one flat list")
        let c = SearchEngine.run(all, query: "", range: nil, category: .transport, sort: .newest, limit: 10, convert: raw)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(Set(c.categories), [.salary, .transport, .food], "pills list the whole period")
    }

    func testShowMoreStringInBothLanguages() {
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                XCTAssertNotEqual(loc("search.show_more"), "search.show_more")
            }
        }
    }
}
