import UIKit

/// The app's end of "Log with DiPo" in the share sheet.
///
/// The share extension (DiPoShare/ShareViewController.swift, `ShareInbox`)
/// writes the shared image into the App Group container; this reads it back
/// and removes it. The two sides agree only on the group ID and the file path —
/// keep them in step.
enum SharedScanInbox {
    static let appGroupID = "group.com.fahmiaquinas.DiPo"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("SharedScans", isDirectory: true)
            .appendingPathComponent("shared-receipt.jpg")
    }

    /// The waiting image, if there is one, removed as it is read so a receipt
    /// can never open the review form twice.
    ///
    /// Older than `maxAge` → discarded, not shown. The inbox exists as a
    /// fallback for when the extension could not bring the app forward; a
    /// review form appearing out of nowhere a day after someone shared a photo
    /// would be more confusing than losing the hand-over.
    static func take(maxAge: TimeInterval = 60 * 60) -> UIImage? {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        if let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > maxAge {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}
