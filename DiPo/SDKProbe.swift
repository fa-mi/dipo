#if DEBUG
import Foundation
import UserNotifications
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging
import FirebaseCrashlytics
import GoogleSignIn
import RevenueCat

// MARK: - SDK probe (Debug builds only)
//
// DiPoTests checks the outside SDKs DiPo is built on: Firebase, Google
// Sign-In, RevenueCat. The SDKs are linked to the app, not to the test
// target, so the tests reach them through this file. It is compiled only
// into Debug builds (the ones tests run), never into what ships.
//
// Two parts:
//   • What the running app set up: read-only looks at the SDK objects after
//     launch (SDKSetupTests).
//   • A Firebase that talks only to the local emulator (FirebaseEmulatorTests).

enum SDKProbe {

    /// Firebase as the app configured it at launch, or nil if it never was.
    static var firebase: (projectID: String?, bundleID: String, googleAppID: String)? {
        guard let o = FirebaseApp.app()?.options else { return nil }
        return (o.projectID, o.bundleID, o.googleAppID)
    }

    /// The OAuth client Google Sign-In was given at launch.
    static var googleClientID: String? {
        GIDSignIn.sharedInstance.configuration?.clientID
    }

    /// A new push token reaches the app (it is saved for the admin panel).
    static var pushTokensReachTheApp: Bool {
        Messaging.messaging().delegate is AppDelegate
    }

    /// A notification that arrives while DiPo is open is shown, and a tap on
    /// one is routed, by the app.
    static var notificationsReachTheApp: Bool {
        UNUserNotificationCenter.current().delegate is AppDelegate
    }

    // What a test run left switched off (DiPo/RunContext.swift).
    static var revenueCatConfigured: Bool { Purchases.isConfigured }
    static var crashReportsOn: Bool { Crashlytics.crashlytics().isCrashlyticsCollectionEnabled() }
    static var pushAutoInitOn: Bool { Messaging.messaging().isAutoInitEnabled }
    /// Signed in to the app's real Firebase project, as opposed to the
    /// emulator's separate one.
    static var signedInToRealFirebase: Bool { Auth.auth().currentUser != nil }
}

// MARK: - Firebase on the local emulator

/// A second Firebase app that talks only to the Firebase Local Emulator
/// Suite, a copy of Auth and Firestore running on the test machine.
///
/// Its project id starts with "demo-", which the emulators treat as
/// local-only: a demo project has no real counterpart, so nothing here can
/// reach DiPo's real Firebase project or anyone's data. The app's own
/// Firebase (FirebaseApp.app()) is left alone.
final class EmulatorFirebase {

    static let projectID = "demo-dipo"

    let auth: Auth
    let db: Firestore

    /// The emulator, when the run started one: `DIPO_AUTH_EMULATOR` and
    /// `DIPO_FIRESTORE_EMULATOR` hold "host:port" (CI sets both, as
    /// TEST_RUNNER_ variables). Nil otherwise, and the emulator tests skip.
    /// Made once: Firestore's settings can't change after first use.
    static let shared: EmulatorFirebase? = {
        let env = ProcessInfo.processInfo.environment
        guard let authHost = env["DIPO_AUTH_EMULATOR"].flatMap(HostPort.init),
              let storeHost = env["DIPO_FIRESTORE_EMULATOR"].flatMap(HostPort.init),
              let base = FirebaseApp.app()?.options else { return nil }
        return EmulatorFirebase(auth: authHost, firestore: storeHost, base: base)
    }()

    private init(auth authHost: HostPort, firestore storeHost: HostPort, base: FirebaseOptions) {
        let name = "dipo-emulator"
        if FirebaseApp.app(name: name) == nil {
            // The app id and sender only need a valid shape; the emulator
            // ignores them. The project is the demo one.
            let options = FirebaseOptions(googleAppID: base.googleAppID, gcmSenderID: base.gcmSenderID)
            options.projectID = Self.projectID
            options.apiKey = base.apiKey
            options.bundleID = base.bundleID
            FirebaseApp.configure(name: name, options: options)
        }
        let app = FirebaseApp.app(name: name)!

        auth = Auth.auth(app: app)
        auth.useEmulator(withHost: authHost.host, port: authHost.port)

        db = Firestore.firestore(app: app)
        let settings = db.settings
        settings.host = "\(storeHost.host):\(storeHost.port)"
        settings.isSSLEnabled = false
        // Nothing kept on the phone between runs: every read below is the
        // emulator's answer, not a cached one.
        settings.cacheSettings = MemoryCacheSettings()
        db.settings = settings
    }

    /// Signs in the way the app does at launch, without an account.
    func signInAnonymously() async throws -> (uid: String, isAnonymous: Bool) {
        let user = try await auth.signInAnonymously().user
        return (user.uid, user.isAnonymous)
    }

    func signOut() throws { try auth.signOut() }

    /// Writes a support ticket where the app writes one.
    func writeTicket(_ data: [String: Any], id: String) async throws {
        try await db.collection("support_tickets").document(id).setData(data)
    }

    /// The person's tickets, found with the app's own query and read with the
    /// app's own decoder, straight from the emulator.
    func myTickets(uid: String) async throws -> [SupportTicket] {
        let snap = try await FirebaseSupportService.ticketsQuery(in: db, uid: uid).getDocuments(source: .server)
        return snap.documents.map { FirebaseSupportService.decodeTicket(id: $0.documentID, data: $0.data()) }
    }

    /// How each field of a stored ticket is typed in Firestore: "timestamp",
    /// "string", "int", "bool", "null" or "other". The admin panel and the
    /// Worker read these documents too, and expect these types.
    func storedTypes(ofTicket id: String) async throws -> [String: String] {
        let snap = try await db.collection("support_tickets").document(id).getDocument(source: .server)
        var types: [String: String] = [:]
        for (key, value) in snap.data() ?? [:] {
            switch value {
            case is Timestamp:    types[key] = "timestamp"
            case is String:       types[key] = "string"
            case let n as NSNumber:
                // NSNumber carries both; a bool is CFBoolean underneath.
                types[key] = CFGetTypeID(n) == CFBooleanGetTypeID() ? "bool" : "int"
            case is NSNull:       types[key] = "null"
            default:              types[key] = "other"
            }
        }
        return types
    }

    func deleteTicket(_ id: String) async throws {
        try await db.collection("support_tickets").document(id).delete()
    }

    /// "127.0.0.1:8080" → host and port.
    private struct HostPort {
        let host: String
        let port: Int
        init?(_ text: String) {
            let parts = text.split(separator: ":")
            guard parts.count == 2, let port = Int(parts[1]), !parts[0].isEmpty else { return nil }
            host = String(parts[0])
            self.port = port
        }
    }
}
#endif
