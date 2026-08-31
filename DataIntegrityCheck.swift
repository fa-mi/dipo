import SwiftUI
import SwiftData

// MARK: - Data Integrity
//
// Every ratio in Smart Budget divides real spending by real income. When the
// ledger disagrees with the schedules — a debt marked settled that still takes
// a payment every month, a recurring plan that drifted from what is actually
// charged, a savings withdrawal filed as income — the arithmetic stays correct
// and the answer is still wrong. Those are the failures nobody notices, because
// nothing looks broken.
//
// This finds them from the data itself and says what it found. It never edits
// anything: each finding names the record and what looks off, and the user
// decides. A checker that silently "corrects" your books is worse than no
// checker at all.
struct IntegrityFinding: Identifiable {
    enum Kind {
        /// Debt payments are flowing to a debt that reads as settled or gone.
        case orphanDebtPayment
        /// A recurring plan's amount no longer matches what actually gets charged.
        case recurringDrift
        /// Money moved out of savings/investments and recorded as income.
        case withdrawalAsIncome
    }

    let id = UUID()
    let kind: Kind
    /// The thing the finding is about — a debt name, a plan label, a merchant.
    let subject: String
    /// The figure that makes the case, already in the preferred currency.
    let amount: Double
    /// Secondary figure, where the finding is a comparison (plan vs actual).
    let comparedTo: Double?
    let occurrences: Int

    var icon: String {
        switch kind {
        case .orphanDebtPayment:  return "creditcard.trianglebadge.exclamationmark"
        case .recurringDrift:     return "arrow.triangle.2.circlepath"
        case .withdrawalAsIncome: return "arrow.down.left.circle"
        }
    }
    var tint: Color {
        switch kind {
        case .orphanDebtPayment:  return AppTheme.red
        case .recurringDrift:     return AppTheme.orange
        case .withdrawalAsIncome: return AppTheme.blue
        }
    }
    var titleKey: String {
        switch kind {
        case .orphanDebtPayment:  return "integrity.orphan_debt"
        case .recurringDrift:     return "integrity.drift"
        case .withdrawalAsIncome: return "integrity.withdrawal"
        }
    }
    var explainKey: String {
        switch kind {
        case .orphanDebtPayment:  return "integrity.orphan_debt_why"
        case .recurringDrift:     return "integrity.drift_why"
        case .withdrawalAsIncome: return "integrity.withdrawal_why"
        }
    }
}

enum DataIntegrityCheck {

    /// How far back to look. One cycle is too little to tell a drift from a
    /// one-off; a year lets long-dead noise resurface.
    private static let lookbackMonths = 3
    /// A recurring plan and its charge rarely match to the rupiah. Only a gap
    /// this large, seen more than once, is worth raising.
    private static let driftTolerance = 0.20

    /// Words that describe money coming BACK from somewhere the user already
    /// owned it. Used only as a secondary signal — the structural rule below
    /// carries most of the weight.
    private static let withdrawalWords = [
        "tarik", "ambil", "cairkan", "cair", "pencairan", "withdraw", "redeem",
        "jual saham", "jual emas", "tabungan",
    ]

    /// True when every word of `needle` begins a word in `haystack`.
    ///
    /// Word-PREFIX rather than exact word, so a "kos" plan still recognises a
    /// charge named "Kosan" — the same bill written differently. And word-based
    /// rather than raw substring, which is what let "kos" match nothing useful
    /// while still being loose enough to matter: the guard that actually stops
    /// "grab ke kosan" from being read as the rent is the amount band at the
    /// call site, since a Rp 10k ride cannot be a Rp 2,1jt room.
    private static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        let words = haystack.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").map(String.init)
        let needleWords = needle.split(separator: " ").map(String.init)
        guard !needleWords.isEmpty else { return false }
        return needleWords.allSatisfy { n in words.contains { $0.hasPrefix(n) } }
    }

    static func run(transactions: [TxRecord],
                    debts: [DebtRecord],
                    recurrings: [RecurringExpense]) -> [IntegrityFinding] {
        let cal = Calendar.current
        let since = cal.safeDate(byAdding: .month, value: -lookbackMonths, to: .now)
        let recent = transactions.filter { $0.date >= since && $0.txSubtype != .transfer }
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        func conv(_ t: TxRecord) -> Double {
            cm.convert(abs(t.amount), from: t.currency.isEmpty ? pref : t.currency, to: pref)
        }

        var out: [IntegrityFinding] = []
        out += orphanDebtPayments(recent, debts: debts, conv: conv)
        out += recurringDrift(recent, recurrings: recurrings, conv: conv)
        out += withdrawalsAsIncome(recent, conv: conv)
        return out.sorted { $0.amount > $1.amount }
    }

    // MARK: - Debt payments with nothing to pay
    //
    // A debt closed in the app but still being paid in the ledger means the
    // Debt Tracker reports "no active debts, DTI 0%" while a real obligation
    // leaves the account every month. That understates the debt ratio and
    // overstates what is free to spend.
    private static func orphanDebtPayments(_ tx: [TxRecord], debts: [DebtRecord],
                                           conv: (TxRecord) -> Double) -> [IntegrityFinding] {
        let payments = tx.filter { $0.category == .debtPayment && $0.amount < 0 }
        guard !payments.isEmpty else { return [] }

        let liveDebtIDs = Set(debts
            .filter { $0.isActive && !$0.manuallyClosed && $0.currentBalance > 0 }
            .map { $0.id.uuidString })

        // A payment counts as orphaned when its linked debt is gone or settled,
        // or when it carries no link at all AND no live debt exists to explain
        // it. The second condition matters: an unlinked payment is fine while
        // the user genuinely has debts.
        let orphans = payments.filter { p in
            if !p.linkedDebtID.isEmpty { return !liveDebtIDs.contains(p.linkedDebtID) }
            return liveDebtIDs.isEmpty
        }
        guard !orphans.isEmpty else { return [] }

        let total = orphans.reduce(0.0) { $0 + conv($1) }
        return [IntegrityFinding(kind: .orphanDebtPayment,
                                 subject: orphans.first?.name ?? "",
                                 amount: total, comparedTo: nil,
                                 occurrences: orphans.count)]
    }

    // MARK: - Recurring plans that drifted
    //
    // The obligation card and Smart Budget both size fixed costs from the PLAN.
    // When the plan says Rp 1jt and the charge is Rp 2jt, every downstream
    // figure is short by the difference.
    private static func recurringDrift(_ tx: [TxRecord], recurrings: [RecurringExpense],
                                       conv: (TxRecord) -> Double) -> [IntegrityFinding] {
        var out: [IntegrityFinding] = []
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency

        for plan in recurrings where plan.isActive {
            let key = plan.label.trimmingCharacters(in: .whitespaces).lowercased()
            guard key.count >= 3 else { continue }
            let planned = cm.convert(plan.amount, from: plan.currency, to: pref)
            guard planned > 0 else { continue }

            let matches = tx.filter { t in
                guard t.amount < 0 else { return false }
                // WORD match, not substring. A plain `contains` on "kos" also
                // caught "grab ke kosan" and "gojek gambir ke kosan" — rides TO
                // the boarding house, Rp 10–50k each — and dragged the average
                // from Rp 2,1jt down to Rp 862k, reporting 59% drift on a plan
                // that actually matched to the rupiah. Same failure the
                // recurring detector had with "tiket".
                guard containsWord(t.name.lowercased(), key) else { return false }
                // And it must be plausibly the same bill. A charge a fraction of
                // the plan, or several times it, is a different thing that
                // happens to share a word — not this one having drifted.
                let amt = conv(t)
                return amt >= planned * 0.25 && amt <= planned * 4.0
            }
            // Two sightings minimum: one differing charge is an anomaly, a
            // repeated one is a plan that no longer describes reality.
            guard matches.count >= 2 else { continue }

            let avg = matches.reduce(0.0) { $0 + conv($1) } / Double(matches.count)
            let gap = abs(avg - planned) / planned
            guard gap >= driftTolerance else { continue }

            out.append(IntegrityFinding(kind: .recurringDrift,
                                        subject: plan.label,
                                        amount: avg, comparedTo: planned,
                                        occurrences: matches.count))
        }
        return out
    }

    // MARK: - Withdrawals recorded as income
    //
    // Moving money out of savings or an investment is not earning it. Counted
    // as income it inflates the denominator of every ratio and can hide a real
    // deficit — the cycle looks balanced because the shortfall was quietly
    // covered by the user's own savings.
    private static func withdrawalsAsIncome(_ tx: [TxRecord],
                                            conv: (TxRecord) -> Double) -> [IntegrityFinding] {
        let suspects = tx.filter { t in
            guard t.amount > 0 else { return false }
            // Structural signal, and the stronger of the two: `investment` and
            // `debtPayment` are outflow categories. A POSITIVE amount filed
            // under one is money coming back, not money earned.
            if t.category == .investment || t.category == .debtPayment { return true }
            // Otherwise fall back to what the user named it.
            let n = t.name.lowercased()
            return withdrawalWords.contains { n.contains($0) }
        }
        guard !suspects.isEmpty else { return [] }
        let total = suspects.reduce(0.0) { $0 + conv($1) }
        return [IntegrityFinding(kind: .withdrawalAsIncome,
                                 subject: suspects.first?.name ?? "",
                                 amount: total, comparedTo: nil,
                                 occurrences: suspects.count)]
    }
}

// MARK: - Card

struct DataIntegrityCard: View {
    let findings: [IntegrityFinding]
    @State private var expanded: UUID? = nil

    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: CurrencyManager.shared.preferredCurrency)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 14)).foregroundStyle(AppTheme.orange)
                Text(loc("integrity.title"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text("\(findings.count)")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(AppTheme.orange)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(AppTheme.orange.opacity(0.15), in: Capsule())
            }
            Text(loc("integrity.subtitle"))
                .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(findings) { f in
                row(f)
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.orange.opacity(0.22), lineWidth: 1))
    }

    private func row(_ f: IntegrityFinding) -> some View {
        let isOpen = expanded == f.id
        return Button {
            HapticManager.shared.tap()
            withAnimation(.easeOut(duration: 0.2)) { expanded = isOpen ? nil : f.id }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Image(systemName: f.icon)
                        .font(.system(size: 13)).foregroundStyle(f.tint)
                        .frame(width: 28, height: 28)
                        .background(f.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline(f))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Text(String(format: loc("integrity.seen"), f.occurrences))
                            .font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                if isOpen {
                    Text(loc(f.explainKey))
                        .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(11)
            .background(AppTheme.cardMid.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func headline(_ f: IntegrityFinding) -> String {
        switch f.kind {
        case .orphanDebtPayment:
            return String(format: loc(f.titleKey), money(f.amount))
        case .recurringDrift:
            return String(format: loc(f.titleKey), f.subject,
                          money(f.comparedTo ?? 0), money(f.amount))
        case .withdrawalAsIncome:
            return String(format: loc(f.titleKey), money(f.amount))
        }
    }
}

// MARK: - Windfall discipline
//
// A cycle can run past the salary and still be fine — a bonus landed and some
// of it was spent. Judging that as a deficit is wrong. But so is waving it
// through: the question worth answering is not "did you overspend" but "when
// extra money arrived, where did it go".
//
// That is the difference between a good month and an expensive one, and no
// income-vs-expense line can express it. Rp 17,75jt of extra income with 7%
// reaching debt or investing is a very different story from the same figure
// with 60% reaching them — yet both look identical on a cash-flow chart.
struct WindfallReview {
    /// Income beyond the regular salary that arrived this cycle.
    let extraIncome: Double
    /// Of that, what went to debt payoff or investing.
    let toDebtOrInvest: Double
    /// Of that, what was moved into savings goals.
    let toGoals: Double

    var productive: Double { toDebtOrInvest + toGoals }
    var absorbed: Double { max(extraIncome - productive, 0) }
    var productiveShare: Double { extraIncome > 0 ? productive / extraIncome : 0 }

    /// Whether there is anything to say. A cycle with no extra income has no
    /// windfall to review, and inventing a verdict would be noise.
    var isRelevant: Bool { extraIncome > 0 }

    enum Verdict { case wellUsed, mixed, absorbed }

    /// Bands chosen against the app's own 20% invest/debt target: clearing that
    /// bar with windfall money is doing well, half of it is a fair attempt, and
    /// almost none of it means the money simply raised the standard of living
    /// for a month and left nothing behind.
    var verdict: Verdict {
        if productiveShare >= 0.40 { return .wellUsed }
        return productiveShare >= 0.15 ? .mixed : .absorbed
    }

    static func build(cycleTransactions tx: [TxRecord], currency: String) -> WindfallReview {
        let cm = CurrencyManager.shared
        func conv(_ t: TxRecord) -> Double {
            cm.convert(abs(t.amount), from: t.currency.isEmpty ? currency : t.currency, to: currency)
        }
        let usable = tx.filter { $0.txSubtype != .transfer }

        // Extra = income that isn't the salary line. Deliberately excludes
        // investment and debtPayment categories on the income side: a positive
        // amount there is a withdrawal coming back, not new money, and counting
        // it would credit the user for "extra income" they already owned.
        let extra = usable
            .filter { $0.amount > 0 && $0.category != .salary
                      && $0.category != .investment && $0.category != .debtPayment }
            .reduce(0.0) { $0 + conv($1) }

        let productive = usable
            .filter { $0.amount < 0 && ($0.category == .investment || $0.category == .debtPayment) }
            .reduce(0.0) { $0 + conv($1) }
        let goals = usable
            .filter { $0.amount < 0 && !$0.linkedGoalID.isEmpty }
            .reduce(0.0) { $0 + conv($1) }

        return WindfallReview(extraIncome: extra,
                              toDebtOrInvest: productive,
                              toGoals: goals)
    }
}

extension WindfallReview.Verdict {
    var tint: Color {
        switch self {
        case .wellUsed: return AppTheme.accent
        case .mixed:    return AppTheme.orange
        case .absorbed: return AppTheme.red
        }
    }
    var labelKey: String {
        switch self {
        case .wellUsed: return "windfall.verdict_good"
        case .mixed:    return "windfall.verdict_mixed"
        case .absorbed: return "windfall.verdict_absorbed"
        }
    }
    var bodyKey: String {
        switch self {
        case .wellUsed: return "windfall.body_good"
        case .mixed:    return "windfall.body_mixed"
        case .absorbed: return "windfall.body_absorbed"
        }
    }
}

struct WindfallCard: View {
    let review: WindfallReview
    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: CurrencyManager.shared.preferredCurrency)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 13)).foregroundStyle(review.verdict.tint)
                Text(loc("windfall.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(loc(review.verdict.labelKey))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(review.verdict.tint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(review.verdict.tint.opacity(0.15), in: Capsule())
            }

            Text(String(format: loc("windfall.headline"),
                        money(review.extraIncome),
                        String(format: "%.0f%%", review.productiveShare * 100)))
                .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Where it went, to scale.
            GeometryReader { g in
                let p = CGFloat(min(review.productiveShare, 1))
                HStack(spacing: 2) {
                    if p > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AppTheme.accent).frame(width: g.size.width * p, height: 10)
                    }
                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppTheme.cardMid).frame(width: g.size.width * (1 - p), height: 10)
                }
            }
            .frame(height: 10)

            VStack(spacing: 6) {
                line(loc("windfall.to_debt"), money(review.toDebtOrInvest), AppTheme.accent)
                line(loc("windfall.to_goals"), money(review.toGoals), AppTheme.blue)
                line(loc("windfall.absorbed"), money(review.absorbed), AppTheme.textSecondary)
            }

            Text(loc(review.verdict.bodyKey))
                .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .stroke(review.verdict.tint.opacity(0.22), lineWidth: 1))
    }

    private func line(_ l: String, _ v: String, _ tint: Color) -> some View {
        HStack {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(l).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(v).font(.system(size: 11, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
        }
    }
}
