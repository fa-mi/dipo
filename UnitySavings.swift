import SwiftUI
import SwiftData
import FirebaseFirestore
import FirebaseAuth

// MARK: - Target Bersama (shared goals; "Unity Savings", once Tabungan Bersama)
//
// Collaborative savings goals shared across DiPo users. Unlike solo goals
// (SwiftData, per-device), shared goals live in Firestore so multiple members
// can see the same goal and contribute.
//
// Two kinds, one model:
//   • on its own — friends saving for a trip, people pooling for a gift. The
//     owner invites by DiPo ID; the invitation's id is "{goalId}_{uid}", which
//     is how the rules know whoever joins was invited.
//   • kept in a Rekening Bersama (`jointAccountId`) — the account's members
//     are its members, without invitations, and money moves to it from the
//     shared balance (JointAccountService.moveToGoal).
//
// Only the person who creates a goal needs Royal, as with Rekening Bersama:
// a friend does not need a subscription to put money towards a gift.

struct SharedGoal: Identifiable, Hashable {
    let id: String
    var ownerUid: String
    var ownerName: String
    var title: String
    var emoji: String
    var targetAmount: Double
    var currency: String
    var targetDate: Date?
    var savedAmount: Double
    var memberUids: [String]
    var memberCount: Int
    var maxMembers: Int
    var status: String            // "active" | "archived"
    var createdAt: Date
    /// The Rekening Bersama this goal is kept in, whose members are its members.
    var jointAccountId: String?

    var progress: Double { targetAmount > 0 ? min(savedAmount / targetAmount, 1) : 0 }
    var remaining: Double { max(targetAmount - savedAmount, 0) }
    var isOwner: Bool { ownerUid == Auth.auth().currentUser?.uid }
    var isFull: Bool { memberCount >= maxMembers }

    /// Decode a Firestore document. Returns nil for malformed docs.
    init?(id: String, data: [String: Any]) {
        guard let ownerUid = data["ownerUid"] as? String,
              let title = data["title"] as? String,
              let target = (data["targetAmount"] as? Double) ?? (data["targetAmount"] as? NSNumber)?.doubleValue
        else { return nil }
        self.id = id
        self.ownerUid = ownerUid
        self.ownerName = data["ownerName"] as? String ?? ""
        self.title = title
        self.emoji = data["emoji"] as? String ?? "🎯"
        self.targetAmount = target
        self.currency = data["currency"] as? String ?? "IDR"
        self.savedAmount = (data["savedAmount"] as? Double) ?? (data["savedAmount"] as? NSNumber)?.doubleValue ?? 0
        self.memberUids = data["memberUids"] as? [String] ?? []
        self.memberCount = data["memberCount"] as? Int ?? self.memberUids.count
        self.maxMembers = data["maxMembers"] as? Int ?? UnitySavingsService.maxMembers
        self.status = data["status"] as? String ?? "active"
        self.targetDate = (data["targetDate"] as? Timestamp)?.dateValue()
        self.createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        self.jointAccountId = (data["jointAccountId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var isKeptInAccount: Bool { jointAccountId != nil }
}

struct SharedInvite: Identifiable {
    let id: String
    var goalId: String
    var goalTitle: String
    var goalEmoji: String
    var fromUid: String
    var fromName: String
    var toUid: String
    var status: String
    var createdAt: Date

    /// The rules find an invitation by this id when someone joins.
    static func id(goal goalId: String, to uid: String) -> String { "\(goalId)_\(uid)" }

    /// Written by DiPo before 3.3 (114), under a random id the rules cannot
    /// find: it can only be declined. The owner invites again.
    var isLegacy: Bool { id != Self.id(goal: goalId, to: toUid) }

    init?(id: String, data: [String: Any]) {
        guard let goalId = data["goalId"] as? String else { return nil }
        self.id = id
        self.goalId = goalId
        self.toUid = data["toUid"] as? String ?? ""
        self.goalTitle = data["goalTitle"] as? String ?? "Shared Goal"
        self.goalEmoji = data["goalEmoji"] as? String ?? "🤝"
        self.fromUid = data["fromUid"] as? String ?? ""
        self.fromName = data["fromName"] as? String ?? "Someone"
        self.status = data["status"] as? String ?? "pending"
        self.createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
    }
}

struct SharedMember: Identifiable {
    let id: String            // uid
    var role: String
    var status: String
    var displayName: String
    var contributedAmount: Double
    var isOwner: Bool { role == "owner" }
    init(id: String, data: [String: Any]) {
        self.id = id
        self.role = data["role"] as? String ?? "member"
        self.status = data["status"] as? String ?? "active"
        self.displayName = data["displayName"] as? String ?? "Member"
        self.contributedAmount = (data["contributedAmount"] as? Double) ?? (data["contributedAmount"] as? NSNumber)?.doubleValue ?? 0
    }
}

struct SharedContribution: Identifiable {
    let id: String
    var uid: String
    var displayName: String
    var amount: Double
    var currency: String
    var note: String
    var date: Date
    init?(id: String, data: [String: Any]) {
        guard let amt = (data["amount"] as? Double) ?? (data["amount"] as? NSNumber)?.doubleValue else { return nil }
        self.id = id
        self.uid = data["uid"] as? String ?? ""
        self.displayName = data["displayName"] as? String ?? "Member"
        self.amount = amt
        self.currency = data["currency"] as? String ?? "IDR"
        self.note = data["note"] as? String ?? ""
        self.date = (data["date"] as? Timestamp)?.dateValue() ?? Date()
    }
}

// MARK: - Service

@MainActor
@Observable
final class UnitySavingsService {
    static let shared = UnitySavingsService()
    private init() {}

    static let maxMembers = 5

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var inviteListener: ListenerRegistration?

    private let notifyURL = "https://dipo-receipt-scanner.fahmi-aquinas.workers.dev/api/unity-notify"

    var goals: [SharedGoal] = []
    var pendingInvites: [SharedInvite] = []
    var isLoading = false

    /// Live-subscribe to the shared goals this user is a member of.
    func start() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        listener?.remove()
        isLoading = true
        listener = db.collection("sharedGoals")
            .whereField("memberUids", arrayContains: uid)
            .addSnapshotListener { [weak self] snap, err in
                guard let self else { return }
                Task { @MainActor in
                    self.isLoading = false
                    if let err { print("[Unity] listen error: \(err)"); return }
                    self.goals = (snap?.documents ?? [])
                        .compactMap { SharedGoal(id: $0.documentID, data: $0.data()) }
                        .filter { $0.status == "active" }
                        .sorted { $0.createdAt > $1.createdAt }
                }
            }
    }

    func stop() { listener?.remove(); listener = nil }

    // MARK: - Incoming invites (F3)

    /// Live-subscribe to invitations addressed to me. Query by a single field
    /// (toUid) so no composite index is needed; pending-filter client-side.
    func startInvites() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        inviteListener?.remove()
        inviteListener = db.collection("invitations")
            .whereField("toUid", isEqualTo: uid)
            .addSnapshotListener { [weak self] snap, err in
                guard let self else { return }
                Task { @MainActor in
                    if let err { print("[Unity] invites listen error: \(err)"); return }
                    self.pendingInvites = (snap?.documents ?? [])
                        .compactMap { SharedInvite(id: $0.documentID, data: $0.data()) }
                        .filter { $0.status == "pending" }
                        .sorted { $0.createdAt > $1.createdAt }
                }
            }
    }

    func stopInvites() { inviteListener?.remove(); inviteListener = nil }

    /// Accept an invite: join the goal, write my member row and answer the
    /// invitation, all in one batch — the rules let me in only while the
    /// invitation addressed to me is pending. No Royal needed: only the
    /// goal's creator needs it.
    @discardableResult
    func acceptInvite(_ invite: SharedInvite) async -> Bool {
        // Signed in to DiPo, not just the anonymous Firebase session every
        // launch establishes.
        guard UserSession.shared.isLoggedIn, let uid = Auth.auth().currentUser?.uid,
              invite.toUid == uid, !invite.isLegacy else {
            print("[Unity][accept] ✗ blocked: not signed in, not mine, or an invitation from an older DiPo")
            return false
        }
        let goalRef = db.collection("sharedGoals").document(invite.goalId)
        let myName = await myDisplayName(uid: uid, fallback: "Member")
        let batch = db.batch()
        batch.updateData(["memberUids": FieldValue.arrayUnion([uid]),
                          "memberCount": FieldValue.increment(Int64(1))], forDocument: goalRef)
        batch.setData([
            "role":        "member",
            "status":      "active",
            "displayName": myName,
            "contributedAmount": 0,
            "joinedAt":    FieldValue.serverTimestamp(),
        ], forDocument: goalRef.collection("members").document(uid), merge: true)
        batch.updateData(["status": "accepted", "respondedAt": FieldValue.serverTimestamp()],
                         forDocument: db.collection("invitations").document(invite.id))
        do {
            try await batch.commit()
            print("[Unity][accept] ✓ joined goal \(invite.goalId)")
            return true
        } catch {
            // Full, deleted, withdrawn, or I am already in.
            let ns = error as NSError
            print("[Unity][accept] ✗ \(ns.domain) code=\(ns.code): \(ns.localizedDescription)")
            return false
        }
    }

    func declineInvite(_ invite: SharedInvite) async {
        try? await db.collection("invitations").document(invite.id).setData([
            "status": "declined", "respondedAt": FieldValue.serverTimestamp(),
        ], merge: true)
    }

    // MARK: - Contributions (F4)

    /// Add a contribution: record it + bump the goal's collective savedAmount and
    /// this member's running total (atomic increments, no transaction needed).
    @discardableResult
    func addContribution(goal: SharedGoal, amount: Double, note: String) async -> Bool {
        guard amount > 0, let uid = Auth.auth().currentUser?.uid else { return false }
        let goalRef = db.collection("sharedGoals").document(goal.id)
        let name = await myDisplayName(uid: uid, fallback: "Member")
        // One batch: the contribution, the total and my running total move
        // together or not at all.
        let batch = db.batch()
        batch.setData([
            "uid": uid, "displayName": name, "amount": amount,
            "currency": goal.currency, "note": note, "source": "card",
            "date": FieldValue.serverTimestamp(),
        ], forDocument: goalRef.collection("contributions").document())
        batch.updateData(["savedAmount": FieldValue.increment(amount)], forDocument: goalRef)
        batch.setData(["contributedAmount": FieldValue.increment(amount)],
                      forDocument: goalRef.collection("members").document(uid), merge: true)
        do {
            try await batch.commit()
            return true
        } catch { print("[Unity] addContribution error: \(error)"); return false }
    }

    /// Self-heal: member rows written before the display name had loaded show a
    /// fallback ("Member"). On opening a goal, quietly update the current user's
    /// own member row to their real name if it differs. Rules allow a user to
    /// write their own member doc (request.auth.uid == memberUid).
    func syncMyMemberName(goalId: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let real = await myDisplayName(uid: uid, fallback: "")
        guard !real.isEmpty else { return }
        let ref = db.collection("sharedGoals").document(goalId).collection("members").document(uid)
        guard let snap = try? await ref.getDocument(), snap.exists else { return }
        let current = (snap.data()?["displayName"] as? String) ?? ""
        if current != real {
            try? await ref.setData(["displayName": real], merge: true)
        }
    }

    func fetchMembers(goalId: String) async -> [SharedMember] {
        do {
            let snap = try await db.collection("sharedGoals").document(goalId).collection("members").getDocuments()
            return snap.documents.map { SharedMember(id: $0.documentID, data: $0.data()) }
                .filter { $0.status != "left" }
                .sorted { $0.contributedAmount > $1.contributedAmount }
        } catch { return [] }
    }

    func fetchContributions(goalId: String) async -> [SharedContribution] {
        do {
            let snap = try await db.collection("sharedGoals").document(goalId)
                .collection("contributions")
                .order(by: "date", descending: true).limit(to: 30).getDocuments()
            return snap.documents.compactMap { SharedContribution(id: $0.documentID, data: $0.data()) }
        } catch { return [] }
    }

    /// Delete every document in a collection, in batches. There is no
    /// client-side recursive delete in Firestore — you must enumerate and remove
    /// each document yourself.
    private func deleteAll(in ref: CollectionReference, label: String, batchSize: Int = 300) async throws {
        var removed = 0
        while true {
            let snap = try await ref.limit(to: batchSize).getDocuments()
            if snap.documents.isEmpty { break }
            let batch = db.batch()
            snap.documents.forEach { batch.deleteDocument($0.reference) }
            try await batch.commit()
            removed += snap.documents.count
            if snap.documents.count < batchSize { break }
        }
        if removed > 0 { print("[Unity][delete] ✓ removed \(removed) \(label)") }
    }

    // MARK: - Owner / member controls (F5)

    /// A member leaves a goal. Their past contributions stay (the collective
    /// total isn't rewound); they're just removed from the roster.
    @discardableResult
    func leaveGoal(_ goal: SharedGoal) async -> Bool {
        guard let uid = Auth.auth().currentUser?.uid, goal.ownerUid != uid else { return false }
        return await removeUid(uid, from: goal.id, newStatus: "left")
    }

    /// Owner removes another member. Same "keep contributions" semantics.
    @discardableResult
    func removeMember(_ goal: SharedGoal, memberUid: String) async -> Bool {
        guard let uid = Auth.auth().currentUser?.uid, goal.ownerUid == uid, memberUid != uid else { return false }
        return await removeUid(memberUid, from: goal.id, newStatus: "removed")
    }

    private func removeUid(_ target: String, from goalId: String, newStatus: String) async -> Bool {
        let goalRef = db.collection("sharedGoals").document(goalId)
        do {
            _ = try await db.runTransaction { txn, errPtr -> Any? in
                let snap: DocumentSnapshot
                do { snap = try txn.getDocument(goalRef) } catch let e as NSError { errPtr?.pointee = e; return nil }
                guard let data = snap.data() else { return nil }
                var members = data["memberUids"] as? [String] ?? []
                members.removeAll { $0 == target }
                txn.updateData(["memberUids": members, "memberCount": members.count], forDocument: goalRef)
                return nil
            }
            try await goalRef.collection("members").document(target).setData(["status": newStatus], merge: true)
            return true
        } catch { print("[Unity] removeUid error: \(error)"); return false }
    }

    /// Owner deletes the goal for everyone — including everything hanging off it.
    ///
    /// Firestore does NOT cascade: deleting the goal document alone leaves its
    /// `members`/`contributions` subcollections orphaned in the database forever
    /// (invisible in the console tree, but still billed and still readable by
    /// anyone who kept the IDs), and leaves pending invitations pointing at a
    /// goal that no longer exists. So tear the children down first, parent last.
    @discardableResult
    func deleteGoal(_ goal: SharedGoal) async -> Bool {
        guard let uid = Auth.auth().currentUser?.uid, goal.ownerUid == uid else {
            print("[Unity][delete] ✗ blocked: not the owner")
            return false
        }
        let goalRef = db.collection("sharedGoals").document(goal.id)
        do {
            // 1. Subcollections.
            try await deleteAll(in: goalRef.collection("contributions"), label: "contributions")
            try await deleteAll(in: goalRef.collection("members"), label: "members")

            // 2. Invitations for this goal. Query by fromUid only (single-field
            //    index + the read rule allows it), then match goalId client-side.
            let mine = try await db.collection("invitations")
                .whereField("fromUid", isEqualTo: uid).getDocuments()
            var invitesRemoved = 0
            for doc in mine.documents where (doc.data()["goalId"] as? String) == goal.id {
                try? await doc.reference.delete()
                invitesRemoved += 1
            }
            if invitesRemoved > 0 { print("[Unity][delete] ✓ removed \(invitesRemoved) invitation(s)") }

            // 3. The goal itself LAST — the contributions delete rule resolves the
            //    owner via get() on this document, so it must still exist above.
            try await goalRef.delete()
            print("[Unity][delete] ✓ goal \(goal.id) fully removed")
            return true
        } catch {
            let ns = error as NSError
            print("[Unity][delete] ✗ \(ns.domain) code=\(ns.code): \(ns.localizedDescription)")
            return false
        }
    }

    /// Account-deletion cleanup for Unity Savings. For every goal I'm part of:
    ///   • I own it and others are still active → hand it to the oldest member;
    ///   • I own it and I'm the last one → delete it outright, subcollections
    ///     included. (This used to set `status: "archived"`, which stranded the
    ///     goal forever: the read rules gate on membership, so with nobody left
    ///     no one could ever see it again — it was invisible, undeletable data.)
    ///   • I'm only a member → leave; my past contributions stay for the rest.
    ///
    /// Finally removes every invitation I sent or received, so nobody is left
    /// holding an invite to a goal I've walked away from.
    func cleanupForAccountDeletion() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            // Query by MEMBERSHIP, not ownerUid: the rules only allow listing
            // goals you belong to, so `whereField("ownerUid", ...)` would be
            // denied outright. The owner is always in memberUids, so this still
            // finds everything — including previously archived goals.
            let mine = try await db.collection("sharedGoals")
                .whereField("memberUids", arrayContains: uid).getDocuments()

            for doc in mine.documents {
                let data    = doc.data()
                let goalRef = doc.reference
                guard (data["ownerUid"] as? String) == uid else {
                    _ = await removeUid(uid, from: doc.documentID, newStatus: "left")
                    print("[Unity][account-delete] ✓ left goal \(doc.documentID)")
                    continue
                }

                let members = try await goalRef.collection("members").getDocuments()
                let heirs = members.documents.compactMap { d -> (uid: String, joined: Date, name: String)? in
                    let m = d.data()
                    guard d.documentID != uid, (m["status"] as? String ?? "active") == "active" else { return nil }
                    return (d.documentID,
                            (m["joinedAt"] as? Timestamp)?.dateValue() ?? .distantFuture,
                            m["displayName"] as? String ?? "Member")
                }.sorted { $0.joined < $1.joined }

                if let heir = heirs.first {
                    var remaining = (data["memberUids"] as? [String] ?? []).filter { $0 != uid }
                    if !remaining.contains(heir.uid) { remaining.append(heir.uid) }

                    // Write the member docs BEFORE handing over ownership. The
                    // members rule authorises writes against the goal's CURRENT
                    // ownerUid — the moment we set ownerUid to the heir we stop
                    // being the owner (and drop out of memberUids), so anything
                    // left to write after that point gets PERMISSION_DENIED.
                    try await goalRef.collection("members").document(heir.uid).setData(["role": "owner"], merge: true)
                    try await goalRef.collection("members").document(uid).setData(["status": "left", "role": "member"], merge: true)

                    try await goalRef.updateData([
                        "ownerUid": heir.uid, "ownerName": heir.name,
                        "memberUids": remaining, "memberCount": remaining.count,
                    ])
                    print("[Unity][account-delete] ✓ goal \(doc.documentID) handed to \(heir.name)")
                } else {
                    try await deleteAll(in: goalRef.collection("contributions"), label: "contributions")
                    try await deleteAll(in: goalRef.collection("members"), label: "members")
                    try await goalRef.delete()
                    print("[Unity][account-delete] ✓ goal \(doc.documentID) deleted (no heirs)")
                }
            }

            for field in ["fromUid", "toUid"] {
                let snap = try await db.collection("invitations").whereField(field, isEqualTo: uid).getDocuments()
                for d in snap.documents { try? await d.reference.delete() }
                if !snap.documents.isEmpty {
                    print("[Unity][account-delete] ✓ removed \(snap.documents.count) invitation(s) by \(field)")
                }
            }
        } catch {
            let ns = error as NSError
            print("[Unity][account-delete] ✗ \(ns.domain) code=\(ns.code): \(ns.localizedDescription)")
        }
    }

    /// Best-effort push to the invitee via the worker (which reads the real
    /// invitation doc, so it can't be used to spam arbitrary pushes).
    /// Resolve the current user's display name reliably: prefer the live session
    /// name, and if it hasn't loaded yet (which is when member/contribution rows
    /// were showing "Member"/"Someone"), fall back to the authoritative profile
    /// doc `users/{uid}.displayName` before the generic fallback.
    private func myDisplayName(uid: String, fallback: String) async -> String {
        // The Profile name first — the same order Rekening Bersama uses, so
        // the two shared features call a person by one name. The sign-in name
        // is empty after a reinstall (Apple sends it once), which is how
        // rows here came to read "Member".
        if let known = JointAccountService.knownName() { return known }
        let snap = try? await db.collection("users").document(uid).getDocument()
        let profile = (snap?.data()?["displayName"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return profile.isEmpty ? fallback : profile
    }

    private func notifyInvite(inviteId: String) async {
        guard let url = URL(string: notifyURL) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in await WorkerAuth.headers() {
            req.setValue(value, forHTTPHeaderField: field)
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["inviteId": inviteId])
        // Short timeout: this is a best-effort push. It must never make the
        // "Send invite" button spin — the default 60s timeout previously kept
        // the UI in a loading state when the worker was slow/unreachable.
        req.timeoutInterval = 8
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Invite (F2)

    enum InviteResult { case success, notFound, alreadyMember, alreadyInvited, full, cantInviteSelf, error }

    /// Resolve a typed DiPo ID → user, validate, and write a pending invitation.
    /// The write itself is guarded by Firestore rules (only the goal owner may
    /// create invites for their goal). Royal + membership checks are done here
    /// for good UX; accept-time re-checks (F3) are the hard gate.
    func invite(goal: SharedGoal, toDipoID rawID: String) async -> InviteResult {
        let dipoID = rawID.uppercased().trimmingCharacters(in: .whitespaces)
        // A goal kept in a Rekening Bersama takes its members from the account.
        guard let fromUid = Auth.auth().currentUser?.uid, !dipoID.isEmpty, !goal.isKeptInAccount else {
            print("[Unity][invite] ✗ blocked: no auth uid or empty DiPo ID (id='\(dipoID)')")
            return .error
        }
        // Tracks which Firestore operation is in flight, so the catch block can
        // name the exact failing step (resolve / royal-check / write-invite …)
        // instead of a generic "invite error".
        var step = "resolve-dipoIndex"
        print("[Unity][invite] → target='\(dipoID)' from=\(fromUid) goal=\(goal.id)")
        do {
            // 1. Resolve invitee by DiPo ID.
            let idxSnap = try await db.collection("dipoIndex").document(dipoID).getDocument()
            guard idxSnap.exists, let idx = idxSnap.data(), let toUid = idx["uid"] as? String else {
                print("[Unity][invite] ✗ step=\(step): DiPo ID not found in dipoIndex")
                return .notFound
            }
            print("[Unity][invite] ✓ resolved → toUid=\(toUid)")
            if toUid == fromUid {
                print("[Unity][invite] ✗ cannot invite yourself")
                return .cantInviteSelf
            }

            // 2. The invitee's profile, for the check below. No plan check:
            //    only the goal's creator needs Royal.
            step = "read-user-profile"
            let userSnap = try await db.collection("users").document(toUid).getDocument()

            // The entry must be the invitee's own. A DiPo ID derives from the
            // account's social id, so an entry pointing someone else's ID at
            // an account (squatted before the rules checked this) would send
            // the invite — and its goal — to the wrong person.
            let toSocialID = (idx["socialUserID"] as? String) ?? (userSnap.data()?["socialUserID"] as? String)
            guard UserSession.dipoID(dipoID, belongsTo: toSocialID) else {
                print("[Unity][invite] ✗ step=\(step): dipoIndex/\(dipoID) does not derive from the account it points at")
                return .notFound
            }

            // 3. Fresh goal state — not already a member, not full.
            step = "read-goal"
            let goalSnap = try await db.collection("sharedGoals").document(goal.id).getDocument()
            guard let gdata = goalSnap.data() else {
                print("[Unity][invite] ✗ step=\(step): goal doc missing")
                return .error
            }
            let members = gdata["memberUids"] as? [String] ?? []
            let count   = gdata["memberCount"] as? Int ?? members.count
            let maxM    = gdata["maxMembers"] as? Int ?? Self.maxMembers
            print("[Unity][invite] ✓ goal state: \(count)/\(maxM) members")
            if members.contains(toUid) {
                print("[Unity][invite] ✗ step=\(step): already a member")
                return .alreadyMember
            }
            if count >= maxM {
                print("[Unity][invite] ✗ step=\(step): goal is full")
                return .full
            }

            // 4. One invitation per person per goal, by id. An earlier one
            //    that was declined or withdrawn is cleared first, so the new
            //    one starts fresh and the push goes out again. Found through
            //    my own invitations: a document that does not exist cannot
            //    be read directly under the rules.
            step = "query-existing-invites"
            let inviteId = SharedInvite.id(goal: goal.id, to: toUid)
            let mine = try await db.collection("invitations")
                .whereField("fromUid", isEqualTo: fromUid)
                .getDocuments()
            if let old = mine.documents.first(where: { $0.documentID == inviteId }) {
                if (old.data()["status"] as? String) == "pending" {
                    print("[Unity][invite] ✗ step=\(step): duplicate pending invite exists")
                    return .alreadyInvited
                }
                try await old.reference.delete()
            }

            // 5. Resolve the SENDER's display name so the invite (and its push)
            //    shows who it's really from — the recipient needs this to judge
            //    whether the invite is from someone they trust. Prefer the live
            //    session name; if it isn't loaded yet, fall back to the
            //    authoritative profile doc (users/{fromUid}.displayName) rather
            //    than a generic "Someone".
            step = "resolve-sender-name"
            var fromName = JointAccountService.knownName() ?? ""
            if fromName.isEmpty {
                let meSnap = try? await db.collection("users").document(fromUid).getDocument()
                fromName = (meSnap?.data()?["displayName"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            }
            if fromName.isEmpty { fromName = "Someone" }
            print("[Unity][invite] sender name resolved → '\(fromName)'")

            // 6. Create the invitation, then fire a best-effort push.
            step = "write-invitation"
            let ref = db.collection("invitations").document(inviteId)
            try await ref.setData([
                "goalId":     goal.id,
                "goalTitle":  JointText.clip(goal.title, 60),
                "goalEmoji":  JointText.clip(goal.emoji, 8),
                "fromUid":    fromUid,
                "fromName":   JointText.clip(fromName, 40),
                "toUid":      toUid,
                "toSocialId": toSocialID ?? "",
                "status":     "pending",
                "createdAt":  FieldValue.serverTimestamp(),
            ])
            print("[Unity][invite] ✓ invitation written: invitations/\(ref.documentID)")

            // Fire-and-forget the push. The invite is ALREADY committed to
            // Firestore, so success shouldn't wait on (or be blocked by) a
            // best-effort notification. Awaiting it here previously froze the
            // "Send invite" button whenever the worker was slow/unreachable.
            let inviteDocId = ref.documentID
            Task { await self.notifyInvite(inviteId: inviteDocId) }
            print("[Unity][invite] ✓ SUCCESS (push dispatched in background)")
            return .success
        } catch {
            let ns = error as NSError
            // domain=FIRFirestoreErrorDomain code=7 → PERMISSION_DENIED (rules)
            // code=9 → FAILED_PRECONDITION (usually a missing composite index)
            print("[Unity][invite] ✗ THREW at step='\(step)' — \(ns.domain) code=\(ns.code): \(ns.localizedDescription)")
            return .error
        }
    }

    /// Create a shared goal owned by the current user: on its own (sole
    /// member, inviting afterwards), or kept in a Rekening Bersama, with the
    /// account's members as its members and in its currency.
    @discardableResult
    func createGoal(title: String, emoji: String, targetAmount: Double,
                    currency: String, targetDate: Date?, in account: JointAccount? = nil) async -> Bool {
        guard let uid = Auth.auth().currentUser?.uid else { return false }
        if let account, !account.memberUids.contains(uid) || !account.isActive { return false }
        let ownerName = await myDisplayName(uid: uid, fallback: "Me")
        let members = account?.memberUids ?? [uid]
        let ref = db.collection("sharedGoals").document()
        var data: [String: Any] = [
            "ownerUid":    uid,
            "ownerName":   ownerName,
            "title":       title,
            "emoji":       emoji,
            "targetAmount": targetAmount,
            "currency":    account?.currency ?? currency,
            "savedAmount": 0,
            "memberUids":  members,
            "memberCount": members.count,
            "maxMembers":  Self.maxMembers,
            "status":      "active",
            "createdAt":   FieldValue.serverTimestamp(),
        ]
        if let d = targetDate { data["targetDate"] = Timestamp(date: d) }
        if let account { data["jointAccountId"] = account.id }
        do {
            try await ref.setData(data)
            // Every member's row, mine as the owner. The account's members
            // are known by the names they use in it.
            let names = account.map { JointAccountService.shared.members[$0.id] ?? [] } ?? []
            let batch = db.batch()
            for member in members {
                let name = member == uid ? ownerName
                    : names.first { $0.id == member }?.displayName ?? ""
                batch.setData([
                    "role":        member == uid ? "owner" : "member",
                    "status":      "active",
                    "displayName": name.isEmpty ? "Member" : name,
                    "contributedAmount": 0,
                    "joinedAt":    FieldValue.serverTimestamp(),
                ], forDocument: ref.collection("members").document(member), merge: true)
            }
            try await batch.commit()
            return true
        } catch {
            print("[Unity] createGoal error: \(error)")
            return false
        }
    }

    // MARK: - Goals kept in a Rekening Bersama

    /// Per account: its goals, live, while the account is open on screen.
    var accountGoals: [String: [SharedGoal]] = [:]
    private var accountGoalListeners: [String: ListenerRegistration] = [:]

    func watchGoals(of account: JointAccount) {
        guard accountGoalListeners[account.id] == nil else { return }
        let accountId = account.id
        accountGoalListeners[accountId] = db.collection("sharedGoals")
            .whereField("jointAccountId", isEqualTo: accountId)
            .addSnapshotListener { [weak self] snap, err in
                guard let self else { return }
                Task { @MainActor in
                    if let err { print("[Unity] account goals listen error: \(err)"); return }
                    let goals = (snap?.documents ?? [])
                        .compactMap { SharedGoal(id: $0.documentID, data: $0.data()) }
                        .filter { $0.status == "active" }
                        .sorted { $0.createdAt < $1.createdAt }
                    self.accountGoals[accountId] = goals
                    if let account = JointAccountService.shared.account(accountId) {
                        await self.tidy(goals, of: account)
                    }
                }
            }
    }

    func stopWatchingGoals(of accountId: String) {
        accountGoalListeners[accountId]?.remove()
        accountGoalListeners[accountId] = nil
    }

    /// Keeps each goal's members in step with the account's: I join the ones
    /// I am not in yet (I may have joined the account after they were made),
    /// and take off someone who has left the account — handing the goal to
    /// myself if that was its owner. Quiet: the rules decide, and a refusal
    /// only means someone else got there first.
    private func tidy(_ goals: [SharedGoal], of account: JointAccount) async {
        guard let uid = Auth.auth().currentUser?.uid, account.memberUids.contains(uid) else { return }
        for goal in goals {
            let ref = db.collection("sharedGoals").document(goal.id)
            if JointGoals.shouldJoin(goal, account: account, me: uid) {
                let me = await myDisplayName(uid: uid, fallback: "Member")
                let batch = db.batch()
                batch.updateData(["memberUids": FieldValue.arrayUnion([uid]),
                                  "memberCount": FieldValue.increment(Int64(1))], forDocument: ref)
                batch.setData(["role": "member", "status": "active", "displayName": me,
                               "contributedAmount": 0, "joinedAt": FieldValue.serverTimestamp()],
                              forDocument: ref.collection("members").document(uid), merge: true)
                try? await batch.commit()
            } else if goal.memberUids.contains(uid), let gone = JointGoals.departed(goal, account: account).first {
                var update: [String: Any] = ["memberUids": FieldValue.arrayRemove([gone]),
                                             "memberCount": FieldValue.increment(Int64(-1))]
                if gone == goal.ownerUid {
                    update["ownerUid"] = uid
                    update["ownerName"] = await myDisplayName(uid: uid, fallback: "Member")
                }
                try? await ref.updateData(update)
            }
        }
    }

    /// Before I leave a Rekening Bersama: I leave its goals too, handing any
    /// I own to someone who stays.
    func leaveGoals(keptIn account: JointAccount) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let snap = try? await db.collection("sharedGoals")
            .whereField("jointAccountId", isEqualTo: account.id).getDocuments()
        for doc in snap?.documents ?? [] {
            guard let goal = SharedGoal(id: doc.documentID, data: doc.data()),
                  goal.memberUids.contains(uid) else { continue }
            let remaining = goal.memberUids.filter { $0 != uid }
            var update: [String: Any] = ["memberUids": remaining, "memberCount": remaining.count]
            if goal.ownerUid == uid {
                guard let heir = remaining.first(where: { account.memberUids.contains($0) }) ?? remaining.first else {
                    continue   // the last one in it: it stays with me
                }
                update["ownerUid"] = heir
                update["ownerName"] = JointAccountService.shared.name(of: heir, in: account.id)
            }
            try? await doc.reference.updateData(update)
            try? await doc.reference.collection("members").document(uid).setData(["status": "left"], merge: true)
        }
    }
}

// MARK: - Section (embedded in the Savings Goals screen)

struct UnitySavingsSection: View {
    @State private var unity = UnitySavingsService.shared
    /// The parent owns the create flow (a single "+" that opens the type
    /// chooser), so the section just asks it to start a shared-goal creation.
    var onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Pending invitations inbox (F3) — shown above the goals list.
            if !unity.pendingInvites.isEmpty {
                Text(String(format: loc("unity.invites_header"), unity.pendingInvites.count))
                    .font(.system(.body, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                    .padding(.horizontal, 22)
                ForEach(unity.pendingInvites) { invite in
                    InviteInboxRow(invite: invite)
                        .padding(.horizontal, 22)
                }
            }

            // Same heading style as "In progress" above, so the screen reads as
            // one list of sections rather than a second, differently-coloured app.
            Text(loc("unity.title"))
                .font(.system(.body, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 4)

            if unity.goals.isEmpty {
                UnityEmptyCard { onCreate() }
                    .padding(.horizontal, 22)
            } else {
                // Overview stays scannable: show at most `previewLimit`; the rest
                // live on a dedicated full-list page reached via "See all".
                ForEach(unity.goals.prefix(Self.previewLimit)) { goal in
                    SharedGoalCard(goal: goal)
                        .padding(.horizontal, 22)
                }
                if unity.goals.count > Self.previewLimit {
                    NavigationLink { AllSharedGoalsView() } label: {
                        SeeAllLabel(count: unity.goals.count)
                    }
                    .padding(.horizontal, 22)
                }
            }
        }
        // The Rekening Bersama service too: a goal kept in an account is
        // labelled with the account's name.
        .onAppear { unity.start(); unity.startInvites(); JointAccountService.shared.start() }
        .onDisappear { unity.stop(); unity.stopInvites() }
    }

    private static let previewLimit = 3
}

// MARK: - See-all row (shared by both savings sections)

struct SeeAllLabel: View {
    let count: Int
    var tint: Color = AppTheme.accent
    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: loc("savings.see_all"), count))
                .font(.system(.subheadline, weight: .semibold)).foregroundStyle(tint)
            Spacer()
            Image(systemName: "chevron.right").font(.system(.caption, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.vertical, 14).padding(.horizontal, 16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }
}

// MARK: - All Shared Goals (full-list page)

struct AllSharedGoalsView: View {
    @State private var unity = UnitySavingsService.shared
    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 14) {
                    ForEach(unity.goals) { goal in
                        SharedGoalCard(goal: goal).padding(.horizontal, 22)
                    }
                }
                .padding(.vertical, 16)
                .containerRelativeFrame(.horizontal)
            }
        }
        .navigationTitle(loc("unity.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { unity.start() }
        .trackScreen(.unitySavings)
    }
}

// MARK: - Goal type chooser (New Goal page)

enum GoalSheet: Int, Identifiable { case chooser, personal, shared, paywall; var id: Int { rawValue } }

struct GoalTypeChooserView: View {
    /// Marks a kind that opens the paywall instead of its form: a second
    /// personal goal at once, or starting a shared one, without Royal.
    var personalNeedsRoyal = false
    var sharedNeedsRoyal = false
    let onPersonal: () -> Void
    let onShared: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack { AppTheme.bg.ignoresSafeArea()
                VStack(spacing: 14) {
                    Text(loc("goal.chooser_sub"))
                        .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.top, 8)

                    optionCard(icon: "star.fill", tint: AppTheme.accent,
                               title: loc("savings.personal_goal"),
                               subtitle: loc("goal.chooser_personal_sub"),
                               needsRoyal: personalNeedsRoyal,
                               action: onPersonal)
                    optionCard(icon: "person.2.fill", tint: AppTheme.blue,
                               title: loc("unity.title"),
                               subtitle: loc("goal.chooser_shared_sub"),
                               needsRoyal: sharedNeedsRoyal,
                               action: onShared)
                    Spacer()
                }
            }
            .navigationTitle(loc("goal.chooser_title")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
            } }
        }
    }

    private func optionCard(icon: String, tint: Color, title: String, subtitle: String,
                            needsRoyal: Bool, action: @escaping () -> Void) -> some View {
        Button { HapticManager.shared.tap(); action() } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.md).fill(tint.opacity(0.15)).frame(width: 52, height: 52)
                    Image(systemName: icon).font(.system(.title2)).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(.callout, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                    Text(subtitle).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if needsRoyal {
                    PlanBadge(plan: .royal)
                } else {
                    Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(16)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(ScaleButtonStyle())
        .padding(.horizontal, 22)
    }
}

private struct UnityEmptyCard: View {
    let onCreate: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Text("🤝").font(.system(.title))
            Text(loc("unity.empty")).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
            Text(loc("unity.empty_sub")).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                HapticManager.shared.tap(); onCreate()
            } label: {
                Text(loc("unity.create")).font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(AppTheme.cardMid, in: Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
    }
}

// MARK: - Invite inbox row (F3)

struct InviteInboxRow: View {
    let invite: SharedInvite
    @State private var unity = UnitySavingsService.shared
    @State private var busy = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.sm).fill(AppTheme.cardMid.opacity(0.7)).frame(width: 42, height: 42)
                Text(invite.goalEmoji).font(.system(.title3))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.goalTitle).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                Text(invite.isLegacy ? String(format: loc("unity.invite_legacy"), invite.fromName)
                                     : String(format: loc("unity.invited_by"), invite.fromName))
                    .font(.system(.caption2)).foregroundStyle(invite.isLegacy ? AppTheme.orange : AppTheme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if busy {
                ProgressView().tint(AppTheme.accent)
            } else {
                HStack(spacing: 8) {
                    Button {
                        busy = true
                        Task { await unity.declineInvite(invite); busy = false; HapticManager.shared.tap() }
                    } label: {
                        Image(systemName: "xmark").font(.system(.footnote, weight: .bold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 34, height: 34).background(AppTheme.cardMid, in: Circle())
                    }
.accessibilityLabel(loc("a11y.decline_invite")).buttonStyle(ScaleButtonStyle())
                    // Written by an older DiPo under an id the rules cannot
                    // find: accepting would only fail. The owner invites again.
                    if !invite.isLegacy {
                        Button {
                            busy = true
                            Task {
                                let ok = await unity.acceptInvite(invite)
                                busy = false
                                ok ? HapticManager.shared.success() : HapticManager.shared.error()
                            }
                        } label: {
                            Image(systemName: "checkmark").font(.system(.footnote, weight: .bold))
                                .foregroundStyle(AppTheme.onVividFill)
                                .frame(width: 34, height: 34).background(AppTheme.accentFill, in: Circle())
                        }
                        .accessibilityLabel(loc("a11y.accept_invite")).buttonStyle(ScaleButtonStyle())
                    }
                }
            }
        }
        .padding(12)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }
}

// MARK: - Card

struct SharedGoalCard: View {
    let goal: SharedGoal
    @State private var showInvite = false
    @State private var showDetail = false

    private var accountName: String? {
        goal.jointAccountId.flatMap { JointAccountService.shared.account($0) }.map { "\($0.emoji) \($0.name)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.sm).fill(AppTheme.cardMid.opacity(0.7)).frame(width: 48, height: 48)
                    Text(goal.emoji).font(.system(.title2))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(goal.title).font(.system(.body, weight: .bold)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                        // Kept in a Rekening Bersama: its name says whose goal it is.
                        Text(accountName ?? loc("unity.badge")).font(.system(.caption2, weight: .bold)).foregroundStyle(AppTheme.blue)
                            .lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AppTheme.blue.opacity(0.14), in: Capsule())
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill").font(.system(.caption2)).imageScale(.small).foregroundStyle(AppTheme.textSecondary)
                        Text(String(format: loc("unity.members"), goal.memberCount, goal.maxMembers))
                            .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                        if goal.isOwner {
                            Text("· \(loc("unity.you_owner"))").font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }
                Spacer()
            }

            // Collective progress
            // Same figures-then-bar layout as a personal goal card.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(CurrencyManager.shared.formatted(goal.savedAmount, currency: goal.currency))
                        .font(.system(.title2, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(String(format: loc("savings.of_target"),
                                CurrencyManager.shared.formatted(goal.targetAmount, currency: goal.currency)))
                        .font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Text("\(Int((goal.progress * 100).rounded()))%")
                        .font(.system(.footnote, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                }
                SavingsProgressBar(progress: goal.progress)
            }

            // Owner can invite members until the goal is full. A goal kept in
            // a Rekening Bersama takes its members from the account instead.
            if goal.isOwner && !goal.isFull && !goal.isKeptInAccount {
                Button {
                    HapticManager.shared.tap(); showInvite = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.badge.plus").font(.system(.footnote, weight: .semibold))
                        Text(loc("unity.invite")).font(.system(.footnote, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(AppTheme.cardMid.opacity(0.7), in: RoundedRectangle(cornerRadius: AppRadius.md))
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.xl))
        .contentShape(Rectangle())
        .onTapGesture { HapticManager.shared.tap(); showDetail = true }
        .sheet(isPresented: $showInvite) {
            InviteSheet(goal: goal)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
        .sheet(isPresented: $showDetail) {
            SharedGoalDetailView(goal: goal)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bg)
        }
    }
}

// MARK: - Detail (F4 breakdown + F5 controls)

struct SharedGoalDetailView: View {
    let goal: SharedGoal
    @Environment(\.dismiss) private var dismiss
    @State private var joint = JointAccountService.shared
    /// The Rekening Bersama the goal is kept in, when it is loaded.
    private var account: JointAccount? { goal.jointAccountId.flatMap { joint.account($0) } }
    @State private var unity = UnitySavingsService.shared
    @State private var members: [SharedMember] = []
    @State private var contributions: [SharedContribution] = []
    @State private var showAdd = false
    @State private var confirmDelete = false
    @State private var confirmLeave = false
    @State private var memberToRemove: SharedMember? = nil

    private func money(_ v: Double) -> String { CurrencyManager.shared.formatted(v, currency: goal.currency) }

    var body: some View {
        NavigationStack {
            ZStack { AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        // Hero
                        VStack(spacing: 8) {
                            Text(goal.emoji).font(.system(size: 40))
                            Text(goal.title).font(.system(.body, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                            Text(account.map { String(format: loc("unity.kept_in"), "\($0.emoji) \($0.name)") }
                                 ?? String(format: loc("unity.members"), goal.memberCount, goal.maxMembers))
                                .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(AppTheme.cardMid).frame(height: 9)
                                    Capsule().fill(LinearGradient(colors: [AppTheme.purple, AppTheme.blue], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: g.size.width * goal.progress, height: 9)
                                }
                            }.frame(height: 9).padding(.top, 4)
                            HStack {
                                Text(money(goal.savedAmount)).font(.system(.callout, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                Text("/ \(money(goal.targetAmount))").font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                                Spacer()
                                Text("\(Int(goal.progress * 100))%").font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.purple)
                            }
                        }
                        .padding(18)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        .padding(.horizontal, 22).padding(.top, 8)

                        // Add contribution (any active member)
                        Button { HapticManager.shared.tap(); showAdd = true } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill").font(.system(.callout))
                                Text(loc("unity.add_savings")).font(.system(.subheadline, weight: .bold))
                            }
                            .foregroundStyle(AppTheme.onVividFill).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(AppTheme.purple, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        }.buttonStyle(ScaleButtonStyle()).padding(.horizontal, 22)

                        // Members breakdown
                        section(loc("unity.members_title")) {
                            ForEach(members) { m in
                                HStack(spacing: 10) {
                                    Circle().fill(AppTheme.purple.opacity(0.15)).frame(width: 30, height: 30)
                                        .overlay(Text(String(m.displayName.prefix(1)).uppercased()).font(.system(.caption, weight: .bold)).foregroundStyle(AppTheme.purple))
                                    Text(m.displayName).font(.system(.footnote, weight: .medium)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                                    if m.isOwner { Text(loc("unity.role_owner")).font(.system(.caption2, weight: .bold)).foregroundStyle(AppTheme.purple).padding(.horizontal, 5).padding(.vertical, 1).background(AppTheme.purple.opacity(0.15), in: Capsule()) }
                                    Spacer()
                                    Text(money(m.contributedAmount)).font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                                    // Members of an account's goal come and go with the account.
                                    if goal.isOwner && !m.isOwner && !goal.isKeptInAccount {
                                        Button { memberToRemove = m } label: {
                                            Image(systemName: "minus.circle").font(.system(.subheadline)).foregroundStyle(AppTheme.red)
                                        }
.accessibilityLabel(loc("a11y.remove_member")).buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        // Contributions history
                        if !contributions.isEmpty {
                            section(loc("unity.history")) {
                                ForEach(contributions) { c in
                                    HStack(spacing: 10) {
                                        Image(systemName: "arrow.down.circle.fill").font(.system(.subheadline)).foregroundStyle(AppTheme.accent)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(c.displayName).font(.system(.caption, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                                            Text(c.date.formatted(date: .abbreviated, time: .shortened)).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                        }
                                        Spacer()
                                        Text("+\(money(c.amount))").font(.system(.footnote, weight: .bold)).foregroundStyle(AppTheme.accent)
                                    }
                                }
                            }
                        }

                        // Danger zone. Leaving an account's goal is leaving the
                        // account: staying in one, you would be back in it.
                        if goal.isOwner {
                            dangerButton(loc("unity.delete_goal")) { confirmDelete = true }
                        } else if !goal.isKeptInAccount {
                            dangerButton(loc("unity.leave_goal")) { confirmLeave = true }
                        }

                        Spacer(minLength: 24)
                    }
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("unity.title")).navigationBarTitleDisplayMode(.inline)
            .doneToolbar { dismiss() }
            .task {
                // Its account's balance is where money for it comes from first.
                if goal.isKeptInAccount { joint.start() }
                await load()
            }
            .sheet(isPresented: $showAdd) {
                AddContributionSheet(goal: goal, account: account) { await load() }
                    .presentationDetents([.large]).presentationDragIndicator(.visible).presentationBackground(AppTheme.bg)
            }
            // Centered alerts (not action-sheet popovers) for destructive confirms.
            .confirmSheet(isPresented: $confirmDelete,
                          title: loc("unity.delete_goal"),
                          message: loc("unity.delete_goal_confirm"),
                          confirmLabel: loc("common.delete")) {
                Task { if await unity.deleteGoal(goal) { dismiss() } }
            }
            .confirmSheet(isPresented: $confirmLeave,
                          icon: "rectangle.portrait.and.arrow.right",
                          tone: .warning,
                          title: loc("unity.leave_goal"),
                          message: loc("unity.leave_goal_confirm"),
                          confirmLabel: loc("unity.leave_goal")) {
                Task { if await unity.leaveGoal(goal) { dismiss() } }
            }
            .confirmSheet(item: $memberToRemove,
                          icon: "person.fill.xmark",
                          title: { _ in loc("unity.remove_member") },
                          message: { String(format: loc("unity.remove_confirm"), $0.displayName) },
                          confirmLabel: loc("unity.remove_member")) { m in
                Task { _ = await unity.removeMember(goal, memberUid: m.id); await load() }
            }
        }
    }

    private func load() async {
        await unity.syncMyMemberName(goalId: goal.id)   // heal old "Member" rows
        members = await unity.fetchMembers(goalId: goal.id)
        contributions = await unity.fetchContributions(goalId: goal.id)
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
            VStack(spacing: 12) { content() }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }.padding(.horizontal, 22)
    }

    private func dangerButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button { HapticManager.shared.tap(); action() } label: {
            Text(title).font(.system(.subheadline, weight: .semibold)).foregroundStyle(AppTheme.red)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(AppTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.sm))
        }.buttonStyle(ScaleButtonStyle()).padding(.horizontal, 22)
    }
}

// MARK: - Add contribution sheet

struct AddContributionSheet: View {
    let goal: SharedGoal
    /// The Rekening Bersama the goal is kept in: its balance is the first
    /// place the money can come from.
    var account: JointAccount? = nil
    let onDone: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \BankCard.sortOrder) private var cards: [BankCard]
    @State private var unity = UnitySavingsService.shared
    @State private var amountText = ""
    @State private var note = ""
    @State private var saving = false
    @State private var sourceCardID: UUID? = nil
    /// From the shared balance, when the goal is kept in an account.
    @State private var fromAccount = true

    private var amount: Double { NumberInput.amount(amountText) }
    private var usesAccount: Bool { account != nil && fromAccount }
    private var amountMinor: Int64 { JointMoney.toMinor(amount, currency: goal.currency) }
    /// Contributing to a shared goal moves the user's OWN money out of their
    /// OWN account — it must leave the same transaction trail as any other
    /// outflow, otherwise the spending record (and every analysis built on it)
    /// has a hole.
    private var fundingCards: [BankCard] { cards.filter { !$0.isCreditCard } }
    private var selectedCard: BankCard? {
        if let id = sourceCardID, let c = fundingCards.first(where: { $0.id == id }) { return c }
        return fundingCards.first
    }
    private var canSave: Bool {
        guard amount > 0, !saving else { return false }
        if usesAccount, let account, let me = Auth.auth().currentUser?.uid {
            return JointGoals.canMove(amountMinor, to: goal, from: account, as: me)
        }
        return selectedCard != nil
    }

    /// Book the contribution locally. The shared goal itself lives in
    /// Firestore, but the cash left a local account, so DiPo records it the
    /// same way it records a personal goal deposit.
    private func recordLocalTransaction() {
        guard let card = selectedCard else { return }
        let cm = CurrencyManager.shared
        let debited = cm.convert(amount, from: goal.currency, to: card.resolvedCurrency)
        card.transactions.append(TxRecord(
            name: String(format: loc("savings.tx_name"), goal.title),
            date: .now, amount: -debited, type: "tx.type.purchase",
            icon: goal.emoji, iconBgHex: TxCategory.investment.iconBg,
            category: .investment, currency: card.resolvedCurrency,
            notes: "tx.note.goal_deposit"))
        do {
            try context.save()
        } catch {
            // The contribution is already in Firestore at this point, so a
            // failed local save means the two diverge: the shared goal shows
            // the money, this device's spending record does not. Swallowing it
            // with `try?` made that invisible — surface it so the user can
            // re-add the expense by hand.
            print("[DiPo][unity] ✗ local contribution tx not saved: \(error.localizedDescription)")
            NotificationManager.shared.post(AppNotificationItem(
                icon: "exclamationmark.triangle.fill", iconColorHex: "#E5484D",
                title: loc("unity.local_save_failed_title"),
                body: String(format: loc("unity.local_save_failed_body"), goal.title),
                time: loc("notif.time.now"), isUrgent: true), pushToDevice: false)
        }
    }

    /// The shared balance before and after, and what it means: saved, not
    /// spent, and not undone.
    private func accountFlow(_ account: JointAccount) -> some View {
        let after = account.balance - max(amountMinor, 0)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(account.emoji) \(account.name)").font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                    Text(JointMoney.text(account.balance, currency: account.currency))
                        .font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                }
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(AppTheme.textSecondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(loc("unity.balance_after")).font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                    Text((after < 0 ? "−" : "") + JointMoney.text(after, currency: account.currency))
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(after < 0 ? AppTheme.red : AppTheme.textPrimary)
                }
            }
            .padding(14)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
            Text(String(format: loc("unity.move_note"), account.name))
                .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
    }

    var body: some View {
        NavigationStack {
            ZStack { AppTheme.bg.ignoresSafeArea()
                VStack(spacing: 18) {
                    Text(goal.emoji).font(.system(.largeTitle)).padding(.top, 12)
                    HStack(spacing: 10) {
                        Text(goal.currency).font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.purple)
                            .padding(.horizontal, 14).padding(.vertical, 14)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                        TextField("0", text: $amountText).keyboardType(.decimalPad)
                            .font(.system(.title2, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                    }.padding(.horizontal, 22)
                    if !usesAccount {
                        TextField(loc("unity.note_ph"), text: $note)
                            .font(.system(.subheadline)).padding(.horizontal, 16).padding(.vertical, 12)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md)).padding(.horizontal, 22)
                    }

                    if let account {
                        Picker(loc("savings.source_account"), selection: $fromAccount) {
                            Text("\(account.emoji) \(account.name)").tag(true)
                            Text(loc("unity.source_my_card")).tag(false)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 22)
                    }

                    if usesAccount, let account {
                        accountFlow(account)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(loc("savings.source_account"))
                                .font(.system(.footnote, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
                            if fundingCards.isEmpty {
                                Text(loc("savings.reconcile_no_account"))
                                    .font(.system(.caption2, weight: .medium)).foregroundStyle(AppTheme.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                CardChipPicker(cards: fundingCards,
                                               isSelected: { selectedCard?.id == $0.id },
                                               onSelect: { sourceCardID = $0.id })
                                    .padding(.horizontal, -22)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                    }
                    Button {
                        saving = true
                        Task {
                            let ok: Bool
                            if usesAccount, let account {
                                // Recorded in the account, not on my cards: the money
                                // was the account's.
                                ok = await JointAccountService.shared.moveToGoal(goal, from: account, amount: amountMinor)
                            } else {
                                ok = await unity.addContribution(goal: goal, amount: amount,
                                                                 note: note.trimmingCharacters(in: .whitespaces))
                                if ok { recordLocalTransaction() }
                            }
                            saving = false
                            if ok {
                                HapticManager.shared.success(); await onDone(); dismiss()
                            } else { HapticManager.shared.error() }
                        }
                    } label: {
                        Text(loc("unity.add_savings")).font(.system(.callout, weight: .bold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(canSave ? AppTheme.purple : AppTheme.textSecondary.opacity(0.3), in: RoundedRectangle(cornerRadius: AppRadius.md))
                    }.buttonStyle(ScaleButtonStyle()).disabled(!canSave).padding(.horizontal, 22)
                    Spacer()
                }
            }
            .navigationTitle(loc("unity.add_savings")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary) } }
        }
    }
}

// MARK: - Invite sheet

struct InviteSheet: View {
    let goal: SharedGoal
    @Environment(\.dismiss) private var dismiss
    @State private var unity = UnitySavingsService.shared
    @State private var dipoID = ""
    @State private var sending = false
    @State private var result: (text: String, color: Color)? = nil

    var body: some View {
        NavigationStack {
            ZStack { AppTheme.bg.ignoresSafeArea()
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Text(goal.emoji).font(.system(.largeTitle))
                        Text(goal.title).font(.system(.callout, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                        Text(String(format: loc("unity.members"), goal.memberCount, goal.maxMembers))
                            .font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                    }.padding(.top, 12)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(loc("unity.invite_title")).font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                        TextField(loc("unity.dipo_id_ph"), text: $dipoID)
                            .font(.system(.body, design: .monospaced, weight: .bold))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(AppTheme.purple.opacity(0.3), lineWidth: 1))
                        Text(loc("unity.invite_hint")).font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.horizontal, 22)

                    if let r = result {
                        Text(r.text).font(.system(.footnote, weight: .semibold)).foregroundStyle(r.color)
                            .multilineTextAlignment(.center).padding(.horizontal, 22)
                            .transition(.opacity)
                    }

                    Button { send() } label: {
                        HStack(spacing: 8) {
                            if sending { ProgressView().tint(.white) }
                            Text(loc("unity.invite_send")).font(.system(.callout, weight: .bold))
                        }
                        .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(canSend ? AppTheme.purple : AppTheme.textSecondary.opacity(0.3), in: RoundedRectangle(cornerRadius: AppRadius.md))
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .disabled(!canSend)
                    .padding(.horizontal, 22)

                    Spacer()
                }
            }
            .navigationTitle(loc("unity.invite")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
    }

    private var canSend: Bool { dipoID.trimmingCharacters(in: .whitespaces).count >= 6 && !sending }

    private func send() {
        guard canSend else { return }
        sending = true
        withAnimation { result = nil }
        Task {
            let r = await unity.invite(goal: goal, toDipoID: dipoID)
            sending = false
            let (text, color, ok): (String, Color, Bool) = {
                switch r {
                case .success:        return (loc("unity.invite.success"), AppTheme.accent, true)
                case .notFound:       return (loc("unity.invite.not_found"), AppTheme.red, false)
                case .alreadyMember:  return (loc("unity.invite.already_member"), AppTheme.orange, false)
                case .alreadyInvited: return (loc("unity.invite.already_invited"), AppTheme.orange, false)
                case .full:           return (loc("unity.invite.full"), AppTheme.orange, false)
                case .cantInviteSelf: return (loc("unity.invite.self"), AppTheme.orange, false)
                case .error:          return (loc("unity.invite.error"), AppTheme.red, false)
                }
            }()
            withAnimation { result = (text, color) }
            if ok {
                HapticManager.shared.success()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
            } else {
                HapticManager.shared.error()
            }
        }
    }
}

// MARK: - Create form

struct SharedGoalFormSheet: View {
    /// Made from a Rekening Bersama: kept in it, for its members, in its currency.
    var account: JointAccount? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var unity = UnitySavingsService.shared

    @State private var emoji = "🎯"
    @State private var title = ""
    @State private var amountText = ""
    @State private var currency = CurrencyManager.shared.preferredCurrency
    @State private var hasDeadline = false
    @State private var deadline = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now
    @State private var saving = false

    private let emojiChoices = ["🎯", "✈️", "🏠", "🎁", "💍", "🚗", "🕋", "🎓", "💻", "🏖️", "👶", "🎂"]
    private var amount: Double { NumberInput.amount(amountText) }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && amount > 0 && !saving }

    var body: some View {
        NavigationStack {
            ZStack { AppTheme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        // Emoji picker
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(emojiChoices, id: \.self) { e in
                                    Text(e).font(.system(.title2))
                                        .frame(width: 46, height: 46)
                                        .background(emoji == e ? AppTheme.purple.opacity(0.18) : AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                                        .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).stroke(emoji == e ? AppTheme.purple : Color.clear, lineWidth: 2))
                                        .onTapGesture { HapticManager.shared.tap(); emoji = e }
                                }
                            }.padding(.horizontal, 22)
                        }.padding(.top, 8)

                        field(loc("unity.goal_name"), placeholder: loc("unity.goal_name_ph"), text: $title)

                        // Amount + currency
                        VStack(alignment: .leading, spacing: 8) {
                            Text(loc("unity.target")).font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            HStack(spacing: 10) {
                                Button {
                                    HapticManager.shared.tap()
                                    let p = CurrencyManager.shared.preferredCurrency
                                    currency = currency == p ? "USD" : p
                                } label: {
                                    Text(currency).font(.system(.subheadline, weight: .bold)).foregroundStyle(AppTheme.purple)
                                        .padding(.horizontal, 14).padding(.vertical, 14)
                                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.sm))
                                        .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).stroke(AppTheme.purple.opacity(0.3), lineWidth: 1))
                                }.buttonStyle(ScaleButtonStyle())
                                // An account's goal saves in the account's currency.
                                .disabled(account != nil)
                                TextField("0", text: $amountText)
                                    .keyboardType(.decimalPad)
                                    .font(.system(.title2, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                            }.padding(.horizontal, 22)
                        }

                        // Deadline (optional) — styled toggle row + a clean
                        // graphical calendar (the default compact pill looked
                        // cramped/out of place).
                        VStack(spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: "calendar").font(.system(.subheadline)).foregroundStyle(AppTheme.purple)
                                Text(loc("unity.deadline")).font(.system(.subheadline, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                DiPoSwitch(isOn: $hasDeadline.animation(.spring(response: 0.3)),
                                           onIcon: "calendar", offIcon: "infinity",
                                           tint: AppTheme.purple)
                            }
                            .padding(14)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                            .padding(.horizontal, 22)

                            if hasDeadline {
                                DatePicker("", selection: $deadline, in: Date()..., displayedComponents: .date)
                                    .datePickerStyle(.graphical)
                                    .tint(AppTheme.purple)
                                    .padding(8)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                                    .padding(.horizontal, 22)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }

                        // Info: Royal + members
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle").font(.system(.caption)).foregroundStyle(AppTheme.textSecondary)
                            Text(account.map { String(format: loc("unity.create_note_account"), "\($0.emoji) \($0.name)") }
                                 ?? String(format: loc("unity.create_note"), UnitySavingsService.maxMembers))
                                .font(.system(.caption2)).foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 22)

                        Spacer(minLength: 30)
                    }
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(loc("unity.new_title")).navigationBarTitleDisplayMode(.inline)
            .onAppear { if let account { currency = account.currency } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(loc("unity.create_short")) { save() }
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(canSave ? AppTheme.purple : AppTheme.textSecondary.opacity(0.4))
                        .disabled(!canSave)
                }
            }
        }
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(.footnote)).foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
            TextField(placeholder, text: text)
                .font(.system(.subheadline)).foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .padding(.horizontal, 22)
        }
    }

    private func save() {
        guard canSave else { return }
        saving = true
        let t = title.trimmingCharacters(in: .whitespaces)
        Task {
            let ok = await unity.createGoal(
                title: t, emoji: emoji, targetAmount: amount,
                currency: account?.currency ?? currency, targetDate: hasDeadline ? deadline : nil,
                in: account)
            saving = false
            if ok { HapticManager.shared.success(); dismiss() }
            else  { HapticManager.shared.error() }
        }
    }
}
