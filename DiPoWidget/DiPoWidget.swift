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
    /// True when we couldn't read the shared store. The view renders a
    /// friendly default so the widget gallery preview doesn't show zeros.
    let isPlaceholder: Bool

    /// Sample entry for the widget gallery + first-launch fallback.
    /// Indonesian text matches the most common case; the real labels get
    /// resolved on first sync.
    static let placeholder = MonthlyExpensesEntry(
        date: .now,
        expensesFormatted:    "Rp 0",
        incomeFormatted:      "Rp 0",
        monthLabel:           "—",
        isRoyal:              false,
        topCategoryLabel:     "",
        topCategoryFormatted: "",
        topCategoryPercent:   0,
        weeklyAvgFormatted:   "",
        labelExpenses:        "Pengeluaran",
        labelIncome:          "Pemasukan",
        labelQuickAdd:        "Tambah\nTransaksi",
        labelTopCategory:     "Top",
        labelWeeklyAvg:       "Rata-rata mingguan",
        isPlaceholder:        true
    )
}

// MARK: - Timeline Provider

struct Provider: TimelineProvider {

    func placeholder(in context: Context) -> MonthlyExpensesEntry { .placeholder }

    func getSnapshot(in context: Context,
                     completion: @escaping (MonthlyExpensesEntry) -> Void) {
        completion(readCurrent())
    }

    /// We emit a single entry and ask iOS to refresh in 1 hour. In practice
    /// the main app calls `WidgetCenter.reloadAllTimelines()` after every
    /// tx change, so the timer is the worst-case fallback.
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
        let placeholder = MonthlyExpensesEntry.placeholder

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
            // Labels: fall back to the placeholder defaults if the app
            // hasn't synced yet — keeps the widget readable on day-one
            // before first refresh.
            labelExpenses:        store.string(forKey: K.labelExpenses)    ?? placeholder.labelExpenses,
            labelIncome:          store.string(forKey: K.labelIncome)      ?? placeholder.labelIncome,
            labelQuickAdd:        store.string(forKey: K.labelQuickAdd)    ?? placeholder.labelQuickAdd,
            labelTopCategory:     store.string(forKey: K.labelTopCategory) ?? placeholder.labelTopCategory,
            labelWeeklyAvg:       store.string(forKey: K.labelWeeklyAvg)   ?? placeholder.labelWeeklyAvg,
            isPlaceholder:        false
        )
    }
}

// MARK: - Adaptive Widget Theme
//
// The widget can't import the main app's `AppTheme` (separate target,
// separate process). We mirror just the colors the widget renders here so
// the visual language matches across surfaces.
//
// Color values copied 1:1 from `AppTheme.swift` so a tweak there is a
// one-line tweak here too. Don't add app-specific colors that aren't
// actually used by the widget — keep this surface minimal.

private enum WidgetTheme {
    /// App backdrop (`AppTheme.bg`).
    static let bgDark   = Color(red: 0.10, green: 0.12, blue: 0.12)  // #1A1F1E
    static let bgLight  = Color(red: 0.95, green: 0.96, blue: 0.95)  // #F2F4F3

    /// Card surface (`AppTheme.cardDark`).
    static let surfaceDark  = Color(red: 0.13, green: 0.16, blue: 0.15)  // #222827
    static let surfaceLight = Color(red: 1.00, green: 1.00, blue: 1.00)  // #FFFFFF

    /// Subtle gradient overlay on top of the surface so the widget reads
    /// like a card rather than a flat panel. Two-stop, low-contrast.
    static func backgroundGradient(for scheme: ColorScheme) -> LinearGradient {
        let stops: [Color]
        switch scheme {
        case .dark:
            // Slightly tinted toward the brand green so the widget
            // doesn't disappear into Apple's stock dark wallpapers.
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
        return LinearGradient(
            colors: stops,
            startPoint: .topLeading,
            endPoint:   .bottomTrailing
        )
    }
}

// MARK: - View

struct DiPoWidgetEntryView: View {
    var entry: MonthlyExpensesEntry
    /// Mirrors iOS system appearance (auto-toggles when the user changes
    /// dark/light mode at the OS level). WidgetKit re-renders the widget
    /// on appearance changes for free — no extra plumbing needed.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            // For free users the left column doubles as the upgrade hook —
            // tap anywhere on the insights teaser routes to the Royal
            // paywall. For Royal users there's no link; they already paid
            // and the insights are real data.
            if entry.isRoyal {
                infoColumn
            } else {
                Link(destination: DiPoSharedConfig.upgradeRoyalURL) {
                    infoColumn
                }
                // Strip the default Link tint so the widget colors stay
                // intact — without this every Text inside picks up the
                // accent color and the layout looks like one giant button.
                .buttonStyle(.plain)
            }
            Divider()
                .padding(.vertical, 10)
            quickAddColumn
                // Quick Add column is narrower than the info column.
                // Previously 50/50 which under-served the "how much have
                // I spent" question. ~38% gives the button enough hit area
                // without dominating.
                .frame(width: 110)
        }
        .containerBackground(for: .widget) {
            // Adaptive gradient — switches between a soft mint (light
            // mode) and a tinted dark (dark mode) so text contrast stays
            // readable regardless of system appearance. Mirrors the
            // app's `AppTheme.bg` ↔ wallpaper relationship.
            WidgetTheme.backgroundGradient(for: colorScheme)
        }
    }

    // MARK: Info column (left)

    /// The expense headline is always shown. The footer underneath swaps
    /// between income (free) and the Royal insights row. Both occupy the
    /// same vertical space so the layout doesn't reflow on upgrade.
    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row: card icon + "Pengeluaran" / "Expenses".
            HStack(spacing: 6) {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(entry.labelExpenses)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if entry.isRoyal {
                    // Tiny Royal badge so the upgraded state is obvious at
                    // a glance — and so a user looking at someone else's
                    // widget can spot the premium feature.
                    Image(systemName: "crown.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(red: 0.66, green: 0.55, blue: 0.98))
                }
            }

            Text(entry.expensesFormatted)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text(entry.monthLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if entry.isRoyal {
                royalInsights
            } else {
                lockedInsightsTeaser
            }
        }
        .padding(.leading, 14)
        .padding(.vertical, 12)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Free-tier Smart Insights teaser. The goal is curiosity, not coercion:
    /// we show the SHAPE of the insights (icons, labels) so the user can
    /// see what's there to unlock, but redact the actual values. Tapping
    /// anywhere on this column opens the paywall (wired up at body-level).
    ///
    /// Psychology cues used:
    ///   - Sparkles + crown badge → signals "premium content"
    ///   - `.redacted(reason: .placeholder)` on the numbers → users see the
    ///     visual structure but can't read the actual data ⇒ curiosity gap
    ///   - Real-looking sample values inside the redaction so the bars are
    ///     proportional to actual insights (not flat empty boxes)
    ///   - Subtle "Upgrade Royal →" affordance underneath so the action is
    ///     obvious without being shouty
    private var lockedInsightsTeaser: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Header row — labelled "Smart Insights" with a tiny lock,
            // matching the Royal layout's metric icons so the substitution
            // is visually consistent.
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(red: 0.66, green: 0.55, blue: 0.98))
                Text("Smart Insights")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }

            // Redacted preview rows. We render REAL-LOOKING values so the
            // redaction skeleton has proportions, not generic flat bars.
            // The placeholders are localized-ish ("Food & Drinks" works
            // in both EN + ID) so language switch doesn't break visuals.
            Group {
                HStack(spacing: 4) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                    Text("Food & Drinks (100%)")
                        .font(.system(size: 9, weight: .semibold))
                }
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 8))
                        .foregroundStyle(.blue)
                    Text("Rp 351.800 / week")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .redacted(reason: .placeholder)

            // Upgrade CTA. Keep it small + colored so it reads as
            // "tappable hint" instead of "marketing banner". The whole
            // column is the tap target (see body) — this line is just the
            // affordance label.
            HStack(spacing: 3) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("Upgrade Royal")
                    .font(.system(size: 10, weight: .bold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color(red: 0.66, green: 0.55, blue: 0.98))
            .padding(.top, 2)
        }
    }

    /// Royal footer: two rows of insights. We trade visual density for
    /// information here — Royal users opted in to "show me more numbers"
    /// when they paid, so denser layout matches expectation. If either
    /// metric is empty (e.g. no spend yet this month), we hide it rather
    /// than show "—" which would look broken.
    private var royalInsights: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !entry.topCategoryLabel.isEmpty && !entry.topCategoryFormatted.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("\(entry.labelTopCategory) \(entry.topCategoryLabel)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("(\(entry.topCategoryPercent)%)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            if !entry.weeklyAvgFormatted.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 9))
                        .foregroundStyle(.blue)
                    Text(entry.weeklyAvgFormatted)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("/ \(entry.labelWeeklyAvg)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
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
                        .fill(Color.green)
                        .frame(width: 44, height: 44)
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
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
        .description("Pengeluaran bulan ini + Tambah Transaksi cepat.")
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
    monthLabel:        "Mei 2026",
    isRoyal:           false,
    topCategoryLabel:  "",
    topCategoryFormatted: "",
    topCategoryPercent: 0,
    weeklyAvgFormatted: "",
    labelExpenses:    "Pengeluaran",
    labelIncome:      "Pemasukan",
    labelQuickAdd:    "Tambah\nTransaksi",
    labelTopCategory: "Top",
    labelWeeklyAvg:   "Rata-rata mingguan",
    isPlaceholder:    false
)

private let sampleRoyalEntry = MonthlyExpensesEntry(
    date: .now,
    expensesFormatted: "Rp 703.600",
    incomeFormatted:   "Rp 10.000.000",
    monthLabel:        "Mei 2026",
    isRoyal:           true,
    topCategoryLabel:  "Food & Drinks",
    topCategoryFormatted: "Rp 703.600",
    topCategoryPercent: 100,
    weeklyAvgFormatted: "Rp 351.800",
    labelExpenses:    "Pengeluaran",
    labelIncome:      "Pemasukan",
    labelQuickAdd:    "Tambah\nTransaksi",
    labelTopCategory: "Top",
    labelWeeklyAvg:   "Rata-rata mingguan",
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
