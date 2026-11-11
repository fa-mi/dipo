import XCTest
@testable import DiPo

/// The Support screen finds a person's tickets by their Firebase account (uid)
/// once that account carries their Apple/Google login, so the rules can keep
/// everyone else's tickets out of reach. Tickets filed from an earlier install,
/// or before the app wrote a uid, are first moved to this account
/// (`claimTickets`, by the Worker's /api/support/claim-tickets).
@MainActor
final class SupportTicketsMineTests: XCTestCase {

    private let apple = "001234.abcdef0123456789abcdef0123456789.0123"

    /// A claim runs once for each pair of account and person, and again
    /// whenever either changes: a reinstall's new uid, or another login.
    func testClaimRunsOncePerAccountAndPerson() {
        let mark = FirebaseSupportService.claimMark(uid: "uid-1", socialID: apple)
        XCTAssertTrue(FirebaseSupportService.needsClaim(remembered: nil, uid: "uid-1", socialID: apple))
        XCTAssertFalse(FirebaseSupportService.needsClaim(remembered: mark, uid: "uid-1", socialID: apple))
        XCTAssertTrue(FirebaseSupportService.needsClaim(remembered: mark, uid: "uid-2", socialID: apple))
        XCTAssertTrue(FirebaseSupportService.needsClaim(remembered: mark, uid: "uid-1", socialID: "1098765432"))
    }

    /// What is kept on the phone names the person by DiPo ID, never by the
    /// Apple or Google account id itself.
    func testTheRememberedMarkHoldsNoAccountID() {
        let mark = FirebaseSupportService.claimMark(uid: "uid-1", socialID: apple)
        XCTAssertFalse(mark.contains(apple))
        XCTAssertTrue(mark.hasSuffix(UserSession.dipoID(from: apple)))
    }

    /// The Worker reads the person's id from `socialUserID` and checks it
    /// against the ID token; nothing else in the body counts.
    func testClaimRequest() throws {
        XCTAssertEqual(FirebaseSupportService.claimURL.path, "/api/support/claim-tickets")
        let body = try XCTUnwrap(FirebaseSupportService.claimBody(socialID: apple))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["socialUserID": apple])
    }

    /// Every word of the confirm step exists in both languages.
    func testConfirmStepSpeaksBothLanguages() {
        let keys = ["support.connect_title", "support.connect_body", "support.connect_email",
                    "support.login_title", "support.login_required", "support.err.held_elsewhere",
                    "analysis.confirm_apple", "analysis.confirm_google", "analysis.confirming",
                    "analysis.err.other_account", "analysis.err.confirm_failed"]
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in keys {
                    XCTAssertNotEqual(loc(key), key, "\(key) missing in \(language)")
                }
            }
        }
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertTrue(loc("support.connect_email").contains("support@dipo.info"))
        }
    }
}
