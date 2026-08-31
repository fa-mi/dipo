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
// of waiting for one.
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
    @State private var showRevokeConfirm = false
    @State private var appeared = false

    private var dipoID: String { session.dipoID ?? "—" }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        header
                        idCard
                        steps
                        statusCard
                        syncButton
                        if service.lastSyncedAt != nil { revokeLink }
                        Spacer(minLength: 28)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
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
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { appeared = true }
        }
        .confirmationDialog(loc("websync.revoke_title"),
                            isPresented: $showRevokeConfirm, titleVisibility: .visible) {
            Button(loc("websync.revoke_action"), role: .destructive) {
                Task { await service.revoke() }
            }
            Button(loc("common.cancel"), role: .cancel) {}
        } message: {
            Text(loc("websync.revoke_body"))
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.12)).frame(width: 66, height: 66)
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
            }
            Text(loc("websync.header"))
                .font(.system(size: 15)).foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(.bottom, 2)
    }

    // MARK: DiPo ID

    private var idCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(loc("websync.your_id"), systemImage: "number")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)

            HStack(spacing: 12) {
                Text(dipoID)
                    .font(.system(size: 25, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                Button {
                    HapticManager.shared.tap()
                    UIPasteboard.general.string = dipoID
                    withAnimation(.spring(response: 0.3)) { idCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation(.easeOut) { idCopied = false }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: idCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .bold))
                        Text(idCopied ? loc("common.copied") : loc("common.copy"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(idCopied ? AppTheme.bg : AppTheme.accent)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(idCopied ? AnyShapeStyle(AppTheme.accent)
                                         : AnyShapeStyle(AppTheme.accent.opacity(0.14)), in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(session.dipoID == nil)
            }

            Text("dipo.info")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
            Text(loc("websync.id_hint"))
                .font(.system(size: 11.5)).foregroundStyle(AppTheme.textSecondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true).lineSpacing(1.5)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.accent.opacity(0.22), lineWidth: 1))
    }

    // MARK: Steps

    private var steps: some View {
        VStack(spacing: 0) {
            stepRow(1, "safari.fill",            AppTheme.blue,   "websync.step1t", "websync.step1d")
            stepDivider
            stepRow(2, "keyboard.fill",          AppTheme.purple, "websync.step2t", "websync.step2d")
            stepDivider
            stepRow(3, "arrow.up.circle.fill",   AppTheme.accent, "websync.step3t", "websync.step3d")
        }
        .padding(.vertical, 4)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
    }

    private var stepDivider: some View {
        Divider().background(AppTheme.cardMid).padding(.leading, 62)
    }

    private func stepRow(_ n: Int, _ icon: String, _ tint: Color,
                         _ titleKey: String, _ bodyKey: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(tint.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(n)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 16, height: 16)
                        .background(tint.opacity(0.16), in: Circle())
                    Text(loc(titleKey))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                }
                Text(loc(bodyKey))
                    .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(1.5)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
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
                // Syncing before opening the page is not a mistake — the web
                // reads whatever snapshot exists, so the order genuinely does
                // not matter. But the 24-hour clock starts HERE, not when the
                // page is opened, so a snapshot nobody visits quietly burns its
                // whole window. Naming the remaining step turns a report into
                // an instruction, which is what the user needs at this moment.
                statusBox(icon: "checkmark.circle.fill", tint: AppTheme.accent,
                          title: loc("websync.synced"),
                          detail: String(format: loc("websync.valid_until"),
                                         Self.stamp(at.addingTimeInterval(WebSyncService.snapshotLifetime))),
                          nextStep: String(format: loc("websync.next_step"), dipoID))
            }
        default:
            if let at = service.lastSyncedAt {
                statusBox(icon: "clock.arrow.circlepath", tint: AppTheme.textSecondary,
                          title: String(format: loc("websync.last_synced"), Self.stamp(at)),
                          detail: loc("websync.replace_hint"))
            }
        }
    }

    private func statusBox(icon: String, tint: Color, title: String, detail: String,
                          nextStep: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(tint).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(1.5)
                if let nextStep {
                    Text(nextStep)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(1.5)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(tint.opacity(0.2), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Actions

    private var isUploading: Bool { service.state == .uploading }

    private var syncButton: some View {
        Button {
            Task { await service.sync(context: context) }
        } label: {
            HStack(spacing: 9) {
                if isUploading {
                    ProgressView().tint(AppTheme.bg).scaleEffect(0.85)
                } else {
                    Image(systemName: "arrow.up.to.line").font(.system(size: 15, weight: .bold))
                }
                Text(isUploading ? loc("websync.uploading")
                                 : (service.lastSyncedAt == nil ? loc("websync.action")
                                                                : loc("websync.action_again")))
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(AppTheme.bg)
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 15))
            .shadow(color: AppTheme.accent.opacity(0.28), radius: 12, y: 5)
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.red.opacity(0.9))
        }
        .padding(.top, 2)
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
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { breathe = true }
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
                .font(.system(size: 25, weight: .medium))
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
