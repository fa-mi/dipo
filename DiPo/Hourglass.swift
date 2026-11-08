import SwiftUI
import UIKit

// MARK: - Hourglass

/// The hourglass on Home's "This period" card: green sand in the top bulb is
/// what is left of the period's money, grey sand in the bottom bulb is what has
/// been used.
///
/// The drawing is made with the Anatomy kit in `tools/hourglass` (`art.mjs`),
/// and `node tools/hourglass/build.mjs` writes it here as `HourglassArt.json`:
/// every shape the kit draws, tagged with its material (brass, glass, the sand
/// left, the sand spent) and its role (fill, one of four shades, top face,
/// line, dot). This file only paints those shapes, with the app's own tokens,
/// so the colours follow light and dark mode. Regenerate the JSON there; don't
/// edit it by hand.
struct HourglassArt: Decodable {
    struct Shape: Decodable {
        /// brass, glass, left, spent or plain.
        let m: String
        /// halo, glass, fill, shade0…shade3, top, line or dot.
        let r: String
        let d: String?
        /// A dot: centre and radius.
        let c: [Double]?
        /// A line's tone: hi, mid, lo or faint.
        let t: String?
        /// 1 on the outline of a solid.
        let e: Int?
        /// 1 on a smooth solid's tone regions, which are stroked in their own
        /// colour so no hairline shows between them.
        let s: Int?
        /// A line's own opacity (the glass highlight fades).
        let a: Double?
    }

    /// One shape, parsed once.
    struct Piece {
        let shape: Shape
        let path: Path
    }

    let viewBox: [Double]
    let back: [Shape]
    let front: [Shape]
    /// The sand in each bulb at 21 levels, empty to full in steps of 5 %.
    let top: [[Shape]]
    let bottom: [[Shape]]

    /// Loaded once from the app bundle; nil if the file is missing, in which
    /// case the card simply goes without the picture.
    static let shared: Parsed? = {
        guard let url = Bundle.main.url(forResource: "HourglassArt", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let art = try? JSONDecoder().decode(HourglassArt.self, from: data) else { return nil }
        return Parsed(art)
    }()

    struct Parsed {
        let box: CGRect
        let back: [Piece]
        let front: [Piece]
        let top: [[Piece]]
        let bottom: [[Piece]]

        init(_ art: HourglassArt) {
            let v = art.viewBox
            box = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
            let parse = { (list: [Shape]) in list.map { Piece(shape: $0, path: HourglassArt.path($0)) } }
            back = parse(art.back)
            front = parse(art.front)
            top = art.top.map(parse)
            bottom = art.bottom.map(parse)
        }
    }

    /// The level (0…20) drawn for a share of a bulb.
    static func level(_ share: Double) -> Int {
        guard share.isFinite else { return 0 }
        return Int((min(max(share, 0), 1) * 20).rounded())
    }

    /// The kit writes only `M x y`, `L x y` and `Z`.
    static func path(_ shape: Shape) -> Path {
        if let c = shape.c, c.count == 3 {
            return Path(ellipseIn: CGRect(x: c[0] - c[2], y: c[1] - c[2], width: c[2] * 2, height: c[2] * 2))
        }
        return path(shape.d ?? "")
    }

    static func path(_ d: String) -> Path {
        var path = Path()
        var command: Character = "M"
        var numbers: [Double] = []
        var number = ""
        func flushNumber() {
            if let value = Double(number) { numbers.append(value) }
            number = ""
            while numbers.count >= 2 {
                let point = CGPoint(x: numbers[0], y: numbers[1])
                numbers.removeFirst(2)
                if command == "M" { path.move(to: point); command = "L" } else { path.addLine(to: point) }
            }
        }
        for ch in d {
            switch ch {
            case "M", "L":
                flushNumber()
                command = ch
            case "Z", "z":
                flushNumber()
                path.closeSubpath()
            case " ", ",":
                flushNumber()
            default:
                number.append(ch)
            }
        }
        flushNumber()
        return path
    }
}

/// The colours for the hourglass, every one a token the app already has or a
/// blend of two at this call site: brass from Royal gold, glass from the
/// Statistics field's Frost, the sand left in DiPo's green with Young Willow,
/// the sand spent in slate, and Black Moss and the hero's ground for shadow.
struct HourglassPaint {
    let dark: Bool
    private let traits: UITraitCollection

    init(dark: Bool) {
        self.dark = dark
        traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
    }

    /// `t` of `a` over `1 − t` of `b`, resolved for this theme.
    func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let x = UIColor(a).resolvedColor(with: traits), y = UIColor(b).resolvedColor(with: traits)
        var (r1, g1, b1, a1) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        var (r2, g2, b2, a2) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        x.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        y.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let k = CGFloat(t)
        return Color(.sRGB, red: r1 * k + r2 * (1 - k), green: g1 * k + g2 * (1 - k), blue: b1 * k + b2 * (1 - k), opacity: 1)
    }

    var card: Color { AppTheme.cardDark }

    /// The fill for a face of a solid.
    func fill(_ shape: HourglassArt.Shape) -> Color {
        let gold = AppTheme.royalGold, ground = AppTheme.flowGround
        switch (shape.m, shape.r) {
        case ("brass", "fill"), ("brass", "shade1"): return mix(gold, ground, 0.60)
        case ("brass", "shade0"): return mix(gold, ground, 0.46)
        case ("brass", "shade2"): return mix(gold, ground, 0.76)
        case ("brass", "shade3"): return gold
        case ("brass", "top"): return mix(gold, AppTheme.royalGoldLight, 0.55)
        case ("left", "fill"): return AppTheme.accent
        case ("left", "top"): return mix(AppTheme.accent, AppTheme.flowWillow, 0.45)
        case ("left", _): return mix(AppTheme.accent, AppTheme.flowMoss, 0.78)
        case ("spent", "fill"): return mix(AppTheme.slate, card, 0.55)
        case ("spent", "shade0"): return mix(AppTheme.slate, card, 0.40)
        case ("spent", "shade1"): return mix(AppTheme.slate, card, 0.48)
        case ("spent", "shade2"): return mix(AppTheme.slate, card, 0.56)
        case ("spent", "shade3"): return mix(AppTheme.slate, card, 0.64)
        case ("spent", "top"): return mix(AppTheme.slate, card, 0.75)
        case (_, "glass"): return mix(AppTheme.flowFrost, card, 0.09)
        default: return card
        }
    }

    /// The stroke for a line.
    func line(_ shape: HourglassArt.Shape) -> Color {
        switch shape.m {
        case "brass":
            switch shape.t {
            case "lo": return mix(AppTheme.royalGold, AppTheme.flowGround, 0.45)
            case "faint": return mix(AppTheme.royalGold, AppTheme.flowGround, 0.62)
            default: return AppTheme.royalGoldText
            }
        case "glass": return dark ? mix(AppTheme.flowFrost, card, 0.6) : mix(AppTheme.slate, card, 0.7)
        case "left": return shape.e == 1 ? (dark ? AppTheme.flowWillow : AppTheme.flowMoss) : mix(AppTheme.accent, AppTheme.flowMoss, 0.6)
        case "spent": return AppTheme.slate
        default: return AppTheme.textSecondary
        }
    }

    func dot(_ shape: HourglassArt.Shape) -> Color {
        shape.m == "brass" ? AppTheme.flowGround.opacity(0.5) : AppTheme.textSecondary.opacity(0.5)
    }
}

/// The hourglass at a given split of the period's money. `left` and `used` are
/// shares of what came in (0…1); each bulb shows its own.
struct HourglassView: View, Animatable {
    var left: Double
    var used: Double

    @Environment(\.colorScheme) private var scheme

    /// SwiftUI eases both shares together, so the sand runs rather than jumps.
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(left, used) }
        set { left = newValue.first; used = newValue.second }
    }

    var body: some View {
        Canvas { context, size in
            guard let art = HourglassArt.shared else { return }
            let box = art.box
            let scale = min(size.width / box.width, size.height / box.height)
            context.translateBy(x: (size.width - box.width * scale) / 2 - box.minX * scale,
                                y: (size.height - box.height * scale) / 2 - box.minY * scale)
            context.scaleBy(x: scale, y: scale)
            let paint = HourglassPaint(dark: scheme == .dark)
            let hair = 0.55 / scale
            let pieces = art.back + art.bottom[HourglassArt.level(used)] + art.top[HourglassArt.level(left)] + art.front
            for piece in pieces {
                let shape = piece.shape
                switch shape.r {
                case "halo":
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: 3))
                        layer.fill(piece.path, with: .color(AppTheme.flowGround.opacity(paint.dark ? 0.55 : 0.18)))
                    }
                case "line":
                    context.stroke(piece.path, with: .color(paint.line(shape).opacity(shape.a ?? 1)),
                                   style: StrokeStyle(lineWidth: hair, lineCap: .round, lineJoin: .round))
                case "dot":
                    context.fill(piece.path, with: .color(paint.dot(shape)))
                case "glass":
                    context.fill(piece.path, with: .color(paint.fill(shape).opacity(0.85)))
                default:
                    let colour = paint.fill(shape)
                    context.fill(piece.path, with: .color(colour))
                    if shape.s == 1 { context.stroke(piece.path, with: .color(colour), lineWidth: 0.4 / scale) }
                }
            }
        }
    }
}
