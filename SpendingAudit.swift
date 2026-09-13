import SwiftUI
import SwiftData

// MARK: - Spending audit
//
// Every transaction behind the daily-rate figure, and — the part that matters —
// every transaction NOT behind it, with the reason.
//
// The engine now decides on its own which spending is day-to-day and which is
// an episode. That is the right default, and it creates an obligation: a number
// that quietly leaves some of your spending out is a number you cannot check.
// "Rp 165.000 a day" is a claim, and a claim the user cannot trace back to
// their own transactions is asked to be taken on faith. This app has spent too
// long being wrong about arithmetic to be owed that.
//
// So the exclusions are not a footnote here. They are a section of equal
// standing, each row carrying the reason it was left out, and each reason
// correctable from the transaction itself.

struct SpendingAuditRow: Identifiable {
    /// The live record, so a swipe can change the verdict rather than a copy of
    /// it. Snapshots were enough when the sheet only reported; the moment it
    /// became editable, a snapshot would have shown a stale answer the instant
    /// the user acted on it.
    let tx: TxRecord
    let amount: Double
    let verdict: SpendingRhythm.Verdict

    var id: UUID { tx.id }
}

struct SpendingAuditSheet: View {
    /// Every expense in the window, unsplit. The sheet divides them itself so
    /// that a swipe moves a row across immediately — deriving the split here
    /// rather than receiving it is what makes the screen live.
    let transactions: [TxRecord]
    let rhythm: SpendingRhythm
    /// The figures being explained, so the arithmetic and its inputs sit on one
    /// screen instead of the user holding one in their head.
    let typicalDaily: Double
    let weekly: Double
    let dailyAllowance: Double?
    let currency: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var showingExcluded = false

    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: currency)
    }

    private func convert(_ tx: TxRecord) -> Double {
        abs(CurrencyManager.shared.convert(
            tx.amount,
            from: tx.currency.isEmpty ? currency : tx.currency,
            to: currency))
    }

    /// Fixed monthly commitments are excluded by contract, not by the engine,
    /// and cannot be argued with here — so they carry `.dayToDay` and the row
    /// renders "fixed monthly" without offering a swipe.
    private func row(_ tx: TxRecord) -> SpendingAuditRow {
        let amt = convert(tx)
        let v: SpendingRhythm.Verdict = StatisticsView.fixedMonthlyCats.contains(tx.category)
            ? .dayToDay
            : rhythm.verdict(for: tx, amount: amt)
        return SpendingAuditRow(tx: tx, amount: amt, verdict: v)
    }

    private var split: (counted: [SpendingAuditRow], excluded: [SpendingAuditRow]) {
        var counted: [SpendingAuditRow] = [], excluded: [SpendingAuditRow] = []
        for tx in transactions where tx.amount < 0 && tx.txSubtype != .transfer {
            let r = row(tx)
            let isFixed = StatisticsView.fixedMonthlyCats.contains(tx.category)
            if isFixed || r.verdict.isIrregular { excluded.append(r) } else { counted.append(r) }
        }
        return (counted.sorted { $0.tx.date > $1.tx.date },
                excluded.sorted { $0.amount > $1.amount })
    }

    private var counted: [SpendingAuditRow] { split.counted }
    private var excluded: [SpendingAuditRow] { split.excluded }
    private var rows: [SpendingAuditRow] { showingExcluded ? excluded : counted }
    private var countedTotal: Double { counted.reduce(0) { $0 + $1.amount } }
    private var excludedTotal: Double { excluded.reduce(0) { $0 + $1.amount } }

    /// Whether this row's verdict is the user's to change. A rent payment is
    /// excluded because it is contractual, and offering to "count it as daily
    /// spending" would be offering a lie.
    private func isArguable(_ r: SpendingAuditRow) -> Bool {
        !StatisticsView.fixedMonthlyCats.contains(r.tx.category)
    }

    private func setOverride(_ r: SpendingAuditRow, _ value: Bool?) {
        HapticManager.shared.success()
        r.tx.oneOffOverride = value
        try? context.save()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                // A List, purely so rows can carry swipe actions — the system
                // gesture is worth more than the styling it costs, which is why
                // every chrome-bearing modifier below is switched off.
                List {
                    Section {
                        summary.listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                        picker.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    Section {
                        if rows.isEmpty {
                            Text(loc(showingExcluded ? "audit.none_excluded" : "audit.none_counted"))
                                .font(.system(.caption))
                                .foregroundStyle(AppTheme.textSecondary)
                                .padding(.vertical, 14)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        ForEach(rows) { r in
                            rowView(r)
                                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    swipeButtons(r)
                                }
                        }
                        hint
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 1)
                .padding(.horizontal, 16)
            }
            .trackScreen(.spendingAudit)
            .navigationTitle(loc("audit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
    }

    // MARK: The arithmetic

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Stated as the median it is, not as an "average" — the word would
            // be wrong, and being precise here is the whole point of the screen.
            line(loc("audit.typical"), money(typicalDaily), bold: true)
            divider
            line(loc("audit.weekly"), money(weekly))
            if let allowance = dailyAllowance, allowance > 0 {
                divider
                line(loc("audit.allowance"), money(allowance),
                     tint: typicalDaily <= allowance ? AppTheme.accent : AppTheme.orange)
            }
            divider
            line(String(format: loc("audit.counted_n"), counted.count), money(countedTotal))
            divider
            line(String(format: loc("audit.excluded_n"), excluded.count), money(excludedTotal),
                 tint: AppTheme.textSecondary)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private var divider: some View {
        Divider().overlay(AppTheme.cardMid).padding(.vertical, 9)
    }

    private func line(_ label: String, _ value: String,
                      bold: Bool = false, tint: Color = AppTheme.textPrimary) -> some View {
        HStack {
            Text(label)
                .font(.system(size: bold ? 13 : 12))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: bold ? 17 : 13, weight: bold ? .bold : .semibold))
                .foregroundStyle(tint)
        }
    }

    // MARK: Which list

    private var picker: some View {
        HStack(spacing: 6) {
            tab(String(format: loc("audit.tab_counted"), counted.count), on: !showingExcluded) {
                showingExcluded = false
            }
            tab(String(format: loc("audit.tab_excluded"), excluded.count), on: showingExcluded) {
                showingExcluded = true
            }
        }
    }

    private func tab(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.tap()
            withAnimation(.spring(response: 0.28)) { action() }
        } label: {
            Text(title)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(on ? AppTheme.onVividFill : AppTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(on ? AppTheme.accentFill : AppTheme.cardDark, in: Capsule())
        }
        .buttonStyle(ScaleButtonStyle())
    }

    // MARK: Rows

    @ViewBuilder
    private func swipeButtons(_ r: SpendingAuditRow) -> some View {
        if isArguable(r) {
            if showingExcluded {
                // Bring it back into the daily rate. `false`, not nil: the user
                // is disagreeing with the engine, so the answer has to outlive
                // the next recompute.
                Button { setOverride(r, false) } label: {
                    Label(loc("audit.swipe_count"), systemImage: "arrow.uturn.left")
                }
                .tint(AppTheme.accent)
            } else {
                Button { setOverride(r, true) } label: {
                    Label(loc("audit.swipe_exclude"), systemImage: "arrow.up.right")
                }
                .tint(AppTheme.orange)
            }
            // "Automatic" — clearing the override so the engine decides again —
            // deliberately does NOT live here. It is a third choice for a rare
            // case, offered in a gesture menu with no room to say what it means,
            // next to two actions that already cover what people actually want.
            // It belongs in the transaction detail, where the sentence
            // explaining it fits beside it.
        }
    }

    private func rowView(_ r: SpendingAuditRow) -> some View {
        HStack(spacing: 11) {
            Circle().fill(r.tx.category.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.tx.name.isEmpty ? r.tx.category.displayLabel : r.tx.name)
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(r.tx.date, format: .dateTime.day().month(.abbreviated))
                    if showingExcluded {
                        Text("·")
                        Text(loc(reasonKey(r.verdict)))
                            .foregroundStyle(AppTheme.orange.opacity(0.9))
                    } else if r.tx.oneOffOverride == false {
                        Text("·")
                        Text(loc("audit.reason_user_kept"))
                            .foregroundStyle(AppTheme.accent.opacity(0.9))
                    }
                }
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 8)
            Text(money(r.amount))
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(showingExcluded ? AppTheme.textSecondary : AppTheme.textPrimary)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var hint: some View {
        Text(loc("audit.swipe_hint"))
            .font(.system(.caption2))
            .foregroundStyle(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8).padding(.bottom, 20)
    }

    private func reasonKey(_ v: SpendingRhythm.Verdict) -> String {
        switch v {
        case .episodicCategory: return "audit.reason_episodic"
        case .outlier:          return "audit.reason_outlier"
        case .userMarked:       return "audit.reason_user"
        case .dayToDay:         return "audit.reason_fixed"
        }
    }
}
