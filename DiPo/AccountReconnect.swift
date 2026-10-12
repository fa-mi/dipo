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

    static func run() async -> Outcome {
        let session = UserSession.shared
        guard let socialID = session.userID, !socialID.isEmpty,
              let provider = session.provider else { return .failed }

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
        guard await reclaim(socialID: socialID), await indexLeadsHere() else { return .failed }
        await FirebaseSupportService.shared.registerUserProfile()
        return .reconnected
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
            guard let user = apple.user, let token = apple.idToken else { return .outcome(.failed) }
            guard user == socialID else { return .outcome(.otherAccount) }
            return .credential(OAuthProvider.appleCredential(withIDToken: token, rawNonce: nil, fullName: nil))
        case .google:
            let google = await googleSignIn()
            if google.cancelled { return .outcome(.cancelled) }
            guard let user = google.user, let idToken = google.idToken, let access = google.accessToken else {
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

    /// Apple's user id and identity token — strings, so nothing non-Sendable
    /// crosses the continuation.
    private static func appleSignIn() async -> (user: String?, idToken: String?, cancelled: Bool) {
        await withCheckedContinuation { continuation in
            let coordinator = AppleSignInCoordinator()
            appleCoordinator = coordinator
            coordinator.onSuccess = { credential in
                appleCoordinator = nil
                let token = credential.identityToken.flatMap { String(data: $0, encoding: .utf8) }
                continuation.resume(returning: (credential.user, token, false))
            }
            coordinator.onError = { error in
                appleCoordinator = nil
                // 1001 is "canceled"; the login screen also treats 1000 as a
                // dismissal, so the same here.
                let code = (error as NSError).code
                continuation.resume(returning: (nil, nil, code == 1001 || code == 1000))
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
        await withCheckedContinuation { continuation in
            FirebaseAccountLinker.signInPreservingAccount(credential, label: "Reconnect") { result, error in
                continuation.resume(returning: error == nil && result != nil)
            }
        }
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
            return false
        }
    }

    private static func reclaim(socialID: String) async -> Bool {
        // Forced: the cached token may predate the link, and the Worker reads
        // the Apple/Google identity out of the token itself.
        guard let user = Auth.auth().currentUser,
              let token = try? await user.getIDTokenResult(forcingRefresh: true).token else { return false }
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
                return false
            }
            return true
        } catch {
            print("[Reconnect] reclaim failed: \(error.localizedDescription)")
            return false
        }
    }
}
