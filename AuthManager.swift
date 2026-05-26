import SwiftUI
import LocalAuthentication
import Security

// MARK: - Auth State

enum AuthState: Equatable {
    case splash
    case setup
    case biometric   // biometric gate — shown on launch and on foreground if enabled
    case authenticated
}

// MARK: - Keychain

struct Keychain {
    static let service = "com.fahmiaquinas.DiPo"

    static func save(_ value: String, key: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    service,
            kSecAttrAccount:    key,
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Auth ViewModel

@Observable
final class AuthViewModel {

    var authState: AuthState = .splash
    var setupStep: SetupStep = .enterName
    var userName: String = ""
    var errorMessage: String? = nil
    var isLoading: Bool = false
    var biometricType: LABiometryType = .none

    enum SetupStep { case socialLogin, enterName }

    private let kName      = "user_name"
    private let kSetupDone = "setup_done"

    var biometricIcon: String {
        switch biometricType {
        case .faceID:  return "faceid"
        case .touchID: return "touchid"
        default:       return "lock.fill"
        }
    }

    var biometricLabel: String {
        switch biometricType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        default:       return "Biometrics"
        }
    }

    var isBiometricAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// User-controlled toggle — false means always use PIN even if Face/Touch ID is available
    var biometricEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "biometric_enabled") == nil
              ? true  // default ON for new users
              : UserDefaults.standard.bool(forKey: "biometric_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "biometric_enabled") }
    }

    var isBiometricActive: Bool { isBiometricAvailable && biometricEnabled }

    private var wentToBackground = false

    var savedName: String { Keychain.load(key: kName) ?? "User" }

    // MARK: - Boot (called once on launch)

    func bootstrap() {
        detectBiometricType()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let isSetup = Keychain.load(key: self.kSetupDone) == "true"
            let isLoggedIn = UserSession.shared.isLoggedIn

            if isSetup {
                if self.isBiometricActive {
                    // Show biometric gate, then immediately prompt
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                        self.authState = .biometric
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        self.triggerBiometric()
                    }
                } else {
                    // Biometric disabled by user — skip gate, go straight in
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                        self.authState = .authenticated
                    }
                }
            } else if isLoggedIn {
                self.userName = UserSession.shared.displayName ?? ""
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    self.setupStep = .enterName
                    self.authState = .setup
                }
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    self.setupStep = .socialLogin
                    self.authState = .setup
                }
            }
        }
    }

    // MARK: - Scene Phase Handler (call from RootView)

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background, .inactive:
            if authState == .authenticated {
                wentToBackground = true
            }
        case .active:
            guard wentToBackground else { return }
            wentToBackground = false
            let isSetup = Keychain.load(key: kSetupDone) == "true"
            guard isSetup else { return }
            guard isBiometricActive else { return }
            // Lock and re-authenticate via biometric
            errorMessage = nil
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                authState = .biometric
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.triggerBiometric()
            }
        @unknown default:
            break
        }
    }

    private func detectBiometricType() {
        var error: NSError?
        let ctx = LAContext()
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            biometricType = ctx.biometryType
        }
    }

    // MARK: - Biometric

    func triggerBiometric() {
        guard !isLoading else { return }
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // Device doesn't support biometrics — skip gate
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                authState = .authenticated
            }
            return
        }
        isLoading = true
        ctx.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: loc("auth.biometric_reason")
        ) { success, err in
            DispatchQueue.main.async {
                self.isLoading = false
                if success {
                    self.errorMessage = nil
                    HapticManager.shared.success()
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        self.authState = .authenticated
                    }
                } else {
                    let laError = err as? LAError
                    // userCancel / systemCancel — tetap di biometric screen, tidak tampilkan error
                    if laError?.code != .userCancel && laError?.code != .systemCancel {
                        HapticManager.shared.error()
                        self.errorMessage = loc("auth.biometric_failed")
                    }
                    // authState tetap .biometric — user bisa tap retry
                }
            }
        }
    }

    // MARK: - Social Login

    func completeSocialLogin() {
        // Called after Apple/Google sign-in succeeds
        // Pre-fill name if available from social provider
        if userName.trimmingCharacters(in: .whitespaces).isEmpty {
            userName = UserSession.shared.displayName ?? ""
        }
        HapticManager.shared.success()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            setupStep = .enterName
        }
    }

    func skipSocialLogin() {
        // User opts to continue without social login (offline mode).
        //
        // If we already have an on-device name from a previous setup
        // (typical after the user logged out and is now choosing "continue
        // without login"), don't force them to retype it — restore the
        // saved name, re-mark setup as done, and jump straight into the
        // app. The local name is never tied to the social account ID, so
        // keeping it across a logout is safe.
        HapticManager.shared.tap()
        if let saved = Keychain.load(key: kName)?
            .trimmingCharacters(in: .whitespaces),
           !saved.isEmpty {
            userName = saved
            Keychain.save("true", key: kSetupDone)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    self.authState = .authenticated
                }
            }
            return
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            setupStep = .enterName
        }
    }

    // MARK: - Setup

    func submitName() {
        guard userName.trimmingCharacters(in: .whitespaces).count >= 2 else {
            errorMessage = "Enter at least 2 characters"
            HapticManager.shared.error()
            return
        }
        errorMessage = nil
        HapticManager.shared.success()
        Keychain.save(userName.trimmingCharacters(in: .whitespaces), key: kName)
        Keychain.save("true", key: kSetupDone)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                self.authState = .authenticated
            }
        }
    }

    // MARK: - Reset

    func resetApp() {
        // Logout flow. We deliberately KEEP `kName` so that if the user
        // picks "Continue without login" on the next screen, they don't
        // have to retype the name they already set up. `skipSocialLogin`
        // reads it back. `kSetupDone` is cleared because the user is being
        // sent through the setup flow again (they need to choose between
        // signing back in vs. continuing as guest).
        Keychain.delete(key: kSetupDone)
        UserSession.shared.signOut()
        userName = ""
        setupStep = .socialLogin; errorMessage = nil
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { authState = .setup }
    }
}
