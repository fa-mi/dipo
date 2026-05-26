import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers   // for `.json` UTType in fileImporter

// MARK: - Premium Locked Feature Link

struct PremiumLockedFeatureLink: View {
    let feature: PremiumFeature
    let title: String
    let subtitle: String
    @Binding var showPaywall: Bool
    let action: () -> Void

    private var isLocked: Bool { !PremiumManager.shared.canAccess(feature) }

    var body: some View {
        Button(action: {
            HapticManager.shared.tap()
            if isLocked { showPaywall = true } else { action() }
        }) {
            HStack(spacing: 14) {
                Image(systemName: feature.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(isLocked ? AppTheme.textSecondary : feature.color)
                    .frame(width: 36, height: 36)
                    .background(
                        (isLocked ? AppTheme.textSecondary : feature.color).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isLocked ? AppTheme.textSecondary : AppTheme.textPrimary)
                        if isLocked {
                            HStack(spacing: 3) {
                                Image(systemName: feature.requiredPlan.icon)
                                    .font(.system(size: 8, weight: .bold))
                                Text(feature.requiredPlan.label)
                                    .font(.system(size: 9, weight: .bold))
                                    .tracking(0.5)
                            }
                            .foregroundStyle(feature.requiredPlan.color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(feature.requiredPlan.color.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Image(systemName: isLocked ? "lock.fill" : "chevron.right")
                    .font(.system(size: isLocked ? 12 : 13))
                    .foregroundStyle(isLocked ? AppTheme.textSecondary.opacity(0.5) : AppTheme.textSecondary)
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(isLocked ? AppTheme.cardMid.opacity(0.5) : feature.color.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Profile Feature Link

struct ProfileFeatureLink: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: { HapticManager.shared.tap(); action() }) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
                    .frame(width: 36, height: 36)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(color.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Card Manager From Profile

struct CardManagerFromProfile: View {
    @State private var vm = AppViewModel()
    @Query(sort: \BankCard.sortOrder) private var liveCards: [BankCard]

    var body: some View {
        NavigationStack {
            CardListView(vm: vm)
        }
        .onAppear { vm.cards = liveCards }
        .onChange(of: liveCards) { _, new in vm.cards = new }
    }
}

// MARK: - Profile View

struct ProfileView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var authVM: AuthViewModel
    @Environment(\.modelContext) private var context

    /// Live card list — used by `shouldShowBackupReminder` to decide
    /// whether the user has any data worth nagging them to back up.
    /// `@Query` makes it reactive so the banner appears/disappears when
    /// cards are added/deleted without a full Profile re-mount.
    @Query(sort: \BankCard.sortOrder) private var liveCards: [BankCard]

    @State private var appeared           = false
    @State private var showResetConfirm   = false
    @State private var showSalary         = false
    @State private var showAIChat         = false
    @State private var showWishlist       = false
    @State private var showCardManager    = false
    @State private var showBudgetSettings = false
    @State private var isEditingName      = false
    @State private var editNameText       = ""
    @State private var showEmailEdit      = false
    @State private var emailText          = ""
    @State private var showDebt           = false
    @State private var showPaywall        = false
    @State private var appearanceMode: String = UserDefaults.standard.string(forKey: "appearance_mode") ?? "system"
    @State private var premiumMgr  = PremiumManager.shared
    @State private var session     = UserSession.shared
    @State private var showSignOut = false
    @State private var showContact = false
    @State private var showContactAfterLogin = false  // ✅ opens support after login completes
    @State private var isSigningIn = false
    @State private var loginError: String? = nil
    @State private var appleCoordinator = AppleSignInCoordinator()
    @State private var showSignInSheet   = false
    @State private var biometricEnabled: Bool = UserDefaults.standard.object(forKey: "biometric_enabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "biometric_enabled")
    // Backup / restore state
    @State private var backupShareItem: ShareItem? = nil
    @State private var showImportPicker = false
    @State private var pendingImportURL: URL? = nil
    @State private var showImportConfirm = false
    @State private var backupToast: String? = nil
    /// Loading overlay state. `nil` = idle. Otherwise carries the operation
    /// label so we can show "Mengekspor…" vs "Memulihkan…" without juggling
    /// two separate booleans + a flag.
    @State private var backupBusyLabel: String? = nil
    /// Preview snapshot of the picked import file. Non-nil = preview sheet is
    /// up; user has seen the summary but not yet confirmed the destructive
    /// wipe. Two-stage gate: preview → DangerConfirm → actual import.
    @State private var importPreview: BackupPreview? = nil
    /// Last export timestamp, used by the reminder banner. Updated in
    /// runExport on success. Read from UserDefaults on Profile appear so
    /// the banner state survives sessions.
    @State private var lastExportDate: Date? = UserDefaults.standard.object(forKey: "last_backup_export_date") as? Date

    @State private var photoItem: PhotosPickerItem? = nil
    @State private var profileImage: UIImage? = Self.loadProfileImage()
    @State private var showPhotoOptions = false

    static func loadProfileImage() -> UIImage? {
        guard let data = UserDefaults.standard.data(forKey: "profile_photo"),
              let img = UIImage(data: data) else { return nil }
        return img
    }

    static func saveProfileImage(_ image: UIImage) {
        let data = image.jpegData(compressionQuality: 0.8)
        UserDefaults.standard.set(data, forKey: "profile_photo")
        NotificationCenter.default.post(name: .profilePhotoDidChange, object: nil)
    }

    private var initials: String {
        authVM.savedName.split(separator: " ")
            .prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    // MARK: - Style Helpers
    // Extracted so the type-checker doesn't resolve complex ShapeStyle ternaries inside body.

    private var planIconFill: some ShapeStyle {
        if premiumMgr.plan == .free {
            return AnyShapeStyle(AppTheme.textSecondary.opacity(0.1))
        }
        return AnyShapeStyle(LinearGradient(
            colors: [premiumMgr.plan.color.opacity(0.25), premiumMgr.plan.color.opacity(0.08)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var planCardFill: some ShapeStyle {
        if premiumMgr.plan == .free {
            return AnyShapeStyle(AppTheme.cardDark)
        }
        return AnyShapeStyle(LinearGradient(
            colors: [premiumMgr.plan.color.opacity(0.12), AppTheme.cardDark],
            startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var planTaglineFill: some ShapeStyle {
        if premiumMgr.plan == .free {
            return AnyShapeStyle(LinearGradient(colors: [.green, .yellow], startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(premiumMgr.plan.color)
    }

    private var avatarRingFill: some ShapeStyle {
        if premiumMgr.plan == .free {
            return AnyShapeStyle(AppTheme.accent.opacity(0.35))
        }
        return AnyShapeStyle(LinearGradient(
            colors: [premiumMgr.plan.color, premiumMgr.plan.color.opacity(0.4)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    Spacer(minLength: 20)
                    avatarSection
                    nameSection
                    securityCard
                    if session.isLoggedIn { accountCard }
                    if session.isLoggedIn { emailSection }
                    premiumBadge
                    featureLinksCard
                    appearanceCard
                    authButtonSection
                    backupSection
                    resetButton
                    supportSection
                    Spacer(minLength: 110)
                }
            }
        }
        // Backup busy overlay — shown over the entire profile while export
        // or import is running. Disables interaction with all sheets and
        // buttons so the user can't double-tap or cancel mid-write.
        .overlay { backupBusyOverlay }
        // Sign-out confirmation — warning tone (orange) since it's reversible:
        // the user can sign back in, and on-device data is preserved.
        .sheet(isPresented: $showSignOut) {
            DangerConfirmSheet(
                icon: "rectangle.portrait.and.arrow.right.fill",
                tone: .warning,
                title: loc("auth.sign_out"),
                message: loc("auth.sign_out_confirm"),
                confirmLabel: loc("auth.sign_out"),
                onConfirm: {
                    let uid = UserSession.shared.userID
                    if let uid { PremiumManager.shared.onLogout(userID: uid) }
                    HapticManager.shared.warning()
                    authVM.resetApp()
                }
            )
            .presentationDetents([.height(380)])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.bg)
            .presentationCornerRadius(28)
            .preferredColorScheme(appColorScheme())
        }
        // Reset-all confirmation — danger tone (red) since it's irreversible
        // and wipes every local record.
        .sheet(isPresented: $showResetConfirm) {
            DangerConfirmSheet(
                icon: "trash.fill",
                tone: .danger,
                title: loc("profile.reset_all"),
                message: loc("profile.reset_confirm"),
                confirmLabel: loc("profile.reset_btn"),
                onConfirm: { resetAllData() }
            )
            .presentationDetents([.height(420)])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.bg)
            .presentationCornerRadius(28)
            .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showSalary) {
            SalaryView().presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showAIChat) {
            AIChatView().presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showWishlist) {
            WishlistView().presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        // Backup share sheet — fires when export succeeds.
        .sheet(item: $backupShareItem) { item in
            ActivityShareSheet(items: [item.url])
        }
        // File picker for importing a previously-saved JSON backup.
        // Restricted to .json so users don't accidentally pick a wrong file.
        // After picking, we PARSE the file first (no DB writes) and show a
        // summary preview sheet before the destructive confirmation. This
        // prevents the worst-case "user picked the wrong file → wipes
        // current data → realizes mistake too late" scenario.
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            // Clear any toast from a previous attempt — otherwise a stale
            // "invalid file" message from the last pick keeps showing even
            // after a successful pick, making the user think the new file
            // also failed.
            backupToast = nil
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                pendingImportURL = url
                do {
                    importPreview = try BackupService.previewBackup(from: url)
                } catch {
                    backupToast = error.localizedDescription
                    pendingImportURL = nil
                }
            case .failure(let err):
                backupToast = err.localizedDescription
            }
        }
        // Preview sheet — shows what's in the picked file BEFORE wiping.
        // User can back out without consequence here. Tapping Continue
        // advances to the destructive-action confirmation below.
        .sheet(item: $importPreview) { preview in
            BackupPreviewSheet(
                preview: preview,
                onContinue: {
                    importPreview = nil
                    // Brief delay so the preview sheet's dismiss animation
                    // doesn't race with the DangerConfirm sheet's present.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showImportConfirm = true
                    }
                },
                onCancel: {
                    importPreview = nil
                    pendingImportURL = nil
                }
            )
            .presentationDetents([.height(560)])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.bg)
            .presentationCornerRadius(28)
            .preferredColorScheme(appColorScheme())
        }
        // Destructive confirmation before wiping local data with imported one.
        .sheet(isPresented: $showImportConfirm) {
            DangerConfirmSheet(
                icon: "square.and.arrow.down.fill",
                tone: .danger,
                title: loc("backup.import_confirm_title"),
                message: loc("backup.import_confirm_body"),
                confirmLabel: loc("backup.import"),
                onConfirm: {
                    guard let url = pendingImportURL else { return }
                    runImport(from: url)
                }
            )
            .presentationDetents([.height(420)])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.bg)
            .presentationCornerRadius(28)
            .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showBudgetSettings) {
            SmartBudgetSettingsSheet().presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showDebt) {
            DebtView().presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showContact) {
            ContactAdminSheet().presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showSignInSheet) {
            ProfileSignInSheet(
                isSigningIn: $isSigningIn, loginError: $loginError,
                onApple: {
                    doSignInWithApple()
                    showSignInSheet = false
                    // ✅ Open support automatically after sign-in if user tapped
                    // Contact Support while logged out.
                    if showContactAfterLogin {
                        showContactAfterLogin = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            showContact = true
                        }
                    }
                },
                onGoogle: {
                    doSignInWithGoogle()
                    showSignInSheet = false
                    if showContactAfterLogin {
                        showContactAfterLogin = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            showContact = true
                        }
                    }
                },
                context: showContactAfterLogin ? .support : .general
            )
            .presentationDetents([.height(420)]).presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
            .presentationCornerRadius(28)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.1)) { appeared = true }
        }
    }

    // MARK: - Sub-Views

    @ViewBuilder
    private var avatarSection: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [AppTheme.accent.opacity(0.22), .clear],
                                     center: .center, startRadius: 0, endRadius: 90))
                .frame(width: 90, height: 90)
            Circle()
                .fill(RadialGradient(colors: [AppTheme.accent.opacity(0.10), .clear],
                                     center: .center, startRadius: 0, endRadius: 120))
                .frame(width: 120, height: 120)
            Circle()
                .strokeBorder(avatarRingFill, lineWidth: premiumMgr.plan == .free ? 2 : 3)
                .frame(width: 118, height: 118)
            ZStack {
                Circle().fill(AppTheme.cardDark).frame(width: 110, height: 110)
                    .shadow(color: AppTheme.accent.opacity(0.35), radius: 18, y: 6)
                if let img = profileImage {
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(width: 110, height: 110).clipShape(Circle())
                } else {
                    Image("DiPoMascot").resizable().scaledToFill()
                        .frame(width: 110, height: 110).clipShape(Circle())
                        .blendMode(colorScheme == .dark ? .screen : .multiply)
                }
            }
            Button { showPhotoOptions = true } label: {
                ZStack {
                    Circle().fill(AppTheme.accent).frame(width: 32, height: 32)
                        .shadow(color: AppTheme.accent.opacity(0.55), radius: 8, y: 3)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .buttonStyle(ScaleButtonStyle())
            .offset(x: 36, y: 36)
        }
        .scaleEffect(appeared ? 1 : 0.7)
        .opacity(appeared ? 1 : 0)
        .photosPicker(isPresented: $showPhotoOptions, selection: $photoItem,
                      matching: .images, photoLibrary: .shared())
        .onChange(of: photoItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run { profileImage = img; Self.saveProfileImage(img) }
                }
            }
        }
    }

    @ViewBuilder
    private var nameSection: some View {
        VStack(spacing: 8) {
            if isEditingName {
                HStack(spacing: 8) {
                    TextField(loc("auth.name_placeholder"), text: $editNameText)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.accent.opacity(0.5), lineWidth: 1.5))
                        .submitLabel(.done).onSubmit { saveName() }
                    Button { saveName() } label: {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 28)).foregroundStyle(AppTheme.accent)
                    }.buttonStyle(ScaleButtonStyle())
                    Button { isEditingName = false; editNameText = authVM.savedName } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 28)).foregroundStyle(AppTheme.textSecondary)
                    }.buttonStyle(ScaleButtonStyle())
                }
                .padding(.horizontal, 28)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            } else {
                Button {
                    editNameText = authVM.savedName
                    withAnimation(.spring(response: 0.35)) { isEditingName = true }
                } label: {
                    HStack(spacing: 6) {
                        Text(authVM.savedName)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary)
                        Image(systemName: "pencil").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                    }
                }
                .buttonStyle(ScaleButtonStyle())
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
            HStack(spacing: 5) {
                if premiumMgr.plan != .free {
                    Image(systemName: premiumMgr.plan.icon).font(.system(size: 10, weight: .bold))
                        .foregroundStyle(premiumMgr.plan.color)
                }
                Text(premiumMgr.plan == .free ? loc("auth.tagline") : "DiPo \(premiumMgr.plan.label)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(planTaglineFill)
                    .tracking(premiumMgr.plan == .free ? 1.4 : 0.5)
            }
            .padding(.horizontal, premiumMgr.plan == .free ? 0 : 10)
            .padding(.vertical, premiumMgr.plan == .free ? 0 : 4)
            .background(premiumMgr.plan == .free ? .clear : premiumMgr.plan.color.opacity(0.12), in: Capsule())
        }
        .opacity(appeared ? 1 : 0)
    }

    @ViewBuilder
    private var emailSection: some View {
        let hasEmail = !(session.email ?? "").isEmpty
        HStack(spacing: 12) {
            let c: Color = hasEmail ? AppTheme.accent : AppTheme.orange
            Image(systemName: hasEmail ? "envelope.fill" : "envelope.badge")
                .font(.system(size: 18)).foregroundStyle(c)
                .frame(width: 36, height: 36)
                .background(c.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("profile.email_title"))
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                Text(hasEmail ? (session.email ?? "") : loc("profile.email_not_set"))
                    .font(.system(size: 12))
                    .foregroundStyle(hasEmail ? AppTheme.textSecondary : AppTheme.orange)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                HapticManager.shared.tap()
                emailText = session.email ?? ""
                showEmailEdit = true
            } label: {
                Text(hasEmail ? loc("common.edit") : loc("profile.add_email"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hasEmail ? AppTheme.accent : .white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(hasEmail ? AppTheme.accent.opacity(0.12) : AppTheme.accent, in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.accent.opacity(hasEmail ? 0.3 : 0), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke((hasEmail ? AppTheme.accent : AppTheme.orange).opacity(0.18), lineWidth: 1))
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
        .alert(loc("profile.email_title"), isPresented: $showEmailEdit) {
            TextField("you@example.com", text: $emailText)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(loc("common.save")) { saveEmail() }
            Button(loc("common.cancel"), role: .cancel) {}
        } message: {
            Text(loc("profile.email_desc"))
        }
    }

    @ViewBuilder
    private var securityCard: some View {
        HStack(spacing: 12) {
            let bioColor = authVM.isBiometricAvailable ? AppTheme.accent : AppTheme.textSecondary
            Image(systemName: authVM.biometricIcon).font(.system(size: 18)).foregroundStyle(bioColor)
                .frame(width: 36, height: 36)
                .background(bioColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(authVM.biometricLabel).font(.system(size: 14, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                Text(
                    authVM.isBiometricAvailable
                    ? (biometricEnabled
                        ? loc("biometric.auto_unlock")
                        : loc("biometric.disabled"))
                    : loc("biometric.unavailable")
                )
                .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            if authVM.isBiometricAvailable {
                Toggle("", isOn: $biometricEnabled).tint(AppTheme.accent).labelsHidden()
                    .onChange(of: biometricEnabled) { _, on in
                        UserDefaults.standard.set(on, forKey: "biometric_enabled")
                        HapticManager.shared.tap()
                    }
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.accent.opacity(0.18), lineWidth: 1))
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
    }

    @ViewBuilder
    private var accountCard: some View {
        HStack(spacing: 14) {
            ZStack {
                let isApple = session.provider == .apple
                RoundedRectangle(cornerRadius: 12)
                    .fill(isApple
                        ? LinearGradient(colors: [Color(hex: "#1C1C1E"), Color(hex: "#3A3A3C")], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color(hex: "#4285F4").opacity(0.2), Color(hex: "#34A853").opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(isApple ? Color.white.opacity(0.08) : Color(hex: "#4285F4").opacity(0.3), lineWidth: 1))
                if session.provider == .apple {
                    Image(systemName: "apple.logo").font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                } else {
                    Text("G").font(.system(size: 18, weight: .bold)).foregroundStyle(Color(hex: "#4285F4"))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName ?? loc("profile.account"))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                HStack(spacing: 4) {
                    let isApple = session.provider == .apple
                    Text(isApple ? "Apple" : "Google")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isApple ? .white : Color(hex: "#4285F4"))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(isApple ? Color(hex: "#3A3A3C") : Color(hex: "#4285F4").opacity(0.15), in: Capsule())
                    if let email = session.email, !email.isEmpty {
                        Text("· \(email)").font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            Button { HapticManager.shared.tap(); showSignOut = true } label: {
                Text(loc("profile.logout")).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.red)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(AppTheme.red.opacity(0.1), in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.red.opacity(0.3), lineWidth: 1))
            }.buttonStyle(ScaleButtonStyle())
        }
        .padding(16)
        .background(
            LinearGradient(colors: [AppTheme.cardDark, AppTheme.cardDark.opacity(0.8)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.cardMid.opacity(0.6), lineWidth: 1))
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.08), value: appeared)
    }

    @ViewBuilder
    private var premiumBadge: some View {
        Button { HapticManager.shared.tap(); showPaywall = true } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(planIconFill).frame(width: 44, height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(premiumMgr.plan == .free ? Color.clear : premiumMgr.plan.color.opacity(0.4), lineWidth: 1))
                    Image(systemName: premiumMgr.plan.icon).font(.system(size: 18, weight: .medium))
                        .foregroundStyle(premiumMgr.plan == .free ? AppTheme.textSecondary : premiumMgr.plan.color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(premiumMgr.plan == .free ? loc("free.user") : "DiPo \(premiumMgr.plan.label)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(premiumMgr.plan == .free ? AppTheme.textPrimary : premiumMgr.plan.color)
                    // Subtitle ternary collapsed from 3-tier to 2-tier
                    // (Premium plan removed). Only Free or Royal possible.
                    let subtitle = premiumMgr.plan == .free
                        ? loc("free.title")
                        : loc("royal.title")
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                if premiumMgr.plan == .free {
                    // Upgrade chip uses Royal's color now — Premium's
                    // amber tone is gone with the tier. Consistent purple
                    // throughout the upgrade journey is also clearer
                    // branding ("this color = paid feature").
                    Text(loc("profile.upgrade")).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(
                            LinearGradient(colors: [PremiumPlan.royal.color, PremiumPlan.royal.color.opacity(0.75)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                        .shadow(color: PremiumPlan.royal.color.opacity(0.4), radius: 6, y: 3)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(premiumMgr.plan.color.opacity(0.7))
                }
            }
            .padding(16)
            .background(planCardFill, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(premiumMgr.plan == .free ? AppTheme.cardMid.opacity(0.5) : premiumMgr.plan.color.opacity(0.4),
                        lineWidth: premiumMgr.plan == .free ? 1 : 1.5))
        }
        .buttonStyle(ScaleButtonStyle())
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.1), value: appeared)
    }

    @ViewBuilder
    private var featureLinksCard: some View {
        VStack(spacing: 12) {
            PremiumLockedFeatureLink(
                feature: .aiAdvisor, title: loc("profile.ai_advisor"),
                subtitle: premiumMgr.canAccess(.aiAdvisor)
                    ? loc("profile.ai_advisor_sub")
                    : loc("profile.requires_royal"),
                showPaywall: $showPaywall) { showAIChat = true }
            ProfileFeatureLink(icon: "banknote.fill", color: AppTheme.accent,
                               title: loc("profile.salary"),
                               subtitle: loc("profile.salary_sub")) { showSalary = true }
            PremiumLockedFeatureLink(
                feature: .savingsGoals, title: loc("profile.savings"),
                // Savings Goals moved from Premium-tier to Royal-tier when
                // the Premium plan was removed, so the locked-state copy
                // points at Royal now (same key the other paid features
                // already use).
                subtitle: premiumMgr.canAccess(.savingsGoals) ? loc("profile.savings_sub") : loc("profile.requires_royal"),
                showPaywall: $showPaywall) { showWishlist = true }
            PremiumLockedFeatureLink(
                feature: .smartBudget, title: loc("profile.budget"),
                subtitle: premiumMgr.canAccess(.smartBudget)
                    ? (SmartBudgetManager.shared.isEnabled ? loc("profile.budget_active") : loc("budget.off"))
                    : loc("profile.requires_royal"),
                showPaywall: $showPaywall) { showBudgetSettings = true }
            PremiumLockedFeatureLink(
                feature: .smartDebt, title: loc("profile.debt"),
                subtitle: premiumMgr.canAccess(.smartDebt) ? loc("profile.debt_sub") : loc("profile.requires_royal"),
                showPaywall: $showPaywall) { showDebt = true }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.green.opacity(0.18), lineWidth: 1))
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.14), value: appeared)
    }

    @ViewBuilder
    private var appearanceCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 18)).foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("profile.appearance")).font(.system(size: 14, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                    Text(appearanceMode == "system" ? loc("appearance.following_system") : appearanceMode == "dark" ? loc("appearance.dark_mode") : loc("appearance.light_mode"))
                        .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
            }
            Divider().background(AppTheme.cardMid).padding(.vertical, 10)
            HStack(spacing: 0) {
                let modes: [(icon: String, label: String, mode: String)] = [
                    ("sun.max.fill", loc("appearance.light"), "light"),
                    ("circle.lefthalf.filled", loc("appearance.system"), "system"),
                    ("moon.fill", loc("appearance.dark"), "dark")
                ]
                ForEach(modes, id: \.mode) { item in
                    Button {
                        guard item.mode != appearanceMode else { return }
                        HapticManager.shared.tap()
                        withAnimation(.spring(response: 0.3)) { appearanceMode = item.mode }
                        performAppearanceTransition(to: item.mode)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: item.icon).font(.system(size: 16))
                                .foregroundStyle(appearanceMode == item.mode ? AppTheme.bg : AppTheme.textSecondary)
                            Text(item.label)
                                .font(.system(size: 11, weight: appearanceMode == item.mode ? .semibold : .regular))
                                .foregroundStyle(appearanceMode == item.mode ? AppTheme.bg : AppTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(appearanceMode == item.mode ? AppTheme.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
            .padding(4)
            .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.textSecondary.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.18), value: appeared)

        // ── Language Toggle ──────────────────────────────────────────────
        languageSection
            .padding(.horizontal, 22)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)
            .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.21), value: appeared)
    }

    @ViewBuilder
    private var languageSection: some View {
        // LanguageManager is @Observable — accessing it directly creates automatic dependency tracking
        let lang = LanguageManager.shared
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("🌐")
                    .font(.system(size: 18))
                    .frame(width: 36, height: 36)
                    .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("profile.language"))
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                    Text(lang.current.flag + " " + lang.current.nativeName)
                        .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
            }
            Divider().background(AppTheme.cardMid).padding(.vertical, 10)
            HStack(spacing: 0) {
                ForEach(LanguageManager.Language.allCases) { language in
                    Button {
                        guard language != lang.current else { return }
                        HapticManager.shared.tap()
                        withAnimation(.spring(response: 0.3)) {
                            LanguageManager.shared.current = language
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Text(language.flag).font(.system(size: 22))
                            Text(language.nativeName)
                                .font(.system(size: 11,
                                              weight: language == lang.current ? .semibold : .regular))
                                .foregroundStyle(language == lang.current ? AppTheme.bg : AppTheme.textSecondary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(language == lang.current ? AppTheme.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
            .padding(4)
            .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.textSecondary.opacity(0.12), lineWidth: 1))
    }   // ← closing brace was missing, causing all subsequent vars to fall inside

    @ViewBuilder
    private var authButtonSection: some View {
        Group {
            if isSigningIn {
                HStack(spacing: 10) {
                    ProgressView().tint(AppTheme.accent)
                    Text(loc("profile.signing_in")).font(.system(size: 15)).foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
            } else {
                let loggedIn = session.isLoggedIn
                Button {
                    HapticManager.shared.tap()
                    if loggedIn { showSignOut = true } else { showSignInSheet = true }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: loggedIn ? "person.crop.circle.badge.xmark" : "person.crop.circle.badge.checkmark")
                            .font(.system(size: 16))
                        Text(loggedIn ? loc("profile.logout") : loc("profile.login")).font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(loggedIn ? AppTheme.red : AppTheme.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background((loggedIn ? AppTheme.red : AppTheme.accent).opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke((loggedIn ? AppTheme.red : AppTheme.accent).opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle())
            }
            if let err = loginError {
                InlineBanner(tone: .error, message: err)
            }
        }
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
    }

    // MARK: - Backup / Restore Section

    /// Two paired buttons that let the user save a snapshot of their entire
    /// dataset to a JSON file (Backup) or replace local data with a previously
    /// saved file (Restore). This is the recommended migration path when
    /// changing devices since the app intentionally has no server-side mirror.
    @ViewBuilder
    private var backupSection: some View {
        VStack(spacing: 10) {
            // Reminder banner — surfaces ONLY when the user has data worth
            // protecting but hasn't backed up recently. Solves the worst-case
            // "user never exports → loses everything" failure mode without
            // nagging users who don't need it.
            if shouldShowBackupReminder {
                Button {
                    HapticManager.shared.tap()
                    runExport()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: lastExportDate == nil ? "exclamationmark.circle.fill" : "clock.arrow.circlepath")
                            .font(.system(size: 18))
                            .foregroundStyle(AppTheme.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lastExportDate == nil
                                 ? loc("backup.reminder.never_title")
                                 : loc("backup.reminder.stale_title"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(backupReminderSubtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(12)
                    .background(AppTheme.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.orange.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle())
            }

            // Section header so users understand what they're touching
            HStack(spacing: 6) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(loc("backup.section_title"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
            }

            HStack(spacing: 10) {
                // Backups are tied to the logged-in user (each export
                // embeds `userID`, each import checks it). Gate both
                // buttons behind login so the user can't even attempt an
                // operation that would just throw `.notLoggedIn`.
                let isLoggedIn = UserSession.shared.isLoggedIn
                let isDisabled = backupBusyLabel != nil || !isLoggedIn
                // Export
                Button {
                    HapticManager.shared.tap()
                    runExport()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 14, weight: .semibold))
                        Text(loc("backup.export")).font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(AppTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.accent.opacity(0.25), lineWidth: 1))
                    .opacity(isDisabled ? 0.5 : 1)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(isDisabled)

                // Import
                Button {
                    HapticManager.shared.tap()
                    showImportPicker = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 14, weight: .semibold))
                        Text(loc("backup.import")).font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.blue)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(AppTheme.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.blue.opacity(0.25), lineWidth: 1))
                    .opacity(isDisabled ? 0.5 : 1)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(isDisabled)
            }

            if !UserSession.shared.isLoggedIn {
                // Tell the user why the buttons are dimmed instead of
                // letting them silently wonder. Subtle inline hint —
                // matches existing `backup.subtitle` styling.
                Text(loc("backup.login_required"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.red.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            Text(loc("backup.subtitle"))
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if let toast = backupToast {
                // The success string is prefixed with "✅" by the caller;
                // we use that as the signal to render with success tone
                // instead of error. InlineBanner handles icon + color +
                // background so the visual feedback matches every other
                // form in the app.
                let isSuccess = toast.hasPrefix("✅")
                InlineBanner(
                    tone: isSuccess ? .success : .error,
                    // Strip the prefix emoji — InlineBanner renders its own
                    // status icon, so the leading "✅" would be redundant.
                    message: isSuccess
                        ? String(toast.dropFirst().trimmingCharacters(in: .whitespaces))
                        : toast
                )
            }
        }
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
    }

    @ViewBuilder
    private var resetButton: some View {
        Button { HapticManager.shared.warning(); showResetConfirm = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "trash.fill").font(.system(size: 16))
                Text(loc("profile.reset_all")).font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(AppTheme.red).frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(AppTheme.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.red.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(ScaleButtonStyle()).padding(.horizontal, 22).opacity(appeared ? 1 : 0)
    }

    @ViewBuilder
    private var supportSection: some View {
        // Support requires both login AND an email on file — the email is how
        // we reply. When logged in but email is missing, the row is DISABLED
        // and points the user to set their email first.
        let needsEmail = session.isLoggedIn && (session.email ?? "").isEmpty
        VStack(spacing: 12) {
            if needsEmail {
                Button {
                    HapticManager.shared.tap()
                    emailText = ""
                    showEmailEdit = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "headphones.circle.fill")
                            .font(.system(size: 18)).foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 36, height: 36)
                            .background(AppTheme.textSecondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc("profile.support"))
                                .font(.system(size: 14, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                            Text(loc("profile.support_needs_email"))
                                .font(.system(size: 12)).foregroundStyle(AppTheme.orange)
                        }
                        Spacer()
                        Image(systemName: "lock.fill").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(14)
                    .background(AppTheme.cardDark.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.orange.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle())
            } else {
                ProfileFeatureLink(icon: "headphones.circle.fill", color: AppTheme.blue,
                                   title: loc("profile.support"),
                                   subtitle: loc("profile.subcs")) {
                    // ✅ Require login before opening support — Firestore rules
                    // need request.auth != null to allow writes.
                    if session.isLoggedIn {
                        showContact = true
                    } else {
                        showContactAfterLogin = true
                        showSignInSheet       = true
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.26), value: appeared)
    }

    // MARK: - Actions

    private func saveName() {
        let trimmed = editNameText.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return }
        Keychain.save(trimmed, key: "user_name")
        HapticManager.shared.success()
        withAnimation(.spring(response: 0.35)) { isEditingName = false }
    }

    private func saveEmail() {
        let trimmed = emailText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Basic format guard — must look like an email.
        guard trimmed.contains("@"), trimmed.contains("."),
              !trimmed.hasPrefix("@"), !trimmed.hasSuffix("@") else {
            HapticManager.shared.warning()
            return
        }
        UserSession.shared.updateEmail(trimmed)
        HapticManager.shared.success()
    }

    private func resetAllData() {
        try? context.delete(model: BankCard.self)
        try? context.delete(model: TxRecord.self)
        try? context.delete(model: SalarySchedule.self)
        try? context.delete(model: DebtRecord.self)
        try? context.delete(model: SavingsGoal.self)
        // Per-card budget configs (50/30/20 ratios per UUID). Without this
        // delete, orphan rows linger in the store referencing deleted card IDs
        // and accumulate forever every time the user resets.
        try? context.delete(model: CardBudgetConfig.self)
        try? context.save()
        UserDefaults.standard.removeObject(forKey: "profile_photo")
        profileImage = nil
        // Wipe Smart Budget settings too — the user expects "Reset All Data"
        // to be exhaustive. Without this, ratios + master toggle would survive
        // the wipe and reapply to whichever account signs in next.
        SmartBudgetManager.shared.resetAllSettings()
        NotificationCenter.default.post(name: .profilePhotoDidChange, object: nil)
        // NOTE: We deliberately DO NOT call `authVM.resetApp()` here. Reset
        // wipes only the user's financial data — their session, keychain
        // setup state, and Premium subscription stay intact. Forcing a logout
        // was the previous behavior and made the typical "I want to start
        // fresh but stay signed in" flow painful (user had to re-auth after
        // every reset, and their Royal entitlement would have to be
        // re-fetched from RevenueCat). Sign-out is now a separate action.
        HapticManager.shared.warning()
    }

    // MARK: - Backup Reminder Logic

    /// Days between considered "fresh" vs "stale" — 30 is the sweet spot:
    /// long enough that we don't nag active users, short enough that a real
    /// data loss after this period would feel like "I should've backed up."
    private static let reminderStaleDays = 30

    /// Show the reminder banner when:
    ///   - User has meaningful data (≥1 card; transactions/goals/debts will
    ///     accumulate from there) — empty-state users get a fresh slate
    ///     without the nag.
    ///   - AND either: never exported, OR last export > 30 days ago.
    private var shouldShowBackupReminder: Bool {
        guard !liveCards.isEmpty else { return false }
        guard let last = lastExportDate else { return true }
        let daysSince = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0
        return daysSince >= Self.reminderStaleDays
    }

    /// Subtitle string for the reminder — varies by whether this is a
    /// first-time nudge or a stale-backup reminder. Locale-aware via
    /// LanguageManager's currentLocale.
    private var backupReminderSubtitle: String {
        if let last = lastExportDate {
            let f = DateFormatter()
            f.locale = LanguageManager.shared.currentLocale
            f.dateStyle = .medium
            f.timeStyle = .none
            return String(format: loc("backup.reminder.stale_subtitle"), f.string(from: last))
        }
        return loc("backup.reminder.never_subtitle")
    }

    // MARK: - Backup / Restore Runners

    /// Full-screen modal-like overlay shown while `backupBusyLabel != nil`.
    /// Uses opacity transitions so the spinner fades in cleanly. The opaque
    /// scrim behind blocks all interaction — important during import which
    /// deletes data, so the user can't pull-to-dismiss the sheet mid-wipe.
    @ViewBuilder
    private var backupBusyOverlay: some View {
        if let label = backupBusyLabel {
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text(label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 26)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
            }
            .transition(.opacity)
        }
    }

    /// Wraps `BackupService.exportBackup` with a loading overlay. The
    /// overlay is mostly precaution — export is typically <100ms — but on
    /// devices with thousands of transactions the JSON encode + disk write
    /// can pause the UI for 1-2 seconds, and a spinner makes that less
    /// jarring. Also gives the user a clear "saved!" success haptic.
    private func runExport() {
        backupBusyLabel = loc("backup.exporting")
        backupToast = nil
        // Run on next runloop tick so the overlay actually renders before
        // the (possibly synchronous) work begins. Without the dispatch the
        // ProgressView sometimes only appears AFTER export completes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            do {
                let url = try BackupService.exportBackup(context: context)
                backupBusyLabel = nil
                backupShareItem = ShareItem(url: url)
                HapticManager.shared.success()
                // Persist successful export timestamp so the reminder
                // banner knows when to stop nagging. Triggered ONLY on
                // success — failed export shouldn't reset the timer.
                let now = Date()
                UserDefaults.standard.set(now, forKey: "last_backup_export_date")
                lastExportDate = now
            } catch {
                backupBusyLabel = nil
                backupToast = error.localizedDescription
                HapticManager.shared.error()
            }
        }
    }

    /// Wraps `BackupService.importBackup`. Same loading rationale as export
    /// but more important here: import wipes existing data first, so a stuck
    /// UI without feedback feels broken. The overlay reassures the user.
    private func runImport(from url: URL) {
        backupBusyLabel = loc("backup.importing")
        backupToast = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            do {
                try BackupService.importBackup(from: url, context: context)
                backupBusyLabel = nil
                backupToast = loc("backup.import_success")
                HapticManager.shared.success()
            } catch {
                backupBusyLabel = nil
                backupToast = error.localizedDescription
                HapticManager.shared.error()
            }
            pendingImportURL = nil
        }
    }

    private func doSignInWithApple() {
        isSigningIn = true; loginError = nil
        appleCoordinator.onSuccess = { credential in
            session.handleAppleCredential(credential)
            if let uid = session.userID { PremiumManager.shared.onLogin(userID: uid) }
            HapticManager.shared.success()
            isSigningIn = false
        }
        appleCoordinator.onError = { error in
            isSigningIn = false
            let err = error as NSError
            if err.code != 1000 { withAnimation { loginError = loc("auth.apple_failed") } }
        }
        appleCoordinator.signIn()
    }

    private func doSignInWithGoogle() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = windowScene.keyWindow?.rootViewController else { return }
        isSigningIn = true; loginError = nil
        session.signInWithGoogle(presenting: root) { success, error in
            isSigningIn = false
            if success {
                if let uid = session.userID { PremiumManager.shared.onLogin(userID: uid) }
                HapticManager.shared.success()
            } else if let e = error as NSError?, e.code != -5 {
                withAnimation { loginError = loc("auth.google_failed") }
            }
        }
    }
}

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
                ZStack {
                    // 🔥 Outer glow (lebih halus & luas)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    AppTheme.accent.opacity(0.25),
                                    AppTheme.accent.opacity(0.1),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 80
                            )
                        )
                        .frame(width: 140, height: 140)

                    // 🟣 Gradient ring (biar tidak flat)
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    AppTheme.accent.opacity(0.6),
                                    AppTheme.accent.opacity(0.2)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                        .frame(width: 90, height: 90)

                    // 🧱 Base circle (glass feel)
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppTheme.cardDark,
                                    AppTheme.cardDark.opacity(0.85)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 76, height: 76)
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

                    // 🧊 Highlight (fake light reflection)
                    Circle()
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                        .frame(width: 76, height: 76)
                        .blur(radius: 1)

                    // 🐣 Mascot
                    Image("DiPoMascot")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 76, height: 76)
                        .clipShape(Circle())
                        .overlay(
                            Circle().stroke(.white.opacity(0.08), lineWidth: 1)
                        )
                        .blendMode(colorScheme == .dark ? .screen : .normal)
                }
                .scaleEffect(appeared ? 1 : 0.75)
                .rotationEffect(.degrees(appeared ? 0 : -8))
                .opacity(appeared ? 1 : 0)
                .animation(
                    .spring(response: 0.5, dampingFraction: 0.7)
                    .delay(0.05),
                    value: appeared
                )
                VStack(spacing: 5) {
                    Text(context.title).font(.system(size: 20, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                    Text(context.subtitle)
                        .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary).multilineTextAlignment(.center)
                }
                .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 10)
                .animation(.spring(response: 0.45).delay(0.12), value: appeared)
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
                        Image(systemName: "apple.logo").font(.system(size: 17, weight: .medium))
                        Text(loc("auth.apple")).font(.system(size: 16, weight: .semibold))
                    }
                    // Use textPrimary (auto-inverts: dark in light mode, white
                    // in dark mode) instead of fixed `.white`. Previously the
                    // logo + label were white-on-white in light theme, making
                    // the button invisible. Background also matches the
                    // Google button (cardDark + cardMid stroke) for visual
                    // consistency between the two sign-in options.
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(AppTheme.cardMid, lineWidth: 1.5))
                }
                .buttonStyle(ScaleButtonStyle())

                Button {
                    HapticManager.shared.tap(); dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onGoogle() }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(.white).frame(width: 20, height: 20)
                            Text("G").font(.system(size: 13, weight: .bold)).foregroundStyle(Color(hex: "#4285F4"))
                        }
                        Text(loc("auth.google")).font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(AppTheme.cardMid, lineWidth: 1.5))
                }
                .buttonStyle(ScaleButtonStyle())

                Text(loc("auth.data_stays"))
                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary.opacity(0.5))
                    .multilineTextAlignment(.center).padding(.top, 2)
            }
            .padding(.horizontal, 24).padding(.top, 24)
            .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 20)
            .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.18), value: appeared)

            Spacer()
        }
        .onAppear { withAnimation { appeared = true } }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let profilePhotoDidChange = Notification.Name("profilePhotoDidChange")
    /// Posted by empty-state CTAs in HomeView/StatisticsView to request the
    /// MainTabView's central "+" sheet (AddTransactionSheet) to open. Lets
    /// child views trigger the add flow without owning the sheet binding.
    static let requestOpenAddTransaction = Notification.Name("requestOpenAddTransaction")
    /// Posted when an external entry point (currently: the Home Screen
    /// widget's Smart Insights teaser deep-link `dipo://upgrade-royal`)
    /// wants to present the Royal paywall sheet. MainTabView listens and
    /// owns the sheet binding so any tab can land on the paywall without
    /// detours through the Profile tab first.
    static let requestOpenPaywall        = Notification.Name("requestOpenPaywall")
    /// Posted when a support-reply notification's "Learn more" / deep link
    /// (`dipo://support`) is opened. MainTabView presents the Support screen
    /// so the user lands on their ticket thread from anywhere.
    static let requestOpenSupport        = Notification.Name("requestOpenSupport")
}

// MARK: - Danger Confirm Sheet

/// Reusable destructive-action confirmation sheet. Replaces SwiftUI's stock
/// `.confirmationDialog` for two reasons:
///   1. The native dialog is visually plain (gray system action sheet) and
///      doesn't match the app's theme — users complained it felt unfinished.
///   2. Long Indonesian copy gets truncated awkwardly inside the system
///      dialog's header. A custom sheet lets us give the message room to
///      breathe.
///
/// The sheet renders a colored icon, a bold title, a multi-line message, and
/// two side-by-side buttons (Cancel + destructive). Wire it up via
/// `.sheet(isPresented:)` with `.presentationDetents([.height(...)])`.
struct DangerConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// SF Symbol shown in the colored circle at the top.
    let icon: String
    /// Tone of the icon + confirm button. Use `.danger` for destructive (red),
    /// `.warning` for cautionary actions like sign-out (orange).
    let tone: Tone
    let title: String
    let message: String
    /// Label for the destructive button (e.g. "Sign Out", "Reset Everything").
    let confirmLabel: String
    /// Called after the user confirms. Sheet auto-dismisses; the caller does
    /// not need to flip its `isPresented` binding.
    let onConfirm: () -> Void

    enum Tone {
        case danger   // red — irreversible / data loss
        case warning  // orange — reversible / less severe

        var color: Color {
            switch self {
            case .danger:  return AppTheme.red
            case .warning: return AppTheme.orange
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            // Icon
            ZStack {
                Circle()
                    .fill(tone.color.opacity(0.12))
                    .frame(width: 84, height: 84)
                Circle()
                    .stroke(tone.color.opacity(0.25), lineWidth: 1.5)
                    .frame(width: 84, height: 84)
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(tone.color)
            }
            .padding(.top, 14)

            // Title + message
            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)

            Spacer(minLength: 18)

            // Buttons
            HStack(spacing: 12) {
                Button {
                    HapticManager.shared.tap()
                    dismiss()
                } label: {
                    Text(loc("common.cancel"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(AppTheme.cardMid, lineWidth: 1)
                        )
                }
                .buttonStyle(ScaleButtonStyle())

                Button {
                    // Dismiss first so the sheet's exit animation overlaps with
                    // any UI changes the confirm action triggers (sign-out,
                    // data wipe). Without this the sheet snaps closed only
                    // after the transition lands and feels janky.
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        onConfirm()
                    }
                } label: {
                    Text(confirmLabel)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(tone.color, in: RoundedRectangle(cornerRadius: 14))
                        .shadow(color: tone.color.opacity(0.35), radius: 12, y: 6)
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity)
        .background(AppTheme.bg)
    }
}

// MARK: - Backup Preview Sheet

/// Two-stage import gate: file picker → THIS preview sheet → destructive
/// confirmation. The preview shows the file's contents (card count, tx
/// count, export date, app version) so the user can verify they picked
/// the right file before committing to wipe their existing data. This
/// closes the "I picked the wrong file" footgun that the previous direct
/// picker→confirm flow had.
struct BackupPreviewSheet: View {
    let preview: BackupPreview
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(AppTheme.blue.opacity(0.12))
                        .frame(width: 70, height: 70)
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(AppTheme.blue)
                }
                .padding(.top, 12)

                Text(loc("backup.preview.title"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text(loc("backup.preview.subtitle"))
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            // Metadata card
            VStack(spacing: 0) {
                metadataRow(
                    icon: "calendar",
                    label: loc("backup.preview.exported_at"),
                    value: preview.exportedAtFormatted
                )
                divider
                metadataRow(
                    icon: "info.circle",
                    label: loc("backup.preview.app_version"),
                    value: "v\(preview.appVersion)"
                )
            }
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.cardMid, lineWidth: 1))
            .padding(.horizontal, 22)
            .padding(.top, 18)

            // Counts grid
            VStack(alignment: .leading, spacing: 8) {
                Text(loc("backup.preview.contents"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 22)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    countTile(icon: "creditcard.fill", count: preview.cardCount,
                              label: loc("backup.preview.cards"), color: AppTheme.accent)
                    countTile(icon: "list.bullet.rectangle.fill", count: preview.transactionCount,
                              label: loc("backup.preview.transactions"), color: AppTheme.blue)
                    countTile(icon: "creditcard.trianglebadge.exclamationmark",
                              count: preview.debtCount,
                              label: loc("backup.preview.debts"), color: AppTheme.red)
                    countTile(icon: "target", count: preview.goalCount,
                              label: loc("backup.preview.goals"), color: AppTheme.orange)
                    countTile(icon: "banknote.fill", count: preview.salaryCount,
                              label: loc("backup.preview.salaries"), color: AppTheme.purple)
                }
                .padding(.horizontal, 22)
            }
            .padding(.top, 14)

            Spacer(minLength: 14)

            // Buttons
            HStack(spacing: 12) {
                Button {
                    HapticManager.shared.tap()
                    onCancel()
                } label: {
                    Text(loc("common.cancel"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.cardMid, lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle())

                Button {
                    HapticManager.shared.tap()
                    onContinue()
                } label: {
                    Text(loc("backup.preview.continue"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity)
        .background(AppTheme.bg)
    }

    private func metadataRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(AppTheme.cardMid.opacity(0.5))
            .frame(height: 0.5)
            .padding(.horizontal, 14)
    }

    private func countTile(icon: String, count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.15)).frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.cardMid.opacity(0.4), lineWidth: 1))
    }
}
