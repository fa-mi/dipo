import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers   // for `.json` UTType in fileImporter

// Moved out of ProfileView.swift. Its pieces (hero, steps, callouts) are in
// GuidePieces.swift.

// MARK: - Back Tap walkthrough

/// How to wire the two Back Tap gestures.
///
/// Everything here happens OUTSIDE DiPo, which is the whole reason this screen
/// exists. Back Tap is an Accessibility setting and cannot be claimed by an
/// app; it only offers Shortcuts. So DiPo publishes the actions and the user
/// binds them — and without a guide that chain is three apps deep and
/// invisible.
///
/// Two gestures and a notification automation, three lists, kept apart
/// because they are independent setups: someone may well want only one.
struct BackTapGuideView: View {
    @Environment(\.dismiss) private var dismiss

    /// Double tap → capture the payment screen.
    private var screenshotSteps: [GuideStep] {
        [
            GuideStep(id: 1, title: loc("backtap.s1_title"), body: loc("backtap.s1_body"),
                      glyph: "plus.square.on.square"),
            GuideStep(id: 2, title: loc("backtap.s2_title"), body: loc("backtap.s2_body"),
                      glyph: "camera.viewfinder"),
            GuideStep(id: 3, title: loc("backtap.s3_title"), body: loc("backtap.s3_body"),
                      glyph: "text.viewfinder"),
            GuideStep(id: 4, title: loc("backtap.s4_title"), body: loc("backtap.s4_body"),
                      glyph: "textformat"),
            GuideStep(id: 5, title: loc("backtap.s5_title"), body: loc("backtap.s5_body"),
                      glyph: "hand.tap.fill"),
        ]
    }

    /// Triple tap → say it out loud. Shorter because DiPo publishes this action
    /// ready-made: there is no shortcut to assemble, only one to bind.
    private var voiceSteps: [GuideStep] {
        [
            GuideStep(id: 1, title: loc("backtap.v1_title"), body: loc("backtap.v1_body"),
                      glyph: "square.and.arrow.down.on.square"),
            GuideStep(id: 2, title: loc("backtap.v2_title"), body: loc("backtap.v2_body"),
                      glyph: "hand.tap.fill"),
            GuideStep(id: 3, title: loc("backtap.v3_title"), body: loc("backtap.v3_body"),
                      glyph: "waveform"),
        ]
    }

    /// No gesture at all: from iOS 27 Shortcuts can run DiPo's action when a
    /// bank or wallet app sends a notification (LogFromNotificationIntent).
    /// The payment waits under Review like everything else read for you.
    /// iOS 27 builds this inside a new shortcut: its Automation actions put
    /// the trigger at the top, and DiPo's action goes under it.
    private var notificationSteps: [GuideStep] {
        [
            GuideStep(id: 1, title: loc("backtap.n1_title"), body: loc("backtap.n1_body"),
                      glyph: "bell.badge"),
            GuideStep(id: 2, title: loc("backtap.n2_title"), body: loc("backtap.n2_body"),
                      glyph: "plus.circle"),
            GuideStep(id: 3, title: loc("backtap.n3_title"), body: loc("backtap.n3_body"),
                      glyph: "lock.open"),
        ]
    }

    /// The iOS version, on an iPhone too old for the notification trigger.
    /// Said before those steps, which can't be followed yet.
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

                        GuideHero(title: loc("backtap.hero_title"), message: loc("backtap.hero_body"),
                                  tint: AppTheme.orange)

                        GuideSectionLabel(text: loc("backtap.setup_heading"), tint: AppTheme.orange)
                        GuideStepList(steps: screenshotSteps, tint: AppTheme.orange)

                        GuideSectionLabel(text: loc("backtap.voice_heading"), tint: AppTheme.accent)
                        Text(loc("backtap.voice_intro"))
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        GuideStepList(steps: voiceSteps, tint: AppTheme.accent)

                        GuideSectionLabel(text: loc("backtap.notif_heading"), tint: AppTheme.blue)
                        Text(loc("backtap.notif_intro"))
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let version = olderIOS {
                            GuideCallout(title: loc("backtap.notif_needs_ios_heading"),
                                         message: String(format: loc("backtap.notif_needs_ios"), version),
                                         icon: "exclamationmark.circle", tint: AppTheme.orange)
                        }
                        GuideStepList(steps: notificationSteps, tint: AppTheme.blue)

                        GuideCallout(title: loc("backtap.using_heading"), message: loc("backtap.using_body"),
                                     icon: "sparkles", tint: AppTheme.accent)

                        // Stated plainly rather than buried: the parser is good,
                        // not infallible, and a wrong amount saved silently is
                        // worse than one the user was asked to confirm.
                        GuideCallout(title: loc("backtap.limits_heading"), message: loc("backtap.limits_body"),
                                     icon: "exclamationmark.circle", tint: AppTheme.textSecondary)

                        GuideShortcutsButton(title: loc("backtap.open_shortcuts"),
                                             url: "shortcuts://create-shortcut")
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
}
