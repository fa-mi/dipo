import XCTest
import SwiftUI
import UIKit
@testable import DiPo

/// The pockets as they land on screen, not as their arithmetic says they
/// should. Fahmi's Wallet showed a three-card pocket under two cards' worth of
/// empty space while the other pocket held five; this renders the pager the
/// way the Wallet page does, in a vertical scroll view with something under
/// it, and reads where that something lands.
@MainActor
final class WalletPocketLayoutTests: XCTestCase {

    private final class Marks {
        var top: CGFloat = .nan
        var bottom: CGFloat = .nan
    }

    private func card(_ issuer: String) -> BankCard {
        let c = BankCard(holderName: "Fahmi", cardNumber: "5221845086220969", balance: 100_000,
                         expireDate: "11/29", gradientStart: "#00A0E3", gradientEnd: "#005AA5",
                         sortOrder: 0, currency: "IDR")
        c.issuerID = issuer
        return c
    }

    /// How tall the pockets stand on the page, from the line above them to the
    /// line under them, with `conventional` cards in the pocket in front and
    /// `digital` in the one beside it.
    private func pagerHeight(conventional: Int, digital: Int) throws -> CGFloat {
        let cards = (0..<conventional).map { _ in card("bri") } + (0..<digital).map { _ in card("jago") }
        let marks = Marks()
        let page = ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 1)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { marks.top = $0 }
                WalletPockets(cards: cards) { _ in }
                Color.clear.frame(height: 1)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { marks.bottom = $0 }
            }
            .containerRelativeFrame(.horizontal)
        }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1400)
        let host = UIHostingController(rootView: page)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }

        // The pager measures its pockets after the first pass and sets its
        // height on the next, so let a few passes run.
        for _ in 0..<12 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(marks.top.isNaN || marks.bottom.isNaN, "the page was never laid out")
        return marks.bottom - marks.top
    }

    /// A pocket of five beside it takes no room: the page under a three-card
    /// pocket sits where it would if both held three.
    func testThePocketOutOfViewTakesNoRoom() throws {
        let threeBesideFive = try pagerHeight(conventional: 3, digital: 5)
        let threeBesideThree = try pagerHeight(conventional: 3, digital: 3)
        XCTAssertEqual(threeBesideFive, threeBesideThree, accuracy: 1,
                       "a three-card pocket stands as tall as the five-card one beside it")
    }

    /// Two more cards in front, two more strips: 64 points each at the
    /// default text size.
    func testThePagerGrowsWithThePocketInFront() throws {
        let five = try pagerHeight(conventional: 5, digital: 3)
        let three = try pagerHeight(conventional: 3, digital: 5)
        XCTAssertEqual(five - three, 128, accuracy: 2)
    }
}
