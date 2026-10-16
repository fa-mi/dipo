import SwiftUI
import SwiftData
import FirebaseFirestore
import FirebaseAuth

// MARK: - Rekening Bersama (joint accounts)
//
// A shared wallet for two to five people: mostly a couple, sometimes a family
// or housemates. Target Bersama is a goal everyone saves towards; this is
// day-to-day money — what came in, what went out, who spent it, and how much
// of the month's budget is left.
//
// It is a shared RECORD, not a bank: the money itself stays wherever the
// couple keeps it (cash in a tin, one partner's account). DiPo keeps the book
// both of them can see.
//
// It lives in Firestore rather than SwiftData because every member sees the
// same figures, so nothing here is in the local store or in backups and no
// schema changes. The one place it touches the local books is a deposit, which
// leaves the personal card as a transfer: money moved, not money spent.
//
// A Target Bersama can be kept in an account (SharedGoal.jointAccountId): its
// members are the account's, and money moves to it from the shared balance
// as an entry carrying `goalId` — money out of the account, saved rather than
// spent, so neither the monthly budget nor Smart Budget counts it.
//
// The balance is kept honest by the rules (dipo-backend/firestore.rules): it
// moves only in the same batch as an entry is added or removed, by exactly
// that entry's amount. Amounts are whole minor units (rupiah, cents), so the
// arithmetic is exact on every phone.
//
// Only the person who creates one needs Royal. Anyone with a DiPo ID can be
// invited and join — a husband should not need a subscription to see what his
// wife spent on groceries.

// MARK: - Money

/// Joint amounts are integers in the currency's minor unit: rupiah have none,
/// dollars have cents. Doubles would drift the moment two phones add up the
/// same entries in a different order.
enum JointMoney {
    /// The rules refuse anything larger, so the app never sends it.
    static let maxMinor: Int64 = 1_000_000_000_000_000

    static func usesCents(_ currency: String) -> Bool {
        !["IDR", "JPY", "KRW", "VND"].contains(currency.uppercased())
    }

    static func toMinor(_ amount: Double, currency: String) -> Int64 {
        let scaled = (amount * (usesCents(currency) ? 100 : 1)).rounded()
        guard scaled.isFinite else { return 0 }
        return Int64(max(min(scaled, Double(maxMinor)), -Double(maxMinor)))
    }

    static func toMajor(_ minor: Int64, currency: String) -> Double {
        Double(minor) / (usesCents(currency) ? 100 : 1)
    }

    /// "Rp 85.000", without a sign.
    static func text(_ minor: Int64, currency: String) -> String {
        CurrencyManager.shared.formatted(Swift.abs(toMajor(minor, currency: currency)), currency: currency)
    }
}

/// Text the rules cap by length. Counted in UTF-16 units, which is never fewer
/// than the characters the rules count, so a clipped string always passes.
enum JointText {
    static func clip(_ s: String, _ limit: Int) -> String {
        var out = ""
        for ch in s.trimmingCharacters(in: .whitespacesAndNewlines) {
            if out.utf16.count + String(ch).utf16.count > limit { break }
            out.append(ch)
        }
        return out
    }

    /// The words written when no name was known — "Someone", "Seseorang".
    /// A row that carries one should ask the person to write their own.
    static func isPlaceholder(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return n.isEmpty || placeholderNames.contains(n)
    }

    /// `joint.someone` in each language, lowercased. Spelled out rather than
    /// looked up, because this runs while views draw and switching the
    /// language to read the other table would redraw them; JointAccountTests
    /// checks it still matches the tables.
    static let placeholderNames: Set<String> = ["someone", "seseorang"]

    /// One or two letters for an avatar.
    static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}

private func jointInt(_ value: Any?) -> Int64? {
    (value as? NSNumber)?.int64Value
}

// MARK: - Models

struct JointAccount: Identifiable, Hashable {
    let id: String
    var name: String
    var emoji: String
    var currency: String
    var ownerUid: String
    var ownerName: String
    var memberUids: [String]
    var memberCount: Int
    var maxMembers: Int
    var balance: Int64
    var monthlyBudget: Int64
    var status: String
    var createdAt: Date
    /// Smart Budget's split of the month's money in; 50/30/20 until the owner changes it.
    var smartRatios: JointRatios

    init?(id: String, data: [String: Any]) {
        guard let ownerUid = data["ownerUid"] as? String,
              let name = data["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.emoji = data["emoji"] as? String ?? "🤝"
        self.currency = data["currency"] as? String ?? "IDR"
        self.ownerUid = ownerUid
        self.ownerName = data["ownerName"] as? String ?? ""
        self.memberUids = data["memberUids"] as? [String] ?? []
        self.memberCount = Int(jointInt(data["memberCount"]) ?? Int64(memberUids.count))
        self.maxMembers = Int(jointInt(data["maxMembers"]) ?? Int64(JointAccountService.maxMembers))
        self.balance = jointInt(data["balance"]) ?? 0
        self.monthlyBudget = jointInt(data["monthlyBudget"]) ?? 0
        self.status = data["status"] as? String ?? "active"
        self.createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        self.smartRatios = JointRatios(data: data["smartRatios"])
    }

    var isActive: Bool { status == "active" }
    var isFull: Bool { memberCount >= maxMembers }
    func isOwner(_ uid: String?) -> Bool { uid != nil && ownerUid == uid }
}

struct JointTx: Identifiable, Hashable {
    enum Kind: String {
        case income = "in"
        case spend = "out"
        case deposit
    }

    let id: String
    var uid: String
    var displayName: String
    /// Signed: money out is negative.
    var amount: Int64
    var kind: Kind
    /// A `TxCategory` raw value, or empty for a deposit.
    var category: String
    var note: String
    var date: Date
    /// Money put towards one of the account's goals: the goal's id, its
    /// name in `note`. Saved, not spent.
    var goalId: String?

    init?(id: String, data: [String: Any]) {
        guard let amount = jointInt(data["amount"]),
              let kind = Kind(rawValue: data["kind"] as? String ?? "") else { return nil }
        self.id = id
        self.uid = data["uid"] as? String ?? ""
        self.displayName = data["displayName"] as? String ?? ""
        self.amount = amount
        self.kind = kind
        self.category = data["category"] as? String ?? ""
        self.note = data["note"] as? String ?? ""
        self.date = (data["date"] as? Timestamp)?.dateValue() ?? Date()
        self.goalId = (data["goalId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var txCategory: TxCategory? { TxCategory(rawValue: category) }

    /// Money out that the month's budget and Smart Budget count as spending.
    var isSpending: Bool { kind == .spend && goalId == nil }
}

struct JointMember: Identifiable, Hashable {
    let id: String          // uid
    var displayName: String
    var joinedAt: Date

    init(id: String, data: [String: Any]) {
        self.id = id
        self.displayName = data["displayName"] as? String ?? ""
        self.joinedAt = (data["joinedAt"] as? Timestamp)?.dateValue() ?? .distantFuture
    }
}

struct JointInvite: Identifiable, Hashable {
    let id: String
    var accountId: String
    var accountName: String
    var accountEmoji: String
    var fromUid: String
    var fromName: String
    var toUid: String
    var status: String
    var createdAt: Date

    init?(id: String, data: [String: Any]) {
        guard let accountId = data["accountId"] as? String,
              let toUid = data["toUid"] as? String else { return nil }
        self.id = id
        self.accountId = accountId
        self.accountName = data["accountName"] as? String ?? ""
        self.accountEmoji = data["accountEmoji"] as? String ?? "🤝"
        self.fromUid = data["fromUid"] as? String ?? ""
        self.fromName = data["fromName"] as? String ?? ""
        self.toUid = toUid
        self.status = data["status"] as? String ?? "pending"
        self.createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
    }

    /// The rules find an invitation by this id when someone joins.
    static func id(account: String, to uid: String) -> String { "\(account)_\(uid)" }
}

/// What someone typed into the entry sheet, before it is written.
struct JointDraft {
    var kind: JointTx.Kind
    /// Positive, in minor units.
    var amount: Int64
    var category: String
    var note: String
    var date: Date

    var signedAmount: Int64 { kind == .spend ? -amount : amount }
    var isValid: Bool { amount > 0 && amount <= JointMoney.maxMinor }
}

// MARK: - Budget

/// The month's spending against the shared budget. Only money out counts:
/// a deposit or a gift coming in does not make the month's groceries cheaper.
enum JointBudget {
    static func month(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 0)
    }

    /// Spent in `month`, as a positive amount. Money put towards a goal is
    /// saved, not spent.
    static func spent(_ entries: [JointTx], in month: DateInterval) -> Int64 {
        entries.reduce(0) { sum, tx in
            guard tx.isSpending, tx.date >= month.start, tx.date < month.end else { return sum }
            return sum + Swift.abs(tx.amount)
        }
    }

    static func ratio(spent: Int64, budget: Int64) -> Double {
        budget > 0 ? Double(spent) / Double(budget) : 0
    }

    /// 100 once the budget is used up, 80 when it is running low.
    static func level(spent: Int64, budget: Int64) -> Int? {
        guard budget > 0 else { return nil }
        let r = ratio(spent: spent, budget: budget)
        if r >= 1 { return 100 }
        if r >= 0.8 { return 80 }
        return nil
    }

    /// The level an entry has just pushed spending into, if it changed.
    static func crossed(before: Int64, after: Int64, budget: Int64) -> Int? {
        guard let now = level(spent: after, budget: budget),
              now != level(spent: before, budget: budget) else { return nil }
        return now
    }
}

// MARK: - Smart Budget

/// How the month's money in is split: whole percents adding up to 100. The
/// rules hold the same shape (validJointRatios), so a split saved here is one
/// every phone reads back the same.
struct JointRatios: Hashable {
    var needs: Int
    var wants: Int
    var save: Int

    static let balanced = JointRatios(needs: 50, wants: 30, save: 20)
    static let frugal = JointRatios(needs: 60, wants: 20, save: 20)
    static let saver = JointRatios(needs: 50, wants: 20, save: 30)
    /// The quick choices, with the word under each.
    struct Preset: Identifiable {
        let ratios: JointRatios
        let key: String
        var id: String { key }
    }
    static let presets: [Preset] = [
        Preset(ratios: balanced, key: "joint.sb.preset.balanced"),
        Preset(ratios: frugal, key: "joint.sb.preset.frugal"),
        Preset(ratios: saver, key: "joint.sb.preset.saver"),
    ]

    init(needs: Int, wants: Int, save: Int) {
        self.needs = needs; self.wants = wants; self.save = save
    }

    /// From Firestore; anything malformed reads as 50/30/20.
    init(data: Any?) {
        let map = data as? [String: Any] ?? [:]
        func int(_ k: String) -> Int? { (map[k] as? NSNumber).map { $0.intValue } }
        let parsed = JointRatios(needs: int("needs") ?? -1, wants: int("wants") ?? -1, save: int("save") ?? -1)
        self = parsed.isValid ? parsed : .balanced
    }

    var isValid: Bool { needs >= 0 && wants >= 0 && save >= 0 && needs + wants + save == 100 }
    var label: String { "\(needs) / \(wants) / \(save)" }
    var firestore: [String: Any] { ["needs": needs, "wants": wants, "save": save] }

    func percent(_ pot: JointPot) -> Int {
        switch pot {
        case .needs: return needs
        case .wants: return wants
        case .save:  return save
        }
    }
}

/// The three parts of the month, by the personal Smart Budget's categories.
enum JointPot: String, CaseIterable, Identifiable {
    case needs, wants, save
    var id: String { rawValue }

    var categories: Set<TxCategory> {
        switch self {
        case .needs: return Set(SmartBudgetManager.dailyCategories)
        case .wants: return Set(SmartBudgetManager.lifestyleCategories)
        case .save:  return []
        }
    }

    static func of(_ category: TxCategory?) -> JointPot? {
        guard let category else { return nil }
        return [.needs, .wants].first { $0.categories.contains(category) }
    }

    var emoji: String {
        switch self {
        case .needs: return "🍚"
        case .wants: return "🛍️"
        case .save:  return "💰"
        }
    }

    var color: Color {
        switch self {
        case .needs: return AppTheme.blue
        case .wants: return AppTheme.purple
        case .save:  return AppTheme.accent
        }
    }

    var label: String { loc("joint.sb.\(rawValue)") }
    var hint: String { loc("joint.sb.\(rawValue).hint") }
}

/// One month of a shared account seen through Smart Budget: the money that
/// came in, split by the owner's ratios, against what each part has spent.
struct JointSmartBudget: Equatable {
    /// This month's money in — deposits and money in. Last month's when
    /// nothing has come in yet, so the first days of a month aren't a blank.
    let base: Int64
    let baseIsLastMonth: Bool
    let ratios: JointRatios
    let spentNeeds: Int64
    let spentWants: Int64
    /// All money out this month, whatever its category.
    let spentTotal: Int64

    static func compute(_ entries: [JointTx], month: DateInterval, previous: DateInterval,
                        ratios: JointRatios) -> JointSmartBudget {
        func moneyIn(_ m: DateInterval) -> Int64 {
            entries.reduce(0) { sum, tx in
                guard tx.kind != .spend, tx.amount > 0, tx.date >= m.start, tx.date < m.end else { return sum }
                return sum + tx.amount
            }
        }
        // Money put towards a goal stays in Savings: it is not spent.
        let outs = entries.filter { $0.isSpending && $0.date >= month.start && $0.date < month.end }
        func spent(_ pot: JointPot) -> Int64 {
            outs.filter { JointPot.of($0.txCategory) == pot }.reduce(0) { $0 + Swift.abs($1.amount) }
        }
        let this = moneyIn(month)
        return JointSmartBudget(base: this > 0 ? this : moneyIn(previous), baseIsLastMonth: this <= 0,
                                ratios: ratios, spentNeeds: spent(.needs), spentWants: spent(.wants),
                                spentTotal: outs.reduce(0) { $0 + Swift.abs($1.amount) })
    }

    var hasBase: Bool { base > 0 }

    func cap(_ pot: JointPot) -> Int64 { base * Int64(ratios.percent(pot)) / 100 }

    func spent(_ pot: JointPot) -> Int64 {
        switch pot {
        case .needs: return spentNeeds
        case .wants: return spentWants
        case .save:  return 0
        }
    }

    /// What is left of the month's money — Savings' progress towards its target.
    var saved: Int64 { max(base - spentTotal, 0) }

    /// What can still be spent each day, from Needs and Wants together.
    func safePerDay(daysLeft: Int) -> Int64 {
        let left = max(cap(.needs) - spentNeeds, 0) + max(cap(.wants) - spentWants, 0)
        return left / Int64(max(daysLeft, 1))
    }

    /// The level (80 or 100) that spending `amount` more from `pot` would push it into.
    func crossed(_ pot: JointPot, adding amount: Int64) -> Int? {
        guard pot != .save else { return nil }
        let before = spent(pot)
        return JointBudget.crossed(before: before, after: before + amount, budget: cap(pot))
    }
}

/// Days from `now` to the end of `month`, today included.
func jointDaysLeft(in month: DateInterval, from now: Date = .now, calendar: Calendar = .current) -> Int {
    let today = calendar.startOfDay(for: now)
    let days = calendar.dateComponents([.day], from: today, to: month.end).day ?? 1
    return max(days, 1)
}

// MARK: - Service

@MainActor
@Observable
final class JointAccountService {
    static let shared = JointAccountService()
    private init() {}

    static let maxMembers = 5
    static let notifyURL = URL(string: "https://dipo-receipt-scanner.fahmi-aquinas.workers.dev/api/joint-notify")!

    private let db = Firestore.firestore()

    /// Accounts I belong to, oldest first — the one a couple made first stays on top.
    var accounts: [JointAccount] = []
    /// Invitations addressed to me that are still waiting for an answer.
    var invites: [JointInvite] = []
    /// Members per account, in the order they joined.
    var members: [String: [JointMember]] = [:]
    /// This month's and last month's entries per account: the budget on the
    /// wallet card, and Smart Budget, which falls back to last month's money
    /// in until some has come in this month.
    var recent: [String: [JointTx]] = [:]
    /// The latest entries of accounts open on screen.
    var history: [String: [JointTx]] = [:]
    /// A write the server turned down after the sheet had already closed.
    var failure: String?

    private var accountsListener: ListenerRegistration?
    private var invitesListener: ListenerRegistration?
    private var perAccount: [String: [ListenerRegistration]] = [:]
    private var historyListeners: [String: ListenerRegistration] = [:]
    private var listeningUid: String?
    private(set) var month: DateInterval = JointBudget.month(containing: Date())
    var previousMonth: DateInterval { JointBudget.month(containing: month.start.addingTimeInterval(-3600)) }

    private var accountsRef: CollectionReference { db.collection("jointAccounts") }
    private var invitesRef: CollectionReference { db.collection("jointInvitations") }
    private var uid: String? { Auth.auth().currentUser?.uid }

    func account(_ id: String) -> JointAccount? { accounts.first { $0.id == id } }

    // MARK: Listening

    /// Safe to call on every appearance: it only restarts when the signed-in
    /// account or the month has changed since the last time.
    func start() {
        guard let uid else { return }
        // Each appearance also catches a name changed in Profile meanwhile.
        defer { for a in accounts { syncMyName(in: a.id) } }
        let month = JointBudget.month(containing: Date())
        if uid == listeningUid, month == self.month, accountsListener != nil, invitesListener != nil { return }
        stop()
        listeningUid = uid
        self.month = month

        accountsListener = accountsRef.whereField("memberUids", arrayContains: uid)
            .addSnapshotListener { [weak self] snap, err in
                guard let self else { return }
                Task { @MainActor in
                    if let err {
                        // Firestore ends a listener on error. Forget it, so the
                        // next start() — the Wallet appearing, the app coming
                        // back — listens again instead of staying deaf until a
                        // relaunch (which is what happened while the rules were
                        // not yet published).
                        print("[Joint] accounts listen error: \(err.localizedDescription)")
                        self.accountsListener?.remove()
                        self.accountsListener = nil
                        return
                    }
                    let list = (snap?.documents ?? [])
                        .compactMap { JointAccount(id: $0.documentID, data: $0.data()) }
                        .sorted { $0.createdAt < $1.createdAt }
                    self.accounts = list
                    self.follow(list.map(\.id))
                }
            }

        invitesListener = invitesRef.whereField("toUid", isEqualTo: uid)
            .addSnapshotListener { [weak self] snap, err in
                guard let self else { return }
                Task { @MainActor in
                    if let err {
                        print("[Joint] invites listen error: \(err.localizedDescription)")
                        self.invitesListener?.remove()
                        self.invitesListener = nil
                        return
                    }
                    self.invites = (snap?.documents ?? [])
                        .compactMap { JointInvite(id: $0.documentID, data: $0.data()) }
                        .filter { $0.status == "pending" }
                        .sorted { $0.createdAt > $1.createdAt }
                }
            }
    }

    func stop() {
        accountsListener?.remove(); accountsListener = nil
        invitesListener?.remove(); invitesListener = nil
        perAccount.values.flatMap { $0 }.forEach { $0.remove() }
        perAccount = [:]
        historyListeners.values.forEach { $0.remove() }
        historyListeners = [:]
        accounts = []; invites = []; members = [:]; recent = [:]; history = [:]
        listeningUid = nil
    }

    /// Members and this month's entries for each account. Couples have one or
    /// two accounts, so two small listeners each is cheap.
    private func follow(_ ids: [String]) {
        for (id, regs) in perAccount where !ids.contains(id) {
            regs.forEach { $0.remove() }
            perAccount[id] = nil
            members[id] = nil
            recent[id] = nil
        }
        for id in ids where perAccount[id] == nil {
            let ref = accountsRef.document(id)
            let memberReg = ref.collection("members").addSnapshotListener { [weak self] snap, err in
                guard let self else { return }
                Task { @MainActor in
                    if let err { print("[Joint] members listen error: \(err.localizedDescription)"); self.forget(id); return }
                    self.members[id] = (snap?.documents ?? [])
                        .map { JointMember(id: $0.documentID, data: $0.data()) }
                        .sorted { $0.joinedAt < $1.joinedAt }
                    self.syncMyName(in: id)
                }
            }
            let monthReg = ref.collection("transactions")
                .whereField("date", isGreaterThanOrEqualTo: Timestamp(date: previousMonth.start))
                .addSnapshotListener { [weak self] snap, err in
                    guard let self else { return }
                    Task { @MainActor in
                        if let err { print("[Joint] month listen error: \(err.localizedDescription)"); self.forget(id); return }
                        self.recent[id] = (snap?.documents ?? [])
                            .compactMap { JointTx(id: $0.documentID, data: $0.data()) }
                    }
                }
            perAccount[id] = [memberReg, monthReg]
        }
    }

    /// Drops an account's listeners after Firestore ended one, so the next
    /// accounts snapshot follows it again.
    private func forget(_ id: String) {
        perAccount[id]?.forEach { $0.remove() }
        perAccount[id] = nil
    }

    /// Listens again from scratch — the "Try again" on a screen still waiting.
    func retry() {
        listeningUid = nil
        start()
    }

    /// The latest 200 entries, while the account is open.
    func watchHistory(_ accountId: String) {
        guard historyListeners[accountId] == nil else { return }
        historyListeners[accountId] = accountsRef.document(accountId).collection("transactions")
            .order(by: "date", descending: true).limit(to: 200)
            .addSnapshotListener { [weak self] snap, err in
                guard let self else { return }
                Task { @MainActor in
                    if let err {
                        print("[Joint] history listen error: \(err.localizedDescription)")
                        self.historyListeners[accountId]?.remove()
                        self.historyListeners[accountId] = nil
                        return
                    }
                    self.history[accountId] = (snap?.documents ?? [])
                        .compactMap { JointTx(id: $0.documentID, data: $0.data()) }
                }
            }
    }

    func stopHistory(_ accountId: String) {
        historyListeners[accountId]?.remove()
        historyListeners[accountId] = nil
        history[accountId] = nil
    }

    func smartBudget(_ account: JointAccount) -> JointSmartBudget {
        JointSmartBudget.compute(recent[account.id] ?? [], month: month, previous: previousMonth,
                                 ratios: account.smartRatios)
    }

    /// This month's money out by member, largest first.
    func spentByMember(_ accountId: String) -> [(uid: String, amount: Int64)] {
        var by: [String: Int64] = [:]
        for tx in recent[accountId] ?? [] where tx.isSpending && tx.date >= month.start && tx.date < month.end {
            by[tx.uid, default: 0] += Swift.abs(tx.amount)
        }
        return by.map { (uid: $0.key, amount: $0.value) }.sorted { $0.amount > $1.amount }
    }

    /// This month's largest category of money out.
    func topCategory(_ accountId: String) -> (category: TxCategory, amount: Int64, share: Double)? {
        var by: [TxCategory: Int64] = [:]
        var total: Int64 = 0
        for tx in recent[accountId] ?? [] where tx.isSpending && tx.date >= month.start && tx.date < month.end {
            let amount = Swift.abs(tx.amount)
            by[tx.txCategory ?? .other, default: 0] += amount
            total += amount
        }
        guard let top = by.max(by: { $0.value < $1.value }), total > 0 else { return nil }
        return (top.key, top.value, Double(top.value) / Double(total))
    }

    /// Owner only, and the rules check it too.
    func setRatios(_ ratios: JointRatios, for account: JointAccount) {
        guard account.isOwner(uid), ratios.isValid else { return }
        let ref = accountsRef.document(account.id)
        let data = ratios.firestore
        Task {
            do { try await ref.updateData(["smartRatios": data]) } catch {
                print("[Joint] ratios refused: \(error.localizedDescription)")
                failure = loc("joint.err.not_saved")
            }
        }
    }

    func spentThisMonth(_ accountId: String) -> Int64 {
        JointBudget.spent(recent[accountId] ?? [], in: month)
    }

    /// "You & Rina", "You, Rina & Andi".
    func memberLine(_ account: JointAccount) -> String {
        let me = uid
        let others = (members[account.id] ?? []).filter { $0.id != me }.map(\.displayName).filter { !$0.isEmpty }
        let names = [loc("joint.you")] + others
        guard names.count > 1 else { return loc("joint.only_you") }
        return names.dropLast().joined(separator: ", ") + " & " + names.last!
    }

    func name(of uid: String, in accountId: String) -> String {
        if uid == self.uid { return loc("joint.you") }
        let n = members[accountId]?.first { $0.id == uid }?.displayName ?? ""
        return n.isEmpty ? loc("joint.someone") : n
    }

    // MARK: Creating

    /// Returns the new account's id. Written without waiting for the server:
    /// Firestore shows it from its cache straight away and sends it when there
    /// is signal, so a phone on one bar is not left spinning.
    func create(name: String, emoji: String, monthlyBudget: Int64) async -> String? {
        guard PremiumManager.shared.canAccess(.jointAccount), let uid else { return nil }
        let title = JointText.clip(name, 40)
        guard !title.isEmpty else { return nil }
        let me = await myName(uid)
        let ref = accountsRef.document()
        let batch = db.batch()
        batch.setData([
            "name": title,
            "emoji": JointText.clip(emoji, 8),
            "currency": String(CurrencyManager.shared.preferredCurrency.prefix(5)),
            "ownerUid": uid,
            "ownerName": me,
            "memberUids": [uid],
            "memberCount": 1,
            "maxMembers": Self.maxMembers,
            "balance": Int64(0),
            "monthlyBudget": max(0, min(monthlyBudget, JointMoney.maxMinor)),
            "status": "active",
            "createdAt": FieldValue.serverTimestamp(),
        ], forDocument: ref)
        batch.setData(["displayName": me, "joinedAt": FieldValue.serverTimestamp()],
                      forDocument: ref.collection("members").document(uid))
        // Waits for the server's answer, so a refusal shows on the Create
        // sheet instead of an account screen that spins for ever. On one bar
        // it stops waiting after a few seconds: the write stays queued and
        // goes out with the next signal, and the account already shows.
        switch await commit(batch, waitingAtMost: 10) {
        case .saved, .queued:
            return ref.documentID
        case .refused(let error):
            print("[Joint] create refused: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Entries

    /// Writes an entry and moves the balance with it, in one batch, then tells
    /// the others. Returns false only when the entry could not be written at all.
    @discardableResult
    func add(_ draft: JointDraft, to account: JointAccount) async -> Bool {
        guard let uid, account.memberUids.contains(uid), account.isActive, draft.isValid else { return false }
        let me = await myName(uid)
        let accountRef = accountsRef.document(account.id)
        let txRef = accountRef.collection("transactions").document()
        let txId = txRef.documentID
        let batch = db.batch()
        batch.setData([
            "uid": uid,
            "displayName": me,
            "amount": draft.signedAmount,
            "kind": draft.kind.rawValue,
            "category": JointText.clip(draft.category, 40),
            "note": JointText.clip(draft.note, 120),
            "date": Timestamp(date: draft.date),
            "createdAt": FieldValue.serverTimestamp(),
        ], forDocument: txRef)
        batch.updateData(["balance": FieldValue.increment(draft.signedAmount), "lastTxId": txId],
                         forDocument: accountRef)

        let level = draft.kind == .spend ? budgetLevel(account, adding: draft.amount, on: draft.date) : nil
        // Smart Budget: the pot this entry falls in, and whether it tips it
        // past 80% or 100% of its share. Worked out before the write, from
        // what was spent until now; the Worker checks it again.
        var potAlert: (pot: JointPot, level: Int)?
        if draft.kind == .spend, draft.date >= month.start, draft.date < month.end,
           let pot = JointPot.of(TxCategory(rawValue: draft.category)),
           let crossed = smartBudget(account).crossed(pot, adding: draft.amount) {
            potAlert = (pot, crossed)
        }
        let accountId = account.id
        Task {
            do {
                try await batch.commit()
            } catch {
                print("[Joint] add refused: \(error.localizedDescription)")
                failure = loc("joint.err.not_saved")
                return
            }
            await notify(["type": "tx", "accountId": accountId, "txId": txId])
            if let level {
                await notify(["type": "budget", "accountId": accountId, "level": level,
                              "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60])
            }
            if let potAlert {
                await notify(["type": "pot", "accountId": accountId, "pot": potAlert.pot.rawValue,
                              "level": potAlert.level, "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60])
            }
        }
        return true
    }

    /// Money from one of my own cards into the shared account. The card side
    /// is a transfer, so my own budget does not count it as spending; if the
    /// server refuses the shared side, the card side is taken back too.
    @discardableResult
    func deposit(into account: JointAccount, from card: BankCard, amount cardAmount: Double,
                 label: String, context: ModelContext) async -> Bool {
        guard let uid, account.memberUids.contains(uid), account.isActive,
              cardAmount > 0, cardAmount <= card.computedBalance() + 0.0001 else { return false }
        let shared = CurrencyManager.shared.convert(cardAmount, from: card.resolvedCurrency, to: account.currency)
        let draft = JointDraft(kind: .deposit, amount: JointMoney.toMinor(shared, currency: account.currency),
                               category: "", note: label, date: Date())
        guard draft.isValid else { return false }

        let record = TxRecord(
            name: String(format: loc("joint.deposit.card_name"), account.name),
            date: Date(), amount: -cardAmount, type: "tx.type.purchase",
            icon: "⇄", iconBgHex: "#38BDF8", category: .other,
            currency: card.resolvedCurrency, notes: "", subtype: .transfer)
        card.transactions.append(record)
        try? context.save()

        let me = await myName(uid)
        let accountRef = accountsRef.document(account.id)
        let txRef = accountRef.collection("transactions").document()
        let txId = txRef.documentID
        let batch = db.batch()
        batch.setData([
            "uid": uid,
            "displayName": me,
            "amount": draft.signedAmount,
            "kind": draft.kind.rawValue,
            "category": "",
            "note": JointText.clip(draft.note, 120),
            "date": Timestamp(date: draft.date),
            "createdAt": FieldValue.serverTimestamp(),
        ], forDocument: txRef)
        batch.updateData(["balance": FieldValue.increment(draft.signedAmount), "lastTxId": txId],
                         forDocument: accountRef)

        let accountId = account.id
        Task {
            do {
                try await batch.commit()
            } catch {
                print("[Joint] deposit refused: \(error.localizedDescription)")
                context.delete(record)
                try? context.save()
                failure = loc("joint.err.deposit_undone")
                return
            }
            await notify(["type": "tx", "accountId": accountId, "txId": txId])
        }
        return true
    }

    /// Whoever wrote an entry, or the owner, can remove it; the balance goes
    /// back by the same amount in the same write.
    /// Money put towards a goal stays: the goal has counted it, and a goal's
    /// history is not rewound either (the rules refuse it too).
    func canDelete(_ tx: JointTx, in account: JointAccount) -> Bool {
        guard let uid, account.isActive, tx.goalId == nil else { return false }
        return tx.uid == uid || account.ownerUid == uid
    }

    func delete(_ tx: JointTx, from account: JointAccount) {
        guard canDelete(tx, in: account) else { return }
        let accountRef = accountsRef.document(account.id)
        let batch = db.batch()
        batch.deleteDocument(accountRef.collection("transactions").document(tx.id))
        batch.updateData(["balance": FieldValue.increment(-tx.amount), "lastTxId": tx.id],
                         forDocument: accountRef)
        commit(batch, failure: "joint.err.not_deleted")
    }

    /// Money from the shared balance towards one of this account's goals, in
    /// one write: the entry and the balance on the account side, the
    /// contribution and the total on the goal's. Saved, not spent.
    @discardableResult
    func moveToGoal(_ goal: SharedGoal, from account: JointAccount, amount: Int64) async -> Bool {
        guard let uid, account.isActive, account.memberUids.contains(uid),
              JointGoals.canMove(amount, to: goal, from: account, as: uid) else { return false }
        let me = await myName(uid)
        let accountRef = accountsRef.document(account.id)
        let txRef = accountRef.collection("transactions").document()
        let txId = txRef.documentID
        let goalRef = db.collection("sharedGoals").document(goal.id)
        let major = JointMoney.toMajor(amount, currency: account.currency)
        let batch = db.batch()
        batch.setData([
            "uid": uid,
            "displayName": me,
            "amount": -amount,
            "kind": JointTx.Kind.spend.rawValue,
            "category": TxCategory.investment.rawValue,
            "note": JointText.clip(goal.title, 120),
            "goalId": goal.id,
            "date": Timestamp(date: Date()),
            "createdAt": FieldValue.serverTimestamp(),
        ], forDocument: txRef)
        batch.updateData(["balance": FieldValue.increment(-amount), "lastTxId": txId], forDocument: accountRef)
        batch.setData([
            "uid": uid,
            "displayName": me,
            "amount": major,
            "currency": goal.currency,
            "note": "",
            "source": "joint",
            "jointAccountId": account.id,
            "jointTxId": txId,
            "date": FieldValue.serverTimestamp(),
        ], forDocument: goalRef.collection("contributions").document(txId))
        batch.updateData(["savedAmount": FieldValue.increment(major)], forDocument: goalRef)
        batch.setData(["contributedAmount": FieldValue.increment(major)],
                      forDocument: goalRef.collection("members").document(uid), merge: true)
        switch await commit(batch, waitingAtMost: 10) {
        case .refused(let error):
            print("[Joint] move to goal refused: \(error.localizedDescription)")
            failure = loc("joint.err.not_saved")
            return false
        case .saved, .queued:
            let accountId = account.id
            Task { await notify(["type": "tx", "accountId": accountId, "txId": txId]) }
            return true
        }
    }

    private func budgetLevel(_ account: JointAccount, adding spend: Int64, on date: Date) -> Int? {
        guard account.monthlyBudget > 0, date >= month.start, date < month.end else { return nil }
        let before = spentThisMonth(account.id)
        return JointBudget.crossed(before: before, after: before + spend, budget: account.monthlyBudget)
    }

    // MARK: Inviting

    enum InviteResult { case sent, notFound, isYou, alreadyMember, alreadyInvited, full, failed }

    /// Resolve a DiPo ID and invite its owner. Only the account's owner can.
    func invite(dipoID raw: String, to account: JointAccount) async -> InviteResult {
        let dipoID = raw.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uid, account.isOwner(uid), account.isActive, !dipoID.isEmpty else { return .failed }
        guard !account.isFull else { return .full }
        do {
            let idx = try await db.collection("dipoIndex").document(dipoID).getDocument()
            guard let entry = idx.data(), let toUid = entry["uid"] as? String else { return .notFound }
            if toUid == uid { return .isYou }
            // The entry has to be the invitee's own — a DiPo ID derives from
            // the account's social id, so a squatted entry would send the
            // invitation, and the account's name, to the wrong person.
            let profile = try? await db.collection("users").document(toUid).getDocument()
            let socialID = (entry["socialUserID"] as? String) ?? (profile?.data()?["socialUserID"] as? String)
            guard UserSession.dipoID(dipoID, belongsTo: socialID) else { return .notFound }
            if account.memberUids.contains(toUid) { return .alreadyMember }

            // One invitation per person per account, by id. An earlier one that
            // was declined or withdrawn is cleared first, so the new one starts
            // fresh and the push goes out again.
            let inviteId = JointInvite.id(account: account.id, to: toUid)
            let mine = try await invitesRef.whereField("fromUid", isEqualTo: uid).getDocuments()
            if let old = mine.documents.first(where: { $0.documentID == inviteId }) {
                if (old.data()["status"] as? String) == "pending" { return .alreadyInvited }
                try await old.reference.delete()
            }

            let me = await myName(uid)
            try await invitesRef.document(inviteId).setData([
                "accountId": account.id,
                "accountName": JointText.clip(account.name, 40),
                "accountEmoji": JointText.clip(account.emoji, 8),
                "fromUid": uid,
                "fromName": me,
                "toUid": toUid,
                "status": "pending",
                "createdAt": FieldValue.serverTimestamp(),
            ])
            // The invitation is already saved; the push must never hold the button.
            Task { await notify(["type": "invite", "inviteId": inviteId]) }
            return .sent
        } catch {
            print("[Joint] invite failed: \(error.localizedDescription)")
            return .failed
        }
    }

    /// Invitations I sent for this account that nobody has answered yet.
    func pendingInvites(for account: JointAccount) async -> [JointInvite] {
        guard let uid else { return [] }
        let snap = try? await invitesRef.whereField("fromUid", isEqualTo: uid).getDocuments()
        return (snap?.documents ?? [])
            .compactMap { JointInvite(id: $0.documentID, data: $0.data()) }
            .filter { $0.accountId == account.id && $0.status == "pending" }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func withdraw(_ invite: JointInvite) async {
        try? await invitesRef.document(invite.id).delete()
    }

    /// Join: add myself, write my member row and answer the invitation, all in
    /// one batch — the rules let me in only while the invitation is pending.
    func accept(_ invite: JointInvite) async -> Bool {
        guard UserSession.shared.isLoggedIn, let uid, invite.toUid == uid else { return false }
        let me = await myName(uid)
        let accountRef = accountsRef.document(invite.accountId)
        let batch = db.batch()
        batch.updateData(["memberUids": FieldValue.arrayUnion([uid]),
                          "memberCount": FieldValue.increment(Int64(1))], forDocument: accountRef)
        batch.setData(["displayName": me, "joinedAt": FieldValue.serverTimestamp()],
                      forDocument: accountRef.collection("members").document(uid))
        batch.updateData(["status": "accepted", "respondedAt": FieldValue.serverTimestamp()],
                         forDocument: invitesRef.document(invite.id))
        do {
            try await batch.commit()
            return true
        } catch {
            // Full, closed, or gone. The account cannot be read before joining,
            // so the screen says it in general terms.
            print("[Joint] accept refused: \(error.localizedDescription)")
            return false
        }
    }

    func decline(_ invite: JointInvite) async {
        try? await invitesRef.document(invite.id).updateData([
            "status": "declined", "respondedAt": FieldValue.serverTimestamp(),
        ])
    }

    // MARK: Settings

    func update(_ account: JointAccount, name: String, emoji: String, monthlyBudget: Int64) {
        guard account.isOwner(uid) else { return }
        let title = JointText.clip(name, 40)
        guard !title.isEmpty else { return }
        let ref = accountsRef.document(account.id)
        let budget = max(0, min(monthlyBudget, JointMoney.maxMinor))
        let icon = JointText.clip(emoji, 8)
        Task {
            do {
                try await ref.updateData(["name": title, "emoji": icon, "monthlyBudget": budget])
            } catch {
                print("[Joint] update refused: \(error.localizedDescription)")
                failure = loc("joint.err.not_saved")
            }
        }
    }

    /// My name as the other members see it. Apple sends a name only on the
    /// very first sign-in, so after a reinstall DiPo may not know it, and
    /// every entry read "Someone". Written to my row in every account I'm in,
    /// to the owner's name where I own one, and kept for what I write next.
    func renameMe(to raw: String) async -> Bool {
        guard let uid else { return false }
        let name = JointText.clip(raw, 40)
        guard !name.isEmpty, !JointText.isPlaceholder(name) else { return false }
        var ok = true
        for account in accounts where account.memberUids.contains(uid) {
            let ref = accountsRef.document(account.id)
            do {
                try await ref.collection("members").document(uid).setData(["displayName": name], merge: true)
                if account.isOwner(uid) { try await ref.updateData(["ownerName": name]) }
            } catch {
                print("[Joint] rename refused: \(error.localizedDescription)")
                ok = false
            }
        }
        // One name: what is typed here is the Profile name too, so Home,
        // Profile and every joint account say the same thing.
        Keychain.save(name, key: "user_name")
        NotificationCenter.default.post(name: .profilePhotoDidChange, object: nil)
        UserSession.shared.adoptDisplayName(name)
        Task { await FirebaseSupportService.shared.registerUserProfile() }
        return ok
    }

    /// My own row's name in this account, if it is still a placeholder.
    func myNameIsMissing(in account: JointAccount) -> Bool {
        guard let uid, let me = members[account.id]?.first(where: { $0.id == uid }) else { return false }
        // A known name fixes the row by itself (syncMyName); ask only when
        // Profile has none either.
        return JointText.isPlaceholder(me.displayName) && Self.knownName() == nil
    }

    func makeOwner(_ member: JointMember, of account: JointAccount) async -> Bool {
        guard account.isOwner(uid), account.memberUids.contains(member.id) else { return false }
        do {
            try await accountsRef.document(account.id).updateData([
                "ownerUid": member.id, "ownerName": JointText.clip(member.displayName, 40),
            ])
            return true
        } catch { print("[Joint] hand-over refused: \(error.localizedDescription)"); return false }
    }

    func remove(_ memberUid: String, from account: JointAccount) async -> Bool {
        guard let uid, account.isOwner(uid), memberUid != uid else { return false }
        return await drop(memberUid, from: account.id)
    }

    /// Anyone but the owner can leave; the owner hands the account over first.
    func leave(_ account: JointAccount) async -> Bool {
        guard let uid, !account.isOwner(uid), account.memberUids.contains(uid) else { return false }
        // Its goals first, while I can still read them as a member.
        await UnitySavingsService.shared.leaveGoals(keptIn: account)
        let ok = await drop(uid, from: account.id)
        if ok { stopHistory(account.id) }
        return ok
    }

    private func drop(_ memberUid: String, from accountId: String) async -> Bool {
        let ref = accountsRef.document(accountId)
        let batch = db.batch()
        batch.updateData(["memberUids": FieldValue.arrayRemove([memberUid]),
                          "memberCount": FieldValue.increment(Int64(-1))], forDocument: ref)
        batch.deleteDocument(ref.collection("members").document(memberUid))
        do {
            try await batch.commit()
            return true
        } catch { print("[Joint] remove refused: \(error.localizedDescription)"); return false }
    }

    /// Owner closes the account for everyone. Firestore does not cascade, so
    /// the entries, members and invitations go first and the account last;
    /// "closing" stops new entries meanwhile, and lets a close that was cut
    /// off be finished later.
    func close(_ account: JointAccount) async -> Bool {
        guard let uid, account.isOwner(uid) else { return false }
        let ref = accountsRef.document(account.id)
        do {
            if account.status != "closing" { try await ref.updateData(["status": "closing"]) }
            try await deleteAll(ref.collection("transactions"))
            try await deleteAll(ref.collection("members"))
            let sent = try await invitesRef.whereField("fromUid", isEqualTo: uid).getDocuments()
            for doc in sent.documents where (doc.data()["accountId"] as? String) == account.id {
                try? await doc.reference.delete()
            }
            try await ref.delete()
            stopHistory(account.id)
            return true
        } catch {
            print("[Joint] close failed: \(error.localizedDescription)")
            return false
        }
    }

    private func deleteAll(_ ref: CollectionReference, batchSize: Int = 300) async throws {
        while true {
            let snap = try await ref.limit(to: batchSize).getDocuments()
            if snap.documents.isEmpty { return }
            let batch = db.batch()
            snap.documents.forEach { batch.deleteDocument($0.reference) }
            try await batch.commit()
            if snap.documents.count < batchSize { return }
        }
    }

    /// Account deletion. An account I own goes to the member who joined after
    /// me, or is closed if I am alone in it; one I only belong to, I leave.
    /// Every invitation I sent or received goes too.
    func cleanupForAccountDeletion() async {
        guard let uid else { return }
        do {
            let mine = try await accountsRef.whereField("memberUids", arrayContains: uid).getDocuments()
            for doc in mine.documents {
                guard var account = JointAccount(id: doc.documentID, data: doc.data()) else { continue }
                if account.isOwner(uid) {
                    let heirs = try await doc.reference.collection("members").getDocuments().documents
                        .map { JointMember(id: $0.documentID, data: $0.data()) }
                        .filter { $0.id != uid && account.memberUids.contains($0.id) }
                        .sorted { $0.joinedAt < $1.joinedAt }
                    if let heir = heirs.first {
                        guard await makeOwner(heir, of: account) else { continue }
                        account.ownerUid = heir.id
                        _ = await leave(account)
                    } else {
                        _ = await close(account)
                    }
                } else {
                    _ = await leave(account)
                }
            }
            for field in ["fromUid", "toUid"] {
                let snap = try await invitesRef.whereField(field, isEqualTo: uid).getDocuments()
                for d in snap.documents { try? await d.reference.delete() }
            }
        } catch {
            print("[Joint][account-delete] \(error.localizedDescription)")
        }
        stop()
    }

    // MARK: Helpers

    enum CommitOutcome {
        case saved
        /// No answer yet — offline or a slow line. Firestore keeps the write and sends it later.
        case queued
        case refused(Error)
    }

    /// Commits, and waits for the server at most `seconds`.
    private func commit(_ batch: WriteBatch, waitingAtMost seconds: Double) async -> CommitOutcome {
        let answered = Once()
        return await withCheckedContinuation { (done: CheckedContinuation<CommitOutcome, Never>) in
            batch.commit { error in
                Task { @MainActor in
                    guard answered.claim() else {
                        // Answered after the screen moved on: still say so.
                        if error != nil { self.failure = loc("joint.err.not_saved") }
                        return
                    }
                    if let error {
                        done.resume(returning: CommitOutcome.refused(error))
                    } else {
                        done.resume(returning: CommitOutcome.saved)
                    }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard answered.claim() else { return }
                done.resume(returning: CommitOutcome.queued)
            }
        }
    }

    /// Lets exactly one of two racing callbacks resume a continuation.
    private final class Once {
        private var taken = false
        func claim() -> Bool {
            if taken { return false }
            taken = true
            return true
        }
    }

    private func commit(_ batch: WriteBatch, failure key: String) {
        Task {
            do { try await batch.commit() } catch {
                print("[Joint] write refused: \(error.localizedDescription)")
                failure = loc(key)
            }
        }
    }

    /// The live session name, else the profile's, else "Someone" — never an
    /// empty string, which would show as a blank author on every entry.
    private func myName(_ uid: String) async -> String {
        if let known = Self.knownName() { return known }
        let snap = try? await db.collection("users").document(uid).getDocument()
        let profile = (snap?.data()?["displayName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return JointText.clip(profile.isEmpty ? loc("joint.someone") : profile, 40)
    }

    /// The name as the person set it in Profile — the one Home greets them
    /// by. Kept in the Keychain under `user_name`, apart from the Apple or
    /// Google name, which Apple sends only on the very first sign-in and so
    /// is often empty after a reinstall. That gap is why rows read "Someone"
    /// while Profile said "Fahmi".
    static var profileName: String? {
        let n = (Keychain.load(key: "user_name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // AuthManager shows "User" when nothing was ever saved; it isn't a name.
        return n.isEmpty || n == "User" || JointText.isPlaceholder(n) ? nil : n
    }

    /// A name DiPo already knows without asking the server: Profile, then the
    /// sign-in name, then Firebase's.
    static func knownName() -> String? {
        let candidates = [profileName,
                          UserSession.shared.displayName,
                          Auth.auth().currentUser?.displayName]
        for raw in candidates {
            let n = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty, !JointText.isPlaceholder(n) { return JointText.clip(n, 40) }
        }
        return nil
    }

    /// Accounts whose name write is on its way, so a second snapshot doesn't
    /// send it again.
    @ObservationIgnored private var nameSyncing: Set<String> = []

    /// Keeps my row in step with Profile: a name changed there, or a row
    /// written as "Someone" before the name was known, is corrected the next
    /// time the members list arrives — no trip to Settings needed.
    private func syncMyName(in accountId: String) {
        guard let uid, let wanted = Self.knownName(),
              let mine = members[accountId]?.first(where: { $0.id == uid }),
              mine.displayName != wanted, !nameSyncing.contains(accountId) else { return }
        nameSyncing.insert(accountId)
        let ref = accountsRef.document(accountId)
        let owner = account(accountId)?.isOwner(uid) == true
        Task {
            do {
                try await ref.collection("members").document(uid).setData(["displayName": wanted], merge: true)
                if owner { try await ref.updateData(["ownerName": wanted]) }
            } catch {
                print("[Joint] name sync refused: \(error.localizedDescription)")
            }
            nameSyncing.remove(accountId)
        }
    }

    /// Best-effort push through the Worker, which checks that the caller wrote
    /// what the push is about. Short timeout: nothing waits on it.
    private func notify(_ body: [String: Any]) async {
        var request = URLRequest(url: Self.notifyURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        for (field, value) in await WorkerAuth.headers() { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}
