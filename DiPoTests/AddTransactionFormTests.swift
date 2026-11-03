import XCTest

/// The add-transaction form: the amount big and centred, expense or income
/// chosen in ink, then category, account, date and note as four plain rows,
/// and one green Save. Reads the sources and names anything that slips back.
final class AddTransactionFormTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
    }

    private var form: String { get throws { try text("DiPo/AddTransactionSheet.swift") } }

    func testTheKindIsChosenInInk() throws {
        let src = try form
        XCTAssertTrue(src.contains(".background(on ? AppTheme.textPrimary : Color.clear, in: Capsule())"))
        XCTAssertTrue(src.contains(".foregroundStyle(on ? AppTheme.cardDark"))
        XCTAssertFalse(src.contains("type.color"), "red or green no longer fills the chosen kind")
    }

    func testTheAmountIsBigAndCentred() throws {
        let src = try form
        XCTAssertTrue(src.contains("size: 48, weight: .bold"))
        XCTAssertTrue(src.contains(".multilineTextAlignment(.center)"))
    }

    func testOneGreenSave() throws {
        XCTAssertEqual(try form.components(separatedBy: "accentFill").count - 1, 1, "only Save is green")
    }

    func testFourRows() throws {
        let src = try form
        XCTAssertEqual(src.components(separatedBy: "TxFormRow(").count - 1, 4,
                       "category, account, date and note")
        for gone in ["CategoryTilePicker(", "IconField(", "DateTimeFields(", "FormSectionLabel("] {
            XCTAssertFalse(src.contains(gone), "\(gone) is no longer on the form")
        }
    }

    /// The rows and the sheets they open draw nothing for show; a plain fill
    /// marks the chosen category.
    func testRowsDrawNothingForShow() throws {
        let rows = try text("DiPo/AddTxRows.swift")
        XCTAssertFalse(rows.contains(".opacity("), "no faint washes")
        XCTAssertFalse(rows.contains(".stroke("), "no borders")
        XCTAssertFalse(rows.contains("AppTheme.cardDark, in:"), "no card behind a row")
    }
}
