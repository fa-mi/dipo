import Foundation
import FirebaseCrashlytics
import FirebaseMessaging

// MARK: - Run context: a real launch, or a test run
//
// DiPoTests runs inside the app: XCTest launches DiPo on a simulator and
// loads the tests into it. That launch used to be a full one: it signed in
// to the real Firebase project anonymously, opened Firestore listeners on
// production, configured RevenueCat with the real key (one more customer in
// its dashboard), fetched exchange rates and holidays, and could send crash
// reports from the test machine. Every CI run, several times a day.
//
// Under tests the SDKs are still configured locally, so SDKSetupTests can
// check how they are set up, but nothing calls the real services. A real
// phone never takes these branches.
enum RunContext {

    /// True when XCTest started this process. XCTest sets these variables in
    /// the host app's environment at launch, before any app code runs.
    nonisolated static let isUnderTest: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }()

    /// Talks to Firebase, RevenueCat and the other online services.
    nonisolated static var isOnline: Bool { !isUnderTest }

    private static let mutedKey = "sdkSwitchesMutedForTests"

    /// Crash reporting and push auto-registration keep their switches on the
    /// device. Off for a test run; back on at the next real launch of that
    /// same simulator, so a developer's own runs still report. On a phone that
    /// never ran tests this does nothing: both stay at Firebase's default (on).
    /// Call right after FirebaseApp.configure().
    static func applySDKSwitches() {
        let defaults = UserDefaults.standard
        if isUnderTest {
            Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(false)
            Messaging.messaging().isAutoInitEnabled = false
            defaults.set(true, forKey: mutedKey)
        } else if defaults.bool(forKey: mutedKey) {
            Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
            Messaging.messaging().isAutoInitEnabled = true
            defaults.removeObject(forKey: mutedKey)
        }
    }
}
