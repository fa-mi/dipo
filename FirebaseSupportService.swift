import SwiftUI
import FirebaseFirestore
import FirebaseStorage

// MARK: - Models

struct SupportTicket: Identifiable, Codable {
    let id: String
    let userId: String
    let userName: String?
    let userEmail: String?
    let userPlan: String
    let category: String
    let subject: String
    let message: String
    let mediaURLs: [String]
    var status: String           // "open" | "answered" | "closed"
    var hasUnreadReply: Bool
    let createdAt: Date
    var updatedAt: Date
}

struct SupportReply: Identifiable, Codable {
    let id: String
    let message: String
    let isAdmin: Bool
    let createdAt: Date
    var isReadByUser: Bool
}

// MARK: - Firebase Support Service
//
// Firestore schema:
//   support_tickets/{ticketId}
//     userId, userName, userEmail, userPlan, category, subject, message,
//     mediaURLs: [String], status: "open"|"answered"|"closed",
//     hasUnreadReply: Bool, createdAt, updatedAt
//
//   support_tickets/{ticketId}/replies/{replyId}
//     message: String, isAdmin: Bool, createdAt, isReadByUser: Bool
//
// Admin workflow (no extra app needed):
//   Firebase Console → Firestore → support_tickets → [ticket doc]
//   → replies subcollection → Add document:
//     { message: "Your reply", isAdmin: true, isReadByUser: false, createdAt: <serverTimestamp> }
//   → Also update parent doc: { status: "answered", hasUnreadReply: true }
//
// The app listens for hasUnreadReply == true in real-time and fires
// an in-app notification automatically.

@Observable
final class FirebaseSupportService {
    static let shared = FirebaseSupportService()
    private init() {}

    private let db      = Firestore.firestore()
    private let storage = Storage.storage()

    var tickets: [SupportTicket] = []
    var isLoading = false
    var submitError: String?

    private var repliesListener: ListenerRegistration?

    // MARK: - Submit Ticket

    func submitTicket(
        category: String,
        subject: String,
        message: String,
        images: [UIImage]
    ) async throws -> String {
        let ticketId = UUID().uuidString
        let userId   = UserSession.shared.userID ?? "anonymous"

        var mediaURLs: [String] = []
        for (i, img) in images.enumerated() {
            if let url = try? await uploadImage(img, ticketId: ticketId, index: i) {
                mediaURLs.append(url)
            }
        }

        let data: [String: Any] = [
            "userId":         userId,
            "userName":       UserSession.shared.displayName as Any,
            "userEmail":      UserSession.shared.email as Any,
            "userPlan":       PremiumManager.shared.plan.label,
            "category":       category,
            "subject":        subject,
            "message":        message,
            "mediaURLs":      mediaURLs,
            "status":         "open",
            "hasUnreadReply": false,
            "createdAt":      FieldValue.serverTimestamp(),
            "updatedAt":      FieldValue.serverTimestamp()
        ]

        try await db.collection("support_tickets").document(ticketId).setData(data)
        return ticketId
    }

    // MARK: - Upload Image to Firebase Storage

    private func uploadImage(_ image: UIImage, ticketId: String, index: Int) async throws -> String {
        guard let data = image.jpegData(compressionQuality: 0.75) else {
            throw NSError(domain: "DiPo", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Image compression failed"])
        }
        let ref = storage.reference()
            .child("support/\(ticketId)/image_\(index).jpg")
        _ = try await ref.putDataAsync(data)
        return try await ref.downloadURL().absoluteString
    }

    // MARK: - Fetch Tickets for current user

    func fetchTickets() async {
        guard let userId = UserSession.shared.userID else { return }
        await MainActor.run { isLoading = true }
        do {
            let snap = try await db.collection("support_tickets")
                .whereField("userId", isEqualTo: userId)
                .order(by: "updatedAt", descending: true)
                .getDocuments()
            let decoded = snap.documents.compactMap { decodeTicket($0) }
            await MainActor.run { tickets = decoded }
        } catch {
            await MainActor.run { submitError = error.localizedDescription }
        }
        await MainActor.run { isLoading = false }
    }

    // MARK: - Fetch Replies for a ticket

    func fetchReplies(ticketId: String) async throws -> [SupportReply] {
        let snap = try await db.collection("support_tickets")
            .document(ticketId)
            .collection("replies")
            .order(by: "createdAt", descending: false)
            .getDocuments()
        return snap.documents.compactMap { decodeReply($0) }
    }

    // MARK: - Mark admin replies as read

    func markRepliesRead(ticketId: String) async {
        do {
            let snap = try await db.collection("support_tickets")
                .document(ticketId)
                .collection("replies")
                .whereField("isAdmin",       isEqualTo: true)
                .whereField("isReadByUser",  isEqualTo: false)
                .getDocuments()

            let batch = db.batch()
            for doc in snap.documents {
                batch.updateData(["isReadByUser": true], forDocument: doc.reference)
            }
            try await batch.commit()

            try await db.collection("support_tickets")
                .document(ticketId)
                .updateData(["hasUnreadReply": false])

            // Refresh local ticket list
            await fetchTickets()
        } catch {}
    }

    // MARK: - Real-time listener for admin replies
    //
    // Call once from RootView.onAppear (after Purchases.configure).
    // Fires whenever admin sets hasUnreadReply = true on any ticket.
    // Posts an in-app notification + schedules a local push.

    func startListeningForReplies() {
        guard let userId = UserSession.shared.userID else { return }
        repliesListener?.remove()

        repliesListener = db.collection("support_tickets")
            .whereField("userId",         isEqualTo: userId)
            .whereField("hasUnreadReply", isEqualTo: true)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self, let docs = snapshot?.documentChanges else { return }
                // Only react to newly-modified docs (not the initial load if already read)
                let changed = docs.filter { $0.type == .added || $0.type == .modified }
                for change in changed {
                    let doc      = change.document
                    let ticketId = doc.documentID
                    let subject  = doc.data()["subject"] as? String ?? "Support reply"
                    Task {
                        if let replies = try? await self.fetchReplies(ticketId: ticketId),
                           let latest  = replies.last(where: { $0.isAdmin && !$0.isReadByUser }) {
                            await MainActor.run {
                                NotificationManager.shared.postAdminReply(
                                    ticketId: ticketId,
                                    subject:  subject,
                                    message:  latest.message
                                )
                            }
                        }
                    }
                }
            }
    }

    func stopListening() {
        repliesListener?.remove()
        repliesListener = nil
    }

    // MARK: - Decoders

    private func decodeTicket(_ doc: QueryDocumentSnapshot) -> SupportTicket? {
        let d = doc.data()
        return SupportTicket(
            id:             doc.documentID,
            userId:         d["userId"]         as? String ?? "",
            userName:       d["userName"]        as? String,
            userEmail:      d["userEmail"]       as? String,
            userPlan:       d["userPlan"]        as? String ?? "Free",
            category:       d["category"]        as? String ?? "",
            subject:        d["subject"]         as? String ?? "",
            message:        d["message"]         as? String ?? "",
            mediaURLs:      d["mediaURLs"]       as? [String] ?? [],
            status:         d["status"]          as? String ?? "open",
            hasUnreadReply: d["hasUnreadReply"]  as? Bool ?? false,
            createdAt:      (d["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            updatedAt:      (d["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
        )
    }

    private func decodeReply(_ doc: QueryDocumentSnapshot) -> SupportReply? {
        let d = doc.data()
        return SupportReply(
            id:           doc.documentID,
            message:      d["message"]     as? String ?? "",
            isAdmin:      d["isAdmin"]     as? Bool   ?? false,
            createdAt:    (d["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            isReadByUser: d["isReadByUser"] as? Bool  ?? false
        )
    }
}

// MARK: - Helper: Identifiable String (for sheet binding)

struct IdentifiableString: Identifiable {
    let id   = UUID()
    let value: String
}
