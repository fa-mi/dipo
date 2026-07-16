import SwiftUI
import FirebaseFirestore
import FirebaseAuth

// MARK: - Unity Savings (Tabungan Bersama) — F1
//
// Collaborative savings goals shared across DiPo users. Unlike solo goals
// (SwiftData, per-device), shared goals live in Firestore so multiple members
// can see the same goal and contribute. This file covers F1: the model, the
// Firestore service (create + live list), and the create UI. Inviting members
// (F2/F3) and contributions (F4) come next.
//
// Gating: this whole screen sits behind PremiumGate(.savingsGoals) which is
// Royal-only, so every user who reaches it is already Royal.

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
    }
}

struct SharedInvite: Identifiable {
    let id: String
    var goalId: String
    var goalTitle: String
    var goalEmoji: String
    var fromUid: String
    var fromName: String
    var status: String
    var createdAt: Date

    init?(id: String, data: [String: Any]) {
        guard let goalId = data["goalId"] as? String else { return nil }
        self.id = id
        self.goalId = goalId
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

    /// Accept an invite: join the goal (add self to memberUids atomically) +
    /// create your member record + mark the invite accepted. Hard-gated on Royal.
    @discardableResult
    func acceptInvite(_ invite: SharedInvite) async -> Bool {
        guard let uid = Auth.auth().currentUser?.uid else {
            print("[Unity][accept] ✗ blocked: no auth uid")
            return false
        }
        guard PremiumManager.shared.plan == .royal else {
            print("[Unity][accept] ✗ blocked: not Royal (plan=\(PremiumManager.shared.plan))")
            return false
        }
        var step = "join-transaction (read+update goal)"
        print("[Unity][accept] → goal=\(invite.goalId) uid=\(uid)")
        let goalRef = db.collection("sharedGoals").document(invite.goalId)
        do {
            _ = try await db.runTransaction { txn, errPtr -> Any? in
                let snap: DocumentSnapshot
                do { snap = try txn.getDocument(goalRef) }
                catch let e as NSError {
                    // Most likely PERMISSION_DENIED: the sharedGoals read rule
                    // requires membership, but the joiner isn't a member yet.
                    print("[Unity][accept] ✗ txn READ denied: \(e.domain) code=\(e.code): \(e.localizedDescription)")
                    errPtr?.pointee = e; return nil
                }
                guard let data = snap.data() else { return nil }
                var members = data["memberUids"] as? [String] ?? []
                let maxM = data["maxMembers"] as? Int ?? Self.maxMembers
                if members.contains(uid) { return nil } // already joined
                if members.count >= maxM {
                    print("[Unity][accept] ✗ goal full \(members.count)/\(maxM)")
                    errPtr?.pointee = NSError(domain: "Unity", code: 1, userInfo: [NSLocalizedDescriptionKey: "full"])
                    return nil
                }
                members.append(uid)
                txn.updateData(["memberUids": members, "memberCount": members.count], forDocument: goalRef)
                return nil
            }
            print("[Unity][accept] ✓ joined memberUids")

            step = "write-member-doc"
            let myName = await myDisplayName(uid: uid, fallback: "Member")
            try await goalRef.collection("members").document(uid).setData([
                "role":        "member",
                "status":      "active",
                "displayName": myName,
                "contributedAmount": 0,
                "joinedAt":    FieldValue.serverTimestamp(),
            ], merge: true)

            step = "mark-invite-accepted"
            try await db.collection("invitations").document(invite.id).setData([
                "status": "accepted", "respondedAt": FieldValue.serverTimestamp(),
            ], merge: true)
            print("[Unity][accept] ✓ SUCCESS — joined goal")
            return true
        } catch {
            let ns = error as NSError
            print("[Unity][accept] ✗ THREW at step='\(step)' — \(ns.domain) code=\(ns.code): \(ns.localizedDescription)")
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
        do {
            try await goalRef.collection("contributions").document().setData([
                "uid": uid, "displayName": name, "amount": amount,
                "currency": goal.currency, "note": note,
                "date": FieldValue.serverTimestamp(),
            ])
            try await goalRef.updateData(["savedAmount": FieldValue.increment(amount)])
            try await goalRef.collection("members").document(uid).setData([
                "contributedAmount": FieldValue.increment(amount),
            ], merge: true)
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
        let live = (UserSession.shared.displayName ?? "").trimmingCharacters(in: .whitespaces)
        if !live.isEmpty { return live }
        let snap = try? await db.collection("users").document(uid).getDocument()
        let profile = (snap?.data()?["displayName"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return profile.isEmpty ? fallback : profile
    }

    private func notifyInvite(inviteId: String) async {
        guard let url = URL(string: notifyURL) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["inviteId": inviteId])
        // Short timeout: this is a best-effort push. It must never make the
        // "Send invite" button spin — the default 60s timeout previously kept
        // the UI in a loading state when the worker was slow/unreachable.
        req.timeoutInterval = 8
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Invite (F2)

    enum InviteResult { case success, notFound, notRoyal, alreadyMember, alreadyInvited, full, cantInviteSelf, error }

    /// Resolve a typed DiPo ID → user, validate, and write a pending invitation.
    /// The write itself is guarded by Firestore rules (only the goal owner may
    /// create invites for their goal). Royal + membership checks are done here
    /// for good UX; accept-time re-checks (F3) are the hard gate.
    func invite(goal: SharedGoal, toDipoID rawID: String) async -> InviteResult {
        let dipoID = rawID.uppercased().trimmingCharacters(in: .whitespaces)
        guard let fromUid = Auth.auth().currentUser?.uid, !dipoID.isEmpty else {
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

            // 2. Invitee must be Royal (all participants are Royal).
            step = "read-user-plan"
            let userSnap = try await db.collection("users").document(toUid).getDocument()
            let plan = userSnap.data()?["plan"] as? String ?? "free"
            print("[Unity][invite] ✓ plan check: users/\(toUid).plan='\(plan)'")
            if plan != "royal" {
                print("[Unity][invite] ✗ step=\(step): invitee is not Royal")
                return .notRoyal
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

            // 4. No duplicate pending invite. Query by a SINGLE field (fromUid)
            //    — a single-field index is automatic, so no manual composite
            //    index is needed — then match the rest client-side.
            step = "query-existing-invites"
            let mine = try await db.collection("invitations")
                .whereField("fromUid", isEqualTo: fromUid)
                .getDocuments()
            let dup = mine.documents.contains {
                ($0.data()["toUid"] as? String) == toUid &&
                ($0.data()["goalId"] as? String) == goal.id &&
                ($0.data()["status"] as? String) == "pending"
            }
            if dup {
                print("[Unity][invite] ✗ step=\(step): duplicate pending invite exists")
                return .alreadyInvited
            }

            // 5. Resolve the SENDER's display name so the invite (and its push)
            //    shows who it's really from — the recipient needs this to judge
            //    whether the invite is from someone they trust. Prefer the live
            //    session name; if it isn't loaded yet, fall back to the
            //    authoritative profile doc (users/{fromUid}.displayName) rather
            //    than a generic "Someone".
            step = "resolve-sender-name"
            var fromName = (UserSession.shared.displayName ?? "").trimmingCharacters(in: .whitespaces)
            if fromName.isEmpty {
                let meSnap = try? await db.collection("users").document(fromUid).getDocument()
                fromName = (meSnap?.data()?["displayName"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            }
            if fromName.isEmpty { fromName = "Someone" }
            print("[Unity][invite] sender name resolved → '\(fromName)'")

            // 6. Create the invitation, then fire a best-effort push.
            step = "write-invitation"
            let ref = db.collection("invitations").document()
            try await ref.setData([
                "goalId":     goal.id,
                "goalTitle":  goal.title,
                "goalEmoji":  goal.emoji,
                "fromUid":    fromUid,
                "fromName":   fromName,
                "toUid":      toUid,
                "toSocialId": idx["socialUserID"] as? String ?? "",
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

    /// Create a shared goal owned by the current user (sole member to start).
    @discardableResult
    func createGoal(title: String, emoji: String, targetAmount: Double,
                    currency: String, targetDate: Date?) async -> Bool {
        guard let uid = Auth.auth().currentUser?.uid else { return false }
        let ownerName = await myDisplayName(uid: uid, fallback: "Me")
        let ref = db.collection("sharedGoals").document()
        var data: [String: Any] = [
            "ownerUid":    uid,
            "ownerName":   ownerName,
            "title":       title,
            "emoji":       emoji,
            "targetAmount": targetAmount,
            "currency":    currency,
            "savedAmount": 0,
            "memberUids":  [uid],
            "memberCount": 1,
            "maxMembers":  Self.maxMembers,
            "status":      "active",
            "createdAt":   FieldValue.serverTimestamp(),
        ]
        if let d = targetDate { data["targetDate"] = Timestamp(date: d) }
        do {
            try await ref.setData(data)
            // Owner's member record.
            try await ref.collection("members").document(uid).setData([
                "role":        "owner",
                "status":      "active",
                "displayName": ownerName,
                "contributedAmount": 0,
                "joinedAt":    FieldValue.serverTimestamp(),
            ])
            return true
        } catch {
            print("[Unity] createGoal error: \(error)")
            return false
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
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.purple)
                    .padding(.horizontal, 22)
                ForEach(unity.pendingInvites) { invite in
                    InviteInboxRow(invite: invite)
                        .padding(.horizontal, 22)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 12)).foregroundStyle(AppTheme.purple)
                Text(loc("unity.title"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 22)

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
                        SeeAllLabel(count: unity.goals.count, tint: AppTheme.purple)
                    }
                    .padding(.horizontal, 22)
                }
            }
        }
        .onAppear { unity.start(); unity.startInvites() }
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
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
        }
        .padding(.vertical, 14).padding(.horizontal, 16)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.2), lineWidth: 1))
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
            }
        }
        .navigationTitle(loc("unity.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { unity.start() }
    }
}

// MARK: - Goal type chooser (New Goal page)

enum GoalSheet: Int, Identifiable { case chooser, personal, shared; var id: Int { rawValue } }

struct GoalTypeChooserView: View {
    let onPersonal: () -> Void
    let onShared: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack { AppTheme.bg.ignoresSafeArea()
                VStack(spacing: 14) {
                    Text(loc("goal.chooser_sub"))
                        .font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.top, 8)

                    optionCard(icon: "star.fill", tint: AppTheme.accent,
                               title: loc("savings.personal_goal"),
                               subtitle: loc("goal.chooser_personal_sub"),
                               action: onPersonal)
                    optionCard(icon: "person.2.fill", tint: AppTheme.purple,
                               title: loc("unity.title"),
                               subtitle: loc("goal.chooser_shared_sub"),
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

    private func optionCard(icon: String, tint: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button { HapticManager.shared.tap(); action() } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(tint.opacity(0.15)).frame(width: 52, height: 52)
                    Image(systemName: icon).font(.system(size: 22)).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
            }
            .padding(16)
            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(tint.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(ScaleButtonStyle())
        .padding(.horizontal, 22)
    }
}

private struct UnityEmptyCard: View {
    let onCreate: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Text("🤝").font(.system(size: 30))
            Text(loc("unity.empty")).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary)
            Text(loc("unity.empty_sub")).font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                HapticManager.shared.tap(); onCreate()
            } label: {
                Text(loc("unity.create")).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(AppTheme.purple, in: Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(AppTheme.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.purple.opacity(0.18), lineWidth: 1))
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
                RoundedRectangle(cornerRadius: 12).fill(AppTheme.purple.opacity(0.15)).frame(width: 42, height: 42)
                Text(invite.goalEmoji).font(.system(size: 20))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.goalTitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                Text(String(format: loc("unity.invited_by"), invite.fromName))
                    .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if busy {
                ProgressView().tint(AppTheme.purple)
            } else {
                HStack(spacing: 8) {
                    Button {
                        busy = true
                        Task { await unity.declineInvite(invite); busy = false; HapticManager.shared.tap() }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 34, height: 34).background(AppTheme.cardMid, in: Circle())
                    }.buttonStyle(ScaleButtonStyle())
                    Button {
                        busy = true
                        Task {
                            let ok = await unity.acceptInvite(invite)
                            busy = false
                            ok ? HapticManager.shared.success() : HapticManager.shared.error()
                        }
                    } label: {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34).background(AppTheme.purple, in: Circle())
                    }.buttonStyle(ScaleButtonStyle())
                }
            }
        }
        .padding(12)
        .background(AppTheme.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.purple.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Card

struct SharedGoalCard: View {
    let goal: SharedGoal
    @State private var showInvite = false
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(AppTheme.purple.opacity(0.15)).frame(width: 44, height: 44)
                    Text(goal.emoji).font(.system(size: 22))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(goal.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                        Text(loc("unity.badge")).font(.system(size: 9, weight: .bold)).foregroundStyle(AppTheme.purple)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AppTheme.purple.opacity(0.15), in: Capsule())
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill").font(.system(size: 9)).foregroundStyle(AppTheme.textSecondary)
                        Text(String(format: loc("unity.members"), goal.memberCount, goal.maxMembers))
                            .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        if goal.isOwner {
                            Text("· \(loc("unity.you_owner"))").font(.system(size: 11)).foregroundStyle(AppTheme.purple)
                        }
                    }
                }
                Spacer()
            }

            // Collective progress
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.cardMid).frame(height: 7)
                    Capsule().fill(LinearGradient(colors: [AppTheme.purple, AppTheme.blue], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * goal.progress, height: 7)
                }
            }.frame(height: 7)

            HStack {
                Text(CurrencyManager.shared.formatted(goal.savedAmount, currency: goal.currency))
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                Text("/ \(CurrencyManager.shared.formatted(goal.targetAmount, currency: goal.currency))")
                    .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text("\(Int(goal.progress * 100))%").font(.system(size: 13, weight: .bold)).foregroundStyle(AppTheme.purple)
            }

            // Owner can invite members until the goal is full.
            if goal.isOwner && !goal.isFull {
                Button {
                    HapticManager.shared.tap(); showInvite = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.badge.plus").font(.system(size: 13, weight: .semibold))
                        Text(loc("unity.invite")).font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.purple)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(AppTheme.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(16)
        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.purple.opacity(0.18), lineWidth: 1))
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
                            Text(goal.title).font(.system(size: 18, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                            Text(String(format: loc("unity.members"), goal.memberCount, goal.maxMembers))
                                .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(AppTheme.cardMid).frame(height: 9)
                                    Capsule().fill(LinearGradient(colors: [AppTheme.purple, AppTheme.blue], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: g.size.width * goal.progress, height: 9)
                                }
                            }.frame(height: 9).padding(.top, 4)
                            HStack {
                                Text(money(goal.savedAmount)).font(.system(size: 16, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                Text("/ \(money(goal.targetAmount))").font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                Spacer()
                                Text("\(Int(goal.progress * 100))%").font(.system(size: 15, weight: .bold)).foregroundStyle(AppTheme.purple)
                            }
                        }
                        .padding(18)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 20))
                        .padding(.horizontal, 22).padding(.top, 8)

                        // Add contribution (any active member)
                        Button { HapticManager.shared.tap(); showAdd = true } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill").font(.system(size: 16))
                                Text(loc("unity.add_savings")).font(.system(size: 15, weight: .bold))
                            }
                            .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(AppTheme.purple, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(ScaleButtonStyle()).padding(.horizontal, 22)

                        // Members breakdown
                        section(loc("unity.members_title")) {
                            ForEach(members) { m in
                                HStack(spacing: 10) {
                                    Circle().fill(AppTheme.purple.opacity(0.15)).frame(width: 30, height: 30)
                                        .overlay(Text(String(m.displayName.prefix(1)).uppercased()).font(.system(size: 12, weight: .bold)).foregroundStyle(AppTheme.purple))
                                    Text(m.displayName).font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                                    if m.isOwner { Text(loc("unity.role_owner")).font(.system(size: 9, weight: .bold)).foregroundStyle(AppTheme.purple).padding(.horizontal, 5).padding(.vertical, 1).background(AppTheme.purple.opacity(0.15), in: Capsule()) }
                                    Spacer()
                                    Text(money(m.contributedAmount)).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
                                    if goal.isOwner && !m.isOwner {
                                        Button { memberToRemove = m } label: {
                                            Image(systemName: "minus.circle").font(.system(size: 15)).foregroundStyle(AppTheme.red)
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        // Contributions history
                        if !contributions.isEmpty {
                            section(loc("unity.history")) {
                                ForEach(contributions) { c in
                                    HStack(spacing: 10) {
                                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 14)).foregroundStyle(AppTheme.accent)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(c.displayName).font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                                            Text(c.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                                        }
                                        Spacer()
                                        Text("+\(money(c.amount))").font(.system(size: 13, weight: .bold)).foregroundStyle(AppTheme.accent)
                                    }
                                }
                            }
                        }

                        // Danger zone
                        if goal.isOwner {
                            dangerButton(loc("unity.delete_goal")) { confirmDelete = true }
                        } else {
                            dangerButton(loc("unity.leave_goal")) { confirmLeave = true }
                        }

                        Spacer(minLength: 24)
                    }
                }
            }
            .navigationTitle(loc("unity.title")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(loc("common.done")) { dismiss() }.foregroundStyle(AppTheme.purple) } }
            .task { await load() }
            .sheet(isPresented: $showAdd) {
                AddContributionSheet(goal: goal) { await load() }
                    .presentationDetents([.medium]).presentationDragIndicator(.visible).presentationBackground(AppTheme.bg)
            }
            // Centered alerts (not action-sheet popovers) for destructive confirms.
            .alert(loc("unity.delete_goal"), isPresented: $confirmDelete) {
                Button(loc("common.delete"), role: .destructive) { Task { if await unity.deleteGoal(goal) { dismiss() } } }
                Button(loc("common.cancel"), role: .cancel) {}
            } message: { Text(loc("unity.delete_goal_confirm")) }
            .alert(loc("unity.leave_goal"), isPresented: $confirmLeave) {
                Button(loc("unity.leave_goal"), role: .destructive) { Task { if await unity.leaveGoal(goal) { dismiss() } } }
                Button(loc("common.cancel"), role: .cancel) {}
            } message: { Text(loc("unity.leave_goal_confirm")) }
            .alert(loc("unity.remove_member"),
                   isPresented: Binding(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } })) {
                Button(loc("unity.remove_member"), role: .destructive) {
                    if let m = memberToRemove { Task { _ = await unity.removeMember(goal, memberUid: m.id); await load() } }
                }
                Button(loc("common.cancel"), role: .cancel) {}
            } message: { Text(memberToRemove.map { String(format: loc("unity.remove_confirm"), $0.displayName) } ?? "") }
        }
    }

    private func load() async {
        await unity.syncMyMemberName(goalId: goal.id)   // heal old "Member" rows
        members = await unity.fetchMembers(goalId: goal.id)
        contributions = await unity.fetchContributions(goalId: goal.id)
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.textSecondary)
            VStack(spacing: 12) { content() }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
        }.padding(.horizontal, 22)
    }

    private func dangerButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button { HapticManager.shared.tap(); action() } label: {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.red)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(AppTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(ScaleButtonStyle()).padding(.horizontal, 22)
    }
}

// MARK: - Add contribution sheet

struct AddContributionSheet: View {
    let goal: SharedGoal
    let onDone: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var unity = UnitySavingsService.shared
    @State private var amountText = ""
    @State private var note = ""
    @State private var saving = false

    private var amount: Double { Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var canSave: Bool { amount > 0 && !saving }

    var body: some View {
        NavigationStack {
            ZStack { AppTheme.bg.ignoresSafeArea()
                VStack(spacing: 18) {
                    Text(goal.emoji).font(.system(size: 34)).padding(.top, 12)
                    HStack(spacing: 10) {
                        Text(goal.currency).font(.system(size: 15, weight: .bold)).foregroundStyle(AppTheme.purple)
                            .padding(.horizontal, 14).padding(.vertical, 14)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
                        TextField("0", text: $amountText).keyboardType(.decimalPad)
                            .font(.system(size: 24, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                    }.padding(.horizontal, 22)
                    TextField(loc("unity.note_ph"), text: $note)
                        .font(.system(size: 14)).padding(.horizontal, 16).padding(.vertical, 12)
                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 22)
                    Button {
                        saving = true
                        Task {
                            let ok = await unity.addContribution(goal: goal, amount: amount, note: note.trimmingCharacters(in: .whitespaces))
                            saving = false
                            if ok { HapticManager.shared.success(); await onDone(); dismiss() } else { HapticManager.shared.error() }
                        }
                    } label: {
                        Text(loc("unity.add_savings")).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(canSave ? AppTheme.purple : AppTheme.textSecondary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
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
                        Text(goal.emoji).font(.system(size: 34))
                        Text(goal.title).font(.system(size: 16, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                        Text(String(format: loc("unity.members"), goal.memberCount, goal.maxMembers))
                            .font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                    }.padding(.top, 12)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(loc("unity.invite_title")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                        TextField(loc("unity.dipo_id_ph"), text: $dipoID)
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.purple.opacity(0.3), lineWidth: 1))
                        Text(loc("unity.invite_hint")).font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary.opacity(0.8))
                    }.padding(.horizontal, 22)

                    if let r = result {
                        Text(r.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(r.color)
                            .multilineTextAlignment(.center).padding(.horizontal, 22)
                            .transition(.opacity)
                    }

                    Button { send() } label: {
                        HStack(spacing: 8) {
                            if sending { ProgressView().tint(.white) }
                            Text(loc("unity.invite_send")).font(.system(size: 16, weight: .bold))
                        }
                        .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(canSend ? AppTheme.purple : AppTheme.textSecondary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
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
                case .notRoyal:       return (loc("unity.invite.not_royal"), AppTheme.orange, false)
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
    private var amount: Double { Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0 }
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
                                    Text(e).font(.system(size: 24))
                                        .frame(width: 46, height: 46)
                                        .background(emoji == e ? AppTheme.purple.opacity(0.18) : AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(emoji == e ? AppTheme.purple : Color.clear, lineWidth: 2))
                                        .onTapGesture { HapticManager.shared.tap(); emoji = e }
                                }
                            }.padding(.horizontal, 22)
                        }.padding(.top, 8)

                        field(loc("unity.goal_name"), placeholder: loc("unity.goal_name_ph"), text: $title)

                        // Amount + currency
                        VStack(alignment: .leading, spacing: 8) {
                            Text(loc("unity.target")).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
                            HStack(spacing: 10) {
                                Button {
                                    HapticManager.shared.tap()
                                    let p = CurrencyManager.shared.preferredCurrency
                                    currency = currency == p ? "USD" : p
                                } label: {
                                    Text(currency).font(.system(size: 15, weight: .bold)).foregroundStyle(AppTheme.purple)
                                        .padding(.horizontal, 14).padding(.vertical, 14)
                                        .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.purple.opacity(0.3), lineWidth: 1))
                                }.buttonStyle(ScaleButtonStyle())
                                TextField("0", text: $amountText)
                                    .keyboardType(.decimalPad)
                                    .font(.system(size: 22, weight: .bold)).foregroundStyle(AppTheme.textPrimary)
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                            }.padding(.horizontal, 22)
                        }

                        // Deadline (optional) — styled toggle row + a clean
                        // graphical calendar (the default compact pill looked
                        // cramped/out of place).
                        VStack(spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: "calendar").font(.system(size: 15)).foregroundStyle(AppTheme.purple)
                                Text(loc("unity.deadline")).font(.system(size: 14, weight: .medium)).foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                Toggle("", isOn: $hasDeadline.animation(.spring(response: 0.3))).labelsHidden().tint(AppTheme.purple)
                            }
                            .padding(14)
                            .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 22)

                            if hasDeadline {
                                DatePicker("", selection: $deadline, in: Date()..., displayedComponents: .date)
                                    .datePickerStyle(.graphical)
                                    .tint(AppTheme.purple)
                                    .padding(8)
                                    .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 16))
                                    .padding(.horizontal, 22)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }

                        // Info: Royal + members
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(AppTheme.textSecondary)
                            Text(String(format: loc("unity.create_note"), UnitySavingsService.maxMembers))
                                .font(.system(size: 11)).foregroundStyle(AppTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 22)

                        Spacer(minLength: 30)
                    }
                }
            }
            .navigationTitle(loc("unity.new_title")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("common.cancel")) { dismiss() }.foregroundStyle(AppTheme.textSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(loc("unity.create_short")) { save() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canSave ? AppTheme.purple : AppTheme.textSecondary.opacity(0.4))
                        .disabled(!canSave)
                }
            }
        }
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 13)).foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
            TextField(placeholder, text: text)
                .font(.system(size: 15)).foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(AppTheme.cardDark, in: RoundedRectangle(cornerRadius: 14))
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
                currency: currency, targetDate: hasDeadline ? deadline : nil)
            saving = false
            if ok { HapticManager.shared.success(); dismiss() }
            else  { HapticManager.shared.error() }
        }
    }
}
