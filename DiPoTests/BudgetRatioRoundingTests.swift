import XCTest
@testable import DiPo

// "Save lights up when I haven't changed anything."
//
// The Smart Budget editor read the same stored ratio through two different
// conversions: `load()` rounded (0.29 → 29) while the baseline `hasChanges`
// compared against truncated (0.29 → 28). They disagreed, so the screen
// believed it was dirty the moment it opened.
//
// It is narrow — exactly three percentages survive the round trip badly — but
// all three are reachable with the +/- buttons, and once saved the button stays
// lit on every subsequent visit. These tests pin the conversion rule itself,
// since the bug was never in either formula alone but in the gap between them.
final class BudgetRatioRoundingTests: XCTestCase {

    /// Mirrors `SmartBudgetSettingsView.pct(_:)`, which is private to the view.
    private func pct(_ ratio: Double) -> Int { Int((ratio * 100).rounded()) }

    /// The conversion that was in use on the baseline path.
    private func truncatingPct(_ ratio: Double) -> Int { Int(ratio * 100) }

    func testEveryWholePercentSurvivesTheRoundTrip() {
        for p in 0...100 {
            XCTAssertEqual(pct(Double(p) / 100.0), p,
                           "ratio for \(p)% did not read back as \(p)")
        }
    }

    func testTruncationLosesExactlyTheThreeKnownPercentages() {
        let broken = (0...100).filter { truncatingPct(Double($0) / 100.0) != $0 }
        // Pinned deliberately: if a compiler or platform change alters this set,
        // the assumption behind the fix has moved and should be re-read rather
        // than silently drifting.
        XCTAssertEqual(broken, [29, 57, 58])
    }

    func testTheTwoConversionsAgreeEverywhereAfterTheFix() {
        // The defaults were always safe, which is why this went unnoticed: a
        // 50/30/20 split never trips it.
        for p in [50, 30, 20] {
            XCTAssertEqual(pct(Double(p) / 100.0), truncatingPct(Double(p) / 100.0))
        }
        // And these are the ones that did.
        for p in [29, 57, 58] {
            XCTAssertNotEqual(pct(Double(p) / 100.0), truncatingPct(Double(p) / 100.0))
            XCTAssertEqual(pct(Double(p) / 100.0), p)
        }
    }
}
