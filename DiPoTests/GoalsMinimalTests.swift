import XCTest

/// Savings goals, held wants, shared goals and a joint account's goals follow
/// the minimal rules: an emoji or icon with nothing behind it, no border or
/// tinted wash, the choice on the raised fill, bars in ink. Green is a
/// screen's one action and money coming in. Reads the sources, like
/// SheetsMinimalTests, and names anything that slips back.
final class GoalsMinimalTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private let screens = ["WishlistView.swift", "DiPo/HoldViews.swift", "UnitySavings.swift",
                           "DiPo/JointGoals.swift", "DiPo/GoalInvestments.swift"]

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
    /// A faint colour behind words, an emoji or an icon.
    private let wash = #"\.opacity\([^)]*\)\s*,\s*in:\s*(Capsule|RoundedRectangle|Circle)"#
    /// A disc or tile filled with a faint colour and sized for an icon.
    private let tile = #"(Circle\(\)|RoundedRectangle\([^)]*\))\s*\.fill\([^\n]*\.opacity\([^\n]*\.frame\(width:\s*[2-9]\d,\s*height:\s*[2-9]\d\)"#

    func testNothingIsDrawnForShow() throws {
        var found: [String] = []
        for path in screens {
            let source = try text(path)
            for (kind, pattern) in [("border", border), ("wash", wash), ("tile", tile)] {
                found += matches(pattern, in: source).map { "\(path) \(kind): \($0)" }
            }
            if source.contains("LinearGradient(") { found.append("\(path) gradient") }
        }
        XCTAssertTrue(found.isEmpty, "Drawn for show:\n\(found.joined(separator: "\n"))")
    }

    /// How far a goal has come is drawn in ink, as on Plan and Debts.
    func testGoalBarsAndRingAreInk() throws {
        let source = try text("WishlistView.swift")
        XCTAssertTrue(source.contains("Capsule().fill(AppTheme.textPrimary)"))
        XCTAssertTrue(source.contains(".stroke(AppTheme.textPrimary, style: StrokeStyle(lineWidth: 10, lineCap: .round))"))
        XCTAssertFalse(source.contains("Capsule().fill(AppTheme.accentFill)"))
    }

    /// With several goals, a green Add on every card made a column of them.
    /// The list's Add sits on the control fill; the goal's own screen keeps
    /// its Add green.
    func testOneGreenAddPerScreen() throws {
        let source = try text("WishlistView.swift")
        XCTAssertFalse(source.contains(".background(AppTheme.accentFill, in: Circle())"),
                       "the + for a new goal is ink, as on Debts")
        XCTAssertTrue(source.contains(".background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.md))"))
    }

    /// A shared goal's actions are the app's green, not a second action colour.
    func testSharedGoalActionsAreGreen() throws {
        let source = try text("UnitySavings.swift")
        XCTAssertFalse(source.contains(".background(AppTheme.purple, in:"))
        XCTAssertFalse(source.contains("canSave ? AppTheme.purple :"))
        XCTAssertFalse(source.contains("canSend ? AppTheme.purple :"))
    }

    /// Choosing how long to wait marks the choice in ink, not green.
    func testTheWaitChoiceIsInk() throws {
        let source = try text("DiPo/HoldViews.swift")
        XCTAssertTrue(source.contains(".background(on ? AppTheme.textPrimary : AppTheme.cardDark,"))
    }
}
