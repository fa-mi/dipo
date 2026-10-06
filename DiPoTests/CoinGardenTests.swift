import XCTest
import SceneKit
@testable import DiPo

/// The 3D coin garden builds from primitives and keeps running when touched.
@MainActor
final class CoinGardenTests: XCTestCase {

    func testSceneBuilds() {
        let rig = CoinGardenRig(shadows: true)
        let nodes = rig.scene.rootNode.childNodes(passingTest: { _, _ in true })
        XCTAssertTrue(nodes.contains { $0.camera != nil }, "a camera")
        XCTAssertGreaterThanOrEqual(nodes.filter { $0.light != nil }.count, 2, "lights")
        // 3 + 6 + 9 + 13 stacked coins, plus the one in the air, plus the base
        XCTAssertGreaterThanOrEqual(nodes.filter { $0.geometry is SCNCylinder }.count, 32, "coins")
        XCTAssertNotNil(rig.scene.lightingEnvironment.contents, "something for the gold to reflect")
    }

    func testTouchesDoNotBreakIt() {
        let rig = CoinGardenRig(shadows: false)
        let before = rig.scene.rootNode.childNodes(passingTest: { _, _ in true }).count
        rig.dropCoin()
        rig.dropCoin(on: 3)
        rig.turn(by: 0.4)
        rig.settle()
        let after = rig.scene.rootNode.childNodes(passingTest: { _, _ in true }).count
        XCTAssertGreaterThan(after, before, "dropped coins join the scene")
    }

    func testStringInBothLanguages() {
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                XCTAssertNotEqual(loc("garden.a11y"), "garden.a11y")
            }
        }
    }
}
