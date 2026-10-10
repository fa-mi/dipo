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

    /// On the Quest path he turns all the way round; a drag takes over, and
    /// letting go carries on turning from there. Reduce Motion keeps the
    /// slow look instead.
    func testASpinningDiPoKeepsTurningAfterADrag() {
        let rig = DiPoDragonRig(spins: true)
        let moving = !UIAccessibility.isReduceMotionEnabled
        XCTAssertEqual(rig.isSpinning, moving)
        rig.turn(by: 0.8)
        XCTAssertFalse(rig.isSpinning, "the finger has him")
        rig.settle()
        XCTAssertEqual(rig.isSpinning, moving)
        rig.bounce()
        XCTAssertEqual(rig.isSpinning, moving, "a hop does not stop the turn")
    }

    func testTheUsualDiPoDoesNotSpin() {
        XCTAssertFalse(DiPoDragonRig().isSpinning)
        XCTAssertGreaterThanOrEqual(DiPoDragonRig.spinSeconds, 6, "slow enough to read as turning, not spinning")
    }

    func testStringInBothLanguages() {
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                XCTAssertNotEqual(loc("mascot.a11y"), "mascot.a11y")
            }
        }
    }
}
