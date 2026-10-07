import XCTest
import SwiftUI
@testable import DiPo

/// What DiPo says on Home, and in which order, for Free and Royal.
@MainActor
final class DiPoTalkTests: XCTestCase {

    private func insight(_ title: String, _ color: Color) -> SmartInsight {
        SmartInsight(icon: "info.circle", color: color, title: title, body: "\(title) body")
    }

    func testUnreadNotificationsComeFirst() {
        let lines = DiPoScript.lines(unread: 3, insights: [insight("A", AppTheme.orange)], isRoyal: true)
        XCTAssertEqual(lines.first?.id, "unread-3")
        if case .notifications = lines[0].action {} else { XCTFail("tapping opens notifications") }
        XCTAssertTrue(lines[0].text.contains("3"))
    }

    func testNoUnreadNoReminder() {
        let lines = DiPoScript.lines(unread: 0, insights: [insight("A", AppTheme.orange)], isRoyal: true)
        XCTAssertFalse(lines.contains { $0.id.hasPrefix("unread") })
    }

    func testFreeHearsTheTopInsightThenTheRoyalNote() {
        let ins = [insight("A", AppTheme.red), insight("B", AppTheme.accent), insight("C", AppTheme.blue)]
        let lines = DiPoScript.lines(unread: 0, insights: ins, isRoyal: false)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].title, "A")
        if case .royal = lines[1].action {} else { XCTFail("second line points to Royal") }
        XCTAssertTrue(lines[1].text.contains("2"), "says how many are waiting")
    }

    func testRoyalHearsEveryInsight() {
        let ins = [insight("A", AppTheme.red), insight("B", AppTheme.accent), insight("C", AppTheme.blue)]
        let lines = DiPoScript.lines(unread: 1, insights: ins, isRoyal: true)
        XCTAssertEqual(lines.map(\.title), ["", "A", "B", "C"])
    }

    func testNothingToSayGivesTheTipOfTheDay() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let a = DiPoScript.lines(unread: 0, insights: [], isRoyal: false, day: day)
        let b = DiPoScript.lines(unread: 0, insights: [], isRoyal: true, day: day)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].id, b[0].id, "the same tip all day")
        XCTAssertTrue(a[0].id.hasPrefix("tip-"))
    }

    func testMoodFollowsTheInsight() {
        XCTAssertEqual(DiPoScript.mood(of: insight("x", AppTheme.red)), .worry)
        XCTAssertEqual(DiPoScript.mood(of: insight("x", AppTheme.orange)), .worry)
        XCTAssertEqual(DiPoScript.mood(of: insight("x", AppTheme.accent)), .happy)
        XCTAssertEqual(DiPoScript.mood(of: insight("x", AppTheme.blue)), .info)
    }

    func testEveryTipAndLineExistsInBothLanguages() {
        var keys = ["dipo.sfx.happy", "dipo.sfx.worry", "dipo.sfx.cheer", "dipo.sfx.info", "dipo.sfx.psst",
                    "dipo.sfx.tip", "dipo.sfx.tomorrow", "dipo.unread_one", "dipo.unread_many",
                    "dipo.locked", "dipo.next", "dipo.ask", "dipo.a11y_open", "dipo.a11y_ask",
                    "dipo.home_invite", "dipo.speak_on", "dipo.speak_off",
                    "dipo.sfx.payday_soon", "dipo.sfx.payday_today", "dipo.payday_today",
                    "dipo.payday_tomorrow", "dipo.payday_in", "dipo.sfx.bill", "dipo.bill_today",
                    "dipo.bill_tomorrow", "dipo.bill_in", "dipo.bill_auto", "dipo.bill_manual",
                    "dipo.link.notifications", "dipo.link.bills", "dipo.link.salary", "dipo.link.checkin",
                    "ai.credits_left", "ai.credits_out", "ai.credits_placeholder", "game.play"]
        keys += (0..<DiPoVoice.questionCount).map { "dipo.q.\($0)" }
        keys += (0..<DiPoScript.tipCount).map { "dipo.tip.\($0)" }
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                for k in keys { XCTAssertNotEqual(loc(k), k, "\(k) in \(lang)") }
            }
        }
    }

    func testHomeNudgeUnreadBeatsPayday() {
        let n = DiPoNudge.pick(unread: 2, daysToPayday: 1, payDate: .now)
        XCTAssertEqual(n?.action, .notifications)
    }

    func testHomeNudgePaydayFromThreeDaysOut() {
        let pay = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(DiPoNudge.pick(unread: 0, daysToPayday: 3, payDate: pay)?.action, .salary)
        XCTAssertTrue(DiPoNudge.pick(unread: 0, daysToPayday: 3, payDate: pay)?.text.contains("3") ?? false)
        XCTAssertNil(DiPoNudge.pick(unread: 0, daysToPayday: 4, payDate: pay), "not before H-3")
        XCTAssertNil(DiPoNudge.pick(unread: 0, daysToPayday: nil, payDate: nil), "no salary schedule")
        let today = DiPoNudge.pick(unread: 0, daysToPayday: 0, payDate: pay)
        XCTAssertEqual(today?.mood, .cheer)
        XCTAssertEqual(today?.action, .salary)
    }

    func testHomeRemindersInOrderAndOnlyInsideTheWindow() {
        let bill = DiPoNudge.Bill(label: "kos", amount: "Rp 2.100.000", daysLeft: 1, autoRecord: true)
        let all = DiPoNudge.all(unread: 2, bill: bill, daysToPayday: 2, payDate: .now)
        XCTAssertEqual(all.map(\.action), [.notifications, .bills, .salary])
        XCTAssertTrue(all[1].text.contains("kos") && all[1].text.contains("Rp 2.100.000"))
        let far = DiPoNudge.Bill(label: "kos", amount: "Rp 2.100.000", daysLeft: 9, autoRecord: true)
        XCTAssertTrue(DiPoNudge.all(unread: 0, bill: far, daysToPayday: 16, payDate: .now).isEmpty,
                      "nothing to say: DiPo just invites a question")
    }

    func testCheckInRanksAfterUnreadBeforeBills() {
        let bill = DiPoNudge.Bill(label: "kos", amount: "Rp 2.100.000", daysLeft: 1, autoRecord: false)
        let all = DiPoNudge.all(unread: 1, checkIn: true, bill: bill, daysToPayday: 2, payDate: .now)
        XCTAssertEqual(all.map(\.action), [.notifications, .checkIn, .bills, .salary])
        XCTAssertEqual(DiPoNudge.all(unread: 0, checkIn: true, bill: nil, daysToPayday: nil, payDate: nil).map(\.action),
                       [.checkIn])
    }

    func testSpeakingTimeIsBounded() {
        XCTAssertEqual(DiPoVoice.estimatedSeconds(""), 1)
        XCTAssertEqual(DiPoVoice.estimatedSeconds(String(repeating: "a", count: 10_000)), 20)
        XCTAssertGreaterThan(DiPoVoice.estimatedSeconds(String(repeating: "a", count: 100)), 1)
    }

    func testRigMoodsDoNotBreakIt() {
        let rig = DiPoDragonRig()
        for mood in [DiPoMood.happy, .worry, .cheer, .info, .idle] {
            rig.react(mood)
            XCTAssertEqual(rig.mood, mood)
        }
        rig.talk(for: 1.5)
    }
}
