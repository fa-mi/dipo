import Foundation
import SwiftData
import FirebaseAuth
import FirebaseFirestore

// MARK: - Account Deletion
//
// Erases the account everywhere: shared goals, invitations, per-user Firestore
// documents, the Firebase Auth user, and the local SwiftData store.
//
// Order is not cosmetic — every Firestore write below needs a live auth session,
// so the Auth user MUST be deleted last. Delete it first and the rest of the
// cleanup silently fails with PERMISSION_DENIED, leaving the account's data
// behind with no way to ever reach it again.

enum AccountDeletionResult {
    case success
    /// Firebase refuses to delete an account whose sign-in is stale. The user
    /// has to sign in again, then retry — nothing has been destroyed yet.
    case requiresRecentLogin
    case failed(String)
}

@MainActor
final class AccountDeletionService {
    static let shared = AccountDeletionService()
    private init() {}

    private var db: Firestore { Firestore.firestore() }

    func deleteAccount(context: ModelContext) async -> AccountDeletionResult {
        guard let user = Auth.auth().currentUser else {
            return .failed("Not signed in.")
        }
        let uid      = user.uid
        let socialID = UserSession.shared.userID
        let dipoID   = UserSession.shared.dipoID

        print("[DiPo][account-delete] → uid=\(uid) social=\(socialID ?? "—") dipoID=\(dipoID ?? "—")")

        // Fail FAST on the one step that can legitimately refuse: re-auth. Doing
        // this before the destructive cleanup means a stale session leaves the
        // account completely intact instead of half-erased.
        if let staleCheck = await recentLoginProblem(for: user) {
            return staleCheck
        }

        // 1. Shared savings: transfer / delete / leave + drop invitations.
        await UnitySavingsService.shared.cleanupForAccountDeletion()

        // 2. Per-user documents keyed by the SOCIAL id.
        if let socialID {
            await deleteAll(in: db.collection("user_notifications").document(socialID).collection("items"),
                            label: "notification items")
            try? await db.collection("user_notifications").document(socialID).delete()
            try? await db.collection("device_tokens").document(socialID).delete()
            await deleteSupportTickets(socialID: socialID)
        }

        // 3. Identity documents. dipoIndex first — once users/{uid} is gone the
        //    mapping is a dangling pointer to a non-existent account, and its
        //    DiPo ID could never be reissued.
        if let dipoID { try? await db.collection("dipoIndex").document(dipoID).delete() }
        try? await db.collection("users").document(uid).delete()

        // 4. The auth account itself.
        do {
            try await user.delete()
        } catch let e as NSError {
            if e.code == 17014 {   // FIRAuthErrorCodeRequiresRecentLogin
                return .requiresRecentLogin
            }
            print("[DiPo][account-delete] ✗ auth delete failed: \(e.localizedDescription)")
            return .failed(e.localizedDescription)
        }

        // 5. Everything on device. `onLogout` BEFORE `signOut` (its own doc
        // says so): it resets `plan` to .free and neutralises the Smart Budget
        // flags. Without it the deleted account's Royal plan lingered in memory
        // — `canAccess` was safe (it checks isLoggedIn) but any code reading
        // `plan == .royal` directly kept showing Royal content until restart.
        if let socialID { PremiumManager.shared.onLogout(userID: socialID) }
        UserSwitchDetector.wipeLocalData(context: context)
        UserSession.shared.signOut()
        // The deleted account's cached entitlement would otherwise sit in
        // UserDefaults forever.
        if let socialID { UserDefaults.standard.removeObject(forKey: "premium_plan_\(socialID)") }

        print("[DiPo][account-delete] ✓ account fully deleted")
        return .success
    }

    /// Probe whether Firebase will accept a delete for this session. There's no
    /// "can I delete?" API, so we refresh the token — a stale session fails here
    /// the same way `delete()` would, but harmlessly.
    private func recentLoginProblem(for user: User) async -> AccountDeletionResult? {
        do {
            _ = try await user.getIDTokenResult(forcingRefresh: true)
            return nil
        } catch let e as NSError {
            if e.code == 17014 { return .requiresRecentLogin }
            return nil   // Other errors: let the real delete surface them.
        }
    }

    /// Support tickets are the user's own words + email — account deletion means
    /// they go too. Each ticket carries a `replies` subcollection that Firestore
    /// will not cascade, so it's cleared first.
    private func deleteSupportTickets(socialID: String) async {
        do {
            let tickets = try await db.collection("support_tickets")
                .whereField("userId", isEqualTo: socialID).getDocuments()
            for t in tickets.documents {
                await deleteAll(in: t.reference.collection("replies"), label: "replies")
                try? await t.reference.delete()
            }
            if !tickets.documents.isEmpty {
                print("[DiPo][account-delete] ✓ removed \(tickets.documents.count) support ticket(s)")
            }
        } catch {
            print("[DiPo][account-delete] ✗ support tickets: \(error.localizedDescription)")
        }
    }

    /// Batched collection wipe — Firestore has no client-side recursive delete.
    private func deleteAll(in ref: CollectionReference, label: String, batchSize: Int = 300) async {
        var removed = 0
        while true {
            guard let snap = try? await ref.limit(to: batchSize).getDocuments(),
                  !snap.documents.isEmpty else { break }
            let batch = db.batch()
            snap.documents.forEach { batch.deleteDocument($0.reference) }
            guard (try? await batch.commit()) != nil else { break }
            removed += snap.documents.count
            if snap.documents.count < batchSize { break }
        }
        if removed > 0 { print("[DiPo][account-delete] ✓ removed \(removed) \(label)") }
    }
}
