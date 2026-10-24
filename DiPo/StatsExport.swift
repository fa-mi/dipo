import SwiftUI
import SwiftData

// Moved out of StatisticsView.swift. The export sheet and the report it renders.

// MARK: - Statistics Export Sheet

struct StatsExportSheet: View {
    let periodSubtitle: String
    let selectedCard: BankCard?
    let currency: String
    /// The headline's figures, exactly as Statistics shows them.
    let living: Double
    let livingFunds: Double
    let progress: (elapsed: Int, total: Int)?
    /// `StatisticsView.livingChange`: nil in the period's first week.
    let change: Double?
    let debtLine: String?
    let paceLine: (ok: Bool, text: String)?
    /// Spending & bills by category, largest first.
    let categories: [(category: TxCategory, amount: Double)]

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
            currency: currency,
            living: living,
            livingFunds: livingFunds,
            progress: progress,
            change: change,
            debtLine: debtLine,
            paceLine: paceLine,
            categories: categories
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

    /// Renders the report to a PNG at 3× and hands it to the share sheet. The
    /// card is the headline's dark field in both themes; the margin around it
    /// follows the app's light or dark setting, as the preview does.
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

/// The report as an image someone would actually send: the Statistics
/// headline, on its field, in its words.
///
/// It used to say "Expenses Rp 1.725.000" and "1020% more than last time" on
/// the day a Rp 1,5 jt card bill was paid, under a headline that said
/// Rp 225.000 had been spent and the card bill was not new spending. Now it
/// carries the headline's figures: spending & bills against income, debt paid
/// on a line of its own, where the period is heading, and what the spending
/// was. The balance is not in it: this is the picture that leaves the phone.
struct StatsReportCard: View {
    let periodSubtitle: String
    let cardLabel: String
    let cardColor: Color
    let currency: String
    /// Spending & bills, and what it is measured against: income plus any
    /// money added to the period's budget.
    let living: Double
    let livingFunds: Double
    let progress: (elapsed: Int, total: Int)?
    let change: Double?
    /// The headline's debt and pace sentences, word for word.
    let debtLine: String?
    let paceLine: (ok: Bool, text: String)?
    let categories: [(category: TxCategory, amount: Double)]

    private func money(_ v: Double) -> String {
        CurrencyManager.shared.formatted(v, currency: currency)
    }

    private var ratio: Double { livingFunds > 0 ? living / livingFunds : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            figure
            if livingFunds > 0 { gauge }
            if let debtLine {
                panel("creditcard.fill", AppTheme.blue, debtLine, fill: AppTheme.flowCobalt.opacity(0.18))
            }
            if let paceLine {
                panel(paceLine.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                      paceLine.ok ? AppTheme.accent : AppTheme.orange, paceLine.text,
                      fill: paceLine.ok ? AppTheme.flowPine.opacity(0.13) : AppTheme.orange.opacity(0.12))
            }
            if !categories.isEmpty { categoriesBlock }
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // The headline's field. Never the peach one: that warns about the
            // balance, which the image does not show.
            RoundedRectangle(cornerRadius: AppRadius.xl).fill(AppTheme.flowGround)
                .overlay { FlowField() }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.xl)
                    .stroke(AppTheme.flowMint.opacity(0.16), lineWidth: 1))
        }
        // Dark in both themes, as the headline is.
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("DiPoMascot")
                .resizable().scaledToFit()
                .frame(width: 34, height: 34)
                .blendMode(.screen)
            VStack(alignment: .leading, spacing: 1) {
                Text(loc("stats.report_title"))
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(periodSubtitle)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2).minimumScaleFactor(0.8)
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

    /// Spending & bills, as the headline counts them, and what it is out of.
    private var figure: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loc("stats.book_living"))
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            Text(money(living))
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(LinearGradient(stops: [.init(color: AppTheme.textPrimary, location: 0.3),
                                                        .init(color: AppTheme.flowFrost, location: 1)],
                                                startPoint: .top, endPoint: .bottom))
                .minimumScaleFactor(0.5).lineLimit(1)
            Text(figureCaption)
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(2)
        }
    }

    private var figureCaption: String {
        var parts: [String] = []
        if livingFunds > 0 { parts.append(String(format: loc("stats.share_of_income"), money(livingFunds))) }
        if let p = progress { parts.append(String(format: loc("stats.day_of"), p.elapsed, p.total)) }
        return parts.joined(separator: " · ")
    }

    /// The headline's gauge: the share of income, and a tick where time is.
    /// Bars of a set width, as the category rows: the masked gradient the
    /// screen uses drew full in this sheet whatever the share.
    private var gauge: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.cardMid)
                    Capsule().fill(ratio >= 1 ? AppTheme.orange : AppTheme.accent)
                        .frame(width: max(w * CGFloat(min(ratio, 1)), 10))
                    if let p = progress, p.total > 0 {
                        Capsule()
                            .fill(AppTheme.textPrimary.opacity(0.75))
                            .frame(width: 2, height: 18)
                            .offset(x: w * CGFloat(Double(p.elapsed) / Double(p.total)) - 1)
                    }
                }
                .frame(height: 10)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 18)

            HStack(spacing: 8) {
                Text(String(format: loc("stats.pct_of_income"), PeriodCashBook.usedPct(ratio: ratio)))
                    .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let c = change, abs(c) >= 1 {
                    let tint = c < 0 ? AppTheme.accent : AppTheme.orange
                    HStack(spacing: 3) {
                        Image(systemName: c >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(.caption2, weight: .bold))
                        Text(String(format: loc("stats.vs_last_period"), String(format: "%.0f%%", abs(c))))
                            .font(.system(.caption2, weight: .bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(tint.opacity(0.15), in: Capsule())
                    .fixedSize()
                }
            }
        }
    }

    private func panel(_ icon: String, _ tint: Color, _ text: String, fill: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(.subheadline))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .heroPanel(fill)
    }

    private var categoriesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc("stats.where_title"))
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(categories.prefix(5).enumerated()), id: \.offset) { _, item in
                    ReportCategoryRow(category: item.category, amount: item.amount,
                                      percentage: living > 0 ? min(item.amount / living, 1) * 100 : 0,
                                      currency: currency)
                }
            }
            .padding(12)
            .heroPanel(AppTheme.flowGround.opacity(0.46), edge: 0.09)
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
