import SwiftUI
import RevenueCat
import UIKit
import AuthenticationServices
import GoogleSignIn
import FirebaseAuth
import CryptoKit

// MARK: - Social Provider

enum SocialProvider: String {
    case apple  = "apple"
    case google = "google"
}

// MARK: - User Session
// Manages the logged-in social account.
// The social login happens ONCE (on first launch).
// After that, PIN/biometrics handle daily unlocks.
// User ID is stored in Keychain for subscription linkage (e.g. RevenueCat).
//
// ✅ Firebase Auth integration: both Apple and Google sign-ins now also
// authenticate with Firebase so Firestore security rules (request.auth)
// work correctly. Without this, request.auth is always nil and all
// authenticated Firestore writes fail with "Missing or insufficient permissions".


// MARK: - Firebase sign-in that preserves the existing account
//
// DiPo establishes an ANONYMOUS Firebase session on every launch (AppDelegate)
// so Firestore rules, which all require `request.auth != null`, are satisfied
// before anyone logs in. Everything the app then writes — `users/{uid}`,
// `dipoIndex.uid`, `webSync/{uid}` — is keyed to that uid.
//
// `Auth.signIn(with:)` REPLACES that session with a brand-new user and a brand-
// new uid. Every one of those documents is instantly orphaned, and
// `dipoIndex`'s update rule (`resource.data.uid == request.auth.uid`) then
// refuses to let the new uid reclaim the entry — by design, since that guard is
// what stops one account seizing another's DiPo ID. The result is a user who
// signs in properly and silently loses their DiPo ID, their web sync and their
// Unity invites, with no way back.
//
// `link(with:)` upgrades the anonymous account IN PLACE: same uid, now backed
// by a real provider. Nothing is orphaned and nothing needs migrating, and the
// uid finally becomes stable across reinstalls because Firebase maps a given
// Apple/Google identity to the same user every time.
//
// The fallback matters too: if that Apple/Google identity is already attached
// to another Firebase user (a returning user on a fresh device), linking fails
// with `credentialAlreadyInUse` and the right move is to sign into THAT
// account — it is the one holding their history.
@MainActor
enum FirebaseAccountLinker {
    static func signInPreservingAccount(
        _ credential: AuthCredential,
        label: String,
        completion: @escaping (AuthDataResult?, Error?) -> Void
    ) {
        guard let current = Auth.auth().currentUser, current.isAnonymous else {
            Auth.auth().signIn(with: credential, completion: completion)
            return
        }
        current.link(with: credential) { result, error in
            if let error = error as NSError? {
                let code = AuthErrorCode(rawValue: error.code)
                if code == .credentialAlreadyInUse || code == .emailAlreadyInUse {
                    // Their real account already exists — join it rather than
                    // stranding them on an anonymous one.
                    print("[DiPo] Firebase (\(label)) already linked elsewhere; signing into it")
                    Auth.auth().signIn(with: credential, completion: completion)
                    return
                }
                print("[DiPo] Firebase (\(label)) link failed: \(error.localizedDescription)")
                Auth.auth().signIn(with: credential, completion: completion)
                return
            }
            print("[DiPo] Firebase (\(label)) linked in place, uid preserved: \(result?.user.uid ?? "")")
            completion(result, nil)
        }
    }
}

@Observable
final class UserSession {
    static let shared = UserSession()
    private init() { load() }

    // MARK: - State

    var userID: String?
    var displayName: String?
    var email: String?
    var provider: SocialProvider?
    var isLoggedIn: Bool { userID != nil }

    /// A short, shareable DiPo ID (e.g. "7Q3KX9A2").
    /// Derived deterministically from the account's stable social `userID`, so:
    ///   • the SAME user always gets the SAME ID across devices & reinstalls,
    ///   • different users get different IDs,
    ///   • no extra storage or server round-trip is needed.
    /// It exists the moment the user is logged in (i.e. right after onboarding),
    /// ready for future features (referrals, friends, sharing) that key on a
    /// stable per-user identifier. nil only when signed out.
    var dipoID: String? {
        guard let uid = userID, !uid.isEmpty else { return nil }
        return Self.dipoID(from: uid)
    }

    /// Deterministic 8-char code from an opaque social id: uppercase letters +
    /// digits from an unambiguous base-32 alphabet (no 0/O/1/I). ~1.1 trillion
    /// combinations, so per-user IDs stay distinct.
    static func dipoID(from userID: String) -> String {
        let digest = SHA256.hash(data: Data(userID.utf8))
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // 32 chars
        return String(digest.prefix(8).map { alphabet[Int($0) % alphabet.count] })
    }

    // MARK: - Keychain Keys

    private let kUserID   = "social_user_id"
    private let kName     = "social_display_name"
    private let kEmail    = "social_email"
    private let kProvider = "social_provider"

    // MARK: - Apple Sign-In

    func handleAppleCredential(_ credential: ASAuthorizationAppleIDCredential) {
        let id = credential.user

        if let fn = credential.fullName {
            let name = [fn.givenName, fn.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { displayName = name }
        }

        if let em = credential.email, !em.isEmpty {
            email = em
        }

        userID   = id
        provider = .apple
        save()

        // ✅ Sign into Firebase Auth with Apple credential so Firestore
        // security rules (request.auth != null) work correctly.
        if let identityToken = credential.identityToken,
           let tokenString   = String(data: identityToken, encoding: .utf8) {
            let firebaseCredential = OAuthProvider.appleCredential(
                withIDToken: tokenString,
                rawNonce: nil,
                fullName: credential.fullName
            )
            FirebaseAccountLinker.signInPreservingAccount(firebaseCredential, label: "Apple") { [weak self] result, error in
                if let error = error {
                    print("[DiPo] Firebase Auth (Apple) error: \(error.localizedDescription)")
                } else {
                    print("[DiPo] Firebase Auth (Apple) signed in: \(result?.user.uid ?? "")")
                    // Apple returns `credential.email` ONLY on the very first
                    // authorization; on every later sign-in it's nil, so the
                    // email would be lost. Firebase persists the (relay) email
                    // across sign-ins, so backfill from the Firebase user when
                    // we don't already have one. The relay address still
                    // forwards to the user's real inbox, so support emails work.
                    let fbEmail = result?.user.email
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if (self.email ?? "").isEmpty, let fbEmail, !fbEmail.isEmpty {
                            self.email = fbEmail
                            self.save()
                        }
                    }
                }
            }
        }

        PremiumManager.shared.onLogin(userID: id)
    }

    // MARK: - Google Sign-In

    func signInWithGoogle(presenting viewController: UIViewController,
                          completion: @escaping (Bool, Error?) -> Void) {
        GIDSignIn.sharedInstance.signIn(withPresenting: viewController) { [weak self] result, error in
            if let error = error {
                completion(false, error)
                return
            }
            guard let user = result?.user,
                  let idToken = user.idToken?.tokenString else {
                completion(false, nil)
                return
            }

            // ✅ Sign into Firebase Auth with Google credential
            let firebaseCredential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: user.accessToken.tokenString
            )
            FirebaseAccountLinker.signInPreservingAccount(firebaseCredential, label: "Google") { [weak self] authResult, authError in
                if let authError = authError {
                    print("[DiPo] Firebase Auth (Google) error: \(authError.localizedDescription)")
                } else {
                    print("[DiPo] Firebase Auth (Google) signed in: \(authResult?.user.uid ?? "")")
                    // Safety net: if the Google profile didn't include an email,
                    // backfill from the Firebase user so support emails work.
                    let fbEmail = authResult?.user.email
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if (self.email ?? "").isEmpty, let fbEmail, !fbEmail.isEmpty {
                            self.email = fbEmail
                            self.save()
                        }
                    }
                }
            }

            self?.handleGoogleUser(
                id: user.userID ?? UUID().uuidString,
                name: user.profile?.name,
                email: user.profile?.email
            )
            completion(true, nil)
        }
    }

    func handleGoogleUser(id: String, name: String?, email: String?) {
        self.userID      = id
        self.displayName = name
        self.email       = email
        self.provider    = .google
        save()
    }

    // MARK: - Sign Out

    func signOut() {
        if provider == .google {
            GIDSignIn.sharedInstance.signOut()
        }
        try? Auth.auth().signOut()

        userID      = nil
        displayName = nil
        email       = nil
        provider    = nil
        Keychain.delete(key: kUserID)
        Keychain.delete(key: kName)
        Keychain.delete(key: kEmail)
        Keychain.delete(key: kProvider)
    }

    // MARK: - Persistence

    private func save() {
        if let id = userID      { Keychain.save(id,         key: kUserID)   }
        if let n  = displayName { Keychain.save(n,          key: kName)     }
        if let e  = email       { Keychain.save(e,          key: kEmail)    }
        if let p  = provider    { Keychain.save(p.rawValue, key: kProvider) }
    }

    private func load() {
        userID      = Keychain.load(key: kUserID)
        displayName = Keychain.load(key: kName)
        email       = Keychain.load(key: kEmail)
        if let raw  = Keychain.load(key: kProvider) {
            provider = SocialProvider(rawValue: raw)
        }
    }

    /// Backfill a missing email from the restored Firebase user at launch.
    /// Returning users who signed in BEFORE email capture was fixed have a
    /// nil email in Keychain; Firebase still holds it, so recover it here so
    /// support emails (and device_tokens broadcast emails) work without
    /// forcing them to sign out and back in.
    /// User-set email (from Profile). Apple often hides/omits the email, so
    /// the user can add or correct it manually. Persisted to Keychain and
    /// pushed to `device_tokens` so support replies, confirmations, and
    /// broadcast emails can reach them.
    func updateEmail(_ newEmail: String) {
        let trimmed = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        email = trimmed
        Keychain.save(trimmed, key: kEmail)
        Task { await FirebaseSupportService.shared.registerCurrentDeviceToken() }
    }

    func backfillEmailFromFirebaseIfNeeded() {
        guard isLoggedIn, (email ?? "").isEmpty else { return }
        if let fbEmail = Auth.auth().currentUser?.email, !fbEmail.isEmpty {
            email = fbEmail
            save()
            print("[DiPo] email backfilled from Firebase ✓")
        }
    }

    /// Recover the display name for users whose Keychain copy is empty. Apple
    /// only returns the full name on the FIRST authorization, so a reinstall (or
    /// a sign-in that pre-dates name capture) leaves this nil forever — which is
    /// what made invites read "Someone" and member rows read "Member".
    func backfillNameFromFirebaseIfNeeded() {
        guard isLoggedIn, (displayName ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let fbName = Auth.auth().currentUser?.displayName?.trimmingCharacters(in: .whitespaces),
           !fbName.isEmpty {
            displayName = fbName
            save()
            print("[DiPo] displayName backfilled from Firebase ✓")
        }
    }

    /// Adopt a name resolved elsewhere (e.g. the Firestore profile) into the
    /// session + Keychain, so the whole app stops falling back to placeholders.
    func adoptDisplayName(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != displayName else { return }
        displayName = clean
        save()
        print("[DiPo] displayName adopted from profile → '\(clean)' ✓")
    }

    // MARK: - Apple credential state check

    func checkAppleCredentialState(completion: @escaping (Bool) -> Void) {
        guard provider == .apple, let id = userID else {
            completion(false)
            return
        }
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: id) { state, _ in
            DispatchQueue.main.async {
                completion(state == .authorized)
            }
        }
    }
}

// MARK: - Apple Sign-In Button Coordinator

final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    var onSuccess: ((ASAuthorizationAppleIDCredential) -> Void)?
    var onError:   ((Error) -> Void)?

    func signIn() {
        let provider = ASAuthorizationAppleIDProvider()
        let request  = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate                    = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
        onSuccess?(credential)
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        onError?(error)
    }
}
