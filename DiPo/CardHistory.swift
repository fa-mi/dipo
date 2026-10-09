import SwiftUI
import SwiftData

// MARK: - A credit card's own transactions
//
// The card tile on Debts & Credits says what is owed and offers "Log a
// purchase", but the purchase then went nowhere you could see. Home lists the
// card picked in its carousel (here the credit card is the last of ten), and
// this screen listed nothing. Logging Rp 470.000 moved "Owed" from
// Rp 8.030.000 to Rp 8.500.000 with no row to check it against.
//
// The latest few sit under the card; the rest are one tap away. Each row opens
// the usual transaction detail, so a wrong entry can be fixed or deleted here.

enum CardHistory {
    struct Day: Identifiable {
        let id: Date
        let label: String
        let rows: [TxRecord]
    }

    /// Newest first, grouped by day. `limit` keeps only the latest rows.
    static func days(_ txs: [TxRecord], limit: Int? = nil, now: Date = .now,
                     calendar: Calendar = .current) -> [Day] {
        let sorted = txs.sorted { $0.date > $1.date }
        let rows = limit.map { Array(sorted.prefix($0)) } ?? sorted
        var order: [Date] = []
        var byDay: [Date: [TxRecord]] = [:]
        for tx in rows {
            let day = calendar.startOfDay(for: tx.date)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(tx)
        }
        return order.map { Day(id: $0, label: label(for: $0, now: now, calendar: calendar), rows: byDay[$0] ?? []) }
    }

    static func label(for day: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return loc("common.today") }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) {
            return loc("common.yesterday")
        }
        // The year only when it isn't this one.
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        return DateFormatterCache.template(sameYear ? "EEEEdMMM" : "EEEEdMMMy").string(from: day)
    }
}

/// Day headers with their rows. Tapping a row hands it back.
struct CardHistoryList: View {
    let days: [CardHistory.Day]
    let onTap: (TxRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(days) { day in
                VStack(alignment: .leading, spacing: 8) {
                    Text(day.label)
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                    ForEach(day.rows) { tx in
                        Button {
                            HapticManager.shared.tap()
                            onTap(tx)
                        } label: {
                            TxRow(tx: tx, animateEntrance: false)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Under a credit card on Debts & Credits: its latest transactions.
struct CardHistorySection: View {
    let card: BankCard
    static let preview = 3

    @State private var selectedTx: TxRecord? = nil
    @State private var showAll = false

    var body: some View {
        let txs = card.transactions
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(loc("cc.history"))
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                if txs.count > Self.preview {
                    Button {
                        HapticManager.shared.tap()
                        showAll = true
                    } label: {
                        Text(String(format: loc("cc.history_all"), txs.count))
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            if txs.isEmpty {
                Text(loc("cc.history_empty"))
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
            } else {
                CardHistoryList(days: CardHistory.days(txs, limit: Self.preview)) { selectedTx = $0 }
            }
        }
        .sheet(item: $selectedTx) { tx in
            TransactionDetailSheet(tx: tx)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showAll) {
            CardHistorySheet(card: card)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }
}

/// Every transaction on one card, newest first.
struct CardHistorySheet: View {
    let card: BankCard
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTx: TxRecord? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if card.transactions.isEmpty {
                            Text(loc("cc.history_empty"))
                                .font(.system(.footnote))
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else {
                            CardHistoryList(days: CardHistory.days(card.transactions)) { selectedTx = $0 }
                                .padding(.vertical, 12)
                        }
                    }
                    .padding(.horizontal, 22)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(String(format: loc("cc.history_title"), card.pickerLabel))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.close")) { HapticManager.shared.tap(); dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
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
