import XCTest
@testable import DiPo

/// The words, read from LanguageManager.swift like SentenceCaseTests does.
final class CopyTests: XCTestCase {

    private func tables() throws -> (en: [String: String], id: [String: String]) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LanguageManager.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let split = source.range(of: "private let translationsID") else {
            XCTFail("no Indonesian table"); return ([:], [:])
        }
        let entry = try NSRegularExpression(pattern: #"^\s*"([\w.]+)"\s*:\s*"((?:\\.|[^"\\])*)""#,
                                            options: .anchorsMatchLines)
        func read(_ text: String) -> [String: String] {
            let ns = text as NSString
            var out: [String: String] = [:]
            for m in entry.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                out[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
            }
            return out
        }
        return (read(String(source[..<split.lowerBound])), read(String(source[split.lowerBound...])))
    }

    /// Every key carries the same placeholders in both languages. A sentence
    /// rewritten in one table and not the other, or a %@ lost on the way,
    /// shows up here rather than as a crash or a missing figure on screen.
    func testBothLanguagesKeepTheSamePlaceholders() throws {
        let (en, id) = try tables()
        let spec = try NSRegularExpression(pattern: #"%(\d+\$)?(@|d|lld|ld|s|\.\d+f|f|%)"#)
        func placeholders(_ s: String) -> [String] {
            let ns = s as NSString
            return spec.matches(in: s, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) }.sorted()
        }
        var mismatched: [String] = []
        for (key, english) in en {
            guard let indonesian = id[key] else { continue }
            if placeholders(english) != placeholders(indonesian) { mismatched.append(key) }
        }
        XCTAssertTrue(mismatched.isEmpty, "Placeholders differ between EN and ID: \(mismatched.sorted().joined(separator: ", "))")
    }

    /// The sentences people read most (Home, adding a transaction, Smart
    /// Budget) say one thing at a time: no clause hung off a spaced dash.
    func testTheBusiestScreensUseShortSentences() throws {
        let (en, id) = try tables()
        let keys = ["balance.review", "budget.ahead_but_over", "budget.ahead_detail", "budget.met_detail",
                    "budget.over_detail", "home.debt_note", "home.declared_auto_off", "home.over_saved",
                    "home.progress_to_go", "insight.cat_up_body", "insight.group_unbudgeted_body",
                    "insight.ratio_risky_daily_body", "insight.ratio_risky_lifestyle_body",
                    "insight.review_lifestyle_first", "insight.setaside_body", "insight.setaside_met_body",
                    "insight.spike_body", "recurring.help.bill", "recurring.help.habit", "stats.pace_over",
                    "tx.delete_goal_note"]
        for key in keys {
            XCTAssertFalse(en[key, default: ""].contains(" — "), "EN \(key)")
            XCTAssertFalse(id[key, default: ""].contains(" — "), "ID \(key)")
        }
    }

    /// Everything Smart Budget says — the screen, DiPo's tips, the warning when
    /// adding a purchase, the alert and DiPo's plan — names the three parts as
    /// the screen does. DiPo said "Lifestyle" and "Invest & Debt" beside a
    /// screen that says Wants and Savings & debt. One idea per sentence, too:
    /// no clause hung off a spaced dash, no arrows.
    func testSmartBudgetSpeaksWithTheScreensWords() throws {
        let (en, id) = try tables()
        let families = ["budget.", "insight.", "reco.", "notif.budget", "tx.budget"]
        for (key, english) in en where families.contains(where: { key.hasPrefix($0) }) {
            let indonesian = id[key, default: ""]
            for old in ["Lifestyle", "lifestyle", "Invest & Debt", "Invest & debt", "Daily needs", " — ", "→"] {
                XCTAssertFalse(english.contains(old), "EN \(key) says \"\(old)\"")
            }
            for old in ["Gaya hidup", "gaya hidup", "Gaya Hidup", "Invest & Debt", "Investasi & utang", " — ", "→"] {
                XCTAssertFalse(indonesian.contains(old), "ID \(key) says \"\(old)\"")
            }
        }
    }

    /// Lines shown as they are, not through String(format:), keep a single
    /// "%". "Pelan-pelan menabung 20%% dari pemasukan" was on screen.
    func testPlainLinesKeepASinglePercentSign() throws {
        let (en, id) = try tables()
        for key in ["reco.item.save_sub", "reco.why.saverate", "reco.invest.note"] {
            XCTAssertFalse(en[key, default: ""].contains("%%"), "EN \(key)")
            XCTAssertFalse(id[key, default: ""].contains("%%"), "ID \(key)")
        }
    }

    /// Errors say what didn't work and what to do; they don't apologise.
    func testErrorsDoNotApologise() throws {
        let (en, id) = try tables()
        for key in ["ai.error.generic", "receipt.error.generic"] {
            XCTAssertFalse(en[key, default: ""].lowercased().contains("sorry"), key)
            XCTAssertFalse(id[key, default: ""].lowercased().contains("maaf"), key)
        }
    }
}
