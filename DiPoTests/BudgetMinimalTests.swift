import XCTest

/// Smart Budget and the screens it opens (a group's detail, "Did this on
/// purpose?", Ask DiPo for a plan) follow the minimal rules: no border round a
/// card, no tile or disc behind an icon, no tinted pill or wash behind words,
/// no gradient or shadow for show. Green is the one primary action and money
/// coming in; red is trouble and deleting. Reads the sources, like
/// SheetsMinimalTests, and names anything that slips back.
final class BudgetMinimalTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private let screens = ["SmartBudgetSettingsView.swift", "CycleIntentView.swift",
                           "SmartRecommendationView.swift", "SmartRecommendationDetailView.swift"]

    /// A file's source with comments stripped.
    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
    }

    private func matches(_ pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad pattern \(pattern)")
            return []
        }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range, in: source).map {
                source[$0].split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " ")
            }
        }
    }

    /// A shape stroked over a view: a border.
    private let border = #"\.overlay\(\s*(RoundedRectangle|Capsule|Circle)\([^)]*\)\s*\.(stroke|strokeBorder)\("#
    /// A disc or tile filled with a faint colour and sized for an icon.
    private let tile = #"(Circle\(\)|RoundedRectangle\([^)]*\))\s*\.fill\([^\n]*\.opacity\([^\n]*\.frame\(width:\s*[2-9]\d,\s*height:\s*[2-9]\d\)"#
    /// A faint colour behind words or a card.
    private let wash = #"\.opacity\([^)]*\)\s*,\s*in:\s*(Capsule|RoundedRectangle)"#

    func testNothingIsDrawnForShow() throws {
        var found: [String] = []
        for path in screens {
            let source = try text(path)
            for (kind, pattern) in [("border", border), ("tile", tile), ("wash", wash)] {
                found += matches(pattern, in: source).map { "\(path) \(kind): \($0)" }
            }
            found += matches(#"\.shadow\("#, in: source).map { "\(path) shadow: \($0)" }
        }
        XCTAssertTrue(found.isEmpty, "Drawn for show:\n\(found.joined(separator: "\n"))")
    }

    /// The only gradient left is the budget card's own colours, which say
    /// which card the budget counts. Bars are flat.
    func testOnlyTheCardKeepsItsGradient() throws {
        for path in screens {
            let gradients = try text(path).components(separatedBy: "\n")
                .filter { $0.contains("LinearGradient(") || $0.contains("AngularGradient(") || $0.contains("RadialGradient(") }
            let others = gradients.filter { !$0.contains("gradientStart") }
            XCTAssertTrue(others.isEmpty, "\(path): \(others)")
        }
    }

    /// One filled green button on the budget screen: "Go to settings" when
    /// no card is chosen. Save is green in the bar; the notes' fixes are ink.
    func testOneGreenButtonOnTheBudget() throws {
        let source = try text("SmartBudgetSettingsView.swift")
        XCTAssertEqual(source.components(separatedBy: "AppTheme.accentFill").count - 1, 1)
        XCTAssertTrue(source.contains("canSave ? AppTheme.accent"))
        XCTAssertTrue(source.contains("struct BudgetNote: View"))
    }

    /// Left to spend is the budget's, not money in: ink, as on Plan. Being
    /// over says so in red (blue when planned), never with an outline.
    func testWhatIsLeftIsInk() throws {
        let source = try text("SmartBudgetSettingsView.swift")
        XCTAssertTrue(source.contains("fmt(remaining)).font(.system(.subheadline, weight: .bold)).foregroundStyle(isOver ? overTint : AppTheme.textPrimary)"))
        XCTAssertFalse(source.contains("AppTheme.red.opacity"))
    }

    /// The plan's tabs mark the choice in ink on one track, like Statistics'
    /// switch; they were green.
    func testThePlanTabsAreInk() throws {
        let source = try text("SmartRecommendationDetailView.swift")
        XCTAssertTrue(source.contains(".background(on ? AppTheme.textPrimary : Color.clear, in: Capsule())"))
        XCTAssertTrue(source.contains(".foregroundStyle(on ? AppTheme.cardDark : AppTheme.textSecondary)"))
        XCTAssertFalse(source.contains("AppTheme.accentFill"))
    }

    /// Choosing a reason keeps one green action per open card, and turning
    /// one off is a red word on the plain control fill.
    func testTheOnPurposeCardsHaveOneGreenAction() throws {
        let source = try text("CycleIntentView.swift")
        XCTAssertEqual(source.components(separatedBy: "AppTheme.accentFill").count - 1, 1)
        XCTAssertTrue(source.contains(".background(on ? AppTheme.cardMid : AppTheme.accentFill, in: Capsule())"))
    }
}
