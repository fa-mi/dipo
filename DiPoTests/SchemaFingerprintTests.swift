import XCTest
import SwiftData
@testable import DiPo

/// Fails when a @Model's stored shape changes without a new schema version.
///
/// With a migration plan in place, a store whose shape matches none of the
/// plan's versions does not open — for users, that is StoreRecovery moving
/// their ledger aside. So a model change has to arrive together with a new
/// version (see DiPo/SchemaVersions.swift). This test compares the current
/// models against SchemaFingerprint.txt, committed next to it.
///
/// When it fails:
///   • you changed a @Model on purpose → follow the steps at the top of
///     SchemaVersions.swift, then delete SchemaFingerprint.txt and run the
///     tests once to record the new one. Commit it with the version.
///   • you didn't mean to → undo the model change.
@MainActor
final class SchemaFingerprintTests: XCTestCase {

    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("SchemaFingerprint.txt")
    }

    /// One line per stored property, sorted, so a diff names what changed.
    static func fingerprint(_ schema: Schema) -> String {
        var lines: [String] = []
        for entity in schema.entities {
            for a in entity.attributes {
                lines.append("\(entity.name).\(a.name): \(a.valueType)\(a.isOptional ? "?" : "")")
            }
            for r in entity.relationships {
                lines.append("\(entity.name).\(r.name) -> \(r.destination)\(r.isToOneRelationship ? "" : "[]")")
            }
        }
        return lines.sorted().joined(separator: "\n") + "\n"
    }

    func testModelsMatchTheRecordedSchema() throws {
        let current = Self.fingerprint(Schema(versionedSchema: DiPoSchemaCurrent.self))
        let fm = FileManager.default

        guard fm.fileExists(atPath: fixture.path) else {
            try current.write(to: fixture, atomically: true, encoding: .utf8)
            XCTFail("Recorded \(fixture.lastPathComponent) (\(DiPoSchemaCurrent.versionIdentifier)). Commit it; the test passes from the next run.")
            return
        }

        let recorded = try String(contentsOf: fixture, encoding: .utf8)
        guard recorded != current else { return }

        let old = Set(recorded.split(separator: "\n")), new = Set(current.split(separator: "\n"))
        let removed = old.subtracting(new).sorted().map { "  - \($0)" }
        let added = new.subtracting(old).sorted().map { "  + \($0)" }
        XCTFail("""
            The @Model shape changed without a new schema version:
            \((removed + added).joined(separator: "\n"))
            Add a schema version (DiPo/SchemaVersions.swift, steps 1–5), then re-record SchemaFingerprint.txt.
            """)
    }
}
