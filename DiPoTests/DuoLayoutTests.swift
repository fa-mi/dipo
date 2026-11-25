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

    // MARK: Short pages
    //
    // The height a page gets: the panel under the status bar, with the
    // bottom edge included (MainTabView ignores the bottom safe area).

    /// The Duo folded and an iPhone SE are short, and so is any iPhone on its
    /// side: Home's period card moves up under the cards there.
    func testTheDuoFoldedAndAnSEAreShort() {
        XCTAssertTrue(AppLayout.isShortPage(678 - 47), "the Duo folded")
        XCTAssertTrue(AppLayout.isShortPage(667 - 20), "iPhone SE")
        XCTAssertTrue(AppLayout.isShortPage(393), "an iPhone on its side")
    }

    /// Every other iPhone held upright keeps Home's order, and so does a page
    /// that hasn't been measured yet.
    func testOtherIPhonesAreNotShort() {
        for height: CGFloat in [812 - 50, 852 - 62, 874 - 62, 956 - 62] {
            XCTAssertFalse(AppLayout.isShortPage(height), "\(height) pt")
        }
        XCTAssertFalse(AppLayout.isShortPage(0))
        XCTAssertFalse(EnvironmentValues().pageIsShort)
    }

    /// On a short page the period card comes straight after the cards, and
    /// only once.
    func testHomePutsThePeriodCardUnderTheCardsOnAShortPage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let home = try String(contentsOf: root.appendingPathComponent("HomeView.swift"), encoding: .utf8)
        let lines = home.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let cards = try XCTUnwrap(lines.firstIndex(of: "if hasCards { moneyTop }"))
        XCTAssertEqual(lines[cards + 1], "if hasCards && pageIsShort { flowCard }")
        XCTAssertTrue(home.contains("if !pageIsShort { flowCard }"))
        let tabs = try String(contentsOf: root.appendingPathComponent("MainTabView.swift"), encoding: .utf8)
        XCTAssertTrue(tabs.contains(".environment(\\.pageIsShort, AppLayout.isShortPage(pageHeight))"))
    }
}
