import XCTest
@testable import DiPo

/// Which automatic copies survive. The rule has to keep recent copies AND
/// reach back weeks, because a quiet loss shows up in every daily copy
/// taken after it.
@MainActor
final class AutoBackupTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    /// One copy per day, `days` days back, newest first.
    private func daily(_ days: Int) -> [AutoBackup.Entry] {
        (0..<days).map { d in
            AutoBackup.Entry(url: URL(fileURLWithPath: "/tmp/copy-\(d).json"),
                             date: now.addingTimeInterval(-Double(d) * day - 60),
                             reason: .daily)
        }
    }

    func testKeepsThreeNewestAndOnePerWeekForFourWeeks() {
        let entries = daily(40)
        let kept = AutoBackup.kept(entries, now: now)
        // Days 0,1,2 (newest) + the newest in weeks 1,2,3 (days 7,14,21).
        let expected = Set([0, 1, 2, 7, 14, 21].map { entries[$0].url })
        XCTAssertEqual(kept, expected)
    }

    func testNothingOlderThanFourWeeksSurvivesOnceNewerCopiesExist() {
        let kept = AutoBackup.kept(daily(40), now: now)
        XCTAssertFalse(kept.contains(URL(fileURLWithPath: "/tmp/copy-35.json")))
    }

    func testAFewCopiesAreAllKept() {
        let entries = daily(3)
        XCTAssertEqual(AutoBackup.kept(entries, now: now), Set(entries.map(\.url)))
    }

    func testAnOldOnlyCopyIsKeptWhileItIsTheNewest() {
        // A user who stopped opening the app: their one copy is two months
        // old. It is still among the three newest, so it stays.
        let old = AutoBackup.Entry(url: URL(fileURLWithPath: "/tmp/old.json"),
                                   date: now.addingTimeInterval(-60 * day), reason: .daily)
        XCTAssertEqual(AutoBackup.kept([old], now: now), [old.url])
    }
}
