import XCTest
@testable import DiPo

/// The notification walkthrough in Tap to Log: six steps, each with a picture
/// of what Shortcuts shows at that point.
@MainActor
final class NotificationGuideTests: XCTestCase {

    func testEveryStepAndPictureLabelIsInBothLanguages() {
        let steps = (1...6).flatMap { ["backtap.n\($0)_title", "backtap.n\($0)_body"] }
        let labels = ["trigger", "from", "notification", "action", "summary", "titled", "subtitled",
                      "title", "subtitle", "app", "select_variable", "automation", "confirm", "locked"]
            .map { "notifpic.\($0)" }
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in steps + labels {
                    XCTAssertNotEqual(loc(key), key, "missing \(key) in \(language)")
                }
            }
        }
    }

    /// The picture names DiPo's action the way the Shortcuts search does.
    func testThePictureNamesTheActionAsShortcutsShowsIt() {
        XCTAssertEqual(loc("notifpic.action"), String(localized: LogFromNotificationIntent.title))
    }

    /// The steps name the blanks the way the action labels them, so the
    /// words and the picture agree.
    func testTheStepsNameTheBlanksThePictureShows() {
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for label in ["notifpic.title", "notifpic.subtitle", "notifpic.app"] {
                    XCTAssertTrue(loc("backtap.n3_body").contains(loc(label)), "\(label) in \(language)")
                }
                XCTAssertTrue(loc("backtap.n3_body").contains(loc("notifpic.select_variable")), "\(language)")
                XCTAssertTrue(loc("backtap.n6_body").contains(loc("notifpic.confirm")), "\(language)")
                XCTAssertTrue(loc("backtap.n6_body").contains(loc("notifpic.locked")), "\(language)")
            }
        }
    }

    // MARK: Is it working?

    private func freshDefaults() -> UserDefaults {
        let name = "NotificationGuideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// The note keeps when, which app and what came of it; never the words.
    func testTheActionLeavesANoteOfWhenAndFromWhere() throws {
        let defaults = freshDefaults()
        XCTAssertNil(NotificationAutomationStatus.last(in: defaults))
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        NotificationAutomationStatus.record(app: " BRImo ", title: "Transaksi Berhasil", kept: true,
                                            at: at, in: defaults)
        XCTAssertEqual(NotificationAutomationStatus.last(in: defaults),
                       NotificationAutomationStatus(heardAt: at, app: "BRImo", hadTitle: true, kept: true))

        NotificationAutomationStatus.record(app: "  ", title: nil, kept: false, at: at, in: defaults)
        let bare = try XCTUnwrap(NotificationAutomationStatus.last(in: defaults))
        XCTAssertNil(bare.app, "A blank App blank is no app.")
        XCTAssertFalse(bare.hadTitle)
        XCTAssertTrue(bare.isMissingABlank)
    }

    func testTheGuideSaysWhatTheNoteSays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        LanguageManager.shared.withLanguage(.english) {
            XCTAssertEqual(NotificationAutomationStatus.message(for: nil, now: now), loc("notifstatus.never"))

            let working = NotificationAutomationStatus(heardAt: now.addingTimeInterval(-30), app: "BRImo",
                                                       hadTitle: true, kept: true)
            XCTAssertEqual(NotificationAutomationStatus.message(for: working, now: now),
                           "Yes. DiPo last read a notification from BRImo, just now. It was a payment, and it's waiting under Review.")
            XCTAssertFalse(working.isMissingABlank)

            let bare = NotificationAutomationStatus(heardAt: now.addingTimeInterval(-7_200), app: nil,
                                                    hadTitle: false, kept: false)
            let text = NotificationAutomationStatus.message(for: bare, now: now)
            XCTAssertTrue(text.hasPrefix("Yes. DiPo last read a notification 2 hours ago."), text)
            XCTAssertTrue(text.contains(loc("notifstatus.skipped")), text)
            XCTAssertTrue(text.hasSuffix(loc("notifstatus.missing_both")), text)
        }
        LanguageManager.shared.withLanguage(.indonesian) {
            let noApp = NotificationAutomationStatus(heardAt: now, app: nil, hadTitle: true, kept: true)
            XCTAssertTrue(NotificationAutomationStatus.message(for: noApp, now: now)
                .hasSuffix(loc("notifstatus.missing_app")))
            let noTitle = NotificationAutomationStatus(heardAt: now, app: "GoPay", hadTitle: false, kept: true)
            XCTAssertTrue(NotificationAutomationStatus.message(for: noTitle, now: now)
                .hasSuffix(loc("notifstatus.missing_title")))
        }
    }
}
