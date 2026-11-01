import XCTest
@testable import DiPo

/// Plan and Profile follow the minimal rules: related rows share one card,
/// an icon has no tile behind it, nothing has a border, and a locked feature
/// says Royal once — at its trailing edge — while its line says what it does.
/// Reads the sources, like ScrollWidthTests, and names anything that slips back.
@MainActor
final class MinimalListTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The files these two screens are drawn from.
    private let screens = ["PlanView.swift", "ProfileView.swift",
                           "DiPo/ProfileLinks.swift", "DiPo/ListRows.swift"]

    private func lines(of path: String) throws -> [String] {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
    }

    /// No border, no icon tile (the small radius), no glow or gradient.
    func testNoTilesBordersOrGradients() throws {
        let decoration = ["stroke(", "strokeBorder(", "AppRadius.sm", "LinearGradient", "RadialGradient"]
        var found: [String] = []
        for path in screens {
            for (i, line) in try lines(of: path).enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                for word in decoration where code.contains(word) {
                    found.append("\(path):\(i + 1) \(word)")
                }
            }
        }
        XCTAssertTrue(found.isEmpty, """
            Plan and Profile draw rows with ListRow on a ListSection, with no \
            border, tile or gradient: \(found.joined(separator: ", "))
            """)
    }

    /// "Requires Royal" in a row's line repeated the Royal mark beside it and
    /// hid what the feature does. The words are gone from both tables.
    func testLockedRowsDescribeThemselves() throws {
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                XCTAssertEqual(loc("profile.requires_royal"), "profile.requires_royal", "\(language)")
                for feature in [PremiumFeature.smartBudget, .investments, .assets] {
                    XCTAssertFalse(feature.description.isEmpty, "\(feature) in \(language)")
                    XCTAssertFalse(feature.description.contains("Royal"), "\(feature) in \(language)")
                }
                for key in ["oblig.entry_sub", "profile.ai_advisor_sub", "profile.websync_sub",
                            "profile.backtap_sub", "interest.profile_sub", "cleanup.sub"] {
                    XCTAssertNotEqual(loc(key), key, "\(key) in \(language)")
                    XCTAssertFalse(loc(key).contains("Royal"), "\(key) in \(language)")
                }
            }
        }
        for path in screens {
            let source = try lines(of: path).joined(separator: "\n")
            XCTAssertFalse(source.contains("profile.requires_royal"), path)
        }
    }

    /// Profile's groups have titles in both languages.
    func testSectionTitlesInBothLanguages() {
        for language in [LanguageManager.Language.english, .indonesian] {
            LanguageManager.shared.withLanguage(language) {
                for key in ["profile.account", "profile.section_features", "profile.section_settings",
                            "backup.section_title", "plan.section_help"] {
                    XCTAssertNotEqual(loc(key), key, "\(key) in \(language)")
                }
            }
        }
        LanguageManager.shared.withLanguage(.indonesian) {
            XCTAssertEqual(loc("profile.section_features"), "Fitur")
            XCTAssertEqual(loc("profile.section_settings"), "Pengaturan")
        }
    }

    /// Log Out is offered once, at the bottom. The account row used to carry
    /// a second one.
    func testSignOutIsOfferedOnce() throws {
        let source = try lines(of: "ProfileView.swift").joined(separator: "\n")
        XCTAssertEqual(source.components(separatedBy: "loc(\"profile.logout\")").count - 1, 1)
    }
}
