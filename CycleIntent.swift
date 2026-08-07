import SwiftUI
import SwiftData

// MARK: - Cycle Intent
//
// Lets the user tell DiPo that something about a pay cycle was DELIBERATE.
//
// Why this exists: the engine judges a cycle against ratios derived from the
// user's own costs, and anything below target reads as a failure — "Weak",
// "stop the leak". But plenty of real decisions look identical to failure in
// the numbers: pausing investing during a heavy month, funding a wedding from
// savings, throwing everything at a debt, a freelance month with half the
// usual income. Scolding someone for a choice they made on purpose is how a
// budgeting app loses trust.
//
// The rule this feature follows — and must keep following:
//
//   An intent changes the JUDGEMENT and the WORDING. It never hides the
//   CONSEQUENCE. A paused investment still shows as zero growth; a planned
//   savings draw still shows the balance going down. The user gets credit for
//   deciding, not a discount on reality.
//
// Intents are scoped to one pay cycle by default (they expire when the cycle
// does, so last month's exception can't quietly excuse this month), with an
// opt-in "keeps applying" for situations that genuinely span months.

@Model
final class CycleIntent {
    /// `CycleIntentKind.rawValue`. Stored as a string so unknown future kinds
    /// degrade to "ignored" instead of failing to load.
    var kindRaw: String
    /// Pay-cycle start as `yyyy-MM-dd` — the same key notifications dedupe on.
    var cycleKey: String
    /// Optional free-text reason. Shown back to the user so a decision made in
    /// June still makes sense when they look at it in September.
    var note: String
    /// True when the situation spans cycles (irregular income, a long debt
    /// push). Recurring intents apply to every cycle from `cycleKey` onward
    /// until the user turns them off.
    var isRecurring: Bool
    var createdAt: Date

    init(kind: CycleIntentKind, cycleKey: String, note: String = "", isRecurring: Bool = false) {
        self.kindRaw = kind.rawValue
        self.cycleKey = cycleKey
        self.note = note
        self.isRecurring = isRecurring
        self.createdAt = .now
    }

    var kind: CycleIntentKind? { CycleIntentKind(rawValue: kindRaw) }
}

// MARK: - Catalogue

/// The deliberate choices DiPo knows how to respect. Each one answers: what
/// did the user decide, and which judgement should stop firing because of it.
enum CycleIntentKind: String, CaseIterable, Identifiable {
    /// "I'm not investing this cycle." Growth pauses; nothing is owed to anyone.
    case pauseInvesting
    /// "I'm not funding my goals this cycle." The pledge isn't broken, it's paused.
    case pauseGoals
    /// "I'm throwing everything at debt." Lifestyle gets squeezed on purpose.
    case debtFocus
    /// "There was a one-off big expense" — wedding, medical, travel, repair.
    case plannedExpense
    /// "I meant to spend from savings." A planned drawdown, not a leak.
    case plannedSavingsDraw
    /// "My income was unusually low." Freelance gap, unpaid leave, late payment.
    case lowIncome
    /// "I'm building cash buffer first" — before investing or extra payoff.
    case buildingBuffer
    /// "I chose to spend more on living this cycle." Owned, not drifted into.
    case lifestyleSplurge

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .pauseInvesting:    return "pause.circle.fill"
        case .pauseGoals:        return "flag.slash.fill"
        case .debtFocus:         return "bolt.heart.fill"
        case .plannedExpense:    return "calendar.badge.exclamationmark"
        case .plannedSavingsDraw: return "arrow.down.circle.fill"
        case .lowIncome:         return "chart.line.downtrend.xyaxis"
        case .buildingBuffer:    return "shield.lefthalf.filled"
        case .lifestyleSplurge:  return "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .pauseInvesting, .pauseGoals, .buildingBuffer: return AppTheme.blue
        case .debtFocus:                                    return AppTheme.purple
        case .plannedExpense, .plannedSavingsDraw:          return AppTheme.orange
        case .lowIncome:                                    return AppTheme.red
        case .lifestyleSplurge:                             return AppTheme.accent
        }
    }

    var label: String { loc("intent.\(rawValue).label") }
    /// One line describing the situation, in the user's words.
    var summary: String { loc("intent.\(rawValue).summary") }
    /// Exactly what DiPo will stop doing — stated plainly so declaring an
    /// intent never feels like it might quietly disable something important.
    var effect: String { loc("intent.\(rawValue).effect") }
    /// The consequence that remains true regardless. Shown next to the effect
    /// so the trade-off is visible at the moment of choosing.
    var tradeoff: String { loc("intent.\(rawValue).tradeoff") }
}

// MARK: - Resolution

/// The intents in force for a given cycle, resolved from stored rows.
struct CycleIntentSet {
    let kinds: Set<CycleIntentKind>
    /// Notes keyed by kind, for showing the user's own reason back to them.
    let notes: [CycleIntentKind: String]

    static let empty = CycleIntentSet(kinds: [], notes: [:])

    func has(_ kind: CycleIntentKind) -> Bool { kinds.contains(kind) }
    var isEmpty: Bool { kinds.isEmpty }

    /// Resolve which intents apply to `cycleKey`: those declared for exactly
    /// this cycle, plus recurring ones declared on or before it.
    static func resolve(_ all: [CycleIntent], cycleKey: String) -> CycleIntentSet {
        var kinds: Set<CycleIntentKind> = []
        var notes: [CycleIntentKind: String] = [:]
        for row in all {
            guard let kind = row.kind else { continue }
            let applies = row.cycleKey == cycleKey || (row.isRecurring && row.cycleKey <= cycleKey)
            guard applies else { continue }
            kinds.insert(kind)
            if !row.note.isEmpty { notes[kind] = row.note }
        }
        return CycleIntentSet(kinds: kinds, notes: notes)
    }

    // MARK: Derived judgement switches
    //
    // Named for what they SUPPRESS, so call sites read as "don't scold about X"
    // rather than "flag Y is on".

    /// Don't rate investing potential as a shortfall.
    var excusesInvesting: Bool {
        has(.pauseInvesting) || has(.buildingBuffer) || has(.debtFocus) || has(.lowIncome)
    }
    /// Don't push goal funding this cycle.
    var excusesGoalFunding: Bool {
        has(.pauseGoals) || has(.pauseInvesting) || has(.lowIncome) || has(.plannedExpense)
    }
    /// Don't treat the cycle's overspend as a leak to plug.
    var excusesDeficit: Bool {
        has(.plannedExpense) || has(.plannedSavingsDraw) || has(.lowIncome)
    }
    /// Don't flag lifestyle spending as out of balance.
    var excusesLifestyle: Bool {
        has(.lifestyleSplurge) || has(.plannedExpense)
    }
    /// Don't nag about a low saving rate.
    var excusesSaving: Bool {
        has(.plannedExpense) || has(.lowIncome) || has(.debtFocus)
    }
}
