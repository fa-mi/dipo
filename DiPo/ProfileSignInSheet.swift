import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers   // for `.json` UTType in fileImporter

// Moved out of ProfileView.swift, unchanged.

// MARK: - Profile Sign In Sheet

struct ProfileSignInSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isSigningIn: Bool
    @Binding var loginError: String?
    let onApple: () -> Void
    let onGoogle: () -> Void
    var context: SignInContext = .general
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false

    enum SignInContext {
        case general, support
        var title: String {
            switch self {
            case .general: return loc("profile.signin")
            case .support: return loc("profile.signin_support")
            }
        }
        var subtitle: String {
            switch self {
            case .general: return loc("profile.sublogin")
            case .support: return loc("profile.subcus")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                // DiPo's face on a plain disc, as Profile shows it. The glow,
                // ring and sheen that used to sit round it carried nothing.
                ZStack {
                    Circle().fill(AppTheme.cardDark)
                    Image("DiPoMascot")
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                        .blendMode(colorScheme == .dark ? .screen : .normal)
                }
                .frame(width: 84, height: 84)
                .scaleEffect(appeared ? 1 : 0.75)
                .rotationEffect(.degrees(appeared ? 0 : -8))
                .opacity(appeared ? 1 : 0)
                .animation(
                    .spring(response: 0.5, dampingFraction: 0.7)
                    .delay(0.05),
                    value: appeared
                )
                VStack(spacing: 5) {
                    Text(context.title).font(.system(.title3, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                    Text(context.subtitle)
                        .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary).multilineTextAlignment(.center)
                }
                .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 10)
                .animation(AppMotion.appear, value: appeared)
            }
            .padding(.top, 28)

            VStack(spacing: 12) {
                if let err = loginError {
                    InlineBanner(tone: .error, message: err)
                }
                Button {
                    HapticManager.shared.tap(); dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onApple() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "apple.logo").font(.system(.body, weight: .medium))
                        Text(loc("auth.apple")).font(.system(.callout, weight: .semibold))
                    }
                    // Use textPrimary (auto-inverts: dark in light mode, white
                    // in dark mode) instead of fixed `.white`. Previously the
                    // logo + label were white-on-white in light theme, making
                    // the button invisible. Background also matches the
                    // Google button (cardDark + cardMid stroke) for visual
                    // consistency between the two sign-in options.
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.cardMid, lineWidth: 1.5))
                }
                .buttonStyle(ScaleButtonStyle())

                Button {
                    HapticManager.shared.tap(); dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onGoogle() }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(.white).frame(width: 20, height: 20)
                            Text("G").font(.system(.footnote, weight: .bold)).foregroundStyle(Color(hex: "#4285F4"))
                        }
                        Text(loc("auth.google")).font(.system(.callout, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.cardMid, lineWidth: 1.5))
                }
                .buttonStyle(ScaleButtonStyle())

                Text(loc("auth.data_stays"))
                    .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary.opacity(0.5))
                    .multilineTextAlignment(.center).padding(.top, 2)
            }
            .padding(.horizontal, 24).padding(.top, 24)
            .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 20)
            .animation(AppMotion.appear, value: appeared)

            Spacer()
        }
        .onAppear { withAnimation { appeared = true } }
    }
}
