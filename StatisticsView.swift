import SwiftUI
import SwiftData

// MARK: - Statistics Date Period

enum StatPeriod: String, CaseIterable {
    case thisMonth  = "This month"
    case lastMonth  = "Last month"
    case last3      = "3 months"
    case last6      = "6 months"
    case thisYear   = "This year"
    case allTime    = "All time"
    case custom     = "Custom"

    func dateRange() -> (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .thisMonth:
            let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            return (start, now)
        case .lastMonth:
            let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            let start = cal.date(byAdding: .month, value: -1, to: thisMonthStart)!
            return (start, thisMonthStart)
        case .last3:
            return (cal.date(byAdding: .month, value: -3, to: now)!, now)
        case .last6:
            return (cal.date(byAdding: .month, value: -6, to: now)!, now)
        case .thisYear:
            let start = cal.date(from: cal.dateComponents([.year], from: now))!
            return (start, now)
        case .allTime:
            return (Date.distantPast, now)
        case .custom:
            return (now, now) // overridden by custom state
        }
    }
}

// MARK: - Statistics View

struct StatisticsView: View {
    @State var statsVM: StatsViewModel
    let appVM: AppViewModel
    @State private var selectedPeriod: StatPeriod = .thisMonth
    @State private var customStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var customEnd: Date = Date()
    @State private var showCustomPicker = false

    private var effectiveRange: (start: Date, end: Date) {
        selectedPeriod == .custom
            ? (customStart, customEnd)
            : selectedPeriod.dateRange()
    }

    private var allTx: [TxRecord] {
        let (start, end) = effectiveRange
        return appVM.recentTransactions.filter { $0.date >= start && $0.date <= end }
    }

    private var periodSubtitle: String {
        let fmt = DateFormatter(); fmt.dateFormat = "d MMM yyyy"
        if selectedPeriod == .custom {
            return "\(fmt.string(from: customStart)) – \(fmt.string(from: customEnd))"
        }
        let (start, end) = selectedPeriod.dateRange()
        if selectedPeriod == .allTime { return "All transactions" }
        if selectedPeriod == .thisMonth || selectedPeriod == .lastMonth {
            let mfmt = DateFormatter(); mfmt.dateFormat = "MMMM yyyy"
            return mfmt.string(from: start)
        }
        return "\(fmt.string(from: start)) – \(fmt.string(from: end))"
    }

    private var income: Double {
        allTx.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
    }
    private var expenses: Double {
        allTx.filter { $0.amount < 0 }.reduce(0) { $0 + abs($1.amount) }
    }
    private var netBalance: Double { income - expenses }

    private var realCategories: [SpendCategory] {
        let filtered = statsVM.selectedStatTab == .expenses
            ? allTx.filter { $0.amount < 0 }
            : allTx.filter { $0.amount > 0 }
        var totals: [TxCategory: Double] = [:]
        for tx in filtered { totals[tx.category, default: 0] += abs(tx.amount) }
        return TxCategory.allCases.compactMap { cat in
            guard let amt = totals[cat], amt > 0 else { return nil }
            return SpendCategory(name: cat.rawValue, amount: amt, color: cat.color)
        }
    }

    private var realTotal: Double { realCategories.reduce(0) { $0 + $1.amount } }

    private var displayedTx: [TxRecord] {
        statsVM.selectedStatTab == .expenses
            ? allTx.filter { $0.amount < 0 }
            : allTx.filter { $0.amount > 0 }
    }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Title
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Statistics").font(.system(size: 24, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                            Text(periodSubtitle).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)

                    // Period filter pills
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(StatPeriod.allCases, id: \.self) { period in
                                Button {
                                    HapticManager.shared.tap()
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                        selectedPeriod = period
                                        statsVM.selectedSliceIndex = nil
                                        statsVM.animateIn()
                                        if period == .custom { showCustomPicker = true }
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        if period == .custom {
                                            Image(systemName: "calendar.badge.plus")
                                                .font(.system(size: 11))
                                        }
                                        Text(period.rawValue)
                                            .font(.system(size: 13, weight: selectedPeriod == period ? .semibold : .regular))
                                    }
                                    .foregroundStyle(selectedPeriod == period ? AppTheme.bg : AppTheme.textSecondary)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(selectedPeriod == period ? AppTheme.accent : AppTheme.cardDark, in: Capsule())
                                    .overlay(Capsule().stroke(selectedPeriod == period ? AppTheme.accent : Color.clear, lineWidth: 1))
                                }
                                .buttonStyle(ScaleButtonStyle())
                            }
                        }
                        .padding(.horizontal, 22)
                    }
                    .padding(.top, 12)

                    // Summary cards
                    HStack(spacing: 12) {
                        StatSummaryCard(title: "Income", amount: income, color: AppTheme.accent)
                        StatSummaryCard(title: "Expenses", amount: expenses, color: AppTheme.red)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 16)

                    // Net balance card
                    NetBalanceSummary(net: netBalance, income: income, expenses: expenses)
                        .padding(.horizontal, 22)
                        .padding(.top, 10)

                    StatSegmentPicker(vm: statsVM)
                        .padding(.horizontal, 22)
                        .padding(.top, 20)

                    if realCategories.isEmpty {
                        // Empty state
                        VStack(spacing: 14) {
                            Image(systemName: statsVM.selectedStatTab == .expenses ? "cart" : "arrow.down.circle")
                                .font(.system(size: 40))
                                .foregroundStyle(AppTheme.textSecondary)
                            Text("No \(statsVM.selectedStatTab.rawValue.lowercased()) yet")
                                .font(.system(size: 16)).foregroundStyle(AppTheme.textSecondary)
                            Text("Add transactions to see your statistics")
                                .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                        }
                        .padding(.top, 48)
                    } else {
                        // Real donut with live data
                        LiveDonutChart(categories: realCategories, total: realTotal, statsVM: statsVM)
                            .padding(.top, 24)

                        // Category legend
                        LiveCategoryLegend(categories: realCategories, statsVM: statsVM)
                            .padding(.horizontal, 22)
                            .padding(.top, 16)

                        // Category breakdown
                        if let idx = statsVM.selectedSliceIndex, idx < realCategories.count {
                            LiveBreakdownCard(category: realCategories[idx], total: realTotal)
                                .padding(.horizontal, 22)
                                .padding(.top, 16)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }

                    // Recent transactions for selected tab
                    if !displayedTx.isEmpty {
                        VStack(spacing: 0) {
                            HStack {
                                Text("Recent \(statsVM.selectedStatTab.rawValue)")
                                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                            }
                            .padding(.bottom, 14)
                            VStack(spacing: 12) {
                                ForEach(displayedTx.prefix(5)) { tx in
                                    TxRow(tx: tx)
                                }
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 24)
                    }

                    Spacer(minLength: 110)
                }
            }
        }
        .onAppear {
            statsVM.animateIn()
            // Update categories with real data on appear
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                statsVM.categories = realCategories.isEmpty
                    ? [SpendCategory(name: "No data", amount: 1, color: AppTheme.textSecondary)]
                    : realCategories
            }
        }
        .onChange(of: statsVM.selectedStatTab) { _, _ in
            statsVM.selectedSliceIndex = nil
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: selectedPeriod) { _, _ in
            statsVM.selectedSliceIndex = nil
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: customStart) { _, _ in
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .onChange(of: customEnd) { _, _ in
            withAnimation { statsVM.categories = realCategories }
            statsVM.animateIn()
        }
        .sheet(isPresented: $showCustomPicker) {
            CustomDateRangeSheet(startDate: $customStart, endDate: $customEnd)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
    }
}

// MARK: - Summary Cards

struct StatSummaryCard: View {
    let title: String
    let amount: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
            }
            Text(CurrencyManager.shared.formatted(amount, currency: CurrencyManager.shared.preferredCurrency))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.2), lineWidth: 1))
    }
}

struct NetBalanceSummary: View {
    let net: Double
    let income: Double
    let expenses: Double

    private var percentage: Double {
        guard income > 0 else { return 0 }
        return min((expenses / income) * 100, 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Net balance")
                    .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text(net >= 0 ? "+\(CurrencyManager.shared.formatted(net, currency: CurrencyManager.shared.preferredCurrency))"
                             : CurrencyManager.shared.formatted(net, currency: CurrencyManager.shared.preferredCurrency))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(net >= 0 ? AppTheme.accent : AppTheme.red)
                    .contentTransition(.numericText())
            }
            // Expense ratio bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(AppTheme.accent.opacity(0.2)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 4).fill(AppTheme.red)
                        .frame(width: g.size.width * CGFloat(percentage / 100), height: 6)
                        .animation(.spring(response: 0.8, dampingFraction: 0.8), value: percentage)
                }
            }
            .frame(height: 6)
            HStack {
                Text("\(String(format: "%.0f", percentage))% spent").font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text(net >= 0 ? "\(String(format: "%.0f", 100 - percentage))% saved" : "Overspent")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(net >= 0 ? AppTheme.accent : AppTheme.red)
            }
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Live Donut Chart

struct LiveDonutChart: View {
    let categories: [SpendCategory]
    let total: Double
    @Bindable var statsVM: StatsViewModel

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let cx = size.width / 2, cy = size.height / 2
                let r: CGFloat = min(cx, cy) - 20, lw: CGFloat = 28
                var start = -Double.pi / 2
                let gap = 0.05
                ctx.stroke(Path { p in p.addArc(center: .init(x: cx, y: cy), radius: r, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false) },
                           with: .color(AppTheme.cardDark), style: StrokeStyle(lineWidth: lw))
                for (i, cat) in categories.enumerated() {
                    let fullSweep = (cat.amount / total) * .pi * 2
                    let sweep = fullSweep * statsVM.chartProgress
                    let isSel = statsVM.selectedSliceIndex == i
                    if sweep > gap {
                        var path = Path()
                        path.addArc(center: .init(x: cx, y: cy),
                                    radius: isSel ? r + 7 : r,
                                    startAngle: .radians(start + gap / 2),
                                    endAngle: .radians(start + sweep - gap / 2),
                                    clockwise: false)
                        ctx.stroke(path, with: .color(cat.color),
                                   style: StrokeStyle(lineWidth: isSel ? lw + 10 : lw, lineCap: .round))
                    }
                    start += fullSweep
                }
            }
            .frame(width: 210, height: 210)
            .gesture(DragGesture(minimumDistance: 0).onEnded { val in
                let cx: CGFloat = 105, cy: CGFloat = 105
                let dx = val.location.x - cx, dy = val.location.y - cy
                let dist = sqrt(dx*dx + dy*dy)
                guard dist > 50 && dist < 115 else { statsVM.selectSlice(nil); return }
                var angle = atan2(dy, dx) * 180 / .pi + 90
                if angle < 0 { angle += 360 }
                var cum = 0.0
                for (i, cat) in categories.enumerated() {
                    let sweep = (cat.amount / total) * 360
                    if angle >= cum && angle < cum + sweep { statsVM.selectSlice(i); return }
                    cum += sweep
                }
                statsVM.selectSlice(nil)
            })

            VStack(spacing: 4) {
                Text(CurrencyManager.shared.formatted(total, currency: CurrencyManager.shared.preferredCurrency))
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())
                Text("Total").font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
}

// MARK: - Live Category Legend

struct LiveCategoryLegend: View {
    let categories: [SpendCategory]
    @Bindable var statsVM: StatsViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(categories.enumerated()), id: \.element.id) { i, cat in
                    Button { statsVM.selectSlice(i) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(cat.color).frame(width: 8, height: 8)
                            Text(cat.name).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(statsVM.selectedSliceIndex == i ? AppTheme.textPrimary : AppTheme.textSecondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(statsVM.selectedSliceIndex == i ? cat.color.opacity(0.18) : AppTheme.cardDark, in: Capsule())
                        .overlay(Capsule().stroke(statsVM.selectedSliceIndex == i ? cat.color.opacity(0.5) : Color.clear, lineWidth: 1))
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .animation(.spring(response: 0.3), value: statsVM.selectedSliceIndex)
                }
            }
        }
    }
}

// MARK: - Live Breakdown Card

struct LiveBreakdownCard: View {
    let category: SpendCategory
    let total: Double

    private var pct: Double { total > 0 ? (category.amount / total) * 100 : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Circle().fill(category.color).frame(width: 10, height: 10)
                    Text(category.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                }
                Spacer()
                Text(CurrencyManager.shared.formatted(category.amount, currency: CurrencyManager.shared.preferredCurrency))
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(category.color)
            }
            Text("\(String(format: "%.1f", pct))% of total")
                .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(AppTheme.cardMid).frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [category.color, category.color.opacity(0.5)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * CGFloat(pct / 100), height: 6)
                        .animation(.spring(response: 0.8), value: pct)
                }
            }
            .frame(height: 6)
        }
        .padding(14)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(category.color.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Nav Bar

struct StatsNavBar: View {
    var body: some View {
        HStack {
            Button { HapticManager.shared.tap() } label: {
                ZStack {
                    Circle().fill(AppTheme.cardDark).frame(width: 40, height: 40)
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                }
            }
            .buttonStyle(ScaleButtonStyle())

            Spacer()
            Text("Statistics").font(.system(size: 18, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
            Spacer()

            Button { HapticManager.shared.tap() } label: {
                ZStack {
                    Circle().fill(AppTheme.cardDark).frame(width: 40, height: 40)
                    Image(systemName: "ellipsis").font(.system(size: 16)).foregroundStyle(AppTheme.textPrimary)
                }
            }
            .buttonStyle(ScaleButtonStyle())
        }
    }
}

// MARK: - Segment Picker

struct StatSegmentPicker: View {
    @Bindable var vm: StatsViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StatTab.allCases, id: \.self) { tab in
                Button {
                    vm.switchTab(tab)
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(vm.selectedStatTab == tab ? AppTheme.bg : AppTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            if vm.selectedStatTab == tab {
                                Capsule()
                                    .fill(AppTheme.accent)
                                    .shadow(color: AppTheme.accent.opacity(0.4), radius: 10, y: 4)
                            }
                        }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: vm.selectedStatTab)
            }
        }
        .padding(4)
        .background(AppTheme.cardDark, in: Capsule())
    }
}

// MARK: - Donut Chart View

struct DonutChartView: View {
    @Bindable var vm: StatsViewModel

    var body: some View {
        ZStack {
            AnimatedDonutCanvas(vm: vm)
                .frame(width: 230, height: 230)

            VStack(spacing: 6) {
                Text(CurrencyManager.shared.formatted(vm.total, currency: CurrencyManager.shared.preferredCurrency))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())

                Button {
                    HapticManager.shared.tap()
                } label: {
                    HStack(spacing: 4) {
                        Text(vm.filterPeriod)
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(AppTheme.cardDark, in: Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
    }
}

// MARK: - Animated Donut (Canvas-based for performance)

struct AnimatedDonutCanvas: View {
    @Bindable var vm: StatsViewModel

    private var sliceAngles: [(start: Double, sweep: Double, color: Color)] {
        let total = vm.total
        var result: [(Double, Double, Color)] = []
        var cur = -90.0
        for cat in vm.categories {
            let sweep = (cat.amount / total) * 360
            result.append((cur, sweep, cat.color))
            cur += sweep
        }
        return result
    }

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let cy = size.height / 2
            let r: CGFloat = min(cx, cy) - 20
            let lw: CGFloat = 30

            // Track
            var trackPath = Path()
            trackPath.addArc(center: .init(x: cx, y: cy), radius: r,
                             startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            ctx.stroke(trackPath, with: .color(AppTheme.cardDark), style: StrokeStyle(lineWidth: lw))

            // Slices
            for (i, sl) in sliceAngles.enumerated() {
                let isSelected = vm.selectedSliceIndex == i
                let adjustedR = isSelected ? r + 6 : r
                let gap: Double = 3
                let start = sl.start + gap / 2
                let end = sl.start + sl.sweep * vm.chartProgress - gap / 2

                guard end > start else { continue }

                var path = Path()
                path.addArc(
                    center: .init(x: cx, y: cy),
                    radius: adjustedR,
                    startAngle: .degrees(start),
                    endAngle: .degrees(end),
                    clockwise: false
                )
                let lineW: CGFloat = isSelected ? lw + 8 : lw
                ctx.stroke(path, with: .color(sl.color),
                           style: StrokeStyle(lineWidth: lineW, lineCap: .round))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { val in
                    let center = CGPoint(x: 115, y: 115)
                    let dx = val.location.x - center.x
                    let dy = val.location.y - center.y
                    let dist = sqrt(dx*dx + dy*dy)
                    guard dist > 50 && dist < 115 else {
                        vm.selectSlice(nil)
                        return
                    }
                    var angle = atan2(dy, dx) * 180 / .pi + 90
                    if angle < 0 { angle += 360 }

                    var cumAngle = 0.0
                    for (i, cat) in vm.categories.enumerated() {
                        let sweep = (cat.amount / vm.total) * 360
                        if angle >= cumAngle && angle < cumAngle + sweep {
                            vm.selectSlice(i)
                            return
                        }
                        cumAngle += sweep
                    }
                    vm.selectSlice(nil)
                }
        )
    }
}

// MARK: - Category Legend

struct CategoryLegendRow: View {
    @Bindable var vm: StatsViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(vm.categories.enumerated()), id: \.element.id) { i, cat in
                    Button {
                        vm.selectSlice(i)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(cat.color)
                                .frame(width: 8, height: 8)
                            Text(cat.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(vm.selectedSliceIndex == i ? AppTheme.textPrimary : AppTheme.textSecondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(vm.selectedSliceIndex == i
                                          ? cat.color.opacity(0.18)
                                          : AppTheme.cardDark)
                        )
                        .overlay(
                            Capsule().stroke(vm.selectedSliceIndex == i
                                            ? cat.color.opacity(0.5)
                                            : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: vm.selectedSliceIndex)
                }
            }
        }
    }
}

// MARK: - Category Breakdown Card

struct CategoryBreakdownCard: View {
    let category: SpendCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Circle().fill(category.color).frame(width: 10, height: 10)
                Text(category.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(CurrencyManager.shared.formatted(category.amount, currency: CurrencyManager.shared.preferredCurrency))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(category.color)
            }

            // Mini bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(AppTheme.cardMid).frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [category.color, category.color.opacity(0.5)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * CGFloat(category.amount / 11256), height: 6)
                }
            }
            .frame(height: 6)
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(category.color.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Stats Transaction Section

struct StatsTransactionSection: View {
    let transactions: [TxRecord]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Shopping")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                HStack(spacing: 4) {
                    Text("Recently")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.bottom, 16)

            VStack(spacing: 14) {
                ForEach(transactions.filter { $0.category == .shopping }) { tx in
                    TxRow(tx: tx)
                }
            }
        }
    }
}


// MARK: - Profile Feature Link

struct ProfileFeatureLink: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: { HapticManager.shared.tap(); action() }) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
                    .frame(width: 36, height: 36)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(color.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Card Manager From Profile

struct CardManagerFromProfile: View {
    @State private var vm = AppViewModel()
    @Query(sort: \BankCard.sortOrder) private var liveCards: [BankCard]

    var body: some View {
        NavigationStack {
            CardListView(vm: vm)
        }
        .onAppear { vm.cards = liveCards }
        .onChange(of: liveCards) { _, new in vm.cards = new }
    }
}

// MARK: - Profile View

struct ProfileView: View {
    @Bindable var authVM: AuthViewModel
    @Environment(\.modelContext) private var context

    @State private var appeared          = false
    @State private var showLockConfirm   = false
    @State private var showResetConfirm  = false
    @State private var showChangePIN     = false
    @State private var showSalary        = false
    @State private var showWishlist      = false
    @State private var showCardManager   = false
    @State private var showCurrencyPicker = false
    @State private var preferredCurrency  = CurrencyManager.shared.preferredCurrency

    private var initials: String {
        authVM.savedName.split(separator: " ")
            .prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    Spacer(minLength: 36)

                    // Avatar
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [AppTheme.cardMid, AppTheme.cardDark],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 90, height: 90)
                            .shadow(color: AppTheme.accent.opacity(0.25), radius: 20)
                            .overlay(Circle().stroke(AppTheme.accent.opacity(0.3), lineWidth: 1.5))
                        Text(initials.isEmpty ? "?" : initials)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    .scaleEffect(appeared ? 1 : 0.7)
                    .opacity(appeared ? 1 : 0)

                    Text(authVM.savedName)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .opacity(appeared ? 1 : 0)

                    // Security card
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.fill").font(.system(size: 18)).foregroundStyle(AppTheme.accent)
                                .frame(width: 36, height: 36)
                                .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("6-digit PIN").font(.system(size: 14, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                                Text("Active and secured in Keychain").font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                            }
                            Spacer()
                            Circle().fill(AppTheme.accent).frame(width: 8, height: 8)
                        }
                        Divider().background(AppTheme.cardMid)
                        HStack(spacing: 12) {
                            Image(systemName: authVM.biometricIcon).font(.system(size: 18))
                                .foregroundStyle(authVM.isBiometricAvailable ? AppTheme.accent : AppTheme.textSecondary)
                                .frame(width: 36, height: 36)
                                .background((authVM.isBiometricAvailable ? AppTheme.accent : AppTheme.textSecondary).opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(authVM.biometricLabel).font(.system(size: 14, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                                Text(authVM.isBiometricAvailable ? "Auto-unlocks on launch" : "Not available on this device")
                                    .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                            }
                            Spacer()
                            if authVM.isBiometricAvailable { Circle().fill(AppTheme.accent).frame(width: 8, height: 8) }
                        }
                    }
                    .padding(16)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.accent.opacity(0.18), lineWidth: 1))
                    .padding(.horizontal, 22)
                    .opacity(appeared ? 1 : 0)

                    // Feature links
                    VStack(spacing: 12) {
                        ProfileFeatureLink(icon: "creditcard.fill", color: AppTheme.blue,
                                           title: "Manage Cards",
                                           subtitle: "Add, edit or remove your cards") { showCardManager = true }
                        ProfileFeatureLink(icon: "banknote.fill", color: AppTheme.accent,
                                           title: "Salary Schedule",
                                           subtitle: "Manage your income & payday") { showSalary = true }
                        ProfileFeatureLink(icon: "star.fill", color: AppTheme.orange,
                                           title: "Savings Goals",
                                           subtitle: "Save for what matters most") { showWishlist = true }
                    }
                    .padding(.horizontal, 22)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)
                    .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.12), value: appeared)

                    // Currency settings
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Image(systemName: "dollarsign.circle.fill")
                                .font(.system(size: 18)).foregroundStyle(AppTheme.green)
                                .frame(width: 36, height: 36)
                                .background(AppTheme.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Preferred Currency")
                                    .font(.system(size: 14, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                                Text("Used as default across the app")
                                    .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                            }
                            Spacer()
                            Menu {
                                ForEach(CurrencyManager.supportedCurrencies, id: \.code) { c in
                                    Button {
                                        HapticManager.shared.select()
                                        preferredCurrency = c.code
                                        CurrencyManager.shared.preferredCurrency = c.code
                                    } label: {
                                        Label("\(c.flag) \(c.code) — \(c.name)", systemImage: preferredCurrency == c.code ? "checkmark" : "")
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(CurrencyManager.flag(for: preferredCurrency)).font(.system(size: 16))
                                    Text(preferredCurrency).font(.system(size: 14, weight: .bold)).foregroundStyle(AppTheme.accent)
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .padding(16)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.green.opacity(0.18), lineWidth: 1))
                    .padding(.horizontal, 22)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)
                    .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.16), value: appeared)

                    // Lock button
                    Button { HapticManager.shared.tap(); showLockConfirm = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.fill").font(.system(size: 16))
                            Text("Lock App").font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(AppTheme.accent).frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(AppTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.accent.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(ScaleButtonStyle()).padding(.horizontal, 22).opacity(appeared ? 1 : 0)

                    // Change PIN only
                    Button { HapticManager.shared.tap(); showChangePIN = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "key.fill").font(.system(size: 16))
                            Text("Change PIN").font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(AppTheme.blue).frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(AppTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.blue.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(ScaleButtonStyle()).padding(.horizontal, 22).opacity(appeared ? 1 : 0)

                    // Reset ALL data
                    Button { HapticManager.shared.warning(); showResetConfirm = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "trash.fill").font(.system(size: 16))
                            Text("Reset All Data").font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(AppTheme.red).frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(AppTheme.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.red.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(ScaleButtonStyle()).padding(.horizontal, 22).opacity(appeared ? 1 : 0)

                    Spacer(minLength: 110)
                }
                            }
        }
        .confirmationDialog("Lock App", isPresented: $showLockConfirm, titleVisibility: .visible) {
            Button("Lock Now") { authVM.lockApp() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("You'll need your PIN or \(authVM.biometricLabel) to unlock.") }

        .confirmationDialog("Change PIN", isPresented: $showChangePIN, titleVisibility: .visible) {
            Button("Change PIN") { authVM.startChangePIN() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your cards, transactions, and data will be kept. Only your PIN changes.") }

        .confirmationDialog("Reset All Data", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Reset Everything", role: .destructive) { resetAllData() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently deletes ALL cards, transactions, salary, debts, and goals. Cannot be undone.") }

        .sheet(isPresented: $showCardManager) {
            CardManagerFromProfile()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .sheet(isPresented: $showSalary) {
            SalaryView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .sheet(isPresented: $showWishlist) {
            WishlistView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.1)) { appeared = true }
        }
    }

    private func resetAllData() {
        try? context.delete(model: BankCard.self)
        try? context.delete(model: TxRecord.self)
        try? context.delete(model: SalarySchedule.self)
        try? context.delete(model: DebtRecord.self)
        try? context.delete(model: SavingsGoal.self)
        try? context.save()
        authVM.resetApp()
        HapticManager.shared.warning()
    }
}
