import XCTest
@testable import DiPo

/// Labels are written in sentence case. A heading in capitals ("WHAT GOES
/// WITH IT") is harder to read than the same words in sentence case, and
/// shouting labels were the commonest leftover of a template look. Reads the
/// sources, like UserFacingErrorTests, and names anything that slips back.
final class SentenceCaseTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Short codes that are capitals in their own right.
    private let capitalsByNature: Set<String> = [
        "store_recovery.ok",         // OK
        "asset.tax.pbb",             // PBB, a tax's name
        "planner.row_jht",           // BPJS JHT (2%)
        "planner.row_jp",            // BPJS JP (1%)
        "invest.field.symbol_ph_us", // ticker symbols
        "unity.dipo_id_ph",          // an example DiPo ID
    ]

    func testNoLabelIsWrittenInCapitals() throws {
        let source = try String(contentsOf: root.appendingPathComponent("LanguageManager.swift"), encoding: .utf8)
        let entry = try NSRegularExpression(pattern: #"^\s*"([\w.]+)"\s*:\s*"((?:\\.|[^"\\])*)""#,
                                            options: .anchorsMatchLines)
        let format = try NSRegularExpression(pattern: #"%(\d+\$)?(@|d|lld|s|\.\d+f|f)"#)
        var offenders: [String] = []
        let ns = source as NSString
        for m in entry.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1))
            guard !capitalsByNature.contains(key) else { continue }
            var value = ns.substring(with: m.range(at: 2))
            value = format.stringByReplacingMatches(in: value, range: NSRange(location: 0, length: (value as NSString).length),
                                                    withTemplate: " ")
            let words = value.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 2 }
            if !words.isEmpty, words.allSatisfy({ $0 == $0.uppercased() && $0 != $0.lowercased() }) {
                offenders.append(key)
            }
        }
        XCTAssertTrue(offenders.isEmpty, "Write these in sentence case: \(offenders.joined(separator: ", "))")
    }

    /// The same, done in code: `.uppercased()` on a label or `.textCase(.uppercase)`.
    /// Initials (`prefix(…)`) and the month over a calendar day are fine.
    func testNoViewUppercasesALabel() throws {
        var offenders: [String] = []
        for dir in [root, root.appendingPathComponent("DiPo")] {
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
                let lines = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                    .components(separatedBy: "\n")
                for (i, line) in lines.enumerated() {
                    let code = line.components(separatedBy: "//").first ?? line
                    let shouts = code.contains(".textCase(.uppercase)")
                        || ((code.contains("Text(") || code.contains("Label(")) && code.contains(".uppercased()"))
                    guard shouts, !code.contains("prefix("), !code.contains("SalaryFormat.date(") else { continue }
                    offenders.append("\(name):\(i + 1)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "Keep labels in sentence case: \(offenders.joined(separator: ", "))")
    }
}
