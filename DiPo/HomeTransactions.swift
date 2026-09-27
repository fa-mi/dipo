import SwiftUI
import SwiftData

// Moved out of HomeView.swift, unchanged. The filterable transaction list on Home.

// MARK: - Quick Actions

struct CategoryFilterBar: View {
    @Binding var selectedFilter: TxCategory?

    // Derive directly from TxCategory so labels auto-localize.
    // Only the subset relevant to expense/home-screen filtering.
    private let filterCategories: [TxCategory] = [
        .shopping, .food, .travel, .bills,
        .transport, .health, .commitment, .investment, .debtPayment, .salary, .other
    ]

    var body: some View {
        // Spread the filters when they fit, scroll them when they do not.
        // This replaced an `idiom == .pad` check, which reported `.phone` on
        // both of the Duo's panels and so never took the spread branch on a
        // 626 pt display that had ample room for it.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(filterCategories, id: \.self) { cat in
                    filterButton(cat).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 32)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(filterCategories, id: \.self) { cat in
                        filterButton(cat).frame(width: 64)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func filterButton(_ cat: TxCategory) -> some View {
        let isActive = selectedFilter == cat
        Button {
            HapticManager.shared.tap()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedFilter = isActive ? nil : cat
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .fill(isActive ? cat.color.opacity(0.18) : AppTheme.cardDark)
                        .frame(width: 58, height: 58)
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.lg)
                            .stroke(isActive ? cat.color.opacity(0.6) : Color.clear, lineWidth: 1.5))
                    Image(systemName: cat.icon)
                        .font(.system(.title2))
                        .foregroundStyle(isActive ? cat.color : AppTheme.textPrimary)
                        .scaleEffect(isActive ? 1.1 : 1)
                }
                Text(cat.shortLabel)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? cat.color : AppTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(ScaleButtonStyle())
    }
}


// MARK: - Transaction Section (grouped by date)

struct TransactionSection: View {
    let transactions: [TxRecord]       // per-card transactions
    let cards: [BankCard]
    var categoryFilter: TxCategory? = nil
    var onClearFilter: (() -> Void)? = nil
    /// The card every row here belongs to. Home feeds this section a single
    /// card's transactions, so the owner is known up front — it used to be
    /// recovered by scanning every card's entire history instead.
    var sourceCard: BankCard? = nil
    /// Category filtering only looks at the current month; this is how the
    /// user reaches anything older.
    var onOpenSearch: (() -> Void)? = nil
    @State private var showAll        = false
    @State private var selectedTx: TxRecord? = nil
    @State private var pendingDelete: TxRecord? = nil
    @Environment(\.modelContext) private var context


    /// Everything the list needs, derived in ONE pass.
    ///
    /// This was three computed properties — `filtered`, `grouped` and
    /// `cardLookup` — and `body` reads all three. Each one re-derived from
    /// scratch on every body evaluation, so a single tap on "See more" sorted
    /// the transaction list twice and rebuilt a `[UUID: BankCard]` map over
    /// every card's entire history. That is what made repeated taps stall
    /// scrolling: the work was proportional to total transactions, and it ran
    /// again for each tap.
    ///
    /// The map is gone entirely — Home passes `sourceCard` in, because every
    /// row here belongs to the one selected card.
    private struct Derived {
        var groups: [(key: String, date: Date, txs: [TxRecord], total: Double)] = []
        /// True when widening to the 7-day window would actually reveal
        /// something. Without this the toggle offered a wider view that turned
        /// out to be identical.
        var hasMoreInWeek = false
        /// The card HAS transactions, they just fall outside the window on
        /// screen. Distinguishes "you haven't spent in three days" from "this
        /// card has no history", which look identical otherwise and make the
        /// first one read as lost data.
        var hasOlderOutsideWindow = false
    }

    private var derived: Derived {
        let cal = Calendar.current

        // Unfiltered, Home shows the most RECENT activity across all time.
        // It deliberately does NOT month-scope that default view: doing so left
        // Home looking empty on the 1st of a new month even when the card had
        // plenty of recent history.
        //
        // A category filter is the exception, and scoping it to the current
        // month is the point — "what did I spend on food this month" is the
        // question being asked. Anything older is Search's job, and the empty
        // state below says so rather than leaving a blank panel.
        let now = Date()
        let today = cal.startOfDay(for: now)
        let sorted = transactions.sorted { $0.date > $1.date }

        var out = Derived()
        var rows: [TxRecord]

        if let filter = categoryFilter {
            rows = sorted.filter {
                $0.category == filter && cal.isDate($0.date, equalTo: now, toGranularity: .month)
            }
        } else {
            // Rolling windows, counted in calendar days INCLUSIVE of today:
            // 3 days = today plus the two before it, 7 days = today plus six.
            // The list used to be capped by row count instead, which meant the
            // period it covered changed with how busy the days happened to be.
            let weekCutoff = cal.date(byAdding: .day, value: -6, to: today) ?? .distantPast
            let dayCutoff  = cal.date(byAdding: .day, value: -2, to: today) ?? .distantPast
            let inWeek = sorted.filter { $0.date >= weekCutoff }
            let inDays = inWeek.filter { $0.date >= dayCutoff }
            out.hasMoreInWeek = inWeek.count > inDays.count
            rows = showAll ? inWeek : inDays
            out.hasOlderOutsideWindow = sorted.count > rows.count
        }

        guard !rows.isEmpty else { return out }

        // Real per-day totals come from ALL matching rows, so a day header
        // keeps showing the true amount while "See more" only reveals more
        // detail rows beneath it.
        var fullByDay: [Date: Double] = [:]
        for tx in rows { fullByDay[cal.startOfDay(for: tx.date), default: 0] += tx.amount }

        var byDay: [Date: [TxRecord]] = [:]
        var order: [Date] = []
        for tx in rows {
            let day = cal.startOfDay(for: tx.date)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(tx)
        }

        // `rows` is already newest-first, so insertion order IS date order and
        // both the day sort and the per-day sort the old code ran are redundant.
        out.groups = order.map { day in
            let label: String
            if cal.isDateInToday(day)          { label = loc("common.today") }
            else if cal.isDateInYesterday(day) { label = loc("common.yesterday") }
            else { label = DateFormatterCache.template("EEEEdMMM").string(from: day) }
            return (key: label, date: day, txs: byDay[day] ?? [], total: fullByDay[day] ?? 0)
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            // Derived once per body pass and read from here down. Reading the
            // computed property repeatedly is what the old code did, and each
            // read redid the whole derivation.
            let d = derived

            HStack {
                Text(loc("home.transactions"))
                    .font(.system(.body, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Spacer()
                HStack(spacing: 12) {
                    // Names the window it switches to, rather than "See more"
                    // — the list is bounded by days now, so how far back it
                    // reaches is the thing worth stating. Hidden entirely when
                    // widening would reveal nothing, and while a category
                    // filter is on, since that already spans the whole month.
                    if d.hasMoreInWeek {
                        Button {
                            HapticManager.shared.tap()
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showAll.toggle() }
                        } label: {
                            Text(showAll ? loc("home.window_3days") : loc("home.window_week"))
                                .font(.system(.footnote, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }
            }
            .padding(.bottom, 8)

            // Active filter chip with clear button
            if let filter = categoryFilter {
                HStack(spacing: 8) {
                    Image(systemName: filter.icon).font(.system(.caption)).foregroundStyle(filter.color)
                    Text(String(format: loc("home.filtered_month"), filter.displayLabel))
                        .font(.system(.caption, weight: .medium)).foregroundStyle(filter.color)
                    Spacer()
                    Button {
                        HapticManager.shared.tap()
                        onClearFilter?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(.callout)).foregroundStyle(AppTheme.textSecondary)
                    }
.accessibilityLabel(loc("a11y.clear_filter"))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(filter.color.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).stroke(filter.color.opacity(0.2), lineWidth: 1))
                .padding(.bottom, 10)
                .transition(.opacity)
            }

            if d.groups.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: categoryFilter != nil ? "line.3.horizontal.decrease.circle" : "tray")
                        .font(.system(.largeTitle)).foregroundStyle(AppTheme.textSecondary)
                    Text(categoryFilter != nil
                         ? String(format: loc("home.no_cat_tx_month"), categoryFilter!.displayLabel)
                         : (d.hasOlderOutsideWindow
                            ? loc("home.quiet_window")
                            : loc("home.no_tx_card")))
                        .font(.system(.subheadline)).foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                    Text(categoryFilter != nil
                         ? loc("home.older_in_search")
                         : (d.hasOlderOutsideWindow
                            ? loc("home.quiet_window_hint")
                            : loc("home.tap_plus")))
                        .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                        .multilineTextAlignment(.center)

                    // The filter only looks at this month, so an empty result
                    // is a range problem, not a missing-data problem. Hand the
                    // user the tool that does search the full history.
                    if categoryFilter != nil || d.hasOlderOutsideWindow, let onOpenSearch {
                        Button {
                            onOpenSearch()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").font(.system(.subheadline))
                                Text(loc("home.search_older")).font(.system(.footnote, weight: .semibold))
                            }
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(AppTheme.accent.opacity(0.12), in: Capsule())
                            .overlay(Capsule().stroke(AppTheme.accent.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .padding(.top, 4)
                    }

                    // Direct CTA — without this the user sees the empty
                    // state but has to know that the central "+" tab opens
                    // Add Transaction. Surfacing the action inline removes
                    // that guesswork and matches the pattern used by Wishlist
                    // / Debt empty states.
                    if categoryFilter == nil, !d.hasOlderOutsideWindow {
                        Button {
                            HapticManager.shared.tap()
                            NotificationCenter.default.post(name: .requestOpenAddTransaction, object: nil)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill").font(.system(.subheadline))
                                Text(loc("home.add_first_tx")).font(.system(.footnote, weight: .semibold))
                            }
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(AppTheme.accent.opacity(0.12), in: Capsule())
                            .overlay(Capsule().stroke(AppTheme.accent.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 20) {
                    ForEach(d.groups, id: \.key) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            // Date header with the REAL daily total (all txs that
                            // day, not just the visible rows).
                            let dayTotal = group.total
                            HStack {
                                Text(group.key)
                                    .font(.system(.footnote, weight: .semibold))
                                    .foregroundStyle(AppTheme.textSecondary)
                                Spacer()
                                Text(dayTotal >= 0
                                     ? "+\(CurrencyManager.shared.formatted(dayTotal, currency: group.txs.first?.currency ?? CurrencyManager.shared.preferredCurrency))"
                                     : CurrencyManager.shared.formatted(dayTotal, currency: group.txs.first?.currency ?? CurrencyManager.shared.preferredCurrency))
                                    .font(.system(.caption, weight: .medium))
                                    .foregroundStyle(dayTotal >= 0 ? AppTheme.accent.opacity(0.7) : AppTheme.red.opacity(0.7))
                            }

                            VStack(spacing: 10) {
                                ForEach(Array(group.txs.enumerated()), id: \.element.id) { i, tx in
                                    SwipeToDeleteRow(
                                        onTap: { selectedTx = tx },
                                        onDelete: { pendingDelete = tx }
                                    ) {
                                        TxRow(tx: tx, sourceCard: sourceCard ?? cards.first, showCard: cards.count > 1)
                                    }
                                    // Rows used to vanish instantly, which reads
                                    // as a glitch — the eye can't tell a deleted
                                    // row from a mis-rendered list. Collapsing
                                    // out shows WHICH row left.
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .top)),
                                        removal: .scale(scale: 0.92).combined(with: .opacity)))
                                    // A hairline between rows of the same day,
                                    // starting where the name does — 44pt of
                                    // avatar plus the row's 14pt gap — so it
                                    // separates entries without drawing a table
                                    // rule across the card. The last row of a day
                                    // has none: the next day's header is the
                                    // break there, and a line above it would read
                                    // as belonging to that header.
                                    if i < group.txs.count - 1 {
                                        Rectangle()
                                            .fill(AppTheme.cardMid.opacity(0.6))
                                            .frame(height: 1)
                                            .padding(.leading, 58)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $pendingDelete) { tx in
            DeleteTransactionSheet(
                tx: tx,
                card: sourceCard ?? cards.first,
                onConfirm: {
                    pendingDelete = nil
                    // Let the sheet start leaving before the row collapses, so
                    // the removal animation plays where the user can see it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            deleteTransactionWithGoalRollback(tx, context: context)
                        }
                        try? context.save()
                        HapticManager.shared.success()
                    }
                },
                onCancel: { pendingDelete = nil })
            .preferredColorScheme(appColorScheme())
        }
        .sheet(item: $selectedTx) { tx in
            TransactionDetailSheet(tx: tx)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }
}

// MARK: - Swipe-to-Delete Row

/// Reusable swipe-to-delete wrapper for rows rendered inside a `ScrollView`
/// (where SwiftUI's native `List.swipeActions` isn't available). Swipe a row
/// left to reveal a Delete button; tap it to fire `onDelete`. Tapping the row
/// while closed runs `onTap` (open detail); tapping while open just closes it.
///
/// The drag only engages on horizontal-dominant movement, so vertical
/// scrolling stays smooth. Pairs with a single confirmation dialog at the list
/// level so an accidental swipe can't delete financial data in one motion.
// Swipe-to-delete row modeled on the iOS Mail / Phone (Calls) behavior:
//   • the row tracks the finger 1:1 while dragging (no animation lag),
//   • the red action STRETCHES with the swipe and its icon nudges,
//   • a FULL swipe past `fullSwipeThreshold` deletes on release (with a
//     confirming haptic the moment you cross it),
//   • a short swipe snaps open to a fixed Delete button; tapping it deletes,
//   • everything springs on release; vertical drags still scroll the list.
struct SwipeToDeleteRow<Content: View>: View {
    var onTap: () -> Void
    var onDelete: () -> Void
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0
    @State private var gestureStart: CGFloat? = nil
    @State private var crossedFull = false

    private let actionWidth: CGFloat = 88
    private let openThreshold: CGFloat = 44
    private let fullSwipeThreshold: CGFloat = 230   // drag this far → delete on release

    /// Positive width of the red action currently revealed.
    private var revealed: CGFloat { max(0, -offset) }
    private var isFullSwipe: Bool { revealed >= fullSwipeThreshold }
    /// 0→1 as the swipe grows to the resting open width. Drives the circular
    /// delete button's spring-in (scale + fade), iOS Notes-style.
    private var revealProgress: CGFloat { min(revealed / actionWidth, 1) }

    var body: some View {
        ZStack(alignment: .trailing) {
            // iOS-style delete: a single round red button with a "Delete"
            // label, sitting on the PLAIN list background — no red wash/slab
            // behind it. It springs in (scale + fade) as the row slides and
            // pops slightly larger once you cross the full-swipe threshold. A
            // long swipe still deletes on release; a short swipe rests open so
            // you can tap the button.
            if revealed > 0 {
                Button {
                    HapticManager.shared.tap()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { offset = 0 }
                    onDelete()
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .fill(AppTheme.redFill)
                                .frame(width: 44, height: 44)
                            Image(systemName: "trash.fill")
                                .font(.system(.callout, weight: .semibold))
                                .foregroundStyle(AppTheme.onVividFill)
                        }
                        Text(loc("common.delete"))
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(AppTheme.red)
                    }
                    .scaleEffect(isFullSwipe ? 1.15 : max(revealProgress, 0.4))
                    .opacity(min(Double(revealProgress) * 1.7, 1))
                    .animation(.spring(response: 0.32, dampingFraction: 0.55), value: isFullSwipe)
                }
                .buttonStyle(.plain)
                .frame(width: min(revealed, actionWidth))
            }

            content
                // Opaque so the red action is hidden when closed — and the SAME
                // colour as the card the list now sits in. It was `AppTheme.bg`,
                // which on a white card painted a grey slab behind every row.
                .background(AppTheme.cardDark)
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 16)
                        .onChanged { value in
                            // Engage only on horizontal-dominant drags (or when
                            // already open) so vertical scrolling stays smooth.
                            if gestureStart == nil {
                                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                                gestureStart = offset
                            }
                            guard let start = gestureStart else { return }
                            var next = start + value.translation.width
                            if next > 0 { next = 0 }                       // no right-swipe
                            if next < -actionWidth {                        // rubber-band past the button
                                next = -actionWidth - (-(next) - actionWidth) * 0.45
                            }
                            offset = next
                            // Confirming haptic the instant you cross into full-swipe.
                            if revealed >= fullSwipeThreshold, !crossedFull {
                                crossedFull = true; HapticManager.shared.tap()
                            } else if revealed < fullSwipeThreshold, crossedFull {
                                crossedFull = false
                            }
                        }
                        .onEnded { _ in
                            gestureStart = nil
                            let didFull = revealed >= fullSwipeThreshold
                            crossedFull = false
                            if didFull {
                                HapticManager.shared.warning()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 }
                                onDelete()
                            } else {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                                    offset = revealed >= openThreshold ? -actionWidth : 0
                                }
                            }
                        }
                )
                .onTapGesture {
                    if offset != 0 {
                        withAnimation(.spring(response: 0.3)) { offset = 0 }
                    } else {
                        onTap()
                    }
                }
        }
    }
}

struct TxRow: View {
    let tx: TxRecord
    var sourceCard: BankCard? = nil
    var showCard: Bool = false
    /// Entrance animation is nice on the short Home list, but in a long
    /// scrolling history it re-fires on EVERY row as it scrolls into view
    /// (LazyVStack re-runs `onAppear`), stacking dozens of springs → jank.
    /// Long lists pass `false`.
    var animateEntrance: Bool = true
    @State private var appeared = false

    /// Reused across rows — allocating a DateFormatter per row (per render) was
    /// a measurable scroll cost with a long history.
    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter(); df.dateStyle = .none; df.timeStyle = .short
        return df
    }()
    private var timeOnly: String {
        let f = TxRow.timeFormatter
        let loc = LanguageManager.shared.currentLocale
        if f.locale != loc { f.locale = loc }
        return f.string(from: tx.date)
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tx.displayIconBg).frame(width: 44, height: 44)
                Text(tx.icon)
                    .font(.system(size: tx.icon.count == 1 ? 16 : 18)).foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // Two lines at most. A long name used to wrap to three and
                    // squeeze the badge beside it until the badge wrapped too —
                    // "Salary" came out as "Salar / y".
                    Text(tx.name)
                        .font(.system(.subheadline, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(2)
                    // Subtype badge — small inline marker showing this tx is
                    // a refund or transfer. Without this, users can't tell
                    // at a glance which tx is treated specially by the
                    // engine; they'd have to tap each one to check. Hidden
                    // for .normal which is the default and would just add
                    // noise to most rows.
                    if tx.txSubtype != .normal {
                        HStack(spacing: 3) {
                            Image(systemName: tx.txSubtype.icon)
                                .font(.system(.caption2, weight: .semibold)).imageScale(.small)
                            Text(tx.txSubtype.displayLabel)
                                .font(.system(.caption2, weight: .bold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(AppTheme.orange)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(AppTheme.orange.opacity(0.15), in: Capsule())
                        .fixedSize()
                    }
                    // Auto-posted marker — a recurring charge or salary credit
                    // the engine created. Answers "where did my balance go?"
                    // right in the list instead of looking like a manual entry.
                    if tx.notes == "tx.note.recurring_auto" || tx.notes == "tx.note.salary_auto" {
                        let isSalary = tx.notes == "tx.note.salary_auto"
                        HStack(spacing: 3) {
                            Image(systemName: isSalary ? "banknote" : "arrow.clockwise")
                                .font(.system(.caption2, weight: .semibold)).imageScale(.small)
                            Text(loc(isSalary ? "tx.badge.auto_salary" : "tx.badge.auto_recurring"))
                                .font(.system(.caption2, weight: .bold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(isSalary ? AppTheme.accent : AppTheme.blue)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background((isSalary ? AppTheme.accent : AppTheme.blue).opacity(0.13), in: Capsule())
                        // A label, not a column: it keeps its width and the name
                        // beside it gives way instead.
                        .fixedSize()
                    }
                }
                HStack(spacing: 6) {
                    Text(timeOnly)
                        .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                    // Source of fund badge — shown when user has multiple cards
                    if showCard, let card = sourceCard {
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(LinearGradient(
                                    colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                                    startPoint: .leading, endPoint: .trailing))
                                .frame(width: 12, height: 8)
                            Text("••\(card.cardNumber.suffix(2))")
                                .font(.system(.caption2, weight: .medium))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(AppTheme.cardMid, in: Capsule())
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(tx.amount >= 0
                     ? "+\(CurrencyManager.shared.formatted(tx.amount, currency: tx.currency))"
                     : CurrencyManager.shared.formatted(tx.amount, currency: tx.currency))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(tx.amount >= 0 ? AppTheme.green : AppTheme.textPrimary)
                Text(tx.displayType)
                    .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
            }
        }
        .opacity(animateEntrance ? (appeared ? 1 : 0) : 1)
        .offset(x: animateEntrance ? (appeared ? 0 : 20) : 0)
        .onAppear {
            guard animateEntrance, !appeared else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { appeared = true }
        }
    }
}
