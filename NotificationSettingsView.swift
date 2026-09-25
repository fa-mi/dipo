import SwiftUI

// MARK: - Notification Settings
//
// One row per category, each saying what it will actually send. The subtitles
// matter more than the switches: "Reminders 0–3 days before a due date" lets
// someone decide, where a bare "Debt" only lets them guess.
struct NotificationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var prefs = NotificationPreferences.shared
    /// Local mirror so the toggles animate immediately; `UserDefaults` is not
    /// observable, so binding straight to it would not redraw the row.
    @State private var enabled: [String: Bool] = [:]

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        intro
                        VStack(spacing: 0) {
                            ForEach(Array(NotificationPreferences.Kind.allCases.enumerated()),
                                    id: \.element.id) { index, kind in
                                row(kind)
                                if index < NotificationPreferences.Kind.allCases.count - 1 {
                                    Divider().background(AppTheme.cardMid).padding(.leading, 64)
                                }
                            }
                        }
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        footer
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                }
            }
            .navigationTitle(loc("notifpref.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
        .onAppear {
            enabled = Dictionary(uniqueKeysWithValues:
                NotificationPreferences.Kind.allCases.map { ($0.rawValue, prefs.isEnabled($0)) })
        }
    }

    private var intro: some View {
        Text(loc("notifpref.intro"))
            .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ kind: NotificationPreferences.Kind) -> some View {
        let isOn = Binding(
            get: { enabled[kind.rawValue] ?? true },
            set: { newValue in
                enabled[kind.rawValue] = newValue
                prefs.setEnabled(kind, newValue)
            }
        )
        return HStack(alignment: .top, spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.sm).fill(kind.tint.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: kind.icon)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(kind.tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(loc(kind.titleKey))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc(kind.subtitleKey))
                    .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(1.5)
            }
            Spacer(minLength: 8)
            // A bell in the knob, not the category's own icon: that one is
            // already on the left saying WHICH notification this is, and the
            // switch's job is to say whether it rings. The track keeps the
            // accent for every row — "on" should look the same everywhere, and
            // the category tints are text colours that go dark in light mode.
            DiPoSwitch(isOn: isOn, onIcon: "bell.fill", offIcon: "bell.slash.fill")
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle").font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary).padding(.top, 1)
            Text(loc("notifpref.footer"))
                .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(1.5)
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark.opacity(0.6), in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}
