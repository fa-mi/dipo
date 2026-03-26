import SwiftUI
import AuthenticationServices

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

@Observable
final class UserSession {
    static let shared = UserSession()
    private init() { load() }

    // MARK: - State

    var userID: String?          // Apple/Google opaque user identifier
    var displayName: String?     // Full name from Apple (only sent on first sign-in)
    var email: String?           // Email from Apple/Google
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

        // Apple only provides name on the VERY FIRST sign-in
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

        // Link to RevenueCat (add this when integrating RevenueCat SDK):
        // Purchases.shared.logIn(id) { customerInfo, _, _ in }
    }

    // MARK: - Google Sign-In
    // Requires: GoogleSignIn SDK via SPM
    // Package URL: https://github.com/google/GoogleSignIn-iOS
    // Also needs GoogleService-Info.plist from Firebase Console
    //
    // Usage after adding SDK:
    //   GIDSignIn.sharedInstance.signIn(withPresenting: rootVC) { result, error in
    //       guard let user = result?.user else { return }
    //       UserSession.shared.handleGoogleUser(
    //           id: user.userID ?? "",
    //           name: user.profile?.name,
    //           email: user.profile?.email
    //       )
    //   }

    func handleGoogleUser(id: String, name: String?, email: String?) {
        self.userID      = id
        self.displayName = name
        self.email       = email
        self.provider    = .google
        save()
    }

    // MARK: - Sign Out

    func signOut() {
        userID   = nil
        displayName = nil
        email    = nil
        provider = nil
        Keychain.delete(key: kUserID)
        Keychain.delete(key: kName)
        Keychain.delete(key: kEmail)
        Keychain.delete(key: kProvider)
    }

    // MARK: - Persistence

    private func save() {
        if let id = userID   { Keychain.save(id,  key: kUserID)   }
        if let n  = displayName { Keychain.save(n, key: kName)    }
        if let e  = email    { Keychain.save(e,   key: kEmail)    }
        if let p  = provider { Keychain.save(p.rawValue, key: kProvider) }
    }

    private func load() {
        userID      = Keychain.load(key: kUserID)
        displayName = Keychain.load(key: kName)
        email       = Keychain.load(key: kEmail)
        if let raw = Keychain.load(key: kProvider) {
            provider = SocialProvider(rawValue: raw)
        }
    }

    // MARK: - Apple credential state check
    // Call on app launch to verify Apple ID is still valid

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
