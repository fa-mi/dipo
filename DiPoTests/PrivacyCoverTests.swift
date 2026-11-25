import XCTest
import UIKit
@testable import DiPo

/// The app switcher shows a picture of the app as it was when it left the
/// foreground. DiPo covers it with its icon whenever it isn't active, for
/// every user: before, only users with the app lock on were covered, and
/// everyone else's balances and transactions were in that picture.
final class PrivacyCoverTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Covered whenever the scene isn't active, lock on or off.
    func testEveryoneIsCovered() throws {
        let root = try source("RootView.swift")
        XCTAssertTrue(root.contains("} else if scenePhase != .active {"))
        XCTAssertFalse(root.contains("scenePhase != .active && authVM.isBiometricActive"),
                       "the cover is back to lock users only")
        XCTAssertTrue(root.contains("PrivacyCover()"))
    }

    /// The icon ships, and at least as large as it is drawn, so it is sharp.
    func testTheIconIsSharp() throws {
        let icon = try XCTUnwrap(UIImage(named: "DiPoCoverIcon"), "DiPoCoverIcon is not in the app's assets")
        XCTAssertGreaterThanOrEqual(icon.size.width, PrivacyCover.iconSize)
        XCTAssertEqual(icon.size.width, icon.size.height)
    }

    /// Opaque and drawn at once: no blur or material that could leave a
    /// figure readable or be missing from the snapshot, and no animation
    /// that could still be on its way in when the picture is taken.
    func testTheCoverIsOpaqueAndImmediate() throws {
        let cover = try source("DiPo/PrivacyCover.swift")
        let code = cover.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("AppTheme.bg.ignoresSafeArea()"))
        XCTAssertTrue(code.contains(".transaction { $0.animation = nil }"))
        for soft in [".blur(", "Material", ".opacity("] {
            XCTAssertFalse(code.contains(soft), "\(soft) in the cover")
        }
    }
}
