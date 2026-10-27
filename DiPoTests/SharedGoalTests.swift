import XCTest
@testable import DiPo

/// Target Bersama (once Tabungan Bersama): joined by invitation under an id
/// the rules can find, or kept in a Rekening Bersama whose members are its
/// members and whose balance can be set aside for it — saved, not spent.
@MainActor
final class SharedGoalTests: XCTestCase {

    private func goal(_ id: String = "g1", account: String? = nil, members: [String] = ["a1", "b1"],
                      currency: String = "IDR", status: String = "active") -> SharedGoal {
        var data: [String: Any] = [
            "ownerUid": members.first ?? "a1", "title": "DP Rumah", "emoji": "🏡",
            "targetAmount": 100_000_000.0, "currency": currency, "savedAmount": 13_000_000.0,
            "memberUids": members, "memberCount": members.count, "maxMembers": 5, "status": status,
        ]
        if let account { data["jointAccountId"] = account }
        return SharedGoal(id: id, data: data)!
    }

    private func account(_ id: String = "acc1", members: [String] = ["a1", "b1"], balance: Int64 = 4_250_000,
                         currency: String = "IDR") -> JointAccount {
        JointAccount(id: id, data: [
            "name": "Rumah Tangga", "emoji": "🏠", "currency": currency, "ownerUid": "a1",
            "memberUids": members, "memberCount": NSNumber(value: Int64(members.count)),
            "maxMembers": NSNumber(value: Int64(5)), "balance": NSNumber(value: balance),
            "monthlyBudget": NSNumber(value: Int64(0)), "status": "active",
        ])!
    }

    private func entry(_ kind: JointTx.Kind, _ amount: Int64, _ category: TxCategory? = nil,
                       goal goalId: String? = nil, on date: Date) -> JointTx {
        var data: [String: Any] = ["uid": "a1", "kind": kind.rawValue, "amount": NSNumber(value: amount)]
        if let category { data["category"] = category.rawValue }
        if let goalId { data["goalId"] = goalId }
        var tx = JointTx(id: UUID().uuidString, data: data)!
        tx.date = date
        return tx
    }

    private var jakarta: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        return cal
    }

    // MARK: Documents

    func testAGoalKnowsWhichAccountItIsKeptIn() {
        XCTAssertEqual(goal(account: "acc1").jointAccountId, "acc1")
        XCTAssertTrue(goal(account: "acc1").isKeptInAccount)
        XCTAssertNil(goal().jointAccountId)
        XCTAssertNil(SharedGoal(id: "g", data: ["ownerUid": "a1", "title": "x", "targetAmount": 1.0,
                                                "jointAccountId": ""])?.jointAccountId, "empty is none")
    }

    /// The rules find the invitation of whoever joins by exactly this id.
    func testTheInvitationIdIsGoalThenInvitee() {
        XCTAssertEqual(SharedInvite.id(goal: "g1", to: "b1"), "g1_b1")
        let data: [String: Any] = ["goalId": "g1", "toUid": "b1", "fromUid": "a1", "status": "pending"]
        XCTAssertFalse(SharedInvite(id: "g1_b1", data: data)!.isLegacy)
        XCTAssertTrue(SharedInvite(id: "Xr4Kq9zT2", data: data)!.isLegacy,
                      "an older DiPo's random id: the rules cannot find it, so it can only be declined")
    }

    // MARK: Saved, not spent

    func testMoneyPutTowardsAGoalIsNotSpending() {
        let transfer = entry(.spend, -1_000_000, .investment, goal: "g1", on: .now)
        XCTAssertEqual(transfer.goalId, "g1")
        XCTAssertFalse(transfer.isSpending)
        XCTAssertTrue(entry(.spend, -85_000, .food, on: .now).isSpending)
        XCTAssertFalse(entry(.deposit, 85_000, on: .now).isSpending)
    }

    func testTheMonthsBudgetLeavesGoalTransfersOut() {
        let mid = jakarta.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        let month = JointBudget.month(containing: mid, calendar: jakarta)
        let entries = [
            entry(.spend, -850_000, .food, on: mid),
            entry(.spend, -1_000_000, .investment, goal: "g1", on: mid),
        ]
        XCTAssertEqual(JointBudget.spent(entries, in: month), 850_000)
    }

    /// Smart Budget's Savings is what is left of the month's money; setting
    /// some of it aside for a goal keeps it there, it does not spend it.
    func testSmartBudgetCountsGoalTransfersAsSaved() {
        let mid = jakarta.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        let month = JointBudget.month(containing: mid, calendar: jakarta)
        let previous = JointBudget.month(containing: month.start.addingTimeInterval(-3600), calendar: jakarta)
        let entries = [
            entry(.income, 9_000_000, .salary, on: mid),
            entry(.spend, -3_100_000, .food, on: mid),
            entry(.spend, -1_650_000, .shopping, on: mid),
            entry(.spend, -1_000_000, .investment, goal: "g1", on: mid),
        ]
        let sb = JointSmartBudget.compute(entries, month: month, previous: previous, ratios: .balanced)
        XCTAssertEqual(sb.spentTotal, 4_750_000)
        XCTAssertEqual(sb.saved, 4_250_000, "the million set aside is still saved")
        XCTAssertEqual(sb.spent(.needs), 3_100_000)
        XCTAssertEqual(sb.spent(.wants), 1_650_000)
    }

    // MARK: Kept in a Rekening Bersama

    func testMoneyMovesOnlyWithinTheBalanceToTheAccountsOwnGoal() {
        let acc = account()
        let g = goal(account: "acc1")
        XCTAssertTrue(JointGoals.canMove(1_000_000, to: g, from: acc, as: "a1"))
        XCTAssertTrue(JointGoals.canMove(4_250_000, to: g, from: acc, as: "b1"), "all of it")
        XCTAssertFalse(JointGoals.canMove(4_250_001, to: g, from: acc, as: "a1"), "more than there is")
        XCTAssertFalse(JointGoals.canMove(0, to: g, from: acc, as: "a1"))
        XCTAssertFalse(JointGoals.canMove(1, to: goal(account: "acc2"), from: acc, as: "a1"), "another account's goal")
        XCTAssertFalse(JointGoals.canMove(1, to: goal(), from: acc, as: "a1"), "a goal of no account")
        XCTAssertFalse(JointGoals.canMove(1, to: goal(account: "acc1", currency: "USD"), from: acc, as: "a1"))
        XCTAssertFalse(JointGoals.canMove(1, to: goal(account: "acc1", members: ["a1"]), from: acc, as: "b1"),
                       "not in the goal yet")
        XCTAssertFalse(JointGoals.canMove(1, to: goal(account: "acc1", status: "archived"), from: acc, as: "a1"))
    }

    /// Someone who joined the account after the goal was made gets in; someone
    /// who left the account is taken off.
    func testTheGoalsMembersFollowTheAccount() {
        let acc = account(members: ["a1", "b1", "c1"])
        let g = goal(account: "acc1", members: ["a1", "b1", "z1"])
        XCTAssertTrue(JointGoals.shouldJoin(g, account: acc, me: "c1"))
        XCTAssertFalse(JointGoals.shouldJoin(g, account: acc, me: "a1"), "already in")
        XCTAssertFalse(JointGoals.shouldJoin(g, account: acc, me: "q1"), "not in the account")
        XCTAssertFalse(JointGoals.shouldJoin(goal(account: "acc2"), account: acc, me: "c1"), "another account's goal")
        XCTAssertEqual(JointGoals.departed(g, account: acc), ["z1"])
        XCTAssertEqual(JointGoals.departed(goal(members: ["z1"]), account: acc), [], "a goal on its own keeps its people")
    }

    // MARK: Words

    func testItIsCalledTargetBersamaAndThePotIsSavings() {
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(loc("unity.title"), "Target Bersama")
            XCTAssertEqual(loc("joint.sb.save"), "Tabungan", "not a second \"Tabungan bersama\"")
            for key in ["unity.title", "unity.create", "unity.empty", "unity.new_title", "unity.invites_header",
                        "unity.delete_goal_confirm", "joint.sb.empty", "joint.sb.save"] {
                XCTAssertFalse(loc(key).lowercased().contains("tabungan bersama"), key)
            }
            XCTAssertTrue(loc("unity.invite_hint").contains("tidak perlu Royal"))
        }
    }

    func testNewStringsInBothLanguagesKeepTheirArguments() {
        let keys = ["unity.invite_legacy", "unity.kept_in", "unity.source_my_card", "unity.balance_after",
                    "unity.move_note", "unity.create_note_account", "unity.create_in_account_sub",
                    "unity.set_aside", "unity.saved_of", "joint.entry.goal_kind", "joint.entry.to_goal"]
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for k in keys { XCTAssertNotEqual(loc(k), k, "\(k) in \(language)") }
                let of = String(format: loc("unity.saved_of"), "Rp 13 jt", "Rp 100 jt")
                XCTAssertTrue(of.contains("Rp 13 jt") && of.contains("Rp 100 jt"), of)
                XCTAssertTrue(String(format: loc("unity.move_note"), "Rumah Tangga").contains("Rumah Tangga"))
                XCTAssertTrue(String(format: loc("joint.entry.to_goal"), "DP Rumah").contains("DP Rumah"))
                XCTAssertTrue(String(format: loc("unity.invite_legacy"), "Andi").contains("Andi"))
            }
        }
    }
}
