import Foundation
import FirebaseAuth

// MARK: - Worker request headers
//
// The Worker used to take the body's word for who was asking: `userId` chose
// whose AI credits to spend and `userPlan` set how many there were, so anyone
// with curl could claim Royal. It now looks the plan up in RevenueCat itself
// and wants proof of identity: the Firebase ID token, whose `apple.com` /
// `google.com` identity has to be the `userId` being spent.
//
// No token (signed out of Firebase, or offline while it needed refreshing) is
// not an error here. The request still goes, without the header; whether the
// Worker accepts that is its call (REQUIRE_ID_TOKEN in dipo-backend).
enum WorkerAuth {
    static func headers() async -> [String: String] {
        var headers = ["X-DiPo-Client": "iOS"]
        // `getIDToken()` hands back the cached token and only goes to the
        // network in the last five minutes of its hour.
        if let user = Auth.auth().currentUser,
           let token = try? await user.getIDToken() {
            headers["Authorization"] = "Bearer \(token)"
        }
        // Proof the request comes from the real app (see AppCheckSetup).
        // Nil until FirebaseAppCheck is linked; the Worker only logs its
        // absence while REQUIRE_APP_CHECK is off.
        if let appCheck = await AppCheckSetup.token() {
            headers["X-Firebase-AppCheck"] = appCheck
        }
        return headers
    }
}
