import Foundation

extension Date {
    /// Locale-aware date string (long format: "24 April 2026")
    var displayDate: String {
        DateFormatterCache.styles(date: .long, time: .none).string(from: self)
    }
    
    /// Locale-aware abbreviated date string: "24 Apr 2026"
    var displayDateShort: String {
        DateFormatterCache.styles(date: .medium, time: .none).string(from: self)
    }
    
    /// Locale-aware short date + time: "24 Apr 2026, 12:30"
    var displayDateTimeShort: String {
        DateFormatterCache.styles(date: .medium, time: .short).string(from: self)
    }
}
