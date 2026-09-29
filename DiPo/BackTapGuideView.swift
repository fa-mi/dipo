import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers   // for `.json` UTType in fileImporter

// Moved out of ProfileView.swift, unchanged.

// MARK: - Back Tap walkthrough

/// How to wire the two Back Tap gestures.
///
/// Everything here happens OUTSIDE DiPo, which is the whole reason this screen
/// exists. Back Tap is an Accessibility setting and cannot be claimed by an
/// app; it only offers Shortcuts. So DiPo publishes the actions and the user
/// binds them — and without a guide that chain is three apps deep and
/// invisible.
///
/// Two gestures, two lists, kept apart because they are independent setups:
/// someone may well want only one of them.
struct BackTapGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Step: Identifiable {
        let id: Int
        let title: String
        let body: String
        let glyph: String
    }

    /// Double tap → capture the payment screen.
    private var screenshotSteps: [Step] {
        [
            Step(id: 1, title: loc("backtap.s1_title"), body: loc("backtap.s1_body"),
                 glyph: "plus.square.on.square"),
            Step(id: 2, title: loc("backtap.s2_title"), body: loc("backtap.s2_body"),
                 glyph: "camera.viewfinder"),
            Step(id: 3, title: loc("backtap.s3_title"), body: loc("backtap.s3_body"),
                 glyph: "text.viewfinder"),
            Step(id: 4, title: loc("backtap.s4_title"), body: loc("backtap.s4_body"),
                 glyph: "textformat"),
            Step(id: 5, title: loc("backtap.s5_title"), body: loc("backtap.s5_body"),
                 glyph: "hand.tap.fill"),
        ]
    }

    /// Triple tap → say it out loud. Shorter because DiPo publishes this action
    /// ready-made: there is no shortcut to assemble, only one to bind.
    private var voiceSteps: [Step] {
        [
            Step(id: 1, title: loc("backtap.v1_title"), body: loc("backtap.v1_body"),
                 glyph: "square.and.arrow.down.on.square"),
            Step(id: 2, title: loc("backtap.v2_title"), body: loc("backtap.v2_body"),
                 glyph: "hand.tap.fill"),
            Step(id: 3, title: loc("backtap.v3_title"), body: loc("backtap.v3_body"),
                 glyph: "waveform"),
        ]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {

                        hero

                        sectionLabel(loc("backtap.setup_heading"), tint: AppTheme.orange)
                        stepList(screenshotSteps, tint: AppTheme.orange)

                        sectionLabel(loc("backtap.voice_heading"), tint: AppTheme.accent)
                        Text(loc("backtap.voice_intro"))
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        stepList(voiceSteps, tint: AppTheme.accent)

                        callout(loc("backtap.using_heading"), body: loc("backtap.using_body"),
                                icon: "sparkles", tint: AppTheme.accent)

                        // Stated plainly rather than buried: the parser is good,
                        // not infallible, and a wrong amount saved silently is
                        // worse than one the user was asked to confirm.
                        callout(loc("backtap.limits_heading"), body: loc("backtap.limits_body"),
                                icon: "exclamationmark.circle", tint: AppTheme.textSecondary)

                        Button {
                            HapticManager.shared.tap()
                            if let url = URL(string: "shortcuts://create-shortcut") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.forward.app.fill").font(.system(.subheadline))
                                Text(loc("backtap.open_shortcuts")).font(.system(.subheadline, weight: .semibold))
                            }
                            .foregroundStyle(AppTheme.onVividFill)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("profile.backtap"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
    }

    // MARK: Pieces

    /// What the finished gestures feel like, before the setup that earns them.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc("backtap.hero_title"))
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(loc("backtap.hero_body"))
                .font(.system(.subheadline))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
            .stroke(AppTheme.orange.opacity(0.25), lineWidth: 1))
    }

    private func sectionLabel(_ text: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    /// One numbered list with a connecting rail. The rail is real information:
    /// these steps only work in order.
    private func stepList(_ items: [Step], tint: Color) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { step in
                HStack(alignment: .top, spacing: 13) {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle().fill(tint.opacity(0.14))
                                .frame(width: 30, height: 30)
                            Text("\(step.id)")
                                .font(.system(.footnote, weight: .bold))
                                .foregroundStyle(tint)
                        }
                        if step.id != items.count {
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
                    .padding(.bottom, step.id == items.count ? 0 : 20)
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func callout(_ title: String, body: String,
                         icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(tint)
            Text(body)
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}
