import SwiftUI

// MARK: - Home: one reminder line
//
// Home used to say what needed doing in two places: DiPo's row (his face in a
// bordered card, then a bill, payday or the evening check-in) and, under it,
// the attention slot (a negative balance, setting up the salary, a detected
// bill, a pinned goal), each a card of its own with a "3 more" row below.
// Now it is one line, under the period's figures: a dot in the reminder's
// colour, the words, and "1/3 ›" to step to the next. Ask DiPo moved to the
// header, so the line no longer needs his face to be tapped.

/// One thing Home's reminder line can say.
struct HomeReminder: Identifiable {
    /// The dot's colour says how much it matters.
    enum Tone: Equatable {
        /// The balance is below zero. The only red on the line.
        case trouble
        /// Something wants doing soon: a bill, the evening check-in, unread news.
        case due
        /// Money is about to come in: payday.
        case moneyIn
        /// Worth knowing, nothing to do: a streak, a goal, an idea.
        case quiet
    }

    let id: String
    let title: String
    var detail: String? = nil
    let tone: Tone
    /// What a tap does. Nil when there is nowhere to go.
    var action: (() -> Void)? = nil
}

enum HomeReminders {
    /// Each of DiPo's reminders in the line's colours.
    static func tone(for action: DiPoNudge.Action) -> HomeReminder.Tone {
        switch action {
        case .notifications, .checkIn, .bills, .assetCheck:
            return .due
        case .salary:
            return .moneyIn
        case .streak, .interestGuess, .interestTip, .customInterestTip:
            return .quiet
        }
    }

    /// Green only for money coming in, red only for trouble, orange for what
    /// is due, grey for the rest.
    static func color(for tone: HomeReminder.Tone) -> Color {
        switch tone {
        case .trouble: return AppTheme.red
        case .due:     return AppTheme.orange
        case .moneyIn: return AppTheme.accent
        case .quiet:   return AppTheme.textSecondary
        }
    }

    /// The order the line steps through: trouble first, then what DiPo has to
    /// say, then the rest (setting up, a detected bill, a pinned goal).
    static func ordered(first: [HomeReminder], dipo: [HomeReminder], last: [HomeReminder]) -> [HomeReminder] {
        first.filter { $0.tone == .trouble }
            + first.filter { $0.tone != .trouble }
            + dipo
            + last
    }

    /// A detected repeat spend in a few words: "≈ Rp 350.000 · next one in
    /// about 5 days" for a bill, an average per visit for a habit.
    static func recurringDetail(_ pattern: SmartBudgetManager.RecurringPattern, now: Date = .now) -> String {
        let amount = CurrencyManager.shared.formatted(pattern.amount, currency: pattern.currency)
        guard pattern.kind == .bill else {
            return String(format: loc("recurring.detail_habit"), amount)
        }
        let days = max(Calendar.current.dateComponents([.day], from: now, to: pattern.nextExpected).day ?? 0, 0)
        return days == 0
            ? String(format: loc("recurring.detail_today"), amount)
            : String(format: loc("recurring.detail"), amount, days)
    }

    /// The evidence behind a detected pattern, stated plainly: how many times,
    /// over what span. A guess that can't be traced to its sightings is
    /// impossible to argue with when it's wrong.
    static func recurringEvidence(_ pattern: SmartBudgetManager.RecurringPattern) -> String {
        let df = DateFormatter()
        df.locale = LanguageManager.shared.currentLocale
        df.setLocalizedDateFormatFromTemplate("d MMM")
        let first = df.string(from: pattern.firstDate)
        let last = df.string(from: pattern.lastDate)
        return String(format: loc("recurring.evidence"), pattern.occurrences,
                      first == last ? last : "\(first) – \(last)")
    }

    /// A detected bill is due; a habit is only worth knowing.
    static func recurringTone(_ pattern: SmartBudgetManager.RecurringPattern) -> HomeReminder.Tone {
        pattern.kind == .bill ? .due : .quiet
    }
}

/// The line itself: a hairline above and below, a dot, the words, and the
/// pager when there is more than one thing to say. With nothing to say it
/// shows how today stands ("Today is logged"), or nothing at all.
struct HomeReminderLine: View {
    let reminders: [HomeReminder]
    /// Today in a few words, when there is no reminder.
    var status: String? = nil

    @State private var page = 0
    private var current: HomeReminder? {
        reminders.isEmpty ? nil : reminders[min(page, reminders.count - 1)]
    }

    var body: some View {
        Group {
            if let current {
                line(current)
            } else if let status {
                Text(status)
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
        }
        .overlay(alignment: .top) { if current != nil || status != nil { hairline } }
        .overlay(alignment: .bottom) { if current != nil || status != nil { hairline } }
        .onChange(of: reminders.map(\.id)) { _, _ in page = 0 }
        .animation(.spring(response: 0.35), value: current?.id)
    }

    private var hairline: some View {
        Rectangle().fill(AppTheme.cardMid).frame(height: 1)
    }

    private func line(_ r: HomeReminder) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(HomeReminders.color(for: r.tone))
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 1 }
                .accessibilityHidden(true)

            Button {
                guard let action = r.action else { return }
                HapticManager.shared.tap()
                action()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title)
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(r.tone == .trouble ? AppTheme.red : AppTheme.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = r.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(.caption))
                                .foregroundStyle(AppTheme.textSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if r.action != nil && reminders.count < 2 {
                        Image(systemName: "chevron.right")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(r.action == nil)
            .id(r.id)
            .transition(.opacity)
            .accessibilityHint(r.action == nil ? "" : loc("dipo.a11y_open"))

            if reminders.count > 1 {
                Button {
                    HapticManager.shared.tap()
                    withAnimation(.spring(response: 0.3)) { page = (page + 1) % reminders.count }
                } label: {
                    Text(verbatim: "\(min(page, reminders.count - 1) + 1)/\(reminders.count) \u{203A}")
                        .font(.system(.caption, weight: .semibold).monospacedDigit())
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(minWidth: 44, minHeight: 32, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc("dipo.next"))
            }
        }
        .padding(.vertical, 12)
    }
}
