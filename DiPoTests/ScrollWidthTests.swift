import XCTest

/// A vertical ScrollView still scrolls sideways once its content is wider
/// than its bounds, so one wide child (a long translated line, a big Dynamic
/// Type size, an unbreakable email address) lets the whole page slide left.
/// That shipped on Full analysis. Every vertical ScrollView in the app clamps
/// its column with `.containerRelativeFrame(.horizontal)`, which makes the
/// children compress instead; this reads the sources and names any that don't.
final class ScrollWidthTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func sources() throws -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        for dir in [repoRoot, repoRoot.appendingPathComponent("DiPo")] {
            let names = try fm.contentsOfDirectory(atPath: dir.path)
            files += names.filter { $0.hasSuffix(".swift") }.map { dir.appendingPathComponent($0) }
        }
        return files
    }

    func testVerticalScrollViewsClampTheirWidth() throws {
        let opener = try NSRegularExpression(pattern: #"\bScrollView(\s*\(([^)]*)\))?\s*\{\s*$"#)
        let files = try sources()
        XCTAssertGreaterThan(files.count, 20, "sources not found next to the tests")

        var unclamped: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard let m = opener.firstMatch(in: line, range: range) else { continue }
                if let args = Range(m.range(at: 2), in: line), line[args].contains(".horizontal") { continue }
                let indent = line.prefix { $0 == " " }.count
                // The ScrollView's closing brace sits at its own indent.
                guard let end = lines[(i + 1)...].firstIndex(where: {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix("}")
                        && $0.prefix { $0 == " " }.count == indent
                }) else { continue }
                if !lines[(i + 1)..<end].contains(where: { $0.contains("containerRelativeFrame(.horizontal)") }) {
                    unclamped.append("\(file.lastPathComponent):\(i + 1)")
                }
            }
        }
        XCTAssertTrue(unclamped.isEmpty, """
            These vertical ScrollViews can slide sideways. Add \
            .containerRelativeFrame(.horizontal) to the column inside each: \
            \(unclamped.joined(separator: ", "))
            """)
    }
}
