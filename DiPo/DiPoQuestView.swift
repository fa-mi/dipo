import SwiftUI
import SwiftData

// MARK: - DiPo Quest: the path
//
// The map of levels, Duolingo-style: unit banners, round level stones that
// wind down the screen, a chest at the end of each unit. Above them, today's
// quests. DiPo stands beside the level to play next.

struct DiPoQuestView: View {
    let isRoyal: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var store = QuestStore.shared
    @Query private var recent: [TxRecord]
    @Query private var checkIns: [DayCheckIn]
    @State private var playing: QuestLevel?
    @State private var showRunner = false
    @State private var showPaywall = false
    @State private var toast: String?
    @State private var soundOn = QuestSound.shared.enabled
    @State private var pulse = false

    init(isRoyal: Bool) {
        self.isRoyal = isRoyal
        let floor = Calendar.current.date(byAdding: .day, value: -DailyCheckIn.historyDays, to: .now) ?? .distantPast
        _recent = Query(filter: #Predicate<TxRecord> { $0.date >= floor })
    }

    private var logged: Set<String> { DailyCheckIn.loggedDays(recent) }
    private var loggedToday: Bool { logged.contains(DailyCheckIn.key(.now)) }
    private var streak: Int { DailyCheckIn.streak(logged: logged, answered: Set(checkIns.map(\.dayKey))) }
    private var state: QuestState { store.state }

    var body: some View {
        ZStack(alignment: .top) {
            AppTheme.bg.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        dailyCard
                        ForEach(QuestCatalog.units) { unit in unitSection(unit) }
                        if state.current == nil {
                            Text(loc("quest.all_done"))
                                .font(.quest(14, .semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        bonusCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 70)
                    .padding(.bottom, 40)
                    .containerRelativeFrame(.horizontal)
                }
                .onAppear {
                    store.refresh()
                    if let current = state.current {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.easeOut(duration: 0.5)) { proxy.scrollTo(current.id, anchor: .center) }
                        }
                    }
                }
            }
            topBar
            if let toast {
                Text(toast)
                    .font(.quest(14, .bold))
                    .foregroundStyle(AppTheme.onVividFill)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(AppTheme.accent, in: Capsule())
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .fullScreenCover(item: $playing) { level in
            QuestLessonView(level: level, isRoyal: isRoyal, streak: streak, loggedToday: loggedToday,
                            onPaywall: { playing = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showPaywall = true } })
                .preferredColorScheme(appColorScheme())
        }
        .fullScreenCover(isPresented: $showRunner) {
            DiPoRunGameView(isRoyal: isRoyal).preferredColorScheme(appColorScheme())
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
        .trackScreen(.quest)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.quest(17, .heavy))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(loc("game.close"))
            Spacer(minLength: 0)
            stat("flame.fill", "\(streak)", AppTheme.orange)
                .accessibilityLabel(String(format: loc("checkin.streak"), streak))
            stat("bolt.fill", "\(state.xp)", AppTheme.royalGoldText)
                .accessibilityLabel(String(format: loc("quest.xp"), state.xp))
            if isRoyal {
                stat("heart.fill", "∞", AppTheme.red)
                    .accessibilityLabel(loc("quest.hearts_unlimited_a11y"))
            } else {
                stat("heart.fill", "\(state.hearts)", AppTheme.red)
                    .accessibilityLabel(String(format: loc("quest.hearts_a11y"), state.hearts))
            }
            Button {
                soundOn.toggle()
                QuestSound.shared.enabled = soundOn
                HapticManager.shared.tap()
            } label: {
                Image(systemName: soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.quest(15, .bold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(loc(soundOn ? "quest.sound_on" : "quest.sound_off"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8).padding(.bottom, 10)
        .background(AppTheme.bg.opacity(0.96))
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.cardMid).frame(height: 1) }
    }

    private func stat(_ icon: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(verbatim: value).monospacedDigit()
        }
        .font(.quest(16, .heavy))
        .foregroundStyle(tint)
        .accessibilityElement(children: .ignore)
    }

    // MARK: Daily quests

    private var dailyCard: some View {
        let q = state.quests(now: .now, loggedToday: loggedToday)
        let opened = state.chestOpenedToday(now: .now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(loc("quest.daily"))
                    .font(.quest(17, .heavy))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(verbatim: "\(q.doneCount)/3")
                    .font(.quest(14, .heavy).monospacedDigit())
                    .foregroundStyle(AppTheme.accent)
            }
            questRow(loc("quest.daily.play"), done: q.played, progress: q.played ? 1 : 0)
            questRow(loc("quest.daily.log"), done: q.logged, progress: q.logged ? 1 : 0)
            questRow(String(format: loc("quest.daily.xp"), QuestState.dailyXPGoal),
                     done: q.xp >= QuestState.dailyXPGoal,
                     progress: min(1, Double(q.xp) / Double(QuestState.dailyXPGoal)))
            if q.allDone && !opened {
                QuestCTA(title: loc("quest.chest.open"), fill: AppTheme.royalGold) {
                    var opened = false
                    store.update { opened = $0.openDailyChest(now: .now, loggedToday: loggedToday) }
                    if opened {
                        QuestFeedback.chest()
                        GameAnalytics.log(.dailyChest)
                        show(String(format: loc("quest.chest.daily_reward"), QuestState.dailyChestXP))
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.cardMid, lineWidth: 2))
    }

    private func questRow(_ title: String, done: Bool, progress: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.quest(18, .bold))
                .foregroundStyle(done ? AppTheme.accent : AppTheme.textSecondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.quest(14, .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.cardMid)
                        Capsule().fill(AppTheme.royalGold).frame(width: g.size.width * progress)
                    }
                }
                .frame(height: 8)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Units

    @ViewBuilder
    private func unitSection(_ unit: QuestUnit) -> some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: loc("quest.unit_label"), unit.id))
                    .font(.quest(12, .heavy))
                    .opacity(0.85)
                Text(unit.title)
                    .font(.quest(20, .heavy))
                Text(unit.subtitle)
                    .font(.quest(13, .semibold))
                    .opacity(0.9)
            }
            .foregroundStyle(AppTheme.onVividFill)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(unit.tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(unit.tint)
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.25))
                }
                .offset(y: 4)
            }
            .padding(.bottom, 4)

            ForEach(Array(unit.levels.enumerated()), id: \.element.id) { i, level in
                levelStone(level, unit: unit, wave: i)
                    .id(level.id)
            }
            chestStone(unit, wave: unit.levels.count)
        }
    }

    /// Stones swing left and right down the path.
    private func swing(_ i: Int) -> CGFloat { [0, -52, -72, -40, 10, 54, 72, 40][i % 8] }

    private func levelStone(_ level: QuestLevel, unit: QuestUnit, wave: Int) -> some View {
        let done = state.isDone(level)
        let open = state.isUnlocked(level)
        let isCurrent = state.current == level
        let fill = open ? unit.tint : AppTheme.cardMid
        let icon = done ? "checkmark" : (open ? (level.isReview ? "crown.fill" : "star.fill") : "lock.fill")
        return ZStack {
            if isCurrent {
                Circle()
                    .stroke(unit.tint.opacity(0.35), lineWidth: 6)
                    .frame(width: 92, height: 92)
                    .scaleEffect(pulse ? 1.06 : 0.96)
            }
            Button {
                guard open else {
                    HapticManager.shared.warning()
                    show(loc("quest.locked"))
                    return
                }
                if !isRoyal && state.hearts == 0 {
                    store.refresh()
                    guard store.state.hearts > 0 else {
                        HapticManager.shared.warning()
                        show(loc("quest.hearts_out"))
                        return
                    }
                }
                QuestFeedback.select()
                playing = level
            } label: {
                Image(systemName: icon)
                    .font(.quest(26, .heavy))
                    .foregroundStyle(open ? AppTheme.onVividFill : AppTheme.textSecondary)
                    .frame(width: 72, height: 64)
            }
            .buttonStyle(ChunkyButtonStyle(fill: fill, ink: AppTheme.onVividFill,
                                           lip: open ? nil : AppTheme.cardMid.opacity(0.6),
                                           radius: 36, depth: 6))
            .accessibilityLabel("\(unit.title), " + (level.isReview ? loc("quest.review")
                                                      : String(format: loc("quest.level_label"), level.index)))
            .accessibilityValue(done ? loc("quest.done") : "")
            if isCurrent {
                Text(loc("quest.start"))
                    .font(.quest(13, .heavy))
                    .foregroundStyle(unit.tint)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.cardMid, lineWidth: 2))
                    .offset(y: -62)
                    .allowsHitTesting(false)
                // DiPo himself, in 3D, turning slowly beside the level you
                // are on. Tap for a hop; drag sideways to turn him.
                DiPoDragonView(interactive: true, spins: true)
                    .frame(width: 104, height: 104)
                    .offset(x: swing(wave) <= 0 ? 116 : -116, y: -6)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: isCurrent ? 104 : 76)
        .offset(x: swing(wave))
        .padding(.top, isCurrent ? 22 : 0)
    }

    private func chestStone(_ unit: QuestUnit, wave: Int) -> some View {
        let done = state.unitDone(unit.id)
        let opened = state.openedUnitChests.contains(unit.id)
        return Button {
            guard done else {
                HapticManager.shared.warning()
                show(loc("quest.chest.locked"))
                return
            }
            guard !opened else { return }
            var ok = false
            store.update { ok = $0.openUnitChest(unit.id) }
            if ok {
                QuestFeedback.chest()
                GameAnalytics.log(.unitChest, unit: unit.id)
                show(String(format: loc("quest.chest.unit_reward"), QuestState.unitChestXP))
            }
        } label: {
            Image(systemName: opened ? "gift" : "gift.fill")
                .font(.quest(28, .heavy))
                .foregroundStyle(done && !opened ? AppTheme.onVividFill : AppTheme.textSecondary)
                .frame(width: 72, height: 64)
                .scaleEffect(done && !opened && pulse ? 1.08 : 1)
        }
        .buttonStyle(ChunkyButtonStyle(fill: done && !opened ? AppTheme.royalGold : AppTheme.cardMid,
                                       lip: done && !opened ? nil : AppTheme.cardMid.opacity(0.6),
                                       radius: 22, depth: 6))
        .accessibilityLabel(loc("quest.chest.open"))
        .offset(x: swing(wave))
    }

    // MARK: Bonus

    private var bonusCard: some View {
        Button {
            HapticManager.shared.tap()
            GameAnalytics.log(.runPlayed)
            showRunner = true
        } label: {
            HStack(spacing: 12) {
                Image("DiPoRunner")
                    .resizable().scaledToFit()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("quest.bonus").uppercased())
                        .font(.quest(11, .heavy))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(loc("game.title"))
                        .font(.quest(17, .heavy))
                        .foregroundStyle(AppTheme.textPrimary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.quest(15, .heavy))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(14)
        }
        .buttonStyle(ChunkyButtonStyle(fill: AppTheme.cardDark, ink: AppTheme.textPrimary,
                                       stroke: AppTheme.cardMid, lip: AppTheme.cardMid))
    }

    private func show(_ message: String) {
        withAnimation(.spring(response: 0.35)) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeOut(duration: 0.3)) { if toast == message { toast = nil } }
        }
    }
}

// MARK: - A level being played

struct QuestLessonView: View {
    let level: QuestLevel
    let isRoyal: Bool
    let streak: Int
    let loggedToday: Bool
    var onPaywall: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var lesson: QuestLesson
    @State private var store = QuestStore.shared
    @State private var mood: DiPoMood = .idle
    @State private var line = "start"
    @State private var praise = loc("quest.right.0")
    @State private var earned = 0
    @State private var confirmQuit = false
    @State private var shake: CGFloat = 0

    init(level: QuestLevel, isRoyal: Bool, streak: Int, loggedToday: Bool, onPaywall: @escaping () -> Void) {
        self.level = level
        self.isRoyal = isRoyal
        self.streak = streak
        self.loggedToday = loggedToday
        self.onPaywall = onPaywall
        let questions = QuestCatalog.questions(for: level, seed: UInt64.random(in: 1...UInt64.max))
        _lesson = State(initialValue: QuestLesson(level: level, questions: questions, unlimitedHearts: isRoyal) {
            QuestStore.shared.update { $0.loseHeart(now: .now) }
            return QuestStore.shared.state.hearts
        })
    }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            switch lesson.phase {
            case .finished:    results
            case .outOfHearts: outOfHearts
            default:           playing
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: lesson.phase)
        .onAppear { GameAnalytics.log(.levelStart, level: level) }
        .confirmationDialog(loc("quest.quit_title"), isPresented: $confirmQuit, titleVisibility: .visible) {
            Button(loc("quest.quit"), role: .destructive) {
                GameAnalytics.log(.levelQuit, level: level)
                dismiss()
            }
            Button(loc("quest.keep"), role: .cancel) {}
        } message: {
            Text(loc("quest.quit_body"))
        }
        .trackScreen(.questLesson)
    }

    // MARK: Playing

    private var playing: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { HapticManager.shared.tap(); confirmQuit = true } label: {
                    Image(systemName: "xmark")
                        .font(.quest(18, .heavy))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(loc("game.close"))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.cardMid)
                        Capsule().fill(AppTheme.accent)
                            .frame(width: max(16, g.size.width * lesson.progress))
                            .overlay(alignment: .top) {
                                Capsule().fill(Color.white.opacity(0.3)).frame(height: 4).padding(.horizontal, 8).padding(.top, 3)
                            }
                            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: lesson.progress)
                    }
                }
                .frame(height: 16)
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                    Text(verbatim: isRoyal ? "∞" : "\(store.state.hearts)").monospacedDigit()
                }
                .font(.quest(17, .heavy))
                .foregroundStyle(AppTheme.red)
            }
            .padding(.horizontal, 16).padding(.top, 10)

            if let q = lesson.question {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(q.title.uppercased(), systemImage: q.kind.icon)
                            .font(.quest(13, .heavy))
                            .foregroundStyle(q.kind.tint)
                        HStack(alignment: .bottom, spacing: 6) {
                            DiPoDragonView(mood: mood, line: line, talkSeconds: 0.8)
                                .frame(width: 96, height: 104)
                                .accessibilityHidden(true)
                            Text(q.prompt)
                                .font(.quest(16, .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 14 + BubbleShape.tail).padding(.trailing, 14).padding(.vertical, 12)
                                .dipoBubble(tail: .leading, hairline: AppTheme.cardMid)
                        }
                        .offset(x: shake)
                        VStack(spacing: 12) {
                            ForEach(Array(q.options.enumerated()), id: \.offset) { i, option in
                                optionButton(option, index: i, question: q)
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 24)
                    // Clamped to the screen: a long option must wrap, not
                    // let the whole question slide sideways.
                    .containerRelativeFrame(.horizontal)
                    .id(q.id + "-\(lesson.index)")
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
                }
                footer(q)
            }
        }
    }

    private func optionButton(_ text: String, index i: Int, question q: QuestQuestion) -> some View {
        let selected = lesson.selected == i
        var fill = AppTheme.cardDark, stroke = AppTheme.cardMid, lip = AppTheme.cardMid, ink = AppTheme.textPrimary
        if case .checked = lesson.phase {
            if i == q.answer {
                fill = AppTheme.accent.opacity(0.15); stroke = AppTheme.accent; lip = AppTheme.accent.opacity(0.6); ink = AppTheme.accent
            } else if selected {
                fill = AppTheme.red.opacity(0.15); stroke = AppTheme.red; lip = AppTheme.red.opacity(0.6); ink = AppTheme.red
            }
        } else if selected {
            fill = AppTheme.blue.opacity(0.15); stroke = AppTheme.blue; lip = AppTheme.blue.opacity(0.6); ink = AppTheme.blue
        }
        return Button {
            guard lesson.phase == .answering else { return }
            QuestFeedback.select()
            withAnimation(.spring(response: 0.25)) { lesson.select(i) }
        } label: {
            Text(text)
                .font(.quest(16, .bold))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 6)
        }
        .buttonStyle(ChunkyButtonStyle(fill: fill, ink: ink, stroke: stroke, lip: lip))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func footer(_ q: QuestQuestion) -> some View {
        switch lesson.phase {
        case .checked(let right):
            let tint = right ? AppTheme.accent : AppTheme.red
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: right ? "checkmark.circle.fill" : "xmark.circle.fill")
                    Text(right ? praise : loc("quest.wrong"))
                }
                .font(.quest(21, .heavy))
                .foregroundStyle(tint)
                if !right, q.options.indices.contains(q.answer) {
                    Text(String(format: loc("quest.answer_was"), q.options[q.answer]))
                        .font(.quest(14, .bold))
                        .foregroundStyle(tint)
                }
                Text(q.explain)
                    .font(.quest(14, .semibold))
                    .foregroundStyle(AppTheme.textPrimary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                QuestCTA(title: loc("quest.continue"), fill: tint) { advance() }
                    .padding(.top, 6)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.14).ignoresSafeArea(edges: .bottom))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        default:
            QuestCTA(title: loc("quest.check"), enabled: lesson.selected != nil) { check() }
                .padding(.horizontal, 18).padding(.vertical, 12)
        }
    }

    private func check() {
        let right = lesson.check()
        if lesson.phase == .outOfHearts {
            QuestFeedback.wrong()
            GameAnalytics.log(.levelFail, level: level)
            return
        }
        if right {
            praise = loc("quest.right.\(Int.random(in: 0...3))")
            QuestFeedback.correct()
            mood = .cheer
        } else {
            QuestFeedback.wrong()
            mood = .worry
            withAnimation(.default) { shake = 10 }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.2).delay(0.05)) { shake = 0 }
        }
        line = UUID().uuidString
    }

    private func advance() {
        HapticManager.shared.tap()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { lesson.next() }
        mood = .idle
        if lesson.phase == .finished {
            var gained = 0
            store.update { gained = $0.finish(level, mistakes: lesson.mistakes, now: .now) }
            earned = gained
            QuestFeedback.complete()
            GameAnalytics.log(.levelComplete, level: level, perfect: lesson.mistakes == 0)
            mood = .cheer
            line = "done"
        }
    }

    // MARK: Results

    private var results: some View {
        let q = store.state.quests(now: .now, loggedToday: loggedToday)
        return VStack(spacing: 14) {
            Spacer(minLength: 10)
            DiPoDragonView(mood: .cheer, line: line, talkSeconds: 1.2)
                .frame(width: 190, height: 190)
                .accessibilityHidden(true)
            Text(loc("quest.done_title"))
                .font(.quest(30, .heavy))
                .foregroundStyle(AppTheme.royalGoldText)
            Text(lesson.mistakes == 0 ? loc("quest.perfect") : loc("quest.done_sub"))
                .font(.quest(15, .semibold))
                .foregroundStyle(AppTheme.textSecondary)
            HStack(spacing: 10) {
                tile(loc("quest.stat.xp"), "bolt.fill", "\(earned)", AppTheme.royalGold)
                tile(loc("quest.stat.accuracy"), "scope", "\(lesson.accuracy)%", AppTheme.accent)
                tile(loc("quest.stat.streak"), "flame.fill", "\(streak)", AppTheme.orange)
            }
            .padding(.top, 10)
            HStack {
                Label(loc("quest.daily"), systemImage: "list.bullet.clipboard.fill")
                    .font(.quest(15, .heavy))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(verbatim: "\(q.doneCount)/3")
                    .font(.quest(15, .heavy).monospacedDigit())
                    .foregroundStyle(AppTheme.accent)
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.cardMid, lineWidth: 2))
            Spacer()
            QuestCTA(title: loc("quest.continue")) { dismiss() }
        }
        .padding(.horizontal, 18).padding(.bottom, 12)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func tile(_ title: String, _ icon: String, _ value: String, _ tint: Color) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.quest(11, .heavy))
                .foregroundStyle(AppTheme.onVividFill)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(tint)
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(verbatim: value).monospacedDigit()
            }
            .font(.quest(20, .heavy))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .background(AppTheme.cardDark)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tint, lineWidth: 2))
        .accessibilityElement(children: .combine)
    }

    // MARK: Out of hearts

    private var outOfHearts: some View {
        VStack(spacing: 14) {
            Spacer()
            DiPoDragonView(mood: .worry, line: "hearts", talkSeconds: 0.8)
                .frame(width: 170, height: 170)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                Image(systemName: "heart.slash.fill")
                Text(loc("quest.hearts_out"))
            }
            .font(.quest(26, .heavy))
            .foregroundStyle(AppTheme.red)
            Text(loc("quest.hearts_out_body"))
                .font(.quest(15, .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
            TimelineView(.periodic(from: .now, by: 1)) { t in
                if let next = store.state.nextHeart(now: t.date) {
                    let left = max(0, Int(next.timeIntervalSince(t.date)))
                    Text(String(format: loc("quest.hearts_next"), String(format: "%d:%02d", left / 60, left % 60)))
                        .font(.quest(16, .heavy).monospacedDigit())
                        .foregroundStyle(AppTheme.textPrimary)
                }
            }
            Spacer()
            QuestCTA(title: loc("quest.hearts_royal"), fill: AppTheme.royalGold) {
                HapticManager.shared.tap()
                onPaywall()
            }
            Button(loc("quest.back")) { dismiss() }
                .font(.quest(16, .heavy))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.vertical, 8)
        }
        .padding(.horizontal, 22).padding(.bottom, 12)
    }
}
