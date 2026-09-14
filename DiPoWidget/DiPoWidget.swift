//
//  DiPoWidget.swift
//  DiPoWidget
//
//  Home Screen and Lock Screen widgets for this pay period's spending.
//
//    - Small:  spending, the period, and the spend gauge with what is left.
//    - Medium: the same, plus one insight (Royal) and a Quick Add button.
//    - Lock Screen: a circular gauge, a rectangular line with a bar, and an
//      inline line — for the glance that does not need the phone unlocked.
//
//  Every number AND label is computed by the main app and written to App Group
//  UserDefaults (`WidgetDataSync` in RootView.swift). The widget is a thin
//  renderer: it cannot import LanguageManager, CurrencyManager or
//  PremiumManager, which live in the app target.
//

import WidgetKit
import SwiftUI

// MARK: - Shared Bridge Config
//
// Keep these strings byte-identical to `WidgetDataSync.Key.*` in the app —
// they are the contract between the two processes.

enum DiPoSharedConfig {
    /// Must match the App Group enabled on BOTH this extension and the app.
    static let appGroupID = "group.com.fahmiaquinas.DiPo"

    enum Key {
        static let monthlyExpenses          = "widget.monthlyExpenses"
        static let monthlyExpensesFormatted = "widget.monthlyExpensesFormatted"
        static let monthlyIncome            = "widget.monthlyIncome"
        static let monthlyIncomeFormatted   = "widget.monthlyIncomeFormatted"
        static let leftFormatted            = "widget.leftFormatted"
        static let monthLabel               = "widget.monthLabel"
        static let lastUpdated              = "widget.lastUpdated"

        // Royal-only insights.
        static let isRoyal                  = "widget.isRoyal"
        static let topCategoryLabel         = "widget.topCategoryLabel"
        static let topCategoryFormatted     = "widget.topCategoryFormatted"
        static let topCategoryPercent       = "widget.topCategoryPercent"
        static let weeklyAvgFormatted       = "widget.weeklyAvgFormatted"

        // Localized labels (pre-resolved in main app).
        static let labelExpenses            = "widget.label.expenses"
        static let labelIncome              = "widget.label.income"
        static let labelQuickAdd            = "widget.label.quickAdd"
        static let labelTopCategory         = "widget.label.topCategory"
        static let labelWeeklyAvg           = "widget.label.weeklyAvg"
        static let labelInsights            = "widget.label.insights"
        static let labelUpgrade             = "widget.label.upgrade"
        static let labelLeft                = "widget.label.left"
        static let labelOver                = "widget.label.over"

        /// Written by the app's LanguageManager; used here only for the text
        /// the widget shows before the app has ever synced.
        static let language                 = "dipo_language"
    }

    /// Opens Add Transaction. Handled by `.onOpenURL` in FinanceAppMain.swift.
    static let addTransactionURL = URL(string: "dipo://add-transaction")!
    /// Opens the Royal paywall — only ever from the locked insight line.
    static let upgradeRoyalURL    = URL(string: "dipo://upgrade-royal")!
}

// MARK: - Timeline Entry

struct MonthlyExpensesEntry: TimelineEntry {
    let date: Date
    let expenses: Double
    let income: Double
    let expensesFormatted: String
    let incomeFormatted: String
    let leftFormatted: String
    /// The window the total covers: "Since payday 25 Aug", or the month.
    let monthLabel: String
    let isRoyal: Bool
    let topCategoryLabel: String
    let topCategoryPercent: Int
    let labelExpenses: String
    let labelQuickAdd: String
    let labelTopCategory: String
    let labelUpgrade: String
    let labelLeft: String
    let labelOver: String
    let isPlaceholder: Bool

    /// Spent ÷ income; nil when there is no income to measure against.
    var spentFraction: Double? { income > 0 ? expenses / income : nil }

    /// Sample entry for the gallery and first launch, in the app's language
    /// when the app has recorded one (Indonesian otherwise).
    static var placeholder: MonthlyExpensesEntry {
        let english = WidgetCopy.isEnglish
        return MonthlyExpensesEntry(
            date: .now,
            expenses: 3_450_000, income: 10_000_000,
            expensesFormatted: "Rp 3.450.000",
            incomeFormatted:   "Rp 10.000.000",
            leftFormatted:     "Rp 6.550.000",
            monthLabel:        english ? "Since payday 25 Aug" : "Sejak gajian 25 Agu",
            isRoyal: false,
            topCategoryLabel: "", topCategoryPercent: 0,
            labelExpenses:    english ? "Expense" : "Pengeluaran",
            labelQuickAdd:    english ? "Log" : "Catat",
            labelTopCategory: english ? "Biggest" : "Terbesar",
            labelUpgrade:     english ? "Unlock with Royal" : "Buka dengan Royal",
            labelLeft:        english ? "Left" : "Sisa",
            labelOver:        english ? "Over by" : "Lebih",
            isPlaceholder: true
        )
    }
}

/// The few strings the widget needs before the app has written any.
enum WidgetCopy {
    static var isEnglish: Bool {
        UserDefaults(suiteName: DiPoSharedConfig.appGroupID)?
            .string(forKey: DiPoSharedConfig.Key.language) == "en"
    }

    static var galleryDescription: String {
        isEnglish ? "Spending this pay period, how much is left, and a quick Add button."
                  : "Pengeluaran periode ini, sisa uangmu, dan tombol tambah cepat."
    }
}

// MARK: - Timeline Provider

struct Provider: TimelineProvider {

    func placeholder(in context: Context) -> MonthlyExpensesEntry { .placeholder }

    func getSnapshot(in context: Context,
                     completion: @escaping (MonthlyExpensesEntry) -> Void) {
        completion(context.isPreview ? .placeholder : readCurrent())
    }

    /// One entry, refreshed hourly at worst. The app reloads the timeline after
    /// every change it makes and when it goes to the background.
    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<MonthlyExpensesEntry>) -> Void) {
        let refresh = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
        completion(Timeline(entries: [readCurrent()], policy: .after(refresh)))
    }

    private func readCurrent() -> MonthlyExpensesEntry {
        guard let store = UserDefaults(suiteName: DiPoSharedConfig.appGroupID),
              let expensesFormatted = store.string(forKey: DiPoSharedConfig.Key.monthlyExpensesFormatted)
        else {
            return .placeholder
        }
        typealias K = DiPoSharedConfig.Key
        let fallback = MonthlyExpensesEntry.placeholder
        return MonthlyExpensesEntry(
            date:               store.object(forKey: K.lastUpdated) as? Date ?? .now,
            expenses:           store.double(forKey: K.monthlyExpenses),
            income:             store.double(forKey: K.monthlyIncome),
            expensesFormatted:  expensesFormatted,
            incomeFormatted:    store.string(forKey: K.monthlyIncomeFormatted) ?? "—",
            leftFormatted:      store.string(forKey: K.leftFormatted) ?? "",
            monthLabel:         store.string(forKey: K.monthLabel) ?? "—",
            isRoyal:            store.bool(forKey: K.isRoyal),
            topCategoryLabel:   store.string(forKey: K.topCategoryLabel) ?? "",
            topCategoryPercent: store.integer(forKey: K.topCategoryPercent),
            labelExpenses:      store.string(forKey: K.labelExpenses)    ?? fallback.labelExpenses,
            labelQuickAdd:      store.string(forKey: K.labelQuickAdd)    ?? fallback.labelQuickAdd,
            labelTopCategory:   store.string(forKey: K.labelTopCategory) ?? fallback.labelTopCategory,
            labelUpgrade:       store.string(forKey: K.labelUpgrade)     ?? fallback.labelUpgrade,
            labelLeft:          store.string(forKey: K.labelLeft)        ?? fallback.labelLeft,
            labelOver:          store.string(forKey: K.labelOver)        ?? fallback.labelOver,
            isPlaceholder:      false
        )
    }
}

// MARK: - Theme
//
// The widget cannot import `AppTheme`; these mirror its light/dark values.

private enum WidgetTheme {
    static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
    private static func fixed(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255)
    }

    static let accent      = fixed(0x1DB87A)
    static let yellow      = fixed(0xEAB308)
    static let amber       = fixed(0xF97316)
    static let red         = adaptive(dark: 0xFF6166, light: 0xE5484D)
    static let orangeText  = adaptive(dark: 0xFB923C, light: 0xCF5F04)
    static let onVividFill = adaptive(dark: 0x0D1514, light: 0xFFFFFF)
    static let purple      = adaptive(dark: 0xA78BFA, light: 0x8B66F8)
    static let secondary   = adaptive(dark: 0x8A9693, light: 0x4D6B62)
    static let track       = adaptive(dark: 0x2A3330, light: 0xE4EAE8)

    /// Same stops as the app's `SpendGauge`.
    static let gaugeStops: [Gradient.Stop] = [
        .init(color: accent, location: 0),
        .init(color: accent, location: 0.55),
        .init(color: yellow, location: 0.72),
        .init(color: amber,  location: 0.88),
        .init(color: red,    location: 1),
    ]

    static func tone(for fraction: Double) -> Color {
        if fraction < 0.72 { return accent }
        if fraction < 1 { return orangeText }
        return red
    }

    static func background(for scheme: ColorScheme) -> LinearGradient {
        let stops: [Color] = scheme == .dark
            ? [Color(red: 0.13, green: 0.17, blue: 0.16), Color(red: 0.10, green: 0.13, blue: 0.12)]
            : [Color(red: 0.98, green: 0.99, blue: 0.98), Color(red: 0.92, green: 0.97, blue: 0.94)]
        return LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Pieces
//
// Every piece is drawn for two worlds. In full colour it uses DiPo's palette.
// On a Clear or Tinted Home Screen iOS flattens every colour to one tint and
// keeps only opacity — so an opaque track under an opaque fill became one solid
// white bar, and a white "+" on a filled square vanished. There, hierarchy is
// carried by opacity instead, and the parts that matter are marked accentable.

/// The app's spend gauge: a green→red gradient revealed up to the spent share.
private struct WidgetSpendBar: View {
    let fraction: Double
    let fullColor: Bool
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let shown = max(w * CGFloat(min(max(fraction, 0), 1)), height)
            ZStack(alignment: .leading) {
                Capsule().fill(fullColor ? WidgetTheme.track : Color.primary.opacity(0.22))
                if !fullColor {
                    Capsule().fill(Color.primary)
                        .frame(width: shown)
                        .widgetAccentable()
                } else if fraction >= 1 {
                    Capsule().fill(WidgetTheme.red)
                } else {
                    LinearGradient(stops: WidgetTheme.gaugeStops, startPoint: .leading, endPoint: .trailing)
                        .frame(width: w)
                        .mask(alignment: .leading) { Capsule().frame(width: shown) }
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Views per family

struct DiPoWidgetEntryView: View {
    var entry: MonthlyExpensesEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var fullColor: Bool { renderingMode == .fullColor }

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryRectangular:
            rectangular
                .containerBackground(for: .widget) { Color.clear }
        case .accessoryInline:
            inline
                .containerBackground(for: .widget) { Color.clear }
        case .systemSmall:
            small
                .containerBackground(for: .widget) { WidgetTheme.background(for: colorScheme) }
        default:
            medium
                .containerBackground(for: .widget) { WidgetTheme.background(for: colorScheme) }
        }
    }

    // MARK: Shared parts

    private var secondary: Color { fullColor ? WidgetTheme.secondary : Color.primary.opacity(0.65) }

    private func tone(_ fraction: Double) -> Color {
        fullColor ? WidgetTheme.tone(for: fraction) : .primary
    }

    /// "● Expense" with the Royal crown when it applies.
    private var titleRow: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(fullColor ? WidgetTheme.accent : Color.primary)
                .frame(width: 7, height: 7)
                .widgetAccentable()
            Text(entry.labelExpenses)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(secondary)
                .lineLimit(1)
            if entry.isRoyal {
                Image(systemName: "crown.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(fullColor ? WidgetTheme.purple : Color.primary.opacity(0.8))
                    .widgetAccentable()
            }
        }
    }

    private func amount(size: CGFloat) -> some View {
        Text(entry.expensesFormatted)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(.numericText())
    }

    private var period: some View {
        Text(entry.monthLabel)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// Bar with the share spent at its end, and "Left Rp X" underneath.
    @ViewBuilder
    private func gauge(compact: Bool) -> some View {
        if let f = entry.spentFraction, !entry.leftFormatted.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    WidgetSpendBar(fraction: f, fullColor: fullColor)
                    Text("\(Int((f * 100).rounded()))%")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(tone(f))
                        .fixedSize()
                }
                HStack(spacing: 4) {
                    Text(f >= 1 ? entry.labelOver : entry.labelLeft)
                        .foregroundStyle(secondary)
                    Text(entry.leftFormatted)
                        .fontWeight(.semibold)
                        .foregroundStyle(tone(f))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .font(.system(size: compact ? 11 : 12))
            }
        } else {
            period
        }
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            amount(size: 22)
                .padding(.top, 6)
            period
                .padding(.top, 1)
            Spacer(minLength: 8)
            gauge(compact: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                titleRow
                amount(size: 26)
                    .padding(.top, 4)
                period
                    .padding(.top, 1)
                Spacer(minLength: 8)
                gauge(compact: false)
                insightLine
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            quickAdd
        }
    }

    /// One insight for Royal; for everyone else one quiet line on what Royal adds.
    @ViewBuilder
    private var insightLine: some View {
        if entry.isRoyal {
            if !entry.topCategoryLabel.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(fullColor ? WidgetTheme.orangeText : Color.primary.opacity(0.8))
                    Text(entry.topCategoryLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("\(entry.topCategoryPercent)%")
                        .font(.system(size: 11))
                        .foregroundStyle(secondary)
                }
            }
        } else {
            Link(destination: DiPoSharedConfig.upgradeRoyalURL) {
                HStack(spacing: 4) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(entry.labelUpgrade)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(fullColor ? WidgetTheme.purple : Color.primary.opacity(0.8))
            }
        }
    }

    /// A round button with its label. In Clear/Tinted mode the disc turns to a
    /// translucent tint and the plus stays solid, so the glyph can't disappear
    /// into its own background.
    private var quickAdd: some View {
        Link(destination: DiPoSharedConfig.addTransactionURL) {
            VStack(spacing: 7) {
                ZStack {
                    if fullColor {
                        Circle().fill(WidgetTheme.accent)
                    } else {
                        Circle().fill(Color.primary.opacity(0.18))
                            .widgetAccentable()
                    }
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(fullColor ? WidgetTheme.onVividFill : Color.primary)
                }
                .frame(width: 58, height: 58)
                Text(entry.labelQuickAdd)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 70)
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: Lock Screen

    private var circular: some View {
        let f = entry.spentFraction ?? 0
        return Gauge(value: min(max(f, 0), 1)) {
            Image(systemName: "creditcard")
        } currentValueLabel: {
            Text("\(Int((f * 100).rounded()))%")
                .font(.system(size: 13, weight: .bold, design: .rounded))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.labelExpenses)
                .font(.system(size: 12, weight: .semibold))
                .widgetAccentable()
            Text(entry.expensesFormatted)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let f = entry.spentFraction {
                Gauge(value: min(max(f, 0), 1)) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
            } else {
                Text(entry.monthLabel)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        let pct = entry.spentFraction.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
        return Text("\(entry.expensesFormatted)\(pct)")
    }
}

// MARK: - Widget Definition

struct DiPoWidget: Widget {
    /// Stable kind ID — never change it after shipping, or users lose the
    /// widget they installed.
    let kind: String = "DiPoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            DiPoWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("DiPo")
        .description(WidgetCopy.galleryDescription)
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Preview

private let sampleEntry = MonthlyExpensesEntry(
    date: .now, expenses: 7_900_000, income: 10_000_000,
    expensesFormatted: "Rp 7.900.000", incomeFormatted: "Rp 10.000.000",
    leftFormatted: "Rp 2.100.000", monthLabel: "Sejak gajian 25 Agu",
    isRoyal: true, topCategoryLabel: "Makan & Minum", topCategoryPercent: 42,
    labelExpenses: "Pengeluaran", labelQuickAdd: "Catat", labelTopCategory: "Terbesar",
    labelUpgrade: "Buka dengan Royal", labelLeft: "Sisa", labelOver: "Lebih",
    isPlaceholder: false
)

#Preview("Small", as: .systemSmall) { DiPoWidget() } timeline: { sampleEntry }
#Preview("Medium", as: .systemMedium) { DiPoWidget() } timeline: { sampleEntry }
#Preview("Lock · circular", as: .accessoryCircular) { DiPoWidget() } timeline: { sampleEntry }
#Preview("Lock · rectangular", as: .accessoryRectangular) { DiPoWidget() } timeline: { sampleEntry }
