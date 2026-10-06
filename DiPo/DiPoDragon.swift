import SwiftUI
import SceneKit
import UIKit

// MARK: - DiPo in 3D
//
// The DiPo mascot as a real 3D model (DiPoDragon.usdz, made in Meshy from the
// mascot artwork, CC BY 4.0). Cut down for the app before it was bundled:
// 30k triangles instead of 150k, 1024 px textures, 1.2 MB instead of 10.5 MB,
// and the logo on the back of his phone painted out.
//
// The model holds no animation of its own, so he is moved as a whole through
// SCNActions: a slow look left and right, breathing, a hop when tapped, and a
// turn when dragged. 30 fps; Reduce Motion keeps only the slow look.

@MainActor
final class DiPoDragonRig {
    let scene = SCNScene()
    private let turntable = SCNNode()   // the look and the drag
    private let body = SCNNode()        // breathing and hops
    private let calm = UIAccessibility.isReduceMotionEnabled
    /// The artwork's three-quarter view.
    private static let restingTurn: Float = 0.3
    /// False when the model file is missing — the view then shows the picture.
    let hasModel: Bool

    init() {
        let loaded = Bundle.main.url(forResource: "DiPoDragon", withExtension: "usdz")
            .flatMap { try? SCNScene(url: $0) }
        hasModel = loaded != nil

        scene.rootNode.addChildNode(turntable)
        turntable.addChildNode(body)
        turntable.eulerAngles.y = Self.restingTurn

        if let loaded {
            let model = SCNNode()
            for child in loaded.rootNode.childNodes { model.addChildNode(child) }
            // Centre him and fit him in a unit sphere, whatever units the file uses.
            let (centre, radius) = model.boundingSphere
            let k = radius > 0 ? 1 / radius : 1
            model.scale = SCNVector3(k, k, k)
            model.position = SCNVector3(-centre.x * k, -centre.y * k, -centre.z * k)
            body.addChildNode(model)
        }

        scene.lightingEnvironment.contents = CoinGardenRig.environment()
        scene.lightingEnvironment.intensity = 1.0

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        camera.position = SCNVector3(0, 0, 3.75)
        scene.rootNode.addChildNode(camera)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 300
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1100
        key.eulerAngles = SCNVector3(-0.6, -0.4, 0)
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.intensity = 400
        rim.eulerAngles = SCNVector3(-0.3, .pi * 0.85, 0)
        scene.rootNode.addChildNode(rim)

        start()
    }

    private func start() {
        if !calm {
            let inhale = SCNAction.scale(to: 1.02, duration: 1.4)
            let exhale = SCNAction.scale(to: 1.0, duration: 1.4)
            inhale.timingMode = .easeInEaseOut; exhale.timingMode = .easeInEaseOut
            body.runAction(.repeatForever(.sequence([inhale, exhale])), forKey: "breathe")
        }
        look()
    }

    /// Looking slowly left and right — stopped while dragged.
    private func look() {
        let pace: Double = calm ? 2.5 : 1
        let rest = CGFloat(Self.restingTurn)
        let a = SCNAction.rotateTo(x: 0, y: rest - 0.35, z: 0, duration: 3 * pace)
        let b = SCNAction.rotateTo(x: 0, y: rest + 0.2, z: 0, duration: 3 * pace)
        a.timingMode = .easeInEaseOut; b.timingMode = .easeInEaseOut
        turntable.runAction(.repeatForever(.sequence([a, b])), forKey: "look")
    }

    /// One happy hop, for a tap.
    func bounce() {
        guard body.action(forKey: "hop") == nil else { return }
        let up = SCNAction.moveBy(x: 0, y: 0.25, z: 0, duration: 0.18)
        up.timingMode = .easeOut
        let down = SCNAction.moveBy(x: 0, y: -0.25, z: 0, duration: 0.22)
        down.timingMode = .easeIn
        let spin = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 0.4)
        spin.timingMode = .easeInEaseOut
        let hop: SCNAction = calm ? SCNAction.sequence([up, down]) : SCNAction.group([SCNAction.sequence([up, down]), spin])
        body.runAction(hop, forKey: "hop")
    }

    func turn(by radians: Float) {
        turntable.removeAction(forKey: "look")
        turntable.eulerAngles.y += radians
    }

    func settle() {
        let back = SCNAction.rotateTo(x: 0, y: CGFloat(Self.restingTurn), z: 0, duration: 0.6)
        back.timingMode = .easeOut
        turntable.runAction(back) { [weak self] in
            Task { @MainActor in self?.look() }
        }
    }
}

// MARK: - SwiftUI

/// DiPo in 3D. Tap to make him hop; with `interactive`, drag to turn him.
/// Falls back to the mascot picture if the model cannot be loaded.
struct DiPoDragonView: View {
    var interactive = false

    var body: some View {
        DiPoDragonScene(interactive: interactive)
    }
}

private struct DiPoDragonScene: UIViewRepresentable {
    var interactive: Bool

    func makeCoordinator() -> Coordinator { Coordinator(rig: DiPoDragonRig()) }

    func makeUIView(context: Context) -> UIView {
        let rig = context.coordinator.rig
        guard rig.hasModel else {
            let image = UIImageView(image: UIImage(named: "DiPoMascot"))
            image.contentMode = .scaleAspectFit
            return image
        }
        let view = SCNView()
        view.scene = rig.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.isPlaying = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = loc("mascot.a11y")
        view.accessibilityTraits = .image
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
        if interactive {
            view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.dragged(_:))))
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        let rig: DiPoDragonRig
        private var lastX: CGFloat = 0
        init(rig: DiPoDragonRig) { self.rig = rig }

        @objc func tapped() {
            HapticManager.shared.tap()
            rig.bounce()
        }

        @objc func dragged(_ g: UIPanGestureRecognizer) {
            let x = g.translation(in: g.view).x
            switch g.state {
            case .began: lastX = 0
            case .changed:
                rig.turn(by: Float(x - lastX) * 0.01)
                lastX = x
            default: rig.settle()
            }
        }
    }
}
