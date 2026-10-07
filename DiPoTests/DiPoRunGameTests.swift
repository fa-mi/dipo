import XCTest
@testable import DiPo

/// The rules of DiPo Lari Hemat, stepped by hand.
@MainActor
final class DiPoRunGameTests: XCTestCase {

    private func run(_ g: RunGame, seconds: Double) {
        var t = 0.0
        while t < seconds { g.step(1.0 / 60); t += 1.0 / 60 }
    }

    func testJumpRisesAndLands() {
        let g = RunGame(bonusLife: false, seed: 1)
        g.start()
        g.jump()
        run(g, seconds: 0.2)
        XCTAssertGreaterThan(g.dipoY, 50)
        run(g, seconds: 1.5)
        XCTAssertEqual(g.dipoY, 0, "back on the ground")
    }

    func testCoinIsSavings() {
        let g = RunGame(bonusLife: false, seed: 1)
        g.start()
        g.place(.coin, x: RunGame.dipoX + 10, y: 10)
        g.step(1.0 / 60)
        XCTAssertEqual(g.coins, 1)
        XCTAssertEqual(g.saved, RunGame.coinValue)
        XCTAssertEqual(g.popups.count, 1, "a +Rp word floats up")
    }

    func testTrapCostsALifeAndIsRemembered() {
        let g = RunGame(bonusLife: false, seed: 1)
        g.start()
        g.place(.trap(.quickLoan), x: RunGame.dipoX + 10)
        g.step(1.0 / 60)
        XCTAssertEqual(g.lives, 2)
        XCTAssertEqual(g.lastTrap, .quickLoan)
        XCTAssertGreaterThan(g.invulnerable, 0)
        XCTAssertGreaterThan(g.flash, 0, "the screen flashes")
        XCTAssertGreaterThan(g.shake, 0, "and shakes")
    }

    func testHintOnlyAtTheStart() {
        let g = RunGame(bonusLife: false, seed: 1)
        g.start()
        XCTAssertTrue(g.showsHint)
        run(g, seconds: RunGame.hintSeconds + 0.2)
        XCTAssertFalse(g.showsHint)
    }

    func testShieldTakesTheHit() {
        let g = RunGame(bonusLife: false, seed: 1)
        g.start()
        g.place(.shield, x: RunGame.dipoX + 10, y: 10)
        g.step(1.0 / 60)
        XCTAssertTrue(g.shielded)
        g.place(.trap(.fakeSale), x: RunGame.dipoX + 10)
        g.step(1.0 / 60)
        XCTAssertEqual(g.lives, 3)
        XCTAssertFalse(g.shielded)
    }

    func testLoggingTodayGivesAnExtraLife() {
        XCTAssertEqual(RunGame(bonusLife: true, seed: 1).lives, 4)
        XCTAssertEqual(RunGame(bonusLife: false, seed: 1).lives, 3)
    }

    func testRunEndsWhenLivesRunOut() {
        let g = RunGame(bonusLife: false, seed: 1)
        g.start()
        for trap in [RunTrap.fakeSale, .impulseBuy, .shadyArisan] {
            g.place(.trap(trap), x: RunGame.dipoX + 10)
            g.step(1.0 / 60)
            run(g, seconds: 1.1)   // past the blink
        }
        XCTAssertTrue(g.over)
        XCTAssertFalse(g.running)
        XCTAssertEqual(g.lastTrap, .shadyArisan)
        g.restart()
        XCTAssertEqual(g.lives, 3)
        XCTAssertTrue(g.running)
    }

    func testRandomRunsStaySane() {
        let g = RunGame(bonusLife: false, seed: 42)
        g.start()
        for _ in 0..<(60 * 40) where !g.over {
            if Int.random(in: 0..<20) == 0 { g.jump() }
            g.step(1.0 / 60)
        }
        XCTAssertLessThanOrEqual(g.speed, RunGame.maxSpeed)
        XCTAssertGreaterThanOrEqual(g.dipoY, 0)
        XCTAssertLessThan(g.entities.count, 40, "off-screen entities are dropped")
    }

    func testFreePlaysPerDay() {
        let day = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertNil(RunPlays.left(isRoyal: true, on: day))
        let before = RunPlays.used(on: day)
        RunPlays.record(on: day)
        XCTAssertEqual(RunPlays.used(on: day), before + 1)
    }

    func testEveryTrapHasLabelAndLessonInBothLanguages() {
        var keys = ["game.title", "game.tap_hint", "game.how", "game.start", "game.again", "game.close",
                    "game.hint", "game.rule.jump", "game.rule.coin", "game.rule.shield", "game.you_saved",
                    "game.new_best", "game.popup.shield", "game.popup.saved", "game.popup.life",
                    "game.royal", "game.saved", "game.best", "game.caught_by", "game.lives",
                    "game.bonus_life", "game.plays_left", "game.no_plays"]
        for t in RunTrap.allCases { keys += ["game.trap.\(t.rawValue)", "game.lesson.\(t.rawValue)"] }
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                for k in keys { XCTAssertNotEqual(loc(k), k, "\(k) in \(lang)") }
            }
        }
    }
}
