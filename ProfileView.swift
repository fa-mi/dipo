import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers   // for `.json` UTType in fileImporter

// MARK: - Profile View

struct ProfileView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var authVM: AuthViewModel
    /// Arrived from a feature that needs an account: the sign-in sheet opens
    /// once, on arrival, for someone not signed in.
    var opensSignIn = false
    @State private var offeredSignIn = false
    @Environment(\.modelContext) private var context

    /// Live card list — used by `shouldShowBackupReminder` to decide
    /// whether the user has any data worth nagging them to back up.
    /// `@Query` makes it reactive so the banner appears/disappears when
    /// cards are added/deleted without a full Profile re-mount.
    @Query(sort: \BankCard.sortOrder) private var liveCards: [BankCard]

    @State private var showResetConfirm   = false
    @State private var isEditingName      = false
    @State private var editNameText       = ""
    @State private var showEmailEdit      = false
    @State private var idCopied           = false
    @State private var emailText          = ""
    @State private var showBackTapGuide = false
    @State private var showInterests = false
    @State private var showWebSync        = false
    @State private var showCleanup        = false
    @State private var showPaywall        = false
    @State private var showNotificationPrefs = false
    @State private var appearanceMode: String = UserDefaults.standard.string(forKey: "appearance_mode") ?? "system"
    @State private var voiceLanguage = VoiceLanguage.saved
    /// DiPo's face on Home (his row and the stand-in avatar). On this device.
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

    // MARK: - Body

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                        .padding(.top, 8)
                    if !session.isLoggedIn {
                        signInSection
                            .padding(.top, 22)
                    }
                    VStack(alignment: .leading, spacing: 26) {
                        accountSection
                        featuresSection
                        settingsSection
                        backupSection
                        helpSection
                        leaveSection
                    }
                    .padding(.top, 28)
                    Spacer(minLength: 110)
                }
                .padding(.horizontal, 22)
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
                    backupToast = BackupBanner(isError: true, message: UserFacingError.message(error))
                    pendingImportURL = nil
                }
            case .failure(let err):
                backupToast = BackupBanner(isError: true, message: UserFacingError.message(err))
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
        .sheet(isPresented: $showNotificationPrefs) {
            NotificationSettingsView()
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showInterests) {
            DiPoInterestsView()
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
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
        .onAppear {
            guard opensSignIn, !offeredSignIn, !session.isLoggedIn else { return }
            offeredSignIn = true
            showSignInSheet = true
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
        .trackScreen(.profile)
    }

    // MARK: - Sub-Views
    //
    // The screen is a few grouped lists (DiPo/ListRows.swift): a quiet title,
    // rows on one card, a coloured icon with nothing behind it. It used to be
    // a card per setting, most with a border, a tinted tile and a tinted pill
    // of a button, and the feature rows were cards inside a card.

    /// Photo, name, and the plan or DiPo's tagline. No glow and no ring round
    /// the photo: the plan is said in words under the name.
    @ViewBuilder
    private var header: some View {
        VStack(spacing: 14) {
            avatarSection
            nameSection
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var avatarSection: some View {
        ZStack {
            Circle().fill(AppTheme.cardDark).frame(width: 96, height: 96)
            if let img = profileImage {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: 96, height: 96).clipShape(Circle())
            } else {
                Image("DiPoMascot").resizable().scaledToFill()
                    .frame(width: 96, height: 96).clipShape(Circle())
                    .blendMode(colorScheme == .dark ? .screen : .multiply)
            }
            Button { showPhotoOptions = true } label: {
                Image(systemName: "camera.fill")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 30, height: 30)
                    .background(AppTheme.cardMid, in: Circle())
            }
            .accessibilityLabel(loc("a11y.change_photo"))
            .hitTarget(30)
            .buttonStyle(ScaleButtonStyle())
            .offset(x: 34, y: 34)
        }
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
        VStack(spacing: 6) {
            if isEditingName {
                HStack(spacing: 8) {
                    TextField(loc("auth.name_placeholder"), text: $editNameText)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
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
            if premiumMgr.plan == .free {
                Text(loc("auth.tagline"))
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: premiumMgr.plan.icon).imageScale(.small)
                    Text("DiPo \(premiumMgr.plan.label)")
                }
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(premiumMgr.plan.color)
            }
        }
    }

    /// Signed out, signing in is what this screen is for — it turns on
    /// backup, support and savings goals — so it is the one green button.
    @ViewBuilder
    private var signInSection: some View {
        VStack(spacing: 10) {
            if isSigningIn {
                HStack(spacing: 10) {
                    ProgressView().tint(AppTheme.accent)
                    Text(loc("profile.signing_in")).font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
            } else {
                Button {
                    HapticManager.shared.tap()
                    showSignInSheet = true
                } label: {
                    Text(loc("profile.login"))
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                }
                .buttonStyle(ScaleButtonStyle())
            }
            if let err = loginError {
                InlineBanner(tone: .error, message: err)
            }
        }
    }

    // MARK: Account

    /// Who is signed in, the address support replies to, the DiPo ID, and
    /// the plan. Signed out, only the plan.
    @ViewBuilder
    private var accountSection: some View {
        ListSection(loc("profile.account")) {
            if session.isLoggedIn {
                accountRow
                ListDivider()
                emailRow
                ListDivider()
                dipoIDRow
                ListDivider()
            }
            planRow
        }
    }

    /// The account and what it signs in with. Signing out is at the bottom
    /// of the screen, once; this row used to carry a second Log Out button.
    private var accountRow: some View {
        let isApple = session.provider == .apple
        return ListRow(title: session.displayName ?? loc("profile.account"),
                       subtitle: isApple ? "Apple" : "Google") {
            if isApple {
                Image(systemName: "apple.logo")
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
            } else {
                Text("G")
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(Color(hex: "#4285F4"))
            }
        } trailing: {
            EmptyView()
        }
    }

    /// The address support replies to. A tap edits it; without one, the
    /// line under it says why it is needed.
    private var emailRow: some View {
        let email = session.email ?? ""
        let hasEmail = !email.isEmpty
        return Button {
            HapticManager.shared.tap()
            emailText = email
            showEmailEdit = true
        } label: {
            ListRow(icon: hasEmail ? "envelope.fill" : "envelope.badge",
                    tint: hasEmail ? AppTheme.accent : AppTheme.orange,
                    title: loc("profile.email_title"),
                    subtitle: hasEmail ? email : loc("profile.email_not_set"),
                    subtitleTint: hasEmail ? AppTheme.textSecondary : AppTheme.orange) {
                ListAction(title: hasEmail ? loc("common.edit") : loc("profile.add_email"))
            }
        }
        .buttonStyle(.plain)
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

    /// The user's stable, shareable DiPo ID, read-only. A tap copies it.
    private var dipoIDRow: some View {
        let id = session.dipoID ?? "—"
        return Button {
            HapticManager.shared.tap()
            UIPasteboard.general.string = id
            withAnimation(.spring(response: 0.3)) { idCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.easeOut) { idCopied = false }
            }
        } label: {
            ListRow(icon: "person.text.rectangle.fill", tint: AppTheme.blue,
                    title: loc("profile.dipo_id_title"), subtitle: id,
                    subtitleTint: AppTheme.textPrimary,
                    subtitleFont: .system(.footnote, design: .monospaced, weight: .semibold)) {
                ListAction(title: idCopied ? loc("common.copied") : loc("common.copy"),
                           icon: idCopied ? "checkmark" : "doc.on.doc",
                           tint: idCopied ? AppTheme.accent : AppTheme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(session.dipoID == nil)
    }

    /// Free with the way to Royal, or Royal. Opens the plans.
    private var planRow: some View {
        let plan = premiumMgr.plan
        return Button {
            HapticManager.shared.tap()
            showPaywall = true
        } label: {
            ListRow(icon: plan.icon, tint: plan.color,
                    title: plan == .free ? loc("free.user") : "DiPo \(plan.label)",
                    subtitle: plan == .free ? loc("free.title") : loc("royal.title")) {
                if plan == .free {
                    // The screen's one ask to pay, in Royal's colour.
                    Text(loc("profile.upgrade"))
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(PremiumPlan.royal.color, in: Capsule())
                        .fixedSize()
                } else {
                    ListChevron()
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Features

    /// How DiPo connects to things outside the app, and how it is tuned. Money
    /// features (budget, salary, bills, savings, Ask DiPo) live on the Plan
    /// tab. One list: these were a card of cards, with Notifications in a card
    /// of its own beneath.
    @ViewBuilder
    private var featuresSection: some View {
        ListSection(loc("profile.section_features")) {
            // Gated by Smart Budget's Royal entitlement — the same one the
            // Worker checks before serving the dashboard, so the row can't
            // offer something the server will refuse — but badged as itself,
            // a phone-to-laptop glyph, so it stops reading as a second Smart
            // Budget row.
            PremiumLockedFeatureLink(
                feature: .smartBudget, title: loc("profile.websync"),
                subtitle: loc("profile.websync_sub"),
                iconOverride: "laptopcomputer.and.iphone", tintOverride: AppTheme.teal,
                showPaywall: $showPaywall) { showWebSync = true }
            ListDivider()
            // Scanning is the Royal-gated part, so the row is gated the same
            // way — the walkthrough would otherwise teach a gesture that dies
            // at the last step.
            PremiumLockedFeatureLink(
                feature: .scanReceipt, title: loc("profile.backtap"),
                subtitle: loc("profile.backtap_sub"),
                iconOverride: "hand.tap.fill", tintOverride: AppTheme.orange,
                showPaywall: $showPaywall) { showBackTapGuide = true }
            ListDivider()
            // What DiPo knows the user enjoys; he guesses, they decide.
            PremiumLockedFeatureLink(
                feature: .aiAdvisor, title: loc("interest.profile_title"),
                subtitle: loc("interest.profile_sub"),
                iconOverride: "heart.text.square.fill", tintOverride: AppTheme.orange,
                showPaywall: $showPaywall) { showInterests = true }
            ListDivider()
            // Tidy and the spending audit moved off Statistics: that screen
            // reports conclusions, and rewriting the rows behind them is a
            // separate job. Gated as it was there — the audit only ever
            // appeared inside the Royal-locked insights card.
            PremiumLockedFeatureLink(
                feature: .smartBudget, title: loc("cleanup.title"),
                subtitle: loc("cleanup.sub"),
                iconOverride: "wand.and.stars", tintOverride: AppTheme.purple,
                showPaywall: $showPaywall) { showCleanup = true }
            ListDivider()
            // Which reminders DiPo sends, a switch for each kind. Without it the
            // only way to quiet the budget alerts was to silence DiPo in iOS
            // Settings, and with them the debt due dates that save a late fee.
            ProfileFeatureLink(icon: "bell.badge.fill", color: AppTheme.orange,
                               title: loc("notifpref.title"), subtitle: loc("notifpref.link_sub")) {
                showNotificationPrefs = true
            }
        }
    }

    // MARK: Settings

    /// This phone's settings: the lock, the look, the languages.
    @ViewBuilder
    private var settingsSection: some View {
        ListSection(loc("profile.section_settings")) {
            securityRow
            ListDivider()
            appearanceBlock
            ListDivider()
            languageBlock
            ListDivider()
            voiceLanguageBlock
        }
    }

    private var securityRow: some View {
        let available = authVM.isBiometricAvailable
        let status = available
            ? (biometricEnabled ? loc("biometric.auto_unlock") : loc("biometric.disabled"))
            : loc("biometric.unavailable")
        // One line, always. The three states are short enough to fit, and a
        // status that wraps on one of them resizes the row under the switch
        // mid-animation.
        return ListRow(icon: authVM.biometricIcon,
                       tint: available ? AppTheme.accent : AppTheme.textSecondary,
                       title: authVM.biometricLabel, subtitle: status, subtitleLines: 1) {
            if available {
                // The glyph in the knob says WHICH protection this is, which a
                // bare capsule beside the other switches cannot.
                DiPoSwitch(isOn: $biometricEnabled,
                           onIcon: authVM.biometricIcon, offIcon: "lock.open.fill")
                    .onChange(of: biometricEnabled) { _, on in
                        UserDefaults.standard.set(on, forKey: "biometric_enabled")
                    }
            }
        }
    }

    /// What the screen is actually showing right now. While the mode is
    /// "system" the environment carries the system's answer, and while it is
    /// pinned the environment carries that pin — either way, what the user sees.
    private var effectiveDark: Bool {
        appearanceMode == "dark" || (appearanceMode != "light" && colorScheme == .dark)
    }

    private var appearanceStatus: String {
        switch appearanceMode {
        case "system": return loc("appearance.following_system")
        case "dark":   return loc("appearance.dark_mode")
        default:       return loc("appearance.light_mode")
        }
    }

    @ViewBuilder
    private var appearanceBlock: some View {
        VStack(spacing: 0) {
            ListRow(icon: "circle.lefthalf.filled", tint: AppTheme.textPrimary,
                    title: loc("profile.appearance"), subtitle: appearanceStatus)
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
            .padding(.bottom, 2)
            // The third mode, as its own switch rather than a third position on
            // a two-position control.
            ListRow(icon: "iphone", tint: AppTheme.textSecondary, title: loc("appearance.system")) {
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
        }
    }

    /// The choices below the title name the language, so the row doesn't
    /// repeat it in a line of its own.
    @ViewBuilder
    private var languageBlock: some View {
        // LanguageManager is @Observable — reading it here tracks it.
        let lang = LanguageManager.shared
        VStack(spacing: 0) {
            ListRow(icon: "globe", tint: AppTheme.textPrimary, title: loc("profile.language"))
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
            .padding([.horizontal, .bottom], ListRowMetrics.inset)
        }
    }

    /// Same control as the language above it — a row of choices — because it
    /// is the same kind of decision. It was a menu tucked under the language
    /// picker, which read as a detail of it rather than its own setting.
    @ViewBuilder
    private var voiceLanguageBlock: some View {
        let lang = LanguageManager.shared
        VStack(spacing: 0) {
            ListRow(icon: "waveform", tint: AppTheme.textPrimary,
                    title: loc("voice.lang_title"), subtitle: loc("voice.lang_sub"))
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
            .padding([.horizontal, .bottom], ListRowMetrics.inset)
        }
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

    /// Save a snapshot of the entire dataset to a JSON file (Back up), or
    /// replace local data with a saved one (Restore). This is the recommended
    /// migration path when changing devices since the app intentionally has no
    /// server-side mirror.
    @ViewBuilder
    private var backupSection: some View {
        // Backups are tied to the logged-in user (each export embeds `userID`,
        // each import checks it). Every row waits for sign-in, so the user
        // can't even attempt an operation that would just throw `.notLoggedIn`.
        let isLoggedIn = session.isLoggedIn
        let isDisabled = backupBusyLabel != nil || !isLoggedIn
        VStack(alignment: .leading, spacing: 10) {
            ListSection(loc("backup.section_title")) {
                // Reminder — surfaces ONLY when the user has data worth
                // protecting but hasn't backed up recently. Solves the
                // worst-case "user never exports → loses everything" failure
                // mode without nagging users who don't need it.
                if shouldShowBackupReminder {
                    Button {
                        HapticManager.shared.tap()
                        runExport()
                    } label: {
                        ListRow(icon: lastExportDate == nil ? "exclamationmark.circle.fill" : "clock.arrow.circlepath",
                                tint: AppTheme.orange,
                                title: lastExportDate == nil
                                    ? loc("backup.reminder.never_title")
                                    : loc("backup.reminder.stale_title"),
                                subtitle: backupReminderSubtitle) {
                            ListChevron()
                        }
                        .opacity(isDisabled ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                    ListDivider()
                }
                Button {
                    HapticManager.shared.tap()
                    runExport()
                } label: {
                    ListRow(icon: "square.and.arrow.up", tint: AppTheme.accent, title: loc("backup.export")) {
                        ListChevron()
                    }
                    .opacity(isDisabled ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                ListDivider()
                Button {
                    HapticManager.shared.tap()
                    showImportPicker = true
                } label: {
                    ListRow(icon: "square.and.arrow.down", tint: AppTheme.blue, title: loc("backup.import")) {
                        ListChevron()
                    }
                    .opacity(isDisabled ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            }

            Group {
                // DiPo's own daily copies (DiPo/AutoBackup.swift). Restoring one
                // goes through the same preview → confirm steps as a picked file.
                if isLoggedIn, let latest = autoBackups.first {
                    HStack(spacing: 8) {
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
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        .disabled(backupBusyLabel != nil)
                    }
                    Text(loc("backup.auto.note"))
                }
                if !isLoggedIn {
                    // Says why the rows are dimmed instead of leaving the user
                    // to wonder. Not an error, so not red.
                    Text(loc("backup.login_required"))
                }
                Text(loc("backup.subtitle"))
            }
            .font(.system(.caption2))
            .foregroundStyle(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)

            if let toast = backupToast {
                // Tone comes from the banner's own flag, set by whichever path
                // produced it — never inferred from the message text. InlineBanner
                // handles icon + colour + background so the feedback matches every
                // other form in the app.
                InlineBanner(tone: toast.isError ? .error : .success, message: toast.message)
            }
        }
    }

    // MARK: - Help

    /// Support requires both login AND an email on file — the email is how
    /// we reply. Signed in without one, the row asks for the email first.
    @ViewBuilder
    private var helpSection: some View {
        let needsEmail = session.isLoggedIn && (session.email ?? "").isEmpty
        ListSection(loc("plan.section_help")) {
            if needsEmail {
                Button {
                    HapticManager.shared.tap()
                    emailText = ""
                    showEmailEdit = true
                } label: {
                    ListRow(icon: "headphones.circle.fill", tint: AppTheme.textSecondary,
                            title: loc("profile.support"),
                            subtitle: loc("profile.support_needs_email"),
                            subtitleTint: AppTheme.orange) {
                        ListChevron()
                    }
                }
                .buttonStyle(.plain)
            } else {
                ProfileFeatureLink(icon: "headphones.circle.fill", color: AppTheme.blue,
                                   title: loc("profile.support"),
                                   subtitle: loc("profile.subcs")) {
                    // Signed in before support opens: Firestore rules need
                    // request.auth != null to allow writes.
                    if session.isLoggedIn {
                        showContact = true
                    } else {
                        showContactAfterLogin = true
                        showSignInSheet       = true
                    }
                }
            }
        }
    }

    // MARK: - Leaving

    /// At the end of the screen, where they can't be hit on the way to
    /// something else: sign out (the data stays on this phone), erase this
    /// phone's data, and delete the account.
    @ViewBuilder
    private var leaveSection: some View {
        VStack(spacing: 12) {
            ListSection {
                if session.isLoggedIn {
                    Button {
                        HapticManager.shared.tap()
                        showSignOut = true
                    } label: {
                        ListButtonLabel(title: loc("profile.logout"))
                    }
                    .buttonStyle(.plain)
                    ListDivider(flush: true)
                }
                Button {
                    HapticManager.shared.warning()
                    showResetConfirm = true
                } label: {
                    ListButtonLabel(title: loc("profile.reset_all"))
                }
                .buttonStyle(.plain)
            }
            // Account deletion. Deliberately understated (a text link, not a
            // button) — it's irreversible — but always there while signed in,
            // which the App Store requires for any app that creates accounts.
            // Signed out there is no account here to delete: the link only
            // ever ended in "Not signed in."
            if session.isLoggedIn {
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
                .frame(maxWidth: .infinity)
            }
        }
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
        // Every record of every model, and the pushes that speak about them.
        // This used to be its own list, and loans, instalments, investments,
        // assets and the review queue all survived a reset
        // (DiPo/LocalDataWipe.swift).
        LocalDataWipe.deleteAllRecords(in: context)
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
            backupToast = BackupBanner(isError: true, message: UserFacingError.message(error))
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
                backupToast = BackupBanner(isError: true, message: UserFacingError.message(error))
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
                backupToast = BackupBanner(isError: true, message: UserFacingError.message(error))
                HapticManager.shared.error()
            }
            pendingImportURL = nil
        }
    }

    private func doSignInWithApple() {
        isSigningIn = true; loginError = nil
        appleCoordinator.onSuccess = { credential, nonce in
            session.handleAppleCredential(credential, rawNonce: nonce)
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
