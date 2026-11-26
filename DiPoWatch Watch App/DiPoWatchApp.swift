import SwiftUI

/// DiPo on Apple Watch: what is left of the period, and logging cash spending
/// in three taps. The iPhone does the counting and the saving (WatchStore).
@main
struct DiPoWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}
