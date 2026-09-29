import XCTest
@testable import DiPo

/// What Ask DiPo does without signal. Rural coverage drops in and out, and
/// the app used to answer that by locking itself behind a full-screen page;
/// now it stays usable, so these pin what "usable" means for the chat.
@MainActor
final class OfflineChatTests: XCTestCase {

    private var savedUserID: String?

    override func setUp() async throws {
        savedUserID = UserSession.shared.userID
        UserSession.shared.userID = "offline-test-user"
        // NWPathMonitor reports the real path once, shortly after the service
        // is created; let that land before overriding it.
        _ = NetworkService.shared
        try await Task.sleep(nanoseconds: 300_000_000)
        NetworkService.shared.isOnline = false
    }

    override func tearDown() async throws {
        NetworkService.shared.isOnline = true
        UserSession.shared.userID = savedUserID
    }

    /// A message only the model can answer is handed back, not lost.
    func testMessageNeedingTheModelGoesBackToTheInput() async {
        let vm = AIChatViewModel()
        let question = "kenapa pengeluaranku naik bulan ini?"
        vm.input = question

        await vm.send()

        XCTAssertEqual(vm.input, question, "the typed message is back in the box")
        XCTAssertFalse(vm.messages.contains { $0.role == .user && $0.text == question },
                       "no user bubble, or resending would show it twice")
        XCTAssertEqual(vm.messages.last?.text, loc("ai.offline.kept"))
        XCTAssertEqual(vm.messages.last?.isError, true)
        XCTAssertFalse(vm.isLoading)
    }

    /// Plain entries never needed the network, and still don't.
    func testSimpleEntryStillRecordsOffline() async {
        let vm = AIChatViewModel()
        vm.input = "beli kopi 25rb"

        await vm.send()

        XCTAssertEqual(vm.input, "")
        let reply = vm.messages.last
        XCTAssertEqual(reply?.role, .assistant)
        XCTAssertEqual(reply?.isError, false)
        XCTAssertEqual(reply?.transactions.first?.amount, 25_000)
    }

    /// The lost-signal cases are the ones that keep the message; a server
    /// answering with an error is a different failure.
    func testWhichErrorsCountAsLostSignal() {
        XCTAssertTrue(NetworkError.noConnection.isLostSignal)
        XCTAssertTrue(NetworkError.timeout.isLostSignal)
        XCTAssertFalse(NetworkError.httpError(statusCode: 500).isLostSignal)
        XCTAssertFalse(NetworkError.unknown.isLostSignal)
    }
}
