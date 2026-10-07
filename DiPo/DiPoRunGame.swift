import SwiftUI
import SwiftData

// MARK: - DiPo Lari Hemat (DiPo Run)
//
// A one-thumb runner, opened from Ask DiPo. DiPo runs through rice fields on
// his own; a tap makes him jump (twice in the air at most). Coins are savings.
// The obstacles are everyday money traps — a fake sale, a quick-cash loan app,
// an impulse checkout, a shady arisan — each on its own coloured signboard, and
// the rare green shield is an emergency fund that absorbs one hit. When the run
// ends DiPo explains the trap that got him.
//
// Logging a transaction today earns an extra life, so the game nudges the
// habit the app is for. Free plays three runs a day; Royal plays without
// limit. There is no prize and nothing to buy: the coins are only a score.
//
// Everything runs on the main actor through a TimelineView: the model steps
// once per frame and a Canvas draws it — no SpriteKit, no render thread. The
// look was drawn in the browser first; day in light mode, night in dark.

enum RunTrap: String, CaseIterable {
    case fakeSale, quickLoan, impulseBuy, shadyArisan

    var label: String { loc("game.trap.\(rawValue)") }
    var lesson: String { loc("game.lesson.\(rawValue)") }
    var symbol: String {
        switch self {
        case .fakeSale:    return "percent"
        case .quickLoan:   return "banknote.fill"
        case .impulseBuy:  return "cart.fill"
        case .shadyArisan: return "person.3.fill"
        }
    }
    /// Each trap has its own colour, so they can be told apart at speed.
    var color: Color {
        switch self {
        case .fakeSale:    return AppTheme.orange
        case .quickLoan:   return AppTheme.red
        case .impulseBuy:  return AppTheme.purple
        case .shadyArisan: return AppTheme.indigo
        }
    }
}

struct RunEntity: Identifiable {
    enum Kind: Equatable { case coin, shield, trap(RunTrap) }
    let id: Int
    let kind: Kind
    var x: Double
    let y: Double        // bottom of the entity, measured up from the ground
    let w: Double
    let h: Double
    /// Spin offset, so a row of coins does not turn in step.
    let phase: Double

    static func size(of kind: Kind) -> (w: Double, h: Double) {
        switch kind {
        case .coin:   return (32, 32)
        case .shield: return (36, 36)
        case .trap:   return (58, 70)
        }
    }
}

/// A word that floats up from where something happened: "+Rp1.000", "−1 life".
struct RunPopup: Identifiable {
    enum Kind { case coin, shield, saved, life }
    let id: Int
    let kind: Kind
    let x: Double
    let y: Double
    var age: Double = 0
    static let lifetime = 0.9
}

/// A puff of dust where DiPo takes off or lands.
struct RunDust: Identifiable {
    let id: Int
    var x: Double
    var y: Double
    let vx: Double
    let vy: Double
    var age: Double = 0
    static let lifetime = 0.45
}

/// The game's rules, with no drawing in it, so it can be tested.
@MainActor
@Observable
final class RunGame {
    // World, in points, set from the canvas size.
    private(set) var width: Double = 390
    static let dipoX: Double = 64
    static let dipoSize: Double = 92
    static let gravity: Double = 2600
    static let jumpSpeed: Double = 980
    static let startSpeed: Double = 280
    static let maxSpeed: Double = 640
    /// Each coin is this many rupiah of savings on the score.
    static let coinValue = 1_000
    /// How long the "tap to jump" hint shows at the start of a run.
    static let hintSeconds = 3.0

    // Everything that moves every frame is left out of observation. The
    // canvas redraws each frame anyway, from TimelineView; observing these
    // made every frame invalidate the screen around it as well — the HUD,
    // its glass, the hint — which is where the stutter on a jump or a coin
    // came from. Only what the HUD and the cards show is observed, and that
    // changes a few times a run, not sixty times a second.
    @ObservationIgnored private(set) var dipoY: Double = 0          // height above the ground
    @ObservationIgnored private(set) var vy: Double = 0
    @ObservationIgnored private var jumpsLeft = 2
    @ObservationIgnored private(set) var entities: [RunEntity] = []
    @ObservationIgnored private(set) var popups: [RunPopup] = []
    @ObservationIgnored private(set) var dust: [RunDust] = []
    private(set) var coins = 0
    private(set) var lives: Int
    private(set) var shielded = false
    @ObservationIgnored private(set) var speed: Double = RunGame.startSpeed
    @ObservationIgnored private(set) var elapsed: Double = 0
    /// Distance run, for the scenery to scroll by.
    @ObservationIgnored private(set) var distance: Double = 0
    private(set) var running = false
    private(set) var over = false
    private(set) var lastTrap: RunTrap? = nil
    /// Seconds of blinking after a hit, while another hit cannot land.
    @ObservationIgnored private(set) var invulnerable: Double = 0
    /// Seconds left of the red flash and the screen shake after a hit.
    @ObservationIgnored private(set) var flash: Double = 0
    @ObservationIgnored private(set) var shake: Double = 0
    /// Seconds left of the squash after landing.
    @ObservationIgnored private(set) var landing: Double = 0
    /// Whether the "tap to jump" hint shows: stored, and set only when it
    /// flips, so the screen hears about it twice a run rather than every frame.
    private(set) var showsHint = false

    @ObservationIgnored private var nextSpawn: Double = 1.1
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var rng: SplitMix
    /// The frame time last stepped from; kept here, not in the view's state,
    /// so a new frame does not invalidate the view.
    @ObservationIgnored private var lastTick: Date? = nil
    let startingLives: Int

    init(bonusLife: Bool, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        startingLives = bonusLife ? 4 : 3
        lives = startingLives
        rng = SplitMix(seed: seed)
    }

    var saved: Int { coins * Self.coinValue }

    func resize(width: Double) { self.width = max(240, width) }

    func start() {
        guard !running else { return }
        running = true
        over = false
        lastTick = nil
        updateHint()
    }

    /// Steps the world to the frame at `now`.
    func tick(_ now: Date) {
        if let last = lastTick { step(now.timeIntervalSince(last)) }
        lastTick = running ? now : nil
    }

    private func updateHint() {
        let shows = running && elapsed < Self.hintSeconds
        if shows != showsHint { showsHint = shows }
    }

    func restart() {
        dipoY = 0; vy = 0; jumpsLeft = 2
        entities = []; popups = []; dust = []
        coins = 0; lives = startingLives; shielded = false
        speed = Self.startSpeed; elapsed = 0; distance = 0; nextSpawn = 1.1
        lastTrap = nil; invulnerable = 0; flash = 0; shake = 0; landing = 0
        over = false; running = true; lastTick = nil
        updateHint()
    }

    func jump() {
        if !running { start() }
        guard !over, jumpsLeft > 0 else { return }
        vy = Self.jumpSpeed * (jumpsLeft == 2 ? 1 : 0.86)
        jumpsLeft -= 1
        puff(3)
    }

    /// Advances the world by `dt` seconds.
    func step(_ dt: Double) {
        guard running, !over else { return }
        let dt = min(dt, 1.0 / 20)   // a hitch must not teleport him through a trap
        elapsed += dt
        speed = min(Self.maxSpeed, Self.startSpeed + elapsed * 9)
        distance += speed * dt
        invulnerable = max(0, invulnerable - dt)
        flash = max(0, flash - dt)
        shake = max(0, shake - dt)
        landing = max(0, landing - dt)

        // DiPo
        let wasInAir = dipoY > 0
        vy -= Self.gravity * dt
        dipoY += vy * dt
        if dipoY <= 0 {
            if wasInAir { landing = 0.12; puff(4) }
            dipoY = 0; vy = 0; jumpsLeft = 2
        }

        // World
        for i in entities.indices { entities[i].x -= speed * dt }
        entities.removeAll { $0.x + $0.w < -30 }
        for i in popups.indices { popups[i].age += dt }
        popups.removeAll { $0.age >= RunPopup.lifetime }
        for i in dust.indices {
            dust[i].age += dt
            dust[i].x += dust[i].vx * dt
            dust[i].y += dust[i].vy * dt
        }
        dust.removeAll { $0.age >= RunDust.lifetime }

        nextSpawn -= dt
        if nextSpawn <= 0 { spawn() }

        collide()
        updateHint()
    }

    /// Puts an entity in the world directly; used by tests to stage a moment.
    func place(_ kind: RunEntity.Kind, x: Double, y: Double = 0) {
        let s = RunEntity.size(of: kind)
        entities.append(RunEntity(id: nextID, kind: kind, x: x, y: y, w: s.w, h: s.h, phase: 0))
        nextID += 1
        nextSpawn = 99
    }

    private func add(_ kind: RunEntity.Kind, x: Double, y: Double) {
        let s = RunEntity.size(of: kind)
        entities.append(RunEntity(id: nextID, kind: kind, x: x, y: y, w: s.w, h: s.h, phase: rng.next01() * 6))
        nextID += 1
    }

    private func spawn() {
        let roll = rng.next01()
        let x = width + 30
        if roll < 0.42 {
            let all = RunTrap.allCases
            add(.trap(all[Int(rng.next01() * Double(all.count)) % all.count]), x: x, y: 0)
        } else if roll < 0.95 {
            let y: Double = rng.next01() < 0.5 ? 26 : 170     // on the path, or a jump up
            // Sometimes a short row, which reads as a trail to follow.
            let count = rng.next01() < 0.35 ? 3 : 1
            for i in 0..<count { add(.coin, x: x + Double(i) * 42, y: y) }
        } else {
            add(.shield, x: x, y: 130)
        }
        // Faster world, closer spawns, but always room to land between traps.
        let gap = 0.55 + rng.next01() * 0.75
        nextSpawn = gap * (Self.startSpeed / speed) + 0.28
    }

    private func puff(_ n: Int) {
        for _ in 0..<n {
            dust.append(RunDust(id: nextID, x: Self.dipoX + 30 + rng.next01() * 30, y: 0,
                                vx: -60 - rng.next01() * 80, vy: 40 + rng.next01() * 60))
            nextID += 1
        }
    }

    private func pop(_ kind: RunPopup.Kind, x: Double, y: Double) {
        popups.append(RunPopup(id: nextID, kind: kind, x: x, y: y))
        nextID += 1
    }

    private func collide() {
        // A smaller box than the picture, so a near miss is a miss.
        let pad = 16.0
        let dx0 = Self.dipoX + pad, dx1 = Self.dipoX + Self.dipoSize - pad
        let dy0 = dipoY + 6, dy1 = dipoY + Self.dipoSize - pad
        var hit: [Int] = []
        for e in entities {
            let overlaps = e.x < dx1 && e.x + e.w > dx0 && e.y < dy1 && e.y + e.h > dy0
            guard overlaps else { continue }
            switch e.kind {
            case .coin:
                coins += 1
                hit.append(e.id)
                pop(.coin, x: e.x + e.w / 2, y: e.y + e.h)
            case .shield:
                shielded = true
                hit.append(e.id)
                pop(.shield, x: e.x, y: e.y + e.h)
            case .trap(let trap):
                guard invulnerable == 0 else { continue }
                hit.append(e.id)
                if shielded {
                    shielded = false
                    pop(.saved, x: Self.dipoX + Self.dipoSize / 2, y: dipoY + Self.dipoSize + 10)
                } else {
                    lives -= 1
                    lastTrap = trap
                    flash = 0.25
                    shake = 0.3
                    pop(.life, x: Self.dipoX + Self.dipoSize / 2, y: dipoY + Self.dipoSize + 10)
                    if lives <= 0 { over = true; running = false }
                }
                invulnerable = 1.0
            }
        }
        entities.removeAll { hit.contains($0.id) }
    }
}

/// A small, seedable random source, so a test can replay a run.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next01() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: - Daily plays

enum RunPlays {
    static let freePerDay = 3
    private static func key(_ day: Date) -> String { "game_plays_" + DailyCheckIn.key(day) }

    static func used(on day: Date = .now) -> Int { UserDefaults.standard.integer(forKey: key(day)) }
    static func record(on day: Date = .now) { UserDefaults.standard.set(used(on: day) + 1, forKey: key(day)) }
    static func left(isRoyal: Bool, on day: Date = .now) -> Int? {
        isRoyal ? nil : max(0, freePerDay - used(on: day))
    }
}

// MARK: - Screen

struct DiPoRunGameView: View {
    let isRoyal: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Query private var todays: [TxRecord]
    @AppStorage("game_best_saved") private var best = 0
    @State private var game: RunGame
    @State private var showPaywall = false
    @State private var playsLeft: Int?
    @State private var counted = false
    @State private var newBest = false

    init(isRoyal: Bool) {
        self.isRoyal = isRoyal
        let start = Calendar.current.startOfDay(for: .now)
        _todays = Query(filter: #Predicate<TxRecord> { $0.date >= start })
        // The bonus life is decided when the screen opens; see onAppear.
        _game = State(initialValue: RunGame(bonusLife: false))
        _playsLeft = State(initialValue: RunPlays.left(isRoyal: isRoyal))
    }

    private var bonusLife: Bool { !todays.isEmpty }
    private var outOfPlays: Bool { (playsLeft ?? 1) <= 0 }

    var body: some View {
        ZStack {
            AppTheme.gameSkyTop.ignoresSafeArea()
            GeometryReader { geo in
                // Paused between runs: the start and finish cards sit on a still frame.
                TimelineView(.animation(minimumInterval: nil, paused: !game.running)) { timeline in
                    Canvas { ctx, size in
                        RunScene(game: game, dark: scheme == .dark,
                                 time: timeline.date.timeIntervalSinceReferenceDate)
                            .draw(&ctx, size: size)
                    }
                    .onChange(of: timeline.date) { _, now in game.tick(now) }
                }
                .onAppear { game.resize(width: geo.size.width) }
                .onChange(of: geo.size.width) { _, w in game.resize(width: w) }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { tap() }
            .accessibilityElement()
            .accessibilityLabel(loc("game.title"))
            .accessibilityHint(loc("game.tap_hint"))
            .accessibilityAddTraits(.allowsDirectInteraction)

            VStack(spacing: 0) {
                hud
                Spacer()
                if game.showsHint {
                    Label(loc("game.hint"), systemImage: "hand.tap.fill")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(hudFill, in: Capsule())
                        .padding(.bottom, 48)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.4), value: game.showsHint)
            if !game.running {
                Color.black.opacity(0.12).ignoresSafeArea().allowsHitTesting(false)
                if game.over { overCard } else { startCard }
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .onAppear {
            if bonusLife { game = RunGame(bonusLife: true) }
        }
        .onChange(of: game.over) { _, over in
            if over, !counted { finish() }
        }
    }

    private func tap() {
        if game.running {
            HapticManager.shared.tap()
            game.jump()
        }
    }

    private func begin() {
        guard !outOfPlays else { showPaywall = true; return }
        HapticManager.shared.tap()
        counted = false
        newBest = false
        if game.over { game.restart() } else { game.start() }
    }

    private func finish() {
        counted = true
        HapticManager.shared.error()
        newBest = game.saved > best
        best = max(best, game.saved)
        if !isRoyal {
            RunPlays.record()
            playsLeft = RunPlays.left(isRoyal: false)
        }
    }

    private func rupiah(_ v: Int) -> String { CurrencyManager.shared.formatted(Double(v), currency: "IDR") }

    // MARK: HUD

    /// Solid rather than glass: a blur over a canvas that redraws every frame
    /// is recomputed every frame, and the HUD sits over it the whole run.
    private var hudFill: Color { AppTheme.cardDark.opacity(0.88) }

    private var hud: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(hudFill, in: Circle())
            }
            .accessibilityLabel(loc("game.close"))
            HStack(spacing: 3) {
                // Lost lives stay as outlines, so the count reads against the total.
                ForEach(0..<game.startingLives, id: \.self) { i in
                    Image(systemName: i < game.lives ? "heart.fill" : "heart")
                        .foregroundStyle(i < game.lives ? AppTheme.red : AppTheme.textSecondary.opacity(0.5))
                }
                if game.shielded {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(AppTheme.accent)
                        .padding(.leading, 3)
                }
            }
            .font(.system(.footnote, weight: .semibold))
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(hudFill, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: loc("game.lives"), game.lives))
            Spacer()
            HStack(spacing: 6) {
                CoinBadge(size: 16)
                Text(rupiah(game.saved))
                    .font(.system(.subheadline, weight: .bold).monospacedDigit())
                    .foregroundStyle(AppTheme.textPrimary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(hudFill, in: Capsule())
        }
        .padding(.horizontal, 14).padding(.top, 8)
        .animation(.spring(response: 0.3), value: game.coins)
    }

    // MARK: Start and finish

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12, content: content)
            .padding(.horizontal, 18).padding(.vertical, 20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AppTheme.royalGold.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
            .padding(.horizontal, 18)
    }

    private var startCard: some View {
        card {
            Image("DiPoMascot")
                .resizable().scaledToFit()
                .frame(height: 84)
                .accessibilityHidden(true)
            Text(loc("game.title"))
                .font(.system(.title, design: .serif, weight: .semibold).italic())
                .foregroundStyle(AppTheme.royalGoldText)
            VStack(alignment: .leading, spacing: 8) {
                rule(icon: AnyView(Image(systemName: "arrow.up").foregroundStyle(AppTheme.accent)),
                     tint: AppTheme.accent, text: loc("game.rule.jump"))
                rule(icon: AnyView(CoinBadge(size: 16)), tint: AppTheme.royalGold, text: loc("game.rule.coin"))
                rule(icon: AnyView(Image(systemName: "shield.lefthalf.filled").foregroundStyle(AppTheme.accent)),
                     tint: AppTheme.accent, text: loc("game.rule.shield"))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(RunTrap.allCases, id: \.self) { trap in
                    HStack(spacing: 7) {
                        Image(systemName: trap.symbol)
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(trap.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text(trap.label)
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(2).minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(AppTheme.cardDark.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            meta
            startButton
            if let left = playsLeft, !outOfPlays {
                Text(String(format: loc("game.plays_left"), left, RunPlays.freePerDay))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private var overCard: some View {
        card {
            VStack(spacing: 2) {
                Text(loc("game.you_saved"))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(rupiah(game.saved))
                    .font(.system(size: 34, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(AppTheme.textPrimary)
            }
            if newBest {
                Text(loc("game.new_best"))
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(AppTheme.royalGoldText)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(AppTheme.royalGold.opacity(0.2), in: Capsule())
            }
            if let trap = game.lastTrap {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: trap.symbol)
                        .font(.system(.footnote, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(trap.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(format: loc("game.caught_by"), trap.label))
                            .font(.system(.subheadline, weight: .bold))
                        Text(trap.lesson)
                            .font(.system(.subheadline))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AppTheme.textPrimary)
                .padding(14)
                .dipoBubble()
            }
            meta
            startButton
            Button { dismiss() } label: {
                Text(loc("game.close"))
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(AppTheme.cardMid, in: Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
        }
    }

    private func rule(icon: AnyView, tint: Color, text: String) -> some View {
        HStack(spacing: 10) {
            icon
                .font(.system(.footnote, weight: .bold))
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(text)
                .font(.system(.subheadline))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var meta: some View {
        VStack(spacing: 4) {
            Text(String(format: loc("game.best"), rupiah(best)))
                .font(.system(.footnote))
                .foregroundStyle(AppTheme.textSecondary)
            if bonusLife {
                Label(loc("game.bonus_life"), systemImage: "heart.circle.fill")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            if outOfPlays {
                Text(String(format: loc("game.no_plays"), RunPlays.freePerDay))
                    .font(.system(.footnote))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var startButton: some View {
        Button(action: begin) {
            Text(outOfPlays ? loc("game.royal") : (game.over ? loc("game.again") : loc("game.start")))
                .font(.system(.body, weight: .bold))
                .foregroundStyle(AppTheme.onVividFill)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(AppTheme.accentFill, in: Capsule())
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

/// A small gold coin, for the score and the rules.
private struct CoinBadge: View {
    let size: CGFloat
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [AppTheme.royalGoldLight, AppTheme.dipoCrown, AppTheme.royalGold],
                                 center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: size * 0.7))
            .overlay(Circle().stroke(AppTheme.royalGold.opacity(0.8), lineWidth: 1))
            .frame(width: size, height: size)
    }
}

// MARK: - Drawing

/// Draws one frame: sky, sun or moon, clouds, hills, rice terraces, palms,
/// the path, the coins and traps, DiPo, and the floating words.
private struct RunScene {
    let game: RunGame
    let dark: Bool
    let time: Double

    func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let ground = h * 0.8
        let d = game.distance
        var c = ctx
        if game.shake > 0 {
            c.translateBy(x: CGFloat(sin(time * 90)) * 6 * game.shake / 0.3, y: 0)
        }

        // Sky
        c.fill(Path(CGRect(x: -10, y: 0, width: w + 20, height: ground + 2)),
               with: .linearGradient(Gradient(colors: [AppTheme.gameSkyTop, AppTheme.gameSkyLow]),
                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: ground)))
        if dark {
            for i in 0..<40 {
                let x = Double((i * 97) % Int(max(1, w)))
                let y = Double((i * 53) % Int(max(1, ground * 0.55))) + 20
                let a = 0.35 + 0.35 * sin(time * 1.6 + Double(i))
                c.fill(Path(CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(.white.opacity(a)))
            }
        }
        // Sun by day, a full moon by night
        let sun = CGPoint(x: w * 0.78, y: h * 0.2)
        c.fill(Path(ellipseIn: CGRect(x: sun.x - 90, y: sun.y - 90, width: 180, height: 180)),
               with: .radialGradient(Gradient(colors: [AppTheme.gameSun.opacity(dark ? 0.35 : 0.55), AppTheme.gameSun.opacity(0)]),
                                     center: sun, startRadius: 10, endRadius: 90))
        let r: CGFloat = dark ? 24 : 32
        c.fill(Path(ellipseIn: CGRect(x: sun.x - r, y: sun.y - r, width: r * 2, height: r * 2)), with: .color(AppTheme.gameSun))
        if dark {
            for (cx, cy, cr) in [(-7.0, -5.0, 5.0), (6, 4, 4), (2, -10, 2.5)] {
                c.fill(Path(ellipseIn: CGRect(x: sun.x + cx - cr, y: sun.y + cy - cr, width: cr * 2, height: cr * 2)),
                       with: .color(AppTheme.gameHillFar.opacity(0.25)))
            }
        }
        // Clouds
        for i in 0..<4 {
            let span = w + 200
            let x = (Double(i) * 170 - d * 0.06).truncatingRemainder(dividingBy: span)
            let cx = (x + span).truncatingRemainder(dividingBy: span) - 100
            cloud(&c, x: cx, y: h * 0.12 + Double(i) * 38, s: i % 2 == 0 ? 0.8 : 1.2)
        }
        // Hills and terraces
        hills(&c, w: w, h: h, off: d * 0.15, base: ground - 150, a1: 26, a2: 14, f1: 0.006, f2: 0.013, ph: 1, color: AppTheme.gameHillFar)
        hills(&c, w: w, h: h, off: d * 0.35, base: ground - 80, a1: 20, a2: 10, f1: 0.009, f2: 0.021, ph: 3, color: AppTheme.gameHillNear)
        for k in 1..<4 {
            var p = Path()
            var x = 0.0
            while x <= w {
                let y = ground - 80 - wave(x + d * 0.35, 0.009, 0.021, 20, 10, 3) + Double(k) * 18
                if x == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                x += 8
            }
            c.stroke(p, with: .color(dark ? AppTheme.gameTree.opacity(0.6) : .white.opacity(0.35)), lineWidth: 1.5)
        }
        for i in 0..<6 {
            let span = w + 260
            let x = ((Double(i) * 230 - d * 0.55).truncatingRemainder(dividingBy: span) + span)
                .truncatingRemainder(dividingBy: span) - 80
            palm(&c, x: x, base: ground - 4, s: 0.75 + Double((i * 37) % 5) / 10)
        }
        // Path: grass, then soil with pebbles
        c.fill(Path(CGRect(x: -10, y: ground, width: w + 20, height: h - ground)),
               with: .linearGradient(Gradient(colors: [AppTheme.gameSoil, AppTheme.gameSoilDeep]),
                                     startPoint: CGPoint(x: 0, y: ground), endPoint: CGPoint(x: 0, y: h)))
        c.fill(Path(CGRect(x: -10, y: ground - 2, width: w + 20, height: 12)), with: .color(AppTheme.accent))
        c.fill(Path(CGRect(x: -10, y: ground + 8, width: w + 20, height: 4)), with: .color(AppTheme.gameGrassDeep))
        for i in 0..<14 {
            let span = w + 40
            let x = ((Double(i) * 61 - d).truncatingRemainder(dividingBy: span) + span).truncatingRemainder(dividingBy: span) - 20
            let y = ground + 26 + Double((i * 29) % Int(max(1, h - ground - 40)))
            c.fill(Path(roundedRect: CGRect(x: x, y: y, width: 18, height: 4), cornerRadius: 2),
                   with: .color(AppTheme.gamePost.opacity(0.25)))
        }

        // Coins, shields, traps
        for e in game.entities {
            let rect = CGRect(x: e.x, y: ground - e.y - e.h, width: e.w, height: e.h)
            switch e.kind {
            case .coin:   coin(&c, rect: rect, phase: e.phase)
            case .shield: shieldPickup(&c, rect: rect)
            case .trap(let t): trap(&c, rect: rect, trap: t, ground: ground)
            }
        }

        // Dust
        for p in game.dust {
            let a = max(0, 1 - p.age / RunDust.lifetime) * 0.6
            let rad = 5 + p.age * 14
            c.fill(Path(ellipseIn: CGRect(x: p.x - rad, y: ground - p.y * 0.3 - 4 - rad, width: rad * 2, height: rad * 2)),
                   with: .color(AppTheme.gamePost.opacity(a * 0.6)))
        }

        // DiPo: shadow, shield bubble, then him — bobbing as he runs, tilting in the air
        let ds = RunGame.dipoSize
        let lift = max(0.35, 1 - game.dipoY / 260)
        c.fill(Path(ellipseIn: CGRect(x: RunGame.dipoX + ds / 2 - 50 * lift, y: ground + 4 - 6 * lift,
                                      width: 100 * lift, height: 12 * lift)), with: .color(.black.opacity(0.16)))
        let bob = game.running && game.dipoY == 0 ? abs(sin(time * 16)) * 4 : 0
        let tilt = game.dipoY > 0 ? (game.vy > 0 ? -0.12 : 0.1) : sin(time * 16) * 0.04
        let squash = game.landing > 0 ? 0.9 : 1.0
        let centre = CGPoint(x: RunGame.dipoX + ds / 2, y: ground - game.dipoY - bob)
        if game.shielded {
            let pr = 1 + sin(time * 5.5) * 0.04
            let rad = ds * 0.62 * pr
            let bubble = Path(ellipseIn: CGRect(x: centre.x - rad, y: centre.y - ds / 2 - rad, width: rad * 2, height: rad * 2))
            c.fill(bubble, with: .color(AppTheme.accent.opacity(0.16)))
            c.stroke(bubble, with: .color(AppTheme.accent.opacity(0.7)), lineWidth: 2)
        }
        let blink = game.invulnerable > 0 && Int(game.invulnerable * 10) % 2 == 0
        if !blink {
            var dc = c
            dc.translateBy(x: centre.x, y: centre.y)
            dc.rotate(by: .radians(tilt))
            dc.scaleBy(x: 1 / sqrt(squash), y: squash)
            // DiPo in 3D, seen from the side and running right — rendered from
            // the same model as the DiPo on Home, small enough to draw cheaply.
            dc.draw(Image("DiPoRunner"), in: CGRect(x: -ds / 2, y: -ds, width: ds, height: ds))
        }

        // Floating words
        for p in game.popups {
            let a = 1 - p.age / RunPopup.lifetime
            let (text, color): (String, Color) = {
                switch p.kind {
                case .coin:   return ("+" + CurrencyManager.shared.formatted(Double(RunGame.coinValue), currency: "IDR"), AppTheme.royalGoldText)
                case .shield: return (loc("game.popup.shield"), AppTheme.accent)
                case .saved:  return (loc("game.popup.saved"), AppTheme.accent)
                case .life:   return (loc("game.popup.life"), AppTheme.red)
                }
            }()
            let at = CGPoint(x: p.x, y: ground - p.y - p.age * 50)
            var tc = c
            tc.opacity = a
            // One drop shadow instead of a four-way halo: a fifth of the text work.
            tc.draw(Text(text).font(.system(size: 15, weight: .heavy))
                .foregroundStyle(dark ? Color.black.opacity(0.6) : Color.white.opacity(0.95)),
                    at: CGPoint(x: at.x, y: at.y + 1.5))
            tc.draw(Text(text).font(.system(size: 15, weight: .heavy)).foregroundStyle(color), at: at)
        }

        // Red flash on a hit
        if game.flash > 0 {
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(AppTheme.red.opacity(game.flash * 0.8)))
        }
    }

    // MARK: Pieces

    private func wave(_ x: Double, _ f1: Double, _ f2: Double, _ a1: Double, _ a2: Double, _ ph: Double) -> Double {
        a1 * sin(x * f1 + ph) + a2 * sin(x * f2 + ph * 1.7)
    }

    private func hills(_ c: inout GraphicsContext, w: Double, h: Double, off: Double, base: Double,
                       a1: Double, a2: Double, f1: Double, f2: Double, ph: Double, color: Color) {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: h))
        var x = 0.0
        while x <= w + 8 {
            p.addLine(to: CGPoint(x: x, y: base - wave(x + off, f1, f2, a1, a2, ph)))
            x += 8
        }
        p.addLine(to: CGPoint(x: w, y: h))
        p.closeSubpath()
        c.fill(p, with: .color(color))
    }

    private func cloud(_ c: inout GraphicsContext, x: Double, y: Double, s: Double) {
        var p = Path()
        p.addEllipse(in: CGRect(x: x - 30 * s, y: y - 14 * s, width: 60 * s, height: 28 * s))
        p.addEllipse(in: CGRect(x: x, y: y - 24 * s, width: 44 * s, height: 32 * s))
        p.addEllipse(in: CGRect(x: x + 18 * s, y: y - 12 * s, width: 52 * s, height: 24 * s))
        c.fill(p, with: .color(AppTheme.gameCloud.opacity(dark ? 0.55 : 0.92)))
    }

    private func palm(_ c: inout GraphicsContext, x: Double, base: Double, s: Double) {
        var t = c
        t.translateBy(x: x, y: base)
        t.scaleBy(x: s, y: s)
        var trunk = Path()
        trunk.move(to: .zero)
        trunk.addQuadCurve(to: CGPoint(x: 2, y: -80), control: CGPoint(x: 8, y: -40))
        t.stroke(trunk, with: .color(AppTheme.gameTree), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        for i in 0..<5 {
            var leaf = t
            leaf.translateBy(x: 2, y: -80)
            leaf.rotate(by: .radians(-2.6 + Double(i) * 0.55))
            leaf.fill(Path(ellipseIn: CGRect(x: -2, y: -6, width: 48, height: 12)), with: .color(AppTheme.gameTree))
        }
    }

    private func coin(_ c: inout GraphicsContext, rect: CGRect, phase: Double) {
        let spin = max(0.22, abs(cos(time * 5 + phase)))
        var k = c
        k.translateBy(x: rect.midX, y: rect.midY)
        k.scaleBy(x: spin, y: 1)
        let disc = CGRect(x: -16, y: -16, width: 32, height: 32)
        k.fill(Path(ellipseIn: disc),
               with: .radialGradient(Gradient(colors: [AppTheme.royalGoldLight, AppTheme.dipoCrown, AppTheme.royalGold]),
                                     center: CGPoint(x: -5, y: -6), startRadius: 2, endRadius: 18))
        k.stroke(Path(ellipseIn: disc.insetBy(dx: 4.5, dy: 4.5)), with: .color(AppTheme.royalGoldText.opacity(0.55)), lineWidth: 1.6)
        if spin > 0.5 {
            k.draw(Text(verbatim: "Rp").font(.system(size: 10, weight: .heavy)).foregroundStyle(AppTheme.royalGoldText.opacity(0.85)),
                   at: CGPoint(x: 0, y: 1))
        }
    }

    private func shieldPickup(_ c: inout GraphicsContext, rect: CGRect) {
        let pulse = 1 + sin(time * 5) * 0.06
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        c.fill(Path(ellipseIn: CGRect(x: centre.x - 30, y: centre.y - 30, width: 60, height: 60)),
               with: .radialGradient(Gradient(colors: [AppTheme.accent.opacity(0.45), AppTheme.accent.opacity(0)]),
                                     center: centre, startRadius: 4, endRadius: 30))
        let r = 18 * pulse
        c.fill(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)), with: .color(AppTheme.accent))
        c.fill(Path(ellipseIn: CGRect(x: centre.x - 11, y: centre.y - 13, width: 14, height: 7)), with: .color(.white.opacity(0.35)))
        var symbol = c.resolve(Image(systemName: "shield.lefthalf.filled"))
        symbol.shading = .color(.white)
        c.draw(symbol, in: CGRect(x: centre.x - 9, y: centre.y - 10, width: 18, height: 20))
    }

    /// Label sizes, measured once per trap rather than every frame.
    private static var labelSizes: [String: CGSize] = [:]
    private static func labelSize(_ trap: RunTrap, _ label: GraphicsContext.ResolvedText) -> CGSize {
        if let size = labelSizes[trap.label] { return size }
        let size = label.measure(in: CGSize(width: 200, height: 40))
        labelSizes[trap.label] = size
        return size
    }

    private func trap(_ c: inout GraphicsContext, rect: CGRect, trap: RunTrap, ground: Double) {
        let board = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 46)
        // Post and its shadow
        c.fill(Path(ellipseIn: CGRect(x: rect.midX - 20, y: ground - 1, width: 40, height: 8)), with: .color(.black.opacity(0.12)))
        c.fill(Path(roundedRect: CGRect(x: rect.midX - 3, y: board.maxY - 6, width: 6, height: rect.maxY - board.maxY + 6), cornerRadius: 2),
               with: .color(AppTheme.gamePost))
        // Board with a soft highlight
        c.fill(Path(roundedRect: board, cornerRadius: 12), with: .color(trap.color))
        c.fill(Path(roundedRect: CGRect(x: board.minX + 3, y: board.minY + 3, width: board.width - 6, height: 16), cornerRadius: 9),
               with: .color(.white.opacity(0.18)))
        var symbol = c.resolve(Image(systemName: trap.symbol))
        symbol.shading = .color(.white)
        c.draw(symbol, in: CGRect(x: board.midX - 11, y: board.midY - 10, width: 22, height: 20))
        // Name above, on a small pill
        let label = c.resolve(Text(trap.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(trap.color))
        let size = Self.labelSize(trap, label)
        let pill = CGRect(x: board.midX - size.width / 2 - 7, y: board.minY - 24, width: size.width + 14, height: 19)
        c.fill(Path(roundedRect: pill, cornerRadius: 9.5), with: .color(AppTheme.cardDark.opacity(0.94)))
        c.draw(label, at: CGPoint(x: pill.midX, y: pill.midY))
    }
}
