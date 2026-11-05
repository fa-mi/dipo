import XCTest
import UIKit
@testable import DiPo

/// The shared spending report carries DiPo's mascot as its signature, so a
/// picture passed around on its own still says which app made it. Fahmi:
/// the mascot was there but couldn't be seen.
@MainActor
final class ShareSignatureTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The cropped mark ships, and is mostly character: the full mascot image
    /// is two-thirds empty margin, which is why it shrank to a smudge.
    func testTheMarkShipsCropped() throws {
        let mark = try XCTUnwrap(UIImage(named: "DiPoMark"), "DiPoMark is in the asset catalog")
        let full = try XCTUnwrap(UIImage(named: "DiPoMascot"))
        XCTAssertLessThan(mark.size.width * mark.size.height, full.size.width * full.size.height / 3)
    }

    /// Header and footer both show it, unblended.
    func testTheReportShowsTheMarkPlainly() throws {
        let source = try String(contentsOf: root.appendingPathComponent("DiPo/StatsExport.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "Image(\"DiPoMark\")").count - 1, 2)
        XCTAssertFalse(source.contains(".blendMode(.screen)"))
    }

    /// The signature invites whoever receives the picture, in both languages.
    func testTheSignatureInvites() throws {
        let source = try String(contentsOf: root.appendingPathComponent("DiPo/StatsExport.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("loc(\"stats.report_cta\")"))
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(loc("stats.report_cta"), "Catat keuanganmu dengan DiPo, gratis di App Store.")
        }
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(loc("stats.report_cta"), "Track your money with DiPo, free on the App Store.")
        }
    }
}
