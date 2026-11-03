import SwiftUI
import SwiftData

// MARK: - The Debts page, minimal
//
// The page used to be a stack of cards: a summary card with icon tiles and a
// tinted verdict box, a "Due soon" card with a green Pay on every row, a card
// per debt with its own green Pay, a payoff-order card, Smart Budget's card,
// the analysis card, and a bordered card per credit card with its history and
// instalments underneath. Six green buttons, and no one place that said what
// to do.
//
// Now: the total as the one big number, one box that says which debt to pay
// first (the page's only green button), the rest as plain rows, credit cards
// as plain rows that open their own page, and the tools as one row each.

// MARK: When a debt is due

/// Where a debt stands against this month's due day.
enum DebtDue: Equatable {
    /// A payment against it is recorded this month.
    case paid
    /// The due day passed this many days ago and nothing is recorded. Only
    /// within `lateWindow`: past that, a debt paid somewhere DiPo never heard
    /// about would read as late for the rest of the month.
    case overdue(Int)
    case today
    /// Due in this many days, within `soonWindow`.
    case soon(Int)
    /// Due later, on this day of the month.
    case later(Int)

    static let lateWindow = 5
    static let soonWindow = 3

    /// `dueDay` is clamped into the month: a debt due on the 31st falls on
    /// the 30th in November.
    static func of(dueDay: Int, today: Int, daysInMonth: Int, paidThisMonth: Bool) -> DebtDue {
        if paidThisMonth { return .paid }
        let due = min(max(dueDay, 1), max(daysInMonth, 1))
        let diff = due - today
        if diff == 0 { return .today }
        if diff > 0 { return diff <= soonWindow ? .soon(diff) : .later(due) }
        return -diff <= lateWindow ? .overdue(-diff) : .later(due)
    }

    static func of(_ debt: DebtRecord, paid: Set<String>, now: Date = .now) -> DebtDue {
        let cal = Calendar.current
        return of(dueDay: debt.dueDayOfMonth,
                  today: cal.component(.day, from: now),
                  daysInMonth: cal.range(of: .day, in: .month, for: now)?.count ?? 30,
                  paidThisMonth: paid.contains(debt.id.uuidString))
    }

    /// The ids of the debts with a payment recorded this calendar month.
    static func paidThisMonth(_ txs: [TxRecord], now: Date = .now) -> Set<String> {
        let start = Calendar.current.dateInterval(of: .month, for: now)?.start ?? .distantPast
        return Set(txs.lazy
            .filter { !$0.linkedDebtID.isEmpty && $0.amount < 0 && $0.date >= start }
            .map(\.linkedDebtID))
    }

    var text: String {
        switch self {
        case .paid:              return loc("debt.paid_this_month")
        case .overdue(let d):    return String(format: loc("debt.overdue_days"), d)
        case .today:             return loc("debt.due_today")
        case .soon(1):           return loc("debt.due_tomorrow")
        case .soon(let d):       return String(format: loc("debt.due_in_days"), d)
        case .later(let day):    return String(format: loc("debt.due_short"), day)
        }
    }

    /// Red only when it is late; orange while it is close; grey otherwise.
    var color: Color {
        switch self {
        case .overdue:       return AppTheme.red
        case .today, .soon:  return AppTheme.orange
        case .paid, .later:  return AppTheme.textSecondary
        }
    }

    var isLate: Bool { if case .overdue = self { return true } else { return false } }
    var daysLate: Int { if case .overdue(let d) = self { return d } else { return 0 } }
}

// MARK: Which to pay first

enum DebtPayFirst {
    /// A late debt first, the latest of them; otherwise the first in the
    /// chosen order that has not been paid this month; otherwise the first.
    static func pick<T>(_ order: [T], due: (T) -> DebtDue) -> T? {
        let late = order.filter { due($0).isLate }
        if let latest = late.max(by: { due($0).daysLate < due($1).daysLate }) { return latest }
        return order.first { due($0) != .paid } ?? order.first
    }

    /// Why this one, in a sentence. Nil when it is the only debt.
    static func reason(_ debt: DebtRecord, due: DebtDue, byInterest: Bool, count: Int) -> String? {
        if due.isLate { return loc("debt.why_late") }
        guard count > 1 else { return nil }
        if byInterest {
            return debt.annualInterestRate > 0
                ? String(format: loc("debt.why_interest"), DebtFirstAdvice.rate(debt.annualInterestRate))
                : nil
        }
        return loc("debt.why_smallest")
    }
}

// MARK: - Total

/// The total owed as the page's one big number, what is paid each month, and
/// whether a usual month carries it, in two lines.
struct DebtTotalHeader: View {
    let engine: FinancialHealthEngine
    let affordability: DebtAffordability
    var cardOwed: Double = 0
    let debtFreeDate: Date?
    let onAdd: () -> Void

    private var currency: String { CurrencyManager.shared.preferredCurrency }
    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: currency) }

    /// Red only when the payments are more than a usual month carries;
    /// orange when it is tight; grey when it is fine.
    static func verdictColor(_ verdict: DebtAffordability.Verdict?) -> Color {
        switch verdict {
        case .heavy?: return AppTheme.red
        case .tight?: return AppTheme.orange
        default:      return AppTheme.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center) {
                Text(loc("debt.total_title"))
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(width: 40, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel(loc("a11y.add_debt"))
            }
            Text(money(engine.totalDebt))
                .font(.system(.largeTitle, weight: .bold).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            if cardOwed >= 0.5 {
                Text(String(format: loc("debt.total_cards_note"), money(cardOwed)))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            if engine.totalEffectiveMinimums >= 0.5 {
                HStack(spacing: 4) {
                    Text(loc("debt.monthly_payments_label"))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(money(engine.totalEffectiveMinimums))
                        .fontWeight(.semibold)
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .font(.system(.subheadline))
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.top, 6)
            }
            verdict
                .padding(.top, 2)
        }
    }

    private var verdict: some View {
        var line = affordability.title()
        if let debtFreeDate {
            line += " · " + String(format: loc("debt.free_around"),
                                   debtFreeDate.formatted(.dateTime.month(.abbreviated).year()))
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(line)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(Self.verdictColor(affordability.verdict))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = affordability.detail(currency: currency) {
                Text(detail)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Pay this first

/// The one box on the page: which debt to pay first, why, and the page's only
/// green button.
struct DebtPayFirstBox: View {
    let debt: DebtRecord
    let due: DebtDue
    let reason: String?
    let vm: DebtViewModel
    let onPay: () -> Void
    @State private var showActions = false

    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: debt.currency) }

    private var payLabel: String {
        debt.effectiveMinimumPayment >= 0.5
            ? String(format: loc("debt.pay_amount"), money(debt.effectiveMinimumPayment))
            : loc("debt.make_payment")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text(loc("debt.pay_first"))
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Button { HapticManager.shared.tap(); showActions = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 36, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc("a11y.more_actions"))
            }
            Text(debt.name)
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(2)
            if let reason {
                Text(reason)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(due.text)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(due.color)

            HStack(alignment: .firstTextBaseline) {
                Text(loc("debt.left_label"))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text(money(debt.currentBalance))
                    .font(.system(.subheadline, weight: .bold).monospacedDigit())
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())
            }
            .padding(.top, 10)
            DebtThinBar(progress: debt.percentagePaid / 100)

            Button { HapticManager.shared.tap(); onPay() } label: {
                Text(payLabel)
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(AppTheme.onVividFill)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.top, 12)
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        .modifier(DebtActions(debt: debt, vm: vm, showActions: $showActions))
    }
}

// MARK: - A debt as a row

/// Name and what is left, the rate and when it is due, and a thin bar of how
/// much is paid. Tapping it opens its actions: pay, edit, mark paid, delete.
struct DebtRow: View {
    let debt: DebtRecord
    let due: DebtDue
    let vm: DebtViewModel
    @State private var showActions = false

    static func rateText(_ debt: DebtRecord) -> String {
        debt.annualInterestRate > 0
            ? String(format: loc("debt.apr_only"), DebtFirstAdvice.rate(debt.annualInterestRate))
            : loc("debt.no_interest")
    }

    var body: some View {
        Button { HapticManager.shared.tap(); showActions = true } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(debt.name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(CurrencyManager.shared.formatted(debt.currentBalance, currency: debt.currency))
                        .font(.system(.subheadline, weight: .bold).monospacedDigit())
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                HStack(spacing: 0) {
                    Text(Self.rateText(debt) + " · ")
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(due.text)
                        .foregroundStyle(due.color)
                }
                .font(.system(.caption))
                .lineLimit(1).minimumScaleFactor(0.85)
                DebtThinBar(progress: debt.percentagePaid / 100)
                    .padding(.top, 5)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(loc("a11y.more_actions"))
        .modifier(DebtActions(debt: debt, vm: vm, showActions: $showActions))
    }
}

/// How much of a debt is paid, or of a limit used: 3 pt, in ink on a grey
/// track. Orange only where it warns (a card near its limit).
struct DebtThinBar: View {
    let progress: Double
    var tint: Color = AppTheme.textPrimary

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.cardMid)
                Capsule().fill(tint)
                    .frame(width: g.size.width * CGFloat(min(max(progress, 0), 1)))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// A plain hairline between rows.
struct DebtHairline: View {
    var body: some View { Rectangle().fill(AppTheme.cardMid).frame(height: 1) }
}

// MARK: - What a debt can do

/// The actions a debt row or the pay-first box opens: pay, edit, mark paid,
/// turn into a credit card, delete. Was DebtCard's own; shared now that the
/// card is a row.
struct DebtActions: ViewModifier {
    let debt: DebtRecord
    let vm: DebtViewModel
    @Binding var showActions: Bool
    @Environment(\.modelContext) private var modelContext
    @State private var showDelete = false
    @State private var showPaymentSheet = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showActions) {
                ActionListSheet(
                    icon: debt.debtType.icon,
                    iconTint: debt.debtType.color,
                    title: debt.name,
                    subtitle: CurrencyManager.shared.formatted(debt.currentBalance, currency: debt.currency),
                    items: [
                        ActionItem(icon: "banknote.fill", title: loc("debt.make_payment"), tint: AppTheme.accent) {
                            showPaymentSheet = true
                        },
                        ActionItem(icon: "pencil", title: loc("common.edit"), tint: AppTheme.blue) {
                            vm.loadForEdit(debt)
                        },
                        ActionItem(icon: "checkmark.seal.fill", title: loc("debt.mark_paid"),
                                   detail: loc("debt.action.mark_paid_sub"), tint: AppTheme.teal) {
                            markPaid()
                        },
                        // Migration path: a debt that is really a credit card
                        // becomes a proper card account (spendable + owed tracking).
                        ActionItem(icon: "creditcard.fill", title: loc("cc.convert_action"),
                                   detail: loc("cc.convert_action_sub"), tint: AppTheme.purple) {
                            convertToCreditCard()
                        },
                        ActionItem(icon: "trash.fill", title: loc("common.delete"), destructive: true) {
                            showDelete = true
                        },
                    ])
                .preferredColorScheme(appColorScheme())
            }
            .sheet(isPresented: $showPaymentSheet) {
                DebtPaymentSheet(debt: debt)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
            }
            .confirmSheet(isPresented: $showDelete,
                          title: String(format: loc("debt.delete_title"), debt.name),
                          message: loc("debt.delete_confirm"),
                          confirmLabel: loc("common.delete")) {
                modelContext.delete(debt); try? modelContext.save()
            }
    }

    private func markPaid() {
        debt.currentBalance = 0; debt.isActive = false
        debt.manuallyClosed = true   // keep it closed; don't let sync revive it
        try? modelContext.save()
        HapticManager.shared.success()
        // Marking it paid by hand is still paying it off — same moment, same
        // celebration. Only the credit-card conversion is excluded.
        ActionFeedbackCenter.shared.celebrateDebtPayoff(
            name: debt.name, total: debt.totalAmount, currency: debt.currency,
            since: debt.createdAt, monthlyFreed: debt.minimumPayment)
    }

    /// Convert this debt into a real credit-card account, then close the debt
    /// so the same money isn't tracked twice. Limit defaults to the original
    /// total (an editable best-guess); owed carries over from the balance.
    private func convertToCreditCard() {
        let existing = (try? modelContext.fetch(FetchDescriptor<BankCard>())) ?? []
        let g = BankIssuer.fallbackGradient(for: "5")
        let card = BankCard(
            holderName: debt.name, cardNumber: "", balance: 0, expireDate: "",
            gradientStart: g.start, gradientEnd: g.end,
            sortOrder: existing.count, currency: debt.currency.isEmpty ? CurrencyManager.shared.preferredCurrency : debt.currency)
        card.isCreditCard = true
        card.creditLimit = max(debt.totalAmount, debt.currentBalance)
        card.openingOwed = debt.currentBalance
        card.creditSince = Date()
        modelContext.insert(card)
        // Close the debt (don't delete — keeps history), so it's not double-
        // counted. Deliberately NO payoff celebration: the money hasn't been
        // repaid, it has moved to a credit card.
        debt.currentBalance = 0; debt.isActive = false; debt.manuallyClosed = true
        try? modelContext.save()
        HapticManager.shared.success()
    }
}

// MARK: - A credit card as a row

/// Name and what it owes, the limit and what is left of it, and a thin bar
/// of the limit used. Opens the card's own page: spending, paying the bill,
/// its history and instalments.
struct CreditCardPlainRow: View {
    let card: BankCard
    let installments: [CardInstallment]
    let onOpen: () -> Void

    /// Past this share of the limit the bar turns orange: where scoring models
    /// start reading utilisation as a risk.
    static let hotShare = 0.7

    static func title(_ card: BankCard) -> String {
        if !card.holderName.isEmpty { return card.holderName }
        let issuer = BankIssuer.find(card.issuerID.isEmpty ? nil : card.issuerID)
        return issuer?.name ?? loc("cc.default_name")
    }

    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: card.resolvedCurrency) }

    var body: some View {
        let util = card.utilisation(installments)
        Button { HapticManager.shared.tap(); onOpen() } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.title(card))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    if !card.last4.isEmpty {
                        Text(verbatim: "•••• \(card.last4)")
                            .font(.system(.caption2))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer(minLength: 6)
                    Text(money(card.totalOwed(installments)))
                        .font(.system(.subheadline, weight: .bold).monospacedDigit())
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                }
                if card.creditLimit > 0 {
                    Text(String(format: loc("cc.of_limit"), money(card.creditLimit),
                                money(card.availableCredit(installments))))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                if let note = CreditCardLiabilityRow.owedNote(card: card, installments: installments) {
                    Text(note)
                        .font(.system(.caption2))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if card.creditLimit > 0 {
                    DebtThinBar(progress: util, tint: util > Self.hotShare ? AppTheme.orange : AppTheme.textPrimary)
                        .padding(.top, 5)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A credit card's own page: what it owes and its limit, spending on it and
/// paying its bill, editing and deleting it, then its history and instalments.
/// These sat under each card on the Debts page and made it as long as the
/// cards' histories.
struct CreditCardDetailSheet: View {
    let card: BankCard
    let installments: [CardInstallment]
    let cards: [BankCard]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var paying = false
    @State private var loggingSpend = false
    @State private var deleting = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        CreditCardLiabilityRow(card: card,
                                               installments: installments,
                                               onEdit: { editing = true },
                                               onLogSpend: { loggingSpend = true },
                                               onPay: { paying = true },
                                               onDelete: { deleting = true })
                        CardHistorySection(card: card)
                        InstallmentSection(card: card, installments: installments, context: context)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(CreditCardPlainRow.title(card))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
        .sheet(isPresented: $editing) {
            CreditCardFormSheet(editCard: card)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $paying) {
            CreditCardPaymentSheet(creditCard: card, cards: cards, context: context)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $loggingSpend) {
            // Log a purchase on THIS card, locked to it: swiping to another
            // would log the purchase on the wrong account.
            AddTransactionSheet(vm: spendViewModel(), preselectedCardID: card.id,
                                lockToPreselectedCard: true)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .confirmSheet(isPresented: $deleting,
                      icon: "creditcard.fill",
                      title: loc("cc.delete_title"),
                      message: loc("cc.delete_msg"),
                      confirmLabel: loc("action.delete")) {
            // Close this page first: it reads the card, and a deleted model
            // read while the page is still on screen is a crash. Instalments
            // belong to the card; orphaning them would leave phantom
            // principal locking a limit that no longer exists.
            let doomed = card
            let theirs = installments.filter { $0.cardID == doomed.id }
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                for inst in theirs { context.delete(inst) }
                context.delete(doomed)
                try? context.save()
            }
        }
    }

    /// A light AppViewModel carrying the live card list into the add form.
    private func spendViewModel() -> AppViewModel {
        let vm = AppViewModel()
        vm.cards = cards
        return vm
    }
}

// MARK: - A tool as a row

/// One row for a tool that has its own page: an icon in its colour, what it
/// is, a line about it, and a chevron.
struct DebtLinkRow: View {
    let icon: String
    var tint: Color = AppTheme.textSecondary
    let title: String
    var detail: String? = nil
    let action: () -> Void

    var body: some View {
        Button { HapticManager.shared.tap(); action() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A tool's card on a page of its own, opened from its row.
struct DebtToolSheet<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    content
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.bg)
        .preferredColorScheme(appColorScheme())
    }
}
