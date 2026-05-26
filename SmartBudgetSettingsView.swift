import SwiftUI
import SwiftData


// MARK: - Smart Budget Settings Sheet

struct SmartBudgetSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @Query(sort: \SalarySchedule.createdAt) private var schedules: [SalarySchedule]
    @Query private var cardConfigs: [CardBudgetConfig]

    @State private var isEnabled    = SmartBudgetManager.shared.isEnabled
    @State private var dailyPct     = Int(SmartBudgetManager.shared.dailyRatio * 100)
    @State private var lifestylePct = Int(SmartBudgetManager.shared.lifestyleRatio * 100)
    @State private var investPct    = Int(SmartBudgetManager.shared.investDebtRatio * 100)
    @State private var selectedTab  = BudgetTab.overview
    @State private var selectedCardID: String? = nil
    /// When true, edits in Settings tab apply to the selected card only.
    /// When false, edits go to global defaults (used when no card is selected
    /// or when the user explicitly chooses "Default for all cards").
    @State private var editingPerCard: Bool = false

    enum BudgetTab: String, CaseIterable { case overview = "Overview"; case settings = "Settings" }

    private var totalPct: Int { dailyPct + lifestylePct + investPct }
    private var isBalanced: Bool { totalPct == 100 }
    private var primary: String { CurrencyManager.shared.preferredCurrency }
    
    /// Existing per-card config for the currently selected card (nil if none yet).
    private var selectedCardConfig: CardBudgetConfig? {
        guard let id = selectedCardID else { return nil }
        return cardConfigs.first(where: { $0.cardID == id })
    }
    
    /// What the ratios *should* be after saving — either per-card config or global.
    private var currentBaselineRatios: (daily: Int, lifestyle: Int, investDebt: Int) {
        if editingPerCard, let cfg = selectedCardConfig {
            return (Int(cfg.dailyRatio * 100),
                    Int(cfg.lifestyleRatio * 100),
                    Int(cfg.investDebtRatio * 100))
        }
        return (Int(SmartBudgetManager.shared.dailyRatio * 100),
                Int(SmartBudgetManager.shared.lifestyleRatio * 100),
                Int(SmartBudgetManager.shared.investDebtRatio * 100))
    }

    private var hasChanges: Bool {
        if isEnabled != SmartBudgetManager.shared.isEnabled { return true }
        let baseline = currentBaselineRatios
        return dailyPct != baseline.daily ||
               lifestylePct != baseline.lifestyle ||
               investPct != baseline.investDebt
    }

    private var canSave: Bool {
        guard hasChanges else { return false }
        return isEnabled ? isBalanced : true
    }

    private var cardCurrency: String {
        selectedCard?.currency ?? CurrencyManager.shared.preferredCurrency
    }

    /// True when income is derived from transactions rather than a salary schedule
    private var incomeIsFromTransactions: Bool {
        // Only count schedules linked to the SELECTED card
        schedules.filter { $0.isActive && $0.cardID == selectedCard?.id }.isEmpty
    }

    /// Monthly income in the selected card's currency.
    ///
    /// Priority:
    ///   1. Salary schedules explicitly linked to the selected card (converted to card currency)
    ///   2. Income transactions on the selected card this month (jobless / irregular income)
    ///   3. Zero — budget structure still shows, just without monetary amounts
    private var monthlyIncome: Double {
        let mgr = CurrencyManager.shared

        // 1. Salary schedules linked to this card
        let cardSchedules = schedules.filter { $0.isActive && $0.cardID == selectedCard?.id }
        if !cardSchedules.isEmpty {
            return cardSchedules.reduce(0.0) { sum, s in
                sum + mgr.convert(s.amount, from: s.currency, to: cardCurrency)
            }
        }

        // 2. Income transactions on the selected card this month
        let cal = Calendar.current
        let monthStart = cal.safeDate(from: cal.dateComponents([.year, .month], from: Date()))
        return budgetTx
            .filter { $0.amount > 0 && $0.date >= monthStart }
            .reduce(0.0) { sum, tx in
                sum + mgr.convert(tx.amount, from: tx.currency, to: cardCurrency)
            }
        // If this is also 0 (jobless / no income yet), monthlyIncome = 0.
        // The UI handles this gracefully by hiding percentage amounts.
    }

    /// Transactions filtered to the selected main card (or all cards if nil)
    private var budgetTx: [TxRecord] {
        if let id = selectedCardID, let card = cards.first(where: { $0.id.uuidString == id }) {
            return card.transactions
        }
        return cards.flatMap { $0.transactions }
    }

    /// Selected card object for display
    private var selectedCard: BankCard? {
        guard let id = selectedCardID else { return nil }
        return cards.first(where: { $0.id.uuidString == id })
    }

    // Over-budget groups using ratios for the selected card (per-card with global fallback)
    private var overGroups: [(group: BudgetGroup, spent: Double, limit: Double, ratio: Double)] {
        guard monthlyIncome > 0 else { return [] }
        let r = SmartBudgetManager.shared.ratios(forCardID: selectedCardID, configs: cardConfigs)
        return BudgetGroup.allCases.compactMap { grp in
            let s = budgetTx.filter { $0.amount < 0 && Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month) && SmartBudgetManager.shared.categories(for: grp).contains($0.category) }.reduce(0) { $0 + CurrencyManager.shared.convert(abs($1.amount), from: $1.currency, to: cardCurrency) }
            let ratio: Double = {
                switch grp {
                case .daily:      return r.daily
                case .lifestyle:  return r.lifestyle
                case .investDebt: return r.investDebt
                }
            }()
            let l = monthlyIncome * ratio
            guard s > l else { return nil }
            return (grp, s, l, ratio)
        }
    }

    var body: some View {
        PremiumGate(feature: .smartBudget) {
        NavigationStack {
            ZStack { AppTheme.bg.ignoresSafeArea()
                VStack(spacing: 0) {

                    // Master toggle
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12).fill(AppTheme.purple.opacity(0.15)).frame(width: 46, height: 46)
                            Image(systemName: "brain.fill").font(.system(size: 20)).foregroundStyle(AppTheme.purple)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc("profile.budget")).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                            Text(loc("budget.sub")).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                        Toggle("", isOn: $isEnabled).tint(AppTheme.purple).labelsHidden()
                            .onChange(of: isEnabled) { _, on in
                                HapticManager.shared.tap()
                                if on {
                                    // Force user to choose a card before proceeding
                                    if selectedCardID == nil {
                                        withAnimation(.spring(response: 0.3)) { selectedTab = .settings }
                                    }
                                }
                            }
                    }
                    .padding(16)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(isEnabled ? AppTheme.purple.opacity(0.35) : Color.clear, lineWidth: 1.5))
                    .padding(.horizontal, 22).padding(.top, 16)

                    // Over-budget alerts
                    if isEnabled && !overGroups.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(overGroups, id: \.group.rawValue) { item in
                                let actualPct = Int((item.spent / monthlyIncome) * 100)
                                let targetPct = Int(item.ratio * 100)
                                let overPct   = actualPct - targetPct
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle().fill(AppTheme.red.opacity(0.15)).frame(width: 36, height: 36)
                                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15)).foregroundStyle(AppTheme.red)
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(String(format: loc("budget.over_budget"), item.group.label))
                                            .font(.system(size: 13, weight: .bold)).foregroundStyle(AppTheme.red)
                                        Text(String(format: loc("budget.over_detail"), actualPct, overPct, targetPct))
                                            .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                                    }
                                    Spacer()
                                }
                                .padding(12)
                                .background(AppTheme.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.red.opacity(0.22), lineWidth: 1))
                            }
                        }
                        .padding(.horizontal, 22).padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if isEnabled {
                        Picker("", selection: $selectedTab) {
                            ForEach(BudgetTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 4)
                    }

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 20) {
                            if isEnabled {
                                if selectedTab == .overview { overviewTab }
                                else { settingsTab }
                            }
                            Spacer(minLength: 40)
                        }.padding(.top, 12)
                    }
                }
            }
            .navigationTitle(loc("profile.budget")).navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) {
                        // Revert local state to whatever was the active baseline
                        // (per-card config if editingPerCard, else global)
                        isEnabled = SmartBudgetManager.shared.isEnabled
                        let baseline = currentBaselineRatios
                        dailyPct      = baseline.daily
                        lifestylePct  = baseline.lifestyle
                        investPct     = baseline.investDebt
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(loc("common.save")) {
                        guard canSave else { return }
                        SmartBudgetManager.shared.isEnabled = isEnabled
                        
                        if editingPerCard, let cardID = selectedCardID {
                            // Save to per-card config (upsert)
                            if let existing = cardConfigs.first(where: { $0.cardID == cardID }) {
                                existing.dailyRatio      = Double(dailyPct) / 100
                                existing.lifestyleRatio  = Double(lifestylePct) / 100
                                existing.investDebtRatio = Double(investPct) / 100
                                existing.updatedAt       = .now
                            } else {
                                let cfg = CardBudgetConfig(
                                    cardID: cardID,
                                    dailyRatio: Double(dailyPct) / 100,
                                    lifestyleRatio: Double(lifestylePct) / 100,
                                    investDebtRatio: Double(investPct) / 100
                                )
                                context.insert(cfg)
                            }
                            try? context.save()
                        } else {
                            // Save to global defaults
                            SmartBudgetManager.shared.dailyRatio      = Double(dailyPct) / 100
                            SmartBudgetManager.shared.lifestyleRatio  = Double(lifestylePct) / 100
                            SmartBudgetManager.shared.investDebtRatio = Double(investPct) / 100
                        }
                        
                        HapticManager.shared.success()
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canSave ? AppTheme.accent : AppTheme.textSecondary.opacity(0.4))
                    .disabled(!canSave)
                }
            }
        }
        .animation(.spring(response: 0.35), value: overGroups.count)
        .onAppear {
            // Auto-select first card for the Overview preview
            if selectedCardID == nil {
                selectedCardID = cards.first?.id.uuidString
            }
        }
        }
    }

    // MARK: - Overview Tab

    @ViewBuilder private var overviewTab: some View {
        // Guard: user must pick a card before seeing the overview
        if selectedCardID == nil {
            VStack(spacing: 16) {
                Image(systemName: "creditcard.trianglebadge.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(AppTheme.orange)
                Text(loc("budget.choose_card"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(loc("budget.card_hint"))
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button {
                    HapticManager.shared.tap()
                    withAnimation(.spring(response: 0.3)) { selectedTab = .settings }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 14))
                        Text(loc("budget.go_settings")).font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(color: AppTheme.accent.opacity(0.35), radius: 10, y: 4)
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(.top, 40)
        } else {

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("budget.this_month")).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                Text(Date().formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
            }
            Spacer()
            if monthlyIncome > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(incomeIsFromTransactions ? loc("budget.from_tx") : loc("budget.from_salary")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    Text(CurrencyManager.shared.formatted(monthlyIncome, currency: primary))
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.accent)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(AppTheme.orange)
                    Text(loc("budget.log_income")).font(.system(size: 12)).foregroundStyle(AppTheme.orange)
                }
            }
        }
        .padding(.horizontal, 22)

        ForEach(BudgetGroup.allCases, id: \.rawValue) { grp in
            BudgetGroupCard(group: grp, budgetTx: budgetTx, income: monthlyIncome, currency: cardCurrency)
                .padding(.horizontal, 22)
        }
        } // end else (card selected)
    }

    // MARK: - Settings Tab

    @ViewBuilder private var settingsTab: some View {
        // ── Profile Presets — quick-pick lifestyle templates ─────────────
        // The default 50/30/20 doesn't fit everyone (mahasiswa kost-an,
        // freelancer with variable income, KPR payer all need different
        // shapes). This gallery lets the user pick a template that matches
        // their situation in one tap; tapping applies the ratios immediately
        // and the edit fields update to match. Custom is always available
        // as the fallback for users who want to tune manually.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.purple)
                Text(loc("budget.preset.section_title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 22)

            Text(loc("budget.preset.section_sub"))
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                .padding(.horizontal, 22)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(BudgetProfile.allCases) { preset in
                        BudgetPresetCard(
                            preset: preset,
                            isSelected: matchesCurrentRatios(preset),
                            onSelect: { applyPreset(preset) }
                        )
                    }
                }
                .padding(.horizontal, 22)
            }
        }
        .padding(.bottom, 16)

        // ── Card Selector — choose which card's budget to edit ───────────
        // "Default for all cards" applies global ratios; selecting a specific
        // card creates/updates a per-card override (CardBudgetConfig).
        VStack(alignment: .leading, spacing: 8) {
            Text(loc("budget.applies_to"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 22)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // "Default" chip — edits go to global ratios
                    Button {
                        HapticManager.shared.tap()
                        editingPerCard = false
                        // Load global ratios into editor
                        dailyPct      = Int(SmartBudgetManager.shared.dailyRatio * 100)
                        lifestylePct  = Int(SmartBudgetManager.shared.lifestyleRatio * 100)
                        investPct     = Int(SmartBudgetManager.shared.investDebtRatio * 100)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "globe").font(.system(size: 12))
                            Text(loc("budget.default_all_cards")).font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(!editingPerCard ? .white : AppTheme.textPrimary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(!editingPerCard ? AppTheme.accent : AppTheme.cardDark, in: Capsule())
                        .overlay(Capsule().stroke(AppTheme.accent.opacity(!editingPerCard ? 0 : 0.2), lineWidth: 1))
                    }
                    .buttonStyle(ScaleButtonStyle())
                    
                    // One chip per card — edits create/update CardBudgetConfig
                    ForEach(cards) { card in
                        let cardID = card.id.uuidString
                        let isSelected = editingPerCard && selectedCardID == cardID
                        let hasConfig = cardConfigs.contains(where: { $0.cardID == cardID })
                        Button {
                            HapticManager.shared.tap()
                            editingPerCard = true
                            selectedCardID = cardID
                            // Load this card's ratios (or global fallback)
                            let r = SmartBudgetManager.shared.ratios(forCardID: cardID, configs: cardConfigs)
                            dailyPct      = Int(r.daily * 100)
                            lifestylePct  = Int(r.lifestyle * 100)
                            investPct     = Int(r.investDebt * 100)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: card.isDigitalWallet ? "wallet.pass.fill" : "creditcard.fill").font(.system(size: 12))
                                Text(card.isDigitalWallet ? card.walletProvider : card.holderName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                if hasConfig {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(isSelected ? .white.opacity(0.85) : AppTheme.accent)
                                }
                            }
                            .foregroundStyle(isSelected ? .white : AppTheme.textPrimary)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(isSelected ? AppTheme.accent : AppTheme.cardDark, in: Capsule())
                            .overlay(Capsule().stroke(AppTheme.accent.opacity(isSelected ? 0 : 0.2), lineWidth: 1))
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                }
                .padding(.horizontal, 22)
            }
            
            // Hint text — explains what's happening
            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                Text(editingPerCard
                     ? loc("budget.editing_per_card")
                     : loc("budget.editing_default"))
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.85))
            }
            .padding(.horizontal, 22)
        }
        .padding(.bottom, 4)
        
        // ── Budget Allocation ─────────────────────────────────────────────
        VStack(spacing: 6) {
            HStack {
                Text(loc("budget.allocation")).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text("\(totalPct)% / 100%").font(.system(size: 13, weight: .bold)).foregroundStyle(isBalanced ? AppTheme.accent : AppTheme.red)
            }.padding(.horizontal, 22)
            if !isBalanced {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(AppTheme.orange)
                    Text(String(format: loc("budget.ratio_warning"), totalPct)).font(.system(size: 12)).foregroundStyle(AppTheme.orange)
                }.padding(.horizontal, 22)
            }
        }
        BudgetRatioCard(group: .daily,      pct: $dailyPct,     otherTotal: lifestylePct + investPct).padding(.horizontal, 22)
        BudgetRatioCard(group: .lifestyle,  pct: $lifestylePct, otherTotal: dailyPct + investPct).padding(.horizontal, 22)
        BudgetRatioCard(group: .investDebt, pct: $investPct,     otherTotal: dailyPct + lifestylePct).padding(.horizontal, 22)

        VStack(alignment: .leading, spacing: 10) {
            Text(loc("budget.presets")).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textSecondary).padding(.horizontal, 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    let presets: [(String, Int, Int, Int, String)] = [
                        ("50/30/20", 50, 30, 20, loc("budget.preset.classic")),
                        ("60/20/20", 60, 20, 20, loc("budget.preset.conservative")),
                        ("40/30/30", 40, 30, 30, loc("budget.preset.aggressive")),
                        ("50/20/30", 50, 20, 30, loc("budget.preset.debt_focus"))
                    ]
                    ForEach(presets, id: \.0) { p in
                        Button {
                            HapticManager.shared.tap()
                            withAnimation(.spring(response: 0.3)) { dailyPct=p.1; lifestylePct=p.2; investPct=p.3 }
                        } label: {
                            VStack(spacing: 3) {
                                Text(p.0).font(.system(size: 14, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                Text(p.4).font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.accent.opacity(0.2), lineWidth: 1))
                        }.buttonStyle(ScaleButtonStyle())
                    }
                }.padding(.horizontal, 22)
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            Text(loc("budget.whats_in")).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textSecondary).padding(.horizontal, 22)
            ForEach(BudgetGroup.allCases, id: \.rawValue) { grp in
                HStack(spacing: 10) {
                    Image(systemName: grp.icon).font(.system(size: 14)).foregroundStyle(grp.color).frame(width: 28)
                    Text(grp.label).font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    // Use displayLabel (localized) instead of rawValue (English-only)
                    Text(SmartBudgetManager.shared.categories(for: grp).map { $0.displayLabel }.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary).multilineTextAlignment(.trailing)
                }.padding(.horizontal, 22)
            }
        }
        
        // ── Reset per-card override (only shown when this card has a saved config)
        if editingPerCard, selectedCardConfig != nil {
            Button {
                HapticManager.shared.tap()
                if let cfg = selectedCardConfig {
                    context.delete(cfg)
                    try? context.save()
                }
                // Switch back to global view
                editingPerCard = false
                dailyPct      = Int(SmartBudgetManager.shared.dailyRatio * 100)
                lifestylePct  = Int(SmartBudgetManager.shared.lifestyleRatio * 100)
                investPct     = Int(SmartBudgetManager.shared.investDebtRatio * 100)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward.circle").font(.system(size: 14))
                    Text(loc("budget.reset_to_default"))
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(AppTheme.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(AppTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.red.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 22)
            .padding(.top, 8)
        }
    }

    // MARK: - Profile Preset Helpers

    /// Tests whether the current ratio editor values match a given preset.
    /// Used to highlight the active preset card. We check the editor state
    /// (`dailyPct` etc.) rather than the persisted ratios so the highlight
    /// updates immediately when the user taps a different preset.
    private func matchesCurrentRatios(_ preset: BudgetProfile) -> Bool {
        let r = preset.ratios
        return Int(r.daily * 100)      == dailyPct
            && Int(r.lifestyle * 100)  == lifestylePct
            && Int(r.investDebt * 100) == investPct
    }

    /// Tap handler for a preset card. Loads the preset's ratios into the
    /// editor (doesn't persist yet — user still has to tap Save). This
    /// matches the rest of the form which is also unsaved-on-edit, so the
    /// preset behaves like any other ratio change.
    private func applyPreset(_ preset: BudgetProfile) {
        HapticManager.shared.tap()
        let r = preset.ratios
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            dailyPct      = Int(r.daily * 100)
            lifestylePct  = Int(r.lifestyle * 100)
            investPct     = Int(r.investDebt * 100)
        }
    }
}

// MARK: - Budget Preset Card

/// One card in the horizontal preset gallery. Compact: icon, name, ratios.
/// Tap = apply preset to editor. Active preset gets a colored border so
/// the user can confirm what's currently loaded.
struct BudgetPresetCard: View {
    let preset: BudgetProfile
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: preset.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(preset.color)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(preset.color)
                    }
                }
                Text(preset.displayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                // Ratio summary — at a glance "this preset is 50/30/20"
                Text("\(Int(preset.ratios.daily * 100))/\(Int(preset.ratios.lifestyle * 100))/\(Int(preset.ratios.investDebt * 100))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(preset.color)
                Text(preset.tagline)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(width: 160, height: 120, alignment: .topLeading)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? preset.color : AppTheme.cardMid.opacity(0.4),
                            lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: isSelected ? preset.color.opacity(0.2) : .clear, radius: 6, y: 2)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Budget Ratio Card

struct BudgetRatioCard: View {
    let group: BudgetGroup
    @Binding var pct: Int
    let otherTotal: Int

    private var maxAllowed: Int { max(100 - otherTotal, 0) }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: group.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(group.color)
                    Text(group.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Button {
                        if pct > 0 { pct -= 5; HapticManager.shared.tap() }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .frame(width: 32, height: 32)
                            .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text("\(pct)%")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(group.color)
                        .frame(width: 50, alignment: .center)
                        .contentTransition(.numericText())
                    Button {
                        if pct < maxAllowed { pct += 5; HapticManager.shared.tap() }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .frame(width: 32, height: 32)
                            .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            // Progress bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(AppTheme.cardMid).frame(height: 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(group.color)
                        .frame(width: g.size.width * CGFloat(pct) / 100, height: 8)
                        .animation(.spring(response: 0.35), value: pct)
                }
            }
            .frame(height: 8)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(group.color.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Budget Group Card

struct BudgetGroupCard: View {
    let group: BudgetGroup
    let budgetTx: [TxRecord]
    let income: Double
    let currency: String
    @State private var animatedProgress: Double = 0

    private var monthStart: Date { Calendar.current.safeDate(from: Calendar.current.dateComponents([.year, .month], from: Date())) }
    private var groupTx: [TxRecord] {
        let cats = SmartBudgetManager.shared.categories(for: group)
        return budgetTx.filter { $0.amount < 0 && $0.date >= monthStart && cats.contains($0.category) }.sorted { $0.date > $1.date }
    }
    private var spent: Double  { groupTx.reduce(0) { $0 + CurrencyManager.shared.convert(abs($1.amount), from: $1.currency, to: currency) } }
    private var ratio: Double  { SmartBudgetManager.shared.ratio(for: group) }
    private var limit: Double  { income * ratio }
    private var progress: Double { limit > 0 ? min(spent / limit, 1.5) : 0 }
    private var isOver: Bool   { spent > limit && limit > 0 }
    private var actualPct: Int { income > 0 ? Int((spent / income) * 100) : 0 }
    private var targetPct: Int { Int(ratio * 100) }

    var body: some View {
        NavigationLink(destination: BudgetGroupDetailView(group: group, budgetTx: budgetTx, income: income, currency: currency)) {
            VStack(spacing: 12) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: group.icon).font(.system(size: 14)).foregroundStyle(group.color)
                        Text(group.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                    }
                    Spacer()
                    if isOver {
                        Text("\(actualPct)% / \(targetPct)%")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(AppTheme.red)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(AppTheme.red.opacity(0.12), in: Capsule())
                    }
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(AppTheme.cardMid).frame(height: 7)
                        RoundedRectangle(cornerRadius: 4).fill(isOver ? AppTheme.red : group.color)
                            .frame(width: g.size.width * min(CGFloat(animatedProgress), 1.0), height: 7)
                    }
                }.frame(height: 7)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc("budget.spent")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        Text(CurrencyManager.shared.formatted(spent, currency: currency))
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(isOver ? AppTheme.red : AppTheme.textPrimary)
                    }
                    Spacer()
                    if limit > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: loc("budget.target_label"), targetPct)).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                            Text(CurrencyManager.shared.formatted(limit, currency: currency))
                                .font(.system(size: 15, weight: .bold)).foregroundStyle(group.color)
                        }
                    }
                }
                if !groupTx.isEmpty {
                    Divider().background(AppTheme.cardMid)
                    VStack(spacing: 8) {
                        ForEach(groupTx.prefix(2)) { tx in
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9).fill(Color(hex: tx.iconBgHex)).frame(width: 30, height: 30)
                                    Text(tx.icon).font(.system(size: tx.icon.count == 1 ? 12 : 15)).foregroundStyle(.white)
                                }
                                Text(tx.name).font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                                Spacer()
                                Text(CurrencyManager.shared.formatted(abs(tx.amount), currency: tx.currency))
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                        if groupTx.count > 2 { Text(String(format: loc("common.plus_more"), groupTx.count - 2)).font(.system(size: 11)).foregroundStyle(group.color).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle").font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                        Text(loc("tx.no_spending")).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(isOver ? AppTheme.red.opacity(0.35) : group.color.opacity(0.15), lineWidth: isOver ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .onAppear { withAnimation(.easeInOut(duration: 1.0).delay(0.15)) { animatedProgress = progress } }
    }
}

// MARK: - Budget Group Detail View

struct BudgetGroupDetailView: View {
    let group: BudgetGroup
    let budgetTx: [TxRecord]
    let income: Double
    let currency: String
    @State private var appeared = false

    private var cal: Calendar  { Calendar.current }
    private var monthStart: Date { cal.safeDate(from: cal.dateComponents([.year, .month], from: Date())) }
    private var daysInMonth: Int { cal.range(of: .day, in: .month, for: Date())?.count ?? 28 }
    private var dayOfMonth: Int  { cal.component(.day, from: Date()) }
    private var daysLeft: Int    { daysInMonth - dayOfMonth }
    private var primary: String  { currency }
    private func fmt(_ amount: Double) -> String {
        CurrencyManager.shared.formatted(amount, currency: primary)
    }

    private var groupTx: [TxRecord] {
        let cats = SmartBudgetManager.shared.categories(for: group)
        return budgetTx.filter { $0.amount < 0 && $0.date >= monthStart && cats.contains($0.category) }.sorted { $0.date > $1.date }
    }
    private var spent: Double    { groupTx.reduce(0) { $0 + CurrencyManager.shared.convert(abs($1.amount), from: $1.currency, to: currency) } }
    private var ratio: Double    { SmartBudgetManager.shared.ratio(for: group) }
    private var limit: Double    { income * ratio }
    private var progress: Double { limit > 0 ? min(spent / limit, 1.5) : 0 }
    private var isOver: Bool     { spent > limit && limit > 0 }
    private var remaining: Double { max(limit - spent, 0) }
    private var overAmt: Double  { max(spent - limit, 0) }
    private var actualPct: Int   { income > 0 ? Int((spent / income) * 100) : 0 }
    private var targetPct: Int   { Int(ratio * 100) }
    private var overPct: Int     { max(actualPct - targetPct, 0) }

    private var catBreakdown: [(cat: TxCategory, amount: Double)] {
        SmartBudgetManager.shared.categories(for: group).compactMap { cat in
            let a = groupTx.filter { $0.category == cat }.reduce(0) { $0 + CurrencyManager.shared.convert(abs($1.amount), from: $1.currency, to: currency) }
            return a > 0 ? (cat, a) : nil
        }.sorted { $0.amount > $1.amount }
    }
    private var grouped: [(label: String, date: Date, txs: [TxRecord])] {
        var dict: [Date: [TxRecord]] = [:]
        for tx in groupTx { let d = cal.startOfDay(for: tx.date); dict[d, default: []].append(tx) }
        return dict.keys.sorted(by: >).map { d in
            let lbl = cal.isDateInToday(d) ? "Today" : cal.isDateInYesterday(d) ? "Yesterday" : d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
            return (lbl, d, (dict[d] ?? []).sorted { $0.date > $1.date })
        }
    }

    var body: some View {
        ZStack { AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    // Hero summary card
                    VStack(spacing: 0) {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14).fill(isOver ? AppTheme.red.opacity(0.12) : group.color.opacity(0.12)).frame(width: 52, height: 52)
                                Image(systemName: group.icon).font(.system(size: 24)).foregroundStyle(isOver ? AppTheme.red : group.color)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.label).font(.system(size: 18, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                Text(SmartBudgetManager.shared.categories(for: group).map { $0.rawValue }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                            }
                            Spacer()
                            if isOver {
                                VStack(spacing: 2) {
                                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(AppTheme.red)
                                    Text(loc("debt.over")).font(.system(size: 10, weight: .bold)).foregroundStyle(AppTheme.red)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(AppTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)

                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 6).fill(AppTheme.cardMid).frame(height: 10)
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isOver ? LinearGradient(colors: [AppTheme.orange, AppTheme.red], startPoint: .leading, endPoint: .trailing)
                                          : LinearGradient(colors: [group.color, group.color.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: g.size.width * min(CGFloat(appeared ? progress : 0), 1.0), height: 10)
                                    .animation(.spring(response: 1.0, dampingFraction: 0.8).delay(0.1), value: appeared)
                                if isOver {
                                    Rectangle().fill(Color.white.opacity(0.7)).frame(width: 2, height: 16)
                                        .offset(x: g.size.width * min(CGFloat(limit / max(spent, 1)), 1.0) - 1, y: -3)
                                }
                            }
                        }.frame(height: 10).padding(.horizontal, 18)

                        HStack {
                            HStack(spacing: 5) {
                                Circle().fill(isOver ? AppTheme.red : group.color).frame(width: 6, height: 6)
                                Text(isOver
                                     ? "Using \(actualPct)% of income — \(overPct)% above your \(targetPct)% target"
                                     : "Using \(actualPct)% of income (target: \(targetPct)%)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(isOver ? AppTheme.red : AppTheme.textSecondary)
                            }
                            Spacer()
                            Text("\(groupTx.count) transaction\(groupTx.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        }
                        .padding(.horizontal, 18).padding(.top, 8)

                        Divider().background(AppTheme.cardMid).padding(.horizontal, 18).padding(.vertical, 14)

                        HStack(spacing: 0) {
                            VStack(spacing: 5) {
                                HStack(spacing: 4) { Circle().fill(isOver ? AppTheme.red : AppTheme.textSecondary).frame(width: 6, height: 6); Text(loc("budget.spent")).font(.system(size: 11, weight: .medium)).foregroundStyle(AppTheme.textSecondary) }
                                Text(fmt(spent)).font(.system(size: 14, weight: .bold)).foregroundStyle(isOver ? AppTheme.red : AppTheme.textPrimary).minimumScaleFactor(0.6).lineLimit(1)
                                Text("\(actualPct)% of income").font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                            Rectangle().fill(AppTheme.cardMid).frame(width: 1, height: 52)
                            VStack(spacing: 5) {
                                HStack(spacing: 4) { Circle().fill(group.color).frame(width: 6, height: 6); Text(loc("debt.budget")).font(.system(size: 11, weight: .medium)).foregroundStyle(AppTheme.textSecondary) }
                                Text(limit > 0 ? fmt(limit) : "—").font(.system(size: 14, weight: .bold)).foregroundStyle(group.color).minimumScaleFactor(0.6).lineLimit(1)
                                Text("\(targetPct)% of income").font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                            Rectangle().fill(AppTheme.cardMid).frame(width: 1, height: 52)
                            VStack(spacing: 5) {
                                HStack(spacing: 4) { Circle().fill(isOver ? AppTheme.red : AppTheme.accent).frame(width: 6, height: 6); Text(isOver ? "Over by" : "Left").font(.system(size: 11, weight: .medium)).foregroundStyle(AppTheme.textSecondary) }
                                Text(isOver ? fmt(overAmt) : fmt(remaining)).font(.system(size: 14, weight: .bold)).foregroundStyle(isOver ? AppTheme.red : AppTheme.accent).minimumScaleFactor(0.6).lineLimit(1)
                                Text(isOver ? "+\(overPct)%" : "\(income > 0 ? Int((remaining/income)*100) : 0)% of income").font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .padding(.horizontal, 10).padding(.bottom, 14)

                        if !isOver && remaining > 0 && daysLeft > 0 && limit > 0 {
                            Divider().background(AppTheme.cardMid).padding(.horizontal, 18)
                            HStack(spacing: 8) {
                                Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(group.color)
                                Text("\(fmt(remaining / Double(daysLeft)))/day for the remaining \(daysLeft) days to stay within \(targetPct)%")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.textSecondary)
                                Spacer()
                            }.padding(.horizontal, 18).padding(.vertical, 12)
                        }
                    }
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(isOver ? AppTheme.red.opacity(0.3) : group.color.opacity(0.18), lineWidth: isOver ? 1.5 : 1))
                    .padding(.horizontal, 22)
                    .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 20)
                    .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.05), value: appeared)

                    // Category breakdown
                    if !catBreakdown.isEmpty && income > 0 {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(loc("tx.by_category")).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary).padding(.horizontal, 22)
                            VStack(spacing: 10) {
                                ForEach(catBreakdown, id: \.cat) { item in
                                    let catPct = Int((item.amount / income) * 100)
                                    VStack(spacing: 6) {
                                        HStack(spacing: 10) {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 8).fill(item.cat.color.opacity(0.12)).frame(width: 32, height: 32)
                                                Image(systemName: item.cat.icon).font(.system(size: 14)).foregroundStyle(item.cat.color)
                                            }
                                            Text(item.cat.rawValue).font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                                            Spacer()
                                            Text(fmt(item.amount)).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                            Text("\(catPct)% of income").font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary).frame(width: 72, alignment: .trailing)
                                        }
                                        GeometryReader { g in
                                            ZStack(alignment: .leading) {
                                                RoundedRectangle(cornerRadius: 3).fill(AppTheme.cardMid).frame(height: 4)
                                                RoundedRectangle(cornerRadius: 3).fill(item.cat.color)
                                                    .frame(width: g.size.width * CGFloat(appeared ? item.amount / max(spent, 1) : 0), height: 4)
                                                    .animation(.spring(response: 0.8, dampingFraction: 0.8).delay(0.2), value: appeared)
                                            }
                                        }.frame(height: 4)
                                    }.padding(.horizontal, 22)
                                }
                            }
                        }
                        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 16)
                        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.1), value: appeared)
                    }

                    // Transactions
                    if !grouped.isEmpty {
                        // ✅ Capture computed properties before nested closures to avoid scope issues
                        let currencyCode = primary
                        
                        VStack(alignment: .leading, spacing: 16) {
                            Text(loc("home.transactions")).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary).padding(.horizontal, 22)
                            VStack(spacing: 12) {
                                ForEach(grouped, id: \.date) { grp in
                                    VStack(alignment: .leading, spacing: 8) {
                                        let dayTotal = grp.txs.reduce(0) { $0 + CurrencyManager.shared.convert(abs($1.amount), from: $1.currency, to: currency) }
                                        HStack {
                                            Text(grp.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                                            Spacer()
                                            Text(CurrencyManager.shared.formatted(dayTotal, currency: currencyCode)).font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.red.opacity(0.7))
                                        }.padding(.horizontal, 22)
                                        VStack(spacing: 0) {
                                            ForEach(grp.txs) { tx in
                                                let converted = CurrencyManager.shared.convert(abs(tx.amount), from: tx.currency, to: currency)
                                                HStack(spacing: 14) {
                                                    ZStack {
                                                        RoundedRectangle(cornerRadius: 12).fill(Color(hex: tx.iconBgHex)).frame(width: 44, height: 44)
                                                        Text(tx.icon).font(.system(size: tx.icon.count == 1 ? 16 : 20)).foregroundStyle(.white)
                                                    }
                                                    VStack(alignment: .leading, spacing: 3) {
                                                        Text(tx.name).font(.system(size: 14, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                                                        HStack(spacing: 6) {
                                                            Text(tx.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                                            Text(tx.category.rawValue).font(.system(size: 10, weight: .semibold)).foregroundStyle(tx.category.color)
                                                                .padding(.horizontal, 7).padding(.vertical, 2).background(tx.category.color.opacity(0.12), in: Capsule())
                                                        }
                                                    }
                                                    Spacer()
                                                    VStack(alignment: .trailing, spacing: 2) {
                                                        Text(CurrencyManager.shared.formatted(abs(tx.amount), currency: tx.currency)).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                                        if tx.currency.uppercased() != currencyCode.uppercased() {
                                                            Text("≈ \(CurrencyManager.shared.formatted(converted, currency: currencyCode))").font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                                                        }
                                                        if income > 0 {
                                                            Text("\(Int((converted / income) * 100))% of income").font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                                                        }
                                                    }
                                                }
                                                .padding(.horizontal, 16).padding(.vertical, 12)
                                                if tx.id != grp.txs.last?.id { Divider().background(AppTheme.cardMid).padding(.horizontal, 16) }
                                            }
                                        }
                                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 22)
                                    }
                                }
                            }
                        }
                        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 16)
                        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.15), value: appeared)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(AppTheme.textSecondary)
                            Text(String(format: loc("budget.no_spending"), group.label.lowercased())).font(.system(size: 15)).foregroundStyle(AppTheme.textSecondary)
                        }.padding(.top, 32)
                    }
                    Spacer(minLength: 40)
                }.padding(.top, 16)
            }
        }
        .navigationTitle(group.label).navigationBarTitleDisplayMode(.large)
        .toolbarBackground(AppTheme.bg, for: .navigationBar)
        .onAppear { withAnimation { appeared = true } }
    }
}
