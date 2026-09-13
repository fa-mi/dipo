import SwiftUI
import SwiftData

// MARK: - Main card gate
//
// Shown when the user has several accounts and has not said which one the app
// should reason about. It blocks the rest of DiPo, and the reason it is allowed
// to is that without an answer every other screen would be guessing — a budget
// measured against an arbitrary denominator is worse than no budget, because it
// looks authoritative.
//
// Two rules this screen follows.
//
// It EXPLAINS before it asks. A modal that says "choose a main card" and will
// not go away is an obstacle; the same modal that first shows the four things
// the choice feeds is a setup step. The list is not decoration — it is the
// entire justification for interrupting someone.
//
// And it is not a dead end. The one action a person might legitimately need
// here — adding an account that isn't in DiPo yet — is available from inside
// the gate. Blocking someone from the only thing that would let them past is
// how a requirement becomes a trap.
struct MainCardGate: View {
    @Bindable var vm: AppViewModel
    @State private var showAddCard = false
    @State private var picked: UUID? = nil

    private var cards: [BankCard] { MainCard.eligible(vm.cards) }
    private var cm: CurrencyManager { CurrencyManager.shared }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    reasons
                    picker
                }
                .padding(.horizontal, 22)
                .padding(.top, 40)
                .padding(.bottom, 130)
            }

            VStack {
                Spacer()
                confirmBar
            }
        }
        .trackScreen(.mainCardGate)
        .sheet(isPresented: $showAddCard) {
            CardFormSheet(vm: vm, editCard: nil)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.15)).frame(width: 54, height: 54)
                Image(systemName: "star.circle.fill")
                    .font(.system(.title, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            Text(loc("main.gate_title"))
                .font(.system(.title, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(loc("main.gate_body"))
                .font(.system(.subheadline))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Why

    private var reasons: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc("main.gate_why"))
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(AppTheme.textSecondary)
                .tracking(0.7)
                .padding(.bottom, 12)

            ForEach(Array(MainCard.dependents.enumerated()), id: \.element.id) { idx, dep in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: dep.icon)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 26, height: 26)
                        .background(AppTheme.accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc(dep.titleKey))
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(loc(dep.detailKey))
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
                if idx < MainCard.dependents.count - 1 {
                    Divider().overlay(AppTheme.cardMid).padding(.leading, 38)
                }
            }
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Choose

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc("main.gate_choose"))
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(AppTheme.textSecondary)
                .tracking(0.7)

            ForEach(cards) { card in
                Button {
                    HapticManager.shared.tap()
                    picked = card.id
                } label: {
                    CardListRow(card: card, selected: picked == card.id)
                }
                .buttonStyle(ScaleButtonStyle())
            }

            Button {
                HapticManager.shared.tap()
                showAddCard = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.system(.subheadline))
                    Text(loc("main.gate_add_card")).font(.system(.footnote, weight: .semibold))
                }
                .foregroundStyle(AppTheme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(ScaleButtonStyle())

            // Said once, plainly, and only after the choice is in front of
            // them: this is not a decision they are stuck with.
            Text(loc("main.gate_changeable"))
                .font(.system(.caption2))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private var confirmBar: some View {
        Button {
            guard let picked, let card = cards.first(where: { $0.id == picked }) else { return }
            HapticManager.shared.success()
            MainCard.set(card)
        } label: {
            Text(loc("main.gate_confirm"))
                .font(.system(.subheadline, weight: .bold))
                .foregroundStyle(picked == nil ? AppTheme.textSecondary : AppTheme.bg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(picked == nil ? AppTheme.cardMid : AppTheme.accent,
                            in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(picked == nil)
        .padding(.horizontal, 22)
        .padding(.bottom, 34)
        .background {
            LinearGradient(colors: [AppTheme.bg.opacity(0), AppTheme.bg, AppTheme.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }
}
