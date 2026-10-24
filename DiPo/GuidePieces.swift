import SwiftUI

// MARK: - Pieces of a setup guide
//
// The walkthroughs for what DiPo can't set up from inside the app (Back Tap,
// the notification automation) share one look: a card that says what you get,
// numbered steps on a rail, callouts for what's worth knowing, and a button
// that opens Shortcuts.

struct GuideStep: Identifiable {
    let id: Int
    let title: String
    let body: String
    let glyph: String
}

/// What the finished setup feels like, before the steps that earn it.
struct GuideHero: View {
    let title: String
    let message: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(message)
                .font(.system(.subheadline))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
            .stroke(tint.opacity(0.25), lineWidth: 1))
    }
}

struct GuideSectionLabel: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }
}

/// One numbered list with a connecting rail. The rail is real information:
/// these steps only work in order.
struct GuideStepList: View {
    let steps: [GuideStep]
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 13) {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle().fill(tint.opacity(0.14))
                                .frame(width: 30, height: 30)
                            Text("\(step.id)")
                                .font(.system(.footnote, weight: .bold))
                                .foregroundStyle(tint)
                        }
                        if step.id != steps.count {
                            Rectangle()
                                .fill(tint.opacity(0.18))
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Image(systemName: step.glyph)
                                .font(.system(.caption, weight: .semibold))
                                .foregroundStyle(tint)
                            Text(step.title)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        Text(step.body)
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, step.id == steps.count ? 0 : 20)
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

struct GuideCallout: View {
    let title: String
    let message: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

/// Opens Shortcuts, where the rest of the setup happens.
struct GuideShortcutsButton: View {
    let title: String
    /// `shortcuts://` opens the app; `shortcuts://create-shortcut` a new shortcut.
    var url = "shortcuts://"

    var body: some View {
        Button {
            HapticManager.shared.tap()
            if let url = URL(string: url) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward.app.fill").font(.system(.subheadline))
                Text(title).font(.system(.subheadline, weight: .semibold))
            }
            .foregroundStyle(AppTheme.onVividFill)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
