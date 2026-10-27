import SwiftUI
import SwiftData

// MARK: - Wait before buying, on the Savings Goals screen
//
// Under the goals: a jar holding the price of everything let go, the wants
// still waiting with how long is left, and a way to hold one more. When a
// wait is over the row asks, right there: let it go, or still want it. A
// price let go can go into a goal in the next breath. See DiPo/HeldWant.swift.
//
// On every account's Savings Goals screen. Without Royal one want waits at a
// time: with one waiting, "Hold something" becomes the way to Royal.

struct HoldSection: View {
    @Query(sort: \HeldWant.readyAt) private var wants: [HeldWant]
    /// Personal goals still open: where a price let go can be put.
    let goals: [SavingsGoal]
    let onDeposit: (SavingsGoal, Double, BankCard?) -> Void

    @State private var adding = false
    @State private var showPaywall = false
    /// Observed so the limit lifts the moment Royal is bought.
    @State private var pm = PremiumManager.shared

    /// Wants shown here before "See all".
    private let previewLimit = 3

    private var canHoldAnother: Bool {
        HeldWant.canHoldAnother(open: wants.filter { !$0.isDecided }.count,
                                royal: pm.canAccess(.savingsGoals))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("hold.title"))
                .font(.system(.body, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if wants.isEmpty {
                HoldIntroCard { adding = true }
            } else {
                TimelineView(.everyMinute) { timeline in
                    card(now: timeline.date)
                }
            }
        }
        .sheet(isPresented: $adding) {
            HoldFormSheet(editing: nil)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .royalPaywall(isPresented: $showPaywall)
    }

    private func card(now: Date) -> some View {
        let open = wants.filter { !$0.isDecided }
        return VStack(spacing: 0) {
            NavigationLink {
                HoldListView(goals: goals, onDeposit: onDeposit)
            } label: {
                HoldJarHeader(tally: HoldTally(wants, convert: { HoldMoney.toPreferred($0, $1) })).padding(16)
            }
            .buttonStyle(.plain)

            // Always in place, even with nothing waiting: the sheet for a
            // price just let go hangs off it.
            HoldRows(wants: Array(open.prefix(previewLimit)), now: now,
                     goals: goals, onDeposit: onDeposit, dividerAbove: true,
                     canHoldAnother: canHoldAnother, onUpgrade: { showPaywall = true })

            if open.count > previewLimit {
                HoldDivider(inset: 16)
                NavigationLink {
                    HoldListView(goals: goals, onDeposit: onDeposit)
                } label: {
                    HStack(spacing: 8) {
                        Text(String(format: loc("savings.see_all"), open.count))
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HoldDivider(inset: 16)
            if canHoldAnother {
                HoldAddRow { adding = true }
            } else {
                HoldRoyalRow { showPaywall = true }
            }
        }
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }
}

// MARK: - Everything held, decided or not

struct HoldListView: View {
    @Query(sort: \HeldWant.readyAt) private var wants: [HeldWant]
    let goals: [SavingsGoal]
    let onDeposit: (SavingsGoal, Double, BankCard?) -> Void

    @State private var adding = false
    @State private var showPaywall = false
    @State private var pm = PremiumManager.shared

    private var canHoldAnother: Bool {
        HeldWant.canHoldAnother(open: wants.filter { !$0.isDecided }.count,
                                royal: pm.canAccess(.savingsGoals))
    }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                TimelineView(.everyMinute) { timeline in
                    content(now: timeline.date)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .containerRelativeFrame(.horizontal)
            }
        }
        .navigationTitle(loc("hold.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.bg, for: .navigationBar)
        .sheet(isPresented: $adding) {
            HoldFormSheet(editing: nil)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .royalPaywall(isPresented: $showPaywall)
    }

    private func content(now: Date) -> some View {
        let open = wants.filter { !$0.isDecided }
        let decided = wants.filter(\.isDecided)
            .sorted { ($0.decidedAt ?? .distantPast) > ($1.decidedAt ?? .distantPast) }
        return VStack(alignment: .leading, spacing: 22) {
            HoldJarHeader(tally: HoldTally(wants, convert: { HoldMoney.toPreferred($0, $1) }), jarSize: 104, showsChevron: false)
                .padding(18)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(loc("hold.waiting_section"))
                VStack(spacing: 0) {
                    HoldRows(wants: open, now: now, goals: goals, onDeposit: onDeposit, dividerAbove: false,
                             canHoldAnother: canHoldAnother, onUpgrade: { showPaywall = true })
                    if !open.isEmpty { HoldDivider(inset: 16) }
                    if canHoldAnother {
                        HoldAddRow { adding = true }
                    } else {
                        HoldRoyalRow { showPaywall = true }
                    }
                }
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
            }

            if !decided.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle(loc("hold.decided_section"))
                    HoldRows(wants: decided, now: now, goals: goals, onDeposit: onDeposit, dividerAbove: false,
                             canHoldAnother: canHoldAnother, onUpgrade: { showPaywall = true })
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, weight: .bold))
            .foregroundStyle(AppTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rows, and what they open

/// The rows of a list of wants, with everything a row can ask for: the
/// decision itself, waiting longer, changing, deleting, and putting a price
/// let go into a goal.
struct HoldRows: View {
    let wants: [HeldWant]
    let now: Date
    let goals: [SavingsGoal]
    let onDeposit: (SavingsGoal, Double, BankCard?) -> Void
    /// A rule above the first row too, when the rows follow something else
    /// in the same card.
    var dividerAbove: Bool
    /// Whether a decided want can go back on the list: false for an account
    /// without Royal that already has its one want waiting.
    var canHoldAnother = true
    var onUpgrade: () -> Void = {}

    @Environment(\.modelContext) private var context
    @State private var menuFor: HeldWant?
    @State private var editing: HeldWant?
    @State private var deleting: HeldWant?
    /// Just let go, and there are goals to put its price into.
    @State private var keptFrom: HeldWant?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(wants.enumerated()), id: \.element.id) { i, want in
                if i > 0 || dividerAbove { HoldDivider(inset: i == 0 ? 16 : 66) }
                HoldRow(want: want, now: now,
                        onLetGo: { letGo(want) },
                        onBuy: { buy(want) },
                        onMore: { menuFor = want })
            }
        }
        .sheet(item: $menuFor) { menu(for: $0) }
        .sheet(item: $editing) { want in
            HoldFormSheet(editing: want)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .sheet(item: $keptFrom) { want in
            LetGoSheet(want: want, goals: goals, onDeposit: onDeposit)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .confirmSheet(item: $deleting,
                      title: { String(format: loc("hold.delete_title"), $0.name) },
                      message: { _ in loc("hold.delete_message") },
                      confirmLabel: loc("common.delete")) { want in
            delete(want)
        }
    }

    private func menu(for want: HeldWant) -> some View {
        var items: [ActionItem] = []
        if want.isDecided {
            if canHoldAnother {
                items.append(ActionItem(icon: "arrow.uturn.backward", title: loc("hold.undo"),
                                        detail: loc("hold.undo_sub"), tint: AppTheme.blue) { undo(want) })
            } else {
                items.append(ActionItem(icon: "arrow.uturn.backward", title: loc("hold.undo"),
                                        detail: loc("hold.more_royal_sub"), tint: AppTheme.royalGoldText) { onUpgrade() })
            }
        } else if want.isReady(at: .now) {
            let until = HeldWant.end(ofWait: want.waitDays, from: .now)
            items.append(ActionItem(icon: "hourglass",
                                    title: String(format: loc("hold.wait_again"), HeldWant.waitText(want.waitDays)),
                                    detail: String(format: loc("hold.form_ready_at"), HoldMoney.when(until)),
                                    tint: AppTheme.teal) { waitAgain(want) })
        } else {
            items.append(ActionItem(icon: "hand.wave.fill", title: loc("hold.let_go_now"),
                                    detail: loc("hold.let_go_now_sub"), tint: AppTheme.accent) { letGo(want) })
        }
        items.append(ActionItem(icon: "pencil", title: loc("common.edit"), tint: AppTheme.blue) { editing = want })
        items.append(ActionItem(icon: "trash.fill", title: loc("common.delete"), destructive: true) { deleting = want })
        return ActionListSheet(icon: "hourglass", iconTint: want.isDecided ? AppTheme.textSecondary : AppTheme.teal,
                               title: want.name,
                               subtitle: CurrencyManager.shared.formatted(want.amount, currency: want.currency),
                               items: items)
            .preferredColorScheme(appColorScheme())
    }

    private func letGo(_ want: HeldWant) {
        want.decide(.letGo)
        HeldWantReminders.saveAndReschedule(context)
        HapticManager.shared.success()
        if goals.isEmpty {
            ActionFeedbackCenter.shared.show(
                icon: "hand.wave.fill", tint: AppTheme.accent, title: loc("hold.let_go_toast"),
                detail: String(format: loc("hold.kept_title"),
                               CurrencyManager.shared.formatted(want.amount, currency: want.currency)))
        } else {
            keptFrom = want
        }
    }

    private func buy(_ want: HeldWant) {
        want.decide(.buy)
        HeldWantReminders.saveAndReschedule(context)
        HapticManager.shared.tap()
        ActionFeedbackCenter.shared.show(icon: "bag.fill", tint: AppTheme.accent,
                                         title: loc("hold.bought_toast"), detail: loc("hold.bought_toast_sub"))
    }

    private func waitAgain(_ want: HeldWant) {
        want.waitAgain()
        HeldWantReminders.saveAndReschedule(context)
        HapticManager.shared.select()
        ActionFeedbackCenter.shared.show(icon: "hourglass", tint: AppTheme.teal,
                                         title: String(format: loc("hold.held_again"), HeldWant.waitText(want.waitDays)),
                                         detail: want.name)
    }

    private func undo(_ want: HeldWant) {
        want.undoDecision()
        HeldWantReminders.saveAndReschedule(context)
        HapticManager.shared.select()
    }

    private func delete(_ want: HeldWant) {
        let name = want.name
        context.delete(want)
        HeldWantReminders.saveAndReschedule(context)
        HapticManager.shared.warning()
        ActionFeedbackCenter.shared.removed(loc("hold.deleted"), detail: name)
    }
}

/// One want: how long is left, or, once the wait is over, the question.
struct HoldRow: View {
    let want: HeldWant
    let now: Date
    let onLetGo: () -> Void
    let onBuy: () -> Void
    let onMore: () -> Void

    var body: some View {
        let ready = want.isReady(at: now)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                HapticManager.shared.tap(); onMore()
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    badge(ready: ready)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(want.name)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .lineLimit(2)
                            Spacer(minLength: 6)
                            Text(CurrencyManager.shared.formatted(want.amount, currency: want.currency))
                                .font(.system(.subheadline, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(want.decision == .letGo ? AppTheme.accent : AppTheme.textPrimary)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                        Text(status(ready: ready))
                            .font(.system(.caption, weight: ready ? .semibold : .regular))
                            .foregroundStyle(ready ? AppTheme.accent : AppTheme.textSecondary)
                    }
                    .padding(.top, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if ready {
                HStack(spacing: 8) {
                    decision(loc("hold.let_go"), primary: true, action: onLetGo)
                    decision(loc("hold.buy"), primary: false, action: onBuy)
                }
                .padding(.leading, 50)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder private func badge(ready: Bool) -> some View {
        switch want.decision {
        case .letGo?:
            outcome("hand.wave.fill", tint: AppTheme.accent)
        case .buy?:
            outcome("bag.fill", tint: AppTheme.textSecondary)
        case nil:
            if want.isDecided {
                outcome("checkmark", tint: AppTheme.textSecondary)
            } else {
                HoldRing(progress: want.waited(at: now), ready: ready)
            }
        }
    }

    private func outcome(_ icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(tint.opacity(0.14), in: Circle())
    }

    private func status(ready: Bool) -> String {
        if let decided = want.decidedAt {
            let day = HoldMoney.day(decided)
            return String(format: loc(want.decision == .buy ? "hold.was_bought" : "hold.was_let_go"), day)
        }
        if ready {
            let days = want.daysHeld(at: now)
            return days == 1 ? loc("hold.ready_one") : String(format: loc("hold.ready"), days)
        }
        switch want.timeLeft(at: now) {
        case .days(1)?: return loc("hold.days_left_one")
        case .days(let n)?: return String(format: loc("hold.days_left"), n)
        case .hours(1)?: return loc("hold.hours_left_one")
        case .hours(let n)?: return String(format: loc("hold.hours_left"), n)
        case .soon?, nil: return loc("hold.soon")
        }
    }

    private func decision(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.system(.subheadline, weight: .bold))
                .foregroundStyle(primary ? AppTheme.onVividFill : AppTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(primary ? AppTheme.accentFill : AppTheme.cardMid.opacity(0.7),
                            in: RoundedRectangle(cornerRadius: AppRadius.sm))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Adding and changing a want

struct HoldFormSheet: View {
    let editing: HeldWant?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var amountText = ""
    @State private var waitDays = HeldWant.defaultWait
    @State private var currency = CurrencyManager.shared.preferredCurrency

    private var amount: Double { NumberInput.amount(amountText) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && amount > 0 }
    /// When the wait would end: from now for a new want; for one being
    /// changed, from when its current wait began.
    private var readyAt: Date { HeldWant.end(ofWait: waitDays, from: editing?.waitStartedAt ?? .now) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    header
                    IconField(label: loc("hold.form_what"), icon: "bag",
                              placeholder: loc("hold.form_what_placeholder"), text: $name)
                        .padding(.horizontal, 22)
                    priceField.padding(.horizontal, 22)
                    waitPicker.padding(.horizontal, 22)
                }
                .padding(.bottom, 12)
                .containerRelativeFrame(.horizontal)
            }

            // Pinned — never scrolls out of reach.
            Button {
                save()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "hourglass").font(.system(.body))
                    Text(editing == nil
                         ? String(format: loc("hold.form_save"), HeldWant.waitText(waitDays))
                         : loc("common.save"))
                        .font(.system(.callout, weight: .bold))
                }
                .foregroundStyle(canSave ? AppTheme.onVividFill : AppTheme.textSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(canSave ? AppTheme.accentFill : AppTheme.cardMid,
                            in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!canSave)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(AppTheme.bg)
        }
        .onAppear {
            guard let w = editing else { return }
            name = w.name
            amountText = SavingsNumber.edit(w.amount, currency: w.currency)
            waitDays = w.waitDays
            currency = w.currency
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HoldRing(progress: 0, ready: false, size: 56)
            Text(loc(editing == nil ? "hold.form_title" : "hold.form_edit_title"))
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)
            if editing == nil {
                Text(loc("hold.form_sub"))
                    .font(.system(.subheadline))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
            }
        }
        .padding(.top, 24)
    }

    private var priceField: some View {
        VStack(alignment: .leading, spacing: 8) {
            FormSectionLabel(text: loc("hold.form_price"))
            HStack(spacing: 12) {
                Text(CurrencyManager.symbol(for: currency))
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                TextField("0", text: $amountText)
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .keyboardType(.decimalPad)
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            if let p = AmountInputHelper.preview(amountText, currency: currency) {
                Text(p).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private var waitPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormSectionLabel(text: loc("hold.form_wait"))
            HStack(spacing: 8) {
                ForEach(HeldWant.waits, id: \.self) { days in
                    let on = waitDays == days
                    Button {
                        HapticManager.shared.select(); waitDays = days
                    } label: {
                        Text(HeldWant.waitText(days))
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(on ? AppTheme.onVividFill : AppTheme.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(on ? AppTheme.accentFill : AppTheme.cardDark,
                                        in: RoundedRectangle(cornerRadius: AppRadius.sm))
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Text(readyAt > .now ? String(format: loc("hold.form_ready_at"), HoldMoney.when(readyAt))
                                : loc("hold.form_ready_now"))
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        guard canSave else { return }
        let name = String(trimmedName.prefix(80))
        if let w = editing {
            w.name = name
            w.amount = amount
            w.currency = currency
            if w.waitDays != waitDays {
                let start = w.waitStartedAt
                w.waitDays = waitDays
                w.readyAt = HeldWant.end(ofWait: waitDays, from: start)
            }
        } else {
            context.insert(HeldWant(name: name, amount: amount, currency: currency, waitDays: waitDays))
        }
        HeldWantReminders.saveAndReschedule(context)
        HapticManager.shared.success()
        ActionFeedbackCenter.shared.show(
            icon: "hourglass", tint: AppTheme.accent,
            title: editing == nil ? String(format: loc("hold.saved"), HeldWant.waitText(waitDays)) : loc("hold.updated"),
            detail: name)
        dismiss()
    }
}

// MARK: - After letting go

/// The price just let go, and the goals it could go into. Choosing one opens
/// that goal's own deposit, with the price already in it.
struct LetGoSheet: View {
    let want: HeldWant
    let goals: [SavingsGoal]
    let onDeposit: (SavingsGoal, Double, BankCard?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query private var wants: [HeldWant]
    @State private var chosen: SavingsGoal?

    var body: some View {
        if let goal = chosen {
            DepositSheet(goal: goal, initialAmount: price(in: goal.currency)) { amount, card in
                onDeposit(goal, amount, card)
                dismiss()
            }
        } else {
            chooser
        }
    }

    private func price(in currency: String) -> Double {
        let converted = CurrencyManager.shared.convert(want.amount, from: want.currency, to: currency)
        return (converted * 100).rounded() / 100
    }

    private var chooser: some View {
        let cm = CurrencyManager.shared
        let after = HoldTally(wants, convert: { HoldMoney.toPreferred($0, $1) })
        let before = HoldTally(wants.filter { $0.id != want.id }, convert: { HoldMoney.toPreferred($0, $1) })
        return ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                // The one moment the jar moves on its own: the price just let
                // go running in.
                HoldJar(level: after.level, size: 120, startingAt: before.level)
                    .padding(.top, 28)
                VStack(spacing: 6) {
                    Text(String(format: loc("hold.kept_title"), cm.formatted(want.amount, currency: want.currency)))
                        .font(.system(.title3, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(loc("hold.kept_sub"))
                        .font(.system(.subheadline))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

                VStack(spacing: 0) {
                    ForEach(Array(goals.enumerated()), id: \.element.id) { i, goal in
                        if i > 0 { HoldDivider(inset: 76) }
                        Button {
                            HapticManager.shared.tap()
                            withAnimation(.easeInOut(duration: 0.2)) { chosen = goal }
                        } label: {
                            goalRow(goal)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
                .padding(.horizontal, 22)

                Button {
                    HapticManager.shared.tap(); dismiss()
                } label: {
                    Text(loc("hold.not_now"))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.vertical, 10).padding(.horizontal, 20)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 24)
            .containerRelativeFrame(.horizontal)
        }
    }

    private func goalRow(_ goal: SavingsGoal) -> some View {
        let cm = CurrencyManager.shared
        return HStack(spacing: 12) {
            Text(goal.emoji)
                .font(.system(.title2))
                .frame(width: 48, height: 48)
                .background(AppTheme.cardMid.opacity(0.7), in: RoundedRectangle(cornerRadius: AppRadius.sm))
            VStack(alignment: .leading, spacing: 3) {
                Text(goal.name)
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(String(format: loc("savings.saved_of"),
                            cm.formatted(goal.savedAmount, currency: goal.currency),
                            cm.formatted(goal.targetAmount, currency: goal.currency)))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - The jar, and smaller pieces

/// The jar and what it says: how much stayed, out of how much was wanted.
struct HoldJarHeader: View {
    let tally: HoldTally
    var jarSize: CGFloat = 84
    var showsChevron = true

    var body: some View {
        let cm = CurrencyManager.shared
        let pref = cm.preferredCurrency
        HStack(alignment: .center, spacing: 16) {
            HoldJar(level: tally.level, size: jarSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("hold.kept"))
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(cm.formatted(tally.kept, currency: pref))
                    .font(.system(.title2, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text(tally.decided > 0
                     ? String(format: loc("hold.kept_of"), cm.formatted(tally.decided, currency: pref))
                     : loc("hold.kept_none"))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A round glass jar, filled to `level` (0 to 1) with DiPo's green. It sits
/// still, and moves only when its level changes: the surface rises with a
/// single slow wave, so letting something go is something you can see.
struct HoldJar: View {
    let level: Double
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double
    @State private var phase: Double = 0

    /// `startingAt`, when given, is the level it shows first and rises from.
    init(level: Double, size: CGFloat = 84, startingAt: Double? = nil) {
        self.level = level
        self.size = size
        _shown = State(initialValue: startingAt ?? level)
    }

    var body: some View {
        ZStack {
            Circle().fill(AppTheme.cardMid.opacity(0.45))
            ZStack {
                JarSurface(level: shown, phase: phase + 1.4, amplitude: 0.03)
                    .fill(AppTheme.accent.opacity(0.35))
                JarSurface(level: max(shown - 0.03, 0), phase: phase, amplitude: 0.032)
                    .fill(AppTheme.accent.opacity(0.92))
            }
            .clipShape(Circle().inset(by: size * 0.06))
            Circle().strokeBorder(AppTheme.cardMid, lineWidth: max(2, size * 0.03))
            JarGlint()
                .stroke(AppTheme.flowFrost.opacity(0.35),
                        style: StrokeStyle(lineWidth: max(2, size * 0.04), lineCap: .round))
        }
        .frame(width: size, height: size)
        .onAppear { rise() }
        .onChange(of: level) { _, _ in rise() }
        .accessibilityHidden(true)
    }

    private func rise() {
        guard shown != level else { return }
        if reduceMotion {
            shown = level
        } else {
            withAnimation(.spring(response: 1.2, dampingFraction: 0.85)) {
                shown = level
                phase += 2 * .pi
            }
        }
    }
}

/// The liquid: a gentle wave across the jar at `level`, filled down to the
/// bottom. `phase` slides the wave along; both animate.
private struct JarSurface: Shape {
    var level: Double
    var phase: Double
    /// The wave's height, as a share of the jar's.
    let amplitude: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(level, phase) }
        set { level = newValue.first; phase = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard level > 0.001 else { return path }
        let top = rect.maxY - CGFloat(min(level, 1)) * rect.height
        let amp = CGFloat(amplitude) * rect.height
        let steps = 48
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let point = CGPoint(x: rect.minX + CGFloat(t) * rect.width,
                                y: top + amp * CGFloat(sin(t * 2 * .pi * 1.2 + phase)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The light caught on the glass, up at the jar's left shoulder.
private struct JarGlint: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width * 0.32
        for (i, degrees) in stride(from: 202.0, through: 249.0, by: 3.0).enumerated() {
            let angle = degrees * .pi / 180
            let point = CGPoint(x: center.x + radius * CGFloat(cos(angle)),
                                y: center.y + radius * CGFloat(sin(angle)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// How far a wait has run, around an hourglass: teal while it runs, green
/// once it is over.
struct HoldRing: View {
    let progress: Double
    let ready: Bool
    var size: CGFloat = 38

    var body: some View {
        let tint = ready ? AppTheme.accent : AppTheme.teal
        let line = max(2.4, size * 0.07)
        ZStack {
            if ready { Circle().fill(AppTheme.accent.opacity(0.14)) }
            Circle().strokeBorder(AppTheme.accentTrack, lineWidth: line)
            Circle()
                .inset(by: line / 2)
                .trim(from: 0, to: ready ? 1 : max(min(progress, 1), 0.02))
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: ready ? "hourglass.bottomhalf.filled" : "hourglass.tophalf.filled")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Before anything is held: what this is for, and the way to start.
struct HoldIntroCard: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                HoldJar(level: 0, size: 64)
                Text(loc("hold.intro_title"))
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(loc("hold.intro_body"))
                .font(.system(.subheadline))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                HapticManager.shared.tap(); onAdd()
            } label: {
                Text(loc("hold.add"))
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.onVividFill)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppRadius.md))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }
}

/// "Hold something", at the foot of a card of wants.
private struct HoldAddRow: View {
    let onAdd: () -> Void

    var body: some View {
        Button {
            HapticManager.shared.tap(); onAdd()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").font(.system(.body))
                Text(loc("hold.add")).font(.system(.subheadline, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// In place of "Hold something" once an account without Royal has its one
/// want waiting: what Royal adds, and the way to it.
private struct HoldRoyalRow: View {
    let onUpgrade: () -> Void

    var body: some View {
        Button {
            HapticManager.shared.tap(); onUpgrade()
        } label: {
            HStack(spacing: 12) {
                Text("👑").font(.system(.body))
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("hold.more_royal"))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(loc("hold.more_royal_sub"))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    /// The Royal paywall, as every other screen presents it.
    func royalPaywall(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            PaywallView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }
}

private struct HoldDivider: View {
    let inset: CGFloat
    var body: some View {
        Rectangle().fill(AppTheme.cardMid.opacity(0.7)).frame(height: 1).padding(.leading, inset)
    }
}

/// Money and dates as the hold list writes them.
enum HoldMoney {
    static func toPreferred(_ amount: Double, _ currency: String) -> Double {
        let cm = CurrencyManager.shared
        return cm.convert(amount, from: currency, to: cm.preferredCurrency)
    }

    /// "Mon, 28 Oct, 14:20", in the app's language.
    static func when(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
            .locale(LanguageManager.shared.currentLocale))
    }

    /// "25 Oct".
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(LanguageManager.shared.currentLocale))
    }
}
