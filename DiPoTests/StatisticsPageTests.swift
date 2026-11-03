import XCTest
@testable import DiPo

/// Statistics opens on what went on living this period, as the one big
/// number, with how it compares with the last period in a sentence. Below the
/// hero the sections sit on the page: no card behind them, no icon discs.
@MainActor
final class StatisticsPageTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: "IDR") }

    func testComparisonInWords() {
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(StatsLines.comparison(-12.4), "12% lebih hemat dari periode lalu")
            XCTAssertEqual(StatsLines.comparison(60), "60% lebih banyak dari periode lalu")
        }
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(StatsLines.comparison(-30), "30% less than last period")
        }
        XCTAssertNil(StatsLines.comparison(nil), "nothing to compare with")
        XCTAssertNil(StatsLines.comparison(0.4), "within a percent says nothing")
    }

    func testTodayAgainstATypicalDay() {
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(StatsLines.days(today: 45_000, typical: 120_000, money: money),
                           "Hari ini \(money(45_000)) · hari biasa \(money(120_000))")
            XCTAssertEqual(StatsLines.days(today: 45_000, typical: 0, money: money), "Hari ini \(money(45_000))")
        }
        XCTAssertNil(StatsLines.days(today: 0, typical: 0, money: money))
    }

    func testNewStringsInBothLanguages() {
        let keys = ["stats.spent_label", "stats.vs_less", "stats.vs_more", "stats.day_line",
                    "stats.today_line", "stats.book_show", "stats.book_hide"]
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                for k in keys { XCTAssertNotEqual(loc(k), k, "\(k) in \(lang)") }
            }
        }
    }

    // MARK: Read from the sources

    private func body(of name: String, in path: String) throws -> String {
        let lines = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
        guard let start = lines.firstIndex(where: { $0.contains(name) }) else {
            XCTFail("\(name) not found"); return ""
        }
        var depth = 0, opened = false, out: [String] = []
        for line in lines[start...] {
            out.append(line)
            for ch in line {
                if ch == "{" { depth += 1; opened = true }
                if ch == "}" { depth -= 1 }
            }
            if opened && depth == 0 { break }
        }
        return out.joined(separator: "\n")
    }

    /// The hero's big number is what went on living; the balance comes after.
    func testTheBigNumberIsSpending() throws {
        let hero = try body(of: "var spendHero: some View", in: "DiPo/StatisticsView+MainPage.swift")
        XCTAssertTrue(hero.contains("Text(money(spent))"))
        XCTAssertTrue(hero.contains("size: 40"))
        XCTAssertTrue(hero.contains("FlowField"), "the hero keeps the web dashboard's field")
    }

    /// Below the hero: no card behind a section, no disc behind an icon, and
    /// the four-figure strip and the two mini cards are gone.
    func testSectionsSitOnThePage() throws {
        let path = "DiPo/StatisticsView+MainPage.swift"
        for name in ["var monthBars: some View", "var categoriesCard: some View", "var notesCard: some View",
                     "var detailLink: some View", "func categoryRow(", "var nonFlowSection: some View",
                     "var header: some View"] {
            let src = try body(of: name, in: path)
            XCTAssertFalse(src.contains("AppTheme.cardDark, in:"), "\(name) sits on a card")
            XCTAssertFalse(src.contains("in: Circle())"), "\(name) puts a disc behind an icon")
        }
        let page = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        XCTAssertFalse(page.contains("var metricStrip"))
        XCTAssertFalse(page.contains("func miniStatCard("))
    }

    /// The hero's sentences carry their icon's colour and nothing behind them.
    func testHeroSentencesHaveNoPanels() throws {
        let path = "DiPo/StatisticsView+MainPage.swift"
        for name in ["func livingBox(", "func debtBox(", "func sentence(", "func balanceLines("] {
            XCTAssertFalse(try body(of: name, in: path).contains("heroPanel"), name)
        }
        XCTAssertFalse(try body(of: "var spendHero: some View", in: path).contains("in: Capsule()"),
                       "no tinted pill on the hero")
    }
}
