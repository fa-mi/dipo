import SwiftUI
import FirebaseAuth

// MARK: - Members and settings of a shared account
//
// The owner names it, sets the monthly budget, invites by DiPo ID, removes or
// promotes members, and closes it. Everyone else sees the same page with
// those controls absent, and a way to leave.

struct JointSettingsSheet: View {
    let accountID: String

    @Environment(\.dismiss) private var dismiss
    @State private var service = JointAccountService.shared
    @State private var name = ""
    @State private var emoji = ""
    @State private var budgetText = ""
    @State private var loaded = false
    @State private var saved = false
    @State private var dipoID = ""
    @State private var inviting = false
    @State private var inviteResult: JointAccountService.InviteResult?
    @State private var pending: [JointInvite] = []
    @State private var confirm: Confirm?
    @State private var working = false
    @State private var failed = false

    enum Confirm: Identifiable {
        case remove(JointMember), makeOwner(JointMember), leave, close
        var id: String {
            switch self {
            case .remove(let m): return "remove-\(m.id)"
            case .makeOwner(let m): return "owner-\(m.id)"
            case .leave: return "leave"
            case .close: return "close"
            }
        }
    }

    private var account: JointAccount? { service.account(accountID) }
    private var me: String? { Auth.auth().currentUser?.uid }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                if let account {
                    content(account)
                } else {
                    ProgressView().tint(AppTheme.accent)
                }
            }
            .navigationTitle(loc("joint.settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.close")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        .task { await load() }
        .onChange(of: account == nil) { _, gone in if gone && loaded { dismiss() } }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { c in
            Button(confirmButton(c), role: .destructive) { run(c) }
            Button(loc("common.cancel"), role: .cancel) {}
        } message: { c in
            Text(confirmMessage(c))
        }
    }

    private func load() async {
        guard let account, !loaded else { return }
        name = account.name
        emoji = account.emoji
        budgetText = account.monthlyBudget > 0
            ? NumberInput.text(JointMoney.toMajor(account.monthlyBudget, currency: account.currency)) : ""
        loaded = true
        if account.isOwner(me) { pending = await service.pendingInvites(for: account) }
    }

    @ViewBuilder
    private func content(_ account: JointAccount) -> some View {
        let owner = account.isOwner(me)
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                if owner {
                    section(loc("joint.settings.name")) {
                        VStack(alignment: .leading, spacing: 12) {
                            JointEmojiRow(options: JointCreateSheet.emojis, selection: $emoji)
                            JointField(title: loc("joint.create.name")) {
                                TextField(loc("joint.create.name_placeholder"), text: $name)
                                    .font(.system(.body, weight: .semibold))
                            }
                            JointField(title: loc("joint.budget.monthly"), hint: loc("joint.create.budget_hint")) {
                                HStack(spacing: 10) {
                                    Text(account.currency)
                                        .font(.system(.subheadline, weight: .bold))
                                        .foregroundStyle(AppTheme.accent)
                                    TextField("0", text: $budgetText)
                                        .font(.system(.body, weight: .semibold))
                                        .keyboardType(.decimalPad)
                                }
                            }
                            JointPrimaryButton(title: saved ? loc("joint.settings.saved") : loc("common.save"),
                                               enabled: account.isActive && !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                                service.update(account, name: name, emoji: emoji,
                                               monthlyBudget: JointMoney.toMinor(NumberInput.amount(budgetText), currency: account.currency))
                                HapticManager.shared.success()
                                withAnimation { saved = true }
                            }
                        }
                    }
                } else if account.monthlyBudget > 0 {
                    section(loc("joint.budget.monthly")) {
                        HStack {
                            Text(loc("joint.settings.budget_row"))
                                .font(.system(.subheadline))
                                .foregroundStyle(AppTheme.textPrimary)
                            Spacer()
                            Text(JointMoney.text(account.monthlyBudget, currency: account.currency))
                                .font(.system(.subheadline, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        .padding(16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                    }
                }

                section(String(format: loc("joint.settings.members"), account.memberCount, account.maxMembers)) {
                    VStack(spacing: 0) {
                        let members = service.members[account.id] ?? []
                        ForEach(Array(members.enumerated()), id: \.element.id) { i, m in
                            if i > 0 { Divider().background(AppTheme.cardMid) }
                            memberRow(m, index: i, account: account)
                        }
                        ForEach(pending) { inv in
                            Divider().background(AppTheme.cardMid)
                            pendingRow(inv)
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                }

                if owner && account.isActive && !account.isFull {
                    section(loc("joint.settings.invite")) {
                        inviteBox(account)
                    }
                }

                if failed {
                    Text(loc("joint.err.generic"))
                        .font(.system(.footnote, weight: .medium))
                        .foregroundStyle(AppTheme.orange)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        HapticManager.shared.tap()
                        confirm = owner ? .close : .leave
                    } label: {
                        Group {
                            if working { ProgressView().tint(AppTheme.red) }
                            else { Text(loc(owner ? "joint.settings.close" : "joint.settings.leave")) }
                        }
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(AppTheme.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .disabled(working)
                    if owner && account.memberCount > 1 {
                        Text(loc("joint.settings.owner_leave_hint"))
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            .padding(22)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(.caption, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(AppTheme.textSecondary)
            content()
        }
    }

    private func memberRow(_ m: JointMember, index: Int, account: JointAccount) -> some View {
        let isMe = m.id == me
        let isOwnerRow = m.id == account.ownerUid
        let name = m.displayName.isEmpty ? loc("joint.someone") : m.displayName
        return HStack(spacing: 12) {
            Text(JointText.initials(name))
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(JointAccountCard.avatarTints[index % JointAccountCard.avatarTints.count], in: Circle())
            Text(isMe ? String(format: loc("joint.settings.me"), name) : name)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if isOwnerRow {
                Text(loc("joint.role.owner"))
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(AppTheme.accent.opacity(0.12), in: Capsule())
            } else {
                Text(loc("joint.role.member"))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            if account.isOwner(me) && !isMe && account.isActive {
                Menu {
                    Button { confirm = .makeOwner(m) } label: {
                        Label(loc("joint.settings.make_owner"), systemImage: "crown")
                    }
                    Button(role: .destructive) { confirm = .remove(m) } label: {
                        Label(loc("joint.settings.remove"), systemImage: "person.fill.xmark")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(format: loc("joint.settings.member_options"), name))
            }
        }
        .padding(.vertical, 12)
    }

    private func pendingRow(_ inv: JointInvite) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.badge")
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(AppTheme.purple)
                .frame(width: 36, height: 36)
                .background(AppTheme.purple.opacity(0.12), in: Circle())
            Text(loc("joint.settings.pending"))
                .font(.system(.subheadline))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Button(loc("joint.settings.withdraw")) {
                HapticManager.shared.tap()
                Task {
                    await service.withdraw(inv)
                    pending.removeAll { $0.id == inv.id }
                }
            }
            .font(.system(.footnote, weight: .semibold))
            .foregroundStyle(AppTheme.red)
        }
        .padding(.vertical, 12)
    }

    private func inviteBox(_ account: JointAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(loc("joint.settings.dipo_id_placeholder"), text: $dipoID)
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .tracking(3)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(AppTheme.cardMid.opacity(0.6), in: RoundedRectangle(cornerRadius: AppRadius.md))
                .onChange(of: dipoID) { _, _ in inviteResult = nil }
            JointPrimaryButton(title: loc("joint.settings.send_invite"), busy: inviting,
                               enabled: !dipoID.trimmingCharacters(in: .whitespaces).isEmpty) {
                inviting = true
                Task {
                    let result = await service.invite(dipoID: dipoID, to: account)
                    inviting = false
                    inviteResult = result
                    if result == .sent {
                        HapticManager.shared.success()
                        dipoID = ""
                        pending = await service.pendingInvites(for: account)
                    } else {
                        HapticManager.shared.warning()
                    }
                }
            }
            if let inviteResult {
                Text(Self.message(inviteResult))
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(inviteResult == .sent ? AppTheme.accent : AppTheme.orange)
            } else {
                Text(loc("joint.settings.invite_hint"))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    static func message(_ r: JointAccountService.InviteResult) -> String {
        switch r {
        case .sent:           return loc("joint.invite.sent")
        case .notFound:       return loc("joint.invite.not_found")
        case .isYou:          return loc("joint.invite.is_you")
        case .alreadyMember:  return loc("joint.invite.already_member")
        case .alreadyInvited: return loc("joint.invite.already_invited")
        case .full:           return loc("joint.invite.full")
        case .failed:         return loc("joint.err.generic")
        }
    }

    // MARK: Confirmations

    private var confirmTitle: String {
        switch confirm {
        case .remove(let m)?: return String(format: loc("joint.confirm.remove_title"), m.displayName)
        case .makeOwner(let m)?: return String(format: loc("joint.confirm.owner_title"), m.displayName)
        case .leave?: return loc("joint.confirm.leave_title")
        case .close?: return loc("joint.confirm.close_title")
        case nil: return ""
        }
    }

    private func confirmButton(_ c: Confirm) -> String {
        switch c {
        case .remove: return loc("joint.settings.remove")
        case .makeOwner: return loc("joint.settings.make_owner")
        case .leave: return loc("joint.settings.leave")
        case .close: return loc("joint.settings.close")
        }
    }

    private func confirmMessage(_ c: Confirm) -> String {
        switch c {
        case .remove: return loc("joint.confirm.remove_msg")
        case .makeOwner: return loc("joint.confirm.owner_msg")
        case .leave: return loc("joint.confirm.leave_msg")
        case .close: return loc("joint.confirm.close_msg")
        }
    }

    private func run(_ c: Confirm) {
        guard let account else { return }
        working = true
        failed = false
        Task {
            let ok: Bool
            switch c {
            case .remove(let m): ok = await service.remove(m.id, from: account)
            case .makeOwner(let m): ok = await service.makeOwner(m, of: account)
            case .leave: ok = await service.leave(account)
            case .close: ok = await service.close(account)
            }
            working = false
            if ok {
                HapticManager.shared.success()
                if case .leave = c { dismiss() }
                if case .close = c { dismiss() }
            } else {
                HapticManager.shared.warning()
                failed = true
            }
        }
    }
}
