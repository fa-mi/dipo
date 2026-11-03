import XCTest

/// Sign-in, choosing the main card, salary, monthly bills and their
/// duplicates, money owed to you, cards and moving money between them follow
/// the minimal rules: no tinted wash, pill or tile, no disc behind an icon,
/// no outline but the one ring round a chosen card colour and the Google
/// button's own. Card faces keep their colours and shadow. Reads the sources.
final class MoneyScreensMinimalTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private let screens = ["AuthViews.swift", "MainCardGate.swift", "SalaryView.swift",
                           "RecurringExpense.swift", "DiPo/RecurringDuplicates.swift",
                           "Receivables.swift", "DiPo/ReceivableConvertSheet.swift",
                           "CardManagementView.swift", "CardPicker.swift"]

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
    }

    private func matches(_ pattern: String, in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range, in: source).map { String(source[$0]) }
        }
    }

    func testNothingIsDrawnForShow() throws {
        var found: [String] = []
        for path in screens {
            let source = try text(path)
            found += try matches(#"\.opacity\([^)]*\)\s*,\s*in:\s*(Capsule|RoundedRectangle|Circle)"#, in: source)
                .map { "\(path) wash: \($0)" }
            found += try matches(#"Circle\(\)\.fill\(AppTheme\.\w+\.opacity\("#, in: source)
                .map { "\(path) disc: \($0)" }
            found += try matches(#"\.overlay\(\s*(RoundedRectangle|Capsule|Circle)\([^)]*\)\s*\.stroke\([^\n]*"#, in: source)
                .filter { !$0.contains("selected ? AppTheme.textPrimary") && !$0.contains("AppTheme.cardMid, lineWidth: 1.5") }
                .map { "\(path) border: \($0)" }
        }
        XCTAssertTrue(found.isEmpty, "Drawn for show:\n\(found.joined(separator: "\n"))")
    }

    /// The Face ID screen is a plain button on the page: no green glow
    /// behind it, no pulsing rings round it.
    func testTheLockScreenHasNoGlow() throws {
        let source = try text("AuthViews.swift")
        XCTAssertFalse(source.contains("RadialGradient("))
        XCTAssertFalse(source.contains("repeatForever"))
    }

    /// A bill due today is money going out: orange, not green.
    func testABillDueIsNotGreen() throws {
        let source = try text("RecurringExpense.swift")
        XCTAssertFalse(source.contains("days <= 0 ? AppTheme.accent"))
    }
}
