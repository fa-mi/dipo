import Foundation
import FirebaseAuth
import FirebaseFirestore

// MARK: - Contact email

/// The address a user types in Profile, kept on the server so it outlives the
/// Keychain.
///
/// Apple hands over an email only on the very first sign-in, and usually a
/// hidden relay one at that, so for most people this typed address is the only
/// one support can reply to. It used to live in the Keychain, which sign-out
/// wipes, and in `device_tokens`, which nothing reads back. Fahmi set his,
/// signed out, signed in, and Profile said "Not set" again.
///
/// It now lives at `users/{uid}/private/contact`, which only its owner can read
/// or write (firestore.rules, fa-mi/dipo-backend#22). `users/{uid}` itself is
/// readable by anyone signed in, for the invite flow, so the address can't go
/// there. The Firebase uid is the same every time a given Apple or Google
/// account signs in (FirebaseAccountLinker), so the app finds it again.
enum ContactEmail {
    /// The same check the rules make: something@something.something, no
    /// spaces, at most 254 characters.
    static func isValid(_ email: String) -> Bool {
        guard email.count <= 254 else { return false }
        return email.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }

    /// Apple's hidden-address relay. It does reach the user, but it is not the
    /// address they chose, so one they typed always wins over it.
    static func isRelay(_ email: String) -> Bool {
        email.lowercased().hasSuffix("@privaterelay.appleid.com")
    }

    /// What the app should show after asking the server: the server's address
    /// when the phone has none, or has only Apple's relay; otherwise the one on
    /// the phone, which the user typed here.
    static func preferred(local: String?, server: String?) -> String? {
        let local = (local ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let server = (server ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !server.isEmpty, isValid(server), local.isEmpty || (isRelay(local) && !isRelay(server)) { return server }
        return local.isEmpty ? nil : local
    }

    private static var db: Firestore { Firestore.firestore() }

    private static func document() -> DocumentReference? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return db.collection("users").document(uid).collection("private").document("contact")
    }

    /// Writes the address the user typed. Returns false when there is no
    /// Firebase session yet or the write fails; the Keychain copy still holds
    /// it, and the next launch tries again (`restore` saves a local-only one).
    @discardableResult
    static func save(_ email: String) async -> Bool {
        guard isValid(email), let ref = document() else { return false }
        do {
            try await ref.setData(["email": email, "updatedAt": FieldValue.serverTimestamp()])
            return true
        } catch {
            print("[DiPo] contact email save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The saved address, if any.
    static func load() async -> String? {
        guard let ref = document() else { return nil }
        let snap = try? await ref.getDocument()
        return snap?.data()?["email"] as? String
    }

    /// The address an older build pushed to `device_tokens/{socialId}` before
    /// this document existed, so people who typed one then get it back.
    static func legacy(socialID: String) async -> String? {
        let snap = try? await db.collection("device_tokens").document(socialID).getDocument()
        return snap?.data()?["email"] as? String
    }

    /// Removed with the account (AccountDeletion).
    static func delete() async {
        try? await document()?.delete()
    }
}
