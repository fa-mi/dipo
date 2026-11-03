import XCTest

/// Help (tickets and their thread), Web Sync and the data check follow the
/// minimal rules: no border, wash, disc or tile; a new reply is an orange dot,
/// as Ask DiPo marks its notes; your messages are grey and the team's answers
/// plain text; steps done are ink. The dark discs over photos stay: they keep
/// a close mark legible on any picture. Reads the sources.
final class SupportMinimalTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private let screens = ["SupportView.swift", "WebSyncView.swift", "DataIntegrityCheck.swift"]

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
    }

    private func matches(_ pattern: String, in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap {
            Range($0.range, in: source).map { String(source[$0]) }
        }
    }

    func testNothingIsDrawnForShow() throws {
        var found: [String] = []
        for path in screens {
            let source = try text(path)
            found += try matches(#"\.overlay\(\s*(RoundedRectangle|Capsule|Circle)\([^)]*\)\s*\.(stroke|strokeBorder)\("#, in: source)
                .map { "\(path) border: \($0)" }
            found += try matches(#"\.opacity\([^)]*\)\s*,\s*in:\s*(Capsule|RoundedRectangle|Circle)"#, in: source)
                .map { "\(path) wash: \($0)" }
            found += try matches(#"Circle\(\)\.fill\((?!Color\.(black|white))[^\n]*\.opacity\("#, in: source)
                .map { "\(path) disc: \($0)" }
        }
        XCTAssertTrue(found.isEmpty, "Drawn for show:\n\(found.joined(separator: "\n"))")
    }

    /// A new reply is news, not money in.
    func testNewRepliesAreAnOrangeDot() throws {
        let source = try text("SupportView.swift")
        XCTAssertFalse(source.contains("Circle().fill(AppTheme.accent).frame(width: 6, height: 6)"))
        XCTAssertTrue(source.contains("Circle().fill(AppTheme.orange).frame(width: 6, height: 6)"))
    }

    /// Your messages grey, the team's answer plain text, as in Ask DiPo.
    func testTheThreadReadsLikeAskDiPo() throws {
        let source = try text("SupportView.swift")
        XCTAssertFalse(source.contains(".background(category.color, in:"))
        XCTAssertFalse(source.contains(".background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))"))
    }
}
