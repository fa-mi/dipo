import SwiftUI
import RevenueCat

// MARK: - DiPo AI credit packs
//
// Royal comes with credits each month. When they run out before the month
// does, a pack tops them up: a consumable in-app purchase, sold through the
// RevenueCat offering "ai_credits". The app only buys. The credits are added
// by the Worker when RevenueCat tells it of the purchase (dipo-backend,
// purchases.js), after checking it with RevenueCat itself, so nothing the
// app says can add credits. Bought credits don't expire; the month's are
// used first.

/// A pack on sale: what it holds and its price in the buyer's currency.
struct CreditPack: Identifiable, Equatable {
    let id: String
    let credits: Int
    let price: String
}

enum CreditPacks {
    /// The RevenueCat offering the packs are sold in.
    static let offeringID = "ai_credits"

    /// Product id → credits. The same table as the Worker's CREDIT_PACKS.
    static let credits: [String: Int] = [
        "com.fahmiaquinas.DiPo.credits30": 30,
        "com.fahmiaquinas.DiPo.credits100": 100,
    ]

    /// Smallest first.
    static func sorted(_ packs: [CreditPack]) -> [CreditPack] {
        packs.sorted { $0.credits < $1.credits }
    }

    /// "Beli 100 kredit · Rp 39.000".
    static func buyLabel(_ pack: CreditPack) -> String {
        String(format: loc("packs.buy"), pack.credits, pack.price)
    }

    /// Where buying should start: the larger pack, which most people who run
    /// out mid-month need.
    static func defaultChoice(_ packs: [CreditPack]) -> String? {
        sorted(packs).last?.id
    }
}

/// Loads the packs from RevenueCat and buys one.
@MainActor
@Observable
final class CreditPackStore {
    enum Phase: Equatable {
        case loading, ready, unavailable, buying
        case bought(Int)
        case failed(String)
    }

    var phase: Phase = .loading
    var packs: [CreditPack] = []
    private var packages: [String: Package] = [:]

    func load() async {
        phase = .loading
        do {
            let offerings = try await Purchases.shared.offerings()
            let offered = offerings.offering(identifier: CreditPacks.offeringID)?.availablePackages ?? []
            var found: [CreditPack] = []
            for package in offered {
                let id = package.storeProduct.productIdentifier
                guard let credits = CreditPacks.credits[id] else { continue }
                packages[id] = package
                found.append(CreditPack(id: id, credits: credits, price: package.storeProduct.localizedPriceString))
            }
            packs = CreditPacks.sorted(found)
            phase = packs.isEmpty ? .unavailable : .ready
        } catch {
            print("[CreditPacks] offerings error: \(error.localizedDescription)")
            phase = .unavailable
        }
    }

    /// True when the pack was bought. The credits arrive a moment later,
    /// once RevenueCat has told the Worker.
    func buy(_ pack: CreditPack) async -> Bool {
        guard let package = packages[pack.id] else {
            phase = .failed(loc("packs.err.generic"))
            return false
        }
        // Bought without a signed-in RevenueCat user, the purchase would
        // belong to no DiPo account and the credits would go nowhere.
        guard !Purchases.shared.isAnonymous else {
            phase = .failed(loc("packs.err.signin"))
            return false
        }
        phase = .buying
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled {
                phase = .ready
                return false
            }
            phase = .bought(pack.credits)
            return true
        } catch {
            // RevenueCat's own wording is English and technical; the console
            // keeps it, the person gets a plain sentence.
            print("[CreditPacks] purchase error: \(error.localizedDescription)")
            phase = .failed(loc("packs.err.generic"))
            return false
        }
    }
}

/// The sheet: what a credit is, what is left, the packs, and one green Buy.
struct BuyCreditsSheet: View {
    /// What the person has left now, when known.
    let creditsLeft: Int?
    /// Reads the balance again. Called after a purchase, a few times, since
    /// the credits land once RevenueCat has told the Worker.
    var onBought: () async -> Void = {}

    @State private var store = CreditPackStore()
    @State private var chosen: String?
    @Environment(\.dismiss) private var dismiss

    private var chosenPack: CreditPack? { store.packs.first { $0.id == chosen } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc("packs.title"))
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(loc("packs.sub"))
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            if let creditsLeft {
                Text(String(format: loc("packs.left"), creditsLeft))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.top, 8)
            }

            content
                .padding(.top, 12)

            Text(loc("packs.footer"))
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppTheme.bg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.bg)
        .preferredColorScheme(appColorScheme())
        .task {
            await store.load()
            if chosen == nil { chosen = CreditPacks.defaultChoice(store.packs) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        case .unavailable:
            VStack(spacing: 10) {
                Text(loc("packs.unavailable"))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                Button(loc("packs.retry")) { Task { await store.load() } }
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        default:
            VStack(spacing: 6) {
                ForEach(store.packs) { pack in packRow(pack) }
            }
            buyButton
                .padding(.top, 14)
            if case .failed(let why) = store.phase {
                Text(why)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }

    /// One pack: a radio, what it holds, its price. The chosen one sits on a
    /// plain fill, which marks the choice.
    private func packRow(_ pack: CreditPack) -> some View {
        let on = chosen == pack.id
        return Button {
            HapticManager.shared.select()
            chosen = pack.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(.body))
                    .foregroundStyle(on ? AppTheme.textPrimary : AppTheme.textSecondary)
                Text(String(format: loc("packs.pack"), pack.credits))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer(minLength: 8)
                Text(pack.price)
                    .font(.system(.subheadline, weight: .bold).monospacedDigit())
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .padding(.horizontal, 12).padding(.vertical, 14)
            .background {
                if on { RoundedRectangle(cornerRadius: AppRadius.md).fill(AppTheme.cardMid) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.phase == .buying)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var buyButton: some View {
        Button {
            guard let pack = chosenPack else { return }
            HapticManager.shared.tap()
            Task {
                guard await store.buy(pack) else { return }
                HapticManager.shared.success()
                await onBought()
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
                // The Worker hears of the purchase from RevenueCat; read the
                // balance again a little later in case that took a moment.
                Task {
                    for _ in 0..<2 {
                        try? await Task.sleep(for: .seconds(3))
                        await onBought()
                    }
                }
            }
        } label: {
            Group {
                switch store.phase {
                case .buying:
                    ProgressView().tint(AppTheme.onVividFill)
                case .bought(let n):
                    Label(String(format: loc("packs.bought"), n), systemImage: "checkmark")
                default:
                    Text(chosenPack.map(CreditPacks.buyLabel) ?? loc("packs.add"))
                }
            }
            .font(.system(.body, weight: .bold))
            .foregroundStyle(AppTheme.onVividFill)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(chosenPack == nil || store.phase == .buying)
    }
}

/// "Tambah kredit ›": the way into the sheet, in ink, wherever credits run out.
struct AddCreditsLink: View {
    let action: () -> Void

    var body: some View {
        Button {
            HapticManager.shared.tap()
            action()
        } label: {
            HStack(spacing: 2) {
                Text(loc("packs.add"))
                Image(systemName: "chevron.right").imageScale(.small)
            }
            .font(.system(.footnote, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
