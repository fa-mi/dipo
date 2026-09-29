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

    // MARK: Anyone else's errors

    /// Firebase, RevenueCat and Foundation errors never reach the screen as
    /// they are; the network ones read as "no signal" or "too slow".
    func testForeignErrorsBecomeTranslatedSentences() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(UserFacingError.message(offline), loc("error.no_connection"))
        let slow = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(UserFacingError.message(slow), loc("error.timeout"))
        let firestore = NSError(domain: "FIRFirestoreErrorDomain", code: 14,
                                userInfo: [NSLocalizedDescriptionKey: "Failed to get document because the client is offline."])
        XCTAssertEqual(UserFacingError.message(firestore), loc("error.no_connection"))
        let wrapped = NSError(domain: "RevenueCat.ErrorCode", code: 10,
                              userInfo: [NSUnderlyingErrorKey: offline])
        XCTAssertEqual(UserFacingError.message(wrapped), loc("error.no_connection"))
        let other = NSError(domain: "FIRFirestoreErrorDomain", code: 7,
                            userInfo: [NSLocalizedDescriptionKey: "Missing or insufficient permissions."])
        XCTAssertEqual(UserFacingError.message(other), loc("error.unknown"))
    }

    /// `.localizedDescription` may go to the console or into one of DiPo's
    /// own error types (which translate it away), never to the screen. Reads
    /// the sources, like ScrollWidthTests, and names any other use.
    func testRawErrorTextNeverReachesTheScreen() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let allowed = ["print(", "ReceiptScanError.", "BackupError.", "aiServiceUnavailable("]
        var offenders: [String] = []
        for dir in [root, root.appendingPathComponent("DiPo")] {
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
                let lines = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                    .components(separatedBy: "\n")
                for (i, line) in lines.enumerated() where line.contains(".localizedDescription") {
                    let code = line.components(separatedBy: "//").first ?? line
                    guard code.contains(".localizedDescription") else { continue }
                    if !allowed.contains(where: { code.contains($0) }) { offenders.append("\(name):\(i + 1)") }
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "Show UserFacingError.message(error) instead: \(offenders.joined(separator: ", "))")
    }

    func testOwnErrorsKeepTheirSentence() {
        XCTAssertEqual(UserFacingError.message(BackupError.noData), loc("backup.error.no_data"))
        XCTAssertEqual(UserFacingError.message(NetworkError.httpError(statusCode: 503)), loc("error.busy"))
    }}
