import SwiftUI
import SwiftData

// MARK: - Assets screen (Royal)

struct AssetsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PhysicalAsset.sortOrder) private var assets: [PhysicalAsset]
    @Query private var goals: [SavingsGoal]
    @State private var showAdd = false
    @State private var editing: PhysicalAsset?
    @State private var appeared = false

    private var currency: String { CurrencyManager.shared.preferredCurrency }
    private var summary: AssetSummary { AssetSummary.of(assets, currency: currency) }
    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v.rounded(), currency: currency) }

    private var replacementGoal: SavingsGoal? { AssetAdvice.replacementGoal(in: goals) }

    var body: some View {
        FeatureStack { pushed in
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        if assets.isEmpty {
                            emptyState
                        } else {
                            summaryCard
                            if summary.monthlyWear >= 1_000 { replacementCard }
                            VStack(spacing: 0) {
                                ForEach(assets) { a in
                                    Button {
                                        HapticManager.shared.tap()
                                        editing = a
                                    } label: { AssetRow(asset: a, currency: currency) }
                                    .buttonStyle(.plain)
                                    if a.id != assets.last?.id {
                                        Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1)
                                            .padding(.leading, 68)
                                    }
                                }
                            }
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                            Text(loc("asset.estimate_note"))
                                .font(.system(.caption2))
                                .foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .opacity(appeared ? 1 : 0)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .featureBar(pushed: pushed)
            .onAppear { withAnimation(.easeOut(duration: 0.35)) { appeared = true } }
            .sheet(isPresented: $showAdd) {
                AssetFormSheet(asset: nil, nextOrder: (assets.map(\.sortOrder).max() ?? -1) + 1)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
            }
            .sheet(item: $editing) { a in
                AssetFormSheet(asset: a, nextOrder: a.sortOrder)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("premium.feature.assets"))
                    .font(.system(.title, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("asset.header_sub"))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 12)
            Button {
                HapticManager.shared.tap()
                showAdd = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(AppTheme.onVividFill)
                    .frame(width: 40, height: 40)
                    .background(AppTheme.accent, in: Circle())
            }
            .accessibilityLabel(loc("asset.add"))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "house.and.flag.fill")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.teal)
            Text(loc("asset.empty_title"))
                .font(.system(.headline))
                .foregroundStyle(AppTheme.textPrimary)
            Text(loc("asset.empty_sub"))
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                HapticManager.shared.tap()
                showAdd = true
            } label: {
                Text(loc("asset.add"))
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.onVividFill)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(AppTheme.accent, in: Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36).padding(.horizontal, 20)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private var summaryCard: some View {
        let s = summary
        return VStack(alignment: .leading, spacing: 4) {
            Text(loc("asset.total_value"))
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            Text(money(s.totalValue))
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .minimumScaleFactor(0.7).lineLimit(1)
            Text(String(format: loc("asset.bought_for"), money(s.purchaseTotal)))
                .font(.system(.caption))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    /// The advice: what wears out costs money every month, whether or not it
    /// shows. Setting that aside means the next motorbike isn't another loan.
    private var replacementCard: some View {
        let s = summary
        let monthly = AssetAdvice.roundedMonthly(s.monthlyWear)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.orange)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                Text(loc("asset.replace_title"))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            Text(String(format: loc("asset.replace_body"), money(s.monthlyWear * 12), money(monthly)))
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let g = replacementGoal {
                Label(String(format: loc("asset.replace_goal_exists"), g.name), systemImage: "checkmark.circle.fill")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            } else {
                Button {
                    HapticManager.shared.success()
                    createReplacementGoal(monthly: monthly)
                } label: {
                    Text(String(format: loc("asset.replace_cta"), money(monthly)))
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(AppTheme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private func createReplacementGoal(monthly: Double) {
        let replaceable = assets.filter { $0.kind.isReplaceable }
        let target = replaceable.reduce(0.0) {
            $0 + CurrencyManager.shared.convert($1.purchasePrice, from: $1.currency, to: currency)
        }
        let goal = SavingsGoal(name: loc("asset.replace_goal_name"), emoji: "🛵",
                               targetAmount: max(target, monthly * 12), currency: currency,
                               priority: 2, monthlyContribution: monthly,
                               notes: loc("asset.replace_goal_note"))
        context.insert(goal)
        try? context.save()
        AssetAdvice.remember(goal)
    }
}

// MARK: - Advice

enum AssetAdvice {
    /// The goal this screen created, remembered by id so it is found again and
    /// not doubled. (Goal notes are shown to the user, so no marker goes there.)
    private static let goalKey = "asset_replacement_goal_id"

    static func replacementGoal(in goals: [SavingsGoal]) -> SavingsGoal? {
        guard let id = UserDefaults.standard.string(forKey: goalKey) else { return nil }
        return goals.first { $0.id.uuidString == id && !$0.isCompleted }
    }

    static func remember(_ goal: SavingsGoal) {
        UserDefaults.standard.set(goal.id.uuidString, forKey: goalKey)
    }

    /// A set-aside people can actually remember: to Rp 10rb under 100rb,
    /// Rp 50rb under 1 jt, else Rp 100rb.
    static func roundedMonthly(_ v: Double) -> Double {
        guard v > 0 else { return 0 }
        let step: Double = v < 100_000 ? 10_000 : (v < 1_000_000 ? 50_000 : 100_000)
        return max(step, (v / step).rounded() * step)
    }
}

// MARK: - Row

private struct AssetRow: View {
    let asset: PhysicalAsset
    let currency: String

    var body: some View {
        let cm = CurrencyManager.shared
        let value = asset.value()
        let change = asset.purchasePrice > 0 ? value / asset.purchasePrice - 1 : 0
        let year = Calendar.current.component(.year, from: asset.purchaseDate)
        HStack(spacing: 14) {
            Image(systemName: asset.kind.icon)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(asset.kind.color)
                .frame(width: 40, height: 40)
                .background(asset.kind.color.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.sm))
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text("\(asset.kind.displayName) · \(String(format: loc("asset.since_year"), String(year)))")
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(cm.formatted(cm.convert(value, from: asset.currency, to: currency).rounded(), currency: currency))
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if abs(change) >= 0.005 {
                    Text((change > 0 ? "+" : "−") + "\(Int((abs(change) * 100).rounded()))%")
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(change > 0 ? AppTheme.accent : AppTheme.orange)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - Add / edit

struct AssetFormSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allAssets: [PhysicalAsset]
    let asset: PhysicalAsset?
    let nextOrder: Int

    @State private var kind: AssetKind = .motorcycle
    @State private var name = ""
    @State private var price = ""
    @State private var purchaseDate = Date()
    @State private var valueNow = ""
    @State private var hasTax = false
    @State private var taxDate = Date()
    @State private var confirmDelete = false
    @State private var loaded = false

    private var currency: String { asset?.currency ?? CurrencyManager.shared.preferredCurrency }
    private var symbol: String { CurrencyManager.symbol(for: currency) }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && InvestmentInput.number(price) > 0
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    kindPicker
                    card {
                        PlainField(label: loc("asset.field.name"), placeholder: loc("asset.field.name_ph"),
                                   bg: AppTheme.bg, text: $name)
                        MoneyField(label: loc("asset.field.price"), prefix: symbol,
                                   hint: loc("asset.field.price_hint"), bg: AppTheme.bg, text: $price)
                        DatePicker(loc("asset.field.bought_on"), selection: $purchaseDate,
                                   in: ...Date(), displayedComponents: .date)
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(AppTheme.textPrimary)
                            .tint(AppTheme.accent)
                    }
                    card {
                        MoneyField(label: loc("asset.field.value_now"), prefix: symbol,
                                   hint: estimateHint, bg: AppTheme.bg, text: $valueNow)
                    }
                    if let tax = kind.taxLabel {
                        card {
                            Toggle(isOn: $hasTax.animation()) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(format: loc("asset.field.tax_remind"), tax))
                                        .font(.system(.subheadline, weight: .medium))
                                        .foregroundStyle(AppTheme.textPrimary)
                                    Text(loc("asset.field.tax_remind_sub"))
                                        .font(.system(.caption2))
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                            }
                            .tint(AppTheme.accent)
                            if hasTax {
                                DatePicker(String(format: loc("asset.field.tax_date"), tax), selection: $taxDate,
                                           displayedComponents: .date)
                                    .font(.system(.subheadline, weight: .medium))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .tint(AppTheme.accent)
                            }
                        }
                    }
                    if asset != nil {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Text(loc("asset.delete"))
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(AppTheme.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(AppTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.md))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 20)
                }
                .padding(22)
                .containerRelativeFrame(.horizontal)
            }
            .background(AppTheme.bg)
            .navigationTitle(loc(asset == nil ? "asset.add" : "asset.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("invest.save")) { save() }
                        .font(.system(.body, weight: .bold))
                        .foregroundStyle(canSave ? AppTheme.accent : AppTheme.textSecondary)
                        .disabled(!canSave)
                }
            }
            .confirmationDialog(loc("asset.delete"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(loc("asset.delete"), role: .destructive) { delete() }
            } message: {
                Text(loc("asset.delete_msg"))
            }
            .onAppear(perform: load)
        }
    }

    /// What DiPo would estimate today, so the user can see whether to correct it.
    private var estimateHint: String {
        let p = InvestmentInput.number(price)
        let rate = asset?.annualRate ?? kind.defaultAnnualRate
        let trend = rate == 0 ? loc("asset.trend_flat")
            : String(format: loc(rate < 0 ? "asset.trend_down" : "asset.trend_up"), Int(abs(rate)))
        guard p > 0 else { return trend }
        let est = AssetValuation.value(.init(purchasePrice: p, purchaseDate: purchaseDate, annualRate: rate), at: .now)
        return String(format: loc("asset.field.value_now_hint"),
                      CurrencyManager.shared.formatted(est.rounded(), currency: currency), trend)
    }

    private var kindPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(AssetKind.allCases) { k in
                Button {
                    HapticManager.shared.tap()
                    withAnimation(.spring(response: 0.3)) { kind = k }
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: k.icon).font(.system(.title3))
                            .foregroundStyle(kind == k ? k.color : AppTheme.textSecondary)
                            .frame(width: 40, height: 40)
                            .background((kind == k ? k.color.opacity(0.18) : AppTheme.cardMid.opacity(0.45)), in: Circle())
                        Text(k.displayName).font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(kind == k ? AppTheme.textPrimary : AppTheme.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background((kind == k ? k.color.opacity(0.08) : AppTheme.cardDark),
                                in: RoundedRectangle(cornerRadius: AppRadius.md))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(kind == k ? k.color : Color.clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let a = asset else { return }
        kind = a.kind
        name = a.name
        price = InvestmentInput.text(a.purchasePrice)
        purchaseDate = a.purchaseDate
        valueNow = a.manualValue > 0 ? InvestmentInput.text(a.value()) : ""
        hasTax = a.taxDueDate != nil
        taxDate = a.taxDueDate ?? Date()
    }

    private func save() {
        let p = InvestmentInput.number(price)
        let now = InvestmentInput.number(valueNow)
        let a: PhysicalAsset
        if let existing = asset {
            a = existing
            if a.kind != kind { a.annualRate = kind.defaultAnnualRate }
            a.kindRaw = kind.rawValue
        } else {
            a = PhysicalAsset(kind: kind, name: "", currency: currency, purchasePrice: p,
                              purchaseDate: purchaseDate, sortOrder: nextOrder)
            context.insert(a)
        }
        a.name = name.trimmingCharacters(in: .whitespaces)
        a.purchasePrice = p
        a.purchaseDate = purchaseDate
        // A typed value differing from today's estimate becomes the new anchor;
        // left empty, the estimate runs from the purchase price.
        if now > 0 {
            if abs(now - a.value()) >= 1 || a.manualValue == 0 {
                a.manualValue = now
                a.manualValueDate = .now
            }
        } else {
            a.manualValue = 0
            a.manualValueDate = nil
        }
        a.taxDueDate = (kind.taxLabel != nil && hasTax) ? taxDate : nil
        try? context.save()
        AssetTaxReminders.scheduleAll(assets: allAssets.contains(where: { $0.id == a.id }) ? allAssets : allAssets + [a])
        HapticManager.shared.success()
        dismiss()
    }

    private func delete() {
        guard let a = asset else { return }
        context.delete(a)
        try? context.save()
        AssetTaxReminders.scheduleAll(assets: allAssets.filter { $0.id != a.id })
        dismiss()
    }
}
