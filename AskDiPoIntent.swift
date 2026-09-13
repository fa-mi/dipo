import AppIntents
import Foundation
import UIKit

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
        AppShortcut(
            intent: LogFromScreenshotIntent(),
            phrases: [
                "Log from screenshot in \(.applicationName)",
                "Catat dari tangkapan layar di \(.applicationName)",
            ],
            shortTitle: "Log from Screenshot",
            systemImageName: "text.viewfinder"
        )
    }
}


// MARK: - Log from a screenshot
//
// The gesture the user actually wants is: pay with QRIS → double-tap the back
// of the phone → the payment screen is captured, DiPo opens, the amount and
// merchant are already filled in.
//
// Back Tap is not something an app can claim. It is an Accessibility setting,
// and the only third-party actions it offers are Shortcuts. So the app's job
// is to publish an action worth binding, and the Shortcut supplies the
// screenshot:
//
//     Take Screenshot  →  Log from Screenshot (DiPo)
//
// Taking the screenshot inside the Shortcut rather than asking DiPo to read
// the most recent photo matters: it keeps the image out of the photo library
// and avoids requesting Photos access for something the user handed us
// directly.
struct LogFromScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "Log from Screenshot"
    static var description = IntentDescription(
        "Reads a payment screenshot and opens DiPo with the amount and merchant already filled in."
    )
    static var openAppWhenRun: Bool = true

    /// `connectToPreviousIntentResult` is what makes Shortcuts wire the
    /// preceding action's output straight into this field. Without it the
    /// parameter shows "Choose" and sits empty, and an unfilled required
    /// parameter makes the shortcut try to ASK — which from Back Tap has
    /// nowhere to happen, so the run dies silently right after the screenshot
    /// is taken and the app is never opened.
    @Parameter(title: "Screenshot",
               supportedTypeIdentifiers: ["public.image"],
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var screenshot: IntentFile

    /// Shows the bound image inline in the Shortcuts editor, so a parameter
    /// that failed to connect is visible at a glance instead of hiding in a
    /// collapsed row.
    static var parameterSummary: some ParameterSummary {
        Summary("Log from \(\.$screenshot)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let image = UIImage(data: screenshot.data) else {
            throw QuickScanIntentError.unreadableImage
        }
        QuickScanRoute.shared.pending = image
        // Straight to the scanner. This used to post
        // `.requestOpenAddTransaction`, which opened the full transaction form
        // and then covered it with the scanner — one rendered screen and one
        // extra animation between the gesture and the thing the user came for.
        NotificationCenter.default.post(name: .requestOpenScanFromShortcut, object: nil)
        return .result()
    }
}

enum QuickScanIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unreadableImage

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unreadableImage:
            return "That file could not be read as an image. Put a Take Screenshot action directly before this one."
        }
    }
}

/// Carries the screenshot across the gap between the intent firing and the
/// transaction sheet existing. Same reason as `QuickVoiceRoute`: on a cold
/// launch nothing is listening yet, so the sheet also drains this on appear.
@MainActor
final class QuickScanRoute {
    static let shared = QuickScanRoute()
    var pending: UIImage?
    private init() {}

    /// Reads and clears in one step, so one screenshot can never be scanned
    /// twice if both the notification and the on-appear check fire.
    func consume() -> UIImage? {
        defer { pending = nil }
        return pending
    }
}

/// `UIImage` has no identity, and `fullScreenCover(item:)` needs one. Wrapping
/// it also means the cover cannot outlive the image it is showing.
struct ScanPayload: Identifiable {
    let id = UUID()
    let image: UIImage
}
