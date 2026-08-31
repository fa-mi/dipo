import Foundation
import EventKit

// MARK: - Indonesian Holiday Service
//
// Payday math depends on this: SalaryDateEngine walks backward off weekends and
// holidays, so a missing holiday moves real money dates. That makes the failure
// modes here more important than the happy path.
//
// What went wrong before, and what this rewrite fixes:
//
//   • The previous source (api-harilibur.vercel.app) is DEAD — it answers
//     "Payment required / DEPLOYMENT_DISABLED". Every fetch failed.
//
//   • On failure the old code marked the year as *fetched*, wrote six hardcoded
//     dates into the same cache, and saved them. On the next launch the cache
//     loader saw dates for that year and concluded it was already fetched. So
//     the app never retried — not that session, not ever. One dead endpoint
//     permanently convinced DiPo that Indonesia has six holidays a year.
//
//   • Fallback dates were indistinguishable from fetched ones, so nothing could
//     tell "we know this year" from "we gave up on this year".
//
// The structural fixes: fallback dates are COMPUTED, never cached, so they can
// never be mistaken for real data; a successful fetch is the only thing that
// marks a year confirmed; and failures retry on a backoff instead of
// surrendering.
//
// Sources, in precedence order:
//   1. the device's subscribed regional holiday calendar (EventKit) — the only
//      one that actually carries Idul Fitri, Nyepi, Waisak and the rest, and
//      the only one that maintains itself
//   2. Nager.Date over the network — alive and well-formed, but for Indonesia
//      returns only the Gregorian-fixed and Christian dates
//   3. five hardcoded fixed dates, as a floor
//
// No hand-entry step: the calendar source is what makes this automatic.
@MainActor
final class IndonesianHolidayService {

    static let shared = IndonesianHolidayService()
    private init() { loadCache() }

    // MARK: - State

    /// Dates confirmed by a successful network fetch.
    private var networkHolidays: Set<String> = []
    /// Dates read from the device's own subscribed holiday calendar. iOS keeps
    /// a regional holiday calendar per country, and for Indonesia that one DOES
    /// carry the dates no free API has: Idul Fitri, Idul Adha, Nyepi, Waisak,
    /// Maulid, plus whatever cuti bersama Apple has picked up. It is maintained
    /// for us and updates itself, which is the only way this gets to be
    /// automatic rather than something the user has to keep filling in.
    private(set) var calendarHolidays: Set<String> = []
    /// Dates the user added by hand. Authoritative — outranks the network.
    private(set) var manualHolidays: Set<String> = []
    /// Dates the user explicitly marked as ordinary working days, to undo a
    /// wrong entry from any other source. Highest precedence of all.
    private(set) var manualWorkdays: Set<String> = []

    /// Years whose data came back from a real, successful fetch. Nothing else
    /// ever writes to this — that is the whole point.
    private var confirmedYears: Set<Int> = []
    /// When we last tried each year, so failures back off rather than either
    /// hammering the network or giving up permanently.
    private var lastAttempt: [Int: Date] = [:]
    private var inFlightYears: Set<Int> = []

    private static let retryInterval: TimeInterval = 6 * 60 * 60

    // MARK: - Keys

    static func key(for date: Date) -> String {
        let cal = Calendar.current
        return String(format: "%04d-%02d-%02d",
                      cal.component(.year,  from: date),
                      cal.component(.month, from: date),
                      cal.component(.day,   from: date))
    }

    /// Accepts both "2026-01-05" and "2026-1-5". The old code assumed the API
    /// always zero-padded; an unpadded response would have silently matched
    /// nothing, since lookups are built with %02d.
    private static func normalize(_ raw: String) -> String? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    // MARK: - Fixed national holidays
    //
    // Computed on demand, never written to the cache. These five are fixed by
    // the Gregorian calendar and do not move; everything else in Indonesia does.
    private static func fixedHolidays(year: Int) -> Set<String> {
        let fixed: [(Int, Int)] = [
            (1, 1),   // Tahun Baru Masehi
            (5, 1),   // Hari Buruh
            (6, 1),   // Hari Lahir Pancasila
            (8, 17),  // Hari Kemerdekaan RI
            (12, 25), // Hari Raya Natal
        ]
        return Set(fixed.map { String(format: "%04d-%02d-%02d", year, $0.0, $0.1) })
    }

    // MARK: - Public API

    func isHoliday(_ date: Date) -> Bool {
        let key = Self.key(for: date)
        // User corrections win, in both directions, before anything else.
        if manualWorkdays.contains(key) { return false }
        if manualHolidays.contains(key) { return true }

        let year = Calendar.current.component(.year, from: date)
        scheduleFetchIfNeeded(year)

        return calendarHolidays.contains(key)
            || networkHolidays.contains(key)
            || Self.fixedHolidays(year: year).contains(key)
    }

    /// Whether this year's data came from a real fetch. False means DiPo is
    /// running on fixed dates plus whatever the user entered — callers should
    /// say so rather than present payday math as certain.
    func hasConfirmedData(for year: Int) -> Bool { confirmedYears.contains(year) }

    /// Every holiday DiPo currently believes in for a year, sorted. Powers the
    /// settings screen so the user can see exactly what payday math is using.
    func knownHolidays(year: Int) -> [String] {
        let all = networkHolidays
            .union(Self.fixedHolidays(year: year))
            .union(manualHolidays)
            .filter { $0.hasPrefix(String(format: "%04d-", year)) }
            .subtracting(manualWorkdays)
        return all.sorted()
    }

    func isManual(_ key: String) -> Bool { manualHolidays.contains(key) }

    func addManualHoliday(_ date: Date) {
        let key = Self.key(for: date)
        manualHolidays.insert(key)
        manualWorkdays.remove(key)
        saveCache()
    }

    /// Removing works for any source: a user-added date is simply dropped, and
    /// a date from the network or the fixed list is shadowed by an explicit
    /// working-day marker, since we cannot delete from those.
    func removeHoliday(_ key: String) {
        if manualHolidays.contains(key) {
            manualHolidays.remove(key)
        } else {
            manualWorkdays.insert(key)
        }
        saveCache()
    }

    /// Pre-fetch the current and next year so payday math is ready immediately.
    func prefetch() {
        let year = Calendar.current.component(.year, from: .now)
        scheduleFetchIfNeeded(year)
        scheduleFetchIfNeeded(year + 1)
        Task { await loadFromSystemCalendar() }
    }

    // MARK: - System calendar
    //
    // Read-only, and only ever from calendars the user cannot edit — the
    // subscribed regional ones. Personal events are never touched: an all-day
    // entry in someone's own calendar is a dentist appointment, not a national
    // holiday, and treating it as one would silently move their payday.
    private static let calendarSourceKey = "dipo_holidays_calendar"

    func loadFromSystemCalendar() async {
        let store = EKEventStore()
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { c in
                store.requestAccess(to: .event) { ok, _ in c.resume(returning: ok) }
            }
        }
        guard granted else {
            print("[DiPo] Calendar access not granted — holidays fall back to network + fixed")
            return
        }

        let holidayCalendars = store.calendars(for: .event).filter {
            // Subscribed and non-editable is what a shipped holiday calendar
            // looks like; a user's own calendars are always editable.
            $0.type == .subscription && !$0.allowsContentModifications
        }
        guard !holidayCalendars.isEmpty else { return }

        let cal = Calendar.current
        let year = cal.component(.year, from: .now)
        guard let from = cal.date(from: DateComponents(year: year - 1, month: 1, day: 1)),
              let to   = cal.date(from: DateComponents(year: year + 2, month: 1, day: 1)) else { return }

        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: holidayCalendars)
        let events = store.events(matching: predicate).filter(\.isAllDay)

        var found: Set<String> = []
        for e in events {
            guard let start = e.startDate else { continue }
            found.insert(Self.key(for: start))
        }
        guard !found.isEmpty else { return }

        calendarHolidays = found
        UserDefaults.standard.set(Array(found), forKey: Self.calendarSourceKey)
        print("[DiPo] Holidays from system calendar: \(found.count) dates")
    }

    /// Clears the backoff and refetches — for a manual "try again" control.
    func forceRefresh() {
        let year = Calendar.current.component(.year, from: .now)
        for y in [year, year + 1] {
            confirmedYears.remove(y)
            lastAttempt[y] = nil
            scheduleFetchIfNeeded(y)
        }
    }

    // MARK: - Fetch

    private func scheduleFetchIfNeeded(_ year: Int) {
        guard !confirmedYears.contains(year), !inFlightYears.contains(year) else { return }
        // Back off after a failure instead of retrying on every lookup — but
        // unlike before, always eventually retry.
        if let last = lastAttempt[year], Date().timeIntervalSince(last) < Self.retryInterval { return }
        inFlightYears.insert(year)
        Task { await fetchYear(year) }
    }

    private func fetchYear(_ year: Int) async {
        defer { inFlightYears.remove(year) }
        lastAttempt[year] = Date()

        let urlString = "https://date.nager.at/api/v3/PublicHolidays/\(year)/ID"
        guard let url = URL(string: urlString) else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            // The old code fed any response body straight to the decoder. A 402
            // page happened to throw, but relying on that is luck, not a check.
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                print("[DiPo] Holiday fetch \(year): HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }

            struct Item: Decodable {
                let date: String
                let global: Bool?
            }
            let items = try JSONDecoder().decode([Item].self, from: data)
            let dates = items
                .filter { $0.global ?? true }
                .compactMap { Self.normalize($0.date) }

            guard !dates.isEmpty else {
                print("[DiPo] Holiday fetch \(year): empty payload, not marking confirmed")
                return
            }

            networkHolidays.formUnion(dates)
            confirmedYears.insert(year)      // only ever set here
            saveCache()
            print("[DiPo] Holidays \(year): \(dates.count) confirmed")
        } catch {
            // No fallback write, no "fetched" marker. The year stays
            // unconfirmed and will be retried after the backoff.
            print("[DiPo] Holiday fetch \(year) failed: \(error) — will retry")
        }
    }

    // MARK: - Persistence

    private let networkKey   = "dipo_id_holidays_network"
    private let manualKey    = "dipo_id_holidays_manual"
    private let workdayKey   = "dipo_id_workdays_manual"
    private let confirmedKey = "dipo_id_holidays_confirmed_years"

    private func saveCache() {
        let d = UserDefaults.standard
        d.set(Array(networkHolidays), forKey: networkKey)
        d.set(Array(manualHolidays),  forKey: manualKey)
        d.set(Array(manualWorkdays),  forKey: workdayKey)
        d.set(Array(confirmedYears),  forKey: confirmedKey)
    }

    private func loadCache() {
        let d = UserDefaults.standard
        networkHolidays  = Set(d.stringArray(forKey: networkKey) ?? [])
        calendarHolidays = Set(d.stringArray(forKey: Self.calendarSourceKey) ?? [])
        manualHolidays  = Set(d.stringArray(forKey: manualKey)  ?? [])
        manualWorkdays  = Set(d.stringArray(forKey: workdayKey) ?? [])
        // Confirmed years are stored explicitly. Inferring them from the
        // presence of cached dates — as the old loader did — is what let six
        // fallback entries masquerade as a complete year.
        confirmedYears  = Set((d.array(forKey: confirmedKey) as? [Int]) ?? [])

        // One-time migration off the old combined cache. Those entries mixed
        // real and fallback data with no way to tell them apart, so they are
        // dropped rather than trusted; the years simply refetch.
        if d.object(forKey: "dipo_id_holidays") != nil {
            d.removeObject(forKey: "dipo_id_holidays")
            print("[DiPo] Cleared legacy holiday cache (fallback and real data were indistinguishable)")
        }
    }
}
