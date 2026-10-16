import SwiftUI
import FirebaseAuth

// MARK: - Target Bersama kept in a Rekening Bersama
//
// A couple saving for a house used to need two features that did not know
// about each other: the shared wallet, and a shared goal they had to invite
// each other to again (both of them on Royal). Now a goal can be kept in the
// account: the account's members are its members, and money moves to it
// from the shared balance — saved, not spent, so the month's budget and
// Smart Budget leave it out. A goal on its own, for friends who share no
// wallet, still works by invitation.

enum JointGoals {
    /// Whether `amount` (minor units) can move from the account's balance to
    /// the goal now, by `uid`. The rules check the same and more.
    static func canMove(_ amount: Int64, to goal: SharedGoal, from account: JointAccount, as uid: String) -> Bool {
        amount > 0 && amount <= JointMoney.maxMinor && amount <= account.balance
            && goal.jointAccountId == account.id && goal.currency == account.currency
            && goal.status == "active" && goal.memberUids.contains(uid)
    }

    /// A member of the account the goal has not taken in yet: they joined the
    /// account after the goal was made.
    static func shouldJoin(_ goal: SharedGoal, account: JointAccount, me: String) -> Bool {
        goal.jointAccountId == account.id && goal.status == "active"
            && account.memberUids.contains(me) && !goal.memberUids.contains(me) && !goal.isFull
    }

    /// The goal's members who are no longer in the account.
    static func departed(_ goal: SharedGoal, account: JointAccount) -> [String] {
        guard goal.jointAccountId == account.id else { return [] }
        return goal.memberUids.filter { !account.memberUids.contains($0) }
    }
}

// MARK: - The section on the account's screen

struct JointGoalsSection: View {
    let account: JointAccount
    @State private var unity = UnitySavingsService.shared
    @State private var creating = false
    @State private var detail: SharedGoal?
    @State private var adding: SharedGoal?

    private var goals: [SharedGoal] { unity.accountGoals[account.id] ?? [] }
    private var me: String? { Auth.auth().currentUser?.uid }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc("unity.title").uppercased(with: LanguageManager.shared.currentLocale))
                .font(.system(.caption, weight: .bold))
                .tracking(1)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 4)
                .padding(.top, 4)

            ForEach(goals) { goal in
                row(goal)
            }

            if account.isActive {
                Button {
                    HapticManager.shared.tap()
                    creating = true
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "plus").font(.system(.subheadline, weight: .bold))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc("unity.create"))
                                .font(.system(.subheadline, weight: .bold))
                            Text(loc("unity.create_in_account_sub"))
                                .font(.system(.caption))
                                .foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(AppTheme.accent)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.md))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                        .strokeBorder(AppTheme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .onAppear { unity.watchGoals(of: account) }
        .onDisappear { unity.stopWatchingGoals(of: account.id) }
        .sheet(isPresented: $creating) {
            SharedGoalFormSheet(account: account)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(item: $detail) { goal in
            SharedGoalDetailView(goal: goal)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(item: $adding) { goal in
            AddContributionSheet(goal: goal, account: account) {}
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
    }

    private func row(_ goal: SharedGoal) -> some View {
        let money = { (v: Double) in CurrencyManager.shared.formatted(v, currency: goal.currency) }
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                HapticManager.shared.tap()
                detail = goal
            } label: {
                HStack(spacing: 12) {
                    Text(goal.emoji)
                        .font(.system(.title3))
                        .frame(width: 42, height: 42)
                        .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(goal.title)
                            .font(.system(.subheadline, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        Text(String(format: loc("unity.saved_of"), money(goal.savedAmount), money(goal.targetAmount)))
                            .font(.system(.caption))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 6)
                    Text("\(Int((goal.progress * 100).rounded()))%")
                        .font(.system(.subheadline, weight: .heavy))
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .buttonStyle(.plain)
            SavingsProgressBar(progress: goal.progress)
            if account.isActive, let me, goal.memberUids.contains(me) {
                Button {
                    HapticManager.shared.tap()
                    adding = goal
                } label: {
                    Label(loc("unity.set_aside"), systemImage: "arrow.down.to.line")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: AppRadius.sm))
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

// MARK: - Target Tabungan without Royal

/// Target Tabungan for someone signed in without Royal: the shared goals
/// they are in or invited to, which need no Royal, and personal goals behind
/// the paywall.
struct SharedGoalsOnlyView: View {
    @State private var showPaywall = false

    var body: some View {
        FeatureStack { pushed in
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(loc("profile.savings"))
                                .font(.system(.title, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(loc("unity.free_sub"))
                                .font(.system(.footnote))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 20)

                        // Making a goal needs Royal; taking part does not.
                        UnitySavingsSection(onCreate: { showPaywall = true })

                        Button {
                            HapticManager.shared.tap()
                            showPaywall = true
                        } label: {
                            HStack(spacing: 12) {
                                Text("👑").font(.system(.title3))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(loc("savings.personal_goal"))
                                        .font(.system(.subheadline, weight: .bold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                    Text(loc("unity.personal_royal"))
                                        .font(.system(.caption))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.system(.caption, weight: .bold))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            .padding(14)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .padding(.horizontal, 22)

                        Spacer(minLength: 100)
                    }
                    .containerRelativeFrame(.horizontal)
                }
            }
            .featureBar(pushed: pushed)
            .sheet(isPresented: $showPaywall) {
                PaywallView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.bg)
                    .preferredColorScheme(appColorScheme())
            }
        }
    }
}
