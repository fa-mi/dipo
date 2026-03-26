import SwiftUI

// MARK: - Wall-E App Logo
// WallELogo() = full icon with dark background (use anywhere in app)
// WallELogoMark() = just the chart mark (use on colored backgrounds)
// TabLogoButton() = the center tab bar button

struct WallELogo: View {
    var size: CGFloat = 52
    var showBackground: Bool = true

    var body: some View {
        ZStack {
            if showBackground {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(LinearGradient(
                        colors: [Color(hex: "#1A2E2A"), Color(hex: "#0D1F1C")],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size, height: size)
                    .shadow(color: Color(hex: "#1DB87A").opacity(0.35), radius: size * 0.18, y: size * 0.06)
            }
            WallELogoMark(size: size * 0.62)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Logo Mark (ascending bars + trend line)

struct WallELogoMark: View {
    var size: CGFloat = 32

    var body: some View {
        Canvas { ctx, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height

            let barW: CGFloat      = w * 0.18
            let gap: CGFloat       = w * 0.055
            let barHeights: [CGFloat] = [h * 0.38, h * 0.56, h * 0.74, h * 0.92]
            let totalWidth         = barW * 4 + gap * 3
            let startX             = (w - totalWidth) / 2

            // Draw bars
            for (i, barH) in barHeights.enumerated() {
                let x    = startX + CGFloat(i) * (barW + gap)
                let y    = h * 0.88 - barH
                let rect = CGRect(x: x, y: y, width: barW, height: barH)
                let path = Path(roundedRect: rect, cornerRadius: barW * 0.35)
                let alpha = 0.55 + Double(i) * 0.15
                ctx.fill(path, with: .color(Color(hex: "#1DB87A").opacity(alpha)))
            }

            // Draw trend line
            var line = Path()
            let pts: [CGPoint] = [
                CGPoint(x: startX + barW / 2,            y: h * 0.72),
                CGPoint(x: startX + (barW + gap) + barW / 2, y: h * 0.55),
                CGPoint(x: startX + (barW + gap) * 2 + barW / 2, y: h * 0.38),
                CGPoint(x: startX + (barW + gap) * 3 + barW, y: h * 0.18)
            ]
            line.move(to: pts[0])
            for pt in pts.dropFirst() { line.addLine(to: pt) }
            ctx.stroke(line, with: .color(.white.opacity(0.9)),
                       style: StrokeStyle(lineWidth: w * 0.06, lineCap: .round, lineJoin: .round))

            // Arrow head
            let tip = pts.last!
            var arrow = Path()
            arrow.move(to: CGPoint(x: tip.x - w * 0.07, y: tip.y + w * 0.1))
            arrow.addLine(to: tip)
            arrow.addLine(to: CGPoint(x: tip.x - w * 0.1, y: tip.y + w * 0.03))
            ctx.stroke(arrow, with: .color(.white.opacity(0.9)),
                       style: StrokeStyle(lineWidth: w * 0.06, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Tab Bar Center Button

struct TabLogoButton: View {
    let action: () -> Void
    var isEnabled: Bool = true

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(isEnabled
                        ? LinearGradient(colors: [Color(hex: "#1DB87A"), Color(hex: "#159960")],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [AppTheme.textSecondary.opacity(0.3), AppTheme.textSecondary.opacity(0.2)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 52, height: 52)
                    .shadow(color: isEnabled ? Color(hex: "#1DB87A").opacity(0.5) : .clear, radius: 14, y: 4)

                if isEnabled {
                    WallELogoMark(size: 28)
                } else {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
