import SwiftUI

// MARK: - Contact Admin Sheet
// Moved from NotificationManager.swift — this is UI, not a service.

struct ContactAdminSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var subject  = ""
    @State private var message  = ""
    @State private var category = SupportCategory.bug
    @State private var sent     = false
    @State private var appeared = false

    enum SupportCategory: String, CaseIterable {
        case bug     = "Bug Report"
        case feature = "Feature Request"
        case billing = "Billing"
        case other   = "Other"

        var icon: String {
            switch self {
            case .bug:     return "ant.fill"
            case .feature: return "lightbulb.fill"
            case .billing: return "creditcard.fill"
            case .other:   return "ellipsis.bubble.fill"
            }
        }
        var color: Color {
            switch self {
            case .bug:     return Color(hex: "#FF6B6B")
            case .feature: return Color(hex: "#38BDF8")
            case .billing: return Color(hex: "#FB923C")
            case .other:   return Color(hex: "#8A9693")
            }
        }
    }

    private let adminEmail = "support@dipo.app"

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                if sent { sentView } else { formView }
            }
            .navigationTitle("Contact Support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { HapticManager.shared.tap(); dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        .onAppear { withAnimation(.spring(response: 0.6).delay(0.1)) { appeared = true } }
    }

    private var formView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "headphones.circle.fill").font(.system(size: 32)).foregroundStyle(AppTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("We're here to help").font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                        Text("Usually respond within 24 hours").font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()
                }
                .padding(16)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.accent.opacity(0.2), lineWidth: 1))
                .padding(.horizontal, 22)
                .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5).delay(0.05), value: appeared)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(SupportCategory.allCases, id: \.rawValue) { cat in
                            Button { HapticManager.shared.tap(); withAnimation { category = cat } } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: cat.icon).font(.system(size: 12))
                                    Text(cat.rawValue).font(.system(size: 13, weight: .medium))
                                }
                                .foregroundStyle(category == cat ? .white : AppTheme.textSecondary)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(category == cat ? cat.color : AppTheme.cardDark, in: Capsule())
                                .overlay(Capsule().stroke(category == cat ? Color.clear : AppTheme.cardMid, lineWidth: 1))
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5).delay(0.1), value: appeared)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Subject").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                    TextField("Brief description...", text: $subject)
                        .font(.system(size: 15)).foregroundStyle(AppTheme.textPrimary)
                        .padding(14).background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 22)
                .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5).delay(0.15), value: appeared)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Message").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $message)
                            .font(.system(size: 15)).foregroundStyle(AppTheme.textPrimary)
                            .frame(minHeight: 120).padding(10)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                        if message.isEmpty {
                            Text("Describe the issue in detail...")
                                .font(.system(size: 15)).foregroundStyle(AppTheme.textSecondary.opacity(0.5))
                                .padding(18).allowsHitTesting(false)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5).delay(0.2), value: appeared)

                Button { send() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "paperplane.fill").font(.system(size: 16))
                        Text("Send Message").font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(
                        subject.isEmpty || message.isEmpty ? AppTheme.textSecondary.opacity(0.3) : AppTheme.accent,
                        in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(ScaleButtonStyle()).disabled(subject.isEmpty || message.isEmpty)
                .padding(.horizontal, 22)
                .opacity(appeared ? 1 : 0).animation(.spring(response: 0.5).delay(0.25), value: appeared)

                Button {
                    if let url = URL(string: "mailto:\(adminEmail)") { UIApplication.shared.open(url) }
                } label: {
                    Text("Or email: \(adminEmail)").font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary).underline()
                }

                Spacer(minLength: 40)
            }
            .padding(.top, 8)
        }
    }

    private var sentView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.12)).frame(width: 90, height: 90)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(AppTheme.accent)
            }
            VStack(spacing: 8) {
                Text("Message sent!").font(.system(size: 24, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                Text("We'll get back to you within 24 hours.")
                    .font(.system(size: 15)).foregroundStyle(AppTheme.textSecondary).multilineTextAlignment(.center)
            }
            Button { dismiss() } label: {
                Text("Done").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(ScaleButtonStyle()).padding(.horizontal, 32)
            Spacer()
        }
    }

    private func send() {
        guard !subject.isEmpty, !message.isEmpty else { HapticManager.shared.error(); return }
        let subj = "\(category.rawValue): \(subject)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let info = "User: \(UserSession.shared.userID ?? "anonymous") | Plan: \(PremiumManager.shared.plan.label)\n\n"
        let body = (info + message).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "mailto:\(adminEmail)?subject=\(subj)&body=\(body)"),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            UIPasteboard.general.string = "To: \(adminEmail)\nSubject: \(category.rawValue): \(subject)\n\n\(info)\(message)"
        }
        HapticManager.shared.success()
        withAnimation(.spring(response: 0.5)) { sent = true }
    }
}
