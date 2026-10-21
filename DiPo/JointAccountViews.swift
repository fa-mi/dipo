import SwiftUI
import SwiftData
import FirebaseAuth

// MARK: - Rekening Bersama on the wallet
//
// Under the total balance: one card per shared account, any invitations
// waiting for an answer, and the way to make a new one. The card face is the
// one gradient here, because it IS a card — a shared wallet sitting beside the
// person's own — and everything around it stays flat.

/// An open account, for `.sheet(item:)`.
struct JointRoute: Identifiable, Hashable { let id: String }

struct JointAccountsSection: View {
    @Bindable var vm: AppViewModel
    @State private var service = JointAccountService.shared
    @State private var pm = PremiumManager.shared
    @State private var open: JointRoute?
    @State private var showCreate = false
    @State private var createdID: String?
    @State private var showPaywall = false
    @State private var answering: String?
    @State private var note: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("joint.section"))
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.leading, 4)

            ForEach(service.accounts) { account in
                Button {
                    HapticManager.shared.tap()
                    open = JointRoute(id: account.id)
                } label: {
                    JointAccountCard(account: account,
                                     members: service.members[account.id] ?? [],
                                     memberLine: service.memberLine(account),
                                     spent: service.spentThisMonth(account.id),
                                     month: service.month)
                }
                .buttonStyle(ScaleButtonStyle())
            }

            ForEach(service.invites) { invite in
                inviteRow(invite)
            }

            if let note {
                Text(note)
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(AppTheme.orange)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }

            createButton
        }
        .onAppear { service.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { service.start() }
        }
        .sheet(item: $open) { route in
            JointAccountDetailView(accountID: route.id, vm: vm)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showCreate, onDismiss: {
            // Straight into the new account, where inviting a partner is one tap away.
            if let id = createdID { createdID = nil; service.start(); open = JointRoute(id: id) }
        }) {
            JointCreateSheet { createdID = $0 }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }

    private func inviteRow(_ invite: JointInvite) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.fill")
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(AppTheme.purple)
                .frame(width: 44, height: 44)
                .background(AppTheme.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.sm))
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: loc("joint.invite.from"), invite.fromName.isEmpty ? loc("joint.someone") : invite.fromName))
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(2)
                Text(String(format: loc("joint.invite.to"), "\(invite.accountName) \(invite.accountEmoji)"))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if answering == invite.id {
                ProgressView().tint(AppTheme.accent)
            } else {
                Button {
                    HapticManager.shared.tap()
                    answer(invite, accept: false)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(.footnote, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(AppTheme.cardMid, in: Circle())
                }
                .accessibilityLabel(loc("joint.invite.decline"))
                .buttonStyle(ScaleButtonStyle())
                Button {
                    HapticManager.shared.tap()
                    answer(invite, accept: true)
                } label: {
                    Text(loc("joint.invite.accept"))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.onVividFill)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(AppTheme.accentFill, in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func answer(_ invite: JointInvite, accept: Bool) {
        withAnimation { note = nil }
        guard !accept || UserSession.shared.isLoggedIn else {
            withAnimation { note = loc("joint.invite.login_first") }
            return
        }
        answering = invite.id
        Task {
            if accept {
                if await service.accept(invite) {
                    HapticManager.shared.success()
                    open = JointRoute(id: invite.accountId)
                } else {
                    HapticManager.shared.warning()
                    withAnimation { note = loc("joint.invite.cant_join") }
                }
            } else {
                await service.decline(invite)
            }
            answering = nil
        }
    }

    private var createButton: some View {
        Button {
            HapticManager.shared.tap()
            let _ = pm.plan
            if pm.canAccess(.jointAccount) { showCreate = true } else { showPaywall = true }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(loc("joint.create.cta"))
                            .font(.system(.subheadline, weight: .bold))
                            .foregroundStyle(AppTheme.accent)
                        if !pm.canAccess(.jointAccount) {
                            Image(systemName: "crown.fill")
                                .font(.system(.caption2, weight: .bold))
                                .foregroundStyle(PremiumPlan.royal.color)
                        }
                    }
                    Text(loc("joint.create.cta_sub"))
                        .font(.system(.footnote))
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                .strokeBorder(AppTheme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - The card

struct JointAccountCard: View {
    let account: JointAccount
    let members: [JointMember]
    let memberLine: String
    let spent: Int64
    let month: DateInterval

    /// Avatar fills, in join order. Vivid tokens, so the white initials read.
    static let avatarTints: [Color] = [AppTheme.blue, AppTheme.purple, AppTheme.orange, AppTheme.fuchsia, AppTheme.indigo]

    static func monthName(_ month: DateInterval) -> String {
        let f = DateFormatter()
        f.locale = LanguageManager.shared.currentLocale
        f.setLocalizedDateFormatFromTemplate("MMMM")
        return f.string(from: month.start)
    }

    private var balanceText: String {
        (account.balance < 0 ? "−" : "") + JointMoney.text(account.balance, currency: account.currency)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text("\(account.emoji) \(account.name)")
                    .font(.system(.headline, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                JointAvatars(members: members, ring: .white.opacity(0.9))
            }

            Text(balanceText)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .padding(.top, 14)
            Text("\(loc("joint.balance_label")) · \(memberLine)")
                .font(.system(.footnote, weight: .medium))
                .opacity(0.88)
                .lineLimit(1)

            if !account.isActive {
                Label(loc("joint.closing"), systemImage: "hourglass")
                    .font(.system(.caption, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.2), in: Capsule())
                    .padding(.top, 12)
            } else if account.monthlyBudget > 0 {
                VStack(alignment: .leading, spacing: 7) {
                    Text(String(format: loc("joint.budget.line"), Self.monthName(month),
                                JointMoney.text(spent, currency: account.currency),
                                JointMoney.text(account.monthlyBudget, currency: account.currency)))
                        .font(.system(.caption, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.28))
                            Capsule().fill(.white)
                                .frame(width: g.size.width * min(JointBudget.ratio(spent: spent, budget: account.monthlyBudget), 1))
                        }
                    }
                    .frame(height: 6)
                }
                .padding(.top, 16)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [AppTheme.accent, AppTheme.jointCardDeep],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // The soft disc from the mockup: light on the card, not a pattern.
                Circle()
                    .fill(.white.opacity(0.09))
                    .frame(width: 190, height: 190)
                    .offset(x: 60, y: -70)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
        .shadow(color: AppTheme.jointCardDeep.opacity(0.28), radius: 14, y: 7)
        .accessibilityElement(children: .combine)
    }
}

/// Overlapping initials, one per member.
struct JointAvatars: View {
    let members: [JointMember]
    var ring: Color = AppTheme.cardDark
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(members.prefix(5).enumerated()), id: \.element.id) { i, member in
                Text(JointText.initials(member.displayName))
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(JointAccountCard.avatarTints[i % JointAccountCard.avatarTints.count], in: Circle())
                    .overlay(Circle().stroke(ring, lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Creating one

struct JointCreateSheet: View {
    var onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var service = JointAccountService.shared
    @State private var name = ""
    @State private var emoji = JointIcon.all[0].emoji
    @State private var budgetText = ""
    @State private var saving = false
    @State private var failed = false

    /// The name that tapping an icon last filled in, so a second tap can
    /// replace it but never what the person typed themselves.
    @State private var suggested = ""
    private var currency: String { CurrencyManager.shared.preferredCurrency }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        JointEmojiRow(selection: $emoji) { icon in
                            // An empty name, or one an icon filled in, takes
                            // the icon's word: one tap names the account.
                            let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            if typed.isEmpty || typed == suggested {
                                name = icon.label
                                suggested = icon.label
                            }
                        }

                        JointField(title: loc("joint.create.name")) {
                            TextField(loc("joint.create.name_placeholder"), text: $name)
                                .font(.system(.body, weight: .semibold))
                                .textInputAutocapitalization(.words)
                        }

                        JointField(title: loc("joint.budget.monthly"), hint: loc("joint.create.budget_hint")) {
                            HStack(spacing: 10) {
                                Text(currency)
                                    .font(.system(.subheadline, weight: .bold))
                                    .foregroundStyle(AppTheme.accent)
                                TextField("0", text: $budgetText)
                                    .font(.system(.body, weight: .semibold))
                                    .keyboardType(.decimalPad)
                            }
                        }

                        JointInfo(icon: "info.circle.fill", text: loc("joint.create.explain"))
                        JointInfo(icon: "person.2.fill", text: loc("joint.create.invite_next"))

                        if failed {
                            Text(loc("joint.err.not_created"))
                                .font(.system(.footnote, weight: .medium))
                                .foregroundStyle(AppTheme.orange)
                        }

                        JointPrimaryButton(title: loc("joint.create.button"), busy: saving,
                                           enabled: !trimmed.isEmpty) {
                            create()
                        }
                    }
                    .padding(22)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("joint.create.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        .trackScreen(.jointAccount)
    }

    private func create() {
        saving = true
        failed = false
        let budget = JointMoney.toMinor(NumberInput.amount(budgetText), currency: currency)
        Task {
            let id = await service.create(name: trimmed, emoji: emoji, monthlyBudget: budget)
            saving = false
            guard let id else { failed = true; HapticManager.shared.warning(); return }
            HapticManager.shared.success()
            onCreated(id)
            dismiss()
        }
    }
}

// MARK: - Small shared pieces

/// What an account is for, as a picture and a word. Pictures alone left
/// people guessing — is 🏘️ "the neighbours" or "the boarding house"?
struct JointIcon: Hashable {
    let emoji: String
    let key: String
    var label: String { key.isEmpty ? "" : loc(key) }
    /// One line on what the account is for — the touch screen's answer to
    /// a hover: it shows for whichever icon is chosen.
    var detail: String { key.isEmpty ? "" : loc(key + ".detail") }

    static let all: [JointIcon] = [
        JointIcon(emoji: "🏠", key: "joint.icon.home"),
        JointIcon(emoji: "💑", key: "joint.icon.couple"),
        JointIcon(emoji: "🏡", key: "joint.icon.family"),
        JointIcon(emoji: "🏘️", key: "joint.icon.housemates"),
        JointIcon(emoji: "🛒", key: "joint.icon.groceries"),
        JointIcon(emoji: "🍚", key: "joint.icon.kitchen"),
        JointIcon(emoji: "✈️", key: "joint.icon.holiday"),
        JointIcon(emoji: "💰", key: "joint.icon.savings"),
    ]
}

struct JointEmojiRow: View {
    @Binding var selection: String
    var onPick: ((JointIcon) -> Void)? = nil

    /// An account made with an icon no longer offered keeps it, first.
    private var options: [JointIcon] {
        JointIcon.all.contains { $0.emoji == selection } || selection.isEmpty
            ? JointIcon.all
            : [JointIcon(emoji: selection, key: "")] + JointIcon.all
    }

    /// The page's side margin. The row scrolls right to the screen's edge,
    /// starting and ending at the text margin, so neither the first tile nor
    /// the last is cut in half by the edge of a narrower scroll area.
    private static let margin: CGFloat = 22

    private var chosen: JointIcon? {
        options.first { $0.emoji == selection && !$0.key.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(options, id: \.emoji) { icon in
                            tile(icon)
                                .id(icon.emoji)
                        }
                    }
                    .padding(.horizontal, Self.margin)
                    .padding(.vertical, 3)
                }
                .padding(.horizontal, -Self.margin)
                // An account saved with the last icon opens with it in view.
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }

            if let chosen {
                HStack(alignment: .top, spacing: 10) {
                    Text(chosen.emoji)
                        .font(.system(.subheadline))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chosen.label)
                            .font(.system(.footnote, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(chosen.detail)
                            .font(.system(.footnote))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(AppTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.md))
                .id(chosen.emoji)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.easeOut(duration: 0.18), value: selection)
    }

    private func tile(_ icon: JointIcon) -> some View {
        let on = icon.emoji == selection
        return Button {
            HapticManager.shared.tap()
            selection = icon.emoji
            onPick?(icon)
        } label: {
            VStack(spacing: 6) {
                Text(icon.emoji)
                    .font(.system(size: 26))
                    .frame(width: 52, height: 52)
                    .background(on ? AppTheme.accent.opacity(0.14) : AppTheme.cardDark,
                                in: RoundedRectangle(cornerRadius: AppRadius.md))
                    // Drawn inside the tile, so no part of it falls outside.
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                        .strokeBorder(on ? AppTheme.accent : .clear, lineWidth: 2))
                Text(icon.label)
                    .font(.system(.caption2, weight: on ? .bold : .medium))
                    .foregroundStyle(on ? AppTheme.accent : AppTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 68)
        }
        .buttonStyle(ScaleButtonStyle())
        // A real hover where there is a pointer (iPad trackpad, Mac).
        .help(icon.detail)
        .accessibilityLabel(icon.label.isEmpty ? icon.emoji : icon.label)
        .accessibilityHint(icon.detail)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct JointField<Content: View>: View {
    let title: String
    var hint: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            content
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
            if let hint {
                Text(hint)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
}

struct JointInfo: View {
    let icon: String
    let text: String
    var tint: Color = AppTheme.blue

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

struct JointPrimaryButton: View {
    let title: String
    var busy = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button {
            HapticManager.shared.tap()
            action()
        } label: {
            ZStack {
                if busy { ProgressView().tint(AppTheme.onVividFill) } else { Text(title) }
            }
            .font(.system(.body, weight: .bold))
            .foregroundStyle(AppTheme.onVividFill)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(AppTheme.accentFill.opacity(enabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(!enabled || busy)
    }
}
