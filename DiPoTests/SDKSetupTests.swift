import XCTest
@testable import DiPo

/// Are the outside SDKs wired in right?
///
/// DiPo leans on three SDKs it doesn't own: Firebase (sign-in, Firestore,
/// push, crash reports), Google Sign-In and RevenueCat (Royal and credit
/// purchases). Each one only works if the app hands it the right file, key
/// or URL scheme, and a mistake there compiles fine and fails only on a
/// phone: Google sign-in that never comes back to the app, pushes that
/// never arrive, a purchase screen that stays empty.
///
/// These run inside the real app as the tests start it, with the bundle and
/// Info.plist a build carries, and need no network. FirebaseEmulatorTests
/// goes one step further and sends real requests through the SDKs.
@MainActor
final class SDKSetupTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// GoogleService-Info.plist as it ships in the app bundle.
    private func googleService() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
                                "GoogleService-Info.plist is not in the app bundle: Firebase can't start")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func info(_ key: String) -> Any? {
        Bundle.main.object(forInfoDictionaryKey: key)
    }

    // MARK: A test run stays off production

    /// XCTest's launch of the app is recognised, and nothing in it reaches
    /// the real services: RevenueCat is never configured (no customer added
    /// to its dashboard), crash reports and push registration are off,
    /// Analytics never runs (no experiment fetch from Google, no screen
    /// counts), and no anonymous account is made in the real Firebase project.
    func testATestRunStaysOffProduction() {
        XCTAssertTrue(RunContext.isUnderTest, "the app did not notice it was launched by XCTest")
        XCTAssertFalse(RunContext.isOnline)
        XCTAssertFalse(SDKProbe.revenueCatConfigured, "RevenueCat was configured with the real key in a test run")
        XCTAssertFalse(SDKProbe.crashReportsOn, "a test run would send crash reports to the real dashboard")
        XCTAssertFalse(SDKProbe.pushAutoInitOn, "a test run would register a push token")
        XCTAssertTrue(SDKProbe.analyticsDeactivated,
                      "Firebase Analytics ran in this test run and fetched its experiments from Google: the build has no FIREBASE_ANALYTICS_COLLECTION_DEACTIVATED (ios.yml writes it on CI)")
        XCTAssertFalse(ScreenAnalytics.shared.isEnabled, "a test run would count screens in the real Firestore")
        XCTAssertFalse(SDKProbe.signedInToRealFirebase, "the app signed in to the real Firebase project")
    }

    /// With RevenueCat unconfigured, the calls the app makes on launch and on
    /// returning to the foreground do nothing rather than crash.
    func testPurchasesWaitForRevenueCat() {
        PremiumManager.shared.checkActiveSubscription()
        PremiumManager.shared.fetchPricing()
        PremiumManager.shared.restorePurchases()
        XCTAssertFalse(SDKProbe.revenueCatConfigured)
    }

    // MARK: Firebase

    /// The Firebase file belongs to this app and to DiPo's project. A file
    /// for another bundle id starts Firebase but every request is refused.
    func testFirebaseFileIsForThisApp() throws {
        let gs = try googleService()
        XCTAssertEqual(gs["BUNDLE_ID"] as? String, Bundle.main.bundleIdentifier)
        XCTAssertEqual(gs["PROJECT_ID"] as? String, "dipo-fd6c9")
        for key in ["API_KEY", "GOOGLE_APP_ID", "GCM_SENDER_ID", "CLIENT_ID", "REVERSED_CLIENT_ID"] {
            XCTAssertFalse((gs[key] as? String ?? "").isEmpty, "\(key) is empty")
        }
    }

    /// Firebase was started at launch, and from that file.
    func testFirebaseStartedFromThatFile() throws {
        let gs = try googleService()
        let fb = try XCTUnwrap(SDKProbe.firebase, "FirebaseApp.configure() did not run at launch")
        XCTAssertEqual(fb.projectID, gs["PROJECT_ID"] as? String)
        XCTAssertEqual(fb.bundleID, Bundle.main.bundleIdentifier)
        XCTAssertEqual(fb.googleAppID, gs["GOOGLE_APP_ID"] as? String)
    }

    /// Analytics stays off unless the backend turns it on (ScreenAnalytics).
    /// The Firebase file says off, and the release build writes the switch
    /// Firebase reads before any code runs.
    func testAnalyticsIsOffByDefault() throws {
        XCTAssertEqual(try googleService()["IS_ANALYTICS_ENABLED"] as? Bool, false)
        let release = try String(contentsOf: root.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        XCTAssertTrue(release.contains("Add :FIREBASE_ANALYTICS_COLLECTION_ENABLED bool false"),
                      "release.yml no longer turns Analytics off in the shipped Info.plist")
    }

    // MARK: Push notifications (Firebase Messaging)

    /// Push tokens and notifications reach the app's delegate. Without the
    /// first, the admin panel has no token to send support replies to.
    func testPushReachesTheApp() throws {
        XCTAssertTrue(SDKProbe.pushTokensReachTheApp, "Messaging's delegate is not the AppDelegate")
        XCTAssertTrue(SDKProbe.notificationsReachTheApp, "UNUserNotificationCenter's delegate is not the AppDelegate")
        // A push needs the entitlement too; iOS gives no token without it.
        let url = root.appendingPathComponent("DiPo/DiPo.entitlements")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        XCTAssertNotNil(plist?["aps-environment"], "DiPo.entitlements has no aps-environment: no push token")
    }

    // MARK: Google Sign-In

    /// Google Sign-In was given the client from the Firebase file, and the
    /// Info.plist copy agrees with it.
    func testGoogleSignInHasOneClient() throws {
        let clientID = try XCTUnwrap(googleService()["CLIENT_ID"] as? String)
        XCTAssertEqual(SDKProbe.googleClientID, clientID, "GIDSignIn was not configured at launch")
        if let plistID = info("GIDClientID") as? String {
            XCTAssertEqual(plistID, clientID, "GIDClientID in Info.plist is a different client")
        }
    }

    /// After the Google page, iOS returns to DiPo through a URL scheme made
    /// of the reversed client id. Without it the sign-in sheet never closes.
    /// The widget's `dipo://` links need theirs too.
    func testGoogleSignInCanComeBackToTheApp() throws {
        let reversed = try XCTUnwrap(googleService()["REVERSED_CLIENT_ID"] as? String)
        let types = info("CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = Set(types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] })
        XCTAssertTrue(schemes.contains(reversed), "Info.plist has no URL scheme for Google Sign-In")
        XCTAssertTrue(schemes.contains("dipo"), "Info.plist has no dipo:// scheme for the widget")
    }

    // MARK: RevenueCat

    /// The app carries RevenueCat's public Apple key. A secret key ("sk_")
    /// must never be in an app, anyone can read it out of the download; a
    /// Test Store key ("test_") crashes a release build at launch.
    func testRevenueCatHasThePublicAppleKey() throws {
        let key = try XCTUnwrap(info("REVENUECAT_API_KEY") as? String, "REVENUECAT_API_KEY is missing from Info.plist")
        XCTAssertTrue(key.hasPrefix("appl_"), "REVENUECAT_API_KEY is not a public Apple key (appl_…)")
        XCTAssertFalse(key.hasPrefix("sk_"))
    }

    /// RevenueCat is configured once, in RootView. A second configure (once
    /// in App.init with a test key) crashed the app within milliseconds.
    func testRevenueCatIsConfiguredOnce() throws {
        var calls: [String] = []
        // Hidden folders (.git, and .spm where CI keeps the SDKs' own sources) are skipped.
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", !url.path.contains("/DiPoTests/") else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                if !code.hasPrefix("//"), code.contains("Purchases.configure(") {
                    calls.append(url.lastPathComponent)
                }
            }
        }
        XCTAssertEqual(calls, ["RootView.swift"])
    }
}
