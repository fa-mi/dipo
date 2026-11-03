import XCTest

/// Scanning a receipt, checking what was read, the inbox of rows waiting to
/// be kept, and the voice button follow the minimal rules. The camera's own
/// overlays (dark pills over the picture, the green corner brackets) and the
/// receipt illustration stay: they are the picture, not decoration on a page.
/// Reads the sources, like SheetsMinimalTests.
final class ScanMinimalTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
    }

    private func count(_ pattern: String, in source: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
    }

    private let wash = #"\.opacity\([^)]*\)\s*,\s*in:\s*(Capsule|RoundedRectangle|Circle)"#
    private let border = #"\.overlay\(\s*(RoundedRectangle|Capsule|Circle)\([^)]*\)\s*\.stroke\("#

    /// Scan / Upload is a switch in ink; the illustration sits on the plain
    /// card, not a lilac-to-mint wash; the tip is grey words.
    func testTheLandingIsPlain() throws {
        let source = try text("ReceiptScanFlow.swift")
        XCTAssertTrue(source.contains(".background(selectedTab == tab ? AppTheme.textPrimary : Color.clear, in: Capsule())"))
        XCTAssertFalse(source.contains("#E8E4FF"))
        XCTAssertFalse(source.contains("AppTheme.accent.opacity(0.12)"))
    }

    /// The inbox's notes are orange icons with words, nothing behind; the
    /// chosen card sits on the raised fill.
    func testTheInboxDrawsNothingForShow() throws {
        let source = try text("DiPo/PendingInboxSheet.swift")
        XCTAssertEqual(try count(wash, in: source), 0, "wash")
        XCTAssertEqual(try count(border, in: source), 0, "border")
        XCTAssertTrue(source.contains("struct PendingNote: View"))
    }

    /// The dark disc over the receipt photo's zoom mark stays: it keeps the
    /// mark legible on any photo.
    func testThePreviewDrawsNothingForShow() throws {
        let source = try text("ReceiptPreviewSheet.swift")
        XCTAssertEqual(try count(#"(?<!\.black)"# + wash, in: source), 0, "wash")
        XCTAssertEqual(try count(border, in: source), 0, "border")
    }

    /// The mic button has no glow; the halo that follows the voice stays.
    func testTheMicHasNoGlow() throws {
        let source = try text("VoiceDictation.swift")
        XCTAssertFalse(source.contains(".shadow(color: (isListening ? AppTheme.redFill : AppTheme.accentFill)"))
        XCTAssertTrue(source.contains("voice.level"))
    }
}
