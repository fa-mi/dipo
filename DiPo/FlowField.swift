import SwiftUI

// MARK: - A soft colour field behind the Statistics headline
//
// After the "Flow" studies at feralui.dev/gradients: a few large, blurred
// spots of colour that read as light falling on the card rather than as a
// pattern. The Emerald preset by day (Young Willow, Pine Leaf), Aurora by
// night (Black Moss, Pine Leaf, Midnight Lapis, Deep Hanada), and Peach Pink
// with Ancient Purple when the balance is heading below zero.
//
// One surface only: the Statistics hero, the screen's focal point. Anything
// that carries a figure stays a flat colour — a bar or a tile reads faster
// flat, and when every card glows none of them stands out. Home's card face
// already has its own gradient, so nothing on Home gets one.
//
// Static rather than drifting. A field that moves keeps the GPU awake for as
// long as the screen is open, on phones that are mostly not new ones.

struct FlowField: View {
    /// The balance is on course to run out before payday.
    var danger: Bool = false

    @Environment(\.colorScheme) private var scheme

    /// Centre and size as fractions of the card; the field is clipped by it.
    private struct Spot {
        let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
        let color: Color
        let opacity: Double
    }

    private var spots: [Spot] {
        switch (scheme == .dark, danger) {
        case (false, false):
            return [Spot(x: 0.78, y: -0.10, w: 0.70, h: 0.55, color: AppTheme.flowWillow, opacity: 0.55),
                    Spot(x: 0.96, y: 0.22, w: 0.45, h: 0.40, color: AppTheme.flowPine, opacity: 0.28),
                    Spot(x: -0.12, y: -0.08, w: 0.45, h: 0.32, color: AppTheme.flowHanada, opacity: 0.10)]
        case (true, false):
            return [Spot(x: 0.74, y: -0.12, w: 0.75, h: 0.55, color: AppTheme.flowMoss, opacity: 0.85),
                    Spot(x: 0.98, y: 0.20, w: 0.45, h: 0.40, color: AppTheme.flowPine, opacity: 0.30),
                    Spot(x: -0.14, y: -0.10, w: 0.55, h: 0.40, color: AppTheme.flowLapis, opacity: 0.70),
                    Spot(x: 0.10, y: 0.04, w: 0.40, h: 0.26, color: AppTheme.flowHanada, opacity: 0.35)]
        case (false, true):
            return [Spot(x: 0.78, y: -0.10, w: 0.70, h: 0.55, color: AppTheme.flowPeach, opacity: 0.42),
                    Spot(x: 0.98, y: 0.22, w: 0.45, h: 0.40, color: AppTheme.flowPlum, opacity: 0.18)]
        case (true, true):
            return [Spot(x: 0.74, y: -0.12, w: 0.75, h: 0.55, color: AppTheme.flowPlum, opacity: 0.60),
                    Spot(x: 0.98, y: 0.20, w: 0.45, h: 0.40, color: AppTheme.flowPeach, opacity: 0.30),
                    Spot(x: -0.14, y: -0.10, w: 0.55, h: 0.40, color: AppTheme.flowLapis, opacity: 0.70)]
        }
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                ForEach(Array(spots.enumerated()), id: \.offset) { _, spot in
                    Ellipse()
                        .fill(spot.color.opacity(spot.opacity))
                        .frame(width: w * spot.w, height: h * spot.h)
                        .position(x: w * spot.x, y: h * spot.y)
                }
            }
            .blur(radius: 34)
        }
        // Rendered once into a single layer rather than blurred per frame.
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
