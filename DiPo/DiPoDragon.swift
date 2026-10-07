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

/// What DiPo is feeling about what he is saying.
enum DiPoMood: Equatable {
    case idle, happy, worry, cheer, info
}

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
    /// Top of his head in `body` space, so the crown and the sweat drop sit on it.
    private var headTop: Float = 0.7
    private let crown = SCNNode()
    private let drop = SCNNode()
    private(set) var mood: DiPoMood = .idle

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
            headTop = model.boundingBox.max.y * k + model.position.y
        }
        buildCrown()
        buildDrop()

        scene.lightingEnvironment.contents = Self.environment()
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

    // MARK: Moods

    /// React to what he is saying: a happy hop, a worried shiver with a sweat
    /// drop, a cheering spin with coins, or a nod for plain news.
    func react(_ mood: DiPoMood) {
        self.mood = mood
        drop.isHidden = mood != .worry
        drop.removeAllActions()
        guard !calm else { return }
        switch mood {
        case .idle, .info:
            nod()
        case .happy:
            bounce()
        case .worry:
            let l = SCNAction.moveBy(x: -0.03, y: 0, z: 0, duration: 0.05)
            let r = SCNAction.moveBy(x: 0.03, y: 0, z: 0, duration: 0.05)
            turntable.runAction(.sequence([.repeat(.sequence([l, r, r, l]), count: 5)]), forKey: "shiver")
            let fall = SCNAction.moveBy(x: 0, y: -0.3, z: 0, duration: 1.2)
            let back = SCNAction.moveBy(x: 0, y: 0.3, z: 0, duration: 0)
            drop.runAction(.repeatForever(.sequence([.fadeIn(duration: 0.1), .group([fall, .fadeOut(duration: 1.2)]), back])))
        case .cheer:
            bounce()
            burstCoins()
        }
    }

    /// Nods while the bubble is typing, so he looks like the one talking.
    func talk(for seconds: Double) {
        guard !calm, seconds > 0 else { return }
        let down = SCNAction.rotateBy(x: 0.06, y: 0, z: 0, duration: 0.14)
        let up = down.reversed()
        let times = max(1, Int(seconds / 0.28))
        body.runAction(.repeat(.sequence([down, up]), count: times), forKey: "talk")
    }

    func setCrowned(_ on: Bool) { crown.isHidden = !on }

    private func nod() {
        let down = SCNAction.rotateBy(x: 0.12, y: 0, z: 0, duration: 0.18)
        down.timingMode = .easeInEaseOut
        body.runAction(.sequence([down, down.reversed()]), forKey: "nod")
    }

    private func buildCrown() {
        let gold = Self.metal(UIColor(AppTheme.dipoCrown))
        let band = SCNTube(innerRadius: 0.13, outerRadius: 0.15, height: 0.09)
        band.firstMaterial = gold
        crown.addChildNode(SCNNode(geometry: band))
        for i in 0..<5 {
            let a = Float(i) / 5 * .pi * 2
            let point = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.035, height: 0.1))
            point.geometry?.firstMaterial = gold
            point.position = SCNVector3(sin(a) * 0.14, 0.09, cos(a) * 0.14)
            crown.addChildNode(point)
        }
        crown.position = SCNVector3(-0.04, headTop - 0.04, 0)
        crown.eulerAngles.z = -0.18
        crown.isHidden = true
        body.addChildNode(crown)
    }

    private func buildDrop() {
        let sphere = SCNSphere(radius: 0.045)
        sphere.firstMaterial = Self.metal(UIColor(AppTheme.dipoSweat), metalness: 0)
        drop.geometry = sphere
        drop.scale = SCNVector3(0.8, 1.25, 0.8)
        drop.position = SCNVector3(0.3, headTop - 0.2, 0.3)
        drop.isHidden = true
        body.addChildNode(drop)
    }

    private func burstCoins() {
        let gold = Self.metal(UIColor(AppTheme.dipoCrown))
        for _ in 0..<8 {
            let coin = SCNNode(geometry: SCNCylinder(radius: 0.06, height: 0.015))
            coin.geometry?.firstMaterial = gold
            coin.eulerAngles.x = .pi / 2
            coin.position = SCNVector3(0, headTop, 0.2)
            turntable.addChildNode(coin)
            let dx = CGFloat.random(in: -0.8...0.8), up = CGFloat.random(in: 0.4...0.7)
            let rise = SCNAction.moveBy(x: dx * 0.5, y: up, z: 0.2, duration: 0.35)
            rise.timingMode = .easeOut
            let fall = SCNAction.moveBy(x: dx * 0.5, y: -1.6, z: 0, duration: 0.7)
            fall.timingMode = .easeIn
            let spin = SCNAction.rotateBy(x: 0, y: 0, z: .pi * 4, duration: 1.05)
            coin.runAction(.sequence([.group([.sequence([rise, fall]), spin, .sequence([.wait(duration: 0.7), .fadeOut(duration: 0.35)])]),
                                      .removeFromParentNode()]))
        }
    }

    private static func metal(_ color: UIColor, metalness: CGFloat = 0.9) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metalness
        m.roughness.contents = 0.25
        return m
    }

    /// Warm studio light for him to reflect: bright above, two soft windows,
    /// dim below.
    private static func environment() -> UIImage {
        let size = CGSize(width: 256, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(red: 1, green: 0.97, blue: 0.91, alpha: 1).cgColor,
                          UIColor(red: 0.95, green: 0.89, blue: 0.75, alpha: 1).cgColor,
                          UIColor(red: 0.54, green: 0.48, blue: 0.35, alpha: 1).cgColor,
                          UIColor(red: 0.23, green: 0.2, blue: 0.15, alpha: 1).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 0.55, 1]) {
                cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            cg.setFillColor(UIColor(white: 1, alpha: 0.9).cgColor)
            cg.fill(CGRect(x: 40, y: 20, width: 50, height: 30))
            cg.fill(CGRect(x: 170, y: 30, width: 40, height: 20))
        }
    }
}

// MARK: - SwiftUI

/// DiPo in 3D. Tap to make him hop; with `interactive`, drag to turn him.
/// Falls back to the mascot picture if the model cannot be loaded.
struct DiPoDragonView: View {
    var interactive = false
    /// How he feels about the current line. He reacts each time `line` changes.
    var mood: DiPoMood = .idle
    /// Identifies what he is saying now; a new value makes him react and nod.
    var line: String = ""
    /// How long the bubble takes to type the line, so he nods for that long.
    var talkSeconds: Double = 0
    /// The Royal crown.
    var crowned = false
    /// Called after his hop when he is tapped, e.g. to open Ask DiPo.
    var onTap: (() -> Void)? = nil

    var body: some View {
        DiPoDragonScene(interactive: interactive, mood: mood, line: line,
                        talkSeconds: talkSeconds, crowned: crowned, onTap: onTap)
    }
}

private struct DiPoDragonScene: UIViewRepresentable {
    var interactive: Bool
    var mood: DiPoMood
    var line: String
    var talkSeconds: Double
    var crowned: Bool
    var onTap: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(rig: DiPoDragonRig()) }

    func makeUIView(context: Context) -> UIView {
        let rig = context.coordinator.rig
        context.coordinator.onTap = onTap
        guard rig.hasModel else {
            let image = UIImageView(image: UIImage(named: "DiPoMascot"))
            image.contentMode = .scaleAspectFit
            image.isUserInteractionEnabled = true
            image.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
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

    func updateUIView(_ view: UIView, context: Context) {
        let c = context.coordinator
        c.onTap = onTap
        c.rig.setCrowned(crowned)
        guard line != c.lastLine else { return }
        c.lastLine = line
        c.rig.react(mood)
        c.rig.talk(for: talkSeconds)
    }

    @MainActor
    final class Coordinator: NSObject {
        let rig: DiPoDragonRig
        var lastLine = ""
        var onTap: (() -> Void)?
        private var lastX: CGFloat = 0
        init(rig: DiPoDragonRig) { self.rig = rig }

        @objc func tapped() {
            HapticManager.shared.tap()
            rig.bounce()
            onTap?()
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
