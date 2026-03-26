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

            // Find the target card
            // Prefer the card linked to this schedule, fallback to first card
            let targetCard: BankCard
            if let cardID = schedule.cardID,
               let linked = cards.first(where: { $0.id == cardID }) {
                targetCard = linked
            } else {
                targetCard = cards[0]
            }

            // Create the income transaction
            let salaryTx = TxRecord(
                name: "\(schedule.label) - Salary",
                date: payDate,
                amount: schedule.amount,
                type: "Income",
                icon: "S",
                iconBgHex: "#1D9E75",
                category: .transfer,
                currency: schedule.currency,
                notes: "Auto-credited on payday"
            )
            targetCard.transactions.append(salaryTx)

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
