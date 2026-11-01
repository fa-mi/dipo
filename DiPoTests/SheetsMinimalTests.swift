import XCTest

/// The sheets and forms follow the minimal rules: no border round a card or
/// a button, no tile or disc behind an icon, no tinted pill behind a word, no
/// glow or gradient wash. A fill or ring that marks a choice is information
/// and stays. Reads the sources, like HomeMinimalTests, and names anything
/// that slips back.
final class SheetsMinimalTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// A file's source with comments stripped.
    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
    }

    /// One struct's source, from its declaration to its closing brace.
    private func source(of name: String, in path: String) throws -> String {
        let lines = try text(path).components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("struct \(name):") }) else {
            XCTFail("struct \(name) not found in \(path)")
            return ""
        }
        var depth = 0
        var opened = false
        for i in start..<lines.count {
            for ch in lines[i] {
                if ch == "{" { depth += 1; opened = true }
                if ch == "}" { depth -= 1 }
            }
            if opened && depth == 0 { return lines[start...i].joined(separator: "\n") }
        }
        return lines[start...].joined(separator: "\n")
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

    /// A shape stroked over a view: a border.
    private let border = #"\.overlay\(\s*(RoundedRectangle|Capsule|Circle)\([^)]*\)\s*\.stroke\([^\n]*"#
    /// A disc or tile filled with a faint colour, the kind put behind an icon.
    private let tile = #"(Circle\(\)|RoundedRectangle\([^)]*\))\s*\.fill\([^\n]*\.opacity\("#
    /// A faint colour behind a word.
    private let pill = #"\.opacity\([^)]*\)\s*,\s*in:\s*Capsule\(\)"#

    /// Adding and changing a transaction, confirming, deleting a card and
    /// previewing a backup: nothing drawn round or behind for show.
    func testTheSheetsCarryNoBordersTilesOrPills() throws {
        let sheets = [
            "DiPo/AddTransactionSheet.swift",
            "DiPo/TransactionDetailSheet.swift",
            "DiPo/ConfirmSheet.swift",
            "CardDeleteSheet.swift",
            "DiPo/BackupPreviewSheet.swift",
        ]
        var found: [String] = []
        for path in sheets {
            let source = try text(path)
            for (kind, pattern) in [("border", border), ("tile", tile), ("pill", pill)] {
                found += matches(pattern, in: source).map { "\(path) \(kind): \($0)" }
            }
        }
        XCTAssertTrue(found.isEmpty, "The sheets draw nothing for show:\n\(found.joined(separator: "\n"))")
    }

    /// The card form keeps one ring: the one round the colour that is chosen.
    func testTheCardFormRingsOnlyTheChoice() throws {
        let form = try source(of: "CardFormSheet", in: "CardManagementView.swift")
        let borders = matches(border, in: form).filter { !$0.contains("selected ?") }
        XCTAssertTrue(borders.isEmpty, "\(borders)")
        XCTAssertTrue(matches(tile, in: form).isEmpty, "\(matches(tile, in: form))")
        XCTAssertTrue(matches(pill, in: form).isEmpty, "\(matches(pill, in: form))")
    }

    /// The sign-in sheet shows DiPo's face, without the glow, ring and sheen.
    /// Its Apple and Google buttons keep their outlines: those are theirs.
    func testTheSignInEmblemHasNoGlow() throws {
        let sheet = try text("DiPo/ProfileSignInSheet.swift")
        XCTAssertFalse(sheet.contains("Gradient("))
        XCTAssertFalse(sheet.contains(".blur("))
    }

    /// The payday cards are plain cards; the green wash across them said
    /// nothing the figures don't.
    func testThePaydayCardsAreNotWashed() throws {
        for name in ["PaydayHeroCard", "SalaryDetailView"] {
            XCTAssertFalse(try source(of: name, in: "SalaryView.swift").contains("Gradient("), name)
        }
    }

    /// Money coming in is said by the word's colour, not a pill behind it.
    func testThePhantomIncomeMarkIsAWord() throws {
        let view = try source(of: "PhantomAutoChargesView", in: "RecurringExpense.swift")
        XCTAssertTrue(matches(pill, in: view).isEmpty)
    }

    /// Saving is the form's one action, so it is green whichever kind of
    /// transaction it is; red stays for deleting.
    func testSavingIsGreenForEitherKind() throws {
        XCTAssertTrue(try text("DiPo/AddTransactionSheet.swift").contains("canSubmit ? AppTheme.accentFill"))
        XCTAssertTrue(try text("DiPo/TransactionDetailSheet.swift").contains("canSave ? AppTheme.accentFill"))
    }
}
