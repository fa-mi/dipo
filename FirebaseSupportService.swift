import SwiftUI
import FirebaseFirestore
import FirebaseMessaging
import FirebaseAuth

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
    // ✅ Replaced mediaURLs (Firebase Storage) with mediaBase64 (Firestore inline).
    // Images are compressed + resized to stay well under Firestore's 1MB doc limit.
    // No Storage bucket or billing upgrade required — works on Spark (free) plan.
    let mediaBase64: [String]
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
//     mediaBase64: [String],   ← base64-encoded JPEG strings (max 3 × ~100KB each)
//     status: "open"|"answered"|"closed",
//     hasUnreadReply: Bool, createdAt, updatedAt
//
//   support_tickets/{ticketId}/replies/{replyId}
//     message: String, isAdmin: Bool, createdAt, isReadByUser: Bool
//
// Image budget: 3 images × 600px wide × quality 0.3 ≈ 50–120KB each ≈ ~360KB total.
// Well within Firestore's 1MB document limit.
//
// Admin workflow (Firebase Console → Firestore → support_tickets → [ticket doc]):
//   → replies subcollection → Add document:
//     { message: "Your reply", isAdmin: true, isReadByUser: false, createdAt: <serverTimestamp> }
//   → Also update parent doc: { status: "answered", hasUnreadReply: true }

@Observable
final class FirebaseSupportService {
    static let shared = FirebaseSupportService()
    private init() {}

    // ✅ Regular let — FirebaseApp.configure() is called first in DiPoApp.init()
    // before any view renders and before this singleton is first accessed.
    private let db = Firestore.firestore()

    var tickets: [SupportTicket] = []
    var isLoading = false
    var submitError: String?
    var fetchError: String?      // ← shown in UI so user can see what went wrong

    // MARK: - Submit Ticket

    func submitTicket(
        category: String,
        subject: String,
        message: String,
        images: [UIImage]
    ) async throws -> String {
        let ticketId = UUID().uuidString
        // Support requires login. The UI gates this at the entry point
        // (Profile → Contact Support prompts sign-in when logged out), but we
        // also enforce it here so a ticket is never created without an
        // authenticated user — that guarantees an account the reply can route
        // to, and (via Firebase) an email address for confirmations.
        guard let userId = UserSession.shared.userID else {
            throw NSError(domain: "DiPo", code: 401, userInfo: [
                NSLocalizedDescriptionKey: loc("support.login_required")
            ])
        }

        // Firestore rules require request.auth != null. A user whose Apple/
        // Google Firebase sign-in didn't persist (e.g. right after a
        // logout→login, where the anonymous launch-fallback hasn't re-run)
        // would otherwise hit "Missing or insufficient permissions". Guarantee
        // a Firebase session before writing.
        if Auth.auth().currentUser == nil {
            _ = try? await Auth.auth().signInAnonymously()
        }

        // Encode images to Base64 inline — no Storage bucket needed.
        // Each image is resized to max 600px wide then JPEG-compressed at 0.3
        // to stay well under Firestore's 1MB document size limit.
        var mediaBase64: [String] = []
        for img in images {
            if let encoded = encodeImageForFirestore(img) {
                mediaBase64.append(encoded)
            }
        }

        // Warn if images were provided but ALL failed to encode (corrupt data, etc.)
        if !images.isEmpty && mediaBase64.isEmpty {
            throw NSError(domain: "DiPo", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Screenshots couldn't be processed. Try again or send without attachments."
            ])
        }

        let data: [String: Any] = [
            "userId":         userId,
            "userName":       UserSession.shared.displayName as Any,
            "userEmail":      UserSession.shared.email as Any,
            "userPlan":       PremiumManager.shared.plan.label,
            "category":       category,
            "subject":        subject,
            "message":        message,
            "mediaBase64":    mediaBase64,
            "status":         "open",
            "hasUnreadReply": false,
            // ✅ FCM token so admin panel can push device notifications
            "fcmToken":       UserDefaults.standard.string(forKey: "dipo_fcm_token") as Any,
            "createdAt":      FieldValue.serverTimestamp(),
            "updatedAt":      FieldValue.serverTimestamp()
        ]

        try await db.collection("support_tickets").document(ticketId).setData(data)

        // Fire-and-forget: ask the worker to email (1) the user a confirmation
        // (if their ticket has an email) and (2) the admin inbox a "new ticket"
        // notification (always). The worker reads the recipient from the ticket
        // doc we just wrote (never from the request) and stamps an idempotency
        // flag, so this needs no auth and can't be abused to email arbitrary
        // addresses. Called unconditionally so the admin is alerted even when
        // the user has no email.
        Task.detached { await Self.sendTicketCreatedEmail(ticketId: ticketId) }

        return ticketId
    }

    /// Ask the worker to send the "ticket received" confirmation email.
    /// Best-effort: any failure is logged and swallowed — it must never
    /// surface as a ticket-submission error.
    nonisolated static func sendTicketCreatedEmail(ticketId: String) async {
        let urlStr = "https://dipo-receipt-scanner.fahmi-aquinas.workers.dev/api/send-email"
        guard let url = URL(string: urlStr) else { return }
        let locale = await MainActor.run { LanguageManager.shared.current.rawValue }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "kind": "ticket_created",
            "ticketId": ticketId,
            "locale": locale,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            _ = try await URLSession.shared.data(for: req)
        } catch {
            print("[DiPo] ticket_created email failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Update FCM token on all open tickets when token refreshes

    func updateFCMToken(_ token: String) async {
        let userId = UserSession.shared.userID ?? "anonymous"
        guard userId != "anonymous" else { return }
        do {
            let snap = try await db.collection("support_tickets")
                .whereField("userId", isEqualTo: userId)
                .getDocuments()
            for doc in snap.documents {
                try? await doc.reference.updateData(["fcmToken": token])
            }
        } catch {
            print("[DiPo] updateFCMToken error: \(error)")
        }
        // Also keep the per-user device-token registry fresh.
        await registerDeviceToken(token)
    }

    // MARK: - Device Token Registry (admin push targeting)
    //
    // Firestore schema:
    //   device_tokens/{userId}
    //     fcmToken:  String   ← FCM registration token (admin pushes to this)
    //     userName:  String?
    //     plan:      String   ← "free" | "royal" (rawValue, for segmenting)
    //     locale:    String   ← "en" | "id" (so admin can localize copy)
    //     platform:  "ios"
    //     updatedAt: serverTimestamp
    //
    // The admin website looks a user up here (or queries the whole
    // collection for a broadcast) and sends an FCM push to `fcmToken`.
    //
    // Unlike `updateFCMToken` (which only touches tickets the user filed),
    // this registers EVERY signed-in user — so admins can reach users who
    // never contacted support.

    /// Write/refresh this device's push token under `device_tokens/{userId}`.
    /// No-op for anonymous (not-signed-in) users — an anon doc can't be
    /// targeted anyway.
    func registerDeviceToken(_ token: String) async {
        guard let userId = UserSession.shared.userID else {
            print("[DiPo] registerDeviceToken skipped — not signed in")
            return
        }
        let data: [String: Any] = [
            // Field name MUST be `fcmToken` — the admin panel reads exactly
            // that key. Renaming it silently breaks admin push targeting.
            "fcmToken":  token,
            "userName":  UserSession.shared.displayName as Any,
            // Email enables the admin panel to send broadcast emails. Stored
            // here (in addition to on each ticket) so broadcasts — which
            // target device_tokens, not tickets — can reach users by email.
            "email":     UserSession.shared.email as Any,
            "plan":      PremiumManager.shared.plan.rawValue,   // "free" | "royal"
            "locale":    LanguageManager.shared.current.rawValue,
            "platform":  "ios",
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        do {
            // merge:true — keeps the doc if it exists, just refreshes fields.
            try await db.collection("device_tokens")
                .document(userId)
                .setData(data, merge: true)
            print("[DiPo] device_tokens/\(userId) registered ✓")
        } catch {
            print("[DiPo] registerDeviceToken error: \(error)")
        }
    }

    /// Actively fetch the current FCM token from Firebase Messaging and
    /// register it. Prefer this over trusting the UserDefaults cache —
    /// `Messaging.token()` returns the live token (or triggers generation
    /// if APNs is ready), so a returning user who logged in before the
    /// token-refresh callback fired still gets registered.
    ///
    /// Call on login AND on app launch (for already-signed-in users — the
    /// userID `.onChange` doesn't fire when the value is restored from
    /// Keychain at launch, so launch needs its own explicit call).
    func registerCurrentDeviceToken() async {
        guard UserSession.shared.userID != nil else { return }
        do {
            let token = try await Messaging.messaging().token()
            UserDefaults.standard.set(token, forKey: "dipo_fcm_token")
            await registerDeviceToken(token)
        } catch {
            // APNs not ready yet (capability missing, simulator, or token
            // still in flight). Fall back to whatever is cached; the
            // token-refresh callback will register later when it arrives.
            print("[DiPo] Messaging.token() failed: \(error)")
            if let cached = UserDefaults.standard.string(forKey: "dipo_fcm_token") {
                await registerDeviceToken(cached)
            }
        }
    }

    // MARK: - Image Encoder (Firestore-safe)

    /// Resizes to max 600px wide, then progressively reduces JPEG quality
    /// until the encoded size is under 180KB — ensuring the full ticket
    /// document stays well within Firestore's 1MB limit for up to 3 images.
    private func encodeImageForFirestore(_ image: UIImage) -> String? {
        let maxWidth: CGFloat = 600
        let scale    = image.size.width > maxWidth ? maxWidth / image.size.width : 1.0
        let newSize  = CGSize(width: image.size.width * scale,
                              height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized  = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }

        // Progressive compression — start at 0.5, step down until under 180KB.
        // Covers large iPhone screenshots (typically 800KB+ raw) without silent failure.
        let qualities: [CGFloat] = [0.5, 0.35, 0.2, 0.1]
        let maxBytes = 180_000

        for quality in qualities {
            guard let data = resized.jpegData(compressionQuality: quality) else { continue }
            if data.count < maxBytes {
                print("[DiPo] Image encoded at quality \(quality): \(data.count) bytes")
                return data.base64EncodedString()
            }
        }

        // Last resort: resize down further to 300px and compress hard
        let tinySize  = CGSize(width: min(newSize.width, 300),
                               height: min(newSize.height, 300 * newSize.height / newSize.width))
        let tinyRenderer = UIGraphicsImageRenderer(size: tinySize)
        let tiny = tinyRenderer.image { _ in resized.draw(in: CGRect(origin: .zero, size: tinySize)) }
        guard let data = tiny.jpegData(compressionQuality: 0.1),
              data.count < maxBytes else {
            print("[DiPo] Image could not be compressed to fit Firestore limit, skipping")
            return nil
        }
        print("[DiPo] Image encoded at fallback tiny: \(data.count) bytes")
        return data.base64EncodedString()
    }

    // MARK: - Fetch Tickets for current user

    func fetchTickets() async {
        let userId = UserSession.shared.userID ?? "anonymous"
        await MainActor.run { isLoading = true; fetchError = nil }
        do {
            // ✅ No .order(by:) here — combining whereField + orderBy requires a
            // composite Firestore index. Sort client-side instead, zero config needed.
            let snap = try await db.collection("support_tickets")
                .whereField("userId", isEqualTo: userId)
                .getDocuments()
            let decoded = snap.documents
                .compactMap { decodeTicket($0) }
                .sorted { $0.updatedAt > $1.updatedAt }   // newest first, client-side
            await MainActor.run { tickets = decoded }
        } catch {
            await MainActor.run {
                fetchError = error.localizedDescription
                print("[DiPo Support] fetchTickets failed for userId=\(userId): \(error)")
            }
        }
        await MainActor.run { isLoading = false }
    }

    // MARK: - Fetch Replies for a ticket

    // MARK: - User sends a reply to an existing ticket

    func submitUserReply(ticketId: String, message: String) async throws {
        let batch = db.batch()

        // Add reply document
        let replyRef = db.collection("support_tickets")
            .document(ticketId)
            .collection("replies")
            .document()
        batch.setData([
            "message":      message,
            "isAdmin":      false,
            "isReadByUser": true,
            "createdAt":    FieldValue.serverTimestamp()
        ], forDocument: replyRef)

        // Reopen ticket so admin sees a new message
        let ticketRef = db.collection("support_tickets").document(ticketId)
        batch.updateData([
            "status":         "open",
            "hasUnreadReply": false,
            "updatedAt":      FieldValue.serverTimestamp()
        ], forDocument: ticketRef)

        try await batch.commit()

        // Refresh local list so ticket shows "Open" again
        await fetchTickets()
    }

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
                .whereField("isAdmin",      isEqualTo: true)
                .whereField("isReadByUser", isEqualTo: false)
                .getDocuments()

            let batch = db.batch()
            for doc in snap.documents {
                batch.updateData(["isReadByUser": true], forDocument: doc.reference)
            }
            try await batch.commit()

            try await db.collection("support_tickets")
                .document(ticketId)
                .updateData(["hasUnreadReply": false])

            await fetchTickets()
        } catch {}
    }

    // Ticket-reply notifications are no longer driven by a `support_tickets`
    // listener here. The admin panel writes each reply to
    // `user_notifications/{userId}/items` (picked up by
    // startListeningForAdminNotifications → the bell) AND fires an FCM push
    // (the lock-screen banner). Running a second listener that posted its own
    // push + bell entry double-delivered every reply, so it was removed.

    func stopListening() {
        adminNotifListener?.remove()
        adminNotifListener = nil
    }

    // MARK: - Admin Broadcast Listener (guaranteed in-app delivery)
    //
    // Firestore schema (what the app reads):
    //   user_notifications/{userId}/items/{autoId}
    //     title         String
    //     body          String   (also accepts "message")
    //     icon          String?  SF Symbol, default "megaphone.fill"
    //     iconColorHex  String?  default "#A78BFA"
    //     createdAt     Timestamp  (also accepts "sentAt"/"timestamp"/"date",
    //                               and number/string forms)
    //
    // Why this exists alongside FCM: an FCM push is fire-and-forget — swipe
    // the banner and it's gone, never reaching the bell. Firestore docs
    // PERSIST. This listener attaches on every app open; its initial
    // snapshot replays every doc, so anything the admin wrote while the
    // app was closed lands in the bell the moment the user opens the app.
    //
    // De-dup: a per-user Set of already-consumed doc IDs in UserDefaults.
    // A doc is delivered once, then its ID is remembered. The set is pruned
    // to only IDs that still exist so it can't grow unbounded. A 7-day
    // recency cutoff keeps a fresh install from replaying ancient
    // broadcasts (older docs are marked consumed silently).
    //
    // The field handling is deliberately lenient — the admin web panel is a
    // separate codebase, so we accept the common field-name variants rather
    // than silently dropping a notification on a key typo.

    private var adminNotifListener: ListenerRegistration?

    func startListeningForAdminNotifications() {
        guard let userId = UserSession.shared.userID else { return }
        adminNotifListener?.remove()

        let consumedKey = "admin_notif_consumed_\(userId)"

        adminNotifListener = db.collection("user_notifications")
            .document(userId)
            .collection("items")
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("[DiPo] admin notif listener error: \(error.localizedDescription)")
                    return
                }
                guard let docs = snapshot?.documents else { return }
                print("[DiPo] admin notif listener: \(docs.count) doc(s) in user_notifications/\(userId)/items")

                var consumed = Set(UserDefaults.standard.stringArray(forKey: consumedKey) ?? [])
                let cutoff  = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
                let liveIDs = Set(docs.map(\.documentID))

                // Oldest-first so the bell ends up chronological.
                let items = docs.map { doc -> (id: String, date: Date, data: [String: Any]) in
                    let data = doc.data()
                    return (doc.documentID, Self.extractDate(from: data) ?? Date(), data)
                }.sorted { $0.date < $1.date }

                // Separate deliverable notifications from silent skips.
                // Silent skips (too old, no content) can be consumed immediately.
                // Real notifications: consumed is saved INSIDE the Task, AFTER post()
                // runs — this prevents the bug where consumed is persisted to UserDefaults
                // before the Task executes and the app is terminated, permanently losing
                // the notification (consumed but never shown).
                var toPost: [(id: String, icon: String, hex: String, title: String, body: String, imageUrl: String?, linkUrl: String?, kind: String?)] = []
                var silentConsumed: Set<String> = []

                for item in items {
                    guard !consumed.contains(item.id) else { continue }

                    guard item.date >= cutoff else {
                        silentConsumed.insert(item.id)
                        continue
                    }

                    let title = (item.data["title"] as? String) ?? ""
                    let body  = (item.data["body"] as? String)
                             ?? (item.data["message"] as? String) ?? ""
                    guard !title.isEmpty || !body.isEmpty else {
                        print("[DiPo] admin notif \(item.id) skipped — no title/body")
                        silentConsumed.insert(item.id)
                        continue
                    }
                    let icon     = (item.data["icon"] as? String) ?? "megaphone.fill"
                    let hex      = (item.data["iconColorHex"] as? String) ?? "#A78BFA"
                    // Lenient field names — admin panel is a separate codebase.
                    let imageUrl = (item.data["imageUrl"] as? String)
                                ?? (item.data["image"] as? String)
                                ?? (item.data["imageURL"] as? String)
                    let linkUrl  = (item.data["linkUrl"] as? String)
                                ?? (item.data["link"] as? String)
                                ?? (item.data["url"] as? String)
                    // Category — lets the app render some notifications
                    // distinctly (e.g. "ticket_reply" shows concisely).
                    let kind     = (item.data["type"] as? String)
                                ?? (item.data["kind"] as? String)
                    // Bilingual: the admin panel sends a fixed-language title
                    // for support replies ("DiPo Support membalas"). Override
                    // it with a string localized to the user's CURRENT app
                    // language so EN users don't see Indonesian (and vice
                    // versa). The body stays the agent's actual reply text.
                    let displayTitle = (kind == "ticket_reply")
                        ? loc("notif.support_replied_push")
                        : title
                    print("[DiPo] admin notif queued → bell: \(displayTitle)")
                    toPost.append((item.id, icon, hex, displayTitle, body, imageUrl, linkUrl, kind))
                }

                // Persist silent-consumed IDs immediately (no async work needed).
                consumed.formUnion(silentConsumed)
                consumed.formIntersection(liveIDs)
                UserDefaults.standard.set(Array(consumed), forKey: consumedKey)

                guard !toPost.isEmpty else { return }

                // Post notifications and save their consumed IDs AFTER post() runs.
                //
                // pushToDevice:false on purpose. For admin broadcasts, the
                // Cloudflare Worker already fires an FCM push (which iOS
                // shows as a banner via willPresent). If we ALSO let
                // post() fire its own local push, the user sees the same
                // notification banner twice — once from FCM, once from
                // the local fallback. The Firestore listener's job here
                // is to guarantee the BELL entry; the banner is owned by
                // the FCM path.
                Task { @MainActor in
                    for entry in toPost {
                        NotificationManager.shared.post(AppNotificationItem(
                            icon: entry.icon, iconColorHex: entry.hex,
                            title: entry.title.isEmpty ? entry.body : entry.title,
                            body:  entry.title.isEmpty ? "" : entry.body,
                            time: loc("notif.time.now"), isUrgent: true,
                            imageUrl: entry.imageUrl, linkUrl: entry.linkUrl,
                            kind: entry.kind
                        ), pushToDevice: false)
                    }
                    // Save consumed only now — guarantees no notification is permanently
                    // lost due to app termination between enqueue and execution.
                    var saved = Set(UserDefaults.standard.stringArray(forKey: consumedKey) ?? [])
                    saved.formUnion(toPost.map(\.id))
                    saved.formIntersection(liveIDs)
                    UserDefaults.standard.set(Array(saved), forKey: consumedKey)
                }
            }
    }

    /// Best-effort timestamp extraction. The admin panel might write the
    /// time under any of several keys and in any of several encodings —
    /// accept them all rather than drop the notification.
    private static func extractDate(from data: [String: Any]) -> Date? {
        for key in ["createdAt", "sentAt", "timestamp", "date", "time"] {
            if let ts = data[key] as? Timestamp { return ts.dateValue() }
            if let d  = data[key] as? Date      { return d }
            // Epoch number — seconds vs milliseconds auto-detected.
            if let n  = data[key] as? Double {
                return Date(timeIntervalSince1970: n > 1_000_000_000_000 ? n / 1000 : n)
            }
            if let n  = data[key] as? Int {
                let d = Double(n)
                return Date(timeIntervalSince1970: d > 1_000_000_000_000 ? d / 1000 : d)
            }
            // ISO-8601 string.
            if let s = data[key] as? String, let d = ISO8601DateFormatter().date(from: s) {
                return d
            }
        }
        return nil
    }

    // MARK: - Per-ticket live listener (used by TicketThreadView)
    // Watches both replies subcollection AND the parent ticket doc for status changes.
    // Calls onReplyAdded when new replies arrive, onStatusChanged when admin updates status.

    private var ticketDocListener: ListenerRegistration?
    private var ticketRepliesListener: ListenerRegistration?

    func listenToTicket(
        ticketId: String,
        onReplyAdded: @escaping ([SupportReply]) -> Void,
        onStatusChanged: @escaping (String) -> Void
    ) async {
        // Remove any previous per-ticket listeners
        ticketDocListener?.remove()
        ticketRepliesListener?.remove()

        // Listen to parent doc for status changes
        ticketDocListener = db.collection("support_tickets")
            .document(ticketId)
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let data = snap?.data() else { return }
                let newStatus = data["status"] as? String ?? "open"
                let subject   = data["subject"] as? String ?? "Your ticket"

                // Only fire notification if status actually changed
                if let old = tickets.first(where: { $0.id == ticketId }),
                   old.status != newStatus {
                    Task { @MainActor in
                        NotificationManager.shared.postTicketStatusChanged(
                            subject:   subject,
                            newStatus: newStatus
                        )
                    }
                }
                onStatusChanged(newStatus)
            }

        // Listen to replies subcollection
        ticketRepliesListener = db.collection("support_tickets")
            .document(ticketId)
            .collection("replies")
            .order(by: "createdAt", descending: false)
            .addSnapshotListener { snap, _ in
                guard let docs = snap?.documents else { return }
                let replies = docs.compactMap { d -> SupportReply? in
                    let data = d.data()
                    return SupportReply(
                        id:           d.documentID,
                        message:      data["message"]      as? String ?? "",
                        isAdmin:      data["isAdmin"]      as? Bool   ?? false,
                        createdAt:    (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
                        isReadByUser: data["isReadByUser"] as? Bool   ?? false
                    )
                }
                onReplyAdded(replies)
            }
    }

    func stopTicketListener() {
        ticketDocListener?.remove()
        ticketRepliesListener?.remove()
        ticketDocListener     = nil
        ticketRepliesListener = nil
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
            mediaBase64:    d["mediaBase64"]     as? [String] ?? [],
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
            message:      d["message"]      as? String ?? "",
            isAdmin:      d["isAdmin"]      as? Bool   ?? false,
            createdAt:    (d["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            isReadByUser: d["isReadByUser"] as? Bool   ?? false
        )
    }
}

// MARK: - Helper: Identifiable String (for sheet binding)

struct IdentifiableString: Identifiable {
    let id    = UUID()
    let value: String
}
