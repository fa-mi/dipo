import SwiftUI
import SwiftData

// Moved out of StatisticsView.swift, unchanged. The export sheet and the report it renders.

// MARK: - Statistics Export Sheet

struct StatsExportSheet: View {
    let period: StatPeriod
    let periodSubtitle: String
    let selectedCard: BankCard?
    let income: Double
    /// Salary-aware income for the recommendation math (see StatsReportCard).
    var budgetIncome: Double? = nil
    let expenses: Double
    let weeklyAverage: Double
    let topCategories: [(category: TxCategory, amount: Double, percentage: Double)]
    let transactions: [TxRecord]
    let currency: String
    /// Per-card budget configs forwarded from the parent so this sheet can
    /// hand them to StatsReportCard for ratio resolution.
    let configs: [CardBudgetConfig]
    /// Spending over the same stretch of the previous period, for the change chip.
    var previousExpenses: Double? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: ShareItem?
    @State private var isGenerating = false

    private func cardDisplayLabel(_ card: BankCard) -> String {
        if card.isDigitalWallet, !card.walletProvider.isEmpty {
            return card.walletProvider
        }
        let holder = card.holderName.split(separator: " ").first.map(String.init) ?? card.holderName
        return "\(holder) ••\(card.last4)"
    }

    private var report: StatsReportCard {
        StatsReportCard(
            periodSubtitle: periodSubtitle,
            cardLabel: selectedCard.map(cardDisplayLabel) ?? "—",
            cardColor: selectedCard.map { Color(hex: $0.gradientStart) } ?? AppTheme.accent,
            income: income,
            budgetIncome: budgetIncome,
            expenses: expenses,
            weeklyAverage: weeklyAverage,
            topCategories: topCategories,
            transactionCount: transactions.count,
            currency: currency,
            cardID: selectedCard?.id.uuidString,
            configs: configs,
            filteredTransactions: transactions,
            previousExpenses: previousExpenses
        )
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        Text(loc("stats.export_hint"))
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 30)

                        // The preview IS the image: the same view, at the same
                        // width it is rendered at.
                        report
                            .frame(maxWidth: 400)
                            .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
                            .padding(.horizontal, 18)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 110)
                    .containerRelativeFrame(.horizontal)
                }

                Button {
                    HapticManager.shared.tap()
                    exportImage()
                } label: {
                    HStack(spacing: 10) {
                        if isGenerating {
                            ProgressView().tint(AppTheme.onVividFill)
                        } else {
                            Image(systemName: "square.and.arrow.up").font(.system(.body, weight: .semibold))
                        }
                        Text(loc("stats.export_image"))
                            .font(.system(.callout, weight: .bold))
                    }
                    .foregroundStyle(AppTheme.onVividFill)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(isGenerating)
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
                .background(
                    LinearGradient(colors: [AppTheme.bg.opacity(0), AppTheme.bg],
                                   startPoint: .top, endPoint: .center)
                        .ignoresSafeArea()
                )
            }
            .navigationTitle(loc("stats.export_preview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .doneToolbar { dismiss() }
        }
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(items: [item.url])
        }
    }

    // MARK: - Export

    /// Renders the report to a PNG at 3× and hands it to the share sheet, in the
    /// app's own light/dark setting so the image matches what was previewed.
    @MainActor
    private func exportImage() {
        isGenerating = true
        let cardName = selectedCard.map(cardDisplayLabel) ?? "—"
        let resolvedScheme: ColorScheme = {
            if let pref = appColorScheme() { return pref }
            return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        }()

        let content = report
            .frame(width: 390)
            .padding(18)
            .background(AppTheme.bg)
            .environment(\.colorScheme, resolvedScheme)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 3.0

        guard let uiImg = renderer.uiImage, let data = uiImg.pngData() else {
            isGenerating = false
            return
        }
        let filename = "DiPo_\(cardName.replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970)).png"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: tempURL)
            shareItem = ShareItem(url: tempURL)
        } catch {
            print("Image export error: \(error)")
        }
        isGenerating = false
    }
}

// MARK: - Stats Report Card (preview and PNG export)

/// The report as an image someone would actually send: the same four answers
/// as the Statistics screen, in the same colours, sized for a phone story.
///
/// It used to lead on a net figure in a green or red wash, set income and
/// spending in two boxes, rank categories with orange/grey/purple medals in the
/// old muted category colours, and close on a bordered tinted advice box — a
/// different visual language from the screen it was exported from.
struct StatsReportCard: View {
    let periodSubtitle: String
    let cardLabel: String
    let cardColor: Color
    let income: Double
    /// Income for BUDGET MATH (the recommendation): the salary schedule when
    /// there is one, so a period ending before payday doesn't distort it.
    var budgetIncome: Double? = nil
    private var insightIncome: Double { budgetIncome ?? income }
    let expenses: Double
    let weeklyAverage: Double
    let topCategories: [(category: TxCategory, amount: Double, percentage: Double)]
    let transactionCount: Int
    let currency: String
    /// Card whose ratios appear in the budget split. nil = global defaults.
    let cardID: String?
    let configs: [CardBudgetConfig]
    /// The period's transactions — for the same `topInsight()` Home uses.
    let filteredTransactions: [TxRecord]
    var previousExpenses: Double? = nil

    @Environment(\.colorScheme) private var colorScheme

    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: currency)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            spendingBlock
            if !topCategories.isEmpty { categoriesBlock }
            insightBlock
            if SmartBudgetManager.shared.hasActiveBudget, income > 0 { budgetBlock }
            footer
        }
        .padding(20)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("DiPoMascot")
                .resizable().scaledToFit()
                .frame(width: 34, height: 34)
                .blendMode(colorScheme == .dark ? .screen : .multiply)
            VStack(alignment: .leading, spacing: 1) {
                Text(loc("stats.report_title"))
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(periodSubtitle)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                Circle().fill(cardColor).frame(width: 7, height: 7)
                Text(cardLabel)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(AppTheme.cardMid.opacity(0.6), in: Capsule())
        }
    }

    private var spendingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("stats.expenses"))
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(money(expenses))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.55)
            }
            if let prev = previousExpenses, prev > 0 {
                let change = (expenses - prev) / prev * 100
                let up = change >= 0
                Label(String(format: loc(up ? "stats.vs_prev_up" : "stats.vs_prev_down"),
                             Int(abs(change).rounded())),
                      systemImage: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(up ? AppTheme.red : AppTheme.accent)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background((up ? AppTheme.red : AppTheme.accent).opacity(0.12), in: Capsule())
            }
            if income > 0 {
                let used = expenses / income
                SpendGauge(fraction: used)
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(loc("stats.income")).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        Text(money(income)).font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(loc(income >= expenses ? "stats.left" : "stats.over"))
                            .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        Text(money(abs(income - expenses)))
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(SpendGauge.tone(for: used))
                    }
                }
            }
        }
    }

    private var categoriesBlock: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(loc("stats.where_title"))
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
            ForEach(Array(topCategories.prefix(5).enumerated()), id: \.offset) { _, item in
                ReportCategoryRow(category: item.category, amount: item.amount,
                                  percentage: item.percentage, currency: currency)
            }
        }
    }

    private var insightBlock: some View {
        let insight = SmartBudgetManager.shared.topInsight(
            allTransactions: filteredTransactions,
            income: insightIncome,
            cardID: cardID,
            configs: configs,
            targetCurrency: currency,
            periodStart: filteredTransactions.map(\.date).min()
        )
        let (icon, tint, title, body): (String, Color, String, String) = {
            if let insight { return (insight.icon, insight.color, insight.title, insight.body) }
            if insightIncome <= 0 {
                return ("info.circle.fill", AppTheme.textSecondary,
                        loc("rec.no_income_title"), loc("rec.no_income_body"))
            }
            let savingsRate = max(0, (insightIncome - expenses) / insightIncome * 100)
            let spendRatio = expenses / insightIncome
            if spendRatio > 0.9 {
                return ("exclamationmark.triangle.fill", AppTheme.red,
                        loc("rec.overspend_title"),
                        String(format: loc("rec.overspend_body"), Int(spendRatio * 100)))
            }
            if savingsRate >= 20 {
                return ("checkmark.seal.fill", AppTheme.accent,
                        loc("rec.great_savings_title"),
                        String(format: loc("rec.great_savings_body"), Int(savingsRate)))
            }
            return ("lightbulb.fill", AppTheme.orange,
                    loc("rec.balance_title"),
                    String(format: loc("rec.balance_body"), Int(savingsRate)))
        }()

        return VStack(alignment: .leading, spacing: 10) {
            Text(loc("stats.notes_title"))
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
            reportNote(icon, tint, title, body)
            if weeklyAverage > 0 {
                reportNote("cup.and.saucer.fill", AppTheme.purple,
                           String(format: loc("stats.weekly_line"), money(weeklyAverage)),
                           String(format: loc("stats.report_tx_inline"), transactionCount))
            }
        }
    }

    private func reportNote(_ icon: String, _ tint: Color, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: AppRadius.xs))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(body)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// The budget split as one bar in the group colours — the same three
    /// shares the Smart Budget screen uses.
    private var budgetBlock: some View {
        let r = SmartBudgetManager.shared.ratios(forCardID: cardID, configs: configs)
        let parts: [(String, Double, Color)] = [
            (loc("budget.group.daily"), r.daily, AppTheme.blue),
            (loc("budget.group.lifestyle"), r.lifestyle, AppTheme.purple),
            (loc("budget.group.invest_debt"), r.investDebt, AppTheme.accent),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text(loc("budget.allocation_title"))
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
            GeometryReader { g in
                HStack(spacing: 3) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        Capsule().fill(part.2)
                            .frame(width: max((g.size.width - 6) * CGFloat(part.1), 4))
                    }
                }
            }
            .frame(height: 8)
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Circle().fill(part.2).frame(width: 7, height: 7)
                            Text(part.0).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        Text("\(Int((part.1 * 100).rounded()))% · " + money(income * part.1))
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Rectangle().fill(AppTheme.cardMid).frame(height: 1)
            Text(String(format: loc("stats.generated_by"), Date().displayDateTimeShort))
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: true, vertical: false)
            Rectangle().fill(AppTheme.cardMid).frame(height: 1)
        }
    }
}

/// A category in the report: its list colour, its share as a bar, its amount.
struct ReportCategoryRow: View {
    let category: TxCategory
    let amount: Double
    let percentage: Double
    let currency: String

    var body: some View {
        let hue = Color(hex: category.iconBg)
        HStack(spacing: 10) {
            Image(systemName: category.icon)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(hue, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(category.displayLabel)
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(CurrencyManager.shared.formatted(amount, currency: currency))
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Text("\(Int(percentage.rounded()))%")
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 32, alignment: .trailing)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.cardMid.opacity(0.8))
                        Capsule().fill(hue)
                            .frame(width: max(g.size.width * CGFloat(percentage / 100), 3))
                    }
                }
                .frame(height: 5)
            }
        }
    }
}
