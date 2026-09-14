//
//  DiPoWidget.swift
//  DiPoWidget
//
//  Medium-sized Home Screen widget. Two variants share the same layout:
//    - Free user: expense total, month, income on the left + Quick Add right.
//    - Royal user: same left, but income row is replaced with Smart Insights
//      (top category + weekly avg) so the upgrade unlocks something visible.
//
//  All numbers AND localized labels are pre-computed by the main app and
//  written to App Group UserDefaults. The widget is intentionally a thin
//  renderer — it doesn't import LanguageManager, CurrencyManager, or
//  PremiumManager because those types live in the app target.
//

import WidgetKit
import SwiftUI

// MARK: - Shared Bridge Config
//
// Mirrors `WidgetDataSync` in the main app (RootView.swift). Keep these
// strings byte-identical to the main app's `WidgetDataSync.Key.*` —
// they're the contract between the two processes.

enum DiPoSharedConfig {
    /// Must match the App Group enabled on BOTH this widget extension and
    /// the main app target. iOS silently returns nil if it's wrong.
    static let appGroupID = "group.com.fahmiaquinas.DiPo"

    enum Key {
        static let monthlyExpensesFormatted = "widget.monthlyExpensesFormatted"
        static let monthlyIncomeFormatted   = "widget.monthlyIncomeFormatted"
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

        /// Written by the app's LanguageManager; used here only for the text
        /// the widget shows before the app has ever synced.
        static let language                 = "dipo_language"
    }

    /// Deep-link URL the widget's Quick Add button opens. Handled by the
    /// main app's `.onOpenURL` in FinanceAppMain.swift.
    static let addTransactionURL = URL(string: "dipo://add-transaction")!

    /// Deep-link URL the free-user Smart Insights teaser opens. Routes the
    /// user straight to the Royal paywall — taps on the locked insights
    /// preview must NEVER open the Add Transaction sheet, that would be
    /// a UX trap. Handled by `.onOpenURL` in FinanceAppMain.swift.
    static let upgradeRoyalURL    = URL(string: "dipo://upgrade-royal")!
}

// MARK: - Timeline Entry

/// One snapshot of the data the widget renders.
struct MonthlyExpensesEntry: TimelineEntry {
    let date: Date
    // Numbers
    let expensesFormatted: String
    let incomeFormatted: String
    /// The window the total covers: "Since payday 25 Aug", or the month.
    let monthLabel: String
    // Royal insights
    let isRoyal: Bool
    let topCategoryLabel: String
    let topCategoryFormatted: String
    let topCategoryPercent: Int
    let weeklyAvgFormatted: String
    // Localized labels (mirrors the user's chosen app language)
    let labelExpenses: String
    let labelIncome: String
    let labelQuickAdd: String
    let labelTopCategory: String
    let labelWeeklyAvg: String
    let labelInsights: String
    let labelUpgrade: String
    /// True when we couldn't read the shared store. The view renders a
    /// friendly default so the widget gallery preview doesn't show zeros.
    let isPlaceholder: Bool

    /// Sample entry for the widget gallery and the first launch, in the app's
    /// language when the app has recorded one (Indonesian otherwise).
    static var placeholder: MonthlyExpensesEntry {
        let english = WidgetCopy.isEnglish
        return MonthlyExpensesEntry(
            date: .now,
            expensesFormatted:    "Rp 0",
            incomeFormatted:      "Rp 0",
            monthLabel:           english ? "This month" : "Bulan ini",
            isRoyal:              false,
            topCategoryLabel:     "",
            topCategoryFormatted: "",
            topCategoryPercent:   0,
            weeklyAvgFormatted:   "",
            labelExpenses:        english ? "Expense" : "Pengeluaran",
            labelIncome:          english ? "Income" : "Pemasukan",
            labelQuickAdd:        english ? "Add\nTransaction" : "Tambah\nTransaksi",
            labelTopCategory:     english ? "Biggest" : "Terbesar",
            labelWeeklyAvg:       english ? "per week" : "per minggu",
            labelInsights:        english ? "Spending insights" : "Ringkasan belanja",
            labelUpgrade:         english ? "Unlock with Royal" : "Buka dengan Royal",
            isPlaceholder:        true
        )
    }
}

/// The few strings the widget needs before the app has written any. Everything
/// else arrives pre-translated from the app.
enum WidgetCopy {
    static var isEnglish: Bool {
        UserDefaults(suiteName: DiPoSharedConfig.appGroupID)?
            .string(forKey: DiPoSharedConfig.Key.language) == "en"
    }

    static var galleryDescription: String {
        isEnglish ? "Spending this pay period, and a quick Add button."
                  : "Pengeluaran periode ini dan tombol tambah cepat."
    }
}

// MARK: - Timeline Provider

struct Provider: TimelineProvider {

    func placeholder(in context: Context) -> MonthlyExpensesEntry { .placeholder }

    func getSnapshot(in context: Context,
                     completion: @escaping (MonthlyExpensesEntry) -> Void) {
        completion(readCurrent())
    }

    /// We emit a single entry and ask iOS to refresh in 1 hour. In practice
    /// the main app reloads the timeline after every change it makes (and when
    /// it goes to the background), so the timer is the worst-case fallback.
    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<MonthlyExpensesEntry>) -> Void) {
        let entry   = readCurrent()
        let refresh = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func readCurrent() -> MonthlyExpensesEntry {
        guard let store = UserDefaults(suiteName: DiPoSharedConfig.appGroupID),
              let expensesFormatted = store.string(forKey: DiPoSharedConfig.Key.monthlyExpensesFormatted)
        else {
            return .placeholder
        }
        // `typealias K` lets us reference `K.foo` like a namespace abbrev.
        // Plain `let K = DiPoSharedConfig.Key` would fail — `Key` is a type
        // (a caseless enum used as a namespace), not a value.
        typealias K = DiPoSharedConfig.Key
        let fallback = MonthlyExpensesEntry.placeholder

        return MonthlyExpensesEntry(
            date:                 store.object(forKey: K.lastUpdated) as? Date ?? .now,
            expensesFormatted:    expensesFormatted,
            incomeFormatted:      store.string(forKey: K.monthlyIncomeFormatted) ?? "—",
            monthLabel:           store.string(forKey: K.monthLabel) ?? "—",
            isRoyal:              store.bool(forKey: K.isRoyal),
            topCategoryLabel:     store.string(forKey: K.topCategoryLabel) ?? "",
            topCategoryFormatted: store.string(forKey: K.topCategoryFormatted) ?? "",
            topCategoryPercent:   store.integer(forKey: K.topCategoryPercent),
            weeklyAvgFormatted:   store.string(forKey: K.weeklyAvgFormatted) ?? "",
            // Labels written by an older app build may be missing — fall back
            // to the placeholder copy, which follows the same language.
            labelExpenses:        store.string(forKey: K.labelExpenses)    ?? fallback.labelExpenses,
            labelIncome:          store.string(forKey: K.labelIncome)      ?? fallback.labelIncome,
            labelQuickAdd:        store.string(forKey: K.labelQuickAdd)    ?? fallback.labelQuickAdd,
            labelTopCategory:     store.string(forKey: K.labelTopCategory) ?? fallback.labelTopCategory,
            labelWeeklyAvg:       store.string(forKey: K.labelWeeklyAvg)   ?? fallback.labelWeeklyAvg,
            labelInsights:        store.string(forKey: K.labelInsights)    ?? fallback.labelInsights,
            labelUpgrade:         store.string(forKey: K.labelUpgrade)     ?? fallback.labelUpgrade,
            isPlaceholder:        false
        )
    }
}

// MARK: - Adaptive Widget Theme
//
// The widget can't import the main app's `AppTheme` (separate target,
// separate process). The few colours it renders are mirrored here with the
// SAME light/dark values as `AppTheme.swift` — a tweak there is a tweak here.

private enum WidgetTheme {
    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    /// `AppTheme.accent` — #1DB87A in both themes.
    static let accent      = Color(red: 0x1D / 255, green: 0xB8 / 255, blue: 0x7A / 255)
    /// `AppTheme.onVividFill` — label on a solid fill.
    static let onVividFill = adaptive(dark: 0x0D1514, light: 0xFFFFFF)
    /// `AppTheme.purple` — Royal.
    static let purple      = adaptive(dark: 0xA78BFA, light: 0x8B66F8)
    /// `AppTheme.orange` / `AppTheme.blue` — the two insight icons.
    static let orange      = adaptive(dark: 0xFB923C, light: 0xCF5F04)
    static let blue        = adaptive(dark: 0x38BDF8, light: 0x0789C3)
    /// `AppTheme.textSecondary` — `.secondary` in a widget is too faint on the
    /// tinted background in light mode.
    static let secondary   = adaptive(dark: 0x8A9693, light: 0x4D6B62)

    /// Subtle gradient so the widget reads like a card rather than a flat
    /// panel. Two-stop, low-contrast, tinted toward the brand green.
    static func backgroundGradient(for scheme: ColorScheme) -> LinearGradient {
        let stops: [Color]
        switch scheme {
        case .dark:
            stops = [
                Color(red: 0.13, green: 0.17, blue: 0.16),
                Color(red: 0.10, green: 0.13, blue: 0.12),
            ]
        default:
            stops = [
                Color(red: 0.97, green: 0.99, blue: 0.97),
                Color(red: 0.91, green: 0.97, blue: 0.93),
            ]
        }
        return LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - View

struct DiPoWidgetEntryView: View {
    var entry: MonthlyExpensesEntry
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            infoColumn
            Divider()
                .padding(.vertical, 12)
            quickAddColumn
                // Narrower than the info column: the headline question is
                // "how much have I spent", the button only needs a good target.
                .frame(width: 110)
        }
        .containerBackground(for: .widget) {
            WidgetTheme.backgroundGradient(for: colorScheme)
        }
    }

    // MARK: Info column (left)

    /// The expense headline is always shown; the footer is the Royal insights
    /// or, for everyone else, a locked preview of them.
    ///
    /// Tapping the headline opens the app. It used to open the PAYWALL for free
    /// users — the whole column was one upgrade link, so checking your own
    /// spending from the Home Screen landed you on a sales page. Only the
    /// locked preview links there now.
    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(WidgetTheme.secondary)
                Text(entry.labelExpenses)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WidgetTheme.secondary)
                if entry.isRoyal {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(WidgetTheme.purple)
                }
            }

            Text(entry.expensesFormatted)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())

            Text(entry.monthLabel)
                .font(.system(size: 12))
                .foregroundStyle(WidgetTheme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)

            if entry.isRoyal {
                royalInsights
            } else {
                Link(destination: DiPoSharedConfig.upgradeRoyalURL) {
                    lockedInsightsTeaser
                }
            }
        }
        .padding(.leading, 14)
        .padding(.vertical, 12)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Free-tier preview: the SHAPE of the insights with the values redacted,
    /// and one line saying how to open them.
    private var lockedInsightsTeaser: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Sample values inside the redaction give the skeleton real
            // proportions instead of flat bars.
            HStack(spacing: 4) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(WidgetTheme.orange)
                Text("Makan & Minum 42%")
                    .font(.system(size: 12, weight: .semibold))
                    .redacted(reason: .placeholder)
            }
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(entry.labelUpgrade)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(WidgetTheme.purple)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.labelInsights), \(entry.labelUpgrade)")
    }

    /// Royal footer: biggest category and a typical week. A metric with no
    /// data yet is hidden rather than shown as "—".
    private var royalInsights: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !entry.topCategoryLabel.isEmpty && !entry.topCategoryFormatted.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(WidgetTheme.orange)
                    Text(entry.topCategoryLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("\(entry.topCategoryPercent)%")
                        .font(.system(size: 12))
                        .foregroundStyle(WidgetTheme.secondary)
                }
            }
            if !entry.weeklyAvgFormatted.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11))
                        .foregroundStyle(WidgetTheme.blue)
                    Text(entry.weeklyAvgFormatted)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    // Was "/ \(label)" over a label that already read
                    // "Spending / week" — the widget showed "Rp 351.800 / Spending / week".
                    Text(entry.labelWeeklyAvg)
                        .font(.system(size: 12))
                        .foregroundStyle(WidgetTheme.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }

    // MARK: Quick Add column (right)

    private var quickAddColumn: some View {
        Link(destination: DiPoSharedConfig.addTransactionURL) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(WidgetTheme.accent)
                        .frame(width: 46, height: 46)
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(WidgetTheme.onVividFill)
                }
                Text(entry.labelQuickAdd)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Widget Definition

struct DiPoWidget: Widget {
    /// Stable kind ID. WidgetKit uses this to identify the widget across
    /// reloads — never change it after shipping or users will lose their
    /// installed widget.
    let kind: String = "DiPoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            DiPoWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("DiPo")
        .description(WidgetCopy.galleryDescription)
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Preview

// Previews are split into 4 (light/dark × free/royal) so we catch
// contrast bugs early. Xcode's preview canvas honors `.preferredColorScheme`
// on widget previews same as it does on regular SwiftUI views.

private let sampleFreeEntry = MonthlyExpensesEntry(
    date: .now,
    expensesFormatted: "Rp 703.600",
    incomeFormatted:   "Rp 10.000.000",
    monthLabel:        "Sejak gajian 25 Agu",
    isRoyal:           false,
    topCategoryLabel:  "",
    topCategoryFormatted: "",
    topCategoryPercent: 0,
    weeklyAvgFormatted: "",
    labelExpenses:    "Pengeluaran",
    labelIncome:      "Pemasukan",
    labelQuickAdd:    "Tambah\nTransaksi",
    labelTopCategory: "Terbesar",
    labelWeeklyAvg:   "per minggu",
    labelInsights:    "Ringkasan belanja",
    labelUpgrade:     "Buka dengan Royal",
    isPlaceholder:    false
)

private let sampleRoyalEntry = MonthlyExpensesEntry(
    date: .now,
    expensesFormatted: "Rp 703.600",
    incomeFormatted:   "Rp 10.000.000",
    monthLabel:        "Sejak gajian 25 Agu",
    isRoyal:           true,
    topCategoryLabel:  "Makan & Minum",
    topCategoryFormatted: "Rp 703.600",
    topCategoryPercent: 42,
    weeklyAvgFormatted: "Rp 351.800",
    labelExpenses:    "Pengeluaran",
    labelIncome:      "Pemasukan",
    labelQuickAdd:    "Tambah\nTransaksi",
    labelTopCategory: "Terbesar",
    labelWeeklyAvg:   "per minggu",
    labelInsights:    "Ringkasan belanja",
    labelUpgrade:     "Buka dengan Royal",
    isPlaceholder:    false
)

#Preview("Free · Light", as: .systemMedium) {
    DiPoWidget()
} timeline: { sampleFreeEntry }

#Preview("Free · Dark", as: .systemMedium) {
    DiPoWidget()
} timeline: { sampleFreeEntry }

#Preview("Royal · Light", as: .systemMedium) {
    DiPoWidget()
} timeline: { sampleRoyalEntry }

#Preview("Royal · Dark", as: .systemMedium) {
    DiPoWidget()
} timeline: { sampleRoyalEntry }
