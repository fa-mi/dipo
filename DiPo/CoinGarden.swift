import SwiftUI
import SceneKit
import UIKit

// MARK: - Coin garden: savings that grow, in 3D
//
// Four stacks of gold coins rising like a chart on a round emerald base, a
// sprout growing out of the tallest one, a coin turning in the air and
// another dropping onto the shortest stack — saving a little, often, and
// watching it grow.
//
// Built from primitives with physically based materials and a gradient
// environment for the gold to reflect, so there is no model file to ship.
// Everything moves through SCNActions — no per-frame delegate, which would
// run off the main actor — at 30 fps. Reduce Motion keeps only a slow sway.

@MainActor
final class CoinGardenRig {
    let scene = SCNScene()
    private let world = SCNNode()
    private let sprout = SCNNode()
    private let spinner = SCNNode()
    private let stacks: [(x: Float, z: Float, count: Int)] = [(-1.45, 0.45, 3), (-0.48, -0.15, 6), (0.48, 0.4, 9), (1.45, -0.2, 13)]
    private let calm = UIAccessibility.isReduceMotionEnabled

    static let coinHeight: Float = 0.16
    static let coinRadius: CGFloat = 0.46

    init(shadows: Bool) {
        scene.lightingEnvironment.contents = Self.environment()
        scene.lightingEnvironment.intensity = 1.1
        scene.rootNode.addChildNode(world)

        // Round base with a soft lip
        let baseColor = UIColor(AppTheme.gardenBase)
        let plate = SCNNode(geometry: SCNCylinder(radius: 2.6, height: 0.28))
        plate.geometry?.firstMaterial = Self.material(baseColor, metal: 0, rough: 0.55)
        plate.position = SCNVector3(0, -0.14, 0)
        world.addChildNode(plate)
        let lip = SCNNode(geometry: SCNTorus(ringRadius: 2.6, pipeRadius: 0.14))
        lip.geometry?.firstMaterial = Self.material(baseColor, metal: 0, rough: 0.55)
        world.addChildNode(lip)

        // Stacks, each coin a hair off-centre so they read as a pile
        for stack in stacks {
            for i in 0..<stack.count {
                let c = Self.coin()
                let fi = Float(i)
                c.position = SCNVector3(stack.x + sin(fi * 2.3 + stack.x) * 0.03,
                                        Self.coinHeight / 2 + fi * Self.coinHeight,
                                        stack.z + cos(fi * 1.7 + stack.z) * 0.03)
                c.eulerAngles.y = fi * 0.7
                world.addChildNode(c)
            }
        }

        // Sprout on the tallest stack
        let tall = stacks[3]
        sprout.position = SCNVector3(tall.x, Float(tall.count) * Self.coinHeight, tall.z)
        world.addChildNode(sprout)
        let stem = SCNNode(geometry: SCNCone(topRadius: 0.045, bottomRadius: 0.06, height: 0.9))
        stem.geometry?.firstMaterial = Self.material(baseColor, metal: 0, rough: 0.5)
        stem.position = SCNVector3(0, 0.45, 0)
        sprout.addChildNode(stem)
        for side: Float in [-1, 1] {
            let pivot = SCNNode()
            pivot.position = SCNVector3(0, 0.82, 0)
            pivot.eulerAngles.z = 0.45 * side
            let leaf = SCNNode(geometry: SCNSphere(radius: 0.38))
            (leaf.geometry as? SCNSphere)?.segmentCount = 32
            leaf.geometry?.firstMaterial = Self.material(UIColor(AppTheme.accent), metal: 0, rough: 0.4)
            leaf.scale = SCNVector3(1, 0.18, 0.55)
            leaf.position = SCNVector3(0.36 * side, 0, 0)
            pivot.addChildNode(leaf)
            sprout.addChildNode(pivot)
            if !calm {
                let a = SCNAction.rotateTo(x: 0, y: 0, z: CGFloat(0.37 * side), duration: 1.5)
                let b = SCNAction.rotateTo(x: 0, y: 0, z: CGFloat(0.53 * side), duration: 1.5)
                a.timingMode = .easeInEaseOut; b.timingMode = .easeInEaseOut
                pivot.runAction(.repeatForever(.sequence([a, b])))
            }
        }

        // A coin turning in the air above the second stack
        spinner.position = SCNVector3(-0.48, 2.9, -0.15)
        let upright = Self.coin()
        upright.eulerAngles.x = .pi / 2
        spinner.addChildNode(upright)
        world.addChildNode(spinner)

        // Camera and lights
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        camera.position = SCNVector3(0, 4.6, 11)
        camera.eulerAngles.x = -atan(3.35 / 11)
        scene.rootNode.addChildNode(camera)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 250
        scene.rootNode.addChildNode(ambient)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1500
        sun.eulerAngles = SCNVector3(-1.0, -0.5, 0)
        if shadows {
            sun.light?.castsShadow = true
            sun.light?.shadowMode = .deferred
            sun.light?.shadowRadius = 6
            sun.light?.shadowSampleCount = 8
            sun.light?.shadowColor = UIColor.black.withAlphaComponent(0.35)
        }
        scene.rootNode.addChildNode(sun)

        let warm = SCNNode()
        warm.light = SCNLight()
        warm.light?.type = .omni
        warm.light?.color = UIColor(red: 1, green: 0.89, blue: 0.66, alpha: 1)
        warm.light?.intensity = 600
        warm.position = SCNVector3(3, 4, 4)
        scene.rootNode.addChildNode(warm)

        world.eulerAngles.y = -0.35
        start()
    }

    private func start() {
        let pace: Double = calm ? 2.5 : 1
        let sl = SCNAction.rotateTo(x: 0, y: 0, z: 0.08, duration: 1.9 * pace)
        let sr = SCNAction.rotateTo(x: 0, y: 0, z: -0.08, duration: 1.9 * pace)
        sl.timingMode = .easeInEaseOut; sr.timingMode = .easeInEaseOut
        sprout.runAction(.repeatForever(.sequence([sl, sr])))

        if !calm {
            spinner.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 2.6)))
            let up = SCNAction.moveBy(x: 0, y: 0.12, z: 0, duration: 1.5)
            up.timingMode = .easeInEaseOut
            spinner.runAction(.repeatForever(.sequence([up, up.reversed()])))
        }
        sway()
    }

    /// The garden turning gently to and fro, and coins dropping in — stopped
    /// while the user drags, restarted when they let go.
    private func sway() {
        let pace: Double = calm ? 2.5 : 1
        let l = SCNAction.rotateTo(x: 0, y: -0.6, z: 0, duration: 4 * pace)
        let r = SCNAction.rotateTo(x: 0, y: -0.1, z: 0, duration: 4 * pace)
        l.timingMode = .easeInEaseOut; r.timingMode = .easeInEaseOut
        world.runAction(.repeatForever(.sequence([l, r])), forKey: "sway")

        guard !calm else { return }
        let drop = SCNAction.run { _ in Task { @MainActor [weak self] in self?.dropCoin(on: 0) } }
        world.runAction(.repeatForever(.sequence([.wait(duration: 1.2), drop, .wait(duration: 1.2)])), forKey: "drops")
    }

    /// One coin falls onto a stack, bounces, rests a moment and fades.
    /// Also what a tap does — onto a random stack.
    func dropCoin(on index: Int? = nil) {
        let stack = stacks[index ?? Int.random(in: 0..<stacks.count)]
        let land = Self.coinHeight / 2 + Float(stack.count) * Self.coinHeight
        let coin = Self.coin()
        coin.position = SCNVector3(stack.x, 3.2, stack.z)
        coin.eulerAngles.y = Float.random(in: 0...6)
        world.addChildNode(coin)
        let fall = SCNAction.moveBy(x: 0, y: CGFloat(land - 3.2), z: 0, duration: 0.84)
        fall.timingMode = .easeIn
        let hop = SCNAction.moveBy(x: 0, y: 0.12, z: 0, duration: 0.12)
        hop.timingMode = .easeOut
        let settle = hop.reversed()
        settle.timingMode = .easeIn
        coin.runAction(.sequence([fall, hop, settle, .wait(duration: 1.0), .fadeOut(duration: 0.25), .removeFromParentNode()]))
    }

    func turn(by radians: Float) {
        world.removeAction(forKey: "sway")
        world.removeAction(forKey: "drops")
        world.eulerAngles.y += radians
    }

    func settle() {
        let back = SCNAction.rotateTo(x: 0, y: -0.35, z: 0, duration: 0.6)
        back.timingMode = .easeOut
        world.runAction(back) { [weak self] in
            Task { @MainActor in self?.sway() }
        }
    }

    // MARK: Building blocks

    private static func material(_ color: UIColor, metal: CGFloat, rough: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metal
        m.roughness.contents = rough
        return m
    }

    /// A gold coin: the disc, a raised ring on each face and a groove round the edge.
    private static func coin() -> SCNNode {
        let gold = material(UIColor(AppTheme.coinGold), metal: 0.9, rough: 0.3)
        let groove = material(UIColor(AppTheme.coinGroove), metal: 1, rough: 0.35)
        let n = SCNNode()
        let disc = SCNCylinder(radius: coinRadius, height: CGFloat(coinHeight))
        disc.radialSegmentCount = 48
        disc.firstMaterial = gold
        n.addChildNode(SCNNode(geometry: disc))
        for y in [coinHeight / 2, -coinHeight / 2] {
            let ring = SCNTorus(ringRadius: coinRadius * 0.72, pipeRadius: 0.025)
            ring.firstMaterial = groove
            let r = SCNNode(geometry: ring)
            r.position.y = y
            n.addChildNode(r)
        }
        let edge = SCNTorus(ringRadius: coinRadius, pipeRadius: 0.012)
        edge.firstMaterial = groove
        n.addChildNode(SCNNode(geometry: edge))
        return n
    }

    /// Warm studio light for the gold to reflect: bright above, two soft
    /// windows, dim below.
    static func environment() -> UIImage {
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

/// The coin garden as a view. `interactive` lets a tap drop a coin and a
/// drag turn the garden.
struct CoinGardenView: UIViewRepresentable {
    var interactive = false
    var shadows = false

    func makeCoordinator() -> Coordinator { Coordinator(rig: CoinGardenRig(shadows: shadows)) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.rig.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = false
        view.isPlaying = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = loc("garden.a11y")
        view.accessibilityTraits = .image
        if interactive {
            view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
            view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.dragged(_:))))
        }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        let rig: CoinGardenRig
        private var lastX: CGFloat = 0
        init(rig: CoinGardenRig) { self.rig = rig }

        @objc func tapped() {
            HapticManager.shared.tap()
            rig.dropCoin()
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
