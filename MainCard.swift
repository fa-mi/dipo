import SwiftUI
import SwiftData

// MARK: - Main card
//
// The single account every calculation in DiPo is measured against.
//
// Until now each feature picked its own anchor, and they disagreed. Smart
// Budget used `budgetCardID`. Statistics auto-selected "the first card with
// activity". Salary schedules linked to whichever card was chosen in the form.
// Three answers to one question, so the same person could read Rp 10.000.000 of
// income on one screen and a different figure on the next, with nothing on
// either screen explaining why. That is not a display bug — a budget is a
// statement about ONE pot of money, and a ratio computed over a shifting
// denominator does not mean anything at all.
//
// So there is now one choice, made once, in the place where a person already
// thinks about their accounts: the Wallet. Everything downstream reads it.
//
// This deliberately re-uses `SmartBudgetManager.budgetCardID` as the storage
// rather than introducing a second key. A parallel setting would be a second
// source of truth, which is the exact problem being fixed — and it keeps
// existing backups, restores and web sync working untouched.
enum MainCard {

    // MARK: Storage

    static var id: String? {
        get { SmartBudgetManager.shared.budgetCardID }
        set { SmartBudgetManager.shared.budgetCardID = newValue }
    }

    /// Cards that can serve as the anchor.
    ///
    /// A credit card is excluded on purpose. The main card is where income
    /// lands and against which allowances are measured; a credit line holds
    /// debt, not income, so anchoring the budget to one would compute every
    /// ratio over a denominator of zero. Debit accounts and e-wallets qualify.
    static func eligible(_ cards: [BankCard]) -> [BankCard] {
        cards.filter { !$0.isCreditCard }
    }

    static func resolve(in cards: [BankCard]) -> BankCard? {
        guard let id else { return nil }
        return eligible(cards).first { $0.id.uuidString == id }
    }

    static func isMain(_ card: BankCard) -> Bool {
        id != nil && card.id.uuidString == id
    }

    static func set(_ card: BankCard) {
        guard !card.isCreditCard else { return }
        id = card.id.uuidString
    }

    // MARK: Reconciliation

    /// Keeps the stored choice honest against the cards that actually exist.
    ///
    /// Two jobs, both of which prevent the user being asked a question that has
    /// no meaningful answer:
    ///
    ///  • A dangling id — the card was deleted, or turned into a credit card —
    ///    is cleared, so the app asks again instead of silently reporting on
    ///    nothing.
    ///  • With exactly one eligible card there is no choice to make, so it is
    ///    adopted rather than presented as a decision. Demanding a pick from a
    ///    list of one is ceremony, not consent.
    @discardableResult
    static func reconcile(cards: [BankCard]) -> BankCard? {
        let pool = eligible(cards)
        // An empty list is NOT evidence the chosen card is gone.
        //
        // `AppViewModel.cards` starts empty and fills in asynchronously — that
        // is what its `isLoaded` flag exists to signal. Reconciling before the
        // store had loaded therefore found no match for a perfectly valid id
        // and cleared it, so the user's choice was erased on every launch and
        // the setup gate reappeared as though they had never answered. The
        // setting was saved correctly the whole time; this wiped it.
        //
        // Clearing is only justified when there IS a pool and the card is not
        // in it — the actual "you deleted it" case.
        guard !pool.isEmpty else { return resolve(in: cards) }
        if let id, !pool.contains(where: { $0.id.uuidString == id }) {
            self.id = nil
        }
        if self.id == nil, pool.count == 1 {
            self.id = pool[0].id.uuidString
        }
        return resolve(in: cards)
    }

    /// Whether the user must choose before the rest of the app can mean
    /// anything. False when there is nothing to choose from — a user with no
    /// cards is sent to add one, not interrogated about which to anchor to.
    static func needsChoice(cards: [BankCard]) -> Bool {
        eligible(cards).count >= 2 && resolve(in: cards) == nil
    }

    // MARK: Income that lands here

    /// Active salary schedules paid into the main card.
    ///
    /// Someone with two jobs paid into two accounts has two incomes, and only
    /// one of them funds the account this budget measures. Counting both while
    /// measuring spending on one inflates every allowance by the size of the
    /// other job — a second Rp 5.000.000 salary would quietly raise the Daily
    /// Needs ceiling on an account that never receives it.
    ///
    /// A schedule with NO card is counted. `cardID` is optional and schedules
    /// created before it mattered have none; excluding them would drop a user's
    /// entire income to zero to enforce a rule they were never shown. Unassigned
    /// means "wherever the app is looking", which is here.
    static func salaries(_ all: [SalarySchedule]) -> [SalarySchedule] {
        let active = all.filter(\.isActive)
        guard let id, let uuid = UUID(uuidString: id) else { return active }
        let here = active.filter { $0.cardID == nil || $0.cardID == uuid }
        // NOTHING lands on the anchor — every schedule names some other card.
        // Scoping strictly would leave income at zero, and an income of zero
        // does not read as "your salary is elsewhere", it reads as a broken
        // app: the allowances collapse, the health score bottoms out, and the
        // commitment preview disappears entirely. Falling back to everything is
        // the behaviour from before the anchor existed, which is wrong in a way
        // the user can at least recognise.
        return here.isEmpty ? active : here
    }

    /// Active salary landing on some other account. Disclosed rather than
    /// silently dropped — a second job missing from the plan with no
    /// explanation looks like the app lost it.
    static func salariesElsewhere(_ all: [SalarySchedule]) -> [SalarySchedule] {
        let active = all.filter(\.isActive)
        guard let id, let uuid = UUID(uuidString: id) else { return [] }
        let other = active.filter { $0.cardID != nil && $0.cardID != uuid }
        // Mirrors the fallback above: when everything is elsewhere, everything
        // is being COUNTED, so nothing is being excluded and there is nothing
        // to disclose. Reporting "Rp 15jt is not counted here" beside a plan
        // built on exactly that Rp 15jt would be a lie in the other direction.
        return other.count == active.count ? [] : other
    }

    // MARK: Which payday anchors the cycle

    /// The schedule the pay cycle is measured from.
    ///
    /// Two jobs paid into the SAME account on different days give two candidate
    /// cycle starts, and five screens each resolved that by taking `.first` of a
    /// differently-ordered array. The same person could get a cycle anchored on
    /// the 25th in Statistics and on the 5th in Smart Budget, and every figure
    /// downstream — spent vs budget, overspending, the trend chart — would
    /// disagree accordingly, over a window nobody chose.
    ///
    /// The rule, in order:
    ///   1. the schedule the user pinned — an explicit answer, and the pin is
    ///      already exclusive in the salary list, so it means exactly this;
    ///   2. otherwise the largest, converted to one currency;
    ///   3. ties broken by the earliest created.
    ///
    /// Largest before earliest because someone with a main job and a side job
    /// builds their month around the main one, whichever they happened to enter
    /// into DiPo first.
    static func anchor(among list: [SalarySchedule]) -> SalarySchedule? {
        if let pinned = list.first(where: \.isPinned) { return pinned }
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        func value(_ s: SalarySchedule) -> Double {
            cm.convert(s.amount, from: s.currency, to: pref)
        }
        return list.max { a, b in
            let (va, vb) = (value(a), value(b))
            if va != vb { return va < vb }
            return a.createdAt > b.createdAt
        }
    }

    static func anchorSalary(_ all: [SalarySchedule]) -> SalarySchedule? {
        anchor(among: salaries(all))
    }

    /// Day of the month the pay cycle starts on. nil when there is no active
    /// salary landing here, in which case callers fall back to the calendar
    /// month exactly as before.
    static func payDay(_ all: [SalarySchedule]) -> Int? {
        anchorSalary(all)?.dayOfMonth
    }

    // MARK: What depends on it

    /// Named so the requirement can be justified to the user rather than
    /// asserted. "Required" with no reason reads as an obstacle; the same
    /// requirement with the list of things it feeds reads as a setup step.
    struct Dependent: Identifiable {
        let id = UUID()
        let icon: String
        let titleKey: String
        let detailKey: String
    }

    static let dependents: [Dependent] = [
        .init(icon: "chart.bar.fill",
              titleKey: "main.dep_stats",       detailKey: "main.dep_stats_d"),
        .init(icon: "chart.pie.fill",
              titleKey: "main.dep_budget",      detailKey: "main.dep_budget_d"),
        .init(icon: "calendar.badge.clock",
              titleKey: "main.dep_salary",      detailKey: "main.dep_salary_d"),
        .init(icon: "creditcard.and.123",
              titleKey: "main.dep_obligations", detailKey: "main.dep_obligations_d")
    ]
}
