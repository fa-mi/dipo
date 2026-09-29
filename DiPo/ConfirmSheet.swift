import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers   // for `.json` UTType in fileImporter

// Moved out of ProfileView.swift, unchanged. The one confirmation sheet used app-wide.

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
    /// Measured, so a long message or large Dynamic Type never clips and a short
    /// one does not leave a half-empty panel. Call sites used to guess 420pt,
    /// and two set no height at all and opened full-screen.
    @State private var contentHeight: CGFloat = 400

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
                    .font(.system(.title2, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.system(.subheadline))
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
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.md)
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
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(tone.color, in: RoundedRectangle(cornerRadius: AppRadius.md))
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 + 20 }
        .background(AppTheme.bg)
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.bg)
        .presentationCornerRadius(28)
    }
}

extension View {
    /// The one confirmation for anything that deletes, removes or overrides:
    /// a sheet that names the action, says what happens, and keeps Cancel the
    /// easy tap. Replaces system action sheets and alerts, which could not say
    /// more than one line and looked like a different app from the rest of DiPo.
    func confirmSheet(isPresented: Binding<Bool>,
                      icon: String = "trash.fill",
                      tone: DangerConfirmSheet.Tone = .danger,
                      title: String,
                      message: String,
                      confirmLabel: String,
                      onConfirm: @escaping () -> Void) -> some View {
        sheet(isPresented: isPresented) {
            DangerConfirmSheet(icon: icon, tone: tone, title: title, message: message,
                               confirmLabel: confirmLabel, onConfirm: onConfirm)
                .preferredColorScheme(appColorScheme())
        }
    }

    /// Same, for confirming an action on a specific item (this instalment, this
    /// member). The item is captured when the sheet opens: the sheet closes
    /// before `onConfirm` runs, and closing clears the binding, so reading the
    /// optional at confirm time would find nil and silently do nothing.
    func confirmSheet<Item: Identifiable>(item: Binding<Item?>,
                                          icon: String = "trash.fill",
                                          tone: DangerConfirmSheet.Tone = .danger,
                                          title: @escaping (Item) -> String,
                                          message: @escaping (Item) -> String,
                                          confirmLabel: String,
                                          onConfirm: @escaping (Item) -> Void) -> some View {
        sheet(item: item) { it in
            DangerConfirmSheet(icon: icon, tone: tone, title: title(it), message: message(it),
                               confirmLabel: confirmLabel, onConfirm: { onConfirm(it) })
                .preferredColorScheme(appColorScheme())
        }
    }
}
