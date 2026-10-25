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
}
