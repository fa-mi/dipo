import XCTest
@testable import DiPo

/// When the Worker answers 503, DiPo AI is down for everyone: the account
/// behind it is out of balance or past a limit, or the day's brake is on.
/// Nothing was spent, the owner has been emailed, and "try again in a moment"
/// is the wrong advice. Each AI feature says so in its own words.
@MainActor
final class AIUnavailableTests: XCTestCase {

    func testChatSaysSoAndThatNoCreditWasUsed() {
        XCTAssertEqual(AIChatViewModel.userErrorText(for: .httpError(statusCode: 503)), loc("ai.error.unavailable"))
        XCTAssertTrue(AIChatViewModel.userErrorText(for: .httpError(statusCode: 502)).hasPrefix(loc("ai.error.generic")),
                      "anything else is still the old try-again")
    }

    func testAScanSaysSoAndIsNotOfferedAgain() {
        XCTAssertEqual(ReceiptScanError.aiPaused.errorDescription, loc("receipt.error.ai_paused"))
        XCTAssertFalse(ReceiptScanError.aiPaused.isRetryable, "another photo won't help")
    }

    func testTheAnalysisSaysItWasNotCounted() {
        let body = Data(#"{"error":"ai_unavailable","reason":"billing"}"#.utf8)
        XCTAssertEqual(DebtAnalysisClient.failure(status: 503, body: body), .unavailable)
        // Waited for, the 503 arrives inside a 200, after the spaces.
        let streamed = Data(#"   {"error":"ai_unavailable","reason":"paused","status":503}"#.utf8)
        XCTAssertEqual(DebtAnalysisClient.status(http: 200, body: streamed), 503)
        XCTAssertEqual(DebtAnalysisClient.Failure.unavailable.messageKey, "analysis.err.unavailable")
    }

    func testTheWordsExistInBothLanguages() {
        for key in ["ai.error.unavailable", "receipt.error.ai_paused", "analysis.err.unavailable"] {
            XCTAssertNotEqual(loc(key), key, key)
        }
    }
}
