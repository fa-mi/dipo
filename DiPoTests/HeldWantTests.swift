import XCTest
import SwiftData
@testable import DiPo

/// Wait before buying: how a wait runs, what the jar holds, when DiPo asks,
/// and that a backup carries the list.
@MainActor
final class HeldWantTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DiPoSchemaCurrent.self)
        container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    override func tearDownWithError() throws {
        container = nil
    }

    /// A fixed moment, so every wait ends where the test says.
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    private var jakarta: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        return cal
    }

    private func want(_ name: String = "Sepatu lari", _ amount: Double = 450_000,
                      currency: String = "IDR", days: Int = 3) -> HeldWant {
        let w = HeldWant(name: name, amount: amount, currency: currency, waitDays: days, now: start)
        container.mainContext.insert(w)
        return w
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        jakarta.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: The wait

    func testAWaitEndsAfterTheDaysChosen() {
        let w = want()
        XCTAssertEqual(w.readyAt, start.addingTimeInterval(3 * day))
        XCTAssertFalse(w.isReady(at: start.addingTimeInterval(2 * day)))
        XCTAssertTrue(w.isReady(at: w.readyAt))
        XCTAssertEqual(w.waited(at: start), 0)
        XCTAssertEqual(w.waited(at: start.addingTimeInterval(1.5 * day)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(w.waited(at: w.readyAt.addingTimeInterval(day)), 1)
    }

    /// A three-day wait says three days when it starts, then hours on the
    /// last day, then "almost time".
    func testWhatIsLeftReadsTheWayItIsSaid() {
        let w = want()
        XCTAssertEqual(w.timeLeft(at: start), .days(3))
        XCTAssertEqual(w.timeLeft(at: start.addingTimeInterval(day + 13 * hour)), .days(1))
        XCTAssertEqual(w.timeLeft(at: start.addingTimeInterval(2 * day + hour)), .hours(23))
        XCTAssertEqual(w.timeLeft(at: w.readyAt.addingTimeInterval(-50 * 60)), .hours(1))
        XCTAssertEqual(w.timeLeft(at: w.readyAt.addingTimeInterval(-20 * 60)), .soon)
        XCTAssertNil(w.timeLeft(at: w.readyAt))
    }

    func testDaysHeldCountsFromWhenItWasHeld() {
        let w = want()
        XCTAssertEqual(w.daysHeld(at: start.addingTimeInterval(10 * hour)), 1, "Never less than a day.")
        XCTAssertEqual(w.daysHeld(at: w.readyAt), 3)
        XCTAssertEqual(w.daysHeld(at: start.addingTimeInterval(10 * day)), 10)
    }

    func testWaitingLongerStartsTheSameWaitAgain() {
        let w = want()
        let later = w.readyAt.addingTimeInterval(hour)
        w.waitAgain(from: later)
        XCTAssertEqual(w.readyAt, later.addingTimeInterval(3 * day))
        XCTAssertEqual(w.waitStartedAt, later)
        XCTAssertFalse(w.isReady(at: later))
        XCTAssertEqual(w.waited(at: later), 0)
    }

    func testADecisionTakesItOffTheListAndCanBeUndone() {
        let w = want()
        let after = w.readyAt.addingTimeInterval(hour)
        w.decide(.letGo, at: after)
        XCTAssertTrue(w.isDecided)
        XCTAssertEqual(w.decision, .letGo)
        XCTAssertEqual(w.decidedAt, after)
        XCTAssertFalse(w.isReady(at: after))

        w.undoDecision()
        XCTAssertNil(w.decision)
        XCTAssertNil(w.decidedAt)
        XCTAssertTrue(w.isReady(at: after), "Back to waiting for a decision.")
    }

    /// Written by a newer build: still decided, never asked about again, and
    /// not counted in a jar that doesn't know what it means.
    func testAnUnknownDecisionStillCountsAsMade() {
        let w = want()
        w.decisionRaw = "later"
        XCTAssertTrue(w.isDecided)
        XCTAssertNil(w.decision)
        XCTAssertFalse(w.isReady(at: w.readyAt.addingTimeInterval(day)))
        XCTAssertEqual(HoldTally([w], convert: { a, _ in a }), HoldTally())
    }

    /// Without Royal one want waits at a time; deciding it frees the place.
    /// Royal holds as many as it likes.
    func testWithoutRoyalOneWantWaitsAtATime() {
        XCTAssertEqual(HeldWant.freeLimit, 1)
        XCTAssertTrue(HeldWant.canHoldAnother(open: 0, royal: false))
        XCTAssertFalse(HeldWant.canHoldAnother(open: 1, royal: false))
        XCTAssertFalse(HeldWant.canHoldAnother(open: 4, royal: false), "Kept from Royal days, still no more.")
        XCTAssertTrue(HeldWant.canHoldAnother(open: 1, royal: true))
        XCTAssertTrue(HeldWant.canHoldAnother(open: 25, royal: true))

        let shoes = want()
        let open = { [shoes].filter { !$0.isDecided }.count }
        XCTAssertFalse(HeldWant.canHoldAnother(open: open(), royal: false))
        shoes.decide(.letGo)
        XCTAssertTrue(HeldWant.canHoldAnother(open: open(), royal: false))
    }

    func testTheWaitsOfferedRunShortToLong() {
        XCTAssertEqual(HeldWant.waits, HeldWant.waits.sorted())
        XCTAssertTrue(HeldWant.waits.contains(HeldWant.defaultWait))
    }

    // MARK: The jar

    func testTheJarHoldsWhatWasLetGoOutOfEverythingDecided() {
        let headset = want("Headset", 300_000), snack = want("Jajan", 50_000)
        let shoes = want("Sepatu", 150_000), phone = want("HP baru", 1_000_000)
        let game = want("Game", 10, currency: "USD")
        headset.decide(.letGo); snack.decide(.letGo); shoes.decide(.buy); game.decide(.letGo)
        // `phone` still waits: not in the jar either way.
        let tally = HoldTally([headset, snack, shoes, phone, game]) { amount, currency in
            currency == "USD" ? amount * 16_000 : amount
        }
        XCTAssertEqual(tally.kept, 510_000)
        XCTAssertEqual(tally.decided, 660_000)
        XCTAssertEqual(tally.letGo, 3)
        XCTAssertEqual(tally.bought, 1)
        XCTAssertEqual(tally.level, 510_000 / 660_000, accuracy: 0.0001)
    }

    func testAJarWithNothingLetGoIsEmpty() {
        XCTAssertEqual(HoldTally([], convert: { a, _ in a }).level, 0)
        let bought = want()
        bought.decide(.buy)
        let tally = HoldTally([bought], convert: { a, _ in a })
        XCTAssertEqual(tally.kept, 0)
        XCTAssertEqual(tally.decided, 450_000)
        XCTAssertEqual(tally.level, 0)
    }

    // MARK: Asking

    func testAWaitEndingAtNightIsAskedAboutInTheMorning() {
        let cal = jakarta
        XCTAssertEqual(HeldWantReminders.askTime(for: at(2027, 1, 18, 14, 20), cal: cal), at(2027, 1, 18, 14, 20))
        XCTAssertEqual(HeldWantReminders.askTime(for: at(2027, 1, 18, 20, 59), cal: cal), at(2027, 1, 18, 20, 59))
        XCTAssertEqual(HeldWantReminders.askTime(for: at(2027, 1, 18, 21, 0), cal: cal), at(2027, 1, 19, 8, 0))
        XCTAssertEqual(HeldWantReminders.askTime(for: at(2027, 1, 18, 23, 10), cal: cal), at(2027, 1, 19, 8, 0))
        XCTAssertEqual(HeldWantReminders.askTime(for: at(2027, 1, 19, 5, 30), cal: cal), at(2027, 1, 19, 8, 0))
        XCTAssertEqual(HeldWantReminders.askTime(for: at(2027, 1, 31, 23, 0), cal: cal), at(2027, 2, 1, 8, 0))
    }

    /// One push per want still waiting; none for a decided one or one whose
    /// wait is already over.
    func testDiPoAsksOnlyAboutWantsStillWaiting() {
        let cal = jakarta
        let now = at(2027, 1, 15, 9, 0)
        let shoes = want("Sepatu lari"), headset = want("Headset"), late = want("Jaket")
        let decided = want("Game"), over = want("Kopi")
        shoes.readyAt = at(2027, 1, 18, 14, 20)
        late.readyAt = at(2027, 1, 18, 23, 10)
        headset.readyAt = at(2027, 1, 16, 10, 0)
        decided.readyAt = at(2027, 1, 18, 10, 0)
        decided.decide(.letGo, at: now)
        over.readyAt = at(2027, 1, 14, 10, 0)

        LanguageManager.shared.withLanguage(.indonesian) {
            let planned = HeldWantReminders.plan(wants: [shoes, headset, late, decided, over], now: now, cal: cal)
            XCTAssertEqual(planned.map(\.id), [shoes, headset, late].map { "heldwant_\($0.id.uuidString)" })
            XCTAssertEqual(planned.first?.title, "Masih mau Sepatu lari?")
            XCTAssertEqual(planned.first?.body, "Sudah kamu tahan 3 hari. Buka DiPo untuk beli atau lepaskan.")
            let lateFire = planned.last?.fire
            XCTAssertEqual(lateFire?.day, 19)
            XCTAssertEqual(lateFire?.hour, 8)
            XCTAssertEqual(lateFire?.minute, 0)
            XCTAssertEqual(planned.first?.fire.hour, 14)
            XCTAssertEqual(planned.first?.fire.minute, 20)
        }
    }

    // MARK: Words

    func testEveryWordIsInBothLanguages() {
        let keys = ["title", "kept", "kept_of", "kept_none", "add", "intro_title", "intro_body",
                    "days_left", "days_left_one", "hours_left", "hours_left_one", "soon", "ready", "ready_one",
                    "let_go", "buy", "was_let_go", "was_bought", "let_go_now", "let_go_now_sub", "wait_again",
                    "undo", "undo_sub", "delete_title", "delete_message", "deleted", "wait_days", "wait_days_one",
                    "form_title", "form_edit_title", "form_sub", "form_what", "form_what_placeholder",
                    "form_price", "form_wait", "form_ready_at", "form_ready_now", "form_save", "saved",
                    "updated", "held_again", "kept_title", "kept_sub", "not_now", "let_go_toast",
                    "bought_toast", "bought_toast_sub", "waiting_section", "decided_section",
                    "more_royal", "more_royal_sub"]
            .map { "hold.\($0)" }
            + ["notif.hold_title", "notif.hold_body",
               NotificationPreferences.Kind.wants.titleKey, NotificationPreferences.Kind.wants.subtitleKey]
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in keys {
                    XCTAssertNotEqual(loc(key), key, "missing \(key) in \(language)")
                }
                XCTAssertEqual(HeldWant.waitText(1), loc("hold.wait_days_one"))
                XCTAssertTrue(HeldWant.waitText(7).contains("7"))
            }
        }
    }

    // MARK: Backup

    /// Every field comes back as it went, decision and all; a backup made
    /// before the list existed still reads, with no list.
    func testABackupCarriesTheListBackExactly() throws {
        let w = want()
        w.waitAgain(from: start.addingTimeInterval(4 * day))
        w.decide(.letGo, at: start.addingTimeInterval(8 * day))

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(BackupHeldWant.self, from: encoder.encode(BackupHeldWant(w))).restored()
        XCTAssertEqual(back.id, w.id)
        XCTAssertEqual(back.name, w.name)
        XCTAssertEqual(back.amount, w.amount)
        XCTAssertEqual(back.currency, w.currency)
        XCTAssertEqual(back.addedAt, w.addedAt)
        XCTAssertEqual(back.waitDays, w.waitDays)
        XCTAssertEqual(back.readyAt, w.readyAt)
        XCTAssertEqual(back.decision, .letGo)
        XCTAssertEqual(back.decidedAt, w.decidedAt)

        let smartBudget = BackupSmartBudgetSettings(isEnabled: false, dailyRatio: 0.5, lifestyleRatio: 0.3,
                                                    investDebtRatio: 0.2, budgetCardID: nil)
        let old = BackupPayload(version: 1, exportedAt: start, appVersion: "3.3", cards: [], transactions: [],
                                salaries: [], debts: [], goals: [], cardBudgets: [], smartBudget: smartBudget)
        let oldJSON = try encoder.encode(old)
        XCTAssertFalse(String(decoding: oldJSON, as: UTF8.self).contains("heldWants"))
        XCTAssertNil(try decoder.decode(BackupPayload.self, from: oldJSON).heldWants)

        var new = old
        new.heldWants = [BackupHeldWant(w)]
        let read = try decoder.decode(BackupPayload.self, from: encoder.encode(new))
        XCTAssertEqual(read.heldWants?.map(\.name), ["Sepatu lari"])
        XCTAssertEqual(read.heldWants?.first?.decisionRaw, "letGo")
    }
}
