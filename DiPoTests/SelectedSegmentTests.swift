import XCTest

/// A two-way switch marks its choice in ink. Statistics' Income / Expenses and
/// the debts' payoff order marked it with the page's ground on a grey track,
/// two greys a few steps apart, and in the light theme the chosen side could
/// not be told from the other. Reads the sources and names a switch that
/// slips back.
final class SelectedSegmentTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTheChoiceIsInkNotTheGround() throws {
        for path in ["DiPo/StatisticsView+MainPage.swift", "DiPo/DebtCards.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains(".background(on ? AppTheme.bg : Color.clear, in: Capsule())"), path)
            XCTAssertTrue(source.contains(".background(on ? AppTheme.textPrimary : Color.clear, in: Capsule())"), path)
            XCTAssertTrue(source.contains(".foregroundStyle(on ? AppTheme.cardDark : AppTheme.textSecondary)"), path)
        }
    }
}
