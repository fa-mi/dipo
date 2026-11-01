import SwiftUI

// The feature rows Profile links out from. They sit in one list
// (ListSection), not a card each.

// MARK: - Premium Locked Feature Link

/// A Profile row for a feature that needs Royal. Locked, it keeps its icon,
/// colour and description, and says Royal once, at its trailing edge; a tap
/// opens the paywall. Built on Plan's row so the two tabs look alike.
struct PremiumLockedFeatureLink: View {
    let feature: PremiumFeature
    let title: String
    /// What the feature does. Shown locked or not: "Requires Royal" in its
    /// place told people nothing the Royal mark beside it didn't.
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

    var body: some View {
        Button {
            HapticManager.shared.tap()
            if isLocked { showPaywall = true } else { action() }
        } label: {
            PlanRowLabel(icon: iconOverride ?? feature.icon, tint: tintOverride ?? feature.color,
                         title: title, status: subtitle,
                         lockedPlan: isLocked ? feature.requiredPlan : nil)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Profile Feature Link

/// A Profile row that opens something: icon, name, what it does, chevron.
struct ProfileFeatureLink: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button {
            HapticManager.shared.tap()
            action()
        } label: {
            PlanRowLabel(icon: icon, tint: color, title: title, status: subtitle, lockedPlan: nil)
        }
        .buttonStyle(.plain)
    }
}
