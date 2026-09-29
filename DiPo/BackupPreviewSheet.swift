import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers   // for `.json` UTType in fileImporter

// Moved out of ProfileView.swift, unchanged.

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
                        .font(.system(.title, weight: .semibold))
                        .foregroundStyle(AppTheme.blue)
                }
                .padding(.top, 12)

                Text(loc("backup.preview.title"))
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text(loc("backup.preview.subtitle"))
                    .font(.system(.footnote))
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
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.cardMid, lineWidth: 1))
            .padding(.horizontal, 22)
            .padding(.top, 18)

            // Counts grid
            VStack(alignment: .leading, spacing: 8) {
                Text(loc("backup.preview.contents"))
                    .font(.system(.caption, weight: .semibold))
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
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.cardMid, lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle())

                Button {
                    HapticManager.shared.tap()
                    onContinue()
                } label: {
                    Text(loc("backup.preview.continue"))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
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
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 18)
            Text(label)
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(.footnote, weight: .semibold))
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
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count)")
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())
                Text(label)
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.sm))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).stroke(AppTheme.cardMid.opacity(0.4), lineWidth: 1))
    }
}
