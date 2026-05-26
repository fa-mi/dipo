import SwiftUI

// MARK: - Onboarding View

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0

    // Pages defined as key tuples so they re-read loc() on every render,
    // meaning language switches take effect immediately even on this screen.
    private var pages: [(icon: String, color: Color, titleKey: String, bodyKey: String, tipKey: String?)] {[
        ("creditcard.fill", Color(hex: "#38BDF8"),
         "onboard.p1_title", "onboard.p1_body", nil),
        ("chart.pie.fill",  Color(hex: "#1DB87A"),
         "onboard.p2_title", "onboard.p2_body", "onboard.p2_tip"),
        ("brain.fill",      Color(hex: "#A78BFA"),
         "onboard.p3_title", "onboard.p3_body", "onboard.p3_tip"),
        ("banknote.fill",   Color(hex: "#FB923C"),
         "onboard.p4_title", "onboard.p4_body", "onboard.p4_tip"),
    ]}

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Skip button
                HStack {
                    Spacer()
                    Button(loc("onboard.skip")) {
                        HapticManager.shared.tap()
                        finish()
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                }

                // Page content
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { i, page in
                        OnboardingPageView(
                            icon:        page.icon,
                            color:       page.color,
                            title:       loc(page.titleKey),
                            description: loc(page.bodyKey),
                            tip:         page.tipKey.map { loc($0) }
                        )
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: currentPage)

                // Dots + CTA
                VStack(spacing: 24) {
                    HStack(spacing: 8) {
                        ForEach(0..<pages.count, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(i == currentPage ? AppTheme.accent : AppTheme.cardMid)
                                .frame(width: i == currentPage ? 24 : 8, height: 8)
                                .animation(.spring(response: 0.3), value: currentPage)
                        }
                    }

                    Button {
                        HapticManager.shared.tap()
                        if currentPage < pages.count - 1 {
                            withAnimation { currentPage += 1 }
                        } else {
                            finish()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(currentPage < pages.count - 1
                                 ? loc("onboard.next")
                                 : loc("onboard.get_started"))
                                .font(.system(size: 17, weight: .bold))
                            Image(systemName: currentPage < pages.count - 1
                                  ? "arrow.right" : "checkmark")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .foregroundStyle(AppTheme.bg)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 18))
                        .shadow(color: AppTheme.accent.opacity(0.4), radius: 16, y: 6)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .padding(.horizontal, 28)
                }
                .padding(.bottom, 48)
            }
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboarding_done")
        HapticManager.shared.success()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            isPresented = false
        }
    }
}

// MARK: - Onboarding Page View

struct OnboardingPageView: View {
    let icon:        String
    let color:       Color
    let title:       String
    let description: String   // renamed from 'body' — conflicts with SwiftUI's var body
    let tip:         String?

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 120, height: 120)
                Circle()
                    .fill(color.opacity(0.08))
                    .frame(width: 160, height: 160)
                Image(systemName: icon)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(color)
            }
            .scaleEffect(appeared ? 1 : 0.6)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1), value: appeared)
            .padding(.bottom, 40)

            // Title
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 20)
                .animation(.spring(response: 0.5).delay(0.18), value: appeared)
                .padding(.horizontal, 32)

            // Body
            Text(description)
                .font(.system(size: 16))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 20)
                .animation(.spring(response: 0.5).delay(0.24), value: appeared)
                .padding(.horizontal, 32)
                .padding(.top, 16)

            // Tip pill
            if let tip {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(color)
                    Text(tip)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(color.opacity(0.1), in: Capsule())
                .overlay(Capsule().stroke(color.opacity(0.2), lineWidth: 1))
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.5).delay(0.3), value: appeared)
                .padding(.top, 20)
            }

            Spacer()
            Spacer()
        }
        .onAppear {
            appeared = false
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.05)) {
                appeared = true
            }
        }
    }
}
