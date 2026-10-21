import SwiftUI

// MARK: - Smart Budget for a shared account
//
// The personal Smart Budget splits a salary into Needs, Wants and Savings.
// A shared account has no salary; what it has is the money its members put
// in. So the month's money in is split instead — 50/30/20 until the owner
// picks another split — and each part is measured against what the members
// spent from it. Savings is not a limit but what is left, so going past its
// target is good news.

struct JointSmartBudgetCard: View {
    let account: JointAccount
    var onEdit: (() -> Void)?

    @State private var service = JointAccountService.shared

    private var sb: JointSmartBudget { service.smartBudget(account) }
    private func money(_ v: Int64) -> String { JointMoney.text(v, currency: account.currency) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if sb.hasBase {
                ForEach(JointPot.allCases) { pot in potRow(pot) }
                pace
            } else {
                Text(loc("joint.sb.empty"))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: loc("joint.sb.title"), JointAccountCard.monthName(service.month)))
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                if sb.hasBase {
                    Text(String(format: loc(sb.baseIsLastMonth ? "joint.sb.base_last" : "joint.sb.base"), money(sb.base)))
                        .font(.system(.caption))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            if let onEdit {
                Button {
                    HapticManager.shared.tap()
                    onEdit()
                } label: {
                    HStack(spacing: 4) {
                        Text(account.smartRatios.label)
                        Image(systemName: "slider.horizontal.3")
                    }
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(AppTheme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel(loc("joint.sb.edit"))
            } else {
                Text(account.smartRatios.label)
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(AppTheme.accent.opacity(0.12), in: Capsule())
            }
        }
    }

    private func potRow(_ pot: JointPot) -> some View {
        let cap = sb.cap(pot)
        let isSave = pot == .save
        let value = isSave ? sb.saved : sb.spent(pot)
        let ratio = cap > 0 ? Double(value) / Double(cap) : 0
        let over = !isSave && value > cap
        let tint = isSave ? pot.color : (over ? AppTheme.orange : pot.color)
        let note: String = {
            if isSave {
                return value >= cap ? loc("joint.sb.save_reached")
                                    : String(format: loc("joint.sb.save_short"), money(cap - value))
            }
            return over ? String(format: loc("joint.sb.over"), money(value - cap))
                        : String(format: loc("joint.sb.left"), money(cap - value))
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pot.emoji)
                    .font(.system(.footnote))
                    .frame(width: 26, height: 26)
                    .background(pot.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Text(pot.label)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer(minLength: 6)
                Text(String(format: loc(isSave ? "joint.sb.of_target" : "joint.sb.of"), money(value), money(cap)))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.accentTrack)
                    Capsule().fill(tint).frame(width: g.size.width * min(max(ratio, 0), 1))
                }
            }
            .frame(height: 7)
            Text(note)
                .font(.system(.caption2, weight: over || (isSave && value >= cap) ? .semibold : .regular))
                .foregroundStyle(over ? AppTheme.orange : (isSave && value >= cap ? AppTheme.accent : AppTheme.textSecondary))
        }
        .accessibilityElement(children: .combine)
    }

    private var pace: some View {
        let days = jointDaysLeft(in: service.month)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("joint.sb.per_day"))
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(money(sb.safePerDay(daysLeft: days)))
                    .font(.system(.headline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            Spacer()
            Text(String(format: loc("joint.sb.days_left"), days))
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(12)
        .background(AppTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.sm))
    }
}

/// Two short readings under the card: the biggest category, and who spent.
struct JointSmartInsights: View {
    let account: JointAccount
    @State private var service = JointAccountService.shared

    var body: some View {
        let top = service.topCategory(account.id)
        let byMember = service.spentByMember(account.id)
        VStack(spacing: 8) {
            if let top {
                row(emoji: "📊",
                    title: String(format: loc("joint.sb.top"), top.category.displayLabel),
                    detail: String(format: loc("joint.sb.top_detail"),
                                   JointMoney.text(top.amount, currency: account.currency),
                                   Int((top.share * 100).rounded())))
            }
            if byMember.count > 1 {
                let total = byMember.reduce(Int64(0)) { $0 + $1.amount }
                VStack(alignment: .leading, spacing: 8) {
                    row(emoji: "👥", title: loc("joint.sb.who"),
                        detail: byMember.map { "\(service.name(of: $0.uid, in: account.id)) \(JointMoney.text($0.amount, currency: account.currency))" }
                            .joined(separator: " · "),
                        padded: false)
                    GeometryReader { g in
                        HStack(spacing: 3) {
                            ForEach(Array(byMember.enumerated()), id: \.offset) { i, m in
                                Capsule()
                                    .fill(JointAccountCard.avatarTints[i % JointAccountCard.avatarTints.count])
                                    .frame(width: max((g.size.width - CGFloat(byMember.count - 1) * 3)
                                                      * CGFloat(Double(m.amount) / Double(max(total, 1))), 4))
                            }
                        }
                    }
                    .frame(height: 8)
                    .padding(.leading, 34)
                }
                .padding(14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
            }
        }
    }

    private func row(emoji: String, title: String, detail: String, padded: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(emoji).font(.system(.body))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(detail)
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(padded ? 14 : 0)
        .background(padded ? AppTheme.cardDark : .clear, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The owner's split

struct JointSmartBudgetSheet: View {
    let account: JointAccount

    @Environment(\.dismiss) private var dismiss
    @State private var service = JointAccountService.shared
    @State private var needs: Double
    @State private var wants: Double

    init(account: JointAccount) {
        self.account = account
        _needs = State(initialValue: Double(account.smartRatios.needs))
        _wants = State(initialValue: Double(account.smartRatios.wants))
    }

    private var ratios: JointRatios {
        let n = Int(needs.rounded()), w = Int(wants.rounded())
        return JointRatios(needs: n, wants: w, save: 100 - n - w)
    }
    private var base: Int64 { service.smartBudget(account).base }
    private func amount(_ percent: Int) -> String {
        JointMoney.text(base * Int64(percent) / 100, currency: account.currency)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        caption(loc("joint.sb.presets"))
                        HStack(spacing: 8) {
                            ForEach(JointRatios.presets) { preset in
                                presetTile(preset.ratios, key: preset.key)
                            }
                        }

                        caption(loc("joint.sb.custom"))
                        VStack(spacing: 16) {
                            slider(.needs, value: $needs, range: 0...100) {
                                if needs + wants > 100 { wants = 100 - needs }
                            }
                            slider(.wants, value: $wants, range: 0...100) {
                                if needs + wants > 100 { needs = 100 - wants }
                            }
                            HStack {
                                Text("\(JointPot.save.emoji) \(JointPot.save.label)")
                                    .font(.system(.subheadline, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                Text(base > 0 ? "\(ratios.save)% · \(amount(ratios.save))" : "\(ratios.save)%")
                                    .font(.system(.subheadline))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                        .padding(16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))

                        JointInfo(icon: "info.circle.fill", text: loc("joint.sb.explain"))

                        caption(loc("joint.sb.categories"))
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(JointPot.allCases) { pot in
                                Text("\(pot.emoji) \(pot.label): \(pot.hint)")
                                    .font(.system(.footnote))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))

                        JointPrimaryButton(title: loc("common.save"), enabled: ratios.isValid && ratios != account.smartRatios) {
                            service.setRatios(ratios, for: account)
                            HapticManager.shared.success()
                            dismiss()
                        }
                    }
                    .padding(22)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("joint.sb.settings_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(.footnote, weight: .semibold))
            .foregroundStyle(AppTheme.textSecondary)
    }

    private func presetTile(_ preset: JointRatios, key: String) -> some View {
        let on = preset == ratios
        return Button {
            HapticManager.shared.tap()
            withAnimation(.spring(response: 0.3)) {
                needs = Double(preset.needs)
                wants = Double(preset.wants)
            }
        } label: {
            VStack(spacing: 3) {
                Text("\(preset.needs)/\(preset.wants)/\(preset.save)")
                    .font(.system(.subheadline, weight: .bold).monospacedDigit())
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc(key))
                    .font(.system(.caption2))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(on ? AppTheme.accent.opacity(0.10) : AppTheme.cardDark,
                        in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                .strokeBorder(on ? AppTheme.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func slider(_ pot: JointPot, value: Binding<Double>, range: ClosedRange<Double>,
                        onChange: @escaping () -> Void) -> some View {
        let percent = Int(value.wrappedValue.rounded())
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(pot.emoji) \(pot.label)")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(base > 0 ? "\(percent)% · \(amount(percent))" : "\(percent)%")
                    .font(.system(.subheadline))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Slider(value: value, in: range, step: 5)
                .tint(pot.color)
                .onChange(of: value.wrappedValue) { _, _ in onChange() }
                .accessibilityLabel(pot.label)
        }
    }
}
