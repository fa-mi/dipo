import Foundation

// MARK: - Is the notification automation working?
//
// The automation is built in Shortcuts, out of DiPo's sight, and a payment can
// take days to arrive; until one does, nobody can tell whether the setup took.
// So the action leaves a note each time it runs (LogFromNotificationIntent):
// when, from which app, whether it was a payment, and whether the Title and
// App blanks arrived filled. Never what the notification said: a code must
// not be kept even in part. The Tap to Log guide reads the note back.

struct NotificationAutomationStatus: Codable, Equatable {
    var heardAt: Date
    /// The app as the automation named it; nil when the App blank was empty.
    var app: String?
    var hadTitle: Bool
    /// A payment, now waiting under Review; false for anything skipped.
    var kept: Bool

    private static let key = "notificationAutomation.lastHeard"

    static func record(app: String?, title: String?, kept: Bool, at date: Date = .now,
                       in defaults: UserDefaults = .standard) {
        let note = NotificationAutomationStatus(heardAt: date, app: filled(app),
                                                hadTitle: filled(title) != nil, kept: kept)
        if let data = try? JSONEncoder().encode(note) { defaults.set(data, forKey: key) }
    }

    static func last(in defaults: UserDefaults = .standard) -> NotificationAutomationStatus? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    /// What the guide says: whether it has run, when and from which app,
    /// what came of it, and which blank still needs filling.
    static func message(for note: NotificationAutomationStatus?, now: Date = .now) -> String {
        guard let note else { return loc("notifstatus.never") }
        let when = relative(note.heardAt, now: now)
        var lines = [note.app.map { String(format: loc("notifstatus.heard_app"), $0, when) }
                     ?? String(format: loc("notifstatus.heard"), when)]
        lines.append(loc(note.kept ? "notifstatus.kept" : "notifstatus.skipped"))
        switch (note.hadTitle, note.app != nil) {
        case (false, false): lines.append(loc("notifstatus.missing_both"))
        case (false, true): lines.append(loc("notifstatus.missing_title"))
        case (true, false): lines.append(loc("notifstatus.missing_app"))
        case (true, true): break
        }
        return lines.joined(separator: " ")
    }

    /// Whether the note asks for something to be fixed.
    var isMissingABlank: Bool { !hadTitle || app == nil }

    private static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return loc("notifstatus.just_now") }
        let f = RelativeDateTimeFormatter()
        f.locale = LanguageManager.shared.currentLocale
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }

    private static func filled(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
