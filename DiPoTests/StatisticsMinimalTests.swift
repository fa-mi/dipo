import XCTest

/// Statistics below its hero follows the minimal rules: no tinted pill
/// behind a word that already has its colour, no wash of colour across a
/// card, and no tile behind a note's icon. The hero is left alone: its field
/// is the web dashboard's too (DiPo/FlowField.swift). Reads the sources, like
/// HomeMinimalTests, and names anything that slips back.
final class StatisticsMinimalTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func lines(_ path: String) throws -> [String] {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
    }

    /// The detail screens and the cards: no pill, no gradient wash.
    func testNoTintedPillsOrWashes() throws {
        var found: [String] = []
        for path in ["DiPo/StatisticsView+Details.swift", "DiPo/StatisticsCards.swift"] {
            for (i, line) in try lines(path).enumerated() {
                let pill = line.contains(".opacity(") && line.contains("in: Capsule()")
                let wash = line.contains("LinearGradient")
                if pill || wash { found.append("\(path):\(i + 1)") }
            }
        }
        XCTAssertTrue(found.isEmpty, "Statistics draws words in their colour, with nothing behind: \(found)")
    }

    /// A note's icon has nothing behind it, and the Royal way in is words in
    /// Royal's colour, not a tinted slab.
    func testNotesCarryNoTiles() throws {
        let page = try lines("DiPo/StatisticsView+MainPage.swift")
        for name in ["func noteRow(", "func lockedNotes("] {
            guard let start = page.firstIndex(where: { $0.contains(name) }) else {
                XCTFail("\(name) not found"); continue
            }
            var depth = 0, opened = false, body: [String] = []
            for line in page[start...] {
                body.append(line)
                for ch in line {
                    if ch == "{" { depth += 1; opened = true }
                    if ch == "}" { depth -= 1 }
                }
                if opened && depth == 0 { break }
            }
            let washed = body.filter { $0.contains(".background(") && $0.contains(".opacity(") }
            XCTAssertTrue(washed.isEmpty, "\(name) \(washed)")
        }
    }
}
