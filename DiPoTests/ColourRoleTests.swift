import XCTest

/// Where each colour goes (CLAUDE.md, "Colour use: 60/30/10"): green marks
/// what to press, and the feature and category hues only name things, on an
/// icon or a badge. Shared savings saved with a purple button, the credit
/// card form with a purple one, a notification opened its screen with a
/// purple one, so the one colour that means "press here" meant it only on
/// some screens. Reads the sources, like ScrollWidthTests, and names any
/// button or control that takes a naming hue again.
final class ColourRoleTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Hues that name a category or a feature. Red, orange and blue carry a
    /// meaning of their own and are checked where it matters, not here.
    private let naming = "purple|teal|indigo|fuchsia|amber|slate"

    /// Pictures of the app drawn for the guides: their colours copy screens.
    private let pictures: Set<String> = ["GuidePictures.swift"]

    private func sourceLines() throws -> [(file: String, line: Int, text: String)] {
        let fm = FileManager.default
        var out: [(String, Int, String)] = []
        for dir in [repoRoot, repoRoot.appendingPathComponent("DiPo")] {
            for name in try fm.contentsOfDirectory(atPath: dir.path)
            where name.hasSuffix(".swift") && !pictures.contains(name) {
                let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                    let code = raw.components(separatedBy: "//").first ?? raw
                    out.append((name, i + 1, code))
                }
            }
        }
        XCTAssertGreaterThan(Set(out.map(\.0)).count, 20, "sources not found next to the tests")
        return out
    }

    private func matches(_ pattern: String) throws -> [String] {
        let re = try NSRegularExpression(pattern: pattern)
        return try sourceLines().compactMap { file, line, text in
            let range = NSRange(text.startIndex..., in: text)
            return re.firstMatch(in: text, range: range) == nil ? nil : "\(file):\(line)"
        }
    }

    /// A solid fill in a naming hue is a button or a panel wearing a
    /// feature's colour. A faint one (a badge's wash) is still allowed.
    func testNoSolidFillInANamingHue() throws {
        let found = try matches(#"\.background\(\s*AppTheme\.(\#(naming))\b(?!\.opacity)"#)
        XCTAssertTrue(found.isEmpty, "A filled button or panel takes green or a neutral: \(found.joined(separator: ", "))")
    }

    /// "Enabled: purple, disabled: grey" is a primary button in the wrong colour.
    func testNoEnabledStateInANamingHue() throws {
        let found = try matches(#"(\.background|\.foregroundStyle)\(\s*[\w.!]+\s*\?\s*AppTheme\.(\#(naming))\s*:\s*AppTheme\.(textSecondary|cardMid)"#)
        XCTAssertTrue(found.isEmpty, "A button that turns on turns green: \(found.joined(separator: ", "))")
    }

    /// Controls (pickers, toggles, spinners) show "on" in green, or nothing.
    func testNoControlTintInANamingHue() throws {
        let found = try matches(#"\.tint\(\s*AppTheme\.(\#(naming)|blue)\b"#)
        XCTAssertTrue(found.isEmpty, "A control's tint is green: \(found.joined(separator: ", "))")
    }
}
