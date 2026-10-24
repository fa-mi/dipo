import XCTest
import SwiftUI
@testable import DiPo

/// When the tabs' pages split into two columns. The widths are what a page
/// gets: the panel, less the tab rail (12 pt margin + 76 pt) on a wide one.
@MainActor
final class DuoLayoutTests: XCTestCase {

    private let rail: CGFloat = 12 + 76

    func testEveryIPhoneHeldUprightKeepsOneColumn() {
        for width: CGFloat in [320, 375, 393, 402, 440] {
            XCTAssertFalse(AppLayout.fitsTwoColumns(width), "\(width) pt")
        }
    }

    func testTheDuoFoldedOrOpenedUprightKeepsOneColumn() {
        XCTAssertFalse(AppLayout.fitsTwoColumns(466), "folded: the outer display")
        XCTAssertFalse(AppLayout.fitsTwoColumns(626 - rail), "opened upright, beside the rail")
    }

    func testTheDuoOpenedAndTurnedHasTwo() {
        XCTAssertTrue(AppLayout.fitsTwoColumns(890 - rail))
    }

    func testTwoColumnsStartWhereTwoPhoneColumnsFit() {
        let needed = 2 * AppLayout.columnMinWidth + AppLayout.columnGap + 2 * AppLayout.pageMargin
        XCTAssertTrue(AppLayout.fitsTwoColumns(needed))
        XCTAssertFalse(AppLayout.fitsTwoColumns(needed - 1))
    }

    func testAPageHasOneColumnUnlessToldOtherwise() {
        XCTAssertEqual(EnvironmentValues().pageColumns, 1)
    }
}
