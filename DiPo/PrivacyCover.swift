import SwiftUI

// MARK: - Privacy cover
//
// iOS photographs the screen when the app leaves the foreground and shows
// that picture in the app switcher. With the app lock on, the lock only
// appears on the way back in (AuthViewModel.handleScenePhase), so the
// picture was of balances and transactions, visible to anyone swiping
// through the switcher of a shared phone. This covers the app whenever it
// isn't active, for users who turned the lock on.
//
// No animation: the cover must already be drawn when the snapshot is taken.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            DiPoLogo(size: 72)
        }
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
    }
}
