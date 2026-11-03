import XCTest

/// Investments and assets follow the minimal rules: icons without tiles,
/// cards without the profit-or-loss glow and outline, warnings without
/// washes, the chosen kind or card on the raised fill rather than a ring.
/// The mini card faces keep their bank's colours: they are the card. Reads
/// the sources, like SheetsMinimalTests.
final class InvestMinimalTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private let screens = ["DiPo/InvestmentForms.swift", "DiPo/InvestmentDetail.swift",
                           "DiPo/InvestmentView.swift", "DiPo/AssetsView.swift"]

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
    }

    private func count(_ pattern: String, in source: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
    }

    func testNothingIsDrawnForShow() throws {
        for path in screens {
            let source = try text(path)
            XCTAssertEqual(try count(#"\.overlay\(\s*(RoundedRectangle|Capsule|Circle)\([^)]*\)\s*\.stroke\("#, in: source), 0, "\(path) border")
            XCTAssertEqual(try count(#"\.opacity\([^)]*\)\s*,\s*in:\s*(Capsule|RoundedRectangle|Circle)"#, in: source), 0, "\(path) wash")
            XCTAssertEqual(try count(#"Circle\(\)\.(fill|stroke)\(AppTheme\.\w+\.opacity\("#, in: source), 0, "\(path) disc")
            XCTAssertFalse(source.contains(".shadow("), "\(path) shadow")
            for line in source.components(separatedBy: "\n") where line.contains("LinearGradient(") {
                XCTAssertTrue(line.contains("g.start") || line.contains("gradientStart"), "\(path): \(line)")
            }
        }
    }

    /// Up or down is said by the coloured figures, not a glow across the card.
    func testThePortfolioCardIsPlain() throws {
        XCTAssertFalse(try text("DiPo/InvestmentView.swift").contains("tint.opacity(0.22)"))
        XCTAssertFalse(try text("DiPo/InvestmentDetail.swift").contains("tint.opacity(0.22)"))
    }
}
