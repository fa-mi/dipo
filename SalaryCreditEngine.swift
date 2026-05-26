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

            // Already credited this month?
            if schedule.lastCreditedMonth == currentMonth &&
               schedule.lastCreditedYear == currentYear { continue }

            // What is the actual pay date for this month?
            let payDate = SalaryDateEngine.actualPayDate(
                dayOfMonth: schedule.dayOfMonth,
                month: currentMonth,
                year: currentYear
            )
            let payDay = cal.startOfDay(for: payDate)

            // Only credit on or after the actual pay date
            guard today >= payDay else { continue }

            // Find the target card — must be explicitly linked, no silent fallback
            guard let cardID = schedule.cardID,
                  let targetCard = cards.first(where: { $0.id == cardID }) else {
                print("[SalaryCreditEngine] Skipping \(schedule.label) — no card linked")
                continue
            }

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

            // NOTE: Do NOT touch card.balance — balance is computed from transactions.
            // Adding to both would double-count the salary.

            // Mark as credited for this month
            schedule.lastCreditedMonth = currentMonth
            schedule.lastCreditedYear  = currentYear

            didCredit = true

            print("[SalaryCreditEngine] Credited \(schedule.currency) \(schedule.amount) for \(schedule.label) to card \(targetCard.holderName)")
        }

        if didCredit {
            try? context.save()
        }
    }
}
