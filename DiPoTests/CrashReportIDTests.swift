import XCTest
@testable import DiPo

/// Crash reports go to Firebase Crashlytics, a third-party dashboard. They
/// carry the person's DiPo ID (what Profile shows) so a report can be matched
/// to whoever sent it, but never the Apple or Google account id it is derived
/// from.
@MainActor
final class CrashReportIDTests: XCTestCase {

    func testReportsCarryTheDiPoIDNotTheAccountID() {
        let apple = "001234.abcdef0123456789abcdef0123456789.0123"
        let reported = CrashReporter.reportedID(for: apple)
        XCTAssertEqual(reported, UserSession.dipoID(from: apple))
        XCTAssertEqual(reported.count, 8)
        XCTAssertFalse(reported.contains(apple))
        XCTAssertFalse(apple.contains(reported))

        let google = "109876543210987654321"
        XCTAssertEqual(CrashReporter.reportedID(for: google), UserSession.dipoID(from: google))
        XCTAssertNotEqual(CrashReporter.reportedID(for: google), google)
    }

    /// The same person always gets the same id, and two people never share one
    /// in practice, so reports still group by person.
    func testStableAndDistinct() {
        XCTAssertEqual(CrashReporter.reportedID(for: "a-user"), CrashReporter.reportedID(for: "a-user"))
        XCTAssertNotEqual(CrashReporter.reportedID(for: "a-user"), CrashReporter.reportedID(for: "b-user"))
    }

    func testSignedOutClearsIt() {
        XCTAssertEqual(CrashReporter.reportedID(for: nil), "")
        XCTAssertEqual(CrashReporter.reportedID(for: ""), "")
    }
}
