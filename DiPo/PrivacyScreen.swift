import SwiftUI
import UIKit

// MARK: - Privacy screen (app-switcher cover)
//
// When the app leaves the foreground, iOS captures a snapshot of whatever is on
// screen and shows it in the app switcher. For a finance app that means balances,
// cards and transactions sit exposed in the multitasking preview. Banking apps
// avoid this by covering the window with a branded splash the moment they resign
// active — the snapshot then shows the logo, not the data.
//
// We do it at the UIWindow level (not a SwiftUI overlay) on purpose: an overlay
// on the root view does NOT cover a presented sheet, so a half-filled form would
// still leak into the snapshot. A dedicated window above `.alert` covers the
// whole screen — sheets included — while staying below system dialogs (Face ID,
// permission prompts), which the OS always renders above app windows.

/// The full-screen brand cover. Deliberately fixed to the dark brand look, like
/// a launch screen, so it reads as "DiPo" regardless of the user's theme.
struct PrivacyScreenView: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#12211E"), Color(hex: "#0A1613")],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                DiPoLogo(size: 100)
                Text("DiPo")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .tracking(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Owns the overlay window and shows/hides it as the app changes activation.
@MainActor
final class PrivacyScreenManager {
    static let shared = PrivacyScreenManager()
    private init() {}

    private var window: UIWindow?

    /// Cover the screen. Called as the app is about to resign active — before the
    /// switcher snapshot is taken — so the logo lands in the snapshot.
    func show() {
        guard window == nil else { return }
        // Pin the cover to the same scene as the visible key window.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: {
            $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
        }) ?? scenes.first else { return }

        let host = UIHostingController(rootView: PrivacyScreenView())
        host.view.backgroundColor = .clear

        let w = UIWindow(windowScene: scene)
        // Above the app's own alert windows, but system dialogs (Face ID,
        // permission prompts) are rendered by the OS above this and stay visible.
        w.windowLevel = .alert + 1
        w.isUserInteractionEnabled = false   // never swallow a touch
        w.rootViewController = host
        w.isHidden = false
        window = w
    }

    /// Reveal the app again once it's active. Fades so the return feels smooth.
    func hide() {
        guard let w = window else { return }
        window = nil
        UIView.animate(withDuration: 0.22, animations: { w.alpha = 0 }, completion: { _ in
            w.isHidden = true
        })
    }
}

// MARK: - Wiring
//
// `AppDelegate` (in FinanceAppMain.swift) doesn't implement these lifecycle
// hooks, so we add them here rather than editing that file.

extension AppDelegate {
    func applicationWillResignActive(_ application: UIApplication) {
        PrivacyScreenManager.shared.show()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        PrivacyScreenManager.shared.hide()
    }
}
