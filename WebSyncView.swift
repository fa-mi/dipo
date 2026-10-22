import SwiftUI
import SwiftData

// MARK: - Sync to Web Version
//
// The phone half of the Statistics Dashboard. Its job is narrow: hand the user
// their DiPo ID, then push a snapshot.
//
// The screen is ordered by what the user has to DO, not by what the feature IS.
// The ID comes first because it is the step that happens on the other device,
// and the one people forget.
//
// ORDER DOES NOT MATTER, despite what the three steps imply. The app writes to
// `webSync/{uid}` unconditionally and the Worker reads whatever snapshot is
// there, so a snapshot may predate the browser session entirely — syncing first
// actually renders faster, since the page finds data on its first poll instead
// of waiting for one. Either way the page also needs the access code shown
// here after the sync (see WebSyncService.accessCode): the DiPo ID alone is
// not enough, because it is shared with friends for invites.
//
// What the order DOES cost is time: the 24-hour window starts at sync, not at
// first view. Sync tonight, open the laptop tomorrow afternoon, and it has
// already expired. That is why the success state names the remaining step
// instead of only reporting that the upload worked.
struct WebSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var service = WebSyncService.shared
    @State private var session = UserSession.shared
    @State private var idCopied = false
    @State private var codeCopied = false
    @State private var showRevokeConfirm = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var dipoID: String { session.dipoID ?? "—" }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        header
                        statusCard
                        if service.needsReconnect { reconnectCard }
                        keysCard
                        howCard
                        syncButton
                        if service.lastSyncedAt != nil { revokeLink }
                        Spacer(minLength: 28)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("websync.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
            // Covers the whole sheet while a sync runs. A full surface rather
            // than an inline spinner because the three stages are the only
            // thing that matters during those seconds, and because it also
            // blocks a second tap on Sync mid-upload.
            .overlay {
                if isUploading { SyncProgressOverlay(phase: service.phase) }
            }
        }
        .confirmSheet(isPresented: $showRevokeConfirm,
                      icon: "eye.slash.fill",
                      tone: .warning,
                      title: loc("websync.revoke_title"),
                      message: loc("websync.revoke_body"),
                      confirmLabel: loc("websync.revoke_action")) {
            Task { await service.revoke() }
        }
        .trackScreen(.webSync)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.12)).frame(width: 44, height: 44)
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
            }
            Text(loc("websync.header"))
                .font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }

    // MARK: The two keys
    //
    // People asked why there are two codes. They are the account number and
    // the PIN: the DiPo ID never changes and is shared with friends for
    // invites, so on its own it opens nothing; the code is new every sync
    // and is what proves it's them. Side by side, each says which it is.

    /// The code for the snapshot that is still readable, if any.
    private var liveAccessCode: String? {
        guard let code = service.accessCode, let at = service.lastSyncedAt,
              Date() < at.addingTimeInterval(WebSyncService.snapshotLifetime) else { return nil }
        return code
    }

    private var keysCard: some View {
        let code = liveAccessCode
        return VStack(alignment: .leading, spacing: 10) {
            Text(loc("websync.login_title"))
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            // Side by side, the same height; stacked at the accessibility
            // text sizes, where two columns can't hold an eight-letter ID.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) { idTile; codeTile(code) }
            } else {
                HStack(alignment: .top, spacing: 10) { idTile; codeTile(code) }
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(loc("websync.code_hint"), systemImage: "lock.fill")
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var idTile: some View {
        keyTile(label: loc("websync.id_label"), icon: "number", value: dipoID, caption: loc("websync.id_like"),
                copied: $idCopied, copyable: session.dipoID != nil)
    }

    private func codeTile(_ code: String?) -> some View {
        keyTile(label: loc("websync.code_label"), icon: "lock.fill", value: code ?? "••••••",
                caption: loc(code == nil ? "websync.code_pending" : "websync.code_like"),
                copied: $codeCopied, copyable: code != nil)
    }

    private func keyTile(label: String, icon: String, value: String, caption: String,
                         copied: Binding<Bool>, copyable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: icon)
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(AppTheme.textSecondary)
            Text(value)
                .font(.system(.title3, design: .monospaced, weight: .bold))
                .tracking(copyable ? 1.5 : 3)
                .foregroundStyle(copyable ? AppTheme.textPrimary : AppTheme.textSecondary.opacity(0.45))
                .lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityLabel(copyable ? value.map(String.init).joined(separator: " ") : caption)
            Text(caption)
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            copyButton(value, copied: copied)
                .disabled(!copyable)
                .opacity(copyable ? 1 : 0.35)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.bg.opacity(0.7), in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.accent.opacity(0.18), lineWidth: 1))
    }

    private func copyButton(_ value: String, copied: Binding<Bool>) -> some View {
        Button {
            HapticManager.shared.tap()
            UIPasteboard.general.string = value
            withAnimation(.spring(response: 0.3)) { copied.wrappedValue = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeOut) { copied.wrappedValue = false }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied.wrappedValue ? "checkmark" : "doc.on.doc")
                    .font(.system(.caption2, weight: .bold))
                Text(copied.wrappedValue ? loc("common.copied") : loc("common.copy"))
                    .font(.system(.caption, weight: .semibold))
            }
            .foregroundStyle(copied.wrappedValue ? AppTheme.bg : AppTheme.accent)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(copied.wrappedValue ? AnyShapeStyle(AppTheme.accent)
                                            : AnyShapeStyle(AppTheme.accent.opacity(0.14)), in: Capsule())
        }
        .buttonStyle(ScaleButtonStyle())
    }

    // MARK: How

    /// Three short lines, in the order they're done. The first names the
    /// button as it reads right now, Sync Now or Sync Again.
    private var howCard: some View {
        let action = loc(service.lastSyncedAt == nil ? "websync.action" : "websync.action_again")
        return VStack(alignment: .leading, spacing: 10) {
            howRow(1, String(format: loc("websync.how1"), action))
            howRow(2, loc("websync.how2"))
            howRow(3, loc("websync.how3"))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func howRow(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(n)")
                .font(.system(.caption, weight: .heavy))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 22, height: 22)
                .background(AppTheme.accent.opacity(0.14), in: Circle())
            // **bold** in the string marks what to look for on screen.
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .font(.system(.subheadline))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusCard: some View {
        switch service.state {
        case .failure(let message):
            statusBox(icon: "exclamationmark.triangle.fill", tint: AppTheme.red,
                      title: loc("websync.failed"), detail: message)
        case .success:
            if let at = service.lastSyncedAt {
                // The 24-hour clock starts here, not when the page is opened,
                // so the line says by when to open it.
                statusBox(icon: "checkmark.circle.fill", tint: AppTheme.accent,
                          title: loc("websync.synced"),
                          detail: String(format: loc("websync.valid_until"),
                                         Self.stamp(at.addingTimeInterval(WebSyncService.snapshotLifetime))),
                          inline: true)
            }
        default:
            if let at = service.lastSyncedAt {
                statusBox(icon: "clock.arrow.circlepath", tint: AppTheme.textSecondary,
                          title: String(format: loc("websync.last_synced"), Self.stamp(at)),
                          detail: loc("websync.replace_hint"))
            }
        }
    }

    /// `inline`: title and detail on one line, for a short success.
    private func statusBox(icon: String, tint: Color, title: String, detail: String,
                           inline: Bool = false) -> some View {
        HStack(alignment: inline ? .center : .top, spacing: 10) {
            Image(systemName: icon).font(.system(.subheadline)).foregroundStyle(tint)
                .padding(.top, inline ? 0 : 1)
            if inline {
                Text(Self.oneLine(title, detail))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    Text(detail).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(1.5)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(tint.opacity(0.2), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Actions

    private var isUploading: Bool { service.state == .uploading }

    /// After a reinstall the DiPo ID still points at the old install. One
    /// sign-in with the same Apple ID or Google account brings it here, and
    /// the sync runs again. See AccountReconnect.
    private var reconnectCard: some View {
        let google = session.provider == .google
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                HapticManager.shared.tap()
                Task { await service.reconnect(context: context) }
            } label: {
                HStack(spacing: 9) {
                    if service.isReconnecting {
                        ProgressView().tint(AppTheme.textPrimary).scaleEffect(0.85)
                    } else {
                        Image(systemName: google ? "g.circle.fill" : "apple.logo")
                            .font(.system(.subheadline, weight: .semibold))
                    }
                    Text(loc(service.isReconnecting ? "websync.reconnecting" : "websync.reconnect"))
                        .font(.system(.callout, weight: .semibold))
                }
                .foregroundStyle(AppTheme.textPrimary)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.cardMid, lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(service.isReconnecting || isUploading)

            Text(loc(google ? "websync.reconnect_hint_google" : "websync.reconnect_hint_apple"))
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var syncButton: some View {
        Button {
            Task { await service.sync(context: context) }
        } label: {
            HStack(spacing: 9) {
                if isUploading {
                    ProgressView().tint(AppTheme.bg).scaleEffect(0.85)
                } else {
                    Image(systemName: "arrow.up.to.line").font(.system(.subheadline, weight: .bold))
                }
                Text(isUploading ? loc("websync.uploading")
                                 : (service.lastSyncedAt == nil ? loc("websync.action")
                                                                : loc("websync.action_again")))
                    .font(.system(.callout, weight: .bold))
            }
            .foregroundStyle(AppTheme.bg)
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(isUploading)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isUploading)
    }

    private var revokeLink: some View {
        Button {
            HapticManager.shared.tap()
            showRevokeConfirm = true
        } label: {
            Text(loc("websync.revoke_action"))
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(AppTheme.red.opacity(0.9))
        }
        .padding(.top, 2)
    }

    /// "Sent · open it before 22 Oct, 11:29", the first part bold.
    private static func oneLine(_ title: String, _ detail: String) -> AttributedString {
        var head = AttributedString(title)
        head.font = .system(.footnote, weight: .semibold)
        head.foregroundColor = AppTheme.textPrimary
        var tail = AttributedString(" · " + detail)
        tail.font = .system(.footnote)
        tail.foregroundColor = AppTheme.textSecondary
        return head + tail
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = LanguageManager.shared.currentLocale
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Sync progress

/// The waiting screen for a sync.
///
/// It names the three stages instead of spinning anonymously. That costs
/// nothing and buys two things: the wait stops feeling indefinite, and when
/// something fails the user can tell us WHERE it stopped — "it froze on
/// Sending" is a bug report, "it didn't work" is not.
private struct SyncProgressOverlay: View {
    let phase: WebSyncService.Phase

    @State private var spin = false
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

            VStack(spacing: 26) {
                ring
                VStack(spacing: 9) {
                    ForEach(WebSyncService.Phase.allCases, id: \.rawValue) { p in
                        phaseRow(p)
                    }
                }
                .frame(maxWidth: 260)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spin = true }
            // The spinner says it's working; the breathing only decorated it.
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { breathe = true }
            }
        }
        .transition(.opacity)
    }

    private var ring: some View {
        ZStack {
            Circle()
                .fill(AppTheme.accent.opacity(0.10))
                .frame(width: 108, height: 108)
                .scaleEffect(breathe ? 1.08 : 0.94)

            Circle()
                .stroke(AppTheme.accent.opacity(0.16), lineWidth: 5)
                .frame(width: 84, height: 84)

            // Determinate: the arc is the share of stages completed, so it can
            // never race ahead of the work the way an indeterminate bar does.
            Circle()
                .trim(from: 0, to: progress)
                .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 84, height: 84)
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: phase)

            // A second, faint arc keeps turning so the screen still looks alive
            // during a long stage, without implying progress that isn't there.
            Circle()
                .trim(from: 0, to: 0.12)
                .stroke(AppTheme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 100, height: 100)
                .rotationEffect(.degrees(spin ? 360 : 0))

            Image(systemName: phase.icon)
                .font(.system(.title, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private var progress: CGFloat {
        CGFloat(phase.rawValue + 1) / CGFloat(WebSyncService.Phase.allCases.count)
    }

    @ViewBuilder
    private func phaseRow(_ p: WebSyncService.Phase) -> some View {
        let done = p.rawValue < phase.rawValue
        let active = p == phase
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(done || active ? AppTheme.accent.opacity(0.16) : AppTheme.cardMid.opacity(0.5))
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(AppTheme.accent)
                        .transition(.scale.combined(with: .opacity))
                } else if active {
                    Circle().fill(AppTheme.accent).frame(width: 7, height: 7)
                        .scaleEffect(breathe ? 1.25 : 0.8)
                }
            }
            Text(loc(p.titleKey))
                .font(.system(size: 14, weight: active ? .semibold : .regular))
                .foregroundStyle(done || active ? AppTheme.textPrimary : AppTheme.textSecondary.opacity(0.6))
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: phase)
    }
}
