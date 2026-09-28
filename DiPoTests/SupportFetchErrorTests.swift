import XCTest
@testable import DiPo

/// The Support screen used to print Firestore's raw English error, followed by
/// a developer's note telling users to open the database rules. What it says
/// now is one translated line, and being offline gets its own.
@MainActor
final class SupportFetchErrorTests: XCTestCase {

    func testOfflineReadsAsOffline() {
        let offline = [
            NSError(domain: "FIRFirestoreErrorDomain", code: 14),   // unavailable
            NSError(domain: "FIRFirestoreErrorDomain", code: 4),    // deadline exceeded
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
        ]
        for e in offline {
            XCTAssertEqual(FirebaseSupportService.fetchErrorMessage(e), loc("support.load_error_offline"))
        }
    }

    func testAnythingElseIsTheGenericLineNeverTheRawText() {
        let denied = NSError(domain: "FIRFirestoreErrorDomain", code: 7,
                             userInfo: [NSLocalizedDescriptionKey: "Missing or insufficient permissions."])
        let message = FirebaseSupportService.fetchErrorMessage(denied)
        XCTAssertEqual(message, loc("error.unknown"))
        XCTAssertFalse(message.contains("permissions"))
    }
}
