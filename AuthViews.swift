import SwiftUI
import UIKit
import AuthenticationServices
import GoogleSignIn

// MARK: - Splash

struct SplashView: View {
    @State private var mascotScale: CGFloat = 0.7
    @State private var mascotOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var glowRadius: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Mascot — .screen blend removes the PNG's black bg against our black canvas
                Image("DiPoMascot")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280)
                    .blendMode(.screen)
                    .scaleEffect(mascotScale)
                    .opacity(mascotOpacity)

                Spacer().frame(height: 16)

                // Brand text
                VStack(spacing: 8) {
                    Text("DiPo")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient(
                            colors: [.green, .yellow],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                    Text(loc("auth.tagline"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(LinearGradient(
                            colors: [.white, .gray,],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .tracking(1.5)
                }
                .opacity(textOpacity)

                Spacer()
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.65).delay(0.1)) {
                mascotScale = 1
                mascotOpacity = 1
            }
            withAnimation(.easeOut(duration: 0.6).delay(0.4)) {
                textOpacity = 1
            }
            withAnimation(.easeOut(duration: 1.4).delay(0.1)) {
                glowRadius = 340
            }
        }
    }
}

// MARK: - Setup Flow

struct SetupView: View {
    @Bindable var authVM: AuthViewModel
    @State private var appeared = false

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            switch authVM.setupStep {
            case .socialLogin:
                SocialLoginView(authVM: authVM)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            case .enterName:
                NameEntryView(authVM: authVM, appeared: appeared)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: authVM.setupStep)
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) { appeared = true } }
    }
}

// MARK: - Social Login View

struct SocialLoginView: View {
    @Bindable var authVM: AuthViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared    = false
    @State private var isLoading   = false
    @State private var errorMsg: String? = nil
    @State private var session     = UserSession.shared
    @State private var appleCoordinator = AppleSignInCoordinator()

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo + hero
                VStack(spacing: 0) {
                    // Mascot with glow
                    ZStack {

                        Image("DiPoMascot")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 180, height: 180)
                            .clipShape(Circle())
                            .blendMode(colorScheme == .dark ? .screen : .multiply)
                    }
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.65, dampingFraction: 0.65).delay(0.05), value: appeared)

                    VStack(spacing: 8) {
                        Text(loc("auth.welcome"))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(loc("auth.subtitle"))
                            .font(.system(size: 15))
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                    .animation(.spring(response: 0.5).delay(0.15), value: appeared)
                }
                .padding(.horizontal, 32)

                Spacer()

                // Buttons
                VStack(spacing: 14) {
                    if let err = errorMsg {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .transition(.opacity)
                    }

                    // Sign in with Apple
                    Button {
                        guard !isLoading else { return }
                        isLoading = true
                        errorMsg  = nil
                        appleCoordinator.onSuccess = { credential in
                            isLoading = false
                            // handleAppleCredential now calls PremiumManager.onLogin internally
                            session.handleAppleCredential(credential)
                            authVM.completeSocialLogin()
                        }
                        appleCoordinator.onError = { error in
                            isLoading = false
                            let err = error as NSError
                            // Code 1000 = user cancelled — don't show error
                            if err.code != 1000 {
                                withAnimation { errorMsg = loc("auth.apple_failed") }
                            }
                        }
                        appleCoordinator.signIn()
                    } label: {
                        HStack(spacing: 12) {
                            if isLoading {
                                ProgressView().tint(Color(.systemBackground))
                            } else {
                                Image(systemName: "apple.logo")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(Color(.systemBackground))
                            }
                            Text(loc("auth.apple"))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color(.systemBackground))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(.label), in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .disabled(isLoading)

                    // Sign in with Google
                    Button {
                        guard !isLoading else { return }
                        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                              let rootVC = windowScene.windows.first?.rootViewController else { return }
                        isLoading = true
                        errorMsg  = nil
                        session.signInWithGoogle(presenting: rootVC) { success, error in
                            isLoading = false
                            if success {
                                if let uid = session.userID {
                                    PremiumManager.shared.onLogin(userID: uid)
                                }
                                authVM.completeSocialLogin()
                            } else if let error = error {
                                let nsErr = error as NSError
                                // Code -5 = user cancelled
                                if nsErr.code != -5 {
                                    withAnimation { errorMsg = loc("auth.google_failed") }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if isLoading {
                                ProgressView().tint(AppTheme.textPrimary)
                            } else {
                                ZStack {
                                    Circle().fill(.white).frame(width: 22, height: 22)
                                    Text("G")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(Color(hex: "#4285F4"))
                                }
                            }
                            Text(loc("auth.google"))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.cardMid, lineWidth: 1.5))
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .disabled(isLoading)

                    // Divider
                    HStack {
                        Rectangle().fill(AppTheme.cardMid).frame(height: 1)
                        Text(loc("common.or")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary).fixedSize()
                        Rectangle().fill(AppTheme.cardMid).frame(height: 1)
                    }
                    .padding(.vertical, 4)

                    // Continue without account
                    Button {
                        authVM.skipSocialLogin()
                    } label: {
                        Text(loc("auth.guest"))
                            .font(.system(size: 14))
                            .foregroundStyle(AppTheme.textSecondary)
                            .underline()
                    }
                    .buttonStyle(ScaleButtonStyle())

                    Text(loc("auth.data_stays"))
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 28)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 24)
                .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.22), value: appeared)

                Spacer(minLength: 48)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6).delay(0.1)) { appeared = true }
        }
    }
}

// MARK: - Name Entry

struct NameEntryView: View {
    @Bindable var authVM: AuthViewModel
    let appeared: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {

            // Back button row
            HStack {
                Button {
                    HapticManager.shared.tap()
                    focused = false
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                        authVM.setupStep = .socialLogin
                        authVM.errorMessage = nil
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text(loc("common.back"))
                            .font(.system(size: 15))
                    }
                    .foregroundStyle(AppTheme.textSecondary)
                }
                .buttonStyle(ScaleButtonStyle())
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer()

            VStack(spacing: 32) {
                // Icon
                ZStack {
                    Circle()
                        .fill(AppTheme.cardDark)
                        .frame(width: 88, height: 88)
                        .overlay(Circle().stroke(AppTheme.accent.opacity(0.25), lineWidth: 1.5))
                    Image(systemName: "person.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(AppTheme.accent)
                }
                .scaleEffect(appeared ? 1 : 0.7)
                .opacity(appeared ? 1 : 0)

                VStack(spacing: 10) {
                    Text(loc("auth.name_prompt"))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(loc("auth.name_sub"))
                        .font(.system(size: 15))
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)

                // Name field
                VStack(spacing: 12) {
                    TextField(loc("auth.name_placeholder"), text: $authVM.userName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 16)
                        .padding(.horizontal, 20)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16)
                            .stroke(focused ? AppTheme.accent.opacity(0.6) : Color.clear, lineWidth: 1.5))
                        .focused($focused)
                        .onSubmit { authVM.submitName() }

                    if let err = authVM.errorMessage {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.red)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 36)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 20)
            }

            Spacer()

            Button {
                focused = false
                authVM.submitName()
            } label: {
                HStack(spacing: 10) {
                    Text(loc("auth.continue"))
                        .font(.system(size: 16, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(AppTheme.bg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    authVM.userName.count >= 2 ? AppTheme.accent : AppTheme.textSecondary.opacity(0.3),
                    in: Capsule()
                )
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 32)
            .padding(.bottom, 52)
            .disabled(authVM.userName.count < 2)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear { focused = true }
    }
}

// MARK: - Biometric Gate View
// Ditampilkan saat app dibuka dan saat kembali dari background (jika biometric aktif).
// Tidak ada PIN fallback — user hanya bisa retry biometric atau tunggu sistem mengizinkan.

struct BiometricGateView: View {
    @Bindable var authVM: AuthViewModel
    @State private var appeared = false

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            RadialGradient(
                colors: [AppTheme.accent.opacity(0.07), .clear],
                center: .init(x: 0.5, y: 0.35),
                startRadius: 0, endRadius: 320
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 32) {
                    // Biometric icon with pulse
                    BiometricPulseIcon(authVM: authVM, appeared: appeared)

                    VStack(spacing: 8) {
                        Text(loc("auth.welcome_back"))
                            .font(.system(size: 16))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text(authVM.savedName)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                    .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.1), value: appeared)

                    // Error + retry button
                    if let err = authVM.errorMessage {
                        VStack(spacing: 16) {
                            Text(err)
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)

                            Button {
                                authVM.errorMessage = nil
                                authVM.triggerBiometric()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: authVM.biometricIcon)
                                        .font(.system(size: 15, weight: .semibold))
                                    Text(loc("auth.try_again"))
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .foregroundStyle(AppTheme.bg)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 14)
                                .background(AppTheme.accent, in: Capsule())
                                .shadow(color: AppTheme.accent.opacity(0.35), radius: 12, y: 6)
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }

                Spacer()

                Text(loc("auth.biometric_hint"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 52)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: appeared)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { appeared = true }
        }
    }
}

// MARK: - Biometric Pulse Icon

struct BiometricPulseIcon: View {
    @Bindable var authVM: AuthViewModel
    let appeared: Bool
    @State private var pulsing = false

    var body: some View {
        Button {
            authVM.errorMessage = nil
            authVM.triggerBiometric()
        } label: {
            ZStack {
                ForEach(0..<2) { i in
                    Circle()
                        .stroke(AppTheme.accent.opacity(0.12 - Double(i) * 0.04), lineWidth: 1)
                        .frame(width: CGFloat(80 + i * 28), height: CGFloat(80 + i * 28))
                        .scaleEffect(pulsing ? 1.2 : 1)
                        .opacity(pulsing ? 0 : 1)
                        .animation(
                            .easeOut(duration: 2.0)
                                .repeatForever(autoreverses: false)
                                .delay(Double(i) * 0.5),
                            value: pulsing
                        )
                }
                Circle()
                    .fill(AppTheme.cardDark)
                    .frame(width: 72, height: 72)
                    .overlay(Circle().stroke(AppTheme.accent.opacity(0.3), lineWidth: 1.5))
                    .shadow(color: AppTheme.accent.opacity(0.2), radius: 16)

                if authVM.isLoading {
                    ProgressView()
                        .tint(AppTheme.accent)
                } else {
                    Image(systemName: authVM.biometricIcon)
                        .font(.system(size: 30))
                        .foregroundStyle(AppTheme.accent)
                }
            }
        }
        .buttonStyle(ScaleButtonStyle())
        .onAppear { pulsing = true }
    }
}

// end of AuthViews.swift
