import SwiftUI
import SwiftData

// MARK: - Salary Auto-Credit Engine
// Runs on every app launch and foreground resume.
// For each active salary schedule, checks if today is payday
// and credits the salary to the first available card if not already done this month.

struct SalaryCreditEngine {

    /// Call this from RootView whenever the app becomes active.
    /// Pass the modelContext so we can read and write SwiftData.
    @MainActor
    static func processIfNeeded(context: ModelContext) {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        let currentMonth = cal.component(.month, from: today)
        let currentYear  = cal.component(.year,  from: today)

        // Fetch all active salary schedules
        let scheduleDesc = FetchDescriptor<SalarySchedule>()
        guard let schedules = try? context.fetch(scheduleDesc) else { return }

        // Fetch all cards (to credit to)
        let cardDesc = FetchDescriptor<BankCard>(sortBy: [SortDescriptor(\.sortOrder)])
        guard let cards = try? context.fetch(cardDesc), !cards.isEmpty else { return }

        var didCredit = false

        for schedule in schedules {
            guard schedule.isActive else { continue }
            // Respect the per-schedule auto-record toggle — when off, the
            // schedule is still shown for planning but no income tx is created.
            guard schedule.autoRecord else { continue }

            // Already credited this month?
            if schedule.lastCreditedMonth == currentMonth &&
               schedule.lastCreditedYear == currentYear { continue }

            // Find the target card — must be explicitly linked, no silent fallback
            guard let cardID = schedule.cardID,
                  let targetCard = cards.first(where: { $0.id == cardID }) else {
                print("[SalaryCreditEngine] Skipping \(schedule.label) — no card linked")
                continue
            }

            // ── Catch up on months the app wasn't opened ──────────────────
            // This used to credit ONLY the current month and then stamp
            // lastCredited, so a user who skipped two months lost those two
            // salaries permanently. Every downstream feature reads that as a
            // cycle with expenses and no income: false deficits, wrecked Smart
            // Score, nonsense budget ratios.
            //
            // Bounds that keep this safe:
            //   • never before the schedule was created (a new schedule must
            //     not invent a year of history)
            //   • never before the last credited month
            //   • at most 12 months, so a long-dormant install can't flood the
            //     ledger in one launch
            //   • each month still respects its own actual pay date
            for (m, y) in pendingMonths(for: schedule, currentMonth: currentMonth,
                                        currentYear: currentYear, cal: cal) {
                let payDate = SalaryDateEngine.actualPayDate(dayOfMonth: schedule.dayOfMonth,
                                                            month: m, year: y)
                guard today >= cal.startOfDay(for: payDate) else { continue }

            // Store the transaction in schedule.currency exactly as entered.
            // Display-time conversion is handled by liveTransactionBalance() in
            // BankCardHelpers.swift, which already converts each tx to the card's
            // currency before summing. Converting here would corrupt amounts for
            // schedules whose currency differs from the card (e.g. a USD freelance
            // salary on an IDR card — the user typed 250 meaning $250, not Rp 250).
            //
            // ⚠️ type/notes use stable keys, NOT loc(...) results. Translation happens
            // at display time — storing translated strings would freeze the language
            // at the moment of auto-credit, breaking the UI when the user later switches locale.
                let salaryTx = TxRecord(
                    name: "\(schedule.label) - Salary",
                    date: payDate,
                    amount: schedule.amount,
                    type: "tx.type.income",
                    icon: "S",
                    iconBgHex: "#1D9E75",
                    category: .salary,
                    currency: schedule.currency,
                    notes: "tx.note.salary_auto"
                )
                targetCard.transactions.append(salaryTx)

                // NOTE: Do NOT touch card.balance — balance is computed from
                // transactions. Adding to both would double-count the salary.

                // Stamp the month we just credited, not "now" — otherwise a
                // catch-up run would mark the whole gap as done after one month.
                schedule.lastCreditedMonth = m
                schedule.lastCreditedYear  = y
                didCredit = true

                print("[SalaryCreditEngine] Credited \(schedule.currency) \(schedule.amount) for \(schedule.label) (\(m)/\(y))")
            }
        }

        if didCredit {
            try? context.save()
        }
    }

    /// Months still owing a credit, oldest first. Empty when nothing is due.
    private static func pendingMonths(for schedule: SalarySchedule,
                                      currentMonth: Int, currentYear: Int,
                                      cal: Calendar) -> [(Int, Int)] {
        let createdM = cal.component(.month, from: schedule.createdAt)
        let createdY = cal.component(.year,  from: schedule.createdAt)

        // Start the month AFTER the last credit; if never credited, start at the
        // month the schedule was created.
        var startM: Int, startY: Int
        if schedule.lastCreditedYear > 0 {
            startM = schedule.lastCreditedMonth + 1
            startY = schedule.lastCreditedYear
            if startM > 12 { startM = 1; startY += 1 }
        } else {
            startM = createdM; startY = createdY
        }
        // Never earlier than creation.
        if startY < createdY || (startY == createdY && startM < createdM) {
            startM = createdM; startY = createdY
        }

        var out: [(Int, Int)] = []
        var m = startM, y = startY
        while (y < currentYear) || (y == currentYear && m <= currentMonth) {
            out.append((m, y))
            if out.count >= 12 { break }   // cap a long-dormant catch-up
            m += 1
            if m > 12 { m = 1; y += 1 }
        }
        return out
    }
}
