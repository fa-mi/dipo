import SwiftUI
import SwiftData

// MARK: - A monthly bill logged twice
//
// The old check counted every charge of the bill's AMOUNT across the whole
// analysis window and compared that with how many the plan expected. It knew
// nothing about which bill a charge belonged to, so two Netlify payments of
// Rp 200.000 — one in August, one in September, each in its own pay period —
// were reported as "Possible duplicate: Gold invest", a plan that had only
// existed for a week and had never been charged twice.
//
// A double-log has a precise shape: DiPo records the bill on its due day, and
// the same payment is also entered by hand (or recorded twice) in the SAME pay
// period. So a pair needs:
//   • one charge DiPo recorded for this bill — its marker and its name;
//   • another charge in the same pay period for the same amount, in a
//     fixed-cost category or the bill's own, that is not another bill's
//     recorded charge.
// Each pair is shown with both rows so the user can see which to delete — or
// say both are real, which DiPo then remembers.

struct RecurringDuplicatePair: Identifiable {
    /// Stable across launches: the two rows' ids, so "both are real" sticks.
    /// Stored, not computed: once one of the rows is deleted it must not be
    /// read again.
    let id: String
    let planLabel: String
    /// The charge DiPo recorded for the bill.
    let recorded: TxRecord
    /// The other row of the same amount in the same pay period.
    let twin: TxRecord
    /// One charge, in the caller's currency.
    let amount: Double
    /// Start of the pay period both rows fall in.
    let periodStart: Date

    init(planLabel: String, recorded: TxRecord, twin: TxRecord, amount: Double, periodStart: Date) {
        self.id = "\(recorded.id.uuidString)|\(twin.id.uuidString)"
        self.planLabel = planLabel
        self.recorded = recorded
        self.twin = twin
        self.amount = amount
        self.periodStart = periodStart
    }
}

enum RecurringDuplicates {

    private static let dismissedKey = "recurringDuplicates.notDuplicates"

    /// Pairs the user said are both real.
    static var dismissed: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
    }

    static func markBothReal(_ pair: RecurringDuplicatePair) {
        var s = dismissed
        s.insert(pair.id)
        UserDefaults.standard.set(Array(s), forKey: dismissedKey)
    }

    /// The pay period a date falls in — the same boundaries every screen uses,
    /// or the calendar month without a salary schedule.
    static func periodStart(of date: Date, payDay: Int?, salaryDates: [Date]) -> Date {
        if let day = payDay {
            return StatPeriod.cycleBoundary(offset: 0, payDay: day, salaryDates: salaryDates, now: date)
        }
        let cal = Calendar.current
        return cal.safeDate(from: cal.dateComponents([.year, .month], from: date))
    }

    /// Likely double-logged bills among `transactions` from `since` on.
    static func find(transactions: [TxRecord], recurrings: [RecurringExpense],
                     payDay: Int?, salaryDates: [Date], currency: String,
                     since: Date = .distantPast) -> [RecurringDuplicatePair] {
        let cm = CurrencyManager.shared
        let skip = dismissed
        func value(_ tx: TxRecord) -> Double {
            cm.convert(abs(tx.amount), from: tx.currency.isEmpty ? currency : tx.currency, to: currency)
        }
        let expenses = transactions.filter { (tx: TxRecord) -> Bool in
            tx.date >= since && tx.amount < 0 && tx.txSubtype != TxSubtype.transfer
        }
        let planNames = Set(recurrings.map { RecurringHistory.normalized($0.label) })
        var periodCache: [Date: Date] = [:]
        func period(_ d: Date) -> Date {
            let day = Calendar.current.startOfDay(for: d)
            if let p = periodCache[day] { return p }
            let p = periodStart(of: day, payDay: payDay, salaryDates: salaryDates)
            periodCache[day] = p
            return p
        }

        var used = Set<UUID>()
        var out: [RecurringDuplicatePair] = []
        for plan in recurrings where plan.isActive {
            let key = RecurringHistory.normalized(plan.label)
            let recorded = expenses
                .filter { (tx: TxRecord) -> Bool in
                    tx.notes == "tx.note.recurring_auto" && RecurringHistory.normalized(tx.name) == key
                }
                .sorted { $0.date < $1.date }
            for charge in recorded where !used.contains(charge.id) {
                let amt = value(charge)
                guard amt > 0 else { continue }
                let tolerance: Double = max(amt * 0.01, currency == "IDR" ? 1_000 : 0.01)
                let home = period(charge.date)
                func isTwin(_ tx: TxRecord) -> Bool {
                    guard tx.id != charge.id, !used.contains(tx.id) else { return false }
                    guard abs(value(tx) - amt) <= tolerance else { return false }
                    guard SmartBudgetManager.fixedCategories.contains(tx.category)
                            || tx.category == charge.category else { return false }
                    // Another bill's own recorded charge is that bill's, not a
                    // twin of this one — the Netlify case.
                    let name = RecurringHistory.normalized(tx.name)
                    if tx.notes == "tx.note.recurring_auto", name != key, planNames.contains(name) { return false }
                    return period(tx.date) == home
                }
                func gap(_ tx: TxRecord) -> TimeInterval { abs(tx.date.timeIntervalSince(charge.date)) }
                let twin = expenses.filter(isTwin).min { gap($0) < gap($1) }
                guard let twin else { continue }
                let pair = RecurringDuplicatePair(planLabel: plan.label, recorded: charge, twin: twin,
                                                  amount: amt, periodStart: home)
                guard !skip.contains(pair.id) else { continue }
                used.insert(charge.id)
                used.insert(twin.id)
                out.append(pair)
            }
        }
        return out.sorted { $0.recorded.date > $1.recorded.date }
    }
}

// MARK: - Review sheet

/// Both rows of each suspected double-log, side by side, with what to do:
/// delete the extra one, or keep both.
struct DuplicateReviewSheet: View {
    let pairs: [RecurringDuplicatePair]
    let currency: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    /// Pairs handled in this sheet — deleted from or kept — hidden as they go.
    @State private var handled: Set<String> = []
    @State private var toDelete: TxRecord? = nil

    private var open: [RecurringDuplicatePair] { pairs.filter { !handled.contains($0.id) } }

    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: currency) }

    private func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = LanguageManager.shared.currentLocale
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f.string(from: d)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(loc("dupe.review_intro"))
                            .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if open.isEmpty {
                            Label(loc("dupe.review_done"), systemImage: "checkmark.circle.fill")
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(AppTheme.accent)
                                .padding(.top, 8)
                        }
                        ForEach(open) { pair in pairCard(pair) }
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 30)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("dupe.review_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
        .confirmSheet(item: $toDelete,
                      title: { _ in loc("dupe.delete_title") },
                      message: { tx in
                          String(format: loc("dupe.delete_message"), tx.name,
                                 money(CurrencyManager.shared.convert(abs(tx.amount), from: tx.currency, to: currency)),
                                 day(tx.date))
                      },
                      confirmLabel: loc("dupe.delete_confirm")) { tx in
            let gone = tx.id.uuidString
            for pair in pairs where pair.id.contains(gone) { handled.insert(pair.id) }
            deleteTransactionWithGoalRollback(tx, context: context)
            try? context.save()
            HapticManager.shared.success()
        }
    }

    private func pairCard(_ pair: RecurringDuplicatePair) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pair.planLabel)
                    .font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                Text(String(format: loc("dupe.pair_sub"), money(pair.amount)))
                    .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            row(pair.recorded, badge: loc("dupe.badge_recorded"))
            row(pair.twin, badge: pair.twin.notes == "tx.note.recurring_auto"
                ? loc("dupe.badge_recorded") : loc("dupe.badge_manual"))
            Button {
                HapticManager.shared.tap()
                RecurringDuplicates.markBothReal(pair)
                withAnimation(.spring(response: 0.3)) { _ = handled.insert(pair.id) }
            } label: {
                Text(loc("dupe.both_real"))
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(AppTheme.cardMid, in: Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private func row(_ tx: TxRecord, badge: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tx.name).font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                Text("\(day(tx.date)) · \(tx.category.displayLabel)")
                    .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                Text(badge)
                    .font(.system(.caption2, weight: .bold)).foregroundStyle(AppTheme.blue)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(AppTheme.blue.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(CurrencyManager.shared.formatted(abs(tx.amount), currency: tx.currency.isEmpty ? currency : tx.currency))
                    .font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Button {
                    HapticManager.shared.tap()
                    toDelete = tx
                } label: {
                    Label(loc("dupe.delete"), systemImage: "trash")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(AppTheme.red)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(AppTheme.red.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(AppTheme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}
