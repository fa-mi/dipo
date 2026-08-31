import AppIntents
import Foundation

// MARK: - Ask DiPo Voice Shortcut
//
// Back Tap cannot be claimed by an app. It is an Accessibility setting the user
// configures in Settings → Accessibility → Touch → Back Tap, and the actions it
// offers are system ones plus whatever Shortcuts exist on the device. So the
// only supported route to "double-tap the back of the phone → talk to DiPo" is
// to publish an App Shortcut and let the user bind it there.
//
// `openAppWhenRun` brings DiPo to the front; the notification below tells
// MainTabView to open Ask DiPo already listening, so the whole gesture is
// tap-tap-speak with nothing to press.
struct AskDiPoVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "Log with Voice"
    static var description = IntentDescription(
        "Opens DiPo and starts listening so you can log a transaction just by saying it."
    )
    /// Must be a stored property on the type for the app to be foregrounded.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Posted rather than stored: MainTabView may not exist yet on a cold
        // launch, so it re-reads the pending flag on appear as well.
        QuickVoiceRoute.shared.pending = true
        NotificationCenter.default.post(name: .requestOpenVoiceEntry, object: nil)
        return .result()
    }
}

/// Survives the gap between the intent firing and the UI being ready. On a cold
/// launch the notification is posted before any view is listening, so
/// MainTabView also checks this flag when it appears and clears it on use.
@MainActor
final class QuickVoiceRoute {
    static let shared = QuickVoiceRoute()
    var pending = false
    private init() {}

    /// Reads and clears in one step, so a pending request can never fire twice.
    func consume() -> Bool {
        defer { pending = false }
        return pending
    }
}

struct DiPoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskDiPoVoiceIntent(),
            phrases: [
                "Log a transaction in \(.applicationName)",
                "Catat transaksi di \(.applicationName)",
                "\(.applicationName) voice",
            ],
            shortTitle: "Log with Voice",
            systemImageName: "mic.fill"
        )
    }
}
