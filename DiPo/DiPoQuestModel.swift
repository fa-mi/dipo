import Foundation
import Observation

// MARK: - DiPo Quest: progress
//
// What the player has done, kept on this device in UserDefaults as one small
// JSON value. It is game progress, not a financial record, so it is neither a
// @Model nor in backups — the same line the interests and the runner's best
// score draw.
//
// The rules, as Duolingo taught everyone to expect them:
// • Levels open in order; any finished level can be replayed for XP.
// • 10 XP a level, 5 more for no mistakes.
// • Five hearts; a wrong answer costs one; one comes back every 30 minutes.
//   Royal plays without hearts.
// • Three daily quests — finish a level, log a transaction, earn 30 XP. All
//   three open the day's chest: XP and full hearts. The middle one is the
//   point: the game sends people back to the habit DiPo exists for.
// • Each unit ends in a chest, opened once the unit's levels are done.

struct QuestState: Codable, Equatable {
    var completed: [String] = []
    var xp = 0
    var hearts = QuestState.maxHearts
    /// When the refill clock started; nil while hearts are full.
    var heartsSince: Date? = nil
    /// The day `dayXP` and `dayLevels` belong to.
    var dayKey = ""
    var dayXP = 0
    var dayLevels = 0
    /// The day the daily chest was last opened.
    var chestDay = ""
    var openedUnitChests: [Int] = []

    static let maxHearts = 5
    static let heartRefill: TimeInterval = 30 * 60
    static let levelXP = 10
    static let perfectBonus = 5
    static let dailyXPGoal = 30
    static let dailyChestXP = 20
    static let unitChestXP = 30

    // MARK: Levels

    func isDone(_ level: QuestLevel) -> Bool { completed.contains(level.id) }

    /// Open when it is the first level, or the one before it is done.
    func isUnlocked(_ level: QuestLevel) -> Bool {
        let all = QuestCatalog.allLevels
        guard let i = all.firstIndex(of: level) else { return false }
        return i == 0 || isDone(all[i - 1])
    }

    /// The first level not yet done; nil once every level is.
    var current: QuestLevel? { QuestCatalog.allLevels.first { !isDone($0) } }

    func unitDone(_ unit: Int) -> Bool {
        QuestCatalog.units.first { $0.id == unit }?.levels.allSatisfy(isDone) ?? false
    }

    // MARK: Hearts

    /// Brings hearts up to date with the clock.
    mutating func settleHearts(now: Date) {
        guard hearts < Self.maxHearts, let since = heartsSince else {
            heartsSince = nil
            return
        }
        let gained = Int(now.timeIntervalSince(since) / Self.heartRefill)
        guard gained > 0 else { return }
        hearts = min(Self.maxHearts, hearts + gained)
        heartsSince = hearts == Self.maxHearts ? nil : since.addingTimeInterval(Double(gained) * Self.heartRefill)
    }

    mutating func loseHeart(now: Date) {
        settleHearts(now: now)
        guard hearts > 0 else { return }
        if hearts == Self.maxHearts { heartsSince = now }
        hearts -= 1
    }

    /// When the next heart comes back; nil when they are full.
    func nextHeart(now: Date) -> Date? {
        var s = self
        s.settleHearts(now: now)
        guard s.hearts < Self.maxHearts, let since = s.heartsSince else { return nil }
        return since.addingTimeInterval(Self.heartRefill)
    }

    // MARK: Days

    mutating func rollDay(now: Date) {
        let key = DailyCheckIn.key(now)
        guard key != dayKey else { return }
        dayKey = key
        dayXP = 0
        dayLevels = 0
    }

    /// Records a finished level and returns the XP it earned.
    @discardableResult
    mutating func finish(_ level: QuestLevel, mistakes: Int, now: Date) -> Int {
        rollDay(now: now)
        let earned = Self.levelXP + (mistakes == 0 ? Self.perfectBonus : 0)
        if !isDone(level) { completed.append(level.id) }
        xp += earned
        dayXP += earned
        dayLevels += 1
        return earned
    }

    // MARK: Daily quests

    struct Quests: Equatable {
        var played: Bool
        var logged: Bool
        var xp: Int
        var allDone: Bool { played && logged && xp >= QuestState.dailyXPGoal }
        var doneCount: Int { [played, logged, xp >= QuestState.dailyXPGoal].filter { $0 }.count }
    }

    /// Today's quests. `loggedToday` comes from the ledger.
    func quests(now: Date, loggedToday: Bool) -> Quests {
        let today = dayKey == DailyCheckIn.key(now)
        return Quests(played: today && dayLevels > 0, logged: loggedToday, xp: today ? dayXP : 0)
    }

    func chestOpenedToday(now: Date) -> Bool { chestDay == DailyCheckIn.key(now) }

    mutating func openDailyChest(now: Date, loggedToday: Bool) -> Bool {
        guard quests(now: now, loggedToday: loggedToday).allDone, !chestOpenedToday(now: now) else { return false }
        chestDay = DailyCheckIn.key(now)
        xp += Self.dailyChestXP
        dayXP += Self.dailyChestXP
        hearts = Self.maxHearts
        heartsSince = nil
        return true
    }

    mutating func openUnitChest(_ unit: Int) -> Bool {
        guard unitDone(unit), !openedUnitChests.contains(unit) else { return false }
        openedUnitChests.append(unit)
        xp += Self.unitChestXP
        return true
    }
}

/// The shared, persisted progress.
@MainActor
@Observable
final class QuestStore {
    static let shared = QuestStore()
    private static let key = "quest_state_v1"

    private(set) var state: QuestState

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(QuestState.self, from: data) {
            state = s
        } else {
            state = QuestState()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    func update(_ change: (inout QuestState) -> Void) {
        var s = state
        change(&s)
        guard s != state else { return }
        state = s
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.key) }
    }

    /// Hearts as of now, refilled by the clock.
    func refresh(now: Date = .now) {
        update { $0.settleHearts(now: now); $0.rollDay(now: now) }
    }
}

// MARK: - One play of a level

@MainActor
@Observable
final class QuestLesson {
    enum Phase: Equatable { case answering, checked(correct: Bool), finished, outOfHearts }

    let level: QuestLevel
    let unlimitedHearts: Bool
    private(set) var queue: [QuestQuestion]
    private(set) var index = 0
    private(set) var selected: Int? = nil
    private(set) var phase: Phase = .answering
    private(set) var mistakes = 0
    private(set) var correct = 0
    /// Questions answered wrong once go round again at the end, once.
    @ObservationIgnored private var requeued: Set<String> = []
    private let total: Int
    private let loseHeart: () -> Int

    /// - Parameter loseHeart: takes a heart and returns how many are left.
    init(level: QuestLevel, questions: [QuestQuestion], unlimitedHearts: Bool, loseHeart: @escaping () -> Int) {
        self.level = level
        self.queue = questions
        self.total = questions.count
        self.unlimitedHearts = unlimitedHearts
        self.loseHeart = loseHeart
    }

    var question: QuestQuestion? { queue.indices.contains(index) ? queue[index] : nil }
    /// Questions got right over those in the level; a repeat does not add.
    var progress: Double { total == 0 ? 1 : Double(correct) / Double(total) }
    var accuracy: Int {
        let answered = correct + mistakes
        return answered == 0 ? 100 : Int((Double(correct) / Double(answered) * 100).rounded())
    }

    func select(_ option: Int) {
        guard phase == .answering else { return }
        selected = option
    }

    /// Marks the selected answer. Returns whether it was right.
    @discardableResult
    func check() -> Bool {
        guard phase == .answering, let q = question, let s = selected else { return false }
        let right = s == q.answer
        if right {
            correct += 1
        } else {
            mistakes += 1
            if !requeued.contains(q.id) {
                requeued.insert(q.id)
                queue.append(q)
            }
            if !unlimitedHearts, loseHeart() <= 0 {
                phase = .outOfHearts
                return false
            }
        }
        phase = .checked(correct: right)
        return right
    }

    func next() {
        guard case .checked = phase else { return }
        selected = nil
        index += 1
        // A repeat that was answered right the second time does not count
        // again; the level ends when the original questions are all right.
        if correct >= total || index >= queue.count {
            phase = .finished
        } else {
            phase = .answering
        }
    }
}
