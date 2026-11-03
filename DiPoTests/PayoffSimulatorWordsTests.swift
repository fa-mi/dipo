import XCTest

/// The payoff simulator's banner says how much interest the extra payment
/// saves, then what makes the saving: paying that extra each month.
/// "You'd save %@ in interest" takes the interest saved. Filled with the extra
/// payment, it would tell the person their monthly top-up is what they save in
/// interest, which is not true. Reads the source, like SheetsMinimalTests.
final class PayoffSimulatorWordsTests: XCTestCase {

    private let path = "DiPo/DebtSheets.swift"

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The file's source with comments stripped.
    private func text() throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
    }

    /// From the line holding `opener` to the brace that closes it.
    private func block(opening opener: String, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(opener) }) else { return nil }
        var depth = 0
        var opened = false
        for i in start..<lines.count {
            for ch in lines[i] {
                if ch == "{" { depth += 1; opened = true }
                if ch == "}" { depth -= 1 }
            }
            if opened && depth == 0 { return lines[start...i].joined(separator: "\n") }
        }
        return nil
    }

    private func matches(_ pattern: String, in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range, in: source).map {
                String(source[$0]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    /// "You'd save %@ in interest" is never filled with the extra payment.
    func testInterestSavedIsNeverFilledWithTheExtraPayment() throws {
        let found = try matches(#"loc\("debt\.interest_saved"\)\s*,\s*[^\n]*\bextraPayment\b"#, in: text())
        XCTAssertTrue(found.isEmpty,
                      "debt.interest_saved is formatted with extraPayment:\n\(found.joined(separator: "\n"))")
    }

    /// The banner gives the saving, then the extra each month that makes it.
    func testTheBannerNamesTheExtraPaymentUnderTheSaving() throws {
        guard let banner = block(opening: "if interestSaved > 0 {", in: try text()) else {
            XCTFail("the interest saved banner (if interestSaved > 0 {) is not in \(path)")
            return
        }
        let saving = try matches(#"loc\("debt\.interest_saved"\)\s*,\s*fmt\(\s*interestSaved\s*\)"#, in: banner)
        let extra = try matches(#"loc\("debt\.extra_payment_count"\)\s*,\s*fmt\(\s*extraPayment\s*\)"#, in: banner)
        XCTAssertEqual(saving.count, 1, "the banner's first line is the interest saved")
        XCTAssertEqual(extra.count, 1, "the banner's second line is the extra paid each month")
    }
}
