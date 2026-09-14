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
    // Built around DiPo's original emerald, #1DB87A — the green of its first
    // buttons, chosen back over every alternative tried since: #008049 read as
    // dull, and systemGreen (135°, yellow-leaning) read as cheap lime on white.
    // The problem with light mode was the HUE, not the lightness.
    //
    // Everything else is set to sit beside it: one lightness band in light mode
    // (≈3.9:1 on white) so no colour looks heavier or muddier than the green,
    // and each dark value keeps its hue with the lightness the dark ground needs.
    // Ratios measured after rounding to hex, on the white card (light) and the
    // #222827 card (dark).
    //
    // Trade-off, chosen knowingly: the green is 2.56:1 on white, and white
    // labels on it are 2.56:1 too — the look of the original design. The
    // other colours stay at ≈3.9:1.

    /// THE green — brand, money in, success, primary actions. Same value in
    /// both themes: 2.56:1 on white · 5.85:1 on the dark card.
    static let accent  = Color(hex: "#1DB87A")
    static let green   = accent

    /// THE red — money out, errors, destructive actions, over-budget. A cool,
    /// slightly crimson red (358°) to pair with the emerald's 156°; the
    /// orange-leaning red it replaces fought it.
    /// Light #E5484D (3.91:1) · dark #FF6166 (5.11:1).
    static let red     = Color(UIColor.adaptive(dark: "#FF6166", light: "#E5484D"))

    /// Kept as names so call sites read by role; they ARE the tokens above.
    /// A fill and its text colour are the same value now — what changed is the
    /// label on top (`onVividFill`), which inverts with the theme.
    static let accentFill = accent
    static let redFill    = red
    static let flowIn     = accent
    static let flowOut    = red

    static let orange  = Color(UIColor.adaptive(dark: "#FB923C", light: "#CF5F04"))  // 6.62 / 3.97
    static let blue    = Color(UIColor.adaptive(dark: "#38BDF8", light: "#0789C3"))  // 7.00 / 3.91
    static let purple  = Color(UIColor.adaptive(dark: "#A78BFA", light: "#8B66F8"))  // 5.51 / 3.92
    static let teal    = Color(UIColor.adaptive(dark: "#06B6D4", light: "#058DA4"))  // 6.17 / 3.92
    /// Category and chart hues. None of them is red or green: those two mean
    /// money out and money in, and a coral "Food" circle beside every expense
    /// is how the list came to read as a wall of warnings.
    static let amber   = Color(UIColor.adaptive(dark: "#FBBF24", light: "#A67803"))  // 8.98 / 3.96
    static let indigo  = Color(UIColor.adaptive(dark: "#818CF8", light: "#6673F6"))  // 5.03 / 3.93
    static let fuchsia = Color(UIColor.adaptive(dark: "#E879F9", light: "#D819F5"))  // 6.09 / 3.91
    static let slate   = Color(UIColor.adaptive(dark: "#94A3B8", light: "#6E829F"))  // 5.85 / 3.92

    /// Decorative glow — the voice orb and the halo under a live mic. The one
    /// green allowed to stay bright in light mode, because it is light, not
    /// ink: it carries no information on its own (the orb speaks by moving),
    /// and a deep green glow reads as a smudge. Never text, icon or fill.
    static let voiceGlow = Color(uiColor: .systemGreen)

    /// The track behind a green progress bar: a quiet surface in both modes.
    static let accentTrack = Color(UIColor.adaptive(dark: "#2A3330", light: "#E4EAE8"))

    /// Text and icons ON any solid semantic fill — green, red, orange, blue,
    /// purple, teal, or a category colour. White in light mode, as the original
    /// buttons were (2.56:1 on green, ≈3.9:1 on the rest); near-black in dark,
    /// where the fills are bright (7.22:1 on green, 6.31:1 on red).
    static let onVividFill = Color(UIColor.adaptive(dark: "#0D1514", light: "#FFFFFF"))
    static let onSolid     = onVividFill
}

// MARK: - Radius

/// Corner radii. The app had 20 different values; 14 and 16 were each used
/// ~145 times for the same kind of surface. Five steps, each for a size of
/// thing, so nesting reads right (an inner element is always one step smaller).
/// Radii of 6pt and below are left as literals: thin progress bars and tick
/// marks, where the radius is geometry, not style.
enum AppRadius {
    /// Small chips, tags, tiny tiles.
    static let xs: CGFloat = 8
    /// Icon tiles, pills inside cards, text-field accessories.
    static let sm: CGFloat = 12
    /// Text fields, list rows, inner cards.
    static let md: CGFloat = 16
    /// Cards, primary buttons, form sections.
    static let lg: CGFloat = 20
    /// Hero cards, card faces, large surfaces.
    static let xl: CGFloat = 24
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
