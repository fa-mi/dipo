import SwiftUI
import RevenueCat

// MARK: - Premium Plan

/// Subscription tiers. We collapsed from `free | premium | royal` down to
/// `free | royal` — the middle "Premium" tier was removed because it
/// fragmented the upgrade flow without clear value (most users either want
/// everything or nothing). Royal is now the single paid tier.
///
/// Legacy "premium" entitlement IDs are still tolerated in
/// `syncPlanFromCustomerInfo` so anyone who purchased the now-discontinued
/// Premium plan in sandbox / TestFlight is grandfathered into Royal — they
/// keep what they paid for, no jarring downgrade.
enum PremiumPlan: String, CaseIterable {
    case free  = "free"
    case royal = "royal"

    var label: String {
        switch self {
        case .free:  return loc("premium.plan.free")
        case .royal: return loc("premium.plan.royal")
        }
    }

    var icon: String {
        switch self {
        case .free:  return "person.fill"
        case .royal: return "crown.fill"
        }
    }

    var color: Color {
        switch self {
        case .free:  return AppTheme.textSecondary
        case .royal: return Color(hex: "#A78BFA")
        }
    }

    /// Must match the Product IDs you created in App Store Connect.
    var revenueCatID: String {
        switch self {
        case .free:  return ""
        case .royal: return "com.fahmiaquinas.DiPo.royal.monthly"
        }
    }

    /// Trial period label shown on plan cards / CTA. Royal-only.
    /// IMPORTANT: changing this string alone is not enough — the actual
    /// trial must also be configured on the App Store Connect subscription
    /// product (or RevenueCat's introductory offer). StoreKit honors the
    /// store config, not this label.
    var trialLabel: String {
        switch self {
        case .free:  return ""
        case .royal: return loc("premium.trial_label")
        }
    }

    /// Whether this plan currently offers a free trial period.
    var hasTrial: Bool { !trialLabel.isEmpty }

    var priceLabel: String {
        switch self {
        case .free:  return loc("premium.plan.free")
        case .royal: return loc("premium.price.royal")
        }
    }
}

// MARK: - Premium Feature

enum PremiumFeature: String {
    case smartConversion = "smartConversion"
    case savingsGoals    = "savingsGoals"
    case smartDebt       = "smartDebt"
    case smartBudget     = "smartBudget"
    case scanReceipt     = "scanReceipt"
    case aiAdvisor       = "aiAdvisor"

    var icon: String {
        switch self {
        case .smartConversion: return "arrow.triangle.2.circlepath"
        case .savingsGoals:    return "star.fill"
        case .smartDebt:       return "creditcard.trianglebadge.exclamationmark"
        case .smartBudget:     return "brain.fill"
        case .scanReceipt:     return "doc.text.viewfinder"
        case .aiAdvisor:       return "sparkles"
        }
    }

    var color: Color {
        switch self {
        case .smartConversion: return Color(hex: "#38BDF8")
        case .savingsGoals:    return Color(hex: "#FB923C")
        case .smartDebt:       return Color(hex: "#FF6B6B")
        case .smartBudget:     return Color(hex: "#A78BFA")
        case .scanReceipt:     return Color(hex: "#10B981")
        case .aiAdvisor:       return Color(hex: "#A78BFA")
        }
    }

    /// All paid features require Royal. The AI features (receipt scan +
    /// AI Advisor) are still credit-metered inside the worker, but the
    /// UI gate is Royal-only: non-paying users sample the AI through the
    /// 7-day Royal trial rather than a perpetual free quota.
    var requiredPlan: PremiumPlan {
        switch self {
        case .smartConversion, .savingsGoals, .smartDebt,
             .smartBudget, .scanReceipt, .aiAdvisor:
            return .royal
        }
    }

    /// Display name shown in the paywall and feature list.
    var displayName: String {
        switch self {
        case .smartConversion: return loc("premium.feature.conversion")
        case .savingsGoals:    return loc("premium.feature.savings_goals")
        case .smartDebt:       return loc("premium.feature.debt_tracker")
        case .smartBudget:     return loc("premium.feature.smart_budget")
        case .scanReceipt:     return loc("premium.feature.scan_receipt")
        case .aiAdvisor:       return loc("premium.feature.ai_advisor")
        }
    }

    var description: String {
        switch self {
        case .smartConversion: return loc("premium.feature.conversion_desc")
        case .savingsGoals:    return loc("premium.feature.savings_goals_desc")
        case .smartDebt:       return loc("premium.feature.debt_tracker_desc")
        case .smartBudget:     return loc("premium.feature.smart_budget_desc")
        case .scanReceipt:     return loc("premium.feature.scan_receipt_desc")
        case .aiAdvisor:       return loc("premium.feature.ai_advisor_desc")
        }
    }
}

// MARK: - Premium Manager

@MainActor
@Observable
final class PremiumManager {
    static let shared = PremiumManager()
    private init() {
        load()
        loadCachedPricing()
    }

    var plan: PremiumPlan = .free
    var isLoading = false
    var purchaseError: String? = nil
    var restoreMessage: String? = nil

    // MARK: - Live StoreKit pricing (App Store Guideline 3.1.2c)
    //
    // Apple rejects paywalls that hardcode a price or that make the free
    // trial more prominent than the BILLED amount. We must show the real,
    // localized price pulled from StoreKit (via RevenueCat) — the same value
    // the user is actually charged — and make it the most conspicuous element.
    //
    // `royalPriceString`     → e.g. "Rp 9.000" (localizedPriceString)
    // `royalPeriodString`    → e.g. "month" / "bulan" (billing period unit)
    // `royalIntroString`     → e.g. "7-day free trial" if an intro offer exists
    //
    // All three are populated by `fetchPricing()` and fall back to the static
    // localized labels if the network/offerings are unavailable, so the
    // paywall is never blank.
    var royalPriceString: String? = nil
    var royalPeriodString: String? = nil
    var royalIntroString: String? = nil

    // Cache keys — the LAST price/period/trial we successfully pulled from
    // StoreKit is persisted here. This makes the offline fallback show the
    // real, most-recent price instead of a hardcoded number that drifts the
    // moment you change the price in App Store Connect. The hardcoded
    // `premium.price.royal` string is only ever shown on a fresh install that
    // has never once reached StoreKit (first launch + offline) — an edge case.
    private static let cachePriceKey  = "royal_price_cache"
    private static let cachePeriodKey = "royal_period_cache"
    private static let cacheIntroKey  = "royal_intro_cache"

    /// Restore the last-known StoreKit pricing from disk so the paywall can
    /// render a correct price instantly on launch, before the async
    /// `fetchPricing()` round-trip completes (and even if it's offline).
    func loadCachedPricing() {
        let d = UserDefaults.standard
        royalPriceString  = d.string(forKey: Self.cachePriceKey)
        royalPeriodString = d.string(forKey: Self.cachePeriodKey)
        royalIntroString  = d.string(forKey: Self.cacheIntroKey)
    }

    /// Pull the real localized price + trial info from RevenueCat. Safe to
    /// call repeatedly (e.g. PaywallView.onAppear). On success it also caches
    /// the values to disk so future offline launches show the right price.
    /// Never throws to the caller — failures leave the cached values in place.
    func fetchPricing() {
        Task { @MainActor in
            do {
                let offerings = try await Purchases.shared.offerings()
                guard let package = offerings.current?.availablePackages
                    .first(where: { $0.storeProduct.productIdentifier == PremiumPlan.royal.revenueCatID })
                else { return }

                let product = package.storeProduct
                let d = UserDefaults.standard

                royalPriceString = product.localizedPriceString
                d.set(product.localizedPriceString, forKey: Self.cachePriceKey)

                // Billing period unit → human label.
                if let period = product.subscriptionPeriod {
                    let label = Self.periodLabel(for: period)
                    royalPeriodString = label
                    d.set(label, forKey: Self.cachePeriodKey)
                }

                // Introductory offer (free trial). Only surface it if it's a
                // genuine free/paid intro — kept subordinate in the UI. If the
                // offer disappeared, clear the cache so we don't keep showing a
                // stale trial line.
                if let intro = product.introductoryDiscount {
                    let label = Self.introLabel(for: intro)
                    royalIntroString = label
                    d.set(label, forKey: Self.cacheIntroKey)
                } else {
                    royalIntroString = nil
                    d.removeObject(forKey: Self.cacheIntroKey)
                }
            } catch {
                // Leave cached values in place; log for debugging only.
                print("[Premium] fetchPricing failed: \(error.localizedDescription)")
            }
        }
    }

    /// "Rp 9.000 / month" style string for the hero price. Order of preference:
    /// live StoreKit value → cached last-known value → hardcoded static label
    /// (only on a never-online fresh install).
    var royalDisplayPrice: String {
        guard let price = royalPriceString else {
            return loc("premium.price.royal")
        }
        if let period = royalPeriodString {
            return "\(price) / \(period)"
        }
        return price
    }

    private static func periodLabel(for period: SubscriptionPeriod) -> String {
        let n = period.value
        switch period.unit {
        case .day:   return n == 1 ? loc("premium.period.day")   : "\(n) \(loc("premium.period.days"))"
        case .week:  return n == 1 ? loc("premium.period.week")  : "\(n) \(loc("premium.period.weeks"))"
        case .month: return n == 1 ? loc("premium.period.month") : "\(n) \(loc("premium.period.months"))"
        case .year:  return n == 1 ? loc("premium.period.year")  : "\(n) \(loc("premium.period.years"))"
        @unknown default: return loc("premium.period.month")
        }
    }

    private static func introLabel(for intro: StoreProductDiscount) -> String {
        let p = intro.subscriptionPeriod
        let count = p.value * intro.numberOfPeriods
        let unitWord: String
        switch p.unit {
        case .day:   unitWord = count == 1 ? loc("premium.period.day")   : loc("premium.period.days")
        case .week:  unitWord = count == 1 ? loc("premium.period.week")  : loc("premium.period.weeks")
        case .month: unitWord = count == 1 ? loc("premium.period.month") : loc("premium.period.months")
        case .year:  unitWord = count == 1 ? loc("premium.period.year")  : loc("premium.period.years")
        @unknown default: unitWord = loc("premium.period.days")
        }
        // e.g. "7-day free trial" / "uji coba gratis 7 hari"
        return String(format: loc("premium.trial_format"), "\(count) \(unitWord)")
    }

    // MARK: - Access Control

    func canAccess(_ feature: PremiumFeature) -> Bool {
        let requiredPlan = feature.requiredPlan
        if requiredPlan == .free { return true }
        guard UserSession.shared.isLoggedIn else { return false }
        // Only one paid tier now — Royal. The switch collapsed from three
        // cases to one when Premium was removed.
        switch requiredPlan {
        case .free:  return true
        case .royal: return plan == .royal
        }
    }

    // MARK: - Purchase (real StoreKit via RevenueCat)

    func upgrade(to newPlan: PremiumPlan) {
        guard !isLoading else { return }
        isLoading = true
        purchaseError = nil
        Task { @MainActor in
            do {
                let offerings = try await Purchases.shared.offerings()
                guard let package = offerings.current?.availablePackages
                    .first(where: { $0.storeProduct.productIdentifier == newPlan.revenueCatID })
                else {
                    purchaseError = loc("premium.product_missing")
                    isLoading = false
                    return
                }
                let result = try await Purchases.shared.purchase(package: package)
                if !result.userCancelled {
                    // Poll until RevenueCat reflects the new entitlement.
                    // Only Royal exists as a paid tier now — the previous
                    // multi-tier retry branch collapsed accordingly.
                    var retries = 0
                    var targetReached = false
                    while retries < 5 && !targetReached {
                        let freshInfo = try await Purchases.shared.customerInfo()
                        let active = freshInfo.entitlements.active
                        if newPlan == .royal && active["royal"] != nil {
                            targetReached = true
                            syncPlanFromCustomerInfo(freshInfo)
                        } else {
                            retries += 1
                            try await Task.sleep(nanoseconds: 1_500_000_000) // wait 1.5s
                        }
                    }
                    if !targetReached {
                        // Fallback: sync whatever we have
                        let finalInfo = try await Purchases.shared.customerInfo()
                        syncPlanFromCustomerInfo(finalInfo)
                    }
                    isLoading = false
                } else {
                    isLoading = false
                }
            } catch {
                isLoading = false
                // RevenueCat raw errors are English + technical (e.g. "The
                // payment is invalid. Please try a different payment method.")
                // — show a friendly localized message to the user and keep
                // the raw error in console for debugging.
                print("[Premium] purchase error: \(error.localizedDescription)")
                purchaseError = loc("premium.purchase_failed")
            }
        }
    }

    // MARK: - Restore Purchases

    func restorePurchases() {
        isLoading = true
        purchaseError = nil
        restoreMessage = nil
        Task { @MainActor in
            do {
                let info = try await Purchases.shared.restorePurchases()
                isLoading = false
                syncPlanFromCustomerInfo(info)
                let active = info.entitlements.active
                // Treat legacy "premium" entitlement the same as Royal —
                // anyone who bought the old Premium plan in sandbox/TF
                // gets grandfathered to the equivalent Royal experience
                // rather than seeing a confusing "no subscription found"
                // when they restore.
                if active["royal"] != nil || active["premium"] != nil {
                    self.restoreMessage = loc("premium.restored.royal")
                } else {
                    self.restoreMessage = loc("premium.restored.none")
                }
            } catch {
                isLoading = false
                purchaseError = String(format: loc("premium.restore_failed"), error.localizedDescription)
            }
        }
    }

    // MARK: - Sync plan from RevenueCat CustomerInfo

    func syncPlanFromCustomerInfo(_ info: CustomerInfo) {
        let entitlements = info.entitlements.active
        // Single paid tier: Royal. Legacy "premium" entitlement still
        // resolves to Royal so anyone with an active old Premium
        // subscription doesn't suddenly lose access. New purchases can
        // only grant the "royal" entitlement (Premium product removed
        // from the paywall and not offered for sale anymore).
        let newPlan: PremiumPlan =
            (entitlements["royal"] != nil || entitlements["premium"] != nil)
            ? .royal
            : .free
        self.plan = newPlan
        // Cache the resolved plan keyed by userID so the offline-fallback in
        // `onLogin` and `load` actually has something to read. Without this
        // write, paying users could be downgraded to .free during a RevenueCat
        // outage or cold launch with no network — fitur Royal would lock up
        // until connectivity returns.
        if let userID = UserSession.shared.userID {
            UserDefaults.standard.set(newPlan.rawValue, forKey: "premium_plan_\(userID)")
        }
    }

    /// Downgrade to Free = cancel the active subscription via Apple.
    /// RevenueCat has no API to cancel — cancellation must go through Apple.
    /// We open the Apple subscription management page and let the user cancel there.
    /// The plan reverts to .free automatically after the current period ends,
    /// and checkActiveSubscription() on next foreground open will reflect it.
    func downgradeToFree() {
        if let url = URL(string: "itms-apps://apps.apple.com/account/subscriptions") {
            Task { @MainActor in
                await UIApplication.shared.open(url)
            }
        }
    }

    // MARK: - Session Lifecycle

    /// Call after login — logs into RevenueCat and restores active entitlements
    func onLogin(userID: String) {
        Task { @MainActor in
            do {
                let (info, _) = try await Purchases.shared.logIn(userID)
                syncPlanFromCustomerInfo(info)
            } catch {
                // Fallback to cached plan if RevenueCat is unreachable
                let raw = UserDefaults.standard.string(forKey: "premium_plan_\(userID)") ?? "free"
                plan = PremiumPlan(rawValue: raw) ?? .free
            }
        }
    }

    /// Call BEFORE UserSession.signOut()
    func onLogout(userID: String) {
        Task { @MainActor in try? await Purchases.shared.logOut() }
        withAnimation(.spring(response: 0.4)) { plan = .free }
        // Premium-managed feature flags must be neutralized too — otherwise a
        // second user signing in on the same device would inherit the previous
        // user's Smart Budget toggle (and, if they happen to be Royal, see
        // someone else's 50/30/20 ratios applied to their data).
        SmartBudgetManager.shared.onLogoutCleanup()
    }

    // MARK: - App Launch — restore active subscription

    private func load() {
        if let userID = UserSession.shared.userID {
            let raw = UserDefaults.standard.string(forKey: "premium_plan_\(userID)") ?? "free"
            plan = PremiumPlan(rawValue: raw) ?? .free
        } else {
            plan = .free
        }
    }

    func checkActiveSubscription() {
        Task { @MainActor in
            do {
                let info = try await Purchases.shared.customerInfo()
                syncPlanFromCustomerInfo(info)
            } catch {}
        }
    }
}

// MARK: - Premium Gate View

struct PremiumGate<Content: View>: View {
    let feature: PremiumFeature
    @ViewBuilder let content: () -> Content
    @State private var showPaywall = false
    /// Observe the singleton so the gate re-renders when `plan` changes.
    /// Without this, the body computes `canAccess(...)` once and SwiftUI has
    /// no observation on the @Observable `PremiumManager.shared`, so a user
    /// who completes a purchase while sitting on a locked screen (e.g.
    /// Wishlist) keeps seeing the paywall placeholder until they leave and
    /// re-enter the view. Holding the manager in @State.observed makes
    /// SwiftUI track every property read in body.
    @State private var pm = PremiumManager.shared
    /// Same observation for sign-in/out — `canAccess` short-circuits on
    /// `UserSession.isLoggedIn`, so we need that to drive re-renders too.
    @State private var session = UserSession.shared

    var body: some View {
        // Read both observables so SwiftUI registers dependencies.
        let _ = pm.plan
        let _ = session.userID
        if pm.canAccess(feature) {
            content()
        } else {
            LockedFeaturePlaceholder(feature: feature, showPaywall: $showPaywall)
                .sheet(isPresented: $showPaywall) {
                    PaywallView()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(AppTheme.bg)
                        .preferredColorScheme(appColorScheme())
                }
        }
    }
}

// MARK: - Locked Feature Placeholder

struct LockedFeaturePlaceholder: View {
    let feature: PremiumFeature
    @Binding var showPaywall: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()

                ZStack {
                    ForEach(0..<3) { i in
                        Circle()
                            .stroke(feature.requiredPlan.color.opacity(0.08 - Double(i) * 0.02), lineWidth: 1)
                            .frame(width: CGFloat(100 + i * 40), height: CGFloat(100 + i * 40))
                            .scaleEffect(pulse ? 1.08 : 1)
                            .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true).delay(Double(i) * 0.35), value: pulse)
                    }
                    Circle()
                        .fill(feature.requiredPlan.color.opacity(0.12))
                        .frame(width: 88, height: 88)
                    Image(systemName: feature.icon)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(feature.requiredPlan.color)
                }

                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: feature.requiredPlan.icon)
                            .font(.system(size: 12, weight: .bold))
                        Text(feature.requiredPlan.label.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.5)
                    }
                    .foregroundStyle(feature.requiredPlan.color)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(feature.requiredPlan.color.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(feature.requiredPlan.color.opacity(0.3), lineWidth: 1))

                    Text(feature.displayName)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(feature.description)
                        .font(.system(size: 15))
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .padding(.horizontal, 32)
                }

                Button {
                    HapticManager.shared.tap()
                    showPaywall = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.open.fill").font(.system(size: 16))
                        Text(String(format: loc("premium.unlock"), feature.requiredPlan.label))
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [feature.requiredPlan.color, feature.requiredPlan.color.opacity(0.7)],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
                    .shadow(color: feature.requiredPlan.color.opacity(0.4), radius: 16, y: 6)
                }
                .buttonStyle(ScaleButtonStyle())
                .padding(.horizontal, 32)

                Spacer()
            }
        }
        .onAppear { pulse = true }
    }
}

// MARK: - Paywall View

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false
    // Single-tier app — Royal is the only paid plan. `selectedPlan` is
    // kept as a constant rather than ripping it out everywhere because
    // many subviews below reference `selectedPlan.icon` / `.color` /
    // `.label`; pointing them all at Royal is less invasive than
    // refactoring every reference to `PremiumPlan.royal` literally.
    private let selectedPlan: PremiumPlan = .royal
    private var mgr: PremiumManager { PremiumManager.shared }

    /// All paid features. Used to render the "What you get" section under
    /// the single Royal hero card. Order matters — most-loved features
    /// first so the user sees value before scrolling.
    private let royalAllFeatures: [PremiumFeature] = [
        .aiAdvisor, .scanReceipt, .smartBudget,
        .smartDebt, .smartConversion, .savingsGoals,
    ]

    /// Plain-language billing disclosure shown under the CTA. Builds from the
    /// live StoreKit price so the BILLED amount is explicit and accurate.
    /// Examples:
    ///   trial   → "7-day free trial, then Rp 9.000 / month. Auto-renews,
    ///              cancel anytime."
    ///   no trial → "Rp 9.000 / month. Auto-renews, cancel anytime."
    private var billingDisclosure: String {
        let mgr = PremiumManager.shared
        let price = mgr.royalDisplayPrice
        let trial = mgr.royalIntroString
            ?? (PremiumPlan.royal.trialLabel.isEmpty ? nil : PremiumPlan.royal.trialLabel)
        if let trial {
            return String(format: loc("premium.billing_disclosure_trial"), trial, price)
        }
        return String(format: loc("premium.billing_disclosure"), price)
    }

    var body: some View {
        ZStack(alignment: .top) {
            AppTheme.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 28) {

                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(selectedPlan.color.opacity(0.12))
                                .frame(width: 80, height: 80)
                            Image(systemName: selectedPlan.icon)
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(selectedPlan.color)
                        }
                        .animation(.spring(response: 0.35), value: selectedPlan)
                        .scaleEffect(appeared ? 1 : 0.6)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1), value: appeared)

                        Text(loc("premium.upgrade"))
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.5).delay(0.18), value: appeared)

                        Text(loc("premium.sub"))
                            .font(.system(size: 14))
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.5).delay(0.22), value: appeared)
                    }
                    .padding(.top, 32)

                    HStack(spacing: 6) {
                        Image(systemName: mgr.plan.icon).font(.system(size: 12))
                        Text(String(format: loc("premium.current_member"), mgr.plan.label))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(mgr.plan.color)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(mgr.plan.color.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(mgr.plan.color.opacity(0.3), lineWidth: 1))
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5).delay(0.26), value: appeared)

                    // Single Royal hero card (no tier comparison anymore —
                    // there's only one paid plan). Stretches full-width to
                    // feel hero-quality instead of looking like the
                    // leftover half of a 2-up layout.
                    planCard(.royal, features: royalAllFeatures)
                        .padding(.horizontal, 22)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 20)
                        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.3), value: appeared)

                    VStack(alignment: .leading, spacing: 12) {
                        Text(loc("premium.what_you_get"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)

                        ForEach(royalAllFeatures, id: \.rawValue) { feature in
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(feature.color.opacity(0.12))
                                        .frame(width: 38, height: 38)
                                    Image(systemName: feature.icon)
                                        .font(.system(size: 16))
                                        .foregroundStyle(feature.color)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feature.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                    Text(feature.description)
                                        .font(.system(size: 11))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .lineSpacing(2)
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(selectedPlan.color)
                            }
                        }
                    }
                    .padding(16)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(selectedPlan.color.opacity(0.25), lineWidth: 1))
                    .padding(.horizontal, 22)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.36), value: appeared)

                    VStack(spacing: 12) {
                        if !UserSession.shared.isLoggedIn {
                            VStack(spacing: 12) {
                                HStack(spacing: 10) {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(AppTheme.orange)
                                    Text(loc("premium.sign_req"))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(AppTheme.orange)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .background(AppTheme.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.orange.opacity(0.3), lineWidth: 1))

                                Text(loc("auth.sub_linked"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .multilineTextAlignment(.center)

                                HStack(spacing: 10) {
                                    Image(systemName: "lock.fill").font(.system(size: 16))
                                    Text(loc("premium.sign_in"))
                                        .font(.system(size: 16, weight: .bold))
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(AppTheme.textSecondary.opacity(0.3), in: RoundedRectangle(cornerRadius: 18))
                            }
                        } else if mgr.plan != selectedPlan {
                            // Previous deferred-billing notices for the
                            // Premium ↔ Royal switch dance were removed
                            // along with the Premium tier — there's no
                            // mid-tier to defer billing from anymore.

                            if let err = mgr.purchaseError {
                                Text(err)
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppTheme.red)
                                    .multilineTextAlignment(.center)
                                    .transition(.opacity)
                            }
                            Button {
                                mgr.upgrade(to: selectedPlan)
                            } label: {
                                VStack(spacing: 4) {
                                    HStack(spacing: 10) {
                                        if mgr.isLoading {
                                            ProgressView().tint(.white)
                                        } else {
                                            Image(systemName: selectedPlan.icon).font(.system(size: 16))
                                        }
                                        // CTA text: trial-aware. Free user
                                        // selecting Royal → "Start Free Trial".
                                        // Free user selecting Premium → direct
                                        // "Upgrade to Premium" (no trial copy).
                                        // Already-paid user → "Upgrade to <plan>".
                                        let ctaText: String = {
                                            if mgr.isLoading { return loc("premium.processing") }
                                            if mgr.plan == .free && selectedPlan.hasTrial {
                                                return loc("premium.start_trial")
                                            }
                                            return String(format: loc("premium.upgrade_to"), selectedPlan.label)
                                        }()
                                        Text(ctaText)
                                            .font(.system(size: 16, weight: .bold))
                                    }
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(
                                    LinearGradient(
                                        colors: [selectedPlan.color, selectedPlan.color.opacity(0.75)],
                                        startPoint: .leading, endPoint: .trailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 18)
                                )
                                .shadow(color: selectedPlan.color.opacity(0.45), radius: 16, y: 6)
                            }
                            .buttonStyle(ScaleButtonStyle())
                            .disabled(mgr.isLoading)

                            // Explicit billing disclosure under the CTA. States
                            // the BILLED amount plainly (Guideline 3.1.2c):
                            // "7-day free trial, then Rp 9.000 / month. Auto-
                            // renews. Cancel anytime." The billed amount here is
                            // not styled smaller than any trial text on screen.
                            Text(billingDisclosure)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppTheme.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(selectedPlan.color)
                                Text(String(format: loc("premium.youre_on"), selectedPlan.label))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(selectedPlan.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selectedPlan.color.opacity(0.3), lineWidth: 1))
                        }

                        if mgr.plan != .free {
                            // Royal subscriber actions. Used to have a
                            // "Switch to Premium" downgrade option here —
                            // gone now that Premium doesn't exist.
                            // Cancellation must still go through Apple
                            // (RevenueCat can't cancel server-side).
                            Menu {
                                Button(role: .destructive) {
                                    HapticManager.shared.tap()
                                    // Opens Apple subscription management page.
                                    // Plan auto-reverts to .free after the
                                    // current billing period ends.
                                    mgr.downgradeToFree()
                                } label: {
                                    Label("Cancel Subscription", systemImage: "xmark.circle")
                                }
                                Button("Dismiss", role: .cancel) {}
                            } label: {
                                Text(loc("premium.change_plan"))
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .underline()
                            }
                        }

                        Button {
                            HapticManager.shared.tap()
                            mgr.restorePurchases()
                        } label: {
                            if mgr.isLoading {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.7)
                                    Text(loc("premium.restoring")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                }
                            } else {
                                Text(loc("premium.restore"))
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .underline()
                            }
                        }
                        if let msg = mgr.restoreMessage {
                            Text(msg)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(msg.hasPrefix("✅") ? AppTheme.accent : AppTheme.orange)
                                .multilineTextAlignment(.center)
                                .transition(.opacity)
                        }

                        Text(loc("premium.legal"))
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
                            .multilineTextAlignment(.center)

                        // App Store Guideline 3.1.2(c): the subscription
                        // purchase flow MUST contain functional links to
                        // the privacy policy and Terms of Use (EULA).
                        // Missing these triggers an auto-renewable
                        // subscription rejection. Both point to DiPo's own
                        // hosted pages — verify they load before submitting
                        // (a broken link here = another rejection).
                        HStack(spacing: 6) {
                            Link(loc("premium.privacy_policy"),
                                 destination: URL(string: "https://dipo.info/privacy")!)
                            Text("·")
                                .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
                            Link(loc("premium.terms"),
                                 destination: URL(string: "https://dipo.info/terms")!)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .tint(AppTheme.accent)
                        .padding(.top, 2)
                    }
                    .padding(.horizontal, 22)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5).delay(0.4), value: appeared)

                    Spacer(minLength: 40)
                }
            }

            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(AppTheme.cardMid, in: Circle())
                }
                .buttonStyle(ScaleButtonStyle())
                .padding(.trailing, 22)
                .padding(.top, 20)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6).delay(0.1)) { appeared = true }
            // Pull live localized price + trial from StoreKit so the paywall
            // shows the REAL billed amount (Guideline 3.1.2c), not a hardcoded
            // string that can drift from App Store Connect.
            mgr.fetchPricing()
        }
        .onChange(of: mgr.plan) { oldPlan, newPlan in
            // Dismiss when plan upgrades (free→paid or premium→royal)
            if newPlan != oldPlan && newPlan != .free { dismiss() }
        }
    }

    /// Single Royal hero card. Used to be one of two tappable plan cards
    /// when Premium existed — now it's just a presentational hero block
    /// (no tap, no selection state). Kept as a function rather than
    /// inlining so the call site reads as one self-describing line.
    @ViewBuilder
    private func planCard(_ plan: PremiumPlan, features: [PremiumFeature]) -> some View {
        let isCurrent = mgr.plan == plan
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: plan.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(plan.color)
                Text(plan.label)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(plan.color)
                Spacer()
                if isCurrent {
                    Text(loc("premium.current"))
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(plan.color)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(plan.color.opacity(0.15), in: Capsule())
                }
            }

            // ── PRICE BLOCK (Guideline 3.1.2c) ────────────────────────────
            // The BILLED AMOUNT is the largest, most conspicuous pricing
            // element — pulled live from StoreKit (mgr.royalDisplayPrice),
            // never hardcoded. The free-trial line, if any, sits BELOW it in
            // a small, muted, subordinate position/size. Do NOT make the
            // trial bigger or more colorful than this price, or Apple will
            // reject the build again.
            if plan == .royal && !isCurrent {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mgr.royalDisplayPrice)
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(AppTheme.textPrimary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)

                    // Subordinate trial line — small, secondary color, no
                    // gradient capsule. Only shown when a real intro offer
                    // exists (live) or the static trial label is configured.
                    if let intro = mgr.royalIntroString {
                        Text(intro)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary)
                    } else if !plan.trialLabel.isEmpty {
                        Text(plan.trialLabel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                // Show ALL features now that this is the only paid card —
                // previously we limited to 4 to fit two side-by-side. The
                // hero layout has room to flex.
                ForEach(features, id: \.rawValue) { f in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(plan.color)
                        Text(f.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(plan.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(plan.color.opacity(0.4), lineWidth: 1.5))
    }
}
