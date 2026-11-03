import XCTest

/// The remaining screens follow the minimal rules: search, notices and a
/// notice's page, the money briefing, the guides, notification settings,
/// tidying categories, cleaning data, DiPo's interests and the first-run
/// steps on Home. Shared pieces (the form fields, the action list, the inline
/// banner, the toast) lose their focus rings, tiles, washes and outlines.
/// Kept: the tab bar, the category picker, card faces, and the shadows that
/// lift floating pieces off the page. Reads the sources.
final class RestMinimalTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private let screens = ["DiPo/SearchView.swift", "NotificationManager.swift", "FinancialBriefing.swift",
                           "DiPo/GuidePieces.swift", "NotificationSettingsView.swift", "TidyCategoriesView.swift",
                           "DiPo/DataCleanupView.swift", "DiPo/DiPoInterests.swift", "DiPo/HomeBanners.swift",
                           "ActionFeedback.swift"]

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
            XCTAssertEqual(try count(#"\.opacity\([^)]*\)\s*,\s*in:\s*(Capsule|RoundedRectangle|Circle)"#, in: source), 0, "\(path) wash")
            XCTAssertEqual(try count(#"\.overlay\(\s*(RoundedRectangle|Capsule|Circle)\([^)]*\)\s*\.stroke\("#, in: source), 0, "\(path) border")
            XCTAssertEqual(try count(#"(Circle\(\)|RoundedRectangle\([^)]*\))\s*\.fill\([^\n]*\.opacity\("#, in: source), 0, "\(path) tile")
            XCTAssertEqual(try count(#"(LinearGradient|RadialGradient)\("#, in: source), 0, "\(path) gradient")
        }
    }

    /// The shared form pieces: no green focus ring, no tile behind an action's
    /// icon, no wash or outline round an inline note.
    func testTheSharedPiecesArePlain() throws {
        let source = try text("AppShared.swift")
        XCTAssertFalse(source.contains("focused ? AppTheme.accent.opacity(0.6)"))
        XCTAssertFalse(source.contains("item.tint.opacity(0.14)"))
        XCTAssertFalse(source.contains("tone.color.opacity(0.1)"))
    }

    /// The first-run hint floats over the page with its shadow, no outline.
    func testTheAddCardHintHasNoOutline() throws {
        XCTAssertFalse(try text("MainTabView.swift").contains(".stroke(AppTheme.accent.opacity(0.3), lineWidth: 1)"))
    }

    /// DiPo's interests are chosen in ink, like the app's other switches.
    func testInterestsAreChosenInInk() throws {
        XCTAssertTrue(try text("DiPo/DiPoInterests.swift").contains(".background(on ? AppTheme.textPrimary : AppTheme.cardDark, in: Capsule())"))
    }
}
