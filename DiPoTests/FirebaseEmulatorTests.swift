import XCTest
@testable import DiPo

/// Real requests through the Firebase SDKs, against the Firebase Local
/// Emulator Suite: a copy of Auth and Firestore that runs on the CI machine.
///
/// SDKSetupTests checks that each SDK is set up; this checks that what the
/// app sends survives the trip. A support ticket is built by the app's own
/// code, written with the Firestore SDK, found again with the app's own
/// query and read back with the app's own decoder.
///
/// The project is "demo-dipo": the emulators keep demo projects on the
/// machine, so these tests can't touch DiPo's real Firebase or anyone's data.
///
/// Runs only when the emulator is up: the "sdk-emulator" job in
/// .github/workflows/ios.yml starts it and sets DIPO_AUTH_EMULATOR and
/// DIPO_FIRESTORE_EMULATOR. Everywhere else it skips.
@MainActor
final class FirebaseEmulatorTests: XCTestCase {

    private var firebase: EmulatorFirebase!

    override func setUp() async throws {
        guard let shared = EmulatorFirebase.shared else {
            throw XCTSkip("No Firebase emulator in this run (the sdk-emulator CI job starts one)")
        }
        firebase = shared
    }

    override func tearDown() async throws {
        try? firebase?.signOut()
    }

    /// Anonymous sign-in, the one every launch makes, gives a user.
    func testAnonymousSignIn() async throws {
        let user = try await firebase.signInAnonymously()
        XCTAssertFalse(user.uid.isEmpty)
        XCTAssertTrue(user.isAnonymous)
    }

    /// A ticket the app builds comes back whole through the app's own query
    /// and decoder, with the server's clock on it.
    func testATicketRoundTrips() async throws {
        let uid = try await firebase.signInAnonymously().uid
        let id = UUID().uuidString
        let sent = Date()
        let data = FirebaseSupportService.ticketData(
            userId: "apple_demo", uid: uid, plan: "Royal",
            category: "bug", subject: "Saldo tidak cocok", message: "Saldo di Home beda dengan kartu.",
            mediaCount: 2, name: "Demo", email: "demo@example.com", fcmToken: "demo-token")
        try await firebase.writeTicket(data, id: id)

        let mine = try await firebase.myTickets(uid: uid)
        let ticket = try XCTUnwrap(mine.first { $0.id == id }, "the app's query did not find the ticket it wrote")
        XCTAssertEqual(ticket.userId, "apple_demo")
        XCTAssertEqual(ticket.userPlan, "Royal")
        XCTAssertEqual(ticket.category, "bug")
        XCTAssertEqual(ticket.subject, "Saldo tidak cocok")
        XCTAssertEqual(ticket.message, "Saldo di Home beda dengan kartu.")
        XCTAssertEqual(ticket.userName, "Demo")
        XCTAssertEqual(ticket.userEmail, "demo@example.com")
        XCTAssertEqual(ticket.mediaCount, 2)
        XCTAssertEqual(ticket.status, "open")
        XCTAssertFalse(ticket.hasUnreadReply)
        // Stamped by the server, within a minute of sending.
        XCTAssertEqual(ticket.createdAt.timeIntervalSince(sent), 0, accuracy: 60)
        try await firebase.deleteTicket(id)
    }

    /// Each field is stored with the type the admin panel and the Worker read
    /// it as: a real timestamp (not a string or a number), an integer count,
    /// a true/false flag. Optional fields left out are absent, not null.
    func testTheStoredTypes() async throws {
        let uid = try await firebase.signInAnonymously().uid
        let id = UUID().uuidString
        let data = FirebaseSupportService.ticketData(
            userId: "google_demo", uid: uid, plan: "Free",
            category: "question", subject: "Halo", message: "Tanya",
            mediaCount: 0, name: nil, email: nil, fcmToken: nil)
        try await firebase.writeTicket(data, id: id)

        let types = try await firebase.storedTypes(ofTicket: id)
        XCTAssertEqual(types["createdAt"], "timestamp")
        XCTAssertEqual(types["updatedAt"], "timestamp")
        XCTAssertEqual(types["mediaCount"], "int")
        XCTAssertEqual(types["hasUnreadReply"], "bool")
        XCTAssertEqual(types["uid"], "string")
        XCTAssertEqual(types["status"], "string")
        XCTAssertNil(types["userName"], "no name: the field is left out, not written as null")
        XCTAssertNil(types["userEmail"])
        XCTAssertNil(types["fcmToken"])
        try await firebase.deleteTicket(id)
    }

    /// The query finds only the signed-in person's tickets: someone else's
    /// ticket in the same collection is not in their list.
    func testTheListIsOnlyMine() async throws {
        let other = UUID().uuidString
        try await firebase.writeTicket(FirebaseSupportService.ticketData(
            userId: "apple_other", uid: "someone-else", plan: "Free",
            category: "bug", subject: "Bukan punyamu", message: "-",
            mediaCount: 0, name: nil, email: nil, fcmToken: nil), id: other)

        let uid = try await firebase.signInAnonymously().uid
        let mine = try await firebase.myTickets(uid: uid)
        XCTAssertFalse(mine.contains { $0.id == other })
        try await firebase.deleteTicket(other)
    }
}
