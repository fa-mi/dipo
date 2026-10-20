import Foundation
import UIKit
import AuthenticationServices
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn

// MARK: - Reconnecting a reinstalled phone to its DiPo ID
//
// A reinstall keeps the Apple/Google login (it lives in the Keychain) but not
// the Firebase session, so the app comes back on a new anonymous uid. Every
// shared document is keyed to the uid — `dipoIndex/{dipoID}` still points at
// the old one, and Sync to Web uploads to an address the dashboard never
// looks up. The rules won't let the new uid take the entry over, by design:
// that is what stops anyone pointing someone else's DiPo ID at themselves.
//
// The way back is one more sign-in with the same Apple ID or Google account:
//   1. If that identity is already attached to the OLD Firebase account,
//      FirebaseAccountLinker signs into it. The uid is the old one again, so
//      the DiPo ID, Tabungan Bersama and web sync all lead here — nothing
//      moves at all.
//   2. Otherwise the identity links to the new account, and the Worker's
//      /api/dipo-id/reclaim moves the DiPo ID across. It checks the token
//      carries the identity the ID is derived from, so only the owner can.
//
// A sign-in with a DIFFERENT Apple ID or Google account changes nothing:
// it is refused before Firebase is touched, and the app's own login is left
// exactly as it was.

@MainActor
enum AccountReconnect {

    enum Outcome: Equatable {
        /// The DiPo ID now leads to this phone.
        case reconnected
        /// Signed into a different Apple ID or Google account than this DiPo ID's.
        case otherAccount
        /// The sign-in sheet was closed.
        case cancelled
        /// Network, Firebase or the Worker said no.
        case failed
    }

    static let reclaimURL = URL(string: "https://dipo-receipt-scanner.fahmi-aquinas.workers.dev/api/dipo-id/reclaim")!

    /// Which step failed, and its code: "firebase 17007", "reclaim 403
    /// identity_mismatch". Never shown: a failed run reports it to
    /// Crashlytics (see `report`).
    struct Failure: Equatable {
        let step: String
        var code = 0
        var detail: String?

        var text: String { [step, code == 0 ? nil : String(code), detail].compactMap { $0 }.joined(separator: " ") }
        /// Crashlytics titles a non-fatal by its domain and code, so the
        /// step and its code read straight off the issue list.
        var domain: String { "DiPo.AccountReconnect.\(step)" }
    }

    private static var lastFailure: Failure?

    static func run() async -> Outcome {
        let outcome = await attempt()
        if outcome == .failed { report("reconnect") }
        return outcome
    }

    /// Behind the scenes: the step that failed and its code go to Crashlytics
    /// as a non-fatal, beside the user id it already carries. The person sees
    /// only "Couldn't reconnect".
    private static func report(_ flow: String) {
        let failure = lastFailure ?? Failure(step: "unknown")
        let what = "\(flow) failed: \(failure.text)"
        CrashReporter.log("[Reconnect] \(what)")
        CrashReporter.record(NSError(domain: failure.domain, code: failure.code,
                                     userInfo: [NSLocalizedDescriptionKey: what]))
    }

    private static func attempt() async -> Outcome {
        lastFailure = nil
        let session = UserSession.shared
        guard let socialID = session.userID, !socialID.isEmpty,
              let provider = session.provider else { lastFailure = Failure(step: "login"); return .failed }

        let credential: AuthCredential
        switch await freshCredential(provider, expecting: socialID) {
        case .credential(let c): credential = c
        case .outcome(let o): return o
        }

        guard await signIn(credential) else { return .failed }

        if await indexLeadsHere() {
            await FirebaseSupportService.shared.registerUserProfile()
            return .reconnected
        }
        guard await reclaim(socialID: socialID) else { return .failed }
        guard await indexLeadsHere() else {
            if lastFailure == nil { lastFailure = Failure(step: "index", detail: "unchanged") }
            return .failed
        }
        await FirebaseSupportService.shared.registerUserProfile()
        return .reconnected
    }

    // MARK: Binding the identity in place

    enum BindOutcome: Equatable {
        /// The Firebase account on this phone carries the login's identity.
        case bound
        /// Signed into a different Apple ID or Google account than DiPo's.
        case otherAccount
        /// The sign-in sheet was closed.
        case cancelled
        /// The identity belongs to another Firebase account, and this phone's
        /// DiPo ID leads here: moving would strand what is keyed to this uid.
        case heldElsewhere
        /// Network or Firebase said no.
        case failed
    }

    /// Whether a Firebase account with these providers carries the identity
    /// DiPo is logged in with. The Worker checks the same thing in the ID
    /// token (`firebase.identities`) before it spends a Royal account's
    /// credits or analyses.
    static func identityMatches(_ socialID: String?, providers: [(providerID: String, uid: String)]) -> Bool {
        guard let socialID, !socialID.isEmpty else { return false }
        return providers.contains { ($0.providerID == "apple.com" || $0.providerID == "google.com") && $0.uid == socialID }
    }

    static var isBound: Bool {
        identityMatches(UserSession.shared.userID,
                providers: Auth.auth().currentUser?.providerData.map { (providerID: $0.providerID, uid: $0.uid) } ?? [])
    }

    /// One sign-in with the same Apple ID or Google account, linked to the
    /// Firebase account this phone is on now — the same uid, so joint
    /// accounts, shared goals and the DiPo ID stay exactly where they are.
    ///
    /// A phone can be logged into DiPo while Firebase holds only the anonymous
    /// account from launch: a login from before Firebase sign-in was added,
    /// or one whose Firebase step failed. Nothing else notices; the Worker
    /// does, because it reads whose account a request may spend from the
    /// token.
    ///
    /// When the identity is already on another Firebase account, that
    /// account is the one to return to only if the DiPo ID leads there (a
    /// reinstall, which `run()` handles too). Otherwise this one holds the
    /// history, and nothing is moved.
    static func bind() async -> BindOutcome {
        let outcome = await bindAttempt()
        if outcome == .failed { report("confirm") }
        return outcome
    }

    private static func bindAttempt() async -> BindOutcome {
        lastFailure = nil
        let session = UserSession.shared
        guard let socialID = session.userID, !socialID.isEmpty,
              let provider = session.provider else { lastFailure = Failure(step: "login"); return .failed }
        if isBound { return await refreshed() }

        let credential: AuthCredential
        switch await freshCredential(provider, expecting: socialID) {
        case .credential(let c): credential = c
        case .outcome(.cancelled): return .cancelled
        case .outcome(.otherAccount): return .otherAccount
        case .outcome: return .failed
        }

        guard let current = Auth.auth().currentUser else {
            return await signIn(credential) ? await refreshed() : .failed
        }
        switch await link(credential, to: current) {
        case .linked:
            return await refreshed()
        case .failed:
            return .failed
        case .inUse(let recovery):
            if await indexLeadsHere() { return .heldElsewhere }
            // Apple's own credential is spent once linking has tried it.
            guard let retry = FirebaseAccountLinker.retry(after: credential, recovery: recovery) else { return .failed }
            guard await signIn(retry) else { return .failed }
            var leadsHere = await indexLeadsHere()
            if !leadsHere, await reclaim(socialID: socialID) { leadsHere = await indexLeadsHere() }
            if leadsHere { await FirebaseSupportService.shared.registerUserProfile() }
            return await refreshed()
        }
    }

    private enum LinkResult {
        case linked, failed
        /// Already on another Firebase account. Firebase may hand back a
        /// credential to recover with; that is the one to sign in with.
        case inUse(AuthCredential?)
    }

    private static func link(_ credential: AuthCredential, to user: FirebaseAuth.User) async -> LinkResult {
        // Only the error crosses the continuation: it is Sendable, the
        // credential inside it is read back here.
        let failure: Error? = await withCheckedContinuation { continuation in
            user.link(with: credential) { _, error in continuation.resume(returning: error) }
        }
        guard let error = failure as NSError? else { return .linked }
        let code = AuthErrorCode(rawValue: error.code)
        lastFailure = Failure(step: "link", code: error.code)
        guard code == .credentialAlreadyInUse || code == .emailAlreadyInUse else {
            print("[Reconnect] link failed: \(error.localizedDescription)")
            return .failed
        }
        return .inUse(error.userInfo[AuthErrors.userInfoUpdatedCredentialKey] as? AuthCredential)
    }

    /// The cached ID token can predate the link, and the Worker reads the
    /// identity out of the token itself.
    private static func refreshed() async -> BindOutcome {
        guard let user = Auth.auth().currentUser,
              (try? await user.getIDTokenResult(forcingRefresh: true)) != nil else {
            lastFailure = Failure(step: "token")
            return .failed
        }
        guard isBound else {
            lastFailure = Failure(step: "bound", detail: "identity missing")
            return .failed
        }
        return .bound
    }

    // MARK: Sign-in, without touching the app's own login

    private enum Fresh {
        case credential(AuthCredential)
        case outcome(Outcome)
    }

    private static func freshCredential(_ provider: SocialProvider, expecting socialID: String) async -> Fresh {
        switch provider {
        case .apple:
            let apple = await appleSignIn()
            if apple.cancelled { return .outcome(.cancelled) }
            guard let user = apple.user, let token = apple.idToken else {
                lastFailure = Failure(step: "apple", code: apple.code ?? 0, detail: apple.code == nil ? "no token" : nil)
                return .outcome(.failed)
            }
            guard user == socialID else { return .outcome(.otherAccount) }
            return .credential(OAuthProvider.appleCredential(withIDToken: token, rawNonce: apple.nonce, fullName: nil))
        case .google:
            let google = await googleSignIn()
            if google.cancelled { return .outcome(.cancelled) }
            guard let user = google.user, let idToken = google.idToken, let access = google.accessToken else {
                lastFailure = Failure(step: "google", detail: "no token")
                return .outcome(.failed)
            }
            guard user == socialID else {
                // Leave Google signed in as the account DiPo knows, not this one.
                GIDSignIn.sharedInstance.signOut()
                return .outcome(.otherAccount)
            }
            return .credential(GoogleAuthProvider.credential(withIDToken: idToken, accessToken: access))
        }
    }

    /// Kept alive while Apple's sheet is up: the controller holds its delegate weakly.
    private static var appleCoordinator: AppleSignInCoordinator?

    /// Apple's user id, identity token and the request's raw nonce — strings,
    /// so nothing non-Sendable crosses the continuation.
    private static func appleSignIn() async -> (user: String?, idToken: String?, nonce: String?, code: Int?,
                                               cancelled: Bool) {
        await withCheckedContinuation { continuation in
            let coordinator = AppleSignInCoordinator()
            appleCoordinator = coordinator
            coordinator.onSuccess = { credential, nonce in
                appleCoordinator = nil
                let token = credential.identityToken.flatMap { String(data: $0, encoding: .utf8) }
                continuation.resume(returning: (credential.user, token, nonce, nil, false))
            }
            coordinator.onError = { error in
                appleCoordinator = nil
                // 1001 is "canceled"; the login screen also treats 1000 as a
                // dismissal, so the same here.
                let code = (error as NSError).code
                continuation.resume(returning: (nil, nil, nil, code, code == 1001 || code == 1000))
            }
            coordinator.signIn()
        }
    }

    private static func googleSignIn() async -> (user: String?, idToken: String?, accessToken: String?, cancelled: Bool) {
        guard let presenter = topViewController() else { return (nil, nil, nil, false) }
        return await withCheckedContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { result, error in
                if let error {
                    // -5 is GIDSignInError.canceled.
                    continuation.resume(returning: (nil, nil, nil, (error as NSError).code == -5))
                    return
                }
                let user = result?.user
                continuation.resume(returning: (user?.userID, user?.idToken?.tokenString,
                                                user?.accessToken.tokenString, false))
            }
        }
    }

    /// The controller on top, so Google's sheet opens over the Sync sheet
    /// rather than failing to present from the root underneath it.
    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?.rootViewController
        var top = root
        while let next = top?.presentedViewController { top = next }
        return top
    }

    private static func signIn(_ credential: AuthCredential) async -> Bool {
        let code: Int? = await withCheckedContinuation { continuation in
            FirebaseAccountLinker.signInPreservingAccount(credential, label: "Reconnect") { result, error in
                continuation.resume(returning: error.map { ($0 as NSError).code } ?? (result == nil ? -1 : nil))
            }
        }
        if let code { lastFailure = Failure(step: "firebase", code: code) }
        return code == nil
    }

    // MARK: The index, and the Worker

    /// Whether `dipoIndex/{dipoID}` leads to the account this phone is on now.
    /// A missing entry is claimed on the spot — the create rule allows it.
    private static func indexLeadsHere() async -> Bool {
        guard let dipoID = UserSession.shared.dipoID,
              let uid = Auth.auth().currentUser?.uid else { return false }
        let ref = Firestore.firestore().collection("dipoIndex").document(dipoID)
        do {
            let snap = try await ref.getDocument(source: .server)
            guard snap.exists else {
                try await ref.setData([
                    "uid": uid,
                    "socialUserID": UserSession.shared.userID ?? "",
                    "updatedAt": FieldValue.serverTimestamp(),
                ], merge: true)
                return true
            }
            return (snap.data()?["uid"] as? String) == uid
        } catch {
            print("[Reconnect] dipoIndex check failed: \(error.localizedDescription)")
            lastFailure = Failure(step: "index", code: (error as NSError).code)
            return false
        }
    }

    private static func reclaim(socialID: String) async -> Bool {
        // Forced: the cached token may predate the link, and the Worker reads
        // the Apple/Google identity out of the token itself.
        guard let user = Auth.auth().currentUser,
              let token = try? await user.getIDTokenResult(forcingRefresh: true).token else {
            lastFailure = Failure(step: "token")
            return false
        }
        var request = URLRequest(url: reclaimURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        for (field, value) in await WorkerAuth.headers() { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["socialUserID": socialID])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard status == 200, body?["status"] as? String == "ok" else {
                print("[Reconnect] reclaim refused: HTTP \(status)")
                lastFailure = Failure(step: "reclaim", code: status, detail: body?["error"] as? String)
                return false
            }
            return true
        } catch {
            print("[Reconnect] reclaim failed: \(error.localizedDescription)")
            lastFailure = Failure(step: "reclaim", code: (error as NSError).code, detail: "network")
            return false
        }
    }
}
