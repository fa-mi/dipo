import XCTest
@testable import DiPo

/// After a reinstall, Sync to Web said "DiPo ID still points at an older
/// install — contact support". It now offers to reconnect: one sign-in with
/// the same Apple ID or Google account, and the Worker moves the DiPo ID.
@MainActor
final class AccountReconnectTests: XCTestCase {

    func testTheStringsExistInBothLanguages() {
        let keys = ["websync.reconnect", "websync.reconnecting", "websync.reconnect_hint_apple",
                    "websync.reconnect_hint_google", "websync.reconnect_other", "websync.reconnect_failed"]
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in keys { XCTAssertNotEqual(loc(key), key, "missing \(key) in \(language)") }
            }
        }
    }

    /// The mismatch message is still formatted with the DiPo ID and the
    /// device's uid, in that order, in both languages.
    func testTheMismatchMessageKeepsItsTwoArguments() {
        for language in [LanguageManager.Language.english, .indonesian] {
            let text = LanguageManager.shared.withLanguage(language) {
                String(format: loc("websync.err_index_mismatch"), "A2F6P2WE", "device-uid")
            }
            XCTAssertTrue(text.contains("A2F6P2WE"), "\(language)")
            XCTAssertTrue(text.contains("device-uid"), "\(language)")
            XCTAssertLessThan(text.range(of: "A2F6P2WE")!.lowerBound, text.range(of: "device-uid")!.lowerBound)
        }
    }

    /// The Worker route the app calls, so a rename on one side shows up here.
    func testTheReclaimEndpoint() {
        XCTAssertEqual(AccountReconnect.reclaimURL.path, "/api/dipo-id/reclaim")
        XCTAssertEqual(AccountReconnect.reclaimURL.scheme, "https")
    }

    func testNoReconnectIsOfferedBeforeAnySync() {
        XCTAssertFalse(WebSyncService.shared.isReconnecting)
    }
}
