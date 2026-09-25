import SwiftUI

// MARK: - Day / night switch
//
// Appearance used to be three flat segments — Light · System · Dark. It worked,
// and it looked like a form field for one of the few choices in a finance app
// people actually enjoy making. This is a small scene instead: a sky that runs
// from afternoon to night, the sun sinking behind clouds on one side, a moon
// among stars on the other.
//
// Only two of the three modes live in the switch, because a switch has two
// positions and pretending otherwise is how a control starts lying. "Follow
// system" keeps its own row underneath. While that row is on, this scene is
// still shown — it is the truth about what is on screen — but muted, because
// then it is reporting a state rather than offering a choice.

struct DayNightToggle: View {

    /// Which side the scene is on. Not a binding: the tap is handled by the
    /// owner, which also has to decide what a tap means while the system is in
    /// charge, and a binding here would invite two sources of truth.
    let isDark: Bool
    /// False while "follow system" is on.
    var isLive: Bool = true
    var onTap: () -> Void

    private let trackW: CGFloat = 124
    private let trackH: CGFloat = 58
    private let inset: CGFloat = 6

    private var knobSize: CGFloat { trackH - inset * 2 }
    private var travel: CGFloat { (trackW - knobSize - inset * 2) / 2 }

    var body: some View {
        ZStack {
            sky
            clouds
            stars
            knob.offset(x: isDark ? travel : -travel)
        }
        .frame(width: trackW, height: trackH)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        // Drained of colour rather than dimmed to nothing: the user still needs
        // to read which way the system has gone.
        .saturation(isLive ? 1 : 0.4)
        .opacity(isLive ? 1 : 0.75)
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
        .animation(.spring(response: 0.5, dampingFraction: 0.72), value: isDark)
        .animation(.easeOut(duration: 0.25), value: isLive)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(loc("profile.appearance"))
        .accessibilityValue(loc(isDark ? "appearance.dark_mode" : "appearance.light_mode"))
    }

    // MARK: Sky

    private var sky: some View {
        LinearGradient(
            colors: isDark
                ? [Color(hex: "#1C2B3E"), Color(hex: "#070B12")]
                : [Color(hex: "#63B8F5"), Color(hex: "#2A76D2")],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Soft stacked blobs at the trailing edge, the way the reference piles
    /// them up. They leave to the right as night arrives rather than fading on
    /// the spot, so the sky reads as moving rather than redrawing.
    private var clouds: some View {
        ZStack {
            blob(34, x: 30, y: 14, opacity: 0.30)
            blob(26, x: 44, y: 8,  opacity: 0.45)
            blob(30, x: 52, y: 18, opacity: 0.85)
            blob(22, x: 38, y: 22, opacity: 0.75)
        }
        .offset(x: isDark ? 70 : 0)
        .opacity(isDark ? 0 : 1)
    }

    private func blob(_ size: CGFloat, x: CGFloat, y: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(.white.opacity(opacity))
            .frame(width: size, height: size)
            .offset(x: x, y: y)
    }

    private var stars: some View {
        ZStack {
            star(7, -42, -13)
            star(5, -30,   7)
            star(6, -16, -17)
            star(4,  -8,  11)
            star(5, -36,  18)
            star(4, -22,  -3)
        }
        .foregroundStyle(.white)
        .opacity(isDark ? 1 : 0)
        // They arrive with the night rather than sitting there waiting for it.
        .offset(x: isDark ? 0 : -14)
    }

    private func star(_ size: CGFloat, _ x: CGFloat, _ y: CGFloat) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size + 3, weight: .black))
            .offset(x: x, y: y)
    }

    // MARK: Knob

    private var knob: some View {
        ZStack {
            sun.opacity(isDark ? 0 : 1).scaleEffect(isDark ? 0.72 : 1)
            moon.opacity(isDark ? 1 : 0).scaleEffect(isDark ? 1 : 0.72)
        }
        .frame(width: knobSize, height: knobSize)
    }

    private var sun: some View {
        Circle()
            .fill(RadialGradient(
                colors: [Color(hex: "#F4F09B"), Color(hex: "#CBDE2E")],
                center: .topLeading, startRadius: 1, endRadius: knobSize))
            .shadow(color: Color(hex: "#CBDE2E").opacity(0.5), radius: 9)
    }

    private var moon: some View {
        ZStack {
            Circle().fill(LinearGradient(
                colors: [Color(hex: "#EDEBE1"), Color(hex: "#B8B6AA")],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            crater(10, -6, -5)
            crater(7,    7,  4)
            crater(5,   -2, 10)
        }
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }

    private func crater(_ size: CGFloat, _ x: CGFloat, _ y: CGFloat) -> some View {
        Circle()
            .fill(Color(hex: "#A5A396").opacity(0.7))
            .frame(width: size, height: size)
            .offset(x: x, y: y)
    }
}
