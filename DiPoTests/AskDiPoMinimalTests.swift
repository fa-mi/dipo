import XCTest
@testable import DiPo

/// Ask DiPo without the mascot card: DiPo's notes are plain rows with an
/// orange dot, your messages are grey, his answers are plain text, and green
/// is only for Send and for adding an entry he suggests.
final class AskDiPoMinimalTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private var chat: String {
        get throws {
            try String(contentsOf: root.appendingPathComponent("AIChatView.swift"), encoding: .utf8)
                .components(separatedBy: "\n")
                .map { $0.components(separatedBy: "//").first ?? $0 }
                .joined(separator: "\n")
        }
    }

    func testANoteSplitsIntoHeadlineAndLine() {
        let note = DiPoChatNote.split("Psst… Makan naik\nMinggu ini Rp 420.000, biasanya Rp 300.000.")
        XCTAssertEqual(note.title, "Psst… Makan naik")
        XCTAssertEqual(note.body, "Minggu ini Rp 420.000, biasanya Rp 300.000.")
        XCTAssertEqual(DiPoChatNote.split("Hanya satu baris").title, "Hanya satu baris")
        XCTAssertNil(DiPoChatNote.split("Judul\n  ").body)
    }

    func testNoMascotCardOrBubbles() throws {
        let src = try chat
        XCTAssertFalse(src.contains("DiPoFrame("))
        XCTAssertFalse(src.contains("DiPoDragonView("))
        XCTAssertFalse(src.contains(".dipoBubble("))
    }

    func testGreenOnlyForSendAndAdd() throws {
        let src = try chat
        XCTAssertEqual(src.components(separatedBy: "accentFill").count - 1, 2, "Send, and Add on a suggested entry")
        XCTAssertFalse(src.contains("AppTheme.accent.opacity("), "no green washes")
    }

    func testYourMessagesAreGreyAndNothingIsOutlined() throws {
        let src = try chat
        XCTAssertTrue(src.contains(".background(AppTheme.cardMid, in: RoundedRectangle(cornerRadius: AppRadius.md))"))
        XCTAssertFalse(src.contains("Capsule().stroke("), "the suggestions carry no outline")
        XCTAssertFalse(src.contains("RoundedRectangle(cornerRadius: AppRadius.md).stroke("), "the entry card carries no border")
    }
}
