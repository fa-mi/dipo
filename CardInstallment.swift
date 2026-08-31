import SwiftUI
import SwiftData

// MARK: - Credit Card Installments (Cicilan)
//
// How an Indonesian card installment actually behaves, which is the part that
// makes this need its own model rather than being "just a transaction":
//
//   1. You buy Rp 20jt and convert it to 12× cicilan.
//   2. The FULL Rp 20jt leaves your available limit immediately — not a
//      twelfth of it. This is the part people are surprised by: one purchase
//      can swallow most of a limit even though the monthly bill looks small.
//   3. Each month Rp 1.667jt appears on the statement.
//   4. Your limit comes back only as each instalment is paid off.
//
// So available credit = limit − (outstanding instalment principal + other
// charges). A plain transaction can't express that: it would either take the
// whole 20jt off the bill in month one, or take 1/12 off the limit, and both
// are wrong in ways that mislead in opposite directions.
//
// Fixed instalments (cicilan tetap) also do NOT shorten when you overpay —
// the bank keeps its schedule and charges a termination fee for early
// settlement. Extra money goes to the revolving balance instead. The simulator
// says so out loud, because "pay more, finish sooner" is the intuition
// everyone brings and it is wrong here.
@Model
final class CardInstallment {
    var id: UUID
    /// The credit card this sits on.
    var cardID: UUID
    var merchant: String
    /// Purchase price — the amount that leaves the limit on day one.
    var totalAmount: Double
    var tenorMonths: Int
    var startDate: Date
    /// Flat annual rate. Zero for a 0% promo, which is the common case and the
    /// default, so the maths degrades to a simple division.
    var flatRatePercent: Double
    var currency: String
    var isActive: Bool
    var createdAt: Date

    init(cardID: UUID, merchant: String, totalAmount: Double, tenorMonths: Int,
         startDate: Date = .now, flatRatePercent: Double = 0,
         currency: String = CurrencyManager.shared.preferredCurrency) {
        self.id = UUID()
        self.cardID = cardID
        self.merchant = merchant
        self.totalAmount = totalAmount
        self.tenorMonths = max(tenorMonths, 1)
        self.startDate = startDate
        self.flatRatePercent = flatRatePercent
        self.currency = currency
        self.isActive = true
        self.createdAt = .now
    }
}

// MARK: - Schedule math

extension CardInstallment {

    /// Interest across the whole tenor, flat on the original principal.
    var totalInterest: Double {
        totalAmount * (flatRatePercent / 100) * (Double(tenorMonths) / 12)
    }

    /// What lands on the statement each month.
    var monthlyAmount: Double {
        (totalAmount + totalInterest) / Double(tenorMonths)
    }

    /// Instalments already billed. Counts whole months since the start, capped
    /// at the tenor — an instalment can't be more than fully paid.
    func billedCount(asOf date: Date = .now) -> Int {
        let cal = Calendar.current
        let months = cal.dateComponents([.month], from: startDate, to: date).month ?? 0
        return min(max(months, 0), tenorMonths)
    }

    func remainingCount(asOf date: Date = .now) -> Int {
        tenorMonths - billedCount(asOf: date)
    }

    /// Principal still tied up — this is what the limit is short by. Note it
    /// tracks PRINCIPAL, not principal-plus-interest: the bank frees limit as
    /// the borrowed amount is repaid, not as interest accrues.
    func outstandingPrincipal(asOf date: Date = .now) -> Double {
        guard isActive else { return 0 }
        let paidPrincipal = totalAmount * Double(billedCount(asOf: date)) / Double(tenorMonths)
        return max(totalAmount - paidPrincipal, 0)
    }

    var isFinished: Bool { remainingCount() <= 0 }

    /// Month-by-month view used by the simulator.
    struct ScheduleRow: Identifiable {
        let id = UUID()
        let month: Int
        let date: Date
        let payment: Double
        let principalPortion: Double
        let interestPortion: Double
        let remainingPrincipal: Double
        /// Limit freed once this instalment is paid.
        let limitFreed: Double
    }

    func schedule() -> [ScheduleRow] {
        let cal = Calendar.current
        let principalPerMonth = totalAmount / Double(tenorMonths)
        let interestPerMonth = totalInterest / Double(tenorMonths)
        var rows: [ScheduleRow] = []
        for m in 1...tenorMonths {
            let date = cal.date(byAdding: .month, value: m - 1, to: startDate) ?? startDate
            let remaining = totalAmount - principalPerMonth * Double(m)
            rows.append(ScheduleRow(month: m, date: date,
                                    payment: monthlyAmount,
                                    principalPortion: principalPerMonth,
                                    interestPortion: interestPerMonth,
                                    remainingPrincipal: max(remaining, 0),
                                    limitFreed: principalPerMonth * Double(m)))
        }
        return rows
    }
}

// MARK: - Card-level aggregation

extension BankCard {

    private func myInstallments(_ all: [CardInstallment]) -> [CardInstallment] {
        all.filter { $0.cardID == id && $0.isActive && !$0.isFinished }
    }

    /// Principal locked up by running instalments, in the card's currency.
    func installmentPrincipal(_ all: [CardInstallment]) -> Double {
        let cm = CurrencyManager.shared
        return myInstallments(all).reduce(0.0) {
            $0 + cm.convert($1.outstandingPrincipal(), from: $1.currency, to: resolvedCurrency)
        }
    }

    /// This month's instalment charges — the part of the bill that is fixed
    /// before you spend anything else.
    func installmentMonthlyCharge(_ all: [CardInstallment]) -> Double {
        let cm = CurrencyManager.shared
        return myInstallments(all).reduce(0.0) {
            $0 + cm.convert($1.monthlyAmount, from: $1.currency, to: resolvedCurrency)
        }
    }

    /// Total owed including instalment principal. `owedBalance()` alone only
    /// sees logged transactions, so a card carrying a 12-month instalment would
    /// otherwise report far less owed than the bank does.
    func totalOwed(_ installments: [CardInstallment]) -> Double {
        owedBalance() + installmentPrincipal(installments)
    }

    /// What you can actually still spend.
    func availableCredit(_ installments: [CardInstallment]) -> Double {
        max(creditLimit - totalOwed(installments), 0)
    }

    /// Share of the limit already used, 0…1. Above ~0.7 is the point most
    /// scoring models start treating utilisation as a risk signal.
    func utilisation(_ installments: [CardInstallment]) -> Double {
        guard creditLimit > 0 else { return 0 }
        return min(totalOwed(installments) / creditLimit, 1)
    }
}

// MARK: - Overpayment

enum InstallmentAdvice {
    /// What actually happens when someone pays more than the statement.
    ///
    /// Fixed instalments don't shorten — that is the whole point of the
    /// product from the bank's side. Extra money clears the revolving balance
    /// first (which is where the expensive interest lives, typically ~26%/yr),
    /// and only an explicit early-settlement request touches the instalment,
    /// usually with a termination fee.
    struct Extra {
        let statement: Double
        let paying: Double
        var surplus: Double { max(paying - statement, 0) }
        let revolvingBalance: Double
        /// Surplus that usefully clears revolving debt.
        var clearsRevolving: Double { min(surplus, revolvingBalance) }
        /// Surplus beyond that — sits as a credit balance, earning nothing.
        var idleCredit: Double { max(surplus - revolvingBalance, 0) }
        /// Interest avoided over a year by clearing revolving debt early.
        func interestAvoided(annualRatePercent: Double = 26) -> Double {
            clearsRevolving * (annualRatePercent / 100)
        }
    }
}

// MARK: - Installment section (lives inside the credit card area)

struct InstallmentSection: View {
    let card: BankCard
    let installments: [CardInstallment]
    let context: ModelContext
    @State private var showAdd = false
    @State private var simulating: CardInstallment? = nil

    private var mine: [CardInstallment] {
        installments.filter { $0.cardID == card.id && $0.isActive }
            .sorted { $0.startDate > $1.startDate }
    }
    private var running: [CardInstallment] { mine.filter { !$0.isFinished } }

    private var cm: CurrencyManager { CurrencyManager.shared }
    private func money(_ v: Double) -> String { cm.formatted(v, currency: card.resolvedCurrency) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(loc("inst.section"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Button {
                    HapticManager.shared.tap(); showAdd = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text(loc("inst.add")).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
            }

            if running.isEmpty {
                Text(loc("inst.empty"))
                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
            } else {
                // The number people misjudge: this month's fixed charge before
                // a single new purchase.
                HStack {
                    Text(loc("inst.monthly_total"))
                        .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Text(money(card.installmentMonthlyCharge(installments)))
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(AppTheme.orange)
                }
                ForEach(running) { inst in
                    row(inst)
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            InstallmentFormSheet(card: card, context: context)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .sheet(item: $simulating) { inst in
            InstallmentSimulatorSheet(installment: inst, card: card, installments: installments)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
    }

    private func row(_ inst: CardInstallment) -> some View {
        let billed = inst.billedCount()
        let progress = Double(billed) / Double(inst.tenorMonths)
        return Button {
            HapticManager.shared.tap(); simulating = inst
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(inst.merchant)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                    Spacer()
                    Text(cm.formatted(inst.monthlyAmount, currency: inst.currency) + loc("inst.per_month"))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.cardMid).frame(height: 4)
                        Capsule().fill(AppTheme.accent)
                            .frame(width: geo.size.width * progress, height: 4)
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(String(format: loc("inst.progress"), billed, inst.tenorMonths))
                        .font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Text(String(format: loc("inst.locked"),
                                cm.formatted(inst.outstandingPrincipal(), currency: inst.currency)))
                        .font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(11)
            .background(AppTheme.cardMid.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                context.delete(inst); try? context.save()
            } label: { Label(loc("action.delete"), systemImage: "trash") }
        }
    }
}

// MARK: - Add form

struct InstallmentFormSheet: View {
    let card: BankCard
    let context: ModelContext
    @Environment(\.dismiss) private var dismiss

    @State private var merchant = ""
    @State private var amount = ""
    @State private var tenor = 12
    @State private var rate = "0"
    @State private var start = Date()

    private let tenors = [3, 6, 9, 12, 18, 24, 36]

    private var preview: CardInstallment? {
        guard let a = Double(amount), a > 0 else { return nil }
        return CardInstallment(cardID: card.id, merchant: merchant, totalAmount: a,
                               tenorMonths: tenor, startDate: start,
                               flatRatePercent: Double(rate) ?? 0,
                               currency: card.resolvedCurrency)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        SheetField(label: loc("inst.merchant"),
                                   placeholder: loc("inst.merchant_ph"), text: $merchant)
                        SheetField(label: loc("inst.amount"), placeholder: "0",
                                   text: $amount, keyboard: .decimalPad)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(loc("inst.tenor")).font(.system(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(tenors, id: \.self) { t in
                                        Button {
                                            HapticManager.shared.tap(); tenor = t
                                        } label: {
                                            Text("\(t)×")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(tenor == t ? .white : AppTheme.textSecondary)
                                                .padding(.horizontal, 14).padding(.vertical, 9)
                                                .background(tenor == t ? AppTheme.accent : AppTheme.cardDark,
                                                            in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 22)

                        SheetField(label: loc("inst.rate"), placeholder: "0",
                                   text: $rate, keyboard: .decimalPad)

                        if let preview {
                            summary(preview)
                        }

                        Button { save() } label: {
                            Text(loc("action.save")).font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(preview == nil ? AppTheme.cardMid : AppTheme.accent,
                                            in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .disabled(preview == nil)
                        .padding(.horizontal, 22)
                        Spacer(minLength: 30)
                    }
                    .padding(.top, 14)
                }
            }
            .navigationTitle(loc("inst.add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
    }

    /// Shows the limit hit up front. Someone converting a purchase to
    /// instalments is usually looking at the small monthly figure; the number
    /// that changes what they can do next is the whole amount leaving the limit.
    private func summary(_ i: CardInstallment) -> some View {
        let cm = CurrencyManager.shared
        let cur = card.resolvedCurrency
        return VStack(spacing: 8) {
            row(loc("inst.monthly"), cm.formatted(i.monthlyAmount, currency: cur), bold: true)
            if i.totalInterest > 0 {
                row(loc("inst.total_interest"), cm.formatted(i.totalInterest, currency: cur))
                row(loc("inst.total_paid"), cm.formatted(i.totalAmount + i.totalInterest, currency: cur))
            }
            Divider().overlay(AppTheme.cardMid)
            row(loc("inst.limit_hit"), "− " + cm.formatted(i.totalAmount, currency: cur),
                tint: AppTheme.orange)
            row(loc("inst.limit_after"),
                cm.formatted(max(card.creditLimit - card.owedBalance() - i.totalAmount, 0), currency: cur))
            Text(loc("inst.limit_note"))
                .font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 22)
    }

    private func row(_ l: String, _ v: String, bold: Bool = false, tint: Color = AppTheme.textPrimary) -> some View {
        HStack {
            Text(l).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(v).font(.system(size: bold ? 14 : 11, weight: bold ? .bold : .semibold))
                .foregroundStyle(tint)
        }
    }

    private func save() {
        guard let a = Double(amount), a > 0 else { return }
        let name = merchant.trimmingCharacters(in: .whitespaces)
        let inst = CardInstallment(cardID: card.id,
                                   merchant: name.isEmpty ? loc("inst.untitled") : name,
                                   totalAmount: a, tenorMonths: tenor, startDate: start,
                                   flatRatePercent: Double(rate) ?? 0,
                                   currency: card.resolvedCurrency)
        context.insert(inst)
        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}

// MARK: - Simulator
//
// The teaching surface. Two things people get wrong about card instalments,
// both shown here as numbers rather than as advice:
//   • how much limit is actually gone (not a twelfth — all of it)
//   • what paying more than the statement does (not a shorter tenor)
struct InstallmentSimulatorSheet: View {
    let installment: CardInstallment
    let card: BankCard
    let installments: [CardInstallment]
    @Environment(\.dismiss) private var dismiss

    @State private var payingText = ""

    private var cm: CurrencyManager { CurrencyManager.shared }
    private var cur: String { installment.currency }
    private func money(_ v: Double) -> String { cm.formatted(v, currency: cur) }

    /// Charges on the card that are NOT part of an instalment — the revolving
    /// balance, where the expensive interest actually lives.
    private var revolving: Double { max(card.owedBalance(), 0) }
    private var statement: Double {
        card.installmentMonthlyCharge(installments) + revolving
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        limitCard
                        scheduleCard
                        overpayCard
                        Spacer(minLength: 30)
                    }
                    .padding(.top, 14)
                }
            }
            .navigationTitle(installment.merchant)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
    }

    private var limitCard: some View {
        let locked = installment.outstandingPrincipal()
        let util = card.utilisation(installments)
        return VStack(alignment: .leading, spacing: 10) {
            Text(loc("inst.sim_limit")).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.0f%%", util * 100))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(util > 0.7 ? AppTheme.red : AppTheme.accent)
                Text(loc("inst.of_limit")).font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.cardMid).frame(height: 8)
                    Capsule().fill(util > 0.7 ? AppTheme.red : AppTheme.accent)
                        .frame(width: geo.size.width * util, height: 8)
                }
            }
            .frame(height: 8)
            row(loc("inst.locked_by_this"), money(locked), tint: AppTheme.orange)
            row(loc("inst.available_now"),
                cm.formatted(card.availableCredit(installments), currency: card.resolvedCurrency))
            if util > 0.7 {
                Text(loc("inst.util_warning"))
                    .font(.system(size: 10)).foregroundStyle(AppTheme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 22)
    }

    private var scheduleCard: some View {
        let rows = installment.schedule()
        let billed = installment.billedCount()
        let df = DateFormatter()
        df.locale = LanguageManager.shared.currentLocale
        df.dateFormat = DateFormatter.dateFormat(fromTemplate: "MMM yy", options: 0,
                                                 locale: LanguageManager.shared.currentLocale)
        return VStack(alignment: .leading, spacing: 10) {
            Text(loc("inst.sim_schedule")).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            HStack {
                Text(loc("inst.col_month")).frame(width: 54, alignment: .leading)
                Text(loc("inst.col_pay")).frame(maxWidth: .infinity, alignment: .trailing)
                Text(loc("inst.col_left")).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
            ForEach(rows) { r in
                let done = r.month <= billed
                HStack {
                    Text(df.string(from: r.date))
                        .frame(width: 54, alignment: .leading)
                        .foregroundStyle(done ? AppTheme.textSecondary : AppTheme.textPrimary)
                    Text(money(r.payment))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .foregroundStyle(done ? AppTheme.textSecondary : AppTheme.textPrimary)
                    Text(money(r.remainingPrincipal))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .font(.system(size: 11, weight: done ? .regular : .medium))
                .strikethrough(done, color: AppTheme.textSecondary.opacity(0.5))
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 22)
    }

    private var overpayCard: some View {
        let paying = Double(payingText) ?? 0
        let extra = InstallmentAdvice.Extra(statement: statement, paying: paying,
                                            revolvingBalance: revolving)
        return VStack(alignment: .leading, spacing: 10) {
            Text(loc("inst.sim_overpay")).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            row(loc("inst.statement_this_month"), money(statement), bold: true)
            TextField(loc("inst.if_i_pay"), text: $payingText)
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                .keyboardType(.decimalPad).multilineTextAlignment(.center)
                .padding(.vertical, 11)
                .background(AppTheme.cardMid.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))

            if paying > statement {
                row(loc("inst.surplus"), money(extra.surplus))
                if extra.clearsRevolving > 0 {
                    row(loc("inst.clears_revolving"), money(extra.clearsRevolving),
                        tint: AppTheme.accent)
                    row(loc("inst.interest_avoided"),
                        money(extra.interestAvoided()), tint: AppTheme.accent)
                }
                if extra.idleCredit > 0 {
                    row(loc("inst.idle_credit"), money(extra.idleCredit), tint: AppTheme.orange)
                }
                // The lesson, stated plainly.
                Text(loc("inst.overpay_truth"))
                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            } else {
                Text(loc("inst.overpay_prompt"))
                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 22)
    }

    private func row(_ l: String, _ v: String, bold: Bool = false,
                     tint: Color = AppTheme.textPrimary) -> some View {
        HStack {
            Text(l).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(v).font(.system(size: bold ? 14 : 12, weight: bold ? .bold : .semibold))
                .foregroundStyle(tint)
        }
    }
}
