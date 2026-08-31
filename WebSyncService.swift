import Foundation
import SwiftUI      // `withAnimation` — phase changes drive the progress screen
import SwiftData
import FirebaseAuth
import FirebaseFirestore

// MARK: - Web Sync (Statistics Dashboard)
//
// Uploads a REPORTING SNAPSHOT of the user's finances to `webSync/{uid}` so
// dipo.info/dashboard.html can render it on a big screen. Royal only.
//
// ── This is not a backup, and the difference is the whole design ──────────
//
// A BACKUP is a complete, private, restorable archive the user exports
// deliberately and keeps. It must be lossless, because restoring from it
// replaces everything.
//
// This is the opposite on every axis: partial (only what the dashboard draws),
// disposable (each sync replaces the last), expiring (see `snapshotLifetime`),
// and its entire reason to exist is to be read by something off the phone.
// Losing it costs the user nothing — they tap the button again.
//
// Keeping them apart matters because their failure modes are opposite. A
// backup that silently drops a field is a data-loss bug. A snapshot that
// carries MORE than the dashboard draws is a privacy bug: it puts financial
// detail in a cloud document that nothing on the page will ever show.
//
// ── Currency ──────────────────────────────────────────────────────────────
//
// Everything is converted to the user's preferred currency before upload, and
// the currency is named in `baseCurrency`. The web deliberately does no
// conversion: it has no rate table, and a second one would drift from the
// figures on the phone. The dashboard ADDS these numbers together (balances
// across cards, expenses across transactions), so mixed units there would
// produce a total that means nothing.
@Observable
@MainActor
final class WebSyncService {
    static let shared = WebSyncService()
    private init() {}

    enum State: Equatable {
        case idle
        case uploading
        case success(Date)
        case failure(String)
    }

    /// The three things a sync actually does, in order. These are real stages,
    /// not a decorative animation: `reading` fetches from SwiftData, `building`
    /// converts every amount and assembles the rows, `sending` performs the
    /// Firestore write. Showing them turns a spinner into an explanation of
    /// where the wait is going — and if it fails, WHICH step failed.
    enum Phase: Int, CaseIterable, Equatable {
        case reading, building, sending

        var titleKey: String {
            switch self {
            case .reading:  return "websync.phase_read"
            case .building: return "websync.phase_build"
            case .sending:  return "websync.phase_send"
            }
        }
        var icon: String {
            switch self {
            case .reading:  return "tray.full"
            case .building: return "function"
            case .sending:  return "arrow.up.to.line"
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var phase: Phase = .reading

    /// Floor on how long a stage stays on screen.
    ///
    /// The work itself is genuinely fast — on a small dataset all three stages
    /// can finish inside a frame, and three labels flashing past in 20ms reads
    /// as a glitch rather than as progress. This is a readability floor for the
    /// human eye, not invented work: every stage still runs, and a slow stage
    /// simply takes as long as it takes.
    private static let minimumPhaseDuration: TimeInterval = 0.45

    private func enter(_ next: Phase, since start: Date) async {
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < Self.minimumPhaseDuration {
            try? await Task.sleep(nanoseconds: UInt64((Self.minimumPhaseDuration - elapsed) * 1_000_000_000))
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { phase = next }
        HapticManager.shared.tap()
    }

    /// Timestamp of the last successful sync from THIS device, so the sheet can
    /// say when it happened without another Firestore read.
    private(set) var lastSyncedAt: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastSyncKey) }
    }
    private static let lastSyncKey = "web_sync_last_synced_at"

    /// How long a snapshot stays readable before the dashboard shows its
    /// "expired, sync again" screen.
    ///
    /// 24 hours. This is a privacy setting more than a freshness one: the
    /// snapshot lives in a cloud document that a support engineer with database
    /// access could read, so it should stop existing as a useful artefact
    /// quickly. A day covers "open it on my laptop after work", and anything
    /// longer just leaves someone's finances lying around for a feature they
    /// used once.
    static let snapshotLifetime: TimeInterval = 24 * 60 * 60

    /// How far back transactions are sent.
    ///
    /// Six months, because that is exactly what the dashboard draws — its cash
    /// flow chart is `lastNMonths(6)`. Sending a full history would inflate the
    /// document (Firestore caps a document at 1 MiB) and upload years of
    /// spending detail that no pixel on the page will ever show.
    static let historyMonths = 6

    // MARK: Upload

    func sync(context: ModelContext) async {
        guard PremiumManager.shared.canAccess(.smartBudget) else {
            state = .failure(loc("websync.err_royal")); return
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            state = .failure(loc("websync.err_signin")); return
        }

        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            phase = .reading
            state = .uploading
        }
        HapticManager.shared.tap()

        let now = Date()
        let expires = now.addingTimeInterval(Self.snapshotLifetime)

        // Stage 1 → 2. The fetch and the payload build are separated so the
        // screen can name the step it is on rather than showing one opaque
        // spinner for both.
        var stageStart = Date()
        let source = fetchSource(context: context)
        await enter(.building, since: stageStart)

        stageStart = Date()
        let payload = buildPayload(from: source, now: now)
        await enter(.sending, since: stageStart)

        // `setData` with NO merge — a sync REPLACES the previous snapshot. Merge
        // would leave last week's transactions sitting under this week's, and
        // the dashboard would quietly draw a blend of two moments.
        let doc: [String: Any] = [
            "payload":   payload,
            "syncedAt":  ISO8601DateFormatter().string(from: now),
            "expiresAt": ISO8601DateFormatter().string(from: expires),
        ]

        do {
            try await Firestore.firestore().collection("webSync").document(uid).setData(doc)

            // The write landing is NOT the same as the web being able to find
            // it. The dashboard resolves a typed DiPo ID through
            // `dipoIndex/{dipoID}` to a uid, then reads `webSync/{thatUid}`.
            // When this device's Firebase uid has rotated — a fresh install
            // clears the Keychain, and the anonymous session that DiPo falls
            // back to is reissued — the index still points at the old uid.
            //
            // The snapshot then sits at an address nobody looks up, and the app
            // cheerfully reports success while the page waits forever. This
            // check is here because that exact failure cost an afternoon: it is
            // invisible from both ends unless something compares the two.
            if let problem = await indexMismatch(uid: uid) {
                state = .failure(problem)
                HapticManager.shared.error()
                return
            }

            lastSyncedAt = now
            state = .success(now)
            HapticManager.shared.success()
            ActionFeedbackCenter.shared.webSynced(at: now)
        } catch {
            print("[WebSync] upload failed: \(error.localizedDescription)")
            state = .failure(loc("websync.err_upload"))
            HapticManager.shared.error()
        }
    }

    /// Returns a human-readable problem when `dipoIndex` will not lead the web
    /// back to this device, or nil when the path is intact.
    ///
    /// Self-heals the recoverable case: if the index entry is simply MISSING,
    /// the create rule allows this device to claim it. If it exists pointing at
    /// a different uid, the update rule deliberately refuses — that guard is
    /// what stops someone re-pointing another person's DiPo ID at their own
    /// account — so all we can do is say so precisely.
    private func indexMismatch(uid: String) async -> String? {
        guard let dipoID = UserSession.shared.dipoID, !dipoID.isEmpty else {
            return loc("websync.err_no_dipoid")
        }
        let ref = Firestore.firestore().collection("dipoIndex").document(dipoID)
        do {
            let snap = try await ref.getDocument(source: .server)
            guard snap.exists else {
                // Nothing there yet — claim it. Allowed by the create rule.
                try await ref.setData([
                    "uid": uid,
                    "socialUserID": UserSession.shared.userID ?? "",
                    "updatedAt": FieldValue.serverTimestamp(),
                ], merge: true)
                return nil
            }
            let indexed = snap.data()?["uid"] as? String ?? ""
            if indexed == uid { return nil }
            print("[WebSync] dipoIndex/\(dipoID) points at \(indexed) but this device is \(uid)")
            return String(format: loc("websync.err_index_mismatch"), dipoID, uid)
        } catch {
            // Could not check. Say nothing rather than block a sync that may be
            // perfectly fine — a false alarm here is worse than a silent pass,
            // because the snapshot HAS been written either way.
            print("[WebSync] dipoIndex check failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Payload

    /// Everything the payload is built from. Fetched as its own step so the
    /// progress screen can distinguish "reading your data" from "preparing it".
    struct Source {
        var cards: [BankCard] = []
        var debts: [DebtRecord] = []
        var goals: [SavingsGoal] = []
        var recurrings: [RecurringExpense] = []
        var salaries: [SalarySchedule] = []
        /// Per-card budget overrides. Fetched here because `ratios(forCardID:)`
        /// honours them — reading the globals instead would show the web a
        /// different split from the one the phone is enforcing.
        var configs: [CardBudgetConfig] = []
    }

    private func fetchSource(context: ModelContext) -> Source {
        Source(
            cards:      (try? context.fetch(FetchDescriptor<BankCard>())) ?? [],
            debts:      (try? context.fetch(FetchDescriptor<DebtRecord>())) ?? [],
            goals:      (try? context.fetch(FetchDescriptor<SavingsGoal>())) ?? [],
            recurrings: (try? context.fetch(FetchDescriptor<RecurringExpense>())) ?? [],
            salaries:   (try? context.fetch(FetchDescriptor<SalarySchedule>())) ?? [],
            configs:    (try? context.fetch(FetchDescriptor<CardBudgetConfig>())) ?? []
        )
    }

    private func buildPayload(from source: Source, now: Date) -> [String: Any] {
        let cm = CurrencyManager.shared
        let base = cm.preferredCurrency
        let iso = ISO8601DateFormatter()

        let cards = source.cards
        let debts = source.debts
        let goals = source.goals
        let recurrings = source.recurrings
        let salaries = source.salaries

        let cutoff = Calendar.current.safeDate(
            byAdding: .month, value: -Self.historyMonths,
            to: Calendar.current.safeDate(from: Calendar.current.dateComponents([.year, .month], from: now)))

        // ── Cards ──
        // `computedBalance()` rather than the stored `balance`: that field is a
        // denormalised cache, and every screen in the app reads the computed
        // one. The dashboard must not be the single surface showing a different
        // number from the card face.
        let cardRows: [[String: Any]] = cards.map { c in
            [
                "id":           c.id.uuidString,
                "balance":      cm.convert(c.isCreditCard ? c.owedBalance() : c.computedBalance(),
                                           from: c.resolvedCurrency, to: base),
                "currency":     base,
                "isCreditCard": c.isCreditCard,
            ]
        }

        // ── Transactions ──
        // Transfers are excluded: moving your own money between accounts is not
        // income and not spending, and including them would double the totals
        // the dashboard adds up. Refunds are sent as-is with a negative sign
        // preserved by `amount`, so the web sees the reversal.
        // Split into explicit steps: as one chained expression this was heavy
        // enough that the Swift type-checker gave up on it.
        let allTx: [TxRecord] = cards.flatMap { $0.transactions }
        let windowTx: [TxRecord] = allTx
            .filter { $0.date >= cutoff && $0.txSubtype != .transfer }
            .sorted { $0.date > $1.date }

        var txRows: [[String: Any]] = []
        txRows.reserveCapacity(windowTx.count)
        for tx in windowTx {
            let from: String = tx.currency.isEmpty ? base : tx.currency
            let amount: Double = cm.convert(abs(tx.amount), from: from, to: base)
            let kind: String = tx.amount >= 0 ? "income" : "expense"
            let row: [String: Any] = [
                "id":       tx.id.uuidString,
                "amount":   amount,
                "currency": base,
                // rawValue, never `displayLabel` — the same rule the app follows
                // for stored strings. A label frozen at sync time would stay
                // Indonesian on an English dashboard. The web maps these keys to
                // its own localised names.
                "category": tx.category.rawValue,
                "type":     kind,
                "dateISO":  iso.string(from: tx.date),
            ]
            txRows.append(row)
        }

        // ── Debts ──
        // `paidAmount` is derived, not stored: the web draws a progress bar from
        // total − paid, and `currentBalance` is the field the app keeps accurate.
        let debtRows: [[String: Any]] = debts.filter { $0.isActive }.map { d in
            let total = cm.convert(d.totalAmount, from: d.currency, to: base)
            let remaining = cm.convert(d.currentBalance, from: d.currency, to: base)
            return [
                "id":          d.id.uuidString,
                "name":        d.name,
                "totalAmount": total,
                "paidAmount":  max(total - remaining, 0),
                "currency":    base,
            ]
        }

        // ── Goals ──
        let goalRows: [[String: Any]] = goals.filter { !$0.isCompleted }.map { g in
            [
                "id":            g.id.uuidString,
                "name":          "\(g.emoji) \(g.name)".trimmingCharacters(in: .whitespaces),
                "targetAmount":  cm.convert(g.targetAmount, from: g.currency, to: base),
                "currentAmount": cm.convert(g.savedAmount, from: g.currency, to: base),
                "currency":      base,
            ]
        }

        // ── Upcoming: recurring bills + salary ──
        let recurringRows: [[String: Any]] = recurrings.filter { $0.isActive }.map { r in
            [
                "id":          r.id.uuidString,
                "name":        r.label,
                "amount":      cm.convert(r.amount, from: r.currency, to: base),
                "currency":    base,
                "nextDateISO": iso.string(from: RecurringDateEngine.nextDueDate(dayOfMonth: r.dayOfMonth)),
            ]
        }

        let salaryRows: [[String: Any]] = salaries.filter { $0.isActive }.map { s in
            [
                "id":          s.id.uuidString,
                "name":        s.label,
                "amount":      cm.convert(s.amount, from: s.currency, to: base),
                "currency":    base,
                "nextDateISO": iso.string(from: SalaryDateEngine.nextPayDate(dayOfMonth: s.dayOfMonth)),
            ]
        }

        // The pay cycle the phone is currently judging.
        //
        // Without this the web fell back to a CALENDAR month, so the same app
        // reported "this month's spending" over 1–12 Aug on the laptop and over
        // 25 Jul–24 Aug on the phone. Neither figure was wrong; they simply
        // answered different questions while wearing the same label, which is
        // the worst of both.
        //
        // Sent as boundaries rather than as a precomputed total so the web can
        // still slice by category inside the window.
        let cycle: (start: Date, end: Date)? = salaries
            .first(where: { $0.isActive })
            .map { StatPeriod.payCycleRange(payDay: $0.dayOfMonth) }

        var out: [String: Any] = [
            "baseCurrency": base,
            "cards":        cardRows,
            "transactions": txRows,
            "debts":        debtRows,
            "goals":        goalRows,
            "recurrings":   recurringRows,
            "salaries":     salaryRows,
        ]

        if let cycle {
            out["cycleStartISO"] = iso.string(from: cycle.start)
            out["cycleEndISO"]   = iso.string(from: cycle.end)
        }

        // ── Smart Budget: the ratios and the verdict ──
        //
        // This is the part a free user cannot get, so it is the part that has
        // to be here. Without it the dashboard is a prettier copy of numbers
        // the phone already showed; with it, the big screen is the only place
        // the whole plan — target vs actual across all three groups — is
        // visible at once.
        //
        // Sent as target/actual PAIRS rather than as a pass/fail verdict: the
        // engine's judgement can change between sync and viewing, but the two
        // numbers it judged are a fact about the cycle.
        let sb = SmartBudgetManager.shared
        if sb.hasActiveBudget, let cycle {
            let configs: [CardBudgetConfig] = source.configs
            let r = sb.ratios(forCardID: sb.budgetCardID, configs: configs)
            let income = salaries.filter(\.isActive)
                .reduce(0.0) { $0 + cm.convert($1.amount, from: $1.currency, to: base) }
            let windowTx = allTx.filter { $0.date >= cycle.start && $0.txSubtype != .transfer }

            func group(_ g: BudgetGroup, _ ratio: Double) -> [String: Any] {
                [
                    "key":    g.rawValue,
                    "label":  g.label,
                    "ratio":  Int((ratio * 100).rounded()),
                    "target": income * ratio,
                    "actual": sb.spent(in: g, transactions: windowTx,
                                       targetCurrency: base, periodStart: cycle.start),
                ]
            }

            out["budget"] = [
                "income": income,
                "groups": [
                    group(.daily, r.daily),
                    group(.lifestyle, r.lifestyle),
                    group(.investDebt, r.investDebt),
                ],
            ]

            // Top three only. The phone can afford a scrollable list; a
            // dashboard section that grows without bound stops being a summary.
            //
            // Generated TWICE, once per language. An insight is a sentence the
            // engine assembles around the user's own figures, so the web cannot
            // translate it afterwards — the string tables and the engine only
            // exist together here. Two passes over at most three insights costs
            // nothing measurable, and it is the difference between a dashboard
            // that switches language and one that switches half of itself.
            func insights(in language: LanguageManager.Language) -> [[String: String]] {
                LanguageManager.shared.withLanguage(language) {
                    sb.evaluateAll(
                        allTransactions: allTx, income: income,
                        cardID: sb.budgetCardID, configs: configs,
                        targetCurrency: base, goals: goals, periodStart: cycle.start
                    ).prefix(3).map { ["title": $0.title, "body": $0.body] }
                }
            }
            let en = insights(in: .english)
            let id = insights(in: .indonesian)
            // Zipped into one row per insight so the web can pick a language
            // without having to keep two lists in step by index.
            out["insights"] = zip(en, id).map { e, i in
                ["en": e, "id": i] as [String: Any]
            }
        }
        // Absent when the user has no salary schedule — the web then falls back
        // to a calendar month, which is the right answer for someone whose
        // money has no pay cycle to align to.
        return out
    }

    /// Remove the snapshot from the cloud. Offered in the sheet so a user who
    /// synced once on a shared laptop can revoke it without waiting a day.
    func revoke() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            try await Firestore.firestore().collection("webSync").document(uid).delete()
            lastSyncedAt = nil
            state = .idle
            HapticManager.shared.warning()
            ActionFeedbackCenter.shared.removed(loc("websync.revoked"))
        } catch {
            print("[WebSync] revoke failed: \(error.localizedDescription)")
            state = .failure(loc("websync.err_revoke"))
        }
    }
}
