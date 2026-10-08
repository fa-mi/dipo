import XCTest
@testable import DiPo

@MainActor
final class DiPoQuestTests: XCTestCase {

    // MARK: Content

    func testEveryLevelMakesFiveSoundQuestionsWithManySeeds() {
        for level in QuestCatalog.allLevels {
            for seed in UInt64(1)...40 {
                let qs = QuestCatalog.questions(for: level, seed: seed &* 7_919)
                XCTAssertEqual(qs.count, QuestCatalog.questionsPerLevel, level.id)
                XCTAssertEqual(Set(qs.map(\.id)).count, qs.count, "ids unique in \(level.id)")
                for q in qs {
                    XCTAssertGreaterThanOrEqual(q.options.count, 2, "\(level.id) \(q.id)")
                    XCTAssertTrue(q.options.indices.contains(q.answer), "\(level.id) \(q.id)")
                    XCTAssertEqual(Set(q.options).count, q.options.count, "options distinct: \(q.options)")
                    for text in [q.prompt, q.explain, q.title] + q.options {
                        XCTAssertFalse(text.contains("quest."), "missing string: \(text)")
                        XCTAssertFalse(text.contains("%@") || text.contains("%d"), "unfilled: \(text)")
                    }
                }
            }
        }
    }

    func testSameSeedSameQuestions() {
        let level = QuestLevel(unit: 1, index: 2)
        XCTAssertEqual(QuestCatalog.questions(for: level, seed: 42), QuestCatalog.questions(for: level, seed: 42))
    }

    func testBankItemsDoNotRepeatWithinAPlay() {
        // Unit 5 asks three scams in its first level.
        for seed in UInt64(1)...30 {
            let qs = QuestCatalog.questions(for: QuestLevel(unit: 5, index: 1), seed: seed)
            let scams = qs.filter { $0.kind == .scam }.map(\.prompt)
            XCTAssertEqual(Set(scams).count, scams.count)
        }
    }

    func testEveryBankEntryHasItsStrings() {
        for i in QuestGenerator.needWantBank.indices { XCTAssertNotEqual(loc("quest.nw.\(i)"), "quest.nw.\(i)") }
        for i in QuestGenerator.scamBank.indices {
            XCTAssertNotEqual(loc("quest.scam.\(i)"), "quest.scam.\(i)")
            XCTAssertNotEqual(loc("quest.scam.\(i).why"), "quest.scam.\(i).why")
        }
        for i in QuestGenerator.factBank.indices {
            XCTAssertNotEqual(loc("quest.fact.\(i)"), "quest.fact.\(i)")
            XCTAssertNotEqual(loc("quest.fact.\(i).why"), "quest.fact.\(i).why")
        }
        for unit in QuestCatalog.units {
            XCTAssertNotEqual(unit.title, "quest.unit.\(unit.id).title")
            XCTAssertTrue(QuestGenerator.factBank.contains { $0.unit == unit.id }, "unit \(unit.id) has facts")
        }
    }

    // MARK: Progress

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testLevelsOpenInOrder() {
        var s = QuestState()
        let all = QuestCatalog.allLevels
        XCTAssertTrue(s.isUnlocked(all[0]))
        XCTAssertFalse(s.isUnlocked(all[1]))
        XCTAssertEqual(s.current, all[0])
        s.finish(all[0], mistakes: 0, now: t0)
        XCTAssertTrue(s.isUnlocked(all[1]))
        XCTAssertEqual(s.current, all[1])
    }

    func testXPAndPerfectBonus() {
        var s = QuestState()
        XCTAssertEqual(s.finish(QuestLevel(unit: 1, index: 1), mistakes: 0, now: t0), 15)
        XCTAssertEqual(s.finish(QuestLevel(unit: 1, index: 1), mistakes: 2, now: t0), 10, "replays earn XP too")
        XCTAssertEqual(s.xp, 25)
        XCTAssertEqual(s.completed.count, 1)
        XCTAssertEqual(s.dayLevels, 2)
    }

    func testHeartsDropAndComeBackEveryHalfHour() {
        var s = QuestState()
        s.loseHeart(now: t0)
        s.loseHeart(now: t0.addingTimeInterval(60))
        XCTAssertEqual(s.hearts, 3)
        XCTAssertEqual(s.nextHeart(now: t0.addingTimeInterval(120)), t0.addingTimeInterval(QuestState.heartRefill))
        s.settleHearts(now: t0.addingTimeInterval(QuestState.heartRefill + 1))
        XCTAssertEqual(s.hearts, 4)
        s.settleHearts(now: t0.addingTimeInterval(QuestState.heartRefill * 3))
        XCTAssertEqual(s.hearts, QuestState.maxHearts)
        XCTAssertNil(s.heartsSince)
        XCTAssertNil(s.nextHeart(now: t0.addingTimeInterval(QuestState.heartRefill * 3)))
    }

    func testHeartsNeverGoBelowZero() {
        var s = QuestState()
        for i in 0..<8 { s.loseHeart(now: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(s.hearts, 0)
    }

    func testDailyChestNeedsAllThreeQuestsAndOpensOnce() {
        var s = QuestState()
        s.finish(QuestLevel(unit: 1, index: 1), mistakes: 0, now: t0)
        XCTAssertFalse(s.openDailyChest(now: t0, loggedToday: true), "15 XP is short of the goal")
        s.finish(QuestLevel(unit: 1, index: 2), mistakes: 0, now: t0)
        XCTAssertFalse(s.openDailyChest(now: t0, loggedToday: false), "no transaction logged")
        s.loseHeart(now: t0)
        XCTAssertTrue(s.openDailyChest(now: t0, loggedToday: true))
        XCTAssertEqual(s.hearts, QuestState.maxHearts, "the chest refills hearts")
        XCTAssertFalse(s.openDailyChest(now: t0, loggedToday: true), "once a day")
    }

    func testANewDayStartsTheQuestsAgain() {
        var s = QuestState()
        s.finish(QuestLevel(unit: 1, index: 1), mistakes: 0, now: t0)
        XCTAssertTrue(s.quests(now: t0, loggedToday: false).played)
        let tomorrow = t0.addingTimeInterval(86_400)
        XCTAssertFalse(s.quests(now: tomorrow, loggedToday: false).played)
        XCTAssertEqual(s.quests(now: tomorrow, loggedToday: false).xp, 0)
    }

    func testUnitChestOpensOnlyWhenTheUnitIsDone() {
        var s = QuestState()
        XCTAssertFalse(s.openUnitChest(1))
        for level in QuestCatalog.units[0].levels { s.finish(level, mistakes: 1, now: t0) }
        XCTAssertTrue(s.openUnitChest(1))
        XCTAssertFalse(s.openUnitChest(1))
    }

    // MARK: A play

    private func lesson(hearts: Int, unlimited: Bool = false) -> (QuestLesson, () -> Int) {
        var left = hearts
        let qs = QuestCatalog.questions(for: QuestLevel(unit: 1, index: 1), seed: 9)
        let l = QuestLesson(level: QuestLevel(unit: 1, index: 1), questions: qs, unlimitedHearts: unlimited) {
            left -= 1
            return left
        }
        return (l, { left })
    }

    private func answer(_ l: QuestLesson, right: Bool) {
        guard let q = l.question else { return XCTFail("no question") }
        l.select(right ? q.answer : (q.answer + 1) % q.options.count)
        l.check()
        if case .checked = l.phase { l.next() }
    }

    func testAllRightFinishesPerfect() {
        let (l, _) = lesson(hearts: 5)
        for _ in 0..<QuestCatalog.questionsPerLevel { answer(l, right: true) }
        XCTAssertEqual(l.phase, .finished)
        XCTAssertEqual(l.mistakes, 0)
        XCTAssertEqual(l.accuracy, 100)
        XCTAssertEqual(l.progress, 1)
    }

    func testAWrongAnswerComesBackOnceAndCostsAHeart() {
        let (l, hearts) = lesson(hearts: 5)
        let first = l.question
        answer(l, right: false)
        XCTAssertEqual(hearts(), 4)
        for _ in 0..<(QuestCatalog.questionsPerLevel - 1) { answer(l, right: true) }
        XCTAssertEqual(l.phase, .answering, "the missed question is asked again")
        XCTAssertEqual(l.question?.id, first?.id)
        answer(l, right: true)
        XCTAssertEqual(l.phase, .finished)
        XCTAssertEqual(l.mistakes, 1)
    }

    func testRunningOutOfHeartsEndsThePlay() {
        let (l, _) = lesson(hearts: 2)
        answer(l, right: false)
        answer(l, right: false)
        XCTAssertEqual(l.phase, .outOfHearts)
    }

    func testRoyalNeverRunsOutOfHearts() {
        let (l, hearts) = lesson(hearts: 1, unlimited: true)
        for _ in 0..<3 { answer(l, right: false) }
        XCTAssertNotEqual(l.phase, .outOfHearts)
        XCTAssertEqual(hearts(), 1, "no heart taken")
    }

    func testCheckNeedsASelection() {
        let (l, _) = lesson(hearts: 5)
        XCTAssertFalse(l.check())
        XCTAssertEqual(l.phase, .answering)
    }

    // MARK: Around it

    func testQuestNudgeComesLast() {
        let all = DiPoNudge.all(unread: 1, bill: nil, daysToPayday: nil, payDate: nil, questWaiting: true)
        XCTAssertEqual(all.map(\.action), [.notifications, .quest])
    }

    func testGameCounterIDsAreStable() {
        XCTAssertEqual(GameAnalytics.counterID(.levelStart, level: QuestLevel(unit: 2, index: 3), unit: nil),
                       "quest_level_start_u2l3")
        XCTAssertEqual(GameAnalytics.counterID(.unitChest, level: nil, unit: 4), "quest_unit_chest_u4")
        XCTAssertEqual(GameAnalytics.counterID(.dailyChest, level: nil, unit: nil), "quest_daily_chest")
    }
}
