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
        ("HomeTotalSubline", "DiPo/HomeBalance.swift"),
        ("MonthFlowCard", "HomeSummary.swift"),
        ("HomeReminderLine", "DiPo/HomeReminders.swift"),
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

    /// Home's sections sit on the page: the period's figures, the reminder
    /// line and the header's icons have no card or tile behind them.
    func testNoCardsOrTilesBehindHomeSections() throws {
        for view in [("MonthFlowCard", "HomeSummary.swift"),
                     ("HomeReminderLine", "DiPo/HomeReminders.swift"),
                     ("HomeTotalSubline", "DiPo/HomeBalance.swift"),
                     ("HomeHeader", "DiPo/HomeCards.swift")] {
            let src = try source(of: view.0, in: view.1).joined(separator: "\n")
            XCTAssertFalse(src.contains("AppTheme.cardDark, in:"), "\(view.0) sits on a card")
            // A one-line circle fill is an icon tile. (The avatar's circle,
            // written over several lines, is the photo's frame.)
            XCTAssertFalse(src.contains("Circle().fill(AppTheme.cardDark)"), "\(view.0) has an icon tile")
        }
    }

    /// Ask DiPo is in the header now that the reminder line has no face.
    func testAskDiPoIsInTheHeader() throws {
        let header = try source(of: "HomeHeader", in: "DiPo/HomeCards.swift").joined(separator: "\n")
        XCTAssertTrue(header.contains("onAskDiPo()"))
        XCTAssertTrue(header.contains("loc(\"dipo.ask\")"))
    }

    /// The total is the loudest figure on Home.
    func testTheTotalIsTheBigNumber() throws {
        let row = try source(of: "HomeTotalRow", in: "DiPo/HomeBalance.swift").joined(separator: "\n")
        XCTAssertTrue(row.contains(".largeTitle"))
        let flow = try source(of: "MonthFlowCard", in: "HomeSummary.swift").joined(separator: "\n")
        XCTAssertFalse(flow.contains(".largeTitle") || flow.contains(".title"), "the period's figures stay smaller")
    }
}
