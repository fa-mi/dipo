import Foundation

// MARK: - Formatter cache
//
// `DateFormatter()` is one of the most expensive objects in Foundation to
// create — it builds an ICU formatter underneath — and the app was making 54 of
// them, several inside loops that run on every body evaluation. The transaction
// list allocated one PER DAY GROUP, so scrolling a list of ten days built ten
// formatters per frame.
//
// That is the "see more, then scroll" stutter: expanding the list adds groups,
// each group adds an allocation, and the allocations happen again on every
// redraw the scroll causes.
//
// Formatters are reusable and their configuration is the only thing that
// varies, so they are cached by what actually distinguishes them — the template
// and the locale. Not by call site: two screens asking for "d MMM" in the same
// locale want the same object.
enum DateFormatterCache {

    private static var cache: [String: DateFormatter] = [:]
    /// Formatters are not thread-safe to configure, so the cache is confined
    /// rather than locked — every caller here is already on the main actor.
    @MainActor
    private static func formatter(key: String, configure: (DateFormatter) -> Void) -> DateFormatter {
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.locale = LanguageManager.shared.currentLocale
        configure(f)
        cache[key] = f
        return f
    }

    /// A localised format built from a skeleton, e.g. "dMMM" or "EEEEdMMM".
    /// The template is resolved once and reused.
    @MainActor
    static func template(_ skeleton: String) -> DateFormatter {
        let locale = LanguageManager.shared.currentLocale
        return formatter(key: "t:\(skeleton):\(locale.identifier)") { f in
            f.dateFormat = DateFormatter.dateFormat(fromTemplate: skeleton, options: 0, locale: locale)
        }
    }

    /// Fixed date/time styles, for the cases that do not need a skeleton.
    @MainActor
    static func styles(date: DateFormatter.Style, time: DateFormatter.Style) -> DateFormatter {
        let locale = LanguageManager.shared.currentLocale
        return formatter(key: "s:\(date.rawValue):\(time.rawValue):\(locale.identifier)") { f in
            f.dateStyle = date
            f.timeStyle = time
        }
    }

    /// Dropped when the user switches language, so the next request rebuilds
    /// with the new locale instead of serving the old one forever.
    @MainActor
    static func invalidate() { cache.removeAll() }
}
