import XCTest
@testable import DiPo

/// Home follows the minimal rules: no border round a card, no faint wash of
/// colour behind a card or a figure, no glow or sheen on the bank card, and
/// labels in sentence case. Reads the views' sources, like MinimalListTests,
/// and names anything that slips back. A fill that marks a choice (the
/// category filter that is on) is information, not a wash, and is allowed.
@MainActor
final class HomeMinimalTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The views Home is drawn from, and the file each lives in.
    private let views: [(name: String, file: String)] = [
        ("HomeHeader", "DiPo/HomeCards.swift"),
        ("BankCardView", "DiPo/HomeCards.swift"),
        ("HomeTotalRow", "DiPo/HomeBalance.swift"),
        ("MonthFlowCard", "HomeSummary.swift"),
        ("RecurringReminderBanner", "DiPo/HomeBanners.swift"),
        ("SetupSalaryBanner", "DiPo/HomeBanners.swift"),
        ("PinnedGoalBanner", "DiPo/HomeBanners.swift"),
        ("NegativeBalanceBanner", "DiPo/HomeBanners.swift"),
        ("CategoryFilterBar", "DiPo/HomeTransactions.swift"),
        ("TxRow", "DiPo/HomeTransactions.swift"),
    ]

    /// A struct's source, from its declaration to its closing brace, with
    /// comments stripped.
    private func source(of name: String, in file: String) throws -> [String] {
        let lines = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
        guard let start = lines.firstIndex(where: { $0.hasPrefix("struct \(name):") }) else {
            XCTFail("struct \(name) not found in \(file)")
            return []
        }
        var depth = 0
        var opened = false
        for i in start..<lines.count {
            for ch in lines[i] {
                if ch == "{" { depth += 1; opened = true }
                if ch == "}" { depth -= 1 }
            }
            if opened && depth == 0 { return Array(lines[start...i]) }
        }
        return Array(lines[start...])
    }

    func testNoBordersWashesOrGlow() throws {
        var found: [String] = []
        for view in views {
            for line in try source(of: view.name, in: view.file) {
                let border = (line.contains(".overlay(") && line.contains(".stroke("))
                    || line.contains("strokeBorder(")
                let wash = line.contains(".background(") && line.contains(".opacity(")
                let glow = line.contains(".blur(")
                if border || wash || glow {
                    found.append("\(view.name): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(found.isEmpty, "Home draws no borders, washes or glows:\n\(found.joined(separator: "\n"))")
    }

    /// The total's label was spaced-out capitals; it reads in sentence case
    /// like every other label.
    func testTheTotalIsLabelledInSentenceCase() throws {
        let row = try source(of: "HomeTotalRow", in: "DiPo/HomeBalance.swift").joined(separator: "\n")
        XCTAssertFalse(row.contains(".uppercased("))
        XCTAssertFalse(row.contains(".tracking("))
    }

    /// Purchase and income go without saying beside a signed amount; a debt
    /// payment, or a type the person named, still gets its line.
    func testOnlyATypeThatAddsSomethingIsShown() {
        for ordinary in ["tx.type.purchase", "Purchase", "tx.type.income", "Income"] {
            XCTAssertFalse(TxRow.showsType(ordinary), ordinary)
        }
        XCTAssertTrue(TxRow.showsType("tx.type.debt_payment"))
        XCTAssertTrue(TxRow.showsType("Debt Payment"))
        XCTAssertTrue(TxRow.showsType("Arisan"))
    }
}
