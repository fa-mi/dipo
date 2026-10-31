import XCTest
@testable import DiPo

/// A feature that needs an account and nothing more, like savings goals,
/// sends someone signed out to sign in, not to the paywall.
@MainActor
final class SignInRouteTests: XCTestCase {

    func testSignInLandsOnProfileWithItsSheet() {
        let vm = AppViewModel()
        vm.activeTab = .plan
        vm.planPath = [.goals]
        vm.openSignIn()
        XCTAssertEqual(vm.activeTab, .home)
        XCTAssertEqual(vm.homePath, [.signIn])
        XCTAssertEqual(vm.planPath, [.goals], "the goals screen waits behind, for after signing in")
    }

    /// Signed out, the goals row and screen ask to sign in. They never say
    /// Royal: one goal at a time is free with any account.
    func testTheWordsAskToSignInNotForRoyal() {
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in ["plan.sign_in_first", "savings.sign_in_body"] {
                    XCTAssertNotEqual(loc(key), key, "\(key) in \(language)")
                    XCTAssertFalse(loc(key).contains("Royal"), "\(key) in \(language)")
                }
            }
        }
    }
}
