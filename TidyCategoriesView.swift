import SwiftUI
import SwiftData

// MARK: - Tidy Categories
//
// Auto-categorisation only runs when a transaction is CREATED, so anything
// logged before a keyword existed (or entered in a rush) stays as "Other".
// A backup analysis showed ~21% of one user's spend sitting in "Other" — which
// the budget engine counts as Lifestyle, quietly skewing every Daily-vs-
// Lifestyle number. This screen re-runs the categoriser over existing
// uncategorised expenses and applies the fixes in bulk. It also offers back
// the rows an old keyword mix-up filed wrong (SmartBudgetManager.misfiledFix).

struct TidyCategoriesView: View {
    let cards: [BankCard]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    /// Uncategorised expenses the engine COULD confidently re-map. Built once.
    @State private var suggestions: [TidySuggestion] = []
    @State private var applied = false
    @State private var appeared = false

    struct TidySuggestion: Identifiable {
        let id: UUID
        let tx: TxRecord
        var category: TxCategory     // mutable — user can override
        /// What it was filed under, for a row an old keyword mix-up filed
        /// wrong; nil for one sitting in Other.
        let was: TxCategory?
        let amount: Double
        let currency: String
    }

    /// What Tidy offers for a transaction: a category for an uncategorised
    /// expense, or the right one for an expense an old keyword mix-up filed
    /// wrong. DataCleanupView counts the same.
    static func offer(for tx: TxRecord) -> (category: TxCategory, was: TxCategory?)? {
        guard tx.amount < 0, tx.txSubtype == .normal else { return nil }
        guard tx.category == .other else {
            guard let fix = SmartBudgetManager.misfiledFix(name: tx.name, category: tx.category) else { return nil }
            return (category: fix, was: tx.category)
        }
        guard let suggested = SmartBudgetManager.suggestCategory(for: tx.name, txType: "Expense"),
              suggested != .other else { return nil }
        return (suggested, nil)
    }

    private func build() -> [TidySuggestion] {
        let all = cards.flatMap { $0.transactions }
        return all.compactMap { tx -> TidySuggestion? in
            guard let offer = Self.offer(for: tx) else { return nil }
            return TidySuggestion(id: tx.id, tx: tx, category: offer.category, was: offer.was,
                                  amount: abs(tx.amount),
                                  currency: tx.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : tx.currency)
        }
        .sorted { $0.amount > $1.amount }
    }

    private func total(of rows: [TidySuggestion]) -> Double {
        rows.reduce(0) { $0 + CurrencyManager.shared.convert($1.amount, from: $1.currency, to: CurrencyManager.shared.preferredCurrency) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                if suggestions.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            header
                            ForEach($suggestions) { $s in
                                row($s)
                            }
                            .padding(.horizontal, 22)
                            Spacer(minLength: 100)
                        }
                        .padding(.top, 8)
                        .containerRelativeFrame(.horizontal)
                    }
                }
                if !suggestions.isEmpty {
                    VStack {
                        Spacer()
                        applyButton
                    }
                }
            }
            .navigationTitle(loc("tidy.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
            .onAppear {
                if !appeared { suggestions = build(); appeared = true }
            }
        }
    }

    private var header: some View {
        let uncategorised = suggestions.filter { $0.was == nil }
        let misfiled = suggestions.count - uncategorised.count
        return VStack(alignment: .leading, spacing: 6) {
            if !uncategorised.isEmpty {
                Text(String(format: loc("tidy.found"), uncategorised.count,
                            CurrencyManager.shared.formatted(total(of: uncategorised),
                                                             currency: CurrencyManager.shared.preferredCurrency)))
            }
            if misfiled > 0 {
                Text(String(format: loc("tidy.misfiled"), misfiled))
            }
        }
        .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.bottom, 4)
    }

    private func row(_ s: Binding<TidySuggestion>) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.sm).fill(s.wrappedValue.category.color.opacity(0.14)).frame(width: 40, height: 40)
                Image(systemName: s.wrappedValue.category.icon).font(.system(.callout)).foregroundStyle(s.wrappedValue.category.color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(s.wrappedValue.tx.name).font(.system(.subheadline, weight: .medium)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                Text(detail(s.wrappedValue))
                    .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 6)
            // Tap to override the suggested category.
            Menu {
                ForEach([TxCategory.food, .transport, .shopping, .bills, .health, .travel, .commitment, .investment, .other], id: \.self) { cat in
                    Button { s.wrappedValue.category = cat } label: {
                        Label(cat.displayLabel, systemImage: cat.icon)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(s.wrappedValue.category.displayLabel).font(.system(.caption, weight: .semibold)).foregroundStyle(s.wrappedValue.category.color)
                    Image(systemName: "chevron.down").font(.system(.caption2, weight: .bold)).imageScale(.small).foregroundStyle(s.wrappedValue.category.color)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(s.wrappedValue.category.color.opacity(0.12), in: Capsule())
            }
        }
        .padding(12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    /// The amount, and what a misfiled row was filed under.
    private func detail(_ s: TidySuggestion) -> String {
        let amount = CurrencyManager.shared.formatted(s.amount, currency: s.currency)
        guard let was = s.was else { return amount }
        return amount + " · " + String(format: loc("tidy.was"), was.displayLabel)
    }

    private var applyButton: some View {
        Button {
            HapticManager.shared.success()
            for s in suggestions {
                s.tx.category = s.category
                s.tx.iconBgHex = s.category.iconBg
            }
            try? context.save()
            applied = true
            dismiss()
        } label: {
            Text(String(format: loc("tidy.apply"), suggestions.count))
                .font(.system(.callout, weight: .bold)).foregroundStyle(AppTheme.bg)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(ScaleButtonStyle())
        .padding(.horizontal, 22).padding(.bottom, 20)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.12)).frame(width: 84, height: 84)
                Image(systemName: "checkmark.seal.fill").font(.system(size: 36)).foregroundStyle(AppTheme.accent)
            }
            Text(loc("tidy.none_title")).font(.system(.body, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
            Text(loc("tidy.none_sub")).font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }
}
