import SwiftUI
import SwiftData

// MARK: - Delete a card
//
// Deleting a card in DiPo is not deleting a card. The transactions cascade with
// it, and the salary schedules, recurring plans and budget ratios attached to
// it are removed alongside — 385 records, on this user's main account, behind a
// one-line alert that named four digits and nothing else.
//
// A confirmation is only a safeguard if it states the consequence. "Delete card
// ··0969?" asks whether you meant to tap the button; it does not ask the
// question that matters, which is whether you know what leaves with it.
//
// So this shows the inventory, and it names the one condition that cannot be
// undone by re-adding the card afterwards: the history.
struct CardDeleteSheet: View {
    let card: BankCard
    let txCount: Int
    let scheduleCount: Int
    let recurringCount: Int
    let isMain: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// Deliberate friction, and only where it is earned: a card carrying real
    /// history needs a second, conscious action. An empty card added by mistake
    /// does not — friction applied evenly is just an obstacle.
    @State private var armed = false

    private var needsArming: Bool { txCount > 0 }
    private var canDelete: Bool { !needsArming || armed }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        inventory
                        if isMain { mainWarning }
                        if needsArming { armToggle }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 130)
                }

                VStack {
                    Spacer()
                    actions
                }
            }
            .trackScreen(.cards)
            .navigationTitle(loc("cards.delete_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            LinearGradient(colors: [Color(hex: card.gradientStart), Color(hex: card.gradientEnd)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: 5, height: 42)
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 3) {
                Text(CardLabel.title(card))
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                let sub = CardLabel.subtitle(card)
                Text(sub.isEmpty ? card.formattedBalance : sub + " · " + card.formattedBalance)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    // MARK: What goes with it

    private var inventory: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc("cards.delete_takes"))
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(AppTheme.textSecondary)
                .tracking(0.6)
                .padding(.bottom, 10)

            item("list.bullet.rectangle", String(format: loc("cards.delete_tx"), txCount),
                 loc("cards.delete_tx_sub"), heavy: txCount > 0)
            if scheduleCount > 0 {
                divider
                item("calendar.badge.clock",
                     String(format: loc("cards.delete_salary"), scheduleCount),
                     loc("cards.delete_salary_sub"), heavy: true)
            }
            if recurringCount > 0 {
                divider
                item("arrow.triangle.2.circlepath",
                     String(format: loc("cards.delete_recurring"), recurringCount),
                     loc("cards.delete_recurring_sub"), heavy: true)
            }
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var divider: some View {
        Divider().overlay(AppTheme.cardMid).padding(.vertical, 10).padding(.leading, 34)
    }

    private func item(_ icon: String, _ title: String, _ detail: String, heavy: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(.footnote))
                .foregroundStyle(heavy ? AppTheme.red : AppTheme.textSecondary)
                .frame(width: 23)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(detail)
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var mainWarning: some View {
        Label(loc("cards.delete_is_main"), systemImage: "star.slash")
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(AppTheme.orange)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(AppTheme.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    // MARK: Arm

    private var armToggle: some View {
        Button {
            HapticManager.shared.tap()
            withAnimation(.easeOut(duration: 0.18)) { armed.toggle() }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: armed ? "checkmark.square.fill" : "square")
                    .font(.system(.title3))
                    .foregroundStyle(armed ? AppTheme.red : AppTheme.cardMid)
                Text(String(format: loc("cards.delete_ack"), txCount))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(ScaleButtonStyle())
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                HapticManager.shared.warning()
                onConfirm()
                dismiss()
            } label: {
                Text(loc("cards.delete_confirm_btn"))
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(canDelete ? AppTheme.onVividFill : AppTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(canDelete ? AppTheme.red : AppTheme.cardMid,
                                in: RoundedRectangle(cornerRadius: AppRadius.md))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!canDelete)

            Button {
                HapticManager.shared.tap(); dismiss()
            } label: {
                Text(loc("common.cancel"))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 28)
        .background {
            LinearGradient(colors: [AppTheme.bg.opacity(0), AppTheme.bg, AppTheme.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }
}
