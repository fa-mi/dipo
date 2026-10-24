import SwiftUI

// MARK: - Notification automation walkthrough

/// How to have payments logged from bank and wallet notifications.
///
/// Like Back Tap, the setup happens outside DiPo: iOS 27's Shortcuts has the
/// "when a notification arrives" trigger, DiPo publishes the action it runs
/// (LogFromNotificationIntent), and only the user can join the two. Without a
/// guide the chain is invisible, and the two settings that decide whether it
/// works at all, running without asking and running while locked, are easy
/// to miss.
struct NotificationLogGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private var steps: [GuideStep] {
        [
            GuideStep(id: 1, title: loc("notiflog.s1_title"), body: loc("notiflog.s1_body"),
                      glyph: "plus.app"),
            GuideStep(id: 2, title: loc("notiflog.s2_title"), body: loc("notiflog.s2_body"),
                      glyph: "bell.badge"),
            GuideStep(id: 3, title: loc("notiflog.s3_title"), body: loc("notiflog.s3_body"),
                      glyph: "bolt.fill"),
            GuideStep(id: 4, title: loc("notiflog.s4_title"), body: loc("notiflog.s4_body"),
                      glyph: "plus.circle"),
            GuideStep(id: 5, title: loc("notiflog.s5_title"), body: loc("notiflog.s5_body"),
                      glyph: "checkmark.circle"),
        ]
    }

    /// The iOS version, on an iPhone too old for the trigger. Said before the
    /// steps, which can't be followed yet.
    private var olderIOS: String? {
        let needed = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(needed) ? nil : UIDevice.current.systemVersion
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {

                        GuideHero(title: loc("notiflog.hero_title"), message: loc("notiflog.hero_body"),
                                  tint: AppTheme.accent)

                        if let version = olderIOS {
                            GuideCallout(title: loc("notiflog.needs_ios_heading"),
                                         message: String(format: loc("notiflog.needs_ios"), version),
                                         icon: "exclamationmark.circle", tint: AppTheme.orange)
                        }

                        GuideSectionLabel(text: loc("notiflog.setup_heading"), tint: AppTheme.accent)
                        GuideStepList(steps: steps, tint: AppTheme.accent)

                        GuideCallout(title: loc("notiflog.skip_heading"), message: loc("notiflog.skip_body"),
                                     icon: "hand.raised.fill", tint: AppTheme.accent)

                        GuideCallout(title: loc("notiflog.twice_heading"), message: loc("notiflog.twice_body"),
                                     icon: "square.on.square", tint: AppTheme.orange)

                        GuideCallout(title: loc("notiflog.bank_heading"), message: loc("notiflog.bank_body"),
                                     icon: "bell", tint: AppTheme.textSecondary)

                        GuideCallout(title: loc("notiflog.privacy_heading"), message: loc("notiflog.privacy_body"),
                                     icon: "lock.fill", tint: AppTheme.textSecondary)

                        GuideShortcutsButton(title: loc("notiflog.open_shortcuts"))
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("profile.notiflog"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
    }
}
