import AppIntents
import Foundation
import SwiftData

// MARK: - Log an expense, ask what is left — from Siri, Shortcuts or Spotlight
//
// Two actions any iPhone on iOS 26 can run, Apple Intelligence or not. Both
// run in the background, so the phone stays on whatever it was showing, and
// both work offline: nothing here leaves the device.
//
// Both need the phone unlocked (`requiresAuthentication`), so neither runs
// from the Lock Screen. "Money left" goes further and keeps to DiPo's own
// lock and to balances hidden on Home. Those exist for a phone the household
// shares or a screen read over a shoulder, and Siri saying the figures out
// loud would walk straight past both.
//
// Titles, descriptions and the category and card names in the Shortcuts
// editor are compile-time text, in English like the other intents here. What
// Siri says back runs through `loc()`, in the app's language.

/// What an expense logged from Siri is for. The everyday categories only: a
/// debt payment belongs to a debt, and income has no business in "log an
/// expense".
enum ExpenseCategory: String, AppEnum, CaseIterable {
    case food, transport, shopping, bills, health, travel, commitment, other

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Category"
    static var caseDisplayRepresentations: [ExpenseCategory: DisplayRepresentation] = [
        .food: "Food & drinks",
        .transport: "Transport",
        .shopping: "Shopping",
        .bills: "Bills",
        .health: "Health",
        .travel: "Travel",
        .commitment: "Rent & family",
        .other: "Other",
    ]

    var category: TxCategory {
        switch self {
        case .food:       return .food
        case .transport:  return .transport
        case .shopping:   return .shopping
        case .bills:      return .bills
        case .health:     return .health
        case .travel:     return .travel
        case .commitment: return .commitment
        case .other:      return .other
        }
    }

    static let categories: Set<TxCategory> = Set(allCases.map(\.category))
}

/// A card or wallet, as Shortcuts lists it and Siri names it.
struct CardEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Card"
    static var defaultQuery = CardQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct CardQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [CardEntity] {
        let wanted = Set(identifiers)
        return DiPoIntentSupport.cards()
            .filter { wanted.contains($0.id) }
            .map { CardEntity(id: $0.id, name: DiPoIntentSupport.spokenName($0)) }
    }

    /// The main card first, then the rest in the Wallet's order.
    @MainActor
    func suggestedEntities() async throws -> [CardEntity] {
        DiPoIntentSupport.cards()
            .sorted { a, b in
                if MainCard.isMain(a) != MainCard.isMain(b) { return MainCard.isMain(a) }
                return a.sortOrder < b.sortOrder
            }
            .map { CardEntity(id: $0.id, name: DiPoIntentSupport.spokenName($0)) }
    }
}

// MARK: - Log an expense

struct LogExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "Log an Expense"
    static var description = IntentDescription(
        "Records an expense in DiPo without opening it. DiPo says what it will save and asks first."
    )
    static let supportedModes: IntentModes = .background
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Amount", requestValueDialog: "How much was it?")
    var amount: Double

    @Parameter(title: "Name", requestValueDialog: "What was it for?")
    var name: String

    /// Left empty, DiPo picks it from the name, the way the add form does.
    @Parameter(title: "Category")
    var category: ExpenseCategory?

    /// Left empty, the main card.
    @Parameter(title: "Card")
    var card: CardEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) for \(\.$name)") {
            \.$category
            \.$card
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard DiPoIntentSupport.isRecordable(amount) else {
            return .result(dialog: "\(loc("appintent.log.zero"))")
        }
        let context = DiPoApp.sharedModelContainer.mainContext
        let cards = DiPoIntentSupport.cards(in: context)
        guard let target = card.flatMap({ picked in cards.first(where: { $0.id == picked.id }) })
                ?? DiPoIntentSupport.mainCard(in: cards) else {
            return .result(dialog: "\(DiPoIntentSupport.missingCardText(cards))")
        }

        let label = DiPoIntentSupport.entryName(name)
        let cat = category?.category
            ?? DiPoIntentSupport.suggestedCategory(for: label, history: cards.flatMap(\.transactions))
        let currency = target.resolvedCurrency
        let money = CurrencyManager.shared.formatted(amount, currency: currency)
        let place = DiPoIntentSupport.spokenName(target)

        // Said back before anything is written: a misheard "two hundred
        // thousand" is caught here, not found in the ledger a week later.
        try await requestConfirmation(
            actionName: .log,
            dialog: "\(String(format: loc("appintent.log.confirm"), money, label, place))")

        let tx = DiPoIntentSupport.expense(amount: amount, name: label, category: cat, currency: currency)
        // Insert before appending: `transactions` has no inverse, so a row
        // added only through the card's array is not reliably persisted.
        context.insert(tx)
        target.transactions.append(tx)
        try context.save()
        // The app may stay in the background; the Home Screen widget should
        // not wait for it to come forward to show the new figure.
        WidgetDataSync.refresh(context: context)
        return .result(dialog: "\(String(format: loc("appintent.log.saved"), money, label, place))")
    }
}

// MARK: - Money left

struct MoneyLeftIntent: AppIntent {
    static var title: LocalizedStringResource = "Money Left"
    static var description = IntentDescription(
        "Says your main card's balance, this period's spending and what is left of your income, and how long until payday. When DiPo is locked or its balances are hidden, nothing is read out."
    )
    /// Background by default. Brought forward only when DiPo's lock is on,
    /// so the lock can ask first.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if AuthViewModel.lockIsOn {
            // Open DiPo, where its lock asks for Face ID and Home shows the
            // figures behind it. Nothing is said, and nothing is read first.
            if systemContext.currentMode.canContinueInForeground {
                try await continueInForeground(alwaysConfirm: false)
            }
            return .result(dialog: "\(loc("appintent.money.locked"))")
        }
        let context = DiPoApp.sharedModelContainer.mainContext
        let cards = DiPoIntentSupport.cards(in: context)
        guard let main = DiPoIntentSupport.mainCard(in: cards) else {
            return .result(dialog: "\(DiPoIntentSupport.missingCardText(cards))")
        }
        if DiPoIntentSupport.balancesHidden(main: main, cards: cards) {
            return .result(dialog: "\(loc("appintent.money.hidden"))")
        }
        let schedules = (try? context.fetch(FetchDescriptor<SalarySchedule>())) ?? []
        return .result(dialog: "\(MoneyLeftSummary.make(main: main, cards: cards, schedules: schedules).text)")
    }
}

/// What "Money left" says, from figures alone so it can be checked without
/// a store. The same window and the same three figures as Home's "This
/// period": income plus money added to the period, spending & bills, and
/// what is left of the one after the other.
struct MoneyLeftSummary {
    var cardName: String
    var balance: Double
    var currency: String
    /// The payday the period opened on; nil without a salary schedule, when
    /// the period is the calendar month, as on Home.
    var periodStart: Date?
    var income: Double
    var living: Double
    var daysToPayday: Int?

    static func make(main: BankCard, cards: [BankCard], schedules: [SalarySchedule],
                     now: Date = Date()) -> MoneyLeftSummary {
        let cal = Calendar.current
        let currency = main.resolvedCurrency
        // The main card with the cards it pays bills from — the pot Home and
        // Statistics read.
        let scope = MainCard.isMain(main) ? MainCard.budgetCards(in: cards) : [main]
        let cycle = MainCard.payDay(schedules).map {
            StatPeriod.cycle(payDay: $0, salaryDates: StatPeriod.salaryDates(on: main), now: now)
        }
        let start = cycle?.start ?? cal.safeDate(from: cal.dateComponents([.year, .month], from: now))
        let all = scope.flatMap(\.transactions)
        let rows = all.filter { $0.date >= start }
        let convert: (TxRecord) -> Double = {
            CurrencyManager.shared.convert($0.amount, from: $0.currency, to: currency)
        }
        let extra = MainCard.isMain(main) ? ExtraFunds.total(in: all, from: start, currency: currency) : 0
        return MoneyLeftSummary(
            cardName: DiPoIntentSupport.spokenName(main),
            balance: main.computedBalance(),
            currency: currency,
            periodStart: cycle?.start,
            income: StatisticsView.income(rows, convert: convert) + extra,
            living: StatisticsView.living(rows, convert: convert),
            daysToPayday: cycle.map { StatPeriod.daysLeft(in: $0, now: now) })
    }

    var text: String {
        let money = { CurrencyManager.shared.formatted($0, currency: currency) }
        let lead = periodStart.map {
            String(format: loc("appintent.money.lead_payday"),
                   DateFormatterCache.template("dMMM").string(from: $0))
        } ?? loc("appintent.money.lead_month")
        var period = String(format: loc("appintent.money.spent"), lead, money(living))
        // Without income in the period there is nothing for spending to be
        // left of, and "Rp 0 left" would read as broke.
        if income >= 0.5 {
            let left = income - living
            period += ", " + (left >= -0.5
                ? String(format: loc("appintent.money.left"), money(max(left, 0)))
                : String(format: loc("appintent.money.over"), money(-left)))
        }
        var sentences = [String(format: loc("appintent.money.balance"), cardName, money(balance)),
                         period + "."]
        if let days = daysToPayday {
            sentences.append(days <= 0 ? loc("appintent.money.payday_today")
                             : days == 1 ? loc("appintent.money.payday_tomorrow")
                             : String(format: loc("appintent.money.payday_in"), days))
        }
        return sentences.joined(separator: " ")
    }
}

// MARK: - Shared

enum DiPoIntentSupport {

    @MainActor
    static func cards(in context: ModelContext = DiPoApp.sharedModelContainer.mainContext) -> [BankCard] {
        (try? context.fetch(FetchDescriptor<BankCard>())) ?? []
    }

    /// The main card, or the only card that could be one. Read-only: unlike
    /// `MainCard.reconcile`, nothing is stored from Siri.
    static func mainCard(in cards: [BankCard]) -> BankCard? {
        if let main = MainCard.resolve(in: cards) { return main }
        let pool = MainCard.eligible(cards)
        return pool.count == 1 ? pool[0] : nil
    }

    /// Why there is no card to use: none at all, or no main card among several.
    static func missingCardText(_ cards: [BankCard]) -> String {
        loc(cards.isEmpty ? "appintent.no_card" : "appintent.no_main")
    }

    /// How Siri names a card: "BCA 0969", "GoPay". Not `pickerLabel`, which
    /// leads with the holder's name — read aloud, that says whose phone it
    /// is rather than which card.
    static func spokenName(_ card: BankCard) -> String {
        if card.isDigitalWallet, !card.walletProvider.isEmpty { return card.walletProvider }
        let last4 = String(card.cardNumber.filter(\.isNumber).suffix(4))
        if let bank = BankIssuer.find(card.issuerID)?.name {
            return last4.isEmpty ? bank : "\(bank) \(last4)"
        }
        return card.pickerLabel
    }

    /// The same bounds the quick-entry parser holds an amount to.
    static func isRecordable(_ amount: Double) -> Bool {
        amount.isFinite && amount > 0 && amount < 1_000_000_000_000
    }

    /// The name as said, tidied to one line; "Expense" when nothing was said.
    static func entryName(_ raw: String) -> String {
        let name = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? loc("appintent.log.default_name") : String(name.prefix(60))
    }

    /// From the user's own history first, then the shipped keyword list —
    /// kept to the everyday categories `ExpenseCategory` offers.
    static func suggestedCategory(for name: String, history: [TxRecord]) -> TxCategory {
        let learned = SmartBudgetManager.suggestCategory(for: name, txType: "Expense", transactions: history)
        if let learned, ExpenseCategory.categories.contains(learned) { return learned }
        let listed = SmartBudgetManager.suggestCategory(for: name, txType: "Expense")
        if let listed, ExpenseCategory.categories.contains(listed) { return listed }
        return .other
    }

    /// The row the add form would write for the same entry, marked as
    /// coming from Siri or Shortcuts.
    static func expense(amount: Double, name: String, category: TxCategory, currency: String,
                        date: Date = Date()) -> TxRecord {
        TxRecord(
            name: name,
            date: date,
            amount: -abs(amount),
            // Stable keys, never `loc(...)` output: a stored translation would
            // freeze the language at the moment of capture.
            type: "tx.type.purchase",
            icon: String(name.prefix(2)).uppercased(),
            iconBgHex: category.iconBg,
            category: category,
            currency: currency,
            notes: "tx.note.from_siri"
        )
    }

    /// Hidden on Home: every balance at once, or the main card's own. The
    /// same test Home applies to its "This period" card.
    static func balancesHidden(main: BankCard, cards: [BankCard],
                               defaults: UserDefaults = .standard) -> Bool {
        let hideAll = defaults.bool(forKey: HomePrefs.hideBalancesKey)
            && HomeTotalRow.shows(cashAccounts: cards.filter { !$0.isCreditCard }.count)
        return hideAll || main.isHidden
    }
}
