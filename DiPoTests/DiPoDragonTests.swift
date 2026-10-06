import XCTest
import SceneKit
@testable import DiPo

/// The bundled 3D DiPo loads, fits the frame and takes touches.
@MainActor
final class DiPoDragonTests: XCTestCase {

    func testModelIsBundledAndLoads() {
        let rig = DiPoDragonRig()
        XCTAssertTrue(rig.hasModel, "DiPoDragon.usdz is in the app bundle and opens")
        let nodes = rig.scene.rootNode.childNodes(passingTest: { _, _ in true })
        XCTAssertTrue(nodes.contains { $0.geometry != nil }, "a mesh")
        XCTAssertTrue(nodes.contains { $0.camera != nil }, "a camera")
    }

    func testTouchesDoNotBreakIt() {
        let rig = DiPoDragonRig()
        rig.bounce()
        rig.turn(by: 0.5)
        rig.settle()
    }

    func testStringInBothLanguages() {
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                XCTAssertNotEqual(loc("mascot.a11y"), "mascot.a11y")
            }
        }
    }
}
