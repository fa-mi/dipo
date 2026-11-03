import XCTest

/// The paywall and the locked-feature card follow the minimal rules: no
/// rings, discs, washes or outlines; the subscribe button is the screen's one
/// action, flat green; Royal keeps its purple on its crown and name. The
/// billed amount stays the most conspicuous price (Guideline 3.1.2c) and the
/// privacy and terms links stay. Reads the source, like SheetsMinimalTests.
final class PaywallMinimalTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func text() throws -> String {
        try String(contentsOf: root.appendingPathComponent("PremiumManager.swift"), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
    }

    private func count(_ pattern: String, in source: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
    }

    func testNothingIsDrawnForShow() throws {
        let source = try text()
        XCTAssertEqual(try count(#"\.overlay\(\s*(RoundedRectangle|Capsule|Circle)\([^)]*\)\s*\.stroke\("#, in: source), 0, "border")
        XCTAssertEqual(try count(#"\.opacity\([^)]*\)\s*,\s*in:\s*(Capsule|RoundedRectangle|Circle)"#, in: source), 0, "wash")
        XCTAssertEqual(try count(#"Circle\(\)\s*\.fill\([^\n]*\.opacity\("#, in: source), 0, "disc")
        XCTAssertFalse(source.contains("LinearGradient("), "gradient")
    }

    /// Subscribe and Unlock are flat green with dark ink on them.
    func testTheActionsAreGreen() throws {
        let source = try text()
        XCTAssertEqual(source.components(separatedBy: ".background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))").count - 1, 2)
    }

    /// What Apple asks of a subscription screen is still there. Read whole:
    /// stripping comments at "//" would cut the links' "https://".
    func testTheBilledAmountAndLinksStay() throws {
        let source = try String(contentsOf: root.appendingPathComponent("PremiumManager.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Text(mgr.royalDisplayPrice)"))
        XCTAssertTrue(source.contains("premium.cta_subscribe"))
        XCTAssertTrue(source.contains("Text(billingDisclosure)"))
        XCTAssertTrue(source.contains("https://dipo.info/privacy"))
        XCTAssertTrue(source.contains("https://dipo.info/terms"))
        XCTAssertTrue(source.contains("mgr.restorePurchases()"))
    }
}
