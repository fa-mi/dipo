import XCTest

/// The screens the Debts page opens (adding a debt, paying it, the payoff
/// simulator, a credit card's page and form, instalments, the analysis, the
/// load of fixed payments) follow the minimal rules: no border or tinted wash,
/// no tile behind an icon, pills as coloured words, bars flat. Green is the
/// one action and money coming in; red is trouble and deleting; what is owed
/// is ink, as on the Debts page. Reads the sources, like SheetsMinimalTests.
final class DebtSubMinimalTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private let screens = ["DiPo/DebtSheets.swift", "DiPo/DebtCards.swift", "CreditCard.swift",
                           "CardInstallment.swift", "DiPo/DebtAnalysis.swift", "ObligationsView.swift",
                           "CommitmentPriority.swift", "CommitmentImpact.swift"]

    /// A file's source with comments stripped.
    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
    }

    private func matches(_ pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad pattern \(pattern)")
            return []
        }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range, in: source).map {
                source[$0].split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " ")
            }
        }
    }

    /// A shape stroked over a view: a border. The one ring kept is round the
    /// card chosen to pay from.
    private let border = #"\.overlay\(\s*(RoundedRectangle|Capsule|Circle)\([^)]*\)\s*\.(stroke|strokeBorder)\([^\n]*"#
    /// A faint colour behind words or a card.
    private let wash = #"\.opacity\([^)]*\)\s*,\s*in:\s*(Capsule|RoundedRectangle|Circle)"#
    /// A disc or tile filled with a faint colour and sized for an icon.
    private let tile = #"(Circle\(\)|RoundedRectangle\([^)]*\))\s*\.fill\([^\n]*\.opacity\([^\n]*\.frame\(width:\s*[2-9]\d,\s*height:\s*[2-9]\d\)"#

    func testNothingIsDrawnForShow() throws {
        var found: [String] = []
        for path in screens {
            let source = try text(path)
            found += matches(border, in: source)
                .filter { !$0.contains("selectedCardIndex == i ?") }
                .map { "\(path) border: \($0)" }
            found += matches(wash, in: source).map { "\(path) wash: \($0)" }
            // The payoff celebration keeps its disc: it is a moment, not a page.
            found += matches(tile, in: source)
                .filter { !$0.contains("width: 104") }
                .map { "\(path) tile: \($0)" }
        }
        XCTAssertTrue(found.isEmpty, "Drawn for show:\n\(found.joined(separator: "\n"))")
    }

    /// Gradients are left only on card faces, which are the cards' own colours.
    func testOnlyCardFacesKeepAGradient() throws {
        for path in screens {
            let lines = try text(path).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("LinearGradient(") {
                let context = lines[i...min(i + 1, lines.count - 1)].joined()
                XCTAssertTrue(context.contains("gradientStart"), "\(path):\(i + 1) \(line)")
            }
        }
    }

    /// Saving a debt and paying one are each the sheet's one action: green,
    /// flat. The save was red and the pay button a gradient of the debt's colour.
    func testTheActionsAreGreen() throws {
        let sheets = try text("DiPo/DebtSheets.swift")
        XCTAssertTrue(sheets.contains(".background(canSave ? AppTheme.accentFill : AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.lg))"))
        XCTAssertTrue(sheets.contains(".background(isValid ? AppTheme.accentFill : AppTheme.cardMid,"))
        XCTAssertFalse(sheets.contains("AppTheme.red.opacity(0.9)"))
    }

    /// What is owed is ink, as on the Debts page; red was saying "trouble"
    /// about every debt.
    func testWhatIsOwedIsInk() throws {
        let card = try text("CreditCard.swift")
        XCTAssertTrue(card.contains("Text(owedFmt).font(.system(.body, weight: .bold)).foregroundStyle(AppTheme.textPrimary)"))
        XCTAssertTrue(card.contains("private var tint: Color { isHot ? AppTheme.orange : AppTheme.textPrimary }"))
        XCTAssertFalse(card.contains("Canvas {"), "the limit bar is flat, not hatched")
    }

    /// A choice is marked in ink (currency, which debt to simulate).
    func testChoicesAreInk() throws {
        let sheets = try text("DiPo/DebtSheets.swift")
        XCTAssertTrue(sheets.contains(".background(vm.formCurrency == c ? AppTheme.textPrimary : AppTheme.cardDark, in: Capsule())"))
        XCTAssertTrue(sheets.contains(".background(selectedDebt.id == d.id ? AppTheme.textPrimary : AppTheme.cardMid,"))
    }

    /// "2x min" was English on every screen.
    func testTwiceTheMinimumIsSaidInWords() throws {
        XCTAssertFalse(try text("DiPo/DebtSheets.swift").contains("\"2x min\""))
        let strings = try text("LanguageManager.swift")
        XCTAssertTrue(strings.contains("\"debt.double_min\":      \"Twice the minimum\""))
        XCTAssertTrue(strings.contains("\"debt.double_min\":      \"Dua kali minimum\""))
    }
}
