import Foundation

// MARK: - Indonesian Holiday Service
//
// Fetches official Indonesian public holidays from api-harilibur.vercel.app (free, no auth).
// Results are cached in UserDefaults so the app works fully offline after first fetch.
// SalaryDateEngine calls isHoliday(_:) which uses cached data + falls back to hardcoded minimums.

@MainActor
final class IndonesianHolidayService {

    static let shared = IndonesianHolidayService()
    private init() { loadCache() }

    // MARK: - State

    private var cachedHolidays: Set<String> = []   // "YYYY-MM-DD"
    private var fetchedYears:   Set<Int>    = []
    /// Years currently in flight. Without this, calling `isHoliday(...)` for
    /// many dates in the same render frame spawns N parallel fetches for the
    /// same year — the `fetchedYears` guard inside `fetchYear` only kicks in
    /// AFTER the first fetch completes. Tracking in-flight at the call site
    /// dedupes synchronously.
    private var inFlightYears: Set<Int>     = []

    // MARK: - Public API

    /// Returns true if the given date is an Indonesian public holiday.
    /// Uses cached data; fetches in background if year not yet loaded.
    func isHoliday(_ date: Date) -> Bool {
        let cal  = Calendar.current
        let year = cal.component(.year,  from: date)
        let mm   = cal.component(.month, from: date)
        let dd   = cal.component(.day,   from: date)
        let key  = String(format: "%04d-%02d-%02d", year, mm, dd)

        // Trigger background fetch only if no fetch has started or completed
        // for this year yet. Combined check (`fetched ∪ inFlight`) protects
        // against the duplicate-Task explosion described above.
        if !fetchedYears.contains(year), !inFlightYears.contains(year) {
            inFlightYears.insert(year)
            Task { await fetchYear(year) }
        }

        return cachedHolidays.contains(key)
    }

    /// Pre-fetch current + next year on app launch so data is ready immediately.
    func prefetch() {
        let year = Calendar.current.component(.year, from: .now)
        for y in [year, year + 1] where !fetchedYears.contains(y) && !inFlightYears.contains(y) {
            inFlightYears.insert(y)
            Task { await fetchYear(y) }
        }
    }

    // MARK: - Fetch

    private func fetchYear(_ year: Int) async {
        // Always clear the in-flight flag at the end so a transient error
        // doesn't lock this year out forever. `fetchedYears` is the
        // authoritative "done" marker.
        defer { inFlightYears.remove(year) }
        guard !fetchedYears.contains(year) else { return }

        let urlString = "https://api-harilibur.vercel.app/api?year=\(year)"
        guard let url = URL(string: urlString) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            struct HolidayItem: Decodable {
                let holiday_date:        String
                let is_national_holiday: Bool
            }

            let items = try JSONDecoder().decode([HolidayItem].self, from: data)
            let dates = items
                .filter { $0.is_national_holiday }
                .map    { $0.holiday_date }         // already "YYYY-MM-DD"

            cachedHolidays.formUnion(dates)
            fetchedYears.insert(year)
            saveCache()

            print("[DiPo] Loaded \(dates.count) Indonesian holidays for \(year)")
        } catch {
            print("[DiPo] Holiday fetch failed for \(year): \(error) — using fallback")
            // Mark as "fetched" so we don't retry endlessly on bad network
            fetchedYears.insert(year)
            // Inject fallback fixed holidays so payday logic still works
            applyFallback(year: year)
        }
    }

    // MARK: - Fallback (fixed holidays that never change)
    // Only used if API fails AND no cache exists for that year.

    private func applyFallback(year: Int) {
        let fixed: [(Int, Int)] = [
            (1, 1),   // Tahun Baru Masehi
            (5, 1),   // Hari Buruh
            (6, 1),   // Hari Lahir Pancasila
            (8, 17),  // Hari Kemerdekaan RI
            (12, 25), // Natal
            (12, 26), // Cuti Bersama Natal
        ]
        for (m, d) in fixed {
            cachedHolidays.insert(String(format: "%04d-%02d-%02d", year, m, d))
        }
        saveCache()
    }

    // MARK: - Persistence

    private let cacheKey = "dipo_id_holidays"

    private func saveCache() {
        let array = Array(cachedHolidays)
        UserDefaults.standard.set(array, forKey: cacheKey)
    }

    private func loadCache() {
        if let saved = UserDefaults.standard.stringArray(forKey: cacheKey) {
            cachedHolidays = Set(saved)
            // Mark years already in cache as fetched so we skip re-fetching
            for key in saved {
                if let yearStr = key.split(separator: "-").first,
                   let year = Int(yearStr) {
                    fetchedYears.insert(year)
                }
            }
        }
    }
}
