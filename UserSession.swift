import SwiftUI
import RevenueCat
import UIKit
import AuthenticationServices
import GoogleSignIn
import FirebaseAuth

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
            Auth.auth().signIn(with: firebaseCredential) { [weak self] result, error in
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
            Auth.auth().signIn(with: firebaseCredential) { [weak self] authResult, authError in
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
