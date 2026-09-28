import Foundation
import FirebaseCore
#if canImport(FirebaseAppCheck)
import FirebaseAppCheck
#endif

// MARK: - Firebase App Check
//
// An ID token says WHO is calling. App Check says WHAT is calling: a genuine
// DiPo build on a real iPhone, attested by Apple (App Attest), rather than a
// script replaying requests with a stolen or invented identity. Firestore
// attaches the token by itself once App Check is set up, and the Worker reads
// it from `X-Firebase-AppCheck` (WorkerAuth.headers()).
//
// Everything here compiles to nothing until the FirebaseAppCheck product is
// linked to the DiPo target — that is a project-file change, made in Xcode:
//
//   1. DiPo target → General → Frameworks, Libraries → + → FirebaseAppCheck
//      (from the firebase-ios-sdk package already in the project).
//   2. DiPo target → Signing & Capabilities → + Capability → App Attest.
//   3. Firebase Console → App Check → register the iOS app with App Attest.
//      Leave enforcement OFF at first; watch the metrics there and the
//      Worker's "app-check:" log lines, then turn it on (Console per service,
//      REQUIRE_APP_CHECK in the Worker).
//
// Debug and simulator builds use the debug provider. It prints a debug token
// to the console on first launch; add it under App Check → Manage debug
// tokens, or those builds are refused once enforcement is on.
enum AppCheckSetup {
    /// Call before `FirebaseApp.configure()`.
    static func install() {
        #if canImport(FirebaseAppCheck)
        AppCheck.setAppCheckProviderFactory(DiPoAppCheckProviderFactory())
        #endif
    }

    /// The current App Check token, or nil (not set up, or it couldn't be
    /// fetched — offline with an expired token, say). A cached token is reused
    /// and only refreshed when it is about to expire, so this rarely costs a
    /// round trip.
    static func token() async -> String? {
        #if canImport(FirebaseAppCheck)
        return try? await AppCheck.appCheck().token(forcingRefresh: false).token
        #else
        return nil
        #endif
    }
}

#if canImport(FirebaseAppCheck)
/// App Attest on devices; the debug provider on the simulator and in Debug
/// builds, which App Attest can't serve. Firebase calls this off the main
/// actor, hence `nonisolated`.
nonisolated final class DiPoAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if targetEnvironment(simulator) || DEBUG
        return AppCheckDebugProvider(app: app)
        #else
        return AppAttestProvider(app: app)
        #endif
    }
}
#endif
