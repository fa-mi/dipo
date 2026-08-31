import SwiftUI

// MARK: - Action Feedback
//
// A confirmation the user can actually read the RESULT from.
//
// The problem this solves: after saving a transaction the sheet just closed.
// Nothing said the data had changed, so people re-opened the list to check —
// or worse, saved twice. A bare "Success!" checkmark would fix the anxiety but
// waste the moment; the interesting information is WHAT changed.
//
// So the toast carries the actual figure and its category colour:
//     ✓  Rp 50.000 recorded
//        Food & Drinks · BRI ·· 0969
//
// Design rules:
//   • Appears at the TOP — the bottom belongs to the tab bar and the sheets
//     that slide from there; a toast fighting either reads as a bug.
//   • Auto-dismisses (2.4s), because a confirmation that needs dismissing is
//     just another task.
//   • Tap or swipe up to dismiss early — never traps the user.
//   • Springs in, fades out. Entry deserves personality; exit should get out
//     of the way.

@Observable
final class ActionFeedbackCenter {
    static let shared = ActionFeedbackCenter()
    private init() {}

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let detail: String?

        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    private(set) var current: Toast?
    private var dismissWork: DispatchWorkItem?

    /// A full-screen moment, not a toast. Held here rather than in the view that
    /// triggered it because the trigger never survives its own success: paying a
    /// debt off dismisses the payment sheet AND drops the debt card out of the
    /// list (it filters on `isActive`), so anything either of them presented
    /// would be torn down before it could animate. This lives at the app root.
    ///
    /// Plain values, never the SwiftData model — the record may be edited or
    /// deleted while the celebration is on screen.
    var debtPayoff: DebtPayoffSummary?

    struct DebtPayoffSummary: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let total: Double
        let currency: String
        let monthsTaken: Int
        let monthlyFreed: Double
    }

    @MainActor
    func celebrateDebtPayoff(name: String, total: Double, currency: String,
                             since: Date, monthlyFreed: Double) {
        let months = Calendar.current.dateComponents([.month], from: since, to: .now).month ?? 0
        let summary = DebtPayoffSummary(name: name, total: total, currency: currency,
                                        monthsTaken: max(months, 0), monthlyFreed: monthlyFreed)
        // Let the payment sheet finish dismissing before taking the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.debtPayoff = summary
        }
    }

    /// Show a confirmation. Calling again replaces the visible one rather than
    /// queueing — a stack of stale confirmations helps nobody.
    @MainActor
    func show(icon: String, tint: Color, title: String, detail: String? = nil) {
        dismissWork?.cancel()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
            current = Toast(icon: icon, tint: tint, title: title, detail: detail)
        }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    @MainActor
    func dismiss() {
        dismissWork?.cancel()
        withAnimation(.easeOut(duration: 0.22)) { current = nil }
    }

    // MARK: Convenience builders
    //
    // Named for the EVENT, so call sites read as what happened rather than as
    // toast plumbing — and so the wording stays consistent app-wide.

    @MainActor
    func transactionSaved(amount: Double, currency: String, category: TxCategory, cardLabel: String) {
        show(icon: "checkmark",
             tint: category.color,
             title: String(format: loc("feedback.tx_saved"),
                           CurrencyManager.shared.formatted(abs(amount), currency: currency)),
             detail: "\(category.displayLabel) · \(cardLabel)")
    }

    @MainActor
    func savingsAdded(amount: Double, currency: String, goalName: String, emoji: String) {
        show(icon: "arrow.down.to.line",
             tint: AppTheme.accent,
             title: String(format: loc("feedback.savings_added"),
                           CurrencyManager.shared.formatted(amount, currency: currency)),
             detail: "\(emoji) \(goalName)")
    }

    @MainActor
    func budgetApplied(daily: Int, lifestyle: Int, investDebt: Int) {
        show(icon: "slider.horizontal.3",
             tint: AppTheme.purple,
             title: loc("feedback.budget_applied"),
             detail: "\(daily)% · \(lifestyle)% · \(investDebt)%")
    }

    /// A debt payment. The detail line answers the question people actually
    /// have after paying — "how much is left?" — rather than repeating the
    /// debt name they just tapped.
    @MainActor
    func debtPaid(amount: Double, currency: String, debtName: String, remaining: Double, remainingCurrency: String) {
        show(icon: "creditcard",
             tint: AppTheme.red,
             title: String(format: loc("feedback.debt_paid"),
                           CurrencyManager.shared.formatted(amount, currency: currency)),
             detail: "\(debtName) · " + String(format: loc("feedback.debt_remaining"),
                           CurrencyManager.shared.formatted(remaining, currency: remainingCurrency)))
    }

    /// Clearing a debt is the rarest and best thing that happens in this app.
    /// It gets the trophy and the accent colour, not the red of a payment.
    @MainActor
    func debtCleared(debtName: String) {
        show(icon: "checkmark.seal.fill",
             tint: AppTheme.accent,
             title: String(format: loc("feedback.debt_cleared"), debtName))
    }

    @MainActor
    func cardSaved(name: String, isUpdate: Bool) {
        show(icon: isUpdate ? "pencil" : "creditcard.fill",
             tint: AppTheme.accent,
             title: String(format: loc(isUpdate ? "feedback.card_updated" : "feedback.card_added"), name))
    }

    @MainActor
    func goalSaved(name: String, emoji: String, isUpdate: Bool) {
        show(icon: isUpdate ? "pencil" : "target",
             tint: AppTheme.accent,
             title: String(format: loc(isUpdate ? "feedback.goal_updated" : "feedback.goal_created"), name),
             detail: emoji)
    }

    @MainActor
    func recurringSaved(name: String, amount: Double, currency: String, day: Int) {
        show(icon: "arrow.triangle.2.circlepath",
             tint: AppTheme.purple,
             title: String(format: loc("feedback.recurring_added"), name),
             detail: String(format: loc("feedback.recurring_detail"),
                            CurrencyManager.shared.formatted(amount, currency: currency), "\(day)"))
    }

    @MainActor
    func webSynced(at date: Date) {
        let f = DateFormatter()
        f.locale = LanguageManager.shared.currentLocale
        f.dateFormat = "d MMM, HH:mm"
        show(icon: "laptopcomputer.and.iphone",
             tint: AppTheme.accent,
             title: loc("feedback.web_synced"),
             detail: String(format: loc("feedback.web_synced_detail"),
                            f.string(from: date.addingTimeInterval(WebSyncService.snapshotLifetime))))
    }

    @MainActor
    func intentsSaved(count: Int) {
        show(icon: count > 0 ? "flag.fill" : "flag.slash",
             tint: count > 0 ? AppTheme.purple : AppTheme.textSecondary,
             title: loc("feedback.intents_saved"),
             detail: count > 0 ? String(format: loc("feedback.intents_detail"), count)
                               : loc("feedback.intents_none"))
    }

    /// Deletions get their own voice. A green checkmark on "you deleted
    /// something" reads as congratulation; a muted trash icon reads as a
    /// receipt, which is what a destructive action actually needs.
    @MainActor
    func removed(_ title: String, detail: String? = nil) {
        show(icon: "trash", tint: AppTheme.textSecondary, title: title, detail: detail)
    }

    @MainActor
    func saved(_ what: String) {
        show(icon: "checkmark", tint: AppTheme.accent, title: what)
    }
}

// MARK: - Presentation

struct ActionFeedbackOverlay: View {
    @State private var center = ActionFeedbackCenter.shared
    /// Drag offset so the toast follows the finger when swiped away.
    @State private var drag: CGFloat = 0

    var body: some View {
        VStack {
            if let toast = center.current {
                card(toast)
                    .offset(y: min(drag, 0))
                    .gesture(
                        DragGesture()
                            .onChanged { drag = $0.translation.height }
                            .onEnded { v in
                                if v.translation.height < -20 { center.dismiss() }
                                withAnimation(.spring(response: 0.3)) { drag = 0 }
                            }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: center.current)
        .allowsHitTesting(center.current != nil)
    }

    private func card(_ toast: ActionFeedbackCenter.Toast) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(toast.tint.opacity(0.16)).frame(width: 34, height: 34)
                Image(systemName: toast.icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(toast.tint)
                    // A checkmark that simply appears feels static; drawing it
                    // in sells the "it happened just now".
                    .transition(.scale.combined(with: .opacity))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if let detail = toast.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(toast.tint.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { center.dismiss() }
        .padding(.top, 8)
    }
}
