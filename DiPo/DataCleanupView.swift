import SwiftUI
import SwiftData

// MARK: - Data cleanup
//
// The two tools that CHANGE transactions in order to make the analysis honest:
// Tidy recategorises rows left on "Other", and the spending audit marks the
// one-off purchases that would otherwise be averaged into a daily habit.
//
// They used to sit on Statistics. That screen reports conclusions, and a screen
// that reports conclusions should not also be where the underlying rows get
// rewritten — a reader tapping through a summary shouldn't be one gesture away
// from editing the data it summarises. The work is the same; only its address
// changed.

struct DataCleanupView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @Query(sort: \SalarySchedule.createdAt) private var salarySchedules: [SalarySchedule]

    @State private var showTidy = false
    @State private var showAudit = false

    private var currency: String { CurrencyManager.shared.preferredCurrency }
    private var mainCard: BankCard? { MainCard.reconcile(cards: cards) }

    private func converted(_ tx: TxRecord) -> Double {
        let c = tx.currency.isEmpty ? currency : tx.currency
        return CurrencyManager.shared.convert(tx.amount, from: c, to: currency)
    }

    /// The same window Statistics opens on: the pay cycle when a salary is
    /// scheduled, otherwise this month. Moving the tool must not silently move
    /// the set of transactions it operates on.
    private var window: (start: Date, end: Date) {
        if let day = MainCard.payDay(salarySchedules) {
            let r = StatPeriod.payCycleRange(payDay: day)
            let salaryDates = (mainCard?.transactions ?? [])
                .filter { $0.category == .salary && $0.amount > 0 }.map(\.date)
            return (StatPeriod.anchoredStart(r.start, salaryDates: salaryDates), r.end)
        }
        return StatPeriod.thisMonth.dateRange()
    }

    private var windowTx: [TxRecord] {
        guard let card = mainCard else { return [] }
        let (start, end) = window
        return card.transactions.filter { $0.date >= start && $0.date <= end }
    }

    private var rhythm: SpendingRhythm {
        SpendingRhythm(history: mainCard?.transactions ?? []) { converted($0) }
    }

    /// How many rows Tidy could still fix — shown so the row can say whether it
    /// is worth opening at all.
    private var tidyableCount: Int {
        cards.flatMap { $0.transactions }.reduce(0) { count, tx in
            guard tx.amount < 0, tx.txSubtype == .normal, tx.category == .other,
                  let s = SmartBudgetManager.suggestCategory(for: tx.name, txType: "Expense"), s != .other
            else { return count }
            return count + 1
        }
    }

    var body: some View {
        FeatureStack { pushed in
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(loc("cleanup.title"))
                                .font(.system(.title, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(loc("cleanup.sub"))
                                .font(.system(.footnote))
                                .foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 20)

                        toolRow(icon: "wand.and.stars", tint: AppTheme.purple,
                                title: loc("cleanup.tidy"),
                                subtitle: tidyableCount > 0
                                    ? String(format: loc("tidy.chip"), tidyableCount)
                                    : loc("cleanup.tidy_clear")) {
                            showTidy = true
                        }

                        toolRow(icon: "slider.horizontal.below.square.filled.and.square",
                                tint: AppTheme.orange,
                                title: loc("cleanup.audit"),
                                subtitle: loc("cleanup.audit_sub")) {
                            showAudit = true
                        }

                        Spacer(minLength: 60)
                    }
                    .padding(.horizontal, 22)
                }
            }
            .featureBar(pushed: pushed)
            .sheet(isPresented: $showTidy) {
                TidyCategoriesView(cards: cards)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
                    .preferredColorScheme(appColorScheme())
            }
            .sheet(isPresented: $showAudit) {
                // The figures come from the shared engine, so what the audit
                // explains is the same number Statistics prints.
                let f = StatisticsView.figures(for: windowTx, rhythm: rhythm, convert: converted)
                SpendingAuditSheet(transactions: windowTx,
                                   rhythm: rhythm,
                                   typicalDaily: f.typicalDaily,
                                   weekly: f.typicalDaily * 7,
                                   // A daily allowance is a property of the period
                                   // being reported, not of this tool — omitted
                                   // rather than recomputed into disagreement.
                                   dailyAllowance: nil,
                                   currency: currency)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
                    .preferredColorScheme(appColorScheme())
            }
        }
    }

    private func toolRow(icon: String, tint: Color, title: String, subtitle: String,
                         action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.tap()
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: AppRadius.md))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(subtitle).font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
