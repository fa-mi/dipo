import SwiftUI

// MARK: - Theme

struct AppTheme {

    // MARK: Surfaces — unchanged from the original palette.

    static let bg            = Color(UIColor.adaptive(dark: "#1A1F1E", light: "#F2F4F3"))
    static let cardDark      = Color(UIColor.adaptive(dark: "#222827", light: "#FFFFFF"))
    static let cardMid       = Color(UIColor.adaptive(dark: "#2A3330", light: "#E4EAE8"))
    static let textPrimary   = Color(UIColor.adaptive(dark: "#FFFFFF",  light: "#0D1514"))
    static let textSecondary = Color(UIColor.adaptive(dark: "#8A9693",  light: "#4D6B62"))

    // MARK: Semantic colours
    //
    // Every colour here is ONE token with a light and a dark value. Each pair
    // keeps the hue and saturation and moves only lightness, so the app reads
    // as the same product in both themes: vivid on the dark ground, deeper on
    // the light one, where a vivid colour on white looks washed out and fails
    // as text. Ratios are measured AFTER rounding to hex, against the white card
    // (light) and the #222827 card (dark).
    //
    // The history this replaces: separate text/fill tokens per colour (accent vs
    // accentFill, red vs redFill, flowOut), plus fixed dark-mode hexes pasted
    // into views. Light mode ended up with three greens and nine reds on screen.

    /// THE green — brand, money in, success, primary actions.
    /// Dark #30D158 (the iPhone charging green, 7.41:1) · light #1D8637
    /// (same 135° hue and 64% saturation, 4.65:1).
    static let accent  = Color(UIColor.adaptive(dark: "#30D158", light: "#1D8637"))
    static let green   = accent

    /// THE red — money out, errors, destructive actions, over-budget.
    /// Dark #FF5A52 (4.88:1) · light #D92D20 (4.83:1). Both sit on systemRed's
    /// hue, the red Apple tunes to sit beside its green.
    static let red     = Color(UIColor.adaptive(dark: "#FF5A52", light: "#D92D20"))

    /// Kept as names so call sites read by role; they ARE the tokens above.
    /// A fill and its text colour are the same value now — what changed is the
    /// label on top (`onVividFill`), which inverts with the theme.
    static let accentFill = accent
    static let redFill    = red
    static let flowIn     = accent
    static let flowOut    = red

    static let orange  = Color(UIColor.adaptive(dark: "#FB923C", light: "#B55304"))  // 6.62 / 5.00
    static let blue    = Color(UIColor.adaptive(dark: "#38BDF8", light: "#0676A8"))  // 7.00 / 5.04
    static let purple  = Color(UIColor.adaptive(dark: "#A78BFA", light: "#784CF7"))  // 5.51 / 5.03
    static let teal    = Color(UIColor.adaptive(dark: "#06B6D4", light: "#047A8F"))  // 6.17 / 5.02
    /// Category and chart hues. None of them is red or green: those two mean
    /// money out and money in, and a coral "Food" circle beside every expense
    /// is how the list came to read as a wall of warnings.
    static let amber   = Color(UIColor.adaptive(dark: "#FBBF24", light: "#956C03"))  // 8.98 / 4.75
    static let indigo  = Color(UIColor.adaptive(dark: "#818CF8", light: "#5664F6"))  // 5.03 / 4.62
    static let fuchsia = Color(UIColor.adaptive(dark: "#E879F9", light: "#C60AE3"))  // 6.09 / 4.61
    static let slate   = Color(UIColor.adaptive(dark: "#94A3B8", light: "#617592"))  // 5.85 / 4.70

    /// Decorative glow — the voice orb and the halo under a live mic. The one
    /// green allowed to stay bright in light mode, because it is light, not
    /// ink: it carries no information on its own (the orb speaks by moving),
    /// and a deep green glow reads as a smudge. Never text, icon or fill.
    static let voiceGlow = Color(uiColor: .systemGreen)

    /// The track behind a green progress bar: a quiet surface in both modes.
    /// Deep green on #E4EAE8 is 3.81:1; #30D158 on #2A3330 is 6.4:1.
    static let accentTrack = Color(UIColor.adaptive(dark: "#2A3330", light: "#E4EAE8"))

    /// Text and icons ON any solid semantic fill — green, red, orange, blue,
    /// purple, teal, or a category colour. Fills are deep in light mode and
    /// vivid in dark, so the label inverts: white in light (4.65:1 on green,
    /// 4.83:1 on red), near-black in dark (9.16:1 on green, 6.03:1 on red).
    static let onVividFill = Color(UIColor.adaptive(dark: "#0D1514", light: "#FFFFFF"))
    static let onSolid     = onVividFill
}

// MARK: - Layout

/// Width-driven layout rules.
///
/// The app used to branch on `userInterfaceIdiom == .pad`, which is the wrong
/// question on a foldable: the iPhone Duo reports `.phone` on both panels, so
/// the iPad path never ran and a single phone column simply stretched.
///
///     iPhone 17          393 x 852 pt
///     iPhone 17 Pro Max  440 x 956 pt
///     Duo, folded        466 x 678 pt   ← wider than any classic iPhone,
///                                          and 278 pt shorter
///     Duo, unfolded      626 x 890 pt   ← 42% wider than the widest iPhone
///
/// Asking about width instead of identity also survives the fold happening
/// while the app is open, which an idiom check cannot observe at all.
enum AppLayout {
    /// The widest classic iPhone. Past this, a single column of full-width
    /// cards stops reading as a phone layout and starts looking like a
    /// stretched one — line lengths grow past comfortable reading, and card
    /// content floats in whitespace.
    static let phoneContentMaxWidth: CGFloat = 440
}

extension View {
    /// Caps content at phone width and centres it, leaving the background to
    /// span the full panel. On every classic iPhone this is a no-op; on the
    /// Duo it is what stops the layout from stretching.
    func phoneWidthCapped() -> some View {
        frame(maxWidth: AppLayout.phoneContentMaxWidth)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - UIColor Adaptive Helper

extension UIColor {
    static func adaptive(dark: String, light: String) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }

    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:  (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                  blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:  (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255,
                  blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
