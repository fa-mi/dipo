import XCTest
import SwiftUI
@testable import DiPo

/// Home says what needs doing on one line: trouble first, then DiPo's
/// reminders, then the rest, each with a dot in its own colour. Green only for
/// money coming in, red only for trouble.
@MainActor
final class HomeReminderTests: XCTestCase {

    private func reminder(_ id: String, _ tone: HomeReminder.Tone) -> HomeReminder {
        HomeReminder(id: id, title: id, tone: tone)
    }

    private func pattern(_ category: TxCategory, nextInDays days: Int, now: Date) -> SmartBudgetManager.RecurringPattern {
        // Seen monthly; the last one 30 − days ago, so the next is `days` out.
        let last = Calendar.current.date(byAdding: .day, value: days - 30, to: now)!
        return SmartBudgetManager.RecurringPattern(
            name: "PLN", amount: 350_000, currency: "IDR", category: category,
            intervalDays: 30, lastDate: last,
            firstDate: Calendar.current.date(byAdding: .day, value: -90, to: last)!, occurrences: 4)
    }

    func testTroubleComesFirstThenDiPoThenTheRest() {
        let line = HomeReminders.ordered(
            first: [reminder("negative", .trouble)],
            dipo: [reminder("bill", .due), reminder("payday", .moneyIn)],
            last: [reminder("setup-salary", .quiet), reminder("goal", .quiet)])
        XCTAssertEqual(line.map(\.id), ["negative", "bill", "payday", "setup-salary", "goal"])
    }

    func testTroubleLeadsEvenWhenHandedInLater() {
        let line = HomeReminders.ordered(first: [reminder("a", .quiet), reminder("negative", .trouble)],
                                         dipo: [], last: [])
        XCTAssertEqual(line.first?.id, "negative")
    }

    func testDiPosRemindersInTheLinesColours() {
        XCTAssertEqual(HomeReminders.tone(for: .bills), .due)
        XCTAssertEqual(HomeReminders.tone(for: .checkIn), .due)
        XCTAssertEqual(HomeReminders.tone(for: .notifications), .due)
        XCTAssertEqual(HomeReminders.tone(for: .assetCheck), .due)
        XCTAssertEqual(HomeReminders.tone(for: .salary), .moneyIn, "payday is money coming in")
        XCTAssertEqual(HomeReminders.tone(for: .streak), .quiet)
        XCTAssertEqual(HomeReminders.tone(for: .customInterestTip("kopi")), .quiet)
    }

    /// Green only for money coming in, red only for trouble.
    func testGreenAndRedAreKeptForTheirOneMeaning() {
        let tones: [HomeReminder.Tone] = [.trouble, .due, .moneyIn, .quiet]
        XCTAssertEqual(tones.filter { HomeReminders.color(for: $0) == AppTheme.accent }, [.moneyIn])
        XCTAssertEqual(tones.filter { HomeReminders.color(for: $0) == AppTheme.red }, [.trouble])
    }

    func testADetectedBillIsDueAndAHabitIsQuiet() {
        let now = Date()
        XCTAssertEqual(HomeReminders.recurringTone(pattern(.bills, nextInDays: 3, now: now)), .due)
        XCTAssertEqual(HomeReminders.recurringTone(pattern(.food, nextInDays: 3, now: now)), .quiet)
    }

    func testRecurringDetailInWords() {
        let now = Date()
        let rp = CurrencyManager.shared.formatted(350_000, currency: "IDR")
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(HomeReminders.recurringDetail(pattern(.bills, nextInDays: 5, now: now), now: now),
                           "≈ \(rp) · berikutnya sekitar 5 hari lagi")
            XCTAssertEqual(HomeReminders.recurringDetail(pattern(.bills, nextInDays: 0, now: now), now: now),
                           "≈ \(rp) · kemungkinan hari ini")
            XCTAssertEqual(HomeReminders.recurringDetail(pattern(.food, nextInDays: 5, now: now), now: now),
                           "≈ \(rp) tiap kali, dari riwayatmu")
        }
    }

    func testRecurringEvidenceSaysHowOftenItWasSeen() {
        let p = pattern(.bills, nextInDays: 5, now: Date())
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertTrue(HomeReminders.recurringEvidence(p).hasPrefix("Seen 4 times · "))
        }
    }

    func testNetWorthLineSignsANegativeFigure() {
        LanguageManager.shared.withLanguage(.indonesian) {
            let rp = CurrencyManager.shared.formatted(2_910_000, currency: "IDR")
            XCTAssertEqual(HomeNetWorth(amount: 2_910_000, currency: "IDR", breakdown: "").text,
                           "Kekayaan bersih \(rp)")
            XCTAssertEqual(HomeNetWorth(amount: -2_910_000, currency: "IDR", breakdown: "").text,
                           "Kekayaan bersih −\(rp)")
        }
    }

    func testTheGreyLineShowsOnlyWithSomethingToSay() {
        XCTAssertFalse(HomeTotalSubline.shows(netWorth: nil, payday: nil))
        XCTAssertTrue(HomeTotalSubline.shows(netWorth: nil, payday: "9 hari lagi gajian"))
        XCTAssertTrue(HomeTotalSubline.shows(netWorth: HomeNetWorth(amount: 1, currency: "IDR", breakdown: ""),
                                             payday: nil))
    }

    func testNewStringsExistInBothLanguages() {
        for lang in LanguageManager.Language.allCases {
            LanguageManager.shared.withLanguage(lang) {
                for k in ["home.net_worth_line", "home.net_worth_hint", "home.reminder.stop"] {
                    XCTAssertNotEqual(loc(k), k, "\(k) in \(lang)")
                }
            }
        }
    }
}
