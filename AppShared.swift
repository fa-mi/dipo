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
    /// Defaults to the normal keyboard so every existing caller is untouched.
    var keyboard: UIKeyboardType = .default
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .font(.system(.subheadline))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(focused ? AppTheme.accent.opacity(0.6) : Color.clear, lineWidth: 1.5)
                )
                .focused($focused)
        }
        .padding(.horizontal, 22)
    }
}

// MARK: - Action List Sheet

/// One row in an `ActionListSheet`.
struct ActionItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    var detail: String? = nil
    var tint: Color = AppTheme.blue
    var destructive: Bool = false
    let action: () -> Void
}

/// What a ⋯ button opens, everywhere: the thing being acted on at the top,
/// then its actions as rows with an icon and — where the verb alone does not
/// say it — what the action does. Destructive actions sit in their own group
/// at the bottom, away from the thumb's path to the everyday ones.
///
/// Replaces system action sheets (bare verbs, no icons, a style from outside
/// the app). The action runs after the sheet has left, because most actions
/// open another sheet and iOS drops one presented mid-dismissal.
struct ActionListSheet: View {
    let icon: String
    var iconTint: Color = AppTheme.accent
    let title: String
    var subtitle: String? = nil
    let items: [ActionItem]

    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 420

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(AppTheme.onVividFill)
                    .frame(width: 46, height: 46)
                    .background(iconTint, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)

            group(items.filter { !$0.destructive })
            let danger = items.filter(\.destructive)
            if !danger.isEmpty { group(danger) }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 + 24 }
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.bg)
        .presentationCornerRadius(28)
    }

    private func group(_ rows: [ActionItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
                if i > 0 {
                    Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, 62)
                }
                Button {
                    HapticManager.shared.tap()
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { item.action() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(item.destructive ? AppTheme.onVividFill : item.tint)
                            .frame(width: 36, height: 36)
                            .background(item.destructive ? AppTheme.red : item.tint.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: AppRadius.sm))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(item.destructive ? AppTheme.red : AppTheme.textPrimary)
                            if let detail = item.detail {
                                Text(detail)
                                    .font(.system(.caption))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 6)
                        if !item.destructive {
                            Image(systemName: "chevron.right")
                                .font(.system(.caption, weight: .semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }
}

// MARK: - Hit Target

extension View {
    /// Grows the tappable area to Apple's 44×44pt minimum WITHOUT changing the
    /// layout: pad out, claim that padded rectangle as the hit shape, then pad
    /// back in. A 36pt circle keeps looking like a 36pt circle while a thumb
    /// that lands 4pt outside it still counts.
    func hitTarget(_ visualSize: CGFloat, minimum: CGFloat = 44) -> some View {
        let inset = max(0, (minimum - visualSize) / 2)
        return padding(inset)
            .contentShape(Rectangle())
            .padding(-inset)
    }
}

// MARK: - Icon Field

/// A labelled text field with a glyph inside it.
///
/// `SheetField` puts a bare box under a label. The glyph is not decoration: on
/// a form where six boxes stack vertically and all of them look alike, it is
/// what lets someone find "the notes one" without reading every label on the
/// way down.
struct IconField: View {
    let label: String
    let icon: String
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    /// Appended to the label in lighter type — for fields that are safe to skip.
    var optionalHint: String? = nil
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                if let optionalHint {
                    Text(optionalHint)
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(.subheadline))
                    .foregroundStyle(focused ? AppTheme.accent : AppTheme.textSecondary)
                    .frame(width: 20)
                TextField(placeholder, text: $text)
                    .keyboardType(keyboard)
                    .font(.system(.subheadline))
                    .foregroundStyle(AppTheme.textPrimary)
                    .focused($focused)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 15)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(focused ? AppTheme.accent.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
            .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

// MARK: - Form Section Label

/// The heading above a form section. One definition so every section on the
/// add-transaction form sits on the same baseline and weight — they had drifted
/// between 13pt secondary and 15pt primary depending on when each was written.
struct FormSectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Category Tile Picker

/// Icon-over-label category tiles, shared by the create AND edit forms so the
/// two cannot drift apart again — the edit form was still on the old pills a
/// release after the create form moved on.
///
/// Neither glyph nor label is tinted with the category colour, deliberately.
/// Ten of the sixteen category colours are bright hexes picked for dark mode;
/// against their own pale tint on a white card they measure 1.55:1 (bonus
/// #FBBF24) to 2.96:1 (health #EC4899), under the 3:1 floor for a graphic that
/// carries meaning. Selection is said four ways that do not depend on hue —
/// tinted fill, coloured border, darker glyph, heavier label — and the hue is
/// left to the fill, which only has to be told apart, not read.
struct CategoryTilePicker: View {
    let categories: [TxCategory]
    @Binding var selection: TxCategory

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories, id: \.self) { cat in
                    let on = selection == cat
                    Button {
                        HapticManager.shared.tap()
                        withAnimation(.spring(response: 0.3)) { selection = cat }
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: cat.icon)
                                .font(.system(.title3, weight: .medium))
                            Text(cat.displayLabel)
                                .font(.system(size: 11, weight: on ? .semibold : .regular))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(on ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .frame(width: 84, height: 78)
                        .background(on ? cat.color.opacity(0.16) : AppTheme.cardDark,
                                    in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg)
                            .stroke(on ? cat.color.opacity(0.65) : Color.clear, lineWidth: 1.5))
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Date & Time Fields

/// Date and time as two separate controls bound to one `Date`. A single
/// combined `.compact` picker made changing only the time a detour through a
/// calendar.
struct DateTimeFields: View {
    @Binding var date: Date

    var body: some View {
        HStack(spacing: 12) {
            box(icon: "calendar") {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.compact).labelsHidden().tint(AppTheme.accent)
            }
            box(icon: "clock") {
                DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact).labelsHidden().tint(AppTheme.accent)
            }
        }
    }

    private func box<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(.subheadline))
                .foregroundStyle(AppTheme.textSecondary)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Expand BEFORE painting: with `.frame` after `.background` the fill
        // hugged its own text and the two boxes came out different widths.
        .frame(maxWidth: .infinity)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

// MARK: - Card Swipe Picker

/// Swipe between cards — the same gesture as the card carousel on Home, so
/// there is one way to move between cards anywhere in the app. A menu hides the
/// other cards behind a tap; a pager shows that there ARE others (the dots) and
/// reaches one with the thumb already on the screen.
///
/// Used by the transaction form and the salary form. `figure` decides what each
/// face states: a balance, or the room left on a credit limit.
struct CardSwipePicker: View {
    let cards: [BankCard]
    @Binding var selectedIndex: Int
    let figure: (BankCard) -> (label: String, value: String)

    var body: some View {
        if cards.count > 1 {
            VStack(spacing: 10) {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        let f = figure(card)
                        CardFaceView(card: card, label: f.label, value: f.value)
                            .padding(.horizontal, 22)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 100)

                HStack(spacing: 5) {
                    ForEach(cards.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == selectedIndex ? AppTheme.accent : AppTheme.textSecondary.opacity(0.35))
                            .frame(width: i == selectedIndex ? 18 : 6, height: 6)
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: selectedIndex)
            }
        } else if let card = cards.first {
            let f = figure(card)
            CardFaceView(card: card, label: f.label, value: f.value)
                .frame(height: 100)
                .padding(.horizontal, 22)
        }
    }
}

/// A short card face: enough to recognise the card — its colours, name and
/// digits — plus one figure.
struct CardFaceView: View {
    let card: BankCard
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CardLabel.title(card))
                        .font(.system(.subheadline, weight: .semibold))
                        .lineLimit(1)
                    let sub = CardLabel.subtitle(card)
                    if !sub.isEmpty {
                        Text(sub)
                            .font(.system(.caption2))
                            .opacity(0.75)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if card.isDigitalWallet, let wp = WalletProvider(rawValue: card.walletProvider) {
                    Image(systemName: wp.icon)
                        .font(.system(.callout, weight: .semibold))
                        .opacity(0.9)
                } else {
                    CardNetworkLogo(network: CardNetwork.detect(from: card.cardNumber))
                        .scaleEffect(0.75, anchor: .topTrailing)
                }
            }
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.system(.caption2, weight: .medium))
                    .opacity(0.75)
                Spacer(minLength: 6)
                Text(card.isHidden ? "••••••" : value)
                    .font(.system(.body, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: AppRadius.lg))
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
                .font(.system(.subheadline))
                .foregroundStyle(tone.color)
            Text(message)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(tone.color)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.sm)
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
        try? context.delete(model: RecurringExpense.self)
        // Declared cycle intents are user-owned judgements. Left behind, the
        // NEXT person signing in on this device inherits softened verdicts they
        // never chose — the analysis quietly stops warning them.
        try? context.delete(model: CycleIntent.self)
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
        // Same reasoning as `sb_dismissed_insights` above, for the flags that
        // record which pushes already went out. Keyed by cycle/debt/day rather
        // than by user, so without this, user B inherits user A's "already
        // warned" state and hears nothing for the rest of the cycle.
        NotificationManager.clearDeliveryDedupState()
        // The widget bridge lives in the App Group container, not in
        // `UserDefaults.standard` — so none of the keys above reach it. Without
        // this, user B's Home Screen shows user A's spending.
        WidgetDataSync.clear()

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

// MARK: - Sheet Done Button
//
// Every dismissable sheet had its own idea of what "Done" looks like: 12 sat
// on the LEFT (`.cancellationAction`) and one on the right, across five colour
// treatments — textSecondary, purple, accent, and two with no colour at all.
// The grey ones in particular read as disabled.
//
// One modifier, one answer: top-RIGHT (where iOS users reach for a confirming
// action), accent green, semibold so it is unmistakably tappable.
//
// Usage:  .doneToolbar { dismiss() }

struct DoneToolbar: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    HapticManager.shared.tap()
                    action()
                } label: {
                    Text(loc("common.done"))
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                }
            }
        }
    }
}

// MARK: - Feature screens: pushed from a tab, or presented as a sheet

private struct PushedFeatureKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Set on a feature screen pushed onto a tab's NavigationStack.
    var pushedFeature: Bool {
        get { self[PushedFeatureKey.self] }
        set { self[PushedFeatureKey.self] = newValue }
    }
}

/// The root of a feature screen (Salary, Bills, Savings Goals, Budget, Debts).
///
/// The same screen is pushed from its tab and, from a few shortcuts, still
/// presented as a sheet. Pushed, it must not open a NavigationStack of its own
/// — a stack inside a stack breaks back navigation — and it keeps the system
/// bar for the back button. Presented, it needs its own stack for its titles
/// and toolbars. `pushed` is handed to the content so it can pick its bar and
/// drop its Done/Cancel button, and the flag is cleared below this point so a
/// sheet the screen opens is treated as a sheet again.
struct FeatureStack<Content: View>: View {
    @Environment(\.pushedFeature) private var pushed
    @ViewBuilder let content: (_ pushed: Bool) -> Content

    var body: some View {
        if pushed {
            content(true).environment(\.pushedFeature, false)
        } else {
            NavigationStack { content(false) }
        }
    }
}

extension View {
    /// Bar for a feature screen that draws its own large header. As a sheet the
    /// system bar is hidden; pushed, it stays for the back button and nothing
    /// else, so the header below is not repeated in it.
    @ViewBuilder
    func featureBar(pushed: Bool) -> some View {
        if pushed {
            self.navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(AppTheme.bg, for: .navigationBar)
        } else {
            self.toolbar(.hidden, for: .navigationBar)
        }
    }

    /// Marks a destination as pushed from a tab. See `FeatureStack`.
    func pushedFeature() -> some View {
        environment(\.pushedFeature, true)
    }
}

extension View {
    /// Standard top-right "Done" for a sheet. See `DoneToolbar`.
    func doneToolbar(_ action: @escaping () -> Void) -> some View {
        modifier(DoneToolbar(action: action))
    }
}
