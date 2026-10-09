import SwiftUI
import SwiftData

// MARK: - Match a card's balance to the bank
//
// A ledger kept by hand drifts. The commonest drift is at the very start: the
// card was added with no opening balance, or an early top-up was never logged,
// so every balance DiPo has worked out since is short by the same amount. On
// Fahmi's BRI card that left the opening balance of a pay period at
// −Rp 75.485 — on a debit account that cannot go below zero — and made a
// healthy card read as overdrawn.
//
// The fix is one number the person can read off their bank app. DiPo moves
// the card's opening seed by the difference, so today's balance matches and
// every earlier balance moves with it. No transaction is written: a made-up
// income or expense would distort the budget, which is exactly what this is
// meant to stop doing.
//
// If the gap is a purchase the person forgot to log, logging it is the better
// fix — the sheet says so — because then the budget sees the spending too.

enum MatchBalance {
    /// The seed that makes the card's balance equal `bankBalance`, given the
    /// balance DiPo works out today.
    static func seed(current seed: Double, computed: Double, bankBalance: Double) -> Double {
        seed + (bankBalance - computed)
    }
}

struct MatchBalanceSheet: View {
    let card: BankCard
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var text = ""

    private var currency: String { card.resolvedCurrency }
    private var dipoBalance: Double { card.computedBalance() }
    private var entered: Double? {
        text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : NumberInput.amount(text)
    }
    private var difference: Double? { entered.map { $0 - dipoBalance } }

    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: currency) }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(loc("match.intro"))
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(card.holderName.isEmpty ? loc("wallet.untitled") : card.holderName)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                            HStack {
                                Text(loc("match.dipo_balance"))
                                    .font(.system(.footnote))
                                    .foregroundStyle(AppTheme.textSecondary)
                                Spacer()
                                Text((dipoBalance < -0.5 ? "−" : "") + money(abs(dipoBalance)))
                                    .font(.system(.footnote, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .monospacedDigit()
                            }
                        }
                        .padding(14)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))

                        VStack(alignment: .leading, spacing: 8) {
                            FormSectionLabel(text: loc("match.bank_balance"))
                            HStack(spacing: 8) {
                                Text(CurrencyManager.symbol(for: currency))
                                    .font(.system(.subheadline, weight: .bold))
                                    .foregroundStyle(AppTheme.textSecondary)
                                TextField("0", text: $text)
                                    .keyboardType(.decimalPad)
                                    .font(.system(.title3, weight: .bold))
                                    .foregroundStyle(AppTheme.textPrimary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))

                            if let d = difference, abs(d) >= 0.5 {
                                Text(String(format: loc(d > 0 ? "match.diff_up" : "match.diff_down"), money(abs(d))))
                                    .font(.system(.footnote, weight: .medium))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if difference != nil {
                                Label(loc("match.already"), systemImage: "checkmark.circle.fill")
                                    .font(.system(.footnote, weight: .medium))
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }

                        Label(loc("match.forgot_hint"), systemImage: "lightbulb.fill")
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 22).padding(.top, 8)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    apply()
                } label: {
                    Text(loc("match.apply"))
                        .font(.system(.callout, weight: .bold))
                        .foregroundStyle(canApply ? AppTheme.onVividFill : AppTheme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(canApply ? AppTheme.accentFill : AppTheme.cardMid,
                                    in: RoundedRectangle(cornerRadius: AppRadius.lg))
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(!canApply)
                .padding(.horizontal, 22).padding(.bottom, 10)
                .background(AppTheme.bg)
            }
            .navigationTitle(loc("match.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.close")) { HapticManager.shared.tap(); dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
    }

    private var canApply: Bool { (difference.map { abs($0) >= 0.5 }) ?? false }

    private func apply() {
        guard let bank = entered, canApply else { return }
        card.balance = MatchBalance.seed(current: card.balance, computed: dipoBalance, bankBalance: bank)
        try? context.save()
        HapticManager.shared.success()
        dismiss()
    }
}
