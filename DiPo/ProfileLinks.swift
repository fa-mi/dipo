import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers   // for `.json` UTType in fileImporter

// Moved out of ProfileView.swift, unchanged. The feature rows Profile links out from.

// MARK: - Premium Locked Feature Link

struct PremiumLockedFeatureLink: View {
    let feature: PremiumFeature
    let title: String
    let subtitle: String
    /// Override the badge when a row is GATED by a feature but is not that
    /// feature. "Sync to Web Version" is unlocked by the same Royal
    /// entitlement as Smart Budget, so it inherited Smart Budget's purple
    /// brain — two different destinations wearing one identity, sitting three
    /// rows apart in the same list. The gate and the badge are separate
    /// questions; this lets a row answer them differently.
    var iconOverride: String? = nil
    var tintOverride: Color? = nil
    @Binding var showPaywall: Bool
    let action: () -> Void

    private var isLocked: Bool { !PremiumManager.shared.canAccess(feature) }
    private var badgeIcon: String { iconOverride ?? feature.icon }
    private var badgeTint: Color { tintOverride ?? feature.color }

    var body: some View {
        Button(action: {
            HapticManager.shared.tap()
            if isLocked { showPaywall = true } else { action() }
        }) {
            HStack(spacing: 14) {
                Image(systemName: badgeIcon)
                    .font(.system(.body))
                    .foregroundStyle(isLocked ? AppTheme.textSecondary : badgeTint)
                    .frame(width: 36, height: 36)
                    .background(
                        (isLocked ? AppTheme.textSecondary : feature.color).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: AppRadius.sm)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(isLocked ? AppTheme.textSecondary : AppTheme.textPrimary)
                        if isLocked {
                            HStack(spacing: 3) {
                                Image(systemName: feature.requiredPlan.icon)
                                    .font(.system(.caption2, weight: .bold)).imageScale(.small)
                                Text(feature.requiredPlan.label)
                                    .font(.system(.caption2, weight: .bold))
                                    .tracking(0.5)
                            }
                            .foregroundStyle(feature.requiredPlan.color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(feature.requiredPlan.color.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        // Without this the Text reports its single-line ideal
                        // width, which pushes the row — and with it the whole
                        // page — wider than the screen. Only showed up once a
                        // subtitle got long, and sooner in Indonesian.
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: isLocked ? "lock.fill" : "chevron.right")
                    .font(.system(size: isLocked ? 12 : 13))
                    .foregroundStyle(isLocked ? AppTheme.textSecondary.opacity(0.5) : AppTheme.textSecondary)
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
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
                    .font(.system(.body))
                    .foregroundStyle(color)
                    .frame(width: 36, height: 36)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        // Without this the Text reports its single-line ideal
                        // width, which pushes the row — and with it the whole
                        // page — wider than the screen. Only showed up once a
                        // subtitle got long, and sooner in Indonesian.
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
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
