import XCTest
@testable import DiPo

/// SDK failures reach Crashlytics (CrashReporter.recordSDK) as domain, code
/// and a fixed place label, and nothing else: no message, no email, no URL.
/// Being offline and cancelling a purchase are not faults and stay out.
final class SDKErrorReportTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// A Firebase Auth error can carry the person's email in its message and
    /// userInfo. What is sent keeps only the domain, the code and the place.
    func testWhatIsSentCarriesNoPersonalData() {
        let auth = NSError(domain: "FIRAuthErrorDomain", code: 17007, userInfo: [
            NSLocalizedDescriptionKey: "The email address budi@example.com is already in use.",
            "FIRAuthErrorUserInfoEmailKey": "budi@example.com",
            NSURLErrorFailingURLStringErrorKey: "https://identitytoolkit.googleapis.com/v1/accounts?key=abc",
        ])
        let sent = CrashReporter.sanitized(auth, at: "auth.google")
        XCTAssertEqual(sent.domain, "FIRAuthErrorDomain")
        XCTAssertEqual(sent.code, 17007)
        XCTAssertEqual(sent.localizedDescription, "auth.google")
        XCTAssertEqual(Set(sent.userInfo.keys), [NSLocalizedDescriptionKey])
        XCTAssertFalse("\(sent.userInfo)".contains("@"))
    }

    /// The error underneath is named by its domain and code only.
    func testTheUnderlyingErrorIsNamedNotQuoted() {
        let under = NSError(domain: NSURLErrorDomain, code: -1200,
                            userInfo: [NSLocalizedDescriptionKey: "secure connection to https://example.com failed"])
        let top = NSError(domain: "FIRFirestoreErrorDomain", code: 13, userInfo: [NSUnderlyingErrorKey: under])
        let sent = CrashReporter.sanitized(top, at: "joint.deposit")
        XCTAssertEqual(sent.userInfo["underlying"] as? String, "\(NSURLErrorDomain) -1200")
        XCTAssertFalse("\(sent.userInfo)".contains("example.com"))
    }

    /// No signal, a slow one, or a cancelled purchase: expected, not sent.
    /// A refused write (permission denied) is a fault and is sent.
    func testWhatCountsAsExpected() {
        func e(_ domain: String, _ code: Int, under: NSError? = nil) -> NSError {
            NSError(domain: domain, code: code, userInfo: under.map { [NSUnderlyingErrorKey: $0] } ?? [:])
        }
        XCTAssertTrue(CrashReporter.isExpected(e(NSURLErrorDomain, NSURLErrorNotConnectedToInternet)))
        XCTAssertTrue(CrashReporter.isExpected(e(NSURLErrorDomain, NSURLErrorTimedOut)))
        XCTAssertTrue(CrashReporter.isExpected(e("FIRFirestoreErrorDomain", 14)))          // unavailable
        XCTAssertTrue(CrashReporter.isExpected(e("FIRAuthErrorDomain", 17020)))            // network
        XCTAssertTrue(CrashReporter.isExpected(e("RevenueCat.ErrorCode", 1)))              // cancelled
        XCTAssertTrue(CrashReporter.isExpected(e("FIRAuthErrorDomain", 17999,
                                                 under: e(NSURLErrorDomain, NSURLErrorNetworkConnectionLost))))
        XCTAssertFalse(CrashReporter.isExpected(e("FIRFirestoreErrorDomain", 7)))          // permission denied
        XCTAssertFalse(CrashReporter.isExpected(e("RevenueCat.ErrorCode", 23)))
        XCTAssertFalse(CrashReporter.isExpected(e("DiPo", 1)))
    }

    /// A test run sends nothing, and recording never throws or crashes.
    func testATestRunSendsNothing() {
        XCTAssertFalse(RunContext.isOnline)
        CrashReporter.recordSDK(NSError(domain: "FIRFirestoreErrorDomain", code: 7), at: "joint.deposit")
    }

    /// Each place label is short, lowercase and dotted ("joint.deposit"), and
    /// used once, so every row in the Crashlytics dashboard points to one
    /// spot in the code.
    func testPlaceLabelsAreUniqueAndTidy() throws {
        var labels: [String: String] = [:]
        let pattern = try NSRegularExpression(pattern: #"recordSDK\([^,]+, at: "([^"]+)"\)"#)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", !url.path.contains("/DiPoTests/") else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let label = String(text[Range(m.range(at: 1), in: text)!])
                XCTAssertNotNil(label.range(of: #"^[a-z_]+\.[a-z_]+$"#, options: .regularExpression), label)
                XCTAssertNil(labels[label], "\(label) is used in \(labels[label] ?? "") and \(url.lastPathComponent)")
                labels[label] = url.lastPathComponent
            }
        }
        XCTAssertGreaterThan(labels.count, 40, "the SDK failure sites lost their reporting")
    }
}
