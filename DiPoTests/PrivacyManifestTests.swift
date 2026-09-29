import XCTest
@testable import DiPo

/// App Store Connect refuses (or flags) a build whose bundle calls a
/// "required reason" API without declaring it. DiPo/PrivacyInfo.xcprivacy is
/// picked up by the synchronised group, not listed in the project file, so a
/// rename or a move out of DiPo/ would drop it from the bundle silently. This
/// catches that before an upload does.
final class PrivacyManifestTests: XCTestCase {

    private func manifest() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                                "PrivacyInfo.xcprivacy is not in the app bundle")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testManifestShipsAndDeclaresNoTracking() throws {
        let m = try manifest()
        XCTAssertEqual(m["NSPrivacyTracking"] as? Bool, false)
    }

    func testRequiredReasonAPIsAreDeclared() throws {
        let types = try XCTUnwrap(manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: Set<String>] = [:]
        for t in types {
            let category = try XCTUnwrap(t["NSPrivacyAccessedAPIType"] as? String)
            reasons[category] = Set(t["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
        }
        // UserDefaults.standard everywhere, and the App Group suite shared
        // with the widget and the share extension.
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1", "1C8F.1"])
        // SharedScanInbox reads a file's modification date in the App Group.
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1"])
    }
}
