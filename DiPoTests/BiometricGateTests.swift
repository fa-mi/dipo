import XCTest
import LocalAuthentication
@testable import DiPo

/// When the lock screen stands. The dangerous case is a Face ID LOCKOUT: iOS
/// then reports biometrics as unavailable, and the app used to take that as
/// "no Face ID on this phone" and open — so failing five times got anyone in.
final class BiometricGateTests: XCTestCase {

    func testFaceIDAvailableKeepsTheGate() {
        XCTAssertTrue(AuthViewModel.biometricGateApplies(canEvaluate: true, error: nil))
    }

    func testLockoutAfterFailedAttemptsKeepsTheGate() {
        XCTAssertTrue(AuthViewModel.biometricGateApplies(canEvaluate: false, error: .biometryLockout),
                      "Five failed Face ID tries must not open the app.")
    }

    /// A phone genuinely without biometrics (none enrolled, no hardware)
    /// keeps today's behaviour: no gate unless the user can set one up.
    func testNoBiometricsOnThePhoneSkipsTheGate() {
        XCTAssertFalse(AuthViewModel.biometricGateApplies(canEvaluate: false, error: .biometryNotEnrolled))
        XCTAssertFalse(AuthViewModel.biometricGateApplies(canEvaluate: false, error: .biometryNotAvailable))
        XCTAssertFalse(AuthViewModel.biometricGateApplies(canEvaluate: false, error: .passcodeNotSet))
    }
}
