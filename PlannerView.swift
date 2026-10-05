import SwiftUI
import SwiftData

// MARK: - Planner
//
// Four calculators for the decisions Indonesians actually run the numbers on.
// All of them are ESTIMATES and say so on screen: the statutory rates below are
// set by regulation and change, so every result shows its full breakdown rather
// than a single number the user would have to take on faith.
//
// Deliberately localised rather than copied: a "car loan / house loan" pair is
// only useful here if the car one uses *bunga flat* (how Indonesian multifinance
// actually quotes hire purchase) and the house one uses *anuitas* (how banks
// quote KPR). Using the same reducing-balance formula for both — the obvious
// shortcut — would understate a car loan's real cost substantially.

// MARK: - Math

enum PlannerMath {

    /// Annuity / reducing-balance instalment — the KPR standard. Interest is
    /// charged on the remaining principal, so it falls every month.
    static func annuityInstalment(principal: Double, annualRatePercent: Double, years: Double) -> Double {
        let n = max(years * 12, 1)
        let r = annualRatePercent / 100 / 12
        guard r > 0 else { return principal / n }
        let factor = pow(1 + r, n)
        return principal * r * factor / (factor - 1)
    }

    /// Flat-rate instalment — how kredit kendaraan is quoted. Interest is
    /// computed once on the ORIGINAL principal for the whole term and never
    /// reduces, which is why a "6% flat" loan costs far more than "6% anuitas".
    static func flatInstalment(principal: Double, annualRatePercent: Double, years: Double) -> (monthly: Double, totalInterest: Double) {
        let n = max(years * 12, 1)
        let interest = principal * (annualRatePercent / 100) * years
        return ((principal + interest) / n, interest)
    }

    /// The comparison that matters: what reducing-balance rate would cost the
    /// same as a given flat rate. Roughly double, and seeing it stops a flat
    /// quote from looking cheaper than it is. Solved by bisection because the
    /// annuity formula can't be inverted for the rate in closed form.
    static func flatRateEquivalentAnnual(principal: Double, flatRatePercent: Double, years: Double) -> Double {
        let target = flatInstalment(principal: principal, annualRatePercent: flatRatePercent, years: years).monthly
        var lo = 0.0, hi = 200.0
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            let payment = annuityInstalment(principal: principal, annualRatePercent: mid, years: years)
            if payment < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Future value of a monthly contribution plus an opening balance.
    static func futureValue(monthly: Double, annualRatePercent: Double, years: Double, opening: Double = 0) -> Double {
        let n = max(years * 12, 0)
        let r = annualRatePercent / 100 / 12
        guard r > 0 else { return opening + monthly * n }
        let growth = pow(1 + r, n)
        return opening * growth + monthly * (growth - 1) / r
    }

    // MARK: - Take-home pay
    //
    // ⚠️ Statutory figures, current as written and subject to change by
    // regulation. They are named constants precisely so they are easy to find
    // and correct — and the UI prints every component so a stale rate is
    // visible rather than buried in a single wrong total.

    /// PTKP — annual untaxed allowance, by marital status and dependants.
    static func ptkp(married: Bool, dependants: Int) -> Double {
        let base = 54_000_000.0
        let spouse = married ? 4_500_000.0 : 0
        let children = Double(min(dependants, 3)) * 4_500_000
        return base + spouse + children
    }

    /// Progressive PPh21 brackets (UU HPP).
    private static let brackets: [(upTo: Double, rate: Double)] = [
        (60_000_000,    0.05),
        (250_000_000,   0.15),
        (500_000_000,   0.25),
        (5_000_000_000, 0.30),
        (.infinity,     0.35),
    ]

    static func annualIncomeTax(taxableIncome: Double) -> Double {
        guard taxableIncome > 0 else { return 0 }
        var remaining = taxableIncome
        var previousCap = 0.0
        var tax = 0.0
        for b in brackets {
            let slice = min(remaining, b.upTo - previousCap)
            guard slice > 0 else { break }
            tax += slice * b.rate
            remaining -= slice
            previousCap = b.upTo
            if remaining <= 0 { break }
        }
        return tax
    }

    struct TakeHome {
        let gross: Double
        let jht: Double            // BPJS Ketenagakerjaan — Jaminan Hari Tua, 2% employee
        let jp: Double             // Jaminan Pensiun, 1% employee, salary-capped
        let health: Double         // BPJS Kesehatan, 1% employee, salary-capped
        let occupationalCost: Double  // Biaya jabatan, 5% capped at 500k/month
        let taxableAnnual: Double
        let taxMonthly: Double
        let net: Double
    }

    /// Employee-side deductions only. The employer pays more on top; this
    /// answers "what lands in my account", not total employment cost.
    static func takeHomePay(monthlyGross: Double, married: Bool, dependants: Int) -> TakeHome {
        let jpCeiling     = 10_547_400.0   // JP contribution ceiling
        let healthCeiling = 12_000_000.0   // BPJS Kesehatan ceiling

        let jht    = monthlyGross * 0.02
        let jp     = min(monthlyGross, jpCeiling) * 0.01
        let health = min(monthlyGross, healthCeiling) * 0.01

        // Biaya jabatan: 5% of gross, capped at Rp 500.000 per month.
        let occupational = min(monthlyGross * 0.05, 500_000)

        // JHT and JP are deductible from taxable income; BPJS Kesehatan is not.
        let annualNetForTax = (monthlyGross - occupational - jht - jp) * 12
        let taxable = max(annualNetForTax - ptkp(married: married, dependants: dependants), 0)
        let taxMonthly = annualIncomeTax(taxableIncome: taxable) / 12

        let net = monthlyGross - jht - jp - health - taxMonthly
        return TakeHome(gross: monthlyGross, jht: jht, jp: jp, health: health,
                        occupationalCost: occupational, taxableAnnual: taxable,
                        taxMonthly: taxMonthly, net: net)
    }
}

// MARK: - View

struct PlannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var active: Tool? = nil
    /// Shown as a segment inside ObligationsView rather than as its own sheet.
    var embedded: Bool = false
    /// The user's real obligation load, so every calculator can answer "what
    /// would this do to MY ratio" instead of returning an abstract instalment.
    var load: ObligationLoad? = nil
    /// Which calculators to show. Splitting these by subject is the point:
    /// KPR and vehicle credit belong with debt because they CREATE debt, while
    /// take-home pay and pension growth are income questions and belong with
    /// budgeting. Together in one place they made users hunt for a salary
    /// calculator inside a screen about what they owe.
    var tools: [Tool] = Tool.allCases

    enum Tool: String, Identifiable, CaseIterable {
        case kpr, vehicle, takeHome, jht
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .kpr:      return "house.fill"
            case .vehicle:  return "car.fill"
            case .takeHome: return "banknote.fill"
            case .jht:      return "chart.line.uptrend.xyaxis"
            }
        }
        var titleKey: String {
            switch self {
            case .kpr:      return "planner.kpr"
            case .vehicle:  return "planner.vehicle"
            case .takeHome: return "planner.takehome"
            case .jht:      return "planner.jht"
            }
        }
        var subtitleKey: String {
            switch self {
            case .kpr:      return "planner.kpr_sub"
            case .vehicle:  return "planner.vehicle_sub"
            case .takeHome: return "planner.takehome_sub"
            case .jht:      return "planner.jht_sub"
            }
        }
        var tint: Color {
            switch self {
            case .kpr:      return AppTheme.blue
            case .vehicle:  return AppTheme.orange
            case .takeHome: return AppTheme.accent
            case .jht:      return AppTheme.teal
            }
        }
    }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        // Grouped so the counter attaches to the screen rather than to one
        // branch: a ViewBuilder if/else is not itself a view you can modify.
        Group {
            if embedded {
                content
            } else {
                NavigationStack {
                    content
                        .navigationTitle(loc("planner.nav"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(AppTheme.bg, for: .navigationBar)
                        .doneToolbar { dismiss() }
                }
            }
        }
        .trackScreen(.planner)
    }

    private var content: some View {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        Text(loc(tools.contains(.takeHome) ? "planner.intro_income" : "planner.intro"))
                            .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)

                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(tools) { tool in
                                Button {
                                    HapticManager.shared.tap(); active = tool
                                } label: { card(tool) }
                                .buttonStyle(ScaleButtonStyle())
                            }
                        }
                        .padding(.horizontal, 22)

                        Text(loc(tools.contains(.takeHome) ? "planner.disclaimer_income" : "planner.disclaimer"))
                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 22).padding(.top, 4)
                        Spacer(minLength: 30)
                    }
                    .padding(.top, 14)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .sheet(item: $active) { tool in
                CalculatorSheet(tool: tool, load: load)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
            }
    }

    private func card(_ tool: Tool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: tool.icon)
                .font(.system(.title2)).foregroundStyle(tool.tint)
                .frame(height: 34)
            // Centred like the icon above it. English titles run longer than
            // Indonesian ones and wrap; a wrapped title fell back to leading
            // alignment inside a centred card.
            Text(loc(tool.titleKey))
                .font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(loc(tool.subtitleKey))
                .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        // Both cards in a row take the taller one's height, so a title that
        // wraps in one language no longer leaves its neighbour shorter.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 20).padding(.horizontal, 12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }
}

// MARK: - Calculator Sheet

struct CalculatorSheet: View {
    let tool: PlannerView.Tool
    /// Present obligations, so a new instalment can be shown as a change to the
    /// user's own ratio rather than a number floating on its own.
    var load: ObligationLoad? = nil
    @Environment(\.dismiss) private var dismiss

    // What the user typed, remembered between visits. Empty means "not given
    // yet": the field then shows the example in grey and the result uses it,
    // so nothing reads as the user's own figure unless they typed it or DiPo
    // filled it from their records.
    @AppStorage("planner.in.principal")  private var principal  = ""
    @AppStorage("planner.in.rate")       private var ratePct    = ""
    @AppStorage("planner.in.years")      private var years      = ""
    @AppStorage("planner.in.gross")      private var grossPay   = ""
    @AppStorage("planner.in.married")    private var married    = false
    @AppStorage("planner.in.dependants") private var dependants = 0
    @AppStorage("planner.in.jhtMonthly") private var jhtMonthly = ""
    @AppStorage("planner.in.jhtOpening") private var jhtOpening = ""
    @AppStorage("planner.in.jhtRate")    private var jhtRate    = ""
    @AppStorage("planner.in.jhtYears")   private var jhtYears   = ""
    @Query private var salaries: [SalarySchedule]
    @Query private var holdings: [InvestmentHolding]
    @Query private var cards: [BankCard]
    @Query private var debts: [DebtRecord]
    @Query private var goals: [SavingsGoal]
    /// Fields DiPo filled from the user's records this visit, to say so.
    @State private var filledFromRecords: Set<String> = []

    /// Examples shown in grey until the user gives their own figure.
    enum Example {
        static let principal = "500000000", rate = "10", years = "15", gross = "10000000"
        static let jhtMonthly = "570000", jhtOpening = "0", jhtRate = "5.5", jhtYears = "25"
    }
    /// JHT is 5.7% of wages: 2% from the worker, 3.7% from the employer.
    static let jhtShareOfWage = 0.057

    /// The typed figure, or the example while the field is empty.
    private func num(_ text: String, _ example: String) -> Double {
        Double(text.trimmingCharacters(in: .whitespaces)) ?? Double(example) ?? 0
    }

    /// Fills what DiPo already knows, once, and only into empty fields — a
    /// figure the user typed is never overwritten.
    private func prefillFromRecords() {
        let salary = salaries.filter(\.isActive)
            .reduce(0.0) { $0 + cm.convert($1.amount, from: $1.currency, to: pref) }
        if jhtMonthly.isEmpty, salary > 0 {
            jhtMonthly = String(Int((salary * Self.jhtShareOfWage).rounded()))
            filledFromRecords.insert("jhtMonthly")
        }
        let pension = holdings.filter { $0.type == .pension }
            .reduce(0.0) { $0 + cm.convert($1.stats().marketValue, from: $1.currency, to: pref) }
        if jhtOpening.isEmpty, pension > 0 {
            jhtOpening = String(Int(pension.rounded()))
            filledFromRecords.insert("jhtOpening")
        }
    }

    private var cm: CurrencyManager { CurrencyManager.shared }
    private var pref: String { cm.preferredCurrency }
    private func money(_ v: Double) -> String { cm.formatted(v, currency: pref) }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        switch tool {
                        case .kpr:      loanInputs; kprResult
                        case .vehicle:  loanInputs; vehicleResult
                        case .takeHome: takeHomeInputs; takeHomeResult
                        case .jht:      jhtInputs; jhtResult
                        }
                        Spacer(minLength: 30)
                    }
                    .padding(.top, 14)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc(tool.titleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
            .onAppear(perform: prefillFromRecords)
        }
    }

    // MARK: Inputs

    private func numberField(_ labelKey: String, _ binding: Binding<String>, suffix: String? = nil,
                             example: String = "0", note: String? = nil) -> some View {
        VStack(spacing: 6) {
            Text(loc(labelKey)).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                TextField(example, text: binding)
                    .font(.system(.body, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    .keyboardType(.decimalPad)
                if let suffix {
                    Text(suffix).font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.sm))
            if let note {
                Text(note).font(.system(.caption2)).foregroundStyle(AppTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 22)
    }

    /// Said once under the inputs while any field still shows its example.
    @ViewBuilder
    private func exampleHint(_ fields: [String]) -> some View {
        if fields.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            Text(loc("planner.example_hint"))
                .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 22)
        }
    }

    private var loanInputs: some View {
        VStack(spacing: 14) {
            numberField("planner.principal", $principal, suffix: pref, example: Example.principal)
            numberField(tool == .vehicle ? "planner.rate_flat" : "planner.rate_annual", $ratePct, suffix: "%",
                        example: Example.rate)
            numberField("planner.term", $years, suffix: loc("planner.years"), example: Example.years)
            exampleHint([principal, ratePct, years])
        }
    }

    private var takeHomeInputs: some View {
        VStack(spacing: 14) {
            numberField("planner.gross", $grossPay, suffix: pref, example: Example.gross)
            exampleHint([grossPay])
            VStack(spacing: 10) {
                Toggle(isOn: $married) {
                    Text(loc("planner.married")).font(.system(.subheadline)).foregroundStyle(AppTheme.textPrimary)
                }
                .tint(AppTheme.accent)
                HStack {
                    Text(loc("planner.dependants")).font(.system(.subheadline))
                        .foregroundStyle(AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 10)
                    // Vertical only. A bare fixedSize here would refuse to
                    // compress against the longer Indonesian label and push the
                    // row past the screen edge.
                    Stepper("\(dependants)", value: $dependants, in: 0...3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(loc("planner.dependants_hint"))
                    .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22)
        }
    }

    private var jhtInputs: some View {
        VStack(spacing: 14) {
            numberField("planner.jht_monthly", $jhtMonthly, suffix: pref, example: Example.jhtMonthly,
                        note: filledFromRecords.contains("jhtMonthly") ? loc("planner.filled_jht_monthly") : nil)
            numberField("planner.jht_opening", $jhtOpening, suffix: pref, example: Example.jhtOpening,
                        note: filledFromRecords.contains("jhtOpening") ? loc("planner.filled_jht_opening") : nil)
            numberField("planner.jht_rate", $jhtRate, suffix: "%", example: Example.jhtRate)
            numberField("planner.jht_years", $jhtYears, suffix: loc("planner.years"), example: Example.jhtYears)
            exampleHint([jhtMonthly, jhtOpening, jhtRate, jhtYears])
        }
    }

    // MARK: Results

    private func resultCard(_ headlineKey: String, _ headline: String,
                            rows: [(String, String)], accent: Color) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(loc(headlineKey)).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                Text(headline).font(.system(.title, weight: .bold)).foregroundStyle(accent)
            }
            Divider().overlay(AppTheme.cardMid)
            VStack(spacing: 9) {
                ForEach(rows, id: \.0) { row in
                    // The label wraps and the figure never does: English labels
                    // now spell out what the Indonesian acronyms stand for.
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.0).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(row.1).font(.system(.caption, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .padding(.horizontal, 22)
    }

    private var p: Double { num(principal, Example.principal) }
    private var r: Double { num(ratePct, Example.rate) }
    private var y: Double { max(num(years, Example.years), 1) }

    private var kprResult: some View {
        let monthly = PlannerMath.annuityInstalment(principal: p, annualRatePercent: r, years: y)
        let total = monthly * y * 12
        return VStack(spacing: 12) {
            resultCard("planner.monthly_instalment", money(monthly), rows: [
                (loc("planner.total_paid"), money(total)),
                (loc("planner.total_interest"), money(max(total - p, 0))),
                (loc("planner.method"), loc("planner.method_annuity")),
            ], accent: AppTheme.blue)
            impactCard(instalment: monthly)
            affordabilityCard(.annuity)
        }
    }

    /// What this instalment would do to the user's real obligation ratio. An
    /// instalment figure alone is unanswerable — "can I afford it" only has
    /// meaning against income and what is already committed.
    @ViewBuilder
    private func impactCard(instalment: Double) -> some View {
        if let load, load.monthlyIncome > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text(loc("planner.impact_title"))
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 22)
                ObligationLoadCard(load: load, projected: load.adding(instalment: instalment))
                    .padding(.horizontal, 22)
            }
        }
    }

    // MARK: Affordability

    /// Cash and liquid holdings beyond the emergency fund — what a down
    /// payment can come from without leaving the household exposed.
    private var spareCash: (spare: Double, emergency: Double) {
        let inputs = LadderInputs.gather(cards: cards, debts: debts, holdings: holdings,
                                         goals: goals, salaries: salaries, currency: pref)
        let ladder = FinancialLadder.evaluate(inputs)
        let buffer = max(inputs.cash, 0) + max(inputs.liquidHoldings, 0)
        return (buffer - ladder.emergencyTarget, ladder.emergencyTarget)
    }

    /// Worked backwards from the user's records: the house or vehicle price
    /// their income and savings carry at the rate and term typed above.
    @ViewBuilder
    private func affordabilityCard(_ method: LoanAffordability.Method) -> some View {
        if let load, load.monthlyIncome > 0 {
            let isHouse = method == .annuity
            let minDown = isHouse ? LoanAffordability.houseMinDown : LoanAffordability.vehicleMinDown
            let cash = spareCash
            let a = LoanAffordability.evaluate(income: load.monthlyIncome, debtPayments: load.debtPayments,
                                               fixedBills: load.commitments, spareCash: cash.spare,
                                               annualRatePercent: r, years: y, method: method,
                                               minDownShare: minDown)
            let pct = { (v: Double) in String(format: "%.0f%%", v * 100) }
            let ceiling = pct(a.lenderRuleBinds ? LoanAffordability.lenderCeiling : ObligationLoad.healthyCeiling)
            VStack(alignment: .leading, spacing: 8) {
                Text(loc("afford.title"))
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 22)
                VStack(alignment: .leading, spacing: 12) {
                    if a.limit == .noRoom {
                        Text(loc("afford.no_room_title"))
                            .font(.system(.headline)).foregroundStyle(AppTheme.red)
                        Text(a.lenderRuleBinds
                             ? String(format: loc("afford.no_room_lender"), pct(load.debtPayments / load.monthlyIncome),
                                      ceiling, money(a.overBy))
                             : String(format: loc("afford.no_room_load"), pct(load.ratio), ceiling,
                                      money(a.overBy)))
                            .font(.system(.caption)).foregroundStyle(AppTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(loc(isHouse ? "afford.max_price_house" : "afford.max_price_vehicle"))
                                .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                            Text(a.maxPrice > 0 ? "≈ " + money(a.maxPrice) : money(0))
                                .font(.system(.title2, weight: .bold)).foregroundStyle(AppTheme.accent)
                        }
                        Divider().overlay(AppTheme.cardMid)
                        VStack(spacing: 7) {
                            affordRow(loc("afford.row_instalment"), money(a.maxInstalment))
                            affordRow(String(format: loc("afford.row_loan"), String(format: "%g", r),
                                             String(format: "%g", y)), money(a.maxLoan))
                            affordRow(String(format: loc("afford.row_down"), pct(minDown)),
                                      money(max(a.maxPrice - a.maxLoan, 0)))
                        }
                        Text(a.limit == .downPayment
                             ? String(format: loc("afford.limit_down"), money(a.downPaymentCash),
                                      money(a.downPaymentShortfall), money(a.priceIfSaved))
                             : String(format: loc("afford.limit_income"), money(a.maxInstalment), ceiling))
                            .font(.system(.caption)).foregroundStyle(AppTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if p > a.maxLoan + 1 {
                            Text(String(format: loc("afford.typed_over"), money(p), money(p - a.maxLoan)))
                                .font(.system(.caption, weight: .semibold)).foregroundStyle(AppTheme.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(String(format: loc("afford.typed_ok"), money(p)))
                                .font(.system(.caption, weight: .semibold)).foregroundStyle(AppTheme.accent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(String(format: loc(isHouse ? "afford.note_house" : "afford.note_vehicle"),
                                money(max(cash.emergency, 0))))
                        .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                .padding(.horizontal, 22)
            }
        }
    }

    private func affordRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(value).font(.system(.caption, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                .fixedSize()
        }
    }

    private var vehicleResult: some View {
        let flat = PlannerMath.flatInstalment(principal: p, annualRatePercent: r, years: y)
        let equivalent = PlannerMath.flatRateEquivalentAnnual(principal: p, flatRatePercent: r, years: y)
        return VStack(spacing: 12) {
            resultCard("planner.monthly_instalment", money(flat.monthly), rows: [
                (loc("planner.total_paid"), money(p + flat.totalInterest)),
                (loc("planner.total_interest"), money(flat.totalInterest)),
                (loc("planner.method"), loc("planner.method_flat")),
            ], accent: AppTheme.orange)
            impactCard(instalment: flat.monthly)
            affordabilityCard(.flat)

            // The single most useful number here. A flat quote looks cheap next
            // to a KPR rate until it's restated on the same basis.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill").font(.system(.caption))
                    .foregroundStyle(AppTheme.orange)
                Text(String(format: loc("planner.flat_equivalent"),
                            String(format: "%.1f", r), String(format: "%.1f", equivalent)))
                    .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(AppTheme.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: AppRadius.sm))
            .padding(.horizontal, 22)
        }
    }

    private var takeHomeResult: some View {
        let g = num(grossPay, Example.gross)
        let t = PlannerMath.takeHomePay(monthlyGross: g, married: married, dependants: dependants)
        return resultCard("planner.net_monthly", money(t.net), rows: [
            (loc("planner.gross"), money(t.gross)),
            // These were hardcoded Indonesian acronyms, so English showed
            // "BPJS JP (1%)" and "PPh 21" with nothing saying what they are.
            (loc("planner.row_jht"), "− " + money(t.jht)),
            (loc("planner.row_jp"), "− " + money(t.jp)),
            (loc("planner.health"), "− " + money(t.health)),
            (loc("planner.row_tax"), "− " + money(t.taxMonthly)),
            (loc("planner.ptkp"), money(PlannerMath.ptkp(married: married, dependants: dependants))),
            (loc("planner.taxable_annual"), money(t.taxableAnnual)),
        ], accent: AppTheme.accent)
    }

    private var jhtResult: some View {
        let m = num(jhtMonthly, Example.jhtMonthly)
        let o = num(jhtOpening, Example.jhtOpening)
        let rate = num(jhtRate, Example.jhtRate)
        let yrs = num(jhtYears, Example.jhtYears)
        let fv = PlannerMath.futureValue(monthly: m, annualRatePercent: rate, years: yrs, opening: o)
        let contributed = o + m * yrs * 12
        return resultCard("planner.projected_value", money(fv), rows: [
            (loc("planner.total_contributed"), money(contributed)),
            (loc("planner.growth"), money(max(fv - contributed, 0))),
            (loc("planner.jht_years"), String(format: "%.0f %@", yrs, loc("planner.years"))),
        ], accent: AppTheme.teal)
    }
}
