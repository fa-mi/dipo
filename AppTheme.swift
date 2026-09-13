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
    // Same hues as before, now ADAPTIVE. They used to be fixed `Color(hex:)`
    // values tuned against the dark ground and then reused verbatim on the
    // light one, where every single one failed the 4.5:1 contrast threshold —
    // blue sat at 1.94:1, orange at 2.05:1, accent at 2.32:1. Light mode was
    // shipping unreadable status colours.
    //
    // The light variants keep each hue and its saturation and only drop
    // lightness until the ratio clears 4.5:1, so the app reads as the same
    // product in both themes rather than gaining a second identity.

    /// Green as TEXT or an icon sitting on the page ground. Light mode has to
    /// be dark enough to clear 4.5:1 there, which is why it cannot be neon.
    /// For the vivid one, see `accentFill` — these are two different jobs and
    /// they were fighting over one value.
    static let accent  = Color(UIColor.adaptive(dark: "#1DB87A", light: "#008049"))  // 6.51 / 4.54
    static let green   = Color(UIColor.adaptive(dark: "#1DB87A", light: "#008049"))  // 6.51 / 4.54
    /// Red as TEXT or an icon on the page ground. Light mode has to be dark
    /// enough to clear 4.5:1 there. For a red FILL see `redFill` — same split
    /// as `accent` / `accentFill`, and for the same reason.
    static let red     = Color(UIColor.adaptive(dark: "#FF5B5B", light: "#DC0000"))  // 5.48 / 4.70

    /// Red as a solid FILL — the Record button, delete chips, over-budget bars.
    ///
    /// Unchanged from the original palette in BOTH modes, because darkening it
    /// for light mode was never the fill's problem: what matters on a fill is
    /// the text sitting ON it. Left alone, the `red` darkening leaked into
    /// every red button and turned a soft salmon into an alarm colour that no
    /// longer matched the category chips beside it, which carry their own
    /// fixed hex.
    ///
    /// Paired with `onVividFill`: near-white text on this was 2.76:1 — the
    /// original palette was failing here too, just quietly.
    static let redFill = Color(hex: "#FF5B5B")
    static let orange  = Color(UIColor.adaptive(dark: "#FB923C", light: "#B55304"))  // 7.37 / 4.51
    /// Decorative glow — the voice orb and the halo under a live mic.
    ///
    /// Deliberately outside the contrast rules every token above obeys, and
    /// allowed to be, because it carries no information on its own: the orb
    /// says "I can hear you" by MOVING, and the halo by pulsing. Nothing here
    /// is ever the only cue for anything, so it is free to be as bright as it
    /// likes — which is the point, since a compliance-safe green rendered at
    /// 12% opacity reads as a smudge rather than a light.
    ///
    /// Never use it for text, an icon, or a control's fill.
    /// Money in / money out — a matched PAIR, not two unrelated colours.
    ///
    /// `flowIn` is the green of the iPhone battery while it charges: literally
    /// `UIColor.systemGreen` (#34C759 light / #30D158 dark), so it tracks the
    /// system rather than approximating it. `flowOut` is `systemRed`, the red
    /// Apple tunes alongside it — lightness 49% vs 59%, both fully saturated —
    /// so the two halves of an income/expense comparison read as equals. Our
    /// `red` (#DC0000, 43% lightness, pure hue) is deliberately darker for
    /// small text and looked heavy and flat beside the charging green.
    ///
    /// Trade-off, measured: on a white card these are 2.22:1 and 3.55:1 as
    /// text, below the 4.5 used for `accent`/`red`. In dark mode they are
    /// 7.41:1 and 4.40:1. Use them for figures set large and bold, and for
    /// solid badges — put `onVividFill` glyphs on them (≈9:1 and ≈5.6:1).
    static let flowIn  = Color(uiColor: .systemGreen)
    static let flowOut = Color(uiColor: .systemRed)
    static let voiceGlow = Color(UIColor.adaptive(dark: "#2BFF9E", light: "#00C86E"))

    static let blue    = Color(UIColor.adaptive(dark: "#38BDF8", light: "#0676A8"))  // 7.79 / 4.58
    static let purple  = Color(UIColor.adaptive(dark: "#A78BFA", light: "#784CF7"))  // 6.13 / 4.54
    /// The one slot the Profile feature list had left. Purple, green, orange,
    /// red and sky are all already spoken for there, so a row that needs to be
    /// told apart from its neighbours has nowhere else to go.
    static let teal    = Color(UIColor.adaptive(dark: "#06B6D4", light: "#047A8F"))  // 6.87 / 4.52

    /// Green as a solid FILL — buttons, bars, chips — where the contrast that
    /// matters is the text sitting ON it (`onSolid`, 5.52:1 here), not the
    /// fill against the page. That frees it to stay vivid: it only owes the
    /// page the 3:1 a UI component needs to have a discernible boundary, and
    /// it clears that at 3.04:1.
    ///
    /// Light mode looked washed out because one token was doing both jobs, so
    /// the darkness that text legibility demanded was dragging every button
    /// and progress bar down with it.
    /// Light mode runs NEON here, and deliberately below the 3:1 a UI
    /// component owes the page. That threshold protects a control whose
    /// boundary is the only thing identifying it — which is not this. Every
    /// accentFill surface is a large shape carrying a glyph or a label, and
    /// the contrast that matters on those is the text sitting on it: 9.08:1.
    ///
    /// The four 6–8pt indicator dots that DID rely on the boundary were moved
    /// to `accent`, where they read better than they ever did here.
    static let accentFill = Color(UIColor.adaptive(dark: "#1DB87A", light: "#00D07A"))

    /// The track behind an `accentFill` progress bar.
    ///
    /// Light mode runs DARK here on purpose. `accentFill` sits at mid
    /// luminance, so a pale track leaves it muddy — against the old
    /// `cardMid` (#E4EAE8) the bright green managed only 2.46:1, and going
    /// pale the other way tops out at 3.00:1 even at pure white. A dark track
    /// gives 3.18:1 and is what makes the fill read as lit rather than
    /// printed. Dark mode already had the separation and is unchanged.
    static let accentTrack = Color(UIColor.adaptive(dark: "#2A3330", light: "#404744"))

    /// Text and icons sitting on a VIVID fill — `accentFill` or `redFill`.
    ///
    /// Unlike `onSolid` this does NOT invert with the theme, because both of
    /// those fills are bright in BOTH modes, so the text on them is dark in
    /// both: 7.22:1 on dark-mode green, 5.52:1 on light-mode green, 6.08:1 on
    /// red. Using `onSolid` here would put white on a light fill — 3.35:1 on
    /// green, 2.76:1 on red — which is exactly the failure this token set
    /// exists to prevent.
    static let onVividFill = Color(hex: "#0D1514")

    /// Text and icons sitting ON a solid `red` / `orange`
    /// fill — which is the opposite problem from text on the page ground.
    ///
    /// `.white` was used for this everywhere and never worked: white on the
    /// green button is 2.56:1, on orange 2.26:1. The fills are bright in dark
    /// mode and dark in light mode, so the text on them has to invert the
    /// other way:
    ///
    ///     dark theme,  fill #1DB87A : white 2.56:1  ·  near-black 7.72:1
    ///     light theme, fill #147E53 : white 5.07:1  ·  near-black 3.90:1
    static let onSolid = Color(UIColor.adaptive(dark: "#0D1514", light: "#FFFFFF"))
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
