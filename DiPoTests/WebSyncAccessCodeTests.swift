import XCTest
@testable import DiPo

/// The web dashboard's access code. The Worker (dipo-backend, dashboard.js)
/// recomputes the same hash, so the vector here is pinned there too.
@MainActor
final class WebSyncAccessCodeTests: XCTestCase {

    func testHashMatchesTheWorkers() {
        XCTAssertEqual(WebSyncService.accessCodeHash(uid: "uid-123", code: "K7M2QX"),
                       "4531d844312b9b097cb61424ff2ea5cbc90ee18d2f445bef697de34a38e4d814")
    }

    /// Six characters from the alphabet the Worker accepts, and not the same
    /// code twice in a row.
    func testCodesAreSixUnambiguousCharacters() {
        let allowed = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var seen = Set<String>()
        for _ in 0..<200 {
            let code = WebSyncService.makeAccessCode()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy { allowed.contains($0) }, code)
            seen.insert(code)
        }
        XCTAssertGreaterThan(seen.count, 195, "codes should not repeat")
    }
}
