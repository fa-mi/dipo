import Foundation

// MARK: - Spending rhythm
//
// Decides, from the user's own history, which expenses are part of "what a day
// costs" and which are episodes that merely happened on a day.
//
// The naive attempts and why they failed, because the failures are what the
// design is made of:
//
//   1. Exclude fixed CATEGORIES (bills, rent, debt). Necessary, insufficient —
//      an annual vehicle tax lands in Other and a dental appointment in Health.
//
//   2. Flag anything rare AND large — "seen ≤2 times and ≥4× its category
//      median". Tested against real data it was wrong in BOTH directions: it
//      flagged thirteen restaurant dinners as anomalies while missing a
//      Rp 800.000 train ticket. The reason is structural, not a tuning problem:
//      Travel's typical amount is already large so nothing clears 4×, while
//      Food's is small so ordinary dinners clear it easily. One multiplier
//      cannot serve categories whose scales differ by two orders of magnitude.
//
//   3. Hardcode Travel and Health as episodic. Works for most people and is
//      wrong for the one who commutes by train every morning — and being wrong
//      in a way the user cannot see or correct is the worst property a rule
//      can have.
//
// So the engine measures the thing that actually separates them: HOW OFTEN the
// user touches a category, then how extreme an amount is WITHIN it.
//
//   • A category touched every day or two is a habit. Everything in it counts,
//     including an expensive dinner — that is not an anomaly, it is how this
//     person lives.
//   • A category touched once a week or less is episodic. Nothing in it belongs
//     in a daily rate: a plane ticket is not a commute.
//   • In between, judge each transaction against its own category's spread,
//     using median and MAD rather than mean and standard deviation — one
//     Rp 2.000.000 outlier inflates a standard deviation enough to hide itself.
//
// Both thresholds are derived per user, so someone with different habits gets a
// different answer without anyone editing a list.
struct SpendingRhythm {

    /// A category touched this often or more is a daily habit.
    static let habitGapDays = 2.0
    /// This rarely or less, it is episodic.
    static let episodicGapDays = 7.0
    /// Modified z-score above which an amount is an outlier in its category.
    /// 3.5 is the conventional cutoff for the MAD-based score.
    static let outlierZ = 3.5
    /// Below these, there is not enough history to judge anyone's rhythm, and
    /// guessing from three weeks of a new user's data would be worse than
    /// saying nothing.
    static let minDays = 14.0
    static let minTransactions = 20

    struct Profile {
        let count: Int
        /// Average days between transactions in this category.
        let gapDays: Double
        let median: Double
        /// Median absolute deviation — the robust analogue of a standard
        /// deviation, and the reason a single huge charge cannot mask itself.
        let mad: Double

        var isHabit: Bool { gapDays <= SpendingRhythm.habitGapDays }
        var isEpisodic: Bool { gapDays >= SpendingRhythm.episodicGapDays }
    }

    private(set) var profiles: [TxCategory: Profile] = [:]
    /// False when history is too thin to classify anything.
    private(set) var isReady = false

    // MARK: Build

    /// Builds from spending history. `convert` maps a transaction to one
    /// currency so a USD purchase does not read as a rounding error beside IDR.
    init(history: [TxRecord], convert: (TxRecord) -> Double) {
        let spends = history.filter { $0.amount < 0 && $0.txSubtype != .transfer }
        guard spends.count >= Self.minTransactions,
              let first = spends.map(\.date).min(),
              let last = spends.map(\.date).max() else { return }

        let days = max(last.timeIntervalSince(first) / 86_400, 1)
        guard days >= Self.minDays else { return }

        var byCategory: [TxCategory: [Double]] = [:]
        for tx in spends {
            byCategory[tx.category, default: []].append(abs(convert(tx)))
        }
        for (cat, amounts) in byCategory {
            let med = Self.median(amounts)
            let mad = Self.median(amounts.map { abs($0 - med) })
            profiles[cat] = Profile(count: amounts.count,
                                    gapDays: days / Double(amounts.count),
                                    median: med,
                                    mad: mad)
        }
        isReady = true
    }

    // MARK: Verdict

    enum Verdict {
        /// Part of what a day costs.
        case dayToDay
        /// Its whole category is episodic — travel, medical, anything this user
        /// touches once a week or less.
        case episodicCategory
        /// A habit category, but this amount is far outside its usual range.
        case outlier
        /// The user said so.
        case userMarked

        var isIrregular: Bool { self != .dayToDay }
    }

    /// The engine's reading, before any user override.
    func autoVerdict(for tx: TxRecord, amount: Double) -> Verdict {
        guard isReady, let p = profiles[tx.category] else { return .dayToDay }
        if p.isHabit { return .dayToDay }
        if p.isEpisodic { return .episodicCategory }
        // Too few points for MAD to mean anything; do not invent a threshold.
        guard p.count >= 5, p.mad > 0 else { return .dayToDay }
        let z = 0.6745 * (amount - p.median) / p.mad
        return z >= Self.outlierZ ? .outlier : .dayToDay
    }

    /// The engine's reading with the user's correction applied.
    ///
    /// The override is stored per transaction and wins outright. An engine that
    /// argues with a correction is one people stop correcting.
    func verdict(for tx: TxRecord, amount: Double) -> Verdict {
        if let forced = tx.oneOffOverride {
            return forced ? .userMarked : .dayToDay
        }
        return autoVerdict(for: tx, amount: amount)
    }

    // MARK: Helpers

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }
}
