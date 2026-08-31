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
    @State private var showSalarySetup = false
    @State private var showRecommendation = false
    /// The preset the user explicitly tapped. Tracked by identity (not by
    /// ratios) so that two presets sharing the same split — e.g. Student Saver
    /// and Mortgage Payer are both 50/20/30 — never light up together. nil
    /// means "no preset is the active choice" (custom/manual ratios).
    @State private var selectedPreset: BudgetProfile? = nil

    enum BudgetTab: String, CaseIterable {
        case overview, settings, simulate
        /// Was rendered straight from `rawValue`, so these two tab labels stayed
        /// English no matter which language the app was in.
        var titleKey: String {
            switch self {
            case .overview: return "budget.tab_overview"
            case .settings: return "budget.tab_settings"
            case .simulate: return "budget.tab_simulate"
            }
        }
    }

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
        // Choosing a specific card with no override yet is itself a change:
        // the user is explicitly pinning this card's budget so it stops
        // following the global default. This must be savable even when the
        // ratios happen to equal the current global default — otherwise the
        // card silently keeps inheriting global and "can't be saved".
        if editingPerCard, selectedCardID != nil, selectedCardConfig == nil { return true }
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

        // 2. Income transactions on the selected card this period (pay cycle
        //    when a schedule exists, else calendar month).
        return budgetTx
            .filter { $0.amount > 0 && $0.txSubtype != .transfer && $0.date >= periodStart }
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

    /// Day-of-month the salary lands on (selected card's schedule, else any
    /// active schedule). Anchors the budget period to the pay cycle.
    private var payCycleDay: Int? {
        if let s = schedules.first(where: { $0.isActive && $0.cardID == selectedCard?.id }) { return s.dayOfMonth }
        return schedules.first(where: { $0.isActive })?.dayOfMonth
    }

    /// Whether spending is measured over the pay cycle (a salary schedule exists).
    private var usesPayCycle: Bool { payCycleDay != nil }

    /// Start of the budget period. With a salary schedule, spending is measured
    /// over the PAY CYCLE (payday → today) instead of the calendar month — so
    /// "spent vs budget" reflects the actual salary period. This matters when
    /// payday is late in the month (e.g. the 25th): early in the new calendar
    /// month almost nothing is "spent yet", which understated usage badly.
    /// Falls back to the 1st of the month when there's no schedule.
    private var periodStart: Date {
        if let day = payCycleDay { return StatPeriod.payCycleRange(payDay: day).start }
        let cal = Calendar.current
        return cal.safeDate(from: cal.dateComponents([.year, .month], from: Date()))
    }

    /// Human label for the current budget window — a date range for the pay
    /// cycle, or the month name for the calendar-month fallback.
    private var periodLabel: String {
        if let day = payCycleDay {
            let (start, end) = StatPeriod.payCycleRange(payDay: day)
            let f = DateFormatter()
            f.locale = LanguageManager.shared.currentLocale
            f.dateFormat = DateFormatter.dateFormat(fromTemplate: "dMMM", options: 0, locale: f.locale)
            return "\(f.string(from: start)) – \(f.string(from: end))"
        }
        return Date().formatted(.dateTime.month(.wide).year())
    }

    // Over-budget groups using ratios for the selected card (per-card with global fallback)
    private var overGroups: [(group: BudgetGroup, spent: Double, limit: Double, ratio: Double)] {
        guard monthlyIncome > 0 else { return [] }
        let r = SmartBudgetManager.shared.ratios(forCardID: selectedCardID, configs: cardConfigs)
        return BudgetGroup.allCases.compactMap { grp in
            let s = budgetTx.filter { $0.amount < 0 && $0.txSubtype != .transfer && $0.date >= periodStart && SmartBudgetManager.shared.categories(for: grp).contains($0.category) }.reduce(0) { $0 + CurrencyManager.shared.convert(abs($1.amount), from: $1.currency, to: cardCurrency) }
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
                            ForEach(BudgetTab.allCases, id: \.self) { Text(loc($0.titleKey)).tag($0) }
                        }
                        .pickerStyle(.segmented).padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 4)
                    }

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 20) {
                            if isEnabled {
                                switch selectedTab {
                                case .overview: overviewTab
                                case .settings: settingsTab
                                // Take-home pay and pension growth live here,
                                // not in Debts & Credits. They answer income and
                                // cash-flow questions, which is what this screen
                                // is already about — a salary calculator filed
                                // under "what you owe" is somewhere nobody
                                // would think to look.
                                case .simulate:
                                    PlannerView(embedded: true, tools: [.takeHome, .jht])
                                }
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
            // Highlight whichever preset matches the loaded ratios.
            reconcileSelectedPreset()
        }
        // Any ratio change that isn't a preset tap (manual +/-, numeric quick
        // presets, switching cards) keeps the highlighted preset in sync. The
        // reconcile is a no-op when an explicitly-tapped preset still matches.
        .onChange(of: dailyPct)     { _, _ in reconcileSelectedPreset() }
        .onChange(of: lifestylePct) { _, _ in reconcileSelectedPreset() }
        .onChange(of: investPct)    { _, _ in reconcileSelectedPreset() }
        .sheet(isPresented: $showSalarySetup) {
            SalaryView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showRecommendation) {
            SmartRecommendationView(onApply: {
                // Sync the editor to what was just applied. Read through
                // `ratios(forCardID:)` rather than the globals directly: the
                // apply step also updates the selected card's override, and
                // this screen may be showing that card — reading globals here
                // made an applied plan look like it hadn't landed.
                isEnabled = true
                let applied = SmartBudgetManager.shared.ratios(forCardID: selectedCardID, configs: cardConfigs)
                dailyPct     = Int((applied.daily * 100).rounded())
                lifestylePct = Int((applied.lifestyle * 100).rounded())
                investPct    = Int((applied.investDebt * 100).rounded())
                reconcileSelectedPreset()
            })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
                .preferredColorScheme(appColorScheme())
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
                Text(usesPayCycle ? loc("stats.period.pay_cycle") : loc("budget.this_month"))
                    .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                Text(periodLabel)
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

        if monthlyIncome > 0 {
            ForEach(BudgetGroup.allCases, id: \.rawValue) { grp in
                BudgetGroupCard(group: grp, budgetTx: budgetTx, income: monthlyIncome, currency: cardCurrency, cardID: selectedCardID, configs: cardConfigs, periodStart: periodStart)
                    .padding(.horizontal, 22)
            }
        } else {
            // No income this month → budget limits would all be 0 and useless.
            // Prompt the user to set up their salary instead of showing empty
            // budget bars. (Smart Budget = income × ratio, so it needs income.)
            SalarySetupCTA(message: loc("salary.cta.budget")) {
                showSalarySetup = true
            }
            .padding(.horizontal, 22)
        }
        } // end else (card selected)
    }

    // MARK: - Settings Tab

    @ViewBuilder private var settingsTab: some View {
        // ── DiPo's Recommendation — AI-analyzed personalized budget ───────
        // Opens a full confirmation screen that reads the user's real
        // transactions and proposes a smarter split + saving/investing plan.
        Button {
            HapticManager.shared.tap()
            showRecommendation = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.18)).frame(width: 42, height: 42)
                    Image(systemName: "sparkles").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("reco.cta_title")).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    Text(loc("reco.cta_sub")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
            .padding(14)
            .background(
                LinearGradient(colors: [AppTheme.purple, AppTheme.purple.opacity(0.72)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: AppTheme.purple.opacity(0.3), radius: 10, y: 5)
        }
        .buttonStyle(ScaleButtonStyle())
        .padding(.horizontal, 22)
        .padding(.bottom, 6)

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
                            isSelected: isPresetSelected(preset),
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

        // NOTE: the numeric "quick presets" row that used to sit here was
        // removed — the Profile Presets gallery above this section already
        // offers the same splits with better labels, and two preset pickers on
        // one screen left the user unsure which one was authoritative.

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

    /// Whether a preset's ratios equal the current editor values. Pure ratio
    /// test — used only as a tie-broken fallback by `reconcileSelectedPreset`,
    /// never directly for highlighting (two presets can share a ratio).
    private func ratiosMatch(_ preset: BudgetProfile) -> Bool {
        let r = preset.ratios
        return Int(r.daily * 100)      == dailyPct
            && Int(r.lifestyle * 100)  == lifestylePct
            && Int(r.investDebt * 100) == investPct
    }

    /// Highlight rule for a preset card: a preset is "selected" only when it
    /// is the exact one the user chose (identity match). This guarantees at
    /// most one card is ever highlighted, even when several presets share the
    /// same 50/20/30 split.
    private func isPresetSelected(_ preset: BudgetProfile) -> Bool {
        selectedPreset == preset
    }

    /// Keeps `selectedPreset` consistent after any ratio change that did NOT
    /// come from tapping a preset card (manual +/-, the numeric quick presets,
    /// switching cards, first appear). If the user's explicitly-chosen preset
    /// still matches the current ratios we keep it (preserves the Mortgage-vs-
    /// Student identity); otherwise we fall back to the first preset whose
    /// ratios match, or nil when nothing matches (truly custom).
    private func reconcileSelectedPreset() {
        if let sel = selectedPreset, ratiosMatch(sel) { return }
        selectedPreset = BudgetProfile.allCases.first(where: ratiosMatch)
    }

    /// Tap handler for a preset card. Records the explicit identity and loads
    /// the preset's ratios into the editor (doesn't persist yet — user still
    /// has to tap Save). This matches the rest of the form which is also
    /// unsaved-on-edit, so the preset behaves like any other ratio change.
    private func applyPreset(_ preset: BudgetProfile) {
        HapticManager.shared.tap()
        let r = preset.ratios
        selectedPreset = preset
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
    /// Card whose budget is being previewed. Drives per-card ratio lookup so
    /// a saved CardBudgetConfig override is reflected here (nil = global).
    var cardID: String? = nil
    var configs: [CardBudgetConfig] = []
    /// Start of the budget window (pay-cycle aware). Defaults to the 1st of the
    /// month so any legacy call site keeps calendar-month behavior.
    var periodStart: Date = Calendar.current.safeDate(from: Calendar.current.dateComponents([.year, .month], from: Date()))
    @State private var animatedProgress: Double = 0

    private var monthStart: Date { periodStart }
    private var groupTx: [TxRecord] {
        let cats = SmartBudgetManager.shared.categories(for: group)
        return budgetTx.filter { $0.amount < 0 && $0.txSubtype != .transfer && $0.date >= monthStart && cats.contains($0.category) }.sorted { $0.date > $1.date }
    }
    private var spent: Double  { groupTx.reduce(0) { $0 + CurrencyManager.shared.convert(abs($1.amount), from: $1.currency, to: currency) } }
    private var ratio: Double  { SmartBudgetManager.shared.ratio(for: group, cardID: cardID, configs: configs) }
    private var limit: Double  { income * ratio }
    private var progress: Double { limit > 0 ? min(spent / limit, 1.5) : 0 }
    private var isOver: Bool   { spent > limit && limit > 0 }
    private var actualPct: Int { income > 0 ? Int((spent / income) * 100) : 0 }
    private var targetPct: Int { Int(ratio * 100) }

    var body: some View {
        NavigationLink(destination: BudgetGroupDetailView(group: group, budgetTx: budgetTx, income: income, currency: currency, cardID: cardID, configs: configs, periodStart: periodStart)) {
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
    /// Card whose budget is shown — drives per-card ratio (nil = global).
    var cardID: String? = nil
    var configs: [CardBudgetConfig] = []
    /// Start of the budget window (pay-cycle aware). Defaults to month start.
    var periodStart: Date = Calendar.current.safeDate(from: Calendar.current.dateComponents([.year, .month], from: Date()))
    @State private var appeared = false

    private var cal: Calendar  { Calendar.current }
    private var monthStart: Date { periodStart }
    /// End of the current budget window: one month after its start — i.e. the
    /// next payday for a pay cycle, or the 1st of next month in calendar mode.
    private var periodEnd: Date { cal.date(byAdding: .month, value: 1, to: periodStart) ?? periodStart }
    /// Days remaining until the window ends. Pay-cycle aware, so the
    /// "remaining/day" hint paces against days left until the next payday
    /// rather than the calendar month-end.
    private var daysLeft: Int {
        max(cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: periodEnd).day ?? 0, 0)
    }
    private var primary: String  { currency }
    private func fmt(_ amount: Double) -> String {
        CurrencyManager.shared.formatted(amount, currency: primary)
    }

    private var groupTx: [TxRecord] {
        let cats = SmartBudgetManager.shared.categories(for: group)
        return budgetTx.filter { $0.amount < 0 && $0.txSubtype != .transfer && $0.date >= monthStart && cats.contains($0.category) }.sorted { $0.date > $1.date }
    }
    private var spent: Double    { groupTx.reduce(0) { $0 + CurrencyManager.shared.convert(abs($1.amount), from: $1.currency, to: currency) } }
    private var ratio: Double    { SmartBudgetManager.shared.ratio(for: group, cardID: cardID, configs: configs) }
    private var limit: Double    { income * ratio }
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
            let lbl = cal.isDateInToday(d) ? loc("common.today")
                    : cal.isDateInYesterday(d) ? loc("search.period.yesterday")
                    : d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
            return (lbl, d, (dict[d] ?? []).sorted { $0.date > $1.date })
        }
    }

    // MARK: - Budget Bar
    //
    // The track is scaled to max(spent, limit), so the bar never just "pegs at
    // full" the moment you go 1% over — it shows the budgeted part in the group
    // colour and the overspill in red, with a tick marking exactly where the
    // limit sits. Under budget, the right edge of the track IS the limit.
    private var barScale: Double { max(spent, limit, 1) }
    /// Share of the track occupied by spending that is still inside the limit.
    private var withinFraction: Double { min(spent, limit) / barScale }
    /// Share of the track occupied by the overspill (0 when under budget).
    private var overFraction: Double { max(spent - limit, 0) / barScale }
    /// Where the limit tick sits along the track.
    private var limitFraction: Double { limit / barScale }
    /// Percentage of the budget consumed (can exceed 100).
    private var usedOfBudgetPct: Int { limit > 0 ? Int(((spent / limit) * 100).rounded()) : 0 }

    private var budgetBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { g in
                    let W = g.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.cardMid).frame(height: 12)

                        HStack(spacing: 0) {
                            Capsule()
                                .fill(LinearGradient(colors: [group.color.opacity(0.75), group.color],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: W * CGFloat(appeared ? withinFraction : 0))
                            if overFraction > 0 {
                                Capsule()
                                    .fill(LinearGradient(colors: [AppTheme.orange, AppTheme.red],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: W * CGFloat(appeared ? overFraction : 0))
                            }
                        }
                        .frame(height: 12)
                        .clipShape(Capsule())
                        .animation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.1), value: appeared)

                        // Limit tick — only drawn when spending has run past it.
                        if isOver {
                            Capsule().fill(Color.white.opacity(0.92))
                                .frame(width: 2.5, height: 20)
                                .shadow(color: .black.opacity(0.4), radius: 2)
                                .offset(x: W * CGFloat(limitFraction) - 1.25)
                        }
                    }
                    .frame(height: 20)
                }
                .frame(height: 20)

                // Caption anchored under the limit tick.
                if isOver {
                    GeometryReader { g in
                        Text(loc("budget.limit_marker"))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .offset(x: max(min(g.size.width * CGFloat(limitFraction) - 12, g.size.width - 30), 0))
                    }
                    .frame(height: 11)
                }
            }
            Text("\(usedOfBudgetPct)%")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(isOver ? AppTheme.red : group.color)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 46, alignment: .trailing)
        }
    }

    /// One stacked bar showing how the group's spending splits across categories.
    private var compositionStrip: some View {
        GeometryReader { g in
            let gaps = CGFloat(max(catBreakdown.count - 1, 0)) * 2
            let usable = max(g.size.width - gaps, 1)
            HStack(spacing: 2) {
                ForEach(catBreakdown, id: \.cat) { item in
                    Capsule()
                        .fill(item.cat.color)
                        .frame(width: max(usable * CGFloat(item.amount / max(spent, 1)), 3))
                }
            }
            .frame(height: 8)
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 0.5).delay(0.25), value: appeared)
        }
        .frame(height: 8)
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

                        budgetBar
                            .padding(.horizontal, 18)

                        HStack(alignment: .top) {
                            HStack(alignment: .top, spacing: 5) {
                                Circle().fill(isOver ? AppTheme.red : group.color).frame(width: 6, height: 6).padding(.top, 4)
                                Text(isOver
                                     ? String(format: loc("budget.over_detail"), actualPct, overPct, targetPct)
                                     : String(format: loc("budget.under_detail"), actualPct, targetPct))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(isOver ? AppTheme.red : AppTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 10)
                            Text(groupTx.count == 1
                                 ? loc("budget.tx_count_one")
                                 : String(format: loc("budget.tx_count"), groupTx.count))
                                .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                // Was a bare .fixedSize(), which locks BOTH axes:
                                // the text refused to wrap AND refused to shrink.
                                // Next to the long left-hand sentence that pushed
                                // the HStack's minimum width past the screen, so
                                // the whole card — and with it the page — became
                                // wider than the display and drifted sideways.
                                // Locking only the vertical axis keeps it on one
                                // line's worth of height while still yielding
                                // horizontally.
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                        }
                        .padding(.horizontal, 18).padding(.top, 10)

                        Divider().background(AppTheme.cardMid).padding(.horizontal, 18).padding(.vertical, 14)

                        HStack(spacing: 0) {
                            VStack(spacing: 5) {
                                HStack(spacing: 4) { Circle().fill(isOver ? AppTheme.red : AppTheme.textSecondary).frame(width: 6, height: 6); Text(loc("budget.spent")).font(.system(size: 11, weight: .medium)).foregroundStyle(AppTheme.textSecondary) }
                                Text(fmt(spent)).font(.system(size: 14, weight: .bold)).foregroundStyle(isOver ? AppTheme.red : AppTheme.textPrimary).minimumScaleFactor(0.6).lineLimit(1)
                                Text(String(format: loc("budget.pct_income"), actualPct)).font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                            Rectangle().fill(AppTheme.cardMid).frame(width: 1, height: 52)
                            VStack(spacing: 5) {
                                HStack(spacing: 4) { Circle().fill(group.color).frame(width: 6, height: 6); Text(loc("debt.budget")).font(.system(size: 11, weight: .medium)).foregroundStyle(AppTheme.textSecondary) }
                                Text(limit > 0 ? fmt(limit) : "—").font(.system(size: 14, weight: .bold)).foregroundStyle(group.color).minimumScaleFactor(0.6).lineLimit(1)
                                Text(String(format: loc("budget.pct_income"), targetPct)).font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                            Rectangle().fill(AppTheme.cardMid).frame(width: 1, height: 52)
                            VStack(spacing: 5) {
                                HStack(spacing: 4) { Circle().fill(isOver ? AppTheme.red : AppTheme.accent).frame(width: 6, height: 6); Text(isOver ? loc("budget.over_by") : loc("budget.left")).font(.system(size: 11, weight: .medium)).foregroundStyle(AppTheme.textSecondary) }
                                Text(isOver ? fmt(overAmt) : fmt(remaining)).font(.system(size: 14, weight: .bold)).foregroundStyle(isOver ? AppTheme.red : AppTheme.accent).minimumScaleFactor(0.6).lineLimit(1)
                                Text(isOver ? "+\(overPct)%" : String(format: loc("budget.pct_income"), income > 0 ? Int((remaining/income)*100) : 0)).font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .padding(.horizontal, 10).padding(.bottom, 14)

                        if !isOver && remaining > 0 && daysLeft > 0 && limit > 0 {
                            Divider().background(AppTheme.cardMid).padding(.horizontal, 18)
                            HStack(spacing: 8) {
                                Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(group.color)
                                Text(String(format: loc("budget.pace_hint"), fmt(remaining / Double(daysLeft)), daysLeft, targetPct))
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

                    // Category breakdown — every number here is a share of THIS
                    // group's spending, so the bars and the % labels agree.
                    if !catBreakdown.isEmpty && income > 0 {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(loc("tx.by_category")).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary).padding(.horizontal, 22)

                            compositionStrip.padding(.horizontal, 22)

                            VStack(spacing: 14) {
                                ForEach(catBreakdown, id: \.cat) { item in
                                    let share = item.amount / max(spent, 1)
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 9).fill(item.cat.color.opacity(0.14)).frame(width: 36, height: 36)
                                            Image(systemName: item.cat.icon).font(.system(size: 15)).foregroundStyle(item.cat.color)
                                        }
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                Text(item.cat.rawValue).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                                Text("\(Int((share * 100).rounded()))%")
                                                    .font(.system(size: 11, weight: .bold)).foregroundStyle(item.cat.color)
                                                Spacer(minLength: 6)
                                                Text(fmt(item.amount)).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                                    .lineLimit(1).minimumScaleFactor(0.7)
                                            }
                                            GeometryReader { g in
                                                ZStack(alignment: .leading) {
                                                    Capsule().fill(AppTheme.cardMid).frame(height: 5)
                                                    Capsule()
                                                        .fill(LinearGradient(colors: [item.cat.color.opacity(0.75), item.cat.color],
                                                                             startPoint: .leading, endPoint: .trailing))
                                                        .frame(width: max(g.size.width * CGFloat(appeared ? share : 0), share > 0 ? 5 : 0), height: 5)
                                                        .animation(.spring(response: 0.8, dampingFraction: 0.85).delay(0.2), value: appeared)
                                                }
                                            }.frame(height: 5)
                                        }
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
                                                        // Per-transaction "% of income" removed — a single tx is a
                                                        // tiny fraction of monthly income, so it always rounded to
                                                        // "0% of income" and just looked broken. The category
                                                        // breakdown above already shows a meaningful % of income.
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
