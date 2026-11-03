import XCTest

/// Rekening Bersama's screens follow the minimal rules: no tile behind an
/// icon, no tinted wash, pill or outline, the choice on the raised fill. The
/// account's own card keeps its gradient, soft disc and shadow, as the wallet
/// cards do, and the avatars keep the ring that parts them; the card chosen
/// to pay from keeps one ink ring. Reads the sources.
final class JointMinimalTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
    }

    /// The file without the structs that draw a card face or avatars.
    private func screens(_ path: String, dropping names: [String]) throws -> String {
        var lines = try text(path).components(separatedBy: "\n")
        for name in names {
            guard let start = lines.firstIndex(where: { $0.hasPrefix("struct \(name):") }) else {
                XCTFail("struct \(name) not found in \(path)"); continue
            }
            var depth = 0, opened = false, end = start
            for i in start..<lines.count {
                for ch in lines[i] { if ch == "{" { depth += 1; opened = true }; if ch == "}" { depth -= 1 } }
                if opened && depth == 0 { end = i; break }
            }
            lines.removeSubrange(start...end)
        }
        return lines.joined(separator: "\n")
    }

    private func count(_ pattern: String, in source: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
    }

    func testNothingIsDrawnForShow() throws {
        let sources = [
            ("JointAccountViews", try screens("DiPo/JointAccountViews.swift", dropping: ["JointAccountCard", "JointAvatars"])),
            ("JointAccountDetail", try text("DiPo/JointAccountDetail.swift")),
            ("JointSmartBudgetViews", try text("DiPo/JointSmartBudgetViews.swift")),
            ("JointAccountSettings", try text("DiPo/JointAccountSettings.swift")),
        ]
        for (name, source) in sources {
            XCTAssertEqual(try count(#"\.opacity\([^)]*\)\s*,\s*in:\s*(Capsule|RoundedRectangle|Circle)"#, in: source), 0, "\(name) wash")
            XCTAssertEqual(try count(#"\.overlay\(\s*(RoundedRectangle|Capsule|Circle)\([^)]*\)\s*\.(stroke|strokeBorder)\((?!on \? AppTheme\.textPrimary)"#, in: source), 0, "\(name) border")
            XCTAssertFalse(source.contains("dash:"), "\(name) dashed outline")
        }
    }

    /// Making the account is the screen's one action: green when it can be
    /// done, the plain control fill when it can't — not a faded green.
    func testThePrimaryButtonIsGreenOrPlain() throws {
        let source = try text("DiPo/JointAccountViews.swift")
        XCTAssertTrue(source.contains(".background(enabled ? AppTheme.accentFill : AppTheme.cardMid,"))
    }
}
