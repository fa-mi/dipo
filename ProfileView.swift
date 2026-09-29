import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers   // for `.json` UTType in fileImporter

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
    @State private var isEditingName      = false
    @State private var editNameText       = ""
    @State private var showEmailEdit      = false
    @State private var idCopied           = false
    @State private var emailText          = ""
    @State private var showBackTapGuide = false
    @State private var showWebSync        = false
    @State private var showCleanup        = false
    @State private var showPaywall        = false
    @State private var appearanceMode: String = UserDefaults.standard.string(forKey: "appearance_mode") ?? "system"
    @State private var voiceLanguage = VoiceLanguage.saved
    @State private var premiumMgr  = PremiumManager.shared
    @State private var session     = UserSession.shared
    @State private var showSignOut = false
    @State private var showDeleteAccount = false
    @State private var deletingAccount   = false
    @State private var deleteAccountError: String? = nil
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
    /// Backup/restore result banner. Carries its OWN tone so a success can
    /// never be mistaken for an error — the previous design inferred success
    /// from a leading "✅" the restore path forgot to add, so "Backup restored."
    /// rendered in red as if it had failed.
    @State private var backupToast: BackupBanner? = nil
    /// Newest first. Read once here and refreshed after a restore; a copy
    /// written while this screen is open shows up next time it's opened.
    @State private var autoBackups: [AutoBackup.Entry] = AutoBackup.entries()
    /// A backup/restore result plus its tone. Explicit, so the banner's colour
    /// is set at the call site that knows the outcome, not guessed from text.
    private struct BackupBanner { let isError: Bool; let message: String }
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
                    Spacer(minLength: 4)
                    avatarSection
                    nameSection
                    securityCard
                    if session.isLoggedIn { accountCard }
                    if session.isLoggedIn { emailSection }
                    if session.isLoggedIn { dipoIDSection }
                    premiumBadge
                    featureLinksCard
                    appearanceCard
                    authButtonSection
                    backupSection
                    resetButton
                    supportSection
                    Spacer(minLength: 110)
                }
                // Hard-clamp the column to the scroll viewport. A card without
                // maxWidth takes its content's natural width, so one unbreakable
                // string (an email address, a long translated line) widened the
                // whole page — and a vertical ScrollView still scrolls sideways
                // once its content is wider than its bounds. Clamping makes the
                // children compress instead, whichever one misbehaves.
                .containerRelativeFrame(.horizontal)
            }
        }
        // Pushed from the avatar on Home: the bar carries the back button.
        .navigationTitle(loc("tab.profile"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.bg, for: .navigationBar)
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
                    // Detach this device's push token from the account BEFORE the
                    // session (and Firebase auth) is torn down — otherwise the
                    // next person to sign in on this phone keeps receiving the
                    // previous account's notifications.
                    if let uid {
                        Task { await FirebaseSupportService.shared.unregisterDeviceToken(userId: uid) }
                    }
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
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.bg)
            .presentationCornerRadius(28)
            .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showDeleteAccount) {
            DangerConfirmSheet(
                icon: "trash.fill",
                tone: .danger,
                title: loc("delete_acct.title"),
                message: loc("delete_acct.message"),
                confirmLabel: loc("delete_acct.confirm"),
                onConfirm: { runDeleteAccount() }
            )
        }
        .alert(loc("delete_acct.title"), isPresented: Binding(
            get: { deleteAccountError != nil },
            set: { if !$0 { deleteAccountError = nil } }
        )) {
            Button(loc("common.done"), role: .cancel) { deleteAccountError = nil }
        } message: {
            Text(deleteAccountError ?? "")
        }
        .overlay {
            if deletingAccount {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().tint(.white).scaleEffect(1.2)
                        Text(loc("delete_acct.working"))
                            .font(.system(.subheadline, weight: .medium)).foregroundStyle(.white)
                    }
                    .padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                }
                .transition(.opacity)
            }
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
                    backupToast = BackupBanner(isError: true, message: error.localizedDescription)
                    pendingImportURL = nil
                }
            case .failure(let err):
                backupToast = BackupBanner(isError: true, message: err.localizedDescription)
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
            .presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.bg)
            .presentationCornerRadius(28)
            .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showCleanup) {
            DataCleanupView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showBackTapGuide) {
            BackTapGuideView()
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showWebSync) {
            WebSyncView().presentationDetents([.large]).presentationDragIndicator(.visible)
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
        .trackScreen(.profile)
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
                    Circle().fill(AppTheme.accentFill).frame(width: 32, height: 32)
                    Image(systemName: "camera.fill")
                        .font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.onVividFill)
                }
            }
.accessibilityLabel(loc("a11y.change_photo"))
.hitTarget(32)
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
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.accent.opacity(0.5), lineWidth: 1.5))
                        .submitLabel(.done).onSubmit { saveName() }
                    Button { saveName() } label: {
                        Image(systemName: "checkmark.circle.fill").font(.system(.title)).foregroundStyle(AppTheme.accent)
                    }
.accessibilityLabel(loc("a11y.save_name")).buttonStyle(ScaleButtonStyle())
                    Button { isEditingName = false; editNameText = authVM.savedName } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(.title)).foregroundStyle(AppTheme.textSecondary)
                    }
.accessibilityLabel(loc("common.cancel")).buttonStyle(ScaleButtonStyle())
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
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Image(systemName: "pencil").font(.system(.footnote, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                    }
                }
                .buttonStyle(ScaleButtonStyle())
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
            HStack(spacing: 5) {
                if premiumMgr.plan != .free {
                    Image(systemName: premiumMgr.plan.icon).font(.system(.caption2, weight: .bold)).imageScale(.small)
                        .foregroundStyle(premiumMgr.plan.color)
                }
                Text(premiumMgr.plan == .free ? loc("auth.tagline") : "DiPo \(premiumMgr.plan.label)")
                    .font(.system(.caption, weight: .semibold))
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
                .font(.system(.body)).foregroundStyle(c)
                .frame(width: 36, height: 36)
                .background(c.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.sm))
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("profile.email_title"))
                    .font(.system(.subheadline, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                Text(hasEmail ? (session.email ?? "") : loc("profile.email_not_set"))
                    .font(.system(.caption))
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
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(hasEmail ? AppTheme.accent : .white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(hasEmail ? AppTheme.accent.opacity(0.12) : AppTheme.accent, in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.accent.opacity(hasEmail ? 0.3 : 0), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
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

    /// Shows the user's stable, shareable DiPo ID with a tap-to-copy button.
    /// Read-only — derived from the account, not editable. Uses a distinct
    /// sky→indigo gradient so it stands out from the green (security/email) and
    /// purple (Royal) cards around it.
    @ViewBuilder
    private var dipoIDSection: some View {
        let id = session.dipoID ?? "—"
        let brandA = AppTheme.blue // sky
        let brandB = Color(hex: "#6366F1") // indigo
        let grad = LinearGradient(colors: [brandA, brandB],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        HStack(spacing: 12) {
            Image(systemName: "person.text.rectangle.fill")
                .font(.system(.body)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(grad, in: RoundedRectangle(cornerRadius: AppRadius.sm))
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("profile.dipo_id_title"))
                    .font(.system(.subheadline, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                Text(id)
                    .font(.system(.footnote, design: .monospaced, weight: .bold))
                    .foregroundStyle(brandB)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                HapticManager.shared.tap()
                UIPasteboard.general.string = id
                withAnimation(.spring(response: 0.3)) { idCopied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation(.easeOut) { idCopied = false }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: idCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(.caption2, weight: .semibold))
                    Text(idCopied ? loc("common.copied") : loc("common.copy"))
                        .font(.system(.caption, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(idCopied ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(grad), in: Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(16)
        .background(
            LinearGradient(colors: [brandA.opacity(0.10), brandB.opacity(0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(brandB.opacity(0.30), lineWidth: 1))
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
    }

    @ViewBuilder
    private var securityCard: some View {
        HStack(spacing: 12) {
            let bioColor = authVM.isBiometricAvailable ? AppTheme.accent : AppTheme.textSecondary
            Image(systemName: authVM.biometricIcon).font(.system(.body)).foregroundStyle(bioColor)
                .frame(width: 36, height: 36)
                .background(bioColor.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.sm))
            VStack(alignment: .leading, spacing: 2) {
                Text(authVM.biometricLabel).font(.system(.subheadline, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                Text(
                    authVM.isBiometricAvailable
                    ? (biometricEnabled
                        ? loc("biometric.auto_unlock")
                        : loc("biometric.disabled"))
                    : loc("biometric.unavailable")
                )
                .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                // One line, always. The three states are short enough to fit,
                // and a status that wraps on one of them resizes the card under
                // the switch mid-animation.
                .lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer()
            if authVM.isBiometricAvailable {
                // The glyph in the knob says WHICH protection this is, which a
                // bare capsule beside three other capsules cannot.
                DiPoSwitch(isOn: $biometricEnabled,
                           onIcon: authVM.biometricIcon, offIcon: "lock.open.fill")
                    .onChange(of: biometricEnabled) { _, on in
                        UserDefaults.standard.set(on, forKey: "biometric_enabled")
                    }
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.accent.opacity(0.18), lineWidth: 1))
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
    }

    @ViewBuilder
    private var accountCard: some View {
        HStack(spacing: 14) {
            ZStack {
                let isApple = session.provider == .apple
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .fill(isApple
                        ? LinearGradient(colors: [Color(hex: "#1C1C1E"), Color(hex: "#3A3A3C")], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color(hex: "#4285F4").opacity(0.2), Color(hex: "#34A853").opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.sm)
                        .stroke(isApple ? Color.white.opacity(0.08) : Color(hex: "#4285F4").opacity(0.3), lineWidth: 1))
                if session.provider == .apple {
                    Image(systemName: "apple.logo").font(.system(.body, weight: .medium)).foregroundStyle(.white)
                } else {
                    Text("G").font(.system(.body, weight: .bold)).foregroundStyle(Color(hex: "#4285F4"))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName ?? loc("profile.account"))
                    .font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                HStack(spacing: 4) {
                    let isApple = session.provider == .apple
                    Text(isApple ? "Apple" : "Google")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(isApple ? .white : Color(hex: "#4285F4"))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(isApple ? Color(hex: "#3A3A3C") : Color(hex: "#4285F4").opacity(0.15), in: Capsule())
                    if let email = session.email, !email.isEmpty {
                        Text("· \(email)").font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            Button { HapticManager.shared.tap(); showSignOut = true } label: {
                Text(loc("profile.logout")).font(.system(.caption, weight: .semibold)).foregroundStyle(AppTheme.red)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(AppTheme.red.opacity(0.1), in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.red.opacity(0.3), lineWidth: 1))
            }.buttonStyle(ScaleButtonStyle())
        }
        .padding(16)
        .background(
            LinearGradient(colors: [AppTheme.cardDark, AppTheme.cardDark.opacity(0.8)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).stroke(AppTheme.cardMid.opacity(0.6), lineWidth: 1))
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
        .animation(AppMotion.appear, value: appeared)
    }

    @ViewBuilder
    private var premiumBadge: some View {
        Button { HapticManager.shared.tap(); showPaywall = true } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.sm).fill(planIconFill).frame(width: 44, height: 44)
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.sm)
                            .stroke(premiumMgr.plan == .free ? Color.clear : premiumMgr.plan.color.opacity(0.4), lineWidth: 1))
                    Image(systemName: premiumMgr.plan.icon).font(.system(.body, weight: .medium))
                        .foregroundStyle(premiumMgr.plan == .free ? AppTheme.textSecondary : premiumMgr.plan.color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(premiumMgr.plan == .free ? loc("free.user") : "DiPo \(premiumMgr.plan.label)")
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(premiumMgr.plan == .free ? AppTheme.textPrimary : premiumMgr.plan.color)
                    // Subtitle ternary collapsed from 3-tier to 2-tier
                    // (Premium plan removed). Only Free or Royal possible.
                    let subtitle = premiumMgr.plan == .free
                        ? loc("free.title")
                        : loc("royal.title")
                    Text(subtitle).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if premiumMgr.plan == .free {
                    // Upgrade chip uses Royal's color now — Premium's
                    // amber tone is gone with the tier. Consistent purple
                    // throughout the upgrade journey is also clearer
                    // branding ("this color = paid feature").
                    Text(loc("profile.upgrade")).font(.system(.caption, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(
                            LinearGradient(colors: [PremiumPlan.royal.color, PremiumPlan.royal.color.opacity(0.75)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                } else {
                    Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(premiumMgr.plan.color.opacity(0.7))
                }
            }
            .padding(16)
            .background(planCardFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(premiumMgr.plan == .free ? AppTheme.cardMid.opacity(0.5) : premiumMgr.plan.color.opacity(0.4),
                        lineWidth: premiumMgr.plan == .free ? 1 : 1.5))
        }
        .buttonStyle(ScaleButtonStyle())
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
        .animation(AppMotion.appear, value: appeared)
    }

    @ViewBuilder
    private var featureLinksCard: some View {
        // Money features (budget, salary, bills, savings, Ask DiPo) moved to the
        // Plan tab and Debts & Credits to Wallet. What stays is how DiPo
        // connects to things outside the app.
        VStack(spacing: 12) {
            // Gated on .smartBudget — the same entitlement the Worker checks
            // before serving the dashboard, so the button can't offer something
            // the server will refuse.
            // Gated by Smart Budget's Royal entitlement, but badged as itself —
            // a phone-to-laptop glyph in blue, so it stops reading as a second
            // Smart Budget row three places below the first one.
            PremiumLockedFeatureLink(
                feature: .smartBudget, title: loc("profile.websync"),
                subtitle: premiumMgr.canAccess(.smartBudget)
                    ? loc("profile.websync_sub")
                    : loc("profile.requires_royal"),
                iconOverride: "laptopcomputer.and.iphone",
                tintOverride: AppTheme.teal,
                showPaywall: $showPaywall) { showWebSync = true }

            // Scanning is the Royal-gated part, so the row is gated the same
            // way — the walkthrough would otherwise teach a gesture that dies
            // at the last step.
            PremiumLockedFeatureLink(
                feature: .scanReceipt, title: loc("profile.backtap"),
                subtitle: premiumMgr.canAccess(.scanReceipt)
                    ? loc("profile.backtap_sub")
                    : loc("profile.requires_royal"),
                iconOverride: "hand.tap.fill",
                tintOverride: AppTheme.orange,
                showPaywall: $showPaywall) { showBackTapGuide = true }

            // Tidy and the spending audit moved off Statistics: that screen
            // reports conclusions, and rewriting the rows behind them is a
            // separate job. Gated as it was there — the audit only ever
            // appeared inside the Royal-locked insights card.
            PremiumLockedFeatureLink(
                feature: .smartBudget, title: loc("cleanup.title"),
                subtitle: premiumMgr.canAccess(.smartBudget)
                    ? loc("cleanup.sub")
                    : loc("profile.requires_royal"),
                iconOverride: "wand.and.stars",
                tintOverride: AppTheme.purple,
                showPaywall: $showPaywall) { showCleanup = true }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.green.opacity(0.18), lineWidth: 1))
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .animation(AppMotion.appear, value: appeared)
    }

    /// What the screen is actually showing right now. While the mode is
    /// "system" the environment carries the system's answer, and while it is
    /// pinned the environment carries that pin — either way, what the user sees.
    private var effectiveDark: Bool {
        appearanceMode == "dark" || (appearanceMode != "light" && colorScheme == .dark)
    }

    @ViewBuilder
    private var appearanceCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "circle.lefthalf.filled").font(.system(.body)).foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("profile.appearance")).font(.system(.subheadline, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                    Text(appearanceMode == "system" ? loc("appearance.following_system") : appearanceMode == "dark" ? loc("appearance.dark_mode") : loc("appearance.light_mode"))
                        .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
            }
            Divider().background(AppTheme.cardMid).padding(.vertical, 10)

            // The scene carries the two modes a switch can hold. Which side it
            // shows is always the truth about the screen, including while the
            // system is choosing — then it is muted, and a tap means "I'll take
            // it from here", pinning the opposite of what is on screen, because
            // a tap is a request for something to change.
            DayNightToggle(isDark: effectiveDark, isLive: appearanceMode != "system") {
                HapticManager.shared.tap()
                let next = effectiveDark ? "light" : "dark"
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { appearanceMode = next }
                performAppearanceTransition(to: next)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2).padding(.bottom, 12)

            // The third mode, as its own switch rather than a third position on
            // a two-position control.
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(loc("appearance.system"))
                    .font(.system(.subheadline))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                DiPoSwitch(isOn: Binding(
                    get: { appearanceMode == "system" },
                    set: { on in
                        // Turning it off keeps what is on screen rather than
                        // snapping to a default the user did not ask for.
                        let next = on ? "system" : (colorScheme == .dark ? "dark" : "light")
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { appearanceMode = next }
                        performAppearanceTransition(to: next)
                    }), onIcon: "gearshape.fill", offIcon: "hand.point.up.left.fill")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.textSecondary.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .animation(AppMotion.appear, value: appeared)

        // ── Language Toggle ──────────────────────────────────────────────
        languageSection
            .padding(.horizontal, 22)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)
            .animation(AppMotion.appear, value: appeared)

        voiceLanguageSection
            .padding(.horizontal, 22)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)
            .animation(AppMotion.appear, value: appeared)
    }

    @ViewBuilder
    private var languageSection: some View {
        // LanguageManager is @Observable — accessing it directly creates automatic dependency tracking
        let lang = LanguageManager.shared
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("🌐")
                    .font(.system(.body))
                    .frame(width: 36, height: 36)
                    .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("profile.language"))
                        .font(.system(.subheadline, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                    Text(lang.current.flag + " " + lang.current.nativeName)
                        .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
            }
            Divider().background(AppTheme.cardMid).padding(.vertical, 10)
            SlidingSegments(options: LanguageManager.Language.allCases,
                            selection: lang.current,
                            onSelect: { LanguageManager.shared.current = $0 }) { language, on in
                VStack(spacing: 5) {
                    Text(language.flag).font(.system(.title2))
                    Text(language.nativeName)
                        .font(.system(size: 11, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? AppTheme.onVividFill : AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }

        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.textSecondary.opacity(0.12), lineWidth: 1))
    }   // ← closing brace was missing, causing all subsequent vars to fall inside

    /// Same control as the language card above it — a row of three choices —
    /// because it is the same kind of decision. It was a menu tucked under the
    /// language picker, which read as a detail of it rather than its own setting.
    @ViewBuilder
    private var voiceLanguageSection: some View {
        let lang = LanguageManager.shared
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(.body)).foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("voice.lang_title"))
                        .font(.system(.subheadline, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                    Text(loc("voice.lang_sub"))
                        .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            Divider().background(AppTheme.cardMid).padding(.vertical, 10)
            SlidingSegments(options: VoiceLanguage.allCases,
                            selection: voiceLanguage,
                            onSelect: { voiceLanguage = $0; VoiceLanguage.saved = $0 }) { option, on in
                VStack(spacing: 5) {
                    Group {
                        switch option {
                        case .app:        Image(systemName: "link").font(.system(.title3, weight: .semibold))
                        case .indonesian: Text(LanguageManager.Language.indonesian.flag).font(.system(.title2))
                        case .english:    Text(LanguageManager.Language.english.flag).font(.system(.title2))
                        }
                    }
                    .frame(height: 28)
                    .foregroundStyle(on ? AppTheme.onVividFill : AppTheme.textSecondary)
                    Text(option == .app
                         ? String(format: loc("voice.lang_app_short"), lang.current == .indonesian ? "ID" : "EN")
                         : option.label)
                        .font(.system(size: 11, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? AppTheme.onVividFill : AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .accessibilityLabel(option.label)
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.textSecondary.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder
    private var authButtonSection: some View {
        Group {
            if isSigningIn {
                HStack(spacing: 10) {
                    ProgressView().tint(AppTheme.accent)
                    Text(loc("profile.signing_in")).font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
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
                            .font(.system(.callout))
                        Text(loggedIn ? loc("profile.logout") : loc("profile.login")).font(.system(.subheadline, weight: .medium))
                    }
                    .foregroundStyle(loggedIn ? AppTheme.red : AppTheme.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background((loggedIn ? AppTheme.red : AppTheme.accent).opacity(0.08),
                                in: RoundedRectangle(cornerRadius: AppRadius.md))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke((loggedIn ? AppTheme.red : AppTheme.accent).opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle())

                // Account deletion. Deliberately understated (a text link, not a
                // button) — it's irreversible — but always reachable, which the
                // App Store requires for any app that creates accounts.
                Button {
                    HapticManager.shared.tap()
                    showDeleteAccount = true
                } label: {
                    Text(loc("profile.delete"))
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.red.opacity(0.85))
                        .underline()
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            if let err = loginError {
                InlineBanner(tone: .error, message: err)
            }
        }
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
    }

    private func runDeleteAccount() {
        deletingAccount = true
        Task {
            if let uid = UserSession.shared.userID {
                PremiumManager.shared.onLogout(userID: uid)
            }
            let result = await AccountDeletionService.shared.deleteAccount(context: context)
            deletingAccount = false
            switch result {
            case .success:
                HapticManager.shared.success()
                authVM.resetApp()
            case .requiresRecentLogin:
                HapticManager.shared.error()
                deleteAccountError = loc("delete_acct.relogin")
            case .failed(let msg):
                HapticManager.shared.error()
                deleteAccountError = String(format: loc("delete_acct.failed"), msg)
            }
        }
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
                            .font(.system(.body))
                            .foregroundStyle(AppTheme.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lastExportDate == nil
                                 ? loc("backup.reminder.never_title")
                                 : loc("backup.reminder.stale_title"))
                                .font(.system(.footnote, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(backupReminderSubtitle)
                                .font(.system(.caption2))
                                .foregroundStyle(AppTheme.textSecondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(12)
                    .background(AppTheme.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).stroke(AppTheme.orange.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle())
            }

            // Section header so users understand what they're touching
            HStack(spacing: 6) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(loc("backup.section_title"))
                    .font(.system(.caption, weight: .semibold))
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
                        Image(systemName: "square.and.arrow.up").font(.system(.subheadline, weight: .semibold))
                        Text(loc("backup.export")).font(.system(.subheadline, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(AppTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.md))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.accent.opacity(0.25), lineWidth: 1))
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
                        Image(systemName: "square.and.arrow.down").font(.system(.subheadline, weight: .semibold))
                        Text(loc("backup.import")).font(.system(.subheadline, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.blue)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(AppTheme.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.md))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.blue.opacity(0.25), lineWidth: 1))
                    .opacity(isDisabled ? 0.5 : 1)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(isDisabled)
            }

            // DiPo's own daily copies (DiPo/AutoBackup.swift). Restoring one
            // goes through the same preview → confirm steps as a picked file.
            if UserSession.shared.isLoggedIn, let latest = autoBackups.first {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(String(format: loc("backup.auto.last"), Self.autoBackupDate(latest.date)))
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Menu {
                        ForEach(autoBackups) { entry in
                            Button {
                                previewAutoBackup(entry)
                            } label: {
                                Text(entry.reason == .beforeRestore
                                     ? String(format: loc("backup.auto.before_restore"), Self.autoBackupDate(entry.date))
                                     : Self.autoBackupDate(entry.date))
                            }
                        }
                    } label: {
                        Text(loc("backup.auto.restore"))
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(AppTheme.blue)
                    }
                    .disabled(backupBusyLabel != nil)
                }
                Text(loc("backup.auto.note"))
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !UserSession.shared.isLoggedIn {
                // Tell the user why the buttons are dimmed instead of
                // letting them silently wonder. Subtle inline hint —
                // matches existing `backup.subtitle` styling.
                Text(loc("backup.login_required"))
                    .font(.system(.caption2, weight: .medium))
                    .foregroundStyle(AppTheme.red.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            Text(loc("backup.subtitle"))
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if let toast = backupToast {
                // Tone comes from the banner's own flag, set by whichever path
                // produced it — never inferred from the message text. InlineBanner
                // handles icon + colour + background so the feedback matches every
                // other form in the app.
                InlineBanner(tone: toast.isError ? .error : .success, message: toast.message)
            }
        }
        .padding(.horizontal, 22)
        .opacity(appeared ? 1 : 0)
    }

    @ViewBuilder
    private var resetButton: some View {
        Button { HapticManager.shared.warning(); showResetConfirm = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "trash.fill").font(.system(.callout))
                Text(loc("profile.reset_all")).font(.system(.subheadline, weight: .medium))
            }
            .foregroundStyle(AppTheme.red).frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(AppTheme.red.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.red.opacity(0.25), lineWidth: 1))
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
                            .font(.system(.body)).foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 36, height: 36)
                            .background(AppTheme.textSecondary.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc("profile.support"))
                                .font(.system(.subheadline, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                            Text(loc("profile.support_needs_email"))
                                .font(.system(.caption)).foregroundStyle(AppTheme.orange)
                        }
                        Spacer()
                        Image(systemName: "lock.fill").font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(14)
                    .background(AppTheme.cardDark.opacity(0.6), in: RoundedRectangle(cornerRadius: AppRadius.md))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.orange.opacity(0.2), lineWidth: 1))
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
        .animation(AppMotion.appear, value: appeared)
    }

    // MARK: - Actions

    private func saveName() {
        let trimmed = editNameText.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return }
        Keychain.save(trimmed, key: "user_name")
        // Home greets the user by name and caches it; tell it the name moved.
        NotificationCenter.default.post(name: .profilePhotoDidChange, object: nil)
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
        try? context.delete(model: CycleIntent.self)
        try? context.delete(model: RecurringExpense.self)
        try? context.save()
        UserDefaults.standard.removeObject(forKey: "profile_photo")
        profileImage = nil
        // Wipe Smart Budget settings too — the user expects "Reset All Data"
        // to be exhaustive. Without this, ratios + master toggle would survive
        // the wipe and reapply to whichever account signs in next.
        SmartBudgetManager.shared.resetAllSettings()
        // "Already sent this cycle" flags are keyed by cycle/debt/day, not by
        // the data they described. Left behind, a user who resets mid-cycle
        // gets no budget or overspend alert until the next payday — the app
        // silently stops warning them right when they've started over.
        NotificationManager.clearDeliveryDedupState()
        // "Reset All Data" has to mean the Home Screen too, otherwise the
        // widget keeps displaying the figures the user just erased.
        WidgetDataSync.clear()
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
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 26)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .transition(.opacity)
        }
    }

    /// Same first step as a picked file: parse, then show the preview sheet.
    private func previewAutoBackup(_ entry: AutoBackup.Entry) {
        backupToast = nil
        pendingImportURL = entry.url
        do {
            importPreview = try BackupService.previewBackup(from: entry.url)
        } catch {
            backupToast = BackupBanner(isError: true, message: error.localizedDescription)
            pendingImportURL = nil
        }
    }

    private static func autoBackupDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = LanguageManager.shared.currentLocale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
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
                // Clears any pending nudge and restarts the 30-day clock.
                NotificationManager.markBackupTaken()
                NotificationManager.scheduleBackupReminder()
                lastExportDate = now
            } catch {
                backupBusyLabel = nil
                backupToast = BackupBanner(isError: true, message: error.localizedDescription)
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
                // Import replaces everything. Keep what is here first, so
                // restoring the wrong file can itself be undone. Fails
                // harmlessly (noData) on an empty device.
                try? AutoBackup.write(context: context, reason: .beforeRestore)
                try BackupService.importBackup(from: url, context: context)
                autoBackups = AutoBackup.entries()
                backupBusyLabel = nil
                backupToast = BackupBanner(isError: false, message: loc("backup.import_success"))
                HapticManager.shared.success()
            } catch {
                backupBusyLabel = nil
                backupToast = BackupBanner(isError: true, message: error.localizedDescription)
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
