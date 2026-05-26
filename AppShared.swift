import SwiftUI

// MARK: - App Color Scheme
// Single source of truth for the user's appearance preference.
// Usage: .preferredColorScheme(appColorScheme())
func appColorScheme() -> ColorScheme? {
    switch UserDefaults.standard.string(forKey: "appearance_mode") ?? "system" {
    case "dark":  return .dark
    case "light": return .light
    default:      return nil
    }
}

// MARK: - Scale Button Style

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Card Wave Background
// The decorative curved highlight on all card visuals.
// Usage: CardWaveBackground(accentColor: network.accentColor)

struct CardWaveBackground: View {
    var accentColor: Color
    var cornerRadius: CGFloat = 22

    var body: some View {
        GeometryReader { g in
            Path { p in
                p.move(to: .init(x: g.size.width * 0.32, y: 0))
                p.addCurve(
                    to: .init(x: g.size.width, y: g.size.height * 0.7),
                    control1: .init(x: g.size.width * 0.74, y: -12),
                    control2: .init(x: g.size.width + 8, y: g.size.height * 0.32)
                )
                p.addLine(to: .init(x: g.size.width, y: 0))
                p.closeSubpath()
            }
            .fill(LinearGradient(
                colors: [accentColor.opacity(0.3), accentColor.opacity(0.05)],
                startPoint: .top, endPoint: .bottom
            ))
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - Int Ordinal Extension
// Formats an integer as an ordinal string: 1 → "1st", 22 → "22nd", etc.

extension Int {
    var ordinal: String {
        let suffix: String
        switch self % 10 {
        case 1 where self % 100 != 11: suffix = "st"
        case 2 where self % 100 != 12: suffix = "nd"
        case 3 where self % 100 != 13: suffix = "rd"
        default:                        suffix = "th"
        }
        return "\(self)\(suffix)"
    }
}

// MARK: - Sheet Field
// Styled label + text field used in all bottom sheets across the app.
// Usage: SheetField(label: "Name", placeholder: "Enter name", text: $name)

struct SheetField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            TextField(placeholder, text: $text)
                .font(.system(size: 15))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(focused ? AppTheme.accent.opacity(0.6) : Color.clear, lineWidth: 1.5)
                )
                .focused($focused)
        }
        .padding(.horizontal, 22)
    }
}

// MARK: - Animated Appearance Wrapper
// Eliminates the repeated @State var appeared + onAppear pattern across views.
//
// Usage (replaces the boilerplate in every view):
//
//   AnimatedAppearance { appeared in
//       MyContent(appeared: appeared)
//   }
//
//   // With custom delay:
//   AnimatedAppearance(delay: 0.3) { appeared in
//       MyContent(appeared: appeared)
//   }
//
// For views that need to reset their animation when re-entering (e.g. tab pages),
// pass a `resetOn` value — the animation restarts whenever that value changes.

struct AnimatedAppearance<Content: View>: View {
    @State private var appeared = false
    let delay: Double
    let content: (Bool) -> Content

    init(delay: Double = 0.1, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.delay = delay
        self.content = content
    }

    var body: some View {
        content(appeared)
            .onAppear {
                // Reset so re-appearing views (e.g. tab switches) animate again
                appeared = false
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(delay)) {
                    appeared = true
                }
            }
    }
}

// MARK: - Safe Calendar Helpers
// Calendar.date(from:) and date(byAdding:) return Optional — force-unwrapping
// them crashes on pathological locale/timezone edge cases.
// These two helpers centralise the fallback to Date() so every call site
// is one word shorter AND crash-safe.

extension Calendar {
    /// Returns the date for the given components, falling back to `Date()` if
    /// the components are invalid for the current calendar/timezone.
    func safeDate(from components: DateComponents) -> Date {
        date(from: components) ?? Date()
    }

    /// Returns the date by adding the given component, falling back to `base`
    /// on arithmetic overflow (effectively impossible in practice, but silences
    /// the force-unwrap and satisfies Swift 6 strict concurrency checks).
    func safeDate(byAdding component: Calendar.Component,
                  value: Int,
                  to base: Date) -> Date {
        date(byAdding: component, value: value, to: base) ?? base
    }
}

// MARK: - Inline Banner

/// Reusable inline banner for short feedback messages (errors, warnings,
/// successes). Replaces the half-dozen ad-hoc patterns scattered across
/// sheets — plain red `Text` here, banner with icon there, no icon
/// elsewhere — that made error UX feel inconsistent. Use this for any
/// transient "something went wrong" or "saved!" affordance inside a form.
struct InlineBanner: View {
    /// Tone of the banner. Drives icon, accent color, and background tint.
    enum Tone {
        case error    // red — invalid input, failed save
        case warning  // orange — caution, needs attention
        case success  // green — confirmation
        case info     // blue — neutral informational note

        var color: Color {
            switch self {
            case .error:   return AppTheme.red
            case .warning: return AppTheme.orange
            case .success: return AppTheme.accent
            case .info:    return AppTheme.blue
            }
        }
        var icon: String {
            switch self {
            case .error:   return "exclamationmark.triangle.fill"
            case .warning: return "exclamationmark.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .info:    return "info.circle.fill"
            }
        }
    }

    let tone: Tone
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tone.icon)
                .font(.system(size: 14))
                .foregroundStyle(tone.color)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tone.color)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(tone.color.opacity(0.25), lineWidth: 1)
        )
        .transition(.opacity)
    }
}

// MARK: - Amount Input Preview

/// Helpers for showing a formatted preview ("Rp 5.000.000") beneath raw
/// amount text fields ("5000000"). We intentionally don't auto-format the
/// input itself — doing so makes the cursor jump on every keystroke and
/// breaks decimal entry on certain keyboards. A subtle preview label below
/// the field gives the user instant feedback without those gotchas.
enum AmountInputHelper {

    /// Returns a formatted preview ("Rp 5.000.000") for the given raw input
    /// or `nil` if the input doesn't yet form a parseable positive number.
    /// Caller decides whether to render the label.
    static func preview(_ raw: String, currency: String) -> String? {
        // Accept both ID-style ("5000,00") and US-style ("5000.00") decimals.
        // Strip thousand-noise the user may have typed but keep the LAST
        // separator as the decimal hint.
        let cleaned = raw.replacingOccurrences(of: " ", with: "")
        let lastDot = cleaned.lastIndex(of: ".")
        let lastComma = cleaned.lastIndex(of: ",")
        var normalized = cleaned
        if let dot = lastDot, let comma = lastComma {
            // Whichever appears LAST is the decimal — drop the other as noise.
            if comma > dot {
                normalized = cleaned.replacingOccurrences(of: ".", with: "")
                normalized = normalized.replacingOccurrences(of: ",", with: ".")
            } else {
                normalized = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if cleaned.contains(",") {
            normalized = cleaned.replacingOccurrences(of: ",", with: ".")
        }
        guard let value = Double(normalized), value > 0 else { return nil }
        return CurrencyManager.shared.formatted(value, currency: currency)
    }
}

// MARK: - User Switch Detector

import SwiftData

/// Detects when a different user signs in on this device and wipes the local
/// SwiftData store + per-device UserDefaults so the new user never sees the
/// previous user's financial data. Same user signing back in is preserved
/// (matches the sign-out copy: "Your cards and transactions are kept on
/// device").
///
/// The detector is idempotent — call `handleSignIn(userID:context:)` from
/// every sign-in code path. Internally it tracks the last-signed-in userID
/// and only wipes when it changes.
enum UserSwitchDetector {

    private static let kLastUserID = "last_signed_in_user_id_v1"

    /// Call after a successful sign-in. Compares the incoming userID to the
    /// last one we saw on this device. If different (and a previous one
    /// existed), wipes all local data so the new user starts clean.
    @MainActor
    static func handleSignIn(userID: String, context: ModelContext) {
        let previousID = UserDefaults.standard.string(forKey: kLastUserID)
        UserDefaults.standard.set(userID, forKey: kLastUserID)

        // First-ever sign-in on this device — nothing to wipe.
        guard let prev = previousID, !prev.isEmpty, prev != userID else { return }

        wipeLocalData(context: context)
    }

    /// Internal data-wipe routine. Public so the "Reset All Data" path can
    /// reuse it, but normally callers should go through `handleSignIn`.
    @MainActor
    static func wipeLocalData(context: ModelContext) {
        // SwiftData models — every user-owned schema must be listed here.
        try? context.delete(model: BankCard.self)
        try? context.delete(model: TxRecord.self)
        try? context.delete(model: SalarySchedule.self)
        try? context.delete(model: DebtRecord.self)
        try? context.delete(model: SavingsGoal.self)
        try? context.delete(model: CardBudgetConfig.self)
        try? context.save()

        // UserDefaults — anything that persists user-specific state. We DO NOT
        // touch language or appearance preferences; those are per-device.
        let keysToWipe = [
            "app_notifications_v2",     // NotificationManager queue
            "profile_photo",            // Profile avatar
            "daily_reminder_on",        // Personal reminder toggle
            // Smart Budget settings + ephemeral state
            "sb_enabled", "sb_daily", "sb_lifestyle", "sb_invest", "sb_card_id",
            // Per-user insight state — same-month dismissals and coaching
            // "seen" flags shouldn't leak between accounts. Without these,
            // user B sees user A's dismissed insights silently suppressed,
            // which feels like the engine is broken (no insights showing).
            "sb_dismissed_insights",
            "sb_seen_coaching",
            // Backup reminder state — user B shouldn't inherit user A's
            // "last backed up" timestamp; that would suppress the reminder
            // banner inappropriately on a fresh account that just got the
            // device's wiped data.
            "last_backup_export_date",
        ]
        for key in keysToWipe {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // In-memory singletons that cache state.
        SmartBudgetManager.shared.resetAllSettings()
        // Crucial: NotificationManager.shared holds the queue in a @Published
        // array. Removing the UserDefaults key alone leaves the in-memory
        // copy intact, so user A's notifications stay visible to user B
        // until app restart. clearAll() flushes both array and persisted key.
        NotificationManager.shared.clearAll()
        NotificationCenter.default.post(name: .profilePhotoDidChange, object: nil)
    }
}

// MARK: - Count-Up Number Text
//
// A currency Text that animates its value by interpolating the underlying
// Double — used for the Home card balance so the number "rolls up" on
// appear (0 → balance) and smoothly re-counts when the balance changes.
//
// How it works: conforming to `Animatable` exposes `animatableData`. When
// the bound `value` changes inside a `withAnimation`, SwiftUI interpolates
// `animatableData` frame-by-frame and re-evaluates `body` each step —
// giving a free count-up with no timers.

struct CountUpText: View, Animatable {
    /// Current (interpolated) value. Driven by `withAnimation` at the call
    /// site — see `.countUp()` usage in HomeView.
    var value: Double
    let currency: String
    /// Visual styling is left to the caller via `.font`/`.foregroundStyle`;
    /// this view only owns the number formatting + interpolation.

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        let magnitude = Swift.abs(value)
        let formatted = CurrencyManager.shared.formatted(magnitude, currency: currency)
        Text(value < 0 ? "-\(formatted)" : formatted)
    }
}

// MARK: - Gentle Float Modifier
//
// A slow, looping up-and-down drift. Used on empty-state icons so a "no
// data yet" screen feels alive rather than dead — subtle enough that it
// reads as polish, not distraction. ~2.4s per cycle, ±5pt travel.

struct GentleFloat: ViewModifier {
    @State private var lifted = false

    func body(content: Content) -> some View {
        content
            .offset(y: lifted ? -5 : 5)
            .animation(
                .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
                value: lifted
            )
            .onAppear { lifted = true }
    }
}

extension View {
    /// Slow looping vertical drift — see `GentleFloat`. Apply to empty-state
    /// icons / illustrations.
    func gentleFloat() -> some View { modifier(GentleFloat()) }
}
