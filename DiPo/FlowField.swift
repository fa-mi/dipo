import SwiftUI

// MARK: - A soft colour field behind the Statistics headline
//
// After the "Flow" studies at feralui.dev/gradients: large, blurred glows
// that read as light falling on the card rather than as a pattern.
//
// The same field the dashboard's hero at dipo.info draws, glow for glow —
// the Emerald preset (Pine Leaf, Young Willow, Black Moss) and Aurora
// (Midnight Lapis, Deep Hanada) on a near-black ground, Peach Pink and
// Ancient Purple when the balance is heading below zero — so the phone and
// the web open on one picture. It is that ground in both themes, as a card
// face is: a pale field in light mode was the one place the two disagreed.
//
// One surface only: the Statistics hero, the screen's focal point. Anything
// that carries a figure stays a flat colour — a bar or a tile reads faster
// flat, and when every card glows none of them stands out.
//
// Static, where the web's drifts. A field that moves keeps the GPU awake for
// as long as the screen is open, on phones that are mostly not new ones.

struct FlowField: View {
    /// The balance is on course to run out before payday.
    var danger: Bool = false

    /// One CSS `radial-gradient` from the web's hero, as written there:
    /// radii and centre as fractions of a box 30% larger than the card on
    /// every side, the colour fading to clear at `fade` of the radius.
    struct Glow {
        let rx: CGFloat, ry: CGFloat
        let cx: CGFloat, cy: CGFloat
        let color: Color
        let alpha: Double
        let fade: CGFloat
    }

    /// Top of the list paints on top, as in CSS.
    static let emerald: [Glow] = [
        Glow(rx: 0.34, ry: 0.40, cx: 0.84, cy: 0.14, color: AppTheme.flowPine,   alpha: 0.72, fade: 0.72),
        Glow(rx: 0.24, ry: 0.30, cx: 0.96, cy: 0.50, color: AppTheme.flowWillow, alpha: 0.34, fade: 0.70),
        Glow(rx: 0.60, ry: 0.16, cx: 0.46, cy: 0.60, color: AppTheme.flowMint,   alpha: 0.24, fade: 0.72),
        Glow(rx: 0.42, ry: 0.52, cx: 0.66, cy: 0.80, color: AppTheme.flowMoss,   alpha: 0.95, fade: 0.72),
        Glow(rx: 0.40, ry: 0.50, cx: 0.10, cy: 0.88, color: AppTheme.flowHanada, alpha: 0.78, fade: 0.72),
        Glow(rx: 0.48, ry: 0.56, cx: 0.12, cy: 0.12, color: AppTheme.flowCobalt, alpha: 0.55, fade: 0.74),
        Glow(rx: 0.48, ry: 0.56, cx: 0.22, cy: 0.30, color: AppTheme.flowLapis,  alpha: 0.95, fade: 0.74),
        Glow(rx: 0.30, ry: 0.34, cx: 0.44, cy: 0.40, color: AppTheme.flowMint,   alpha: 0.16, fade: 0.70),
    ]

    static let ember: [Glow] = [
        Glow(rx: 0.34, ry: 0.40, cx: 0.84, cy: 0.14, color: AppTheme.flowPeach,  alpha: 0.55, fade: 0.72),
        Glow(rx: 0.42, ry: 0.52, cx: 0.66, cy: 0.80, color: AppTheme.flowPlum,   alpha: 0.85, fade: 0.72),
        Glow(rx: 0.40, ry: 0.50, cx: 0.10, cy: 0.88, color: AppTheme.flowEmber,  alpha: 0.70, fade: 0.72),
        Glow(rx: 0.48, ry: 0.56, cx: 0.12, cy: 0.12, color: AppTheme.flowLapis,  alpha: 0.95, fade: 0.74),
    ]

    /// The web's `inset: -30%`.
    static let overscan: CGFloat = 0.3

    var body: some View {
        GeometryReader { g in
            let w = g.size.width * (1 + 2 * Self.overscan)
            let h = g.size.height * (1 + 2 * Self.overscan)
            let ox = -g.size.width * Self.overscan
            let oy = -g.size.height * Self.overscan
            let glows = danger ? Self.ember : Self.emerald
            // Glows only: the card under it is `flowGround`, as the web's
            // hero is #05100d under its blurred ::before.
            ZStack {
                ForEach(Array(glows.enumerated().reversed()), id: \.offset) { _, glow in
                    EllipticalGradient(
                        gradient: Gradient(stops: [
                            .init(color: glow.color.opacity(glow.alpha), location: 0),
                            .init(color: glow.color.opacity(0), location: glow.fade),
                        ]),
                        center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                        .frame(width: 2 * glow.rx * w, height: 2 * glow.ry * h)
                        .position(x: ox + glow.cx * w, y: oy + glow.cy * h)
                }
            }
            .blur(radius: 30)
            .saturation(1.18)
        }
        // Rendered once into a single layer rather than blurred per frame.
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
