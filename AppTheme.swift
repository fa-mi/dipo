import SwiftUI

// MARK: - Theme

struct AppTheme {
    static let bg            = Color(UIColor.adaptive(dark: "#1A1F1E", light: "#F2F4F3"))
    static let cardDark      = Color(UIColor.adaptive(dark: "#222827", light: "#FFFFFF"))
    static let cardMid       = Color(UIColor.adaptive(dark: "#2A3330", light: "#E4EAE8"))
    static let textPrimary   = Color(UIColor.adaptive(dark: "#FFFFFF",  light: "#0D1514"))
    static let textSecondary = Color(UIColor.adaptive(dark: "#8A9693",  light: "#4D6B62"))
    static let accent  = Color(hex: "#1DB87A")
    static let green   = Color(hex: "#1DB87A")
    static let red     = Color(hex: "#FF5B5B")
    static let orange  = Color(hex: "#FB923C")
    static let blue    = Color(hex: "#38BDF8")
    static let purple  = Color(hex: "#A78BFA")
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
