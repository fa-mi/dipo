import Foundation

// MARK: - User-facing errors
//
// The sentence a person sees when something fails. Never an error's own
// `localizedDescription`: Firebase, RevenueCat and Foundation write it in
// English and in their own terms ("Failed to get document because the client
// is offline.", "The operation couldn't be completed. (FIRFirestoreErrorDomain
// error 14.)"), which means nothing to most of DiPo's users. Pinned by
// UserFacingErrorTests.

enum UserFacingError {

    /// A translated sentence for `error`. DiPo's own errors already carry one;
    /// anything else is read as "no signal", "too slow" or "something went
    /// wrong" — on a patchy rural connection the first is by far the likeliest.
    static func message(_ error: Error) -> String {
        if error is BackupError || error is NetworkError || error is ReceiptScanError,
           let own = (error as? LocalizedError)?.errorDescription {
            return own
        }
        switch connectivity(error) {
        case .offline:  return loc("error.no_connection")
        case .timedOut: return loc("error.timeout")
        case nil:       return loc("error.unknown")
        }
    }

    enum Connectivity { case offline, timedOut }

    /// Whether `error` (or the error beneath it) is the network, not DiPo.
    static func connectivity(_ error: Error) -> Connectivity? {
        let ns = error as NSError
        switch ns.domain {
        case NSURLErrorDomain:
            return ns.code == NSURLErrorTimedOut ? .timedOut : .offline
        // Firestore and Cloud Functions share gRPC codes:
        // 14 = unavailable (offline), 4 = deadline exceeded.
        case "FIRFirestoreErrorDomain", "com.firebase.functions":
            if ns.code == 14 { return .offline }
            if ns.code == 4 { return .timedOut }
        default:
            break
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return connectivity(underlying)
        }
        return nil
    }
}
