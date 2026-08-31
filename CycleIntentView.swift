import SwiftUI
import SwiftData

// MARK: - Cycle Intent picker
//
// Where the user tells DiPo a choice was deliberate. Each option states what
// DiPo will stop saying AND what stays true anyway, side by side, so nobody
// picks one expecting it to make a problem disappear.

struct CycleIntentView: View {
    /// Pay-cycle start as `yyyy-MM-dd`.
    let cycleKey: String
    /// Human label for the cycle ("25 Jun – 23 Jul"), shown for orientation.
    let cycleLabel: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var allIntents: [CycleIntent]

    @State private var expanded: CycleIntentKind? = nil
    @State private var noteDrafts: [String: String] = [:]

    /// Rows that apply to THIS cycle only — recurring ones declared earlier are
    /// shown separately so turning one off is unambiguous.
    private func row(for kind: CycleIntentKind) -> CycleIntent? {
        allIntents.first { $0.kindRaw == kind.rawValue && ($0.cycleKey == cycleKey || ($0.isRecurring && $0.cycleKey <= cycleKey)) }
    }
    private func isOn(_ kind: CycleIntentKind) -> Bool { row(for: kind) != nil }

    private var activeIntentCount: Int {
        CycleIntentKind.allCases.filter { isOn($0) }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        ForEach(CycleIntentKind.allCases) { kind in
                            intentCard(kind)
                        }
                        Text(loc("intent.footer"))
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.textSecondary.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                            .padding(.top, 4)
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 20).padding(.top, 8)
                }
            }
            .navigationTitle(loc("intent.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            // Confirm on the way out, not per toggle. Toggling already shows
            // its own result right there on the card; a toast per tap would
            // just cover the card the user is looking at. What is NOT visible
            // here is the consequence — Deep Analysis softening next cycle —
            // so the exit is where a summary earns its place.
            .doneToolbar {
                ActionFeedbackCenter.shared.intentsSaved(count: activeIntentCount)
                dismiss()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc("intent.subtitle"))
                .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            HStack(spacing: 5) {
                Image(systemName: "calendar").font(.system(size: 10, weight: .semibold))
                Text(cycleLabel).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(AppTheme.purple)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(AppTheme.purple.opacity(0.12), in: Capsule())
        }
    }

    @ViewBuilder
    private func intentCard(_ kind: CycleIntentKind) -> some View {
        let on = isOn(kind)
        let isOpen = expanded == kind
        VStack(alignment: .leading, spacing: 10) {
            Button {
                HapticManager.shared.tap()
                withAnimation(.spring(response: 0.3)) {
                    expanded = isOpen ? nil : kind
                }
            } label: {
                HStack(spacing: 11) {
                    ZStack {
                        Circle().fill(kind.tint.opacity(on ? 0.9 : 0.15)).frame(width: 34, height: 34)
                        Image(systemName: kind.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(on ? .white : kind.tint)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(kind.summary)
                            .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .buttonStyle(.plain)

            if isOpen {
                // What changes vs what doesn't — always shown together.
                VStack(alignment: .leading, spacing: 7) {
                    effectLine("checkmark.circle.fill", AppTheme.accent, loc("intent.effect_label"), kind.effect)
                    effectLine("exclamationmark.circle.fill", AppTheme.orange, loc("intent.tradeoff_label"), kind.tradeoff)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 11))

                TextField(loc("intent.note_placeholder"),
                          text: Binding(
                            get: { noteDrafts[kind.rawValue] ?? row(for: kind)?.note ?? "" },
                            set: { noteDrafts[kind.rawValue] = $0 }))
                    .font(.system(size: 12))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(AppTheme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 8) {
                    Button {
                        HapticManager.shared.success()
                        toggle(kind, recurring: false)
                    } label: {
                        Text(loc(on ? "intent.turn_off" : "intent.apply_cycle"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? AppTheme.red : .white)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(on ? AppTheme.red.opacity(0.14) : kind.tint, in: Capsule())
                    }
                    .buttonStyle(ScaleButtonStyle())

                    if !on {
                        Button {
                            HapticManager.shared.success()
                            toggle(kind, recurring: true)
                        } label: {
                            Text(loc("intent.apply_ongoing"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(kind.tint)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(kind.tint.opacity(0.12), in: Capsule())
                                .overlay(Capsule().stroke(kind.tint.opacity(0.35), lineWidth: 1))
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                }
            } else if on {
                // Collapsed but active — say so, and say which scope.
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 10))
                    Text(loc(row(for: kind)?.isRecurring == true ? "intent.active_ongoing" : "intent.active_cycle"))
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(kind.tint)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(on ? kind.tint.opacity(0.45) : AppTheme.cardMid.opacity(0.4), lineWidth: 1))
    }

    private func effectLine(_ icon: String, _ tint: Color, _ label: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                Text(text).font(.system(size: 11.5)).foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(1.5)
            }
        }
    }

    private func toggle(_ kind: CycleIntentKind, recurring: Bool) {
        if let existing = row(for: kind) {
            context.delete(existing)
            HapticManager.shared.tap()
        } else {
            HapticManager.shared.success()
            context.insert(CycleIntent(kind: kind, cycleKey: cycleKey,
                                       note: (noteDrafts[kind.rawValue] ?? "").trimmingCharacters(in: .whitespaces),
                                       isRecurring: recurring))
        }
        try? context.save()
        withAnimation(.spring(response: 0.3)) { expanded = nil }
    }
}
