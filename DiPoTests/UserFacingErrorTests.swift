import XCTest
@testable import DiPo

/// Errors a person can see are translated sentences, never a system's own
/// English text ("HTTP Error 429", "Decoding error: …", "Failed to read
/// backup: The file couldn't be opened …").
@MainActor
final class UserFacingErrorTests: XCTestCase {

    func testBackupErrorsAreTranslated() {
        XCTAssertEqual(BackupError.readFailed("The file couldn’t be opened.").errorDescription, loc("backup.error.read"))
        XCTAssertEqual(BackupError.decodeFailed("keyNotFound").errorDescription, loc("backup.error.decode"))
        XCTAssertEqual(BackupError.unknownVersion(9).errorDescription, loc("backup.error.newer_version"))
        XCTAssertEqual(BackupError.writeFailed("No space left").errorDescription, loc("backup.error.write"))
        XCTAssertEqual(BackupError.noData.errorDescription, loc("backup.error.no_data"))
    }

    func testServerTroubleReadsAsBusy() {
        XCTAssertEqual(NetworkError.httpError(statusCode: 429).errorDescription, loc("error.busy"))
        XCTAssertEqual(NetworkError.httpError(statusCode: 503).errorDescription, loc("error.busy"))
        XCTAssertEqual(NetworkError.httpError(statusCode: 404).errorDescription, loc("error.unknown"))
        let decoding = NetworkError.decodingError(NSError(domain: "x", code: 1))
        XCTAssertEqual(decoding.errorDescription, loc("error.invalid_response"))
    }

    func testScanFailureHidesTheSystemText() {
        let e = ReceiptScanError.unknown("The operation couldn’t be completed. (com.apple.Vision error 9.)")
        XCTAssertEqual(e.errorDescription, loc("error.unknown"))
    }
}
