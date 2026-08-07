import SwiftUI
import SwiftData

// MARK: - Tidy Categories
//
// Auto-categorisation only runs when a transaction is CREATED, so anything
// logged before a keyword existed (or entered in a rush) stays as "Other".
// A backup analysis showed ~21% of one user's spend sitting in "Other" — which
// the budget engine counts as Lifestyle, quietly skewing every Daily-vs-
// Lifestyle number. This screen re-runs the categoriser over existing
// uncategorised expenses and applies the fixes in bulk.

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
        let amount: Double
        let currency: String
    }

    private func build() -> [TidySuggestion] {
        let all = cards.flatMap { $0.transactions }
        return all.compactMap { tx -> TidySuggestion? in
            guard tx.amount < 0, tx.txSubtype == .normal, tx.category == .other,
                  let suggested = SmartBudgetManager.suggestCategory(for: tx.name, txType: "Expense"),
                  suggested != .other else { return nil }
            return TidySuggestion(id: tx.id, tx: tx, category: suggested,
                                  amount: abs(tx.amount),
                                  currency: tx.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : tx.currency)
        }
        .sorted { $0.amount > $1.amount }
    }

    private var totalReclassified: Double {
        suggestions.reduce(0) { $0 + CurrencyManager.shared.convert($1.amount, from: $1.currency, to: CurrencyManager.shared.preferredCurrency) }
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.done")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
            }
            .onAppear {
                if !appeared { suggestions = build(); appeared = true }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: loc("tidy.found"), suggestions.count,
                        CurrencyManager.shared.formatted(totalReclassified, currency: CurrencyManager.shared.preferredCurrency)))
                .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22).padding(.bottom, 4)
    }

    private func row(_ s: Binding<TidySuggestion>) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(s.wrappedValue.category.color.opacity(0.14)).frame(width: 40, height: 40)
                Image(systemName: s.wrappedValue.category.icon).font(.system(size: 16)).foregroundStyle(s.wrappedValue.category.color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(s.wrappedValue.tx.name).font(.system(size: 14, weight: .medium)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                Text(CurrencyManager.shared.formatted(s.wrappedValue.amount, currency: s.wrappedValue.currency))
                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
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
                    Text(s.wrappedValue.category.displayLabel).font(.system(size: 12, weight: .semibold)).foregroundStyle(s.wrappedValue.category.color)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(s.wrappedValue.category.color)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(s.wrappedValue.category.color.opacity(0.12), in: Capsule())
            }
        }
        .padding(12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
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
                .font(.system(size: 16, weight: .bold)).foregroundStyle(AppTheme.bg)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 16))
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
            Text(loc("tidy.none_title")).font(.system(size: 18, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
            Text(loc("tidy.none_sub")).font(.system(size: 14)).foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }
}
