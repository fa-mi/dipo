import XCTest
@testable import DiPo

/// The DiPo ID derivation is computed in three other places besides the app:
/// firestore.rules (who may write dipoIndex/{id}), the Worker's dashboard gate
/// and its tests, all in fa-mi/dipo-backend. They only agree if the algorithm
/// never changes, so these vectors are pinned in both repositories.
@MainActor
final class DipoIDTests: XCTestCase {

    func testDerivationMatchesThePinnedVectors() {
        XCTAssertEqual(UserSession.dipoID(from: "001234.alice"), "UFG5YAEK")
        XCTAssertEqual(UserSession.dipoID(from: "109876543210"), "5L9658FY")
        XCTAssertEqual(UserSession.dipoID(from: "001234.a1b2c3d4e5f6.0123"), "YLG6QRYP")
    }

    /// An index entry is followed only when its ID derives from the social id
    /// it points at — how the app refuses a squatted entry.
    func testAnEntryBelongsOnlyToTheAccountItDerivesFrom() {
        XCTAssertTrue(UserSession.dipoID("UFG5YAEK", belongsTo: "001234.alice"))
        XCTAssertTrue(UserSession.dipoID("ufg5yaek", belongsTo: "001234.alice"), "typed IDs are case-insensitive")
        XCTAssertFalse(UserSession.dipoID("UFG5YAEK", belongsTo: "109876543210"), "someone else's ID")
        XCTAssertFalse(UserSession.dipoID("UFG5YAEK", belongsTo: nil), "an entry with no social id")
        XCTAssertFalse(UserSession.dipoID("UFG5YAEK", belongsTo: ""))
    }
}
