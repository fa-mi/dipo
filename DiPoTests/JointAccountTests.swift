import XCTest
@testable import DiPo

/// Rekening Bersama: a shared wallet whose balance every member's phone adds
/// up the same way. The rules in dipo-backend keep the stored balance honest;
/// these pin the app's half — whole minor units, what counts against the
/// budget, and what the documents look like when they come back.
@MainActor
final class JointAccountTests: XCTestCase {

    // MARK: Money

    func testRupiahHaveNoMinorUnitAndDollarsHaveCents() {
        XCTAssertEqual(JointMoney.toMinor(85_000, currency: "IDR"), 85_000)
        XCTAssertEqual(JointMoney.toMinor(12.34, currency: "USD"), 1_234)
        XCTAssertEqual(JointMoney.toMinor(0.1 + 0.2, currency: "EUR"), 30, "no float drift in what is stored")
        XCTAssertEqual(JointMoney.toMinor(1_500.6, currency: "idr"), 1_501, "rounded, and the code is case-blind")
        XCTAssertEqual(JointMoney.toMajor(1_234, currency: "USD"), 12.34, accuracy: 0.0001)
        XCTAssertEqual(JointMoney.toMajor(85_000, currency: "IDR"), 85_000)
    }

    func testAmountsAreClampedToWhatTheRulesAccept() {
        XCTAssertEqual(JointMoney.toMinor(1e30, currency: "IDR"), JointMoney.maxMinor)
        XCTAssertEqual(JointMoney.toMinor(-1e30, currency: "IDR"), -JointMoney.maxMinor)
        XCTAssertEqual(JointMoney.toMinor(.nan, currency: "IDR"), 0)
        XCTAssertEqual(JointMoney.toMinor(.infinity, currency: "USD"), 0)
    }

    func testAmountsShowWithoutASign() {
        let text = JointMoney.text(-85_000, currency: "IDR")
        XCTAssertTrue(text.contains("85.000"), text)
        XCTAssertFalse(text.contains("-"), text)
    }

    func testADraftIsSignedByItsKind() {
        let out = JointDraft(kind: .spend, amount: 85_000, category: "Food & Drinks", note: "", date: Date())
        XCTAssertEqual(out.signedAmount, -85_000)
        XCTAssertEqual(JointDraft(kind: .income, amount: 5, category: "", note: "", date: Date()).signedAmount, 5)
        XCTAssertEqual(JointDraft(kind: .deposit, amount: 5, category: "", note: "", date: Date()).signedAmount, 5)
        XCTAssertTrue(out.isValid)
        XCTAssertFalse(JointDraft(kind: .spend, amount: 0, category: "", note: "", date: Date()).isValid)
        XCTAssertFalse(JointDraft(kind: .spend, amount: JointMoney.maxMinor + 1, category: "", note: "", date: Date()).isValid)
    }

    // MARK: Text the rules cap

    func testClippingNeverExceedsTheRulesLimit() {
        XCTAssertEqual(JointText.clip("  Rumah Tangga  ", 40), "Rumah Tangga")
        XCTAssertEqual(JointText.clip(String(repeating: "a", count: 50), 40).count, 40)
        // Emoji are several UTF-16 units; a clipped name never splits one.
        let family = String(repeating: "👨‍👩‍👧", count: 10)
        let clipped = JointText.clip(family, 40)
        XCTAssertLessThanOrEqual(clipped.utf16.count, 40)
        XCTAssertTrue(family.hasPrefix(clipped))
    }

    func testInitials() {
        XCTAssertEqual(JointText.initials("rina"), "R")
        XCTAssertEqual(JointText.initials("Fahmi Aquinas Putra"), "FA")
        XCTAssertEqual(JointText.initials(""), "?")
    }

    // MARK: Documents

    func testAnAccountDecodesIntegersFromFirestore() {
        let data: [String: Any] = [
            "name": "Rumah Tangga", "emoji": "🏠", "currency": "IDR",
            "ownerUid": "a1", "ownerName": "Fahmi",
            "memberUids": ["a1", "b1"], "memberCount": NSNumber(value: Int64(2)), "maxMembers": NSNumber(value: Int64(5)),
            "balance": NSNumber(value: Int64(4_250_000)), "monthlyBudget": NSNumber(value: Int64(3_000_000)),
            "status": "active",
        ]
        let account = JointAccount(id: "acc1", data: data)
        XCTAssertEqual(account?.balance, 4_250_000)
        XCTAssertEqual(account?.monthlyBudget, 3_000_000)
        XCTAssertEqual(account?.memberCount, 2)
        XCTAssertEqual(account?.isOwner("a1"), true)
        XCTAssertEqual(account?.isOwner("b1"), false)
        XCTAssertEqual(account?.isOwner(nil), false)
        XCTAssertEqual(account?.isFull, false)
        XCTAssertNil(JointAccount(id: "x", data: ["name": "no owner"]))
    }

    func testEntriesKeepTheirKindAndRefuseUnknownOnes() {
        let base: [String: Any] = ["uid": "b1", "amount": NSNumber(value: Int64(-85_000)), "category": "Food & Drinks"]
        XCTAssertEqual(JointTx(id: "t", data: base.merging(["kind": "out"]) { $1 })?.kind, .spend)
        XCTAssertEqual(JointTx(id: "t", data: base.merging(["kind": "in"]) { $1 })?.kind, .income)
        XCTAssertEqual(JointTx(id: "t", data: base.merging(["kind": "deposit"]) { $1 })?.kind, .deposit)
        XCTAssertNil(JointTx(id: "t", data: base.merging(["kind": "refund"]) { $1 }))
        XCTAssertEqual(JointTx(id: "t", data: base.merging(["kind": "out"]) { $1 })?.txCategory, .food)
    }

    /// The rules look the invitation up by exactly this id when someone joins.
    func testTheInvitationIdIsAccountThenInvitee() {
        XCTAssertEqual(JointInvite.id(account: "acc1", to: "b1"), "acc1_b1")
    }

    // MARK: Budget

    private func tx(_ kind: JointTx.Kind, _ amount: Int64, _ date: Date) -> JointTx {
        JointTx(id: UUID().uuidString, data: ["uid": "a1", "kind": kind.rawValue, "amount": NSNumber(value: amount)])!
            .with(date: date)
    }

    func testOnlyMoneyOutThisMonthCountsAgainstTheBudget() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        let mid = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        let month = JointBudget.month(containing: mid, calendar: cal)
        let lastMonth = cal.date(byAdding: .month, value: -1, to: mid)!
        let entries = [
            tx(.spend, -500_000, mid),
            tx(.spend, -350_000, mid),
            tx(.deposit, 2_000_000, mid),       // money in is not spending
            tx(.income, 1_000_000, mid),
            tx(.spend, -900_000, lastMonth),    // last month's
        ]
        XCTAssertEqual(JointBudget.spent(entries, in: month), 850_000)
        // The first instant of the month counts; the first of the next does not.
        XCTAssertEqual(JointBudget.spent([tx(.spend, -1, month.start), tx(.spend, -10, month.end)], in: month), 1)
    }

    func testBudgetLevels() {
        XCTAssertNil(JointBudget.level(spent: 799_999, budget: 1_000_000))
        XCTAssertEqual(JointBudget.level(spent: 800_000, budget: 1_000_000), 80)
        XCTAssertEqual(JointBudget.level(spent: 1_000_000, budget: 1_000_000), 100)
        XCTAssertNil(JointBudget.level(spent: 5, budget: 0), "no budget, no alert")
        XCTAssertEqual(JointBudget.ratio(spent: 2_150_000, budget: 3_000_000), 0.7167, accuracy: 0.001)
    }

    /// A push goes out when an entry moves spending into a new level — once,
    /// not on every purchase after it.
    func testAnAlertIsSentOnlyWhenALevelIsCrossed() {
        XCTAssertEqual(JointBudget.crossed(before: 700_000, after: 850_000, budget: 1_000_000), 80)
        XCTAssertNil(JointBudget.crossed(before: 850_000, after: 900_000, budget: 1_000_000))
        XCTAssertEqual(JointBudget.crossed(before: 900_000, after: 1_000_000, budget: 1_000_000), 100)
        XCTAssertEqual(JointBudget.crossed(before: 100_000, after: 1_200_000, budget: 1_000_000), 100, "straight past 80")
        XCTAssertNil(JointBudget.crossed(before: 1_100_000, after: 1_300_000, budget: 1_000_000))
    }

    // MARK: Wiring

    func testTheWorkerRoute() {
        XCTAssertEqual(JointAccountService.notifyURL.path, "/api/joint-notify")
        XCTAssertEqual(JointAccountService.notifyURL.scheme, "https")
    }

    func testOnlyCreatingNeedsRoyal() {
        XCTAssertEqual(PremiumFeature.jointAccount.requiredPlan, .royal)
        XCTAssertEqual(JointAccountService.maxMembers, 5, "the rules allow 2–5")
    }

    /// Pictures alone left people guessing what an icon meant.
    func testEveryIconHasAWordInBothLanguages() {
        XCTAssertEqual(Set(JointIcon.all.map(\.emoji)).count, JointIcon.all.count, "no icon twice")
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for icon in JointIcon.all {
                    XCTAssertNotEqual(icon.label, icon.key, "\(icon.emoji) has no word in \(language)")
                    XCTAssertFalse(icon.label.isEmpty)
                    XCTAssertNotEqual(icon.detail, icon.key + ".detail", "\(icon.emoji) has no meaning in \(language)")
                }
                for key in ["joint.waiting.title", "joint.waiting.body", "joint.waiting.retry"] {
                    XCTAssertNotEqual(loc(key), key, "missing \(key) in \(language)")
                }
            }
        }
        XCTAssertEqual(JointIcon(emoji: "🎯", key: "").label, "", "an old icon keeps no word")
        XCTAssertEqual(JointIcon(emoji: "🎯", key: "").detail, "")
    }

    /// "Someone (you)": Apple sends a name only on the first sign-in, so a
    /// member row can carry the fallback, in either language.
    func testAFallbackNameIsRecognisedSoThePersonIsAskedForTheirs() {
        XCTAssertTrue(JointText.isPlaceholder(""))
        XCTAssertTrue(JointText.isPlaceholder("  "))
        XCTAssertTrue(JointText.isPlaceholder("Someone"))
        XCTAssertTrue(JointText.isPlaceholder("seseorang"))
        XCTAssertFalse(JointText.isPlaceholder("Fahmi"))
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in ["joint.name.title", "joint.name.field", "joint.name.placeholder", "joint.name.edit"] {
                    XCTAssertNotEqual(loc(key), key, "missing \(key) in \(language)")
                }
                XCTAssertTrue(String(format: loc("joint.name.unknown"), "Someone").contains("Someone"))
                XCTAssertTrue(JointText.placeholderNames.contains(loc("joint.someone").lowercased()),
                              "joint.someone changed in \(language); update placeholderNames")
            }
        }
    }

    func testFormattedStringsKeepTheirArgumentsInBothLanguages() {
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                let line = String(format: loc("joint.budget.of"), "Rp 2.150.000", "Rp 3.000.000", 72)
                XCTAssertTrue(line.contains("Rp 2.150.000") && line.contains("Rp 3.000.000") && line.contains("72%"),
                              "\(language): \(line)")
                let members = String(format: loc("joint.settings.members"), 2, 5)
                XCTAssertTrue(members.contains("2") && members.contains("5"), "\(language): \(members)")
                let budget = String(format: loc("joint.budget.line"), "Oktober", "Rp 1", "Rp 2")
                XCTAssertTrue(budget.contains("Oktober") && budget.contains("Rp 1") && budget.contains("Rp 2"), "\(language)")
                XCTAssertNotEqual(loc("joint.deposit.card_name"), "joint.deposit.card_name")
            }
        }
    }
}

private extension JointTx {
    func with(date: Date) -> JointTx {
        var copy = self
        copy.date = date
        return copy
    }
}
