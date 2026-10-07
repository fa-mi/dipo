import SwiftUI
import SwiftData

// MARK: - DiPo Lari Hemat (DiPo Run)
//
// A one-thumb runner, opened from Ask DiPo. DiPo runs on his own; a tap makes
// him jump (twice in the air at most). Coins are savings. The obstacles are
// everyday money traps — a fake sale, a quick-cash loan app, an impulse
// checkout, a shady arisan — and the rare green shield is an emergency fund
// that absorbs one hit. When the run ends DiPo explains the trap that got him.
//
// Logging a transaction today earns an extra life, so the game nudges the
// habit the app is for. Free plays three runs a day; Royal plays without
// limit. There is no prize and nothing to buy: the coins are only a score.
//
// Everything runs on the main actor through a TimelineView: the model steps
// once per frame and a Canvas draws it — no SpriteKit, no render thread.

enum RunTrap: String, CaseIterable {
    case fakeSale, quickLoan, impulseBuy, shadyArisan

    var label: String { loc("game.trap.\(rawValue)") }
    var lesson: String { loc("game.lesson.\(rawValue)") }
    var symbol: String {
        switch self {
        case .fakeSale:    return "tag.fill"
        case .quickLoan:   return "banknote.fill"
        case .impulseBuy:  return "cart.fill"
        case .shadyArisan: return "person.3.fill"
        }
    }
}

struct RunEntity: Identifiable {
    enum Kind: Equatable { case coin, shield, trap(RunTrap) }
    let id: Int
    let kind: Kind
    var x: Double
    let y: Double        // bottom of the entity, measured up from the ground
    let size: Double
}

/// The game's rules, with no drawing in it, so it can be tested.
@MainActor
@Observable
final class RunGame {
    // World, in points, set from the canvas size.
    private(set) var width: Double = 390
    static let dipoX: Double = 70
    static let dipoSize: Double = 64
    static let gravity: Double = 2600
    static let jumpSpeed: Double = 900
    static let startSpeed: Double = 260
    static let maxSpeed: Double = 620
    /// Each coin is this many rupiah of savings on the score.
    static let coinValue = 1_000

    private(set) var dipoY: Double = 0          // height above the ground
    private var vy: Double = 0
    private var jumpsLeft = 2
    private(set) var entities: [RunEntity] = []
    private(set) var coins = 0
    private(set) var lives: Int
    private(set) var shielded = false
    private(set) var speed: Double = RunGame.startSpeed
    private(set) var elapsed: Double = 0
    private(set) var running = false
    private(set) var over = false
    private(set) var lastTrap: RunTrap? = nil
    /// Seconds of blinking after a hit, while another hit cannot land.
    private(set) var invulnerable: Double = 0

    private var nextSpawn: Double = 1.2
    private var nextID = 0
    private var rng: SplitMix
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
    }

    func restart() {
        dipoY = 0; vy = 0; jumpsLeft = 2
        entities = []; coins = 0; lives = startingLives; shielded = false
        speed = Self.startSpeed; elapsed = 0; nextSpawn = 1.2
        lastTrap = nil; invulnerable = 0
        over = false; running = true
    }

    func jump() {
        if !running { start() }
        guard !over, jumpsLeft > 0 else { return }
        vy = Self.jumpSpeed * (jumpsLeft == 2 ? 1 : 0.85)
        jumpsLeft -= 1
    }

    /// Advances the world by `dt` seconds.
    func step(_ dt: Double) {
        guard running, !over else { return }
        let dt = min(dt, 1.0 / 20)   // a hitch must not teleport him through a trap
        elapsed += dt
        speed = min(Self.maxSpeed, Self.startSpeed + elapsed * 9)
        invulnerable = max(0, invulnerable - dt)

        // DiPo
        vy -= Self.gravity * dt
        dipoY += vy * dt
        if dipoY <= 0 { dipoY = 0; vy = 0; jumpsLeft = 2 }

        // World
        for i in entities.indices { entities[i].x -= speed * dt }
        entities.removeAll { $0.x + $0.size < -20 }

        nextSpawn -= dt
        if nextSpawn <= 0 { spawn() }

        collide()
    }

    /// Puts an entity in the world directly; used by tests to stage a moment.
    func place(_ kind: RunEntity.Kind, x: Double, y: Double = 0, size: Double = 40) {
        entities.append(RunEntity(id: nextID, kind: kind, x: x, y: y, size: size))
        nextID += 1
        nextSpawn = 99
    }

    private func spawn() {
        let roll = rng.next01()
        let x = width + 30
        let kind: RunEntity.Kind
        let y: Double
        if roll < 0.42 {
            kind = .trap(RunTrap.allCases[Int(rng.next01() * Double(RunTrap.allCases.count)) % RunTrap.allCases.count])
            y = 0
        } else if roll < 0.95 {
            kind = .coin
            y = rng.next01() < 0.5 ? 20 : 150     // on the path, or a jump up
        } else {
            kind = .shield
            y = 110
        }
        let size: Double = { if case .trap = kind { return 46 } else { return 30 } }()
        entities.append(RunEntity(id: nextID, kind: kind, x: x, y: y, size: size))
        nextID += 1
        // Faster world, closer spawns, but always room to land between traps.
        let gap = 0.55 + rng.next01() * 0.75
        nextSpawn = gap * (Self.startSpeed / speed) + 0.25
    }

    private func collide() {
        // A slightly smaller box than the picture, so a near miss is a miss.
        let pad = 12.0
        let dx0 = Self.dipoX + pad, dx1 = Self.dipoX + Self.dipoSize - pad
        let dy0 = dipoY + 4, dy1 = dipoY + Self.dipoSize - pad
        var hit: [Int] = []
        for e in entities {
            let overlaps = e.x < dx1 && e.x + e.size > dx0 && e.y < dy1 && e.y + e.size > dy0
            guard overlaps else { continue }
            switch e.kind {
            case .coin:
                coins += 1
                hit.append(e.id)
            case .shield:
                shielded = true
                hit.append(e.id)
            case .trap(let trap):
                guard invulnerable == 0 else { continue }
                hit.append(e.id)
                if shielded {
                    shielded = false
                } else {
                    lives -= 1
                    lastTrap = trap
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
    @Query private var todays: [TxRecord]
    @AppStorage("game_best_saved") private var best = 0
    @State private var game: RunGame
    @State private var lastTick: Date? = nil
    @State private var showPaywall = false
    @State private var playsLeft: Int?
    @State private var counted = false

    init(isRoyal: Bool) {
        self.isRoyal = isRoyal
        let start = Calendar.current.startOfDay(for: .now)
        _todays = Query(filter: #Predicate<TxRecord> { $0.date >= start })
        // The bonus life is decided when the screen opens; the query below
        // only shows it.
        _game = State(initialValue: RunGame(bonusLife: false))
        _playsLeft = State(initialValue: RunPlays.left(isRoyal: isRoyal))
    }

    private var bonusLife: Bool { !todays.isEmpty }
    private var outOfPlays: Bool { (playsLeft ?? 1) <= 0 }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            GeometryReader { geo in
                TimelineView(.animation(paused: !game.running)) { timeline in
                    Canvas { ctx, size in draw(&ctx, size: size) }
                        .onChange(of: timeline.date) { _, now in
                            if let last = lastTick { game.step(now.timeIntervalSince(last)) }
                            lastTick = now
                            if game.over, !counted { finish() }
                        }
                }
                .onAppear { game.resize(width: geo.size.width) }
                .onChange(of: geo.size.width) { _, w in game.resize(width: w) }
            }
            .contentShape(Rectangle())
            .onTapGesture { tap() }
            .accessibilityElement()
            .accessibilityLabel(loc("game.title"))
            .accessibilityHint(loc("game.tap_hint"))
            .accessibilityAddTraits(.allowsDirectInteraction)

            VStack(spacing: 0) {
                hud
                Spacer()
            }
            if !game.running { overlay }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg).preferredColorScheme(appColorScheme())
        }
        .onAppear {
            if bonusLife { game = RunGame(bonusLife: true) }
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
        lastTick = nil
        if game.over { game.restart() } else { game.start() }
    }

    private func finish() {
        counted = true
        lastTick = nil
        HapticManager.shared.error()
        best = max(best, game.saved)
        if !isRoyal {
            RunPlays.record()
            playsLeft = RunPlays.left(isRoyal: false)
        }
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let ground = size.height * 0.72
        // Ground
        ctx.fill(Path(CGRect(x: 0, y: ground, width: size.width, height: size.height - ground)),
                 with: .color(AppTheme.cardMid))
        ctx.fill(Path(CGRect(x: 0, y: ground, width: size.width, height: 3)), with: .color(AppTheme.accent))
        // Passing ground marks, so speed reads as movement.
        let shift = (game.elapsed * game.speed).truncatingRemainder(dividingBy: 60)
        var x = -shift
        while x < size.width {
            ctx.fill(Path(CGRect(x: x, y: ground + 18, width: 22, height: 3)), with: .color(AppTheme.textSecondary.opacity(0.25)))
            x += 60
        }

        for e in game.entities {
            let rect = CGRect(x: e.x, y: ground - e.y - e.size, width: e.size, height: e.size)
            switch e.kind {
            case .coin:
                ctx.fill(Path(ellipseIn: rect), with: .color(AppTheme.dipoCrown))
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: 4, dy: 4)), with: .color(AppTheme.bubbleInk.opacity(0.25)), lineWidth: 1.5)
                ctx.draw(Text(verbatim: "Rp").font(.system(size: 10, weight: .black)).foregroundStyle(AppTheme.bubbleInk.opacity(0.6)),
                         at: CGPoint(x: rect.midX, y: rect.midY))
            case .shield:
                ctx.fill(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(AppTheme.accent.opacity(0.25)))
                var shield = ctx.resolve(Image(systemName: "shield.lefthalf.filled"))
                shield.shading = .color(AppTheme.accent)
                ctx.draw(shield, in: rect.insetBy(dx: 3, dy: 3))
            case .trap(let trap):
                let box = Path(roundedRect: rect, cornerRadius: 10)
                ctx.fill(box, with: .color(AppTheme.red))
                ctx.stroke(box, with: .color(AppTheme.bubbleInk), lineWidth: 2)
                var symbol = ctx.resolve(Image(systemName: trap.symbol))
                symbol.shading = .color(.white)
                ctx.draw(symbol, in: rect.insetBy(dx: 11, dy: 11))
                ctx.draw(Text(trap.label).font(.system(size: 11, weight: .bold)).foregroundStyle(AppTheme.red),
                         at: CGPoint(x: rect.midX, y: rect.minY - 10))
            }
        }

        // DiPo — blinking while he cannot be hit again.
        let blink = game.invulnerable > 0 && Int(game.invulnerable * 10) % 2 == 0
        let dipo = CGRect(x: RunGame.dipoX, y: ground - game.dipoY - RunGame.dipoSize,
                          width: RunGame.dipoSize, height: RunGame.dipoSize)
        if game.shielded {
            ctx.fill(Path(ellipseIn: dipo.insetBy(dx: -8, dy: -8)), with: .color(AppTheme.accent.opacity(0.22)))
        }
        if !blink {
            ctx.draw(Image("DiPoMascot"), in: dipo)
        }
    }

    // MARK: HUD and overlay

    private var hud: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(.subheadline, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.cardDark, in: Circle())
            }
            .accessibilityLabel(loc("game.close"))
            HStack(spacing: 3) {
                ForEach(0..<max(0, game.lives), id: \.self) { _ in
                    Image(systemName: "heart.fill").foregroundStyle(AppTheme.red)
                }
            }
            .font(.system(.footnote))
            .accessibilityLabel(String(format: loc("game.lives"), game.lives))
            if game.shielded {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(AppTheme.accent)
            }
            Spacer()
            Text(CurrencyManager.shared.formatted(Double(game.saved), currency: "IDR"))
                .font(.system(.subheadline, weight: .heavy).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(AppTheme.cardDark, in: Capsule())
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    private var overlay: some View {
        VStack(spacing: 14) {
            Text(loc("game.title"))
                .font(.system(.largeTitle, design: .serif, weight: .bold).italic())
                .foregroundStyle(AppTheme.royalGoldText)
            if game.over {
                Text(String(format: loc("game.saved"), CurrencyManager.shared.formatted(Double(game.saved), currency: "IDR")))
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                if let trap = game.lastTrap {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: loc("game.caught_by"), trap.label))
                            .font(.system(.subheadline, weight: .heavy))
                        Text(trap.lesson)
                            .font(.system(.subheadline, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .dipoBubble()
                }
            } else {
                Text(loc("game.how"))
                    .font(.system(.subheadline))
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(String(format: loc("game.best"), CurrencyManager.shared.formatted(Double(best), currency: "IDR")))
                .font(.system(.footnote, weight: .semibold))
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
            Button(action: begin) {
                Text(outOfPlays ? loc("game.royal") : (game.over ? loc("game.again") : loc("game.start")))
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(AppTheme.onVividFill)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(AppTheme.accentFill, in: Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
            if let left = playsLeft, !outOfPlays {
                Text(String(format: loc("game.plays_left"), left, RunPlays.freePerDay))
                    .font(.system(.caption))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(22)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        .padding(.horizontal, 24)
    }
}
