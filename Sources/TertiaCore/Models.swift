import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct Club: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let shortCode: String

    public init(id: Int, name: String, shortCode: String) {
        self.id = id; self.name = name; self.shortCode = shortCode
    }

    public static let defaultClubs: [Club] = [
        Club(id: 199, name: "Battersea", shortCode: "BAT"),
        Club(id: 39, name: "Canary Wharf", shortCode: "CANARY"),
        Club(id: 220, name: "Chelsea", shortCode: "CHE"),
        Club(id: 43, name: "City", shortCode: "CITY"),
        Club(id: 201, name: "Clapham Junction", shortCode: "CLJ"),
        Club(id: 123, name: "Islington", shortCode: "ISL"),
        Club(id: 51, name: "Marylebone", shortCode: "MA"),
        Club(id: 171, name: "Mayfair", shortCode: "MAYFAIR"),
        Club(id: 177, name: "Moorgate", shortCode: "MOORGATE"),
        Club(id: 221, name: "Paternoster Square", shortCode: "PAT"),
        Club(id: 222, name: "Queens Park", shortCode: "QPR"),
        Club(id: 218, name: "Richmond", shortCode: "RMD"),
        Club(id: 52, name: "Soho", shortCode: "SOHO"),
        Club(id: 219, name: "The Whiteley", shortCode: "TWH"),
        Club(id: 63, name: "Tower Bridge", shortCode: "TOWER"),
        Club(id: 187, name: "Wimbledon", shortCode: "WIMB"),
        Club(id: 200, name: "Wood Wharf", shortCode: "WW"),
    ]
}

public struct ClassSession: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let date, startTime, endTime, title, trainer, clubName: String
    public let durationMinutes: Int

    public init(id: Int, date: String, startTime: String, endTime: String, durationMinutes: Int, title: String, trainer: String, clubName: String) {
        self.id = id; self.date = date; self.startTime = startTime; self.endTime = endTime
        self.durationMinutes = durationMinutes; self.title = title; self.trainer = trainer; self.clubName = clubName
    }
}

public enum SchedulePeriod: String, CaseIterable, Codable, Hashable, Sendable {
    case all, morning, afternoon, evening

    public var label: String {
        switch self { case .all: "All Day"; case .morning: "Morning"; case .afternoon: "Afternoon"; case .evening: "Evening" }
    }

    public var shortLabel: String {
        switch self { case .all: "All"; case .morning: "AM"; case .afternoon: "PM"; case .evening: "Eve" }
    }
}

public enum BookingWindowStatus: Hashable, Sendable {
    case started, open, openingSoon(String), upcoming(String), invalidTime

    public var badgeLabel: String {
        switch self {
        case .started: "STARTED"
        case .open: "48H OPEN"
        case .invalidTime: "UNAVAILABLE"
        case .openingSoon(let label), .upcoming(let label): label
        }
    }
}

public struct TertiaPreferences: Codable, Hashable, Sendable {
    public var clubId: Int
    public var clubName, clubShortCode, searchQuery: String
    public var period: SchedulePeriod

    public init(clubId: Int = 39, clubName: String = "Canary Wharf", clubShortCode: String = "CANARY", period: SchedulePeriod = .all, searchQuery: String = "") {
        self.clubId = clubId; self.clubName = clubName; self.clubShortCode = clubShortCode
        self.period = period; self.searchQuery = searchQuery
    }

    /// Keeps the selected club inside the signed-in account's timetable clubs (home club first when realigning).
    public func alignment(for session: MemberSession, catalog: [Club]) -> ClubAlignment {
        let allowed = session.entitledClubs(from: catalog)
        guard let target = allowed.first(where: { $0.id == session.homeClubId }) ?? allowed.first else { return .noneEntitled }
        if allowed.contains(where: { $0.id == clubId }) { return .unchanged }
        var next = self
        next.clubId = target.id; next.clubName = target.name; next.clubShortCode = target.shortCode
        return .realigned(next)
    }
}

public enum ClubAlignment: Equatable, Sendable {
    case unchanged
    case realigned(TertiaPreferences)
    case noneEntitled
}

public struct TimetableSnapshot: Codable, Hashable, Sendable {
    public let clubs: [Club]
    public let clubId: Int
    public let clubName, clubShortCode: String
    public let days: [String: [ClassSession]]
    public let syncedAt: Date
    /// When each London date was last fetched; legacy snapshots decode as `[:]` and count as stale.
    public let daySyncedAt: [String: Date]
    /// Request number (`SharedStateStore.reserveSnapshotSequence`) that produced each date; `[:]` in legacy files.
    public let dayRevision: [String: UInt64]
    /// Request number that last wrote `clubName`, `clubShortCode`, and `clubs`; `0` in legacy files.
    public let metaRevision: UInt64
    /// When `clubName`, `clubShortCode`, and `clubs` were last written (never in the future), comparable between the host
    /// and widget copies, which number requests with separate counters; legacy files decode it as `syncedAt`.
    public let metaUpdatedAt: Date

    public init(clubs: [Club], clubId: Int, clubName: String, clubShortCode: String, days: [String: [ClassSession]], syncedAt: Date, daySyncedAt: [String: Date] = [:],
                dayRevision: [String: UInt64] = [:], metaRevision: UInt64 = 0, metaUpdatedAt: Date? = nil) {
        self.clubs = clubs; self.clubId = clubId; self.clubName = clubName
        self.clubShortCode = clubShortCode; self.days = days; self.syncedAt = syncedAt; self.daySyncedAt = daySyncedAt; self.dayRevision = dayRevision
        self.metaRevision = metaRevision; self.metaUpdatedAt = metaUpdatedAt ?? syncedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clubs = try c.decode([Club].self, forKey: .clubs)
        clubId = try c.decode(Int.self, forKey: .clubId)
        clubName = try c.decode(String.self, forKey: .clubName)
        clubShortCode = try c.decode(String.self, forKey: .clubShortCode)
        days = try c.decode([String: [ClassSession]].self, forKey: .days)
        syncedAt = try c.decode(Date.self, forKey: .syncedAt)
        daySyncedAt = try c.decodeIfPresent([String: Date].self, forKey: .daySyncedAt) ?? [:]
        dayRevision = try c.decodeIfPresent([String: UInt64].self, forKey: .dayRevision) ?? [:]
        metaRevision = try c.decodeIfPresent(UInt64.self, forKey: .metaRevision) ?? 0
        metaUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .metaUpdatedAt) ?? syncedAt
    }

    /// How a class ID resolves across every stored day: a row counts only under its own date key, and two different
    /// placements of one ID anywhere (another row, or the same row under another date) make it ambiguous.
    public enum SessionLookup: Equatable, Sendable { case missing, unique(ClassSession), ambiguous }

    public func lookupSession(id: Int) -> SessionLookup { lookupIndex[id] ?? .missing }

    /// The day's rows stored under their own date whose ID resolves to exactly that row (`session(id:)` returns each of
    /// them), with exact repeats collapsed, so the list never offers an action `session(id:)` would refuse.
    public func classes(for dateIso: String) -> [ClassSession] {
        let index = lookupIndex
        var emitted = Set<Int>()
        return (days[dateIso] ?? []).filter { $0.date == dateIso && index[$0.id] == .unique($0) && emitted.insert($0.id).inserted }
    }
    /// The one row with `id` (`lookupSession(id:) == .unique`); `nil` when missing, misplaced, or ambiguous.
    public func session(id: Int) -> ClassSession? { if case .unique(let row) = lookupSession(id: id) { row } else { nil } }

    private struct Placement: Hashable { let day: String; let row: ClassSession }
    /// One pass over every positive-ID row: a single placement under its own date is unique, a single misplaced one is
    /// missing, and more than one distinct placement is ambiguous.
    private var lookupIndex: [Int: SessionLookup] {
        var placements: [Int: Set<Placement>] = [:]
        for (day, rows) in days { for row in rows where row.id > 0 { placements[row.id, default: []].insert(Placement(day: day, row: row)) } }
        return placements.mapValues { set in
            guard set.count == 1, let only = set.first else { return .ambiguous }
            return only.row.date == only.day ? .unique(only.row) : .missing
        }
    }
    /// `true` when `dateIso` was fetched (possibly empty); `false` means the date is missing, not class-free.
    public func hasCachedDay(_ dateIso: String) -> Bool { days[dateIso] != nil }
    public func syncedAt(for dateIso: String) -> Date? { daySyncedAt[dateIso] }
}

public struct MemberSession: Codable, Equatable, Sendable {
    public let token, name, email, homeClubName, expiresAt: String
    public let id, homeClubId: Int
    public let clubs: [Club]

    enum CodingKeys: String, CodingKey {
        case token, id, name, email, homeClubId, homeClubName, expiresAt, clubs
    }

    public init(token: String, id: Int, name: String, email: String, homeClubId: Int, homeClubName: String, expiresAt: String, clubs: [Club] = []) {
        self.token = token; self.id = id; self.name = name; self.email = email
        self.homeClubId = homeClubId; self.homeClubName = homeClubName; self.expiresAt = expiresAt; self.clubs = clubs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        email = try c.decode(String.self, forKey: .email)
        homeClubId = try c.decode(Int.self, forKey: .homeClubId)
        homeClubName = try c.decode(String.self, forKey: .homeClubName)
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
        clubs = try c.decodeIfPresent([Club].self, forKey: .clubs) ?? []
    }

    /// Stable account identity binding cached bookings to their member; `nil` when there is neither an ID nor an email.
    public var ownerKey: String? {
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id > 0 ? "id:\(id)" : mail.isEmpty ? nil : "email:\(mail)"
    }

    /// One-way hash of `ownerKey` for the widget mirror, so raw emails never leave the primary store.
    public var opaqueOwnerId: String? { ownerKey.map(Self.opaqueId) }

    public static func opaqueId(_ ownerKey: String) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(ownerKey.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        // Deterministic non-cryptographic fallback: four FNV-1a 64-bit lanes (256 bits of hex).
        return (0..<4).map { (lane: UInt64) -> String in
            let hash = ownerKey.utf8.reduce(0xcbf29ce484222325 ^ lane) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
            return String(format: "%016llx", hash)
        }.joined()
        #endif
    }

    public var firstName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? (email.isEmpty ? "Account" : email)
    }

    /// Timetable clubs this member may use: home and membership clubs found in `catalog` (membership-only venues
    /// without a public timetable are dropped, and no match means no clubs).
    public func entitledClubs(from catalog: [Club]) -> [Club] {
        let ids = Set(([homeClubId] + clubs.map(\.id)).filter { $0 > 0 })
        return catalog.filter { ids.contains($0.id) }
    }
}

public struct MemberBooking: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let title, startDate, clubName, trainerName, eventAction: String
    public let waitListPosition: Int?

    public init(id: Int, title: String, startDate: String, clubName: String, trainerName: String, eventAction: String, waitListPosition: Int? = nil) {
        self.id = id; self.title = title; self.startDate = startDate
        self.clubName = clubName; self.trainerName = trainerName; self.eventAction = eventAction; self.waitListPosition = waitListPosition
    }

    /// A confirmed booking (the API offers `cancel` as its next action; waitlist entries offer something else).
    public var isActive: Bool { eventAction.caseInsensitiveCompare("cancel") == .orderedSame }
}

public struct BookingsSnapshot: Codable, Equatable, Sendable {
    /// `MemberSession.ownerKey` of the account that fetched these bookings (required: ownerless legacy files never load).
    public let ownerKey: String
    public let bookings: [MemberBooking]
    public let syncedAt: Date
    /// Account revision this snapshot was committed with; it is valid only while `account.json` carries the same
    /// revision. Legacy files decode as `0`.
    public let revision: UInt64
    /// `MemberSession.opaqueId` of the session token that fetched these bookings (primary `bookings.json` only), so a
    /// replaced credential of the same member never inherits them. Legacy files decode as `""`.
    public let sessionTokenDigest: String

    public init(ownerKey: String, bookings: [MemberBooking], syncedAt: Date, revision: UInt64 = 0, sessionTokenDigest: String = "") {
        self.ownerKey = ownerKey; self.bookings = bookings; self.syncedAt = syncedAt; self.revision = revision; self.sessionTokenDigest = sessionTokenDigest
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ownerKey = try c.decode(String.self, forKey: .ownerKey)
        bookings = try c.decode([MemberBooking].self, forKey: .bookings)
        syncedAt = try c.decode(Date.self, forKey: .syncedAt)
        revision = try c.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        sessionTokenDigest = try c.decodeIfPresent(String.self, forKey: .sessionTokenDigest) ?? ""
    }

    public var bookedIds: Set<Int> {
        Set(bookings.filter(\.isActive).map(\.id))
    }

    /// What the active entries for one class ID say about its start.
    public enum ActiveStart: Equatable, Sendable {
        /// No active entry.
        case missing
        /// Every active entry has an empty stamp (the public timetable row decides).
        case empty
        /// Every active entry resolves the same way (one exact instant, the repeated hour, or a single invalid stamp).
        case resolved(WallTimeResolution)
        /// Active entries disagree (different instants, empty mixed with set stamps, or several invalid stamps).
        case conflicting
    }

    /// Reads every active entry for `classId`, so the result never depends on the order the API listed duplicates in.
    public func activeStart(classId: Int) -> ActiveStart { Self.resolveActiveStart(activeEntries(classId: classId)) }

    /// How a group of active entries for one class ID resolves (`.missing` when empty).
    public static func resolveActiveStart(_ entries: [MemberBooking]) -> ActiveStart {
        let stamps = entries.map { $0.startDate.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !stamps.isEmpty else { return .missing }
        if stamps.allSatisfy(\.isEmpty) { return .empty }
        guard !stamps.contains(where: \.isEmpty) else { return .conflicting }
        let resolutions = stamps.map(LondonCalendar.parseBookingStart)
        guard resolutions.allSatisfy({ $0 == resolutions[0] }), resolutions[0] != .invalid || resolutions.count == 1 else { return .conflicting }
        return .resolved(resolutions[0])
    }

    /// Exact start of each active booking whose active entries all agree on one instant (one pass over the bookings).
    public var activeBookingStarts: [Int: Date] {
        Dictionary(grouping: bookings.filter(\.isActive), by: \.id).reduce(into: [:]) { starts, group in
            if case .resolved(.exact(let start)) = Self.resolveActiveStart(group.value) { starts[group.key] = start }
        }
    }

    /// The agreed non-empty trimmed title of the active entries for `classId` (`nil` when missing, empty, or disagreeing).
    public func activeTitle(classId: Int) -> String? {
        let titles = Set(activeEntries(classId: classId).map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard titles.count == 1, let title = titles.first, !title.isEmpty else { return nil }
        return title
    }

    /// Whether this member's active booking of `row.id` is the class shown in `row` (viewed club `clubId`/`clubName`):
    /// the active entries must agree on their start and club, a named club must be the row's or viewed club, an unnamed
    /// one needs the ID to resolve uniquely to this row and club (`lookup`), and an exact start must fall on the row's
    /// London date. So a booking at one club never marks a same-ID class at another club, or on another day, as booked.
    public func matchesDisplayedRow(_ row: ClassSession, clubId: Int, clubName: String, lookup: SharedStateStore.EntitledClassLookup) -> Bool {
        let entries = activeEntries(classId: row.id)
        guard !entries.isEmpty else { return false }
        let start = Self.resolveActiveStart(entries)
        guard start != .conflicting else { return false }
        guard let bookedClub = agreedActiveClub(classId: row.id) else { return false }
        if bookedClub.isEmpty {
            guard lookup == .unique(session: row, clubId: clubId) else { return false }
        } else if bookedClub.caseInsensitiveCompare(clubName) != .orderedSame && bookedClub.caseInsensitiveCompare(row.clubName) != .orderedSame {
            return false
        }
        if case .resolved(.exact(let instant)) = start { return LondonCalendar.londonTodayIso(now: instant) == row.date }
        return true
    }

    /// The active (confirmed) entries for `classId`, in API order.
    public func activeEntries(classId: Int) -> [MemberBooking] { bookings.filter { $0.id == classId && $0.isActive } }

    /// The trimmed club name every active entry for `classId` agrees on (case-insensitively; `""` when all are unnamed),
    /// or `nil` when there is no active entry or the entries name different clubs.
    public func agreedActiveClub(classId: Int) -> String? {
        let clubs = activeEntries(classId: classId).map { $0.clubName.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = clubs.first, Set(clubs.map { $0.lowercased() }).count == 1 else { return nil }
        return first
    }

    /// `[row.id: start]` for each row this member's booking matches (`matchesDisplayedRow`) whose active entries agree on
    /// one exact start, so a booking at one club never keeps a same-ID row of another club or day on screen.
    public func matchedRowStarts(for rows: [ClassSession], clubId: Int, clubName: String, lookup: (Int) -> SharedStateStore.EntitledClassLookup) -> [Int: Date] {
        rows.reduce(into: [:]) { starts, row in
            guard case .resolved(.exact(let start)) = activeStart(classId: row.id),
                  matchesDisplayedRow(row, clubId: clubId, clubName: clubName, lookup: lookup(row.id)) else { return }
            starts[row.id] = start
        }
    }
}

public struct DateEntry: Hashable, Sendable, Identifiable {
    public let iso, weekday, dayNumber: String
    public var id: String { iso }
}

public enum LondonCalendar {
    public static let timeZone = TimeZone(identifier: "Europe/London") ?? .gmt

    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = timeZone
        fmt.locale = Locale(identifier: "en_GB")
        fmt.dateFormat = format
        return fmt
    }

    public static func londonTodayIso(now: Date = Date()) -> String { formatter("yyyy-MM-dd").string(from: now) }
    public static func formatSyncTime(_ date: Date) -> String { formatter("HH:mm").string(from: date) }
    public static func formatWeekdayTime(_ date: Date) -> String { formatter("EEE HH:mm").string(from: date) }

    public static func addDays(to dateIso: String, days: Int) -> String? {
        guard let parsed = parseIsoDate(dateIso),
              let next = calendar.date(byAdding: .day, value: days, to: parsed)
        else { return nil }
        return formatter("yyyy-MM-dd").string(from: next)
    }

    public static func dateStrip(days: Int = 10, now: Date = Date()) -> [DateEntry] {
        guard days > 0 else { return [] }
        guard let todayDate = parseIsoDate(londonTodayIso(now: now)) else { return [] }
        let weekdayFmt = formatter("EEE"), dayFmt = formatter("dd"), isoFmt = formatter("yyyy-MM-dd")
        return (0..<days).compactMap { offset in
            guard let dt = calendar.date(byAdding: .day, value: offset, to: todayDate) else { return nil }
            return DateEntry(iso: isoFmt.string(from: dt), weekday: weekdayFmt.string(from: dt).uppercased(), dayNumber: dayFmt.string(from: dt))
        }
    }

    public static func parseIsoDate(_ dateIso: String) -> Date? { londonWallDate(dateIso: dateIso, hhmm: "12:00") }

    /// `H:mm`, `HH:mm`, `H:mm:ss`, or `HH:mm:ss` (ASCII digits only, no extra fields or suffixes).
    public static func parseWallTime(_ raw: String) -> (hour: Int, minute: Int, second: Int)? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        let widths = [1...2, 2...2, 2...2]
        guard (2...3).contains(parts.count),
              zip(parts, widths).allSatisfy({ part, width in width.contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber } }),
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m),
              let s = parts.count == 3 ? Int(parts[2]) : 0, (0...59).contains(s)
        else { return nil }
        return (h, m, s)
    }

    public static func secondsOfDay(_ raw: String) -> Int? { parseWallTime(raw).map { $0.hour * 3600 + $0.minute * 60 + $0.second } }

    /// London wall-clock instant (seconds kept); `nil` for invalid input or times skipped by the spring-forward gap.
    /// A repeated autumn time returns its first occurrence; use `resolveLondonWallTime` to detect that case.
    public static func londonWallDate(dateIso: String, hhmm: String) -> Date? {
        let dParts = dateIso.split(separator: "-", omittingEmptySubsequences: false)
        guard dateIso.count == 10, dParts.count == 3,
              let y = Int(dParts[0]), y >= 2000,
              let mo = Int(dParts[1]), (1...12).contains(mo),
              let d = Int(dParts[2]), (1...31).contains(d),
              let t = parseWallTime(hhmm)
        else { return nil }
        let comps = DateComponents(timeZone: timeZone, year: y, month: mo, day: d, hour: t.hour, minute: t.minute, second: t.second)
        guard let dt = calendar.date(from: comps),
              formatter(wallFormat).string(from: dt) == dateIso + String(format: " %02d:%02d:%02d", t.hour, t.minute, t.second)
        else { return nil }
        return dt
    }

    private static let wallFormat = "yyyy-MM-dd HH:mm:ss"

    /// Exact instant for a London wall time, or why it has none (spring gap, or the repeated BST to GMT hour).
    public static func resolveLondonWallTime(dateIso: String, hhmm: String) -> WallTimeResolution {
        guard let dt = londonWallDate(dateIso: dateIso, hhmm: hhmm) else { return .invalid }
        let fmt = formatter(wallFormat), wall = fmt.string(from: dt)
        let repeated = [-3600.0, 3600].contains { fmt.string(from: dt.addingTimeInterval($0)) == wall }
        return repeated ? .ambiguousRepeatedHour : .exact(dt)
    }

    /// Strict booking start stamp covering the whole trimmed string: `YYYY-MM-DD`, `T` or space, `HH:mm[:ss[.fff]]`,
    /// then optional `Z` or `+HH:mm`/`-HH:mm`. A zone makes the instant exact; without one it is London wall time.
    public static func parseBookingStart(_ raw: String) -> WallTimeResolution {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 16, text.allSatisfy(\.isASCII), [" ", "T"].contains(Array(text)[10]) else { return .invalid }
        let dateIso = String(text.prefix(10))
        var clock = String(text.dropFirst(11)), offset: Int?
        if clock.hasSuffix("Z") {
            offset = 0; clock.removeLast()
        } else if clock.count > 6, let sign = clock.dropLast(5).last, sign == "+" || sign == "-" {
            guard let zone = parseWallTime(String(clock.suffix(5))) else { return .invalid }
            offset = (sign == "-" ? -1 : 1) * (zone.hour * 3600 + zone.minute * 60)
            clock.removeLast(6)
        }
        var fraction = 0.0
        if let dot = clock.firstIndex(of: ".") {
            let digits = clock[clock.index(after: dot)...]
            guard clock.distance(from: clock.startIndex, to: dot) == 8, !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return .invalid }
            fraction = Double("0." + digits) ?? 0
            clock = String(clock[..<dot])
        }
        guard [5, 8].contains(clock.count), let t = parseWallTime(clock), parseIsoDate(dateIso) != nil else { return .invalid }
        guard let offset else {
            let local = resolveLondonWallTime(dateIso: dateIso, hhmm: clock)
            if case .exact(let instant) = local { return .exact(instant.addingTimeInterval(fraction)) }
            return local
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let ymd = dateIso.split(separator: "-").compactMap { Int($0) }
        guard ymd.count == 3, let base = utc.date(from: DateComponents(year: ymd[0], month: ymd[1], day: ymd[2], hour: t.hour, minute: t.minute, second: t.second)) else { return .invalid }
        return .exact(base.addingTimeInterval(fraction - Double(offset)))
    }

    public static func startDate(of session: ClassSession) -> Date? { londonWallDate(dateIso: session.date, hhmm: session.startTime) }

    /// `.invalidTime` for a nonexistent (spring gap) or ambiguous (repeated autumn hour) London start.
    public static func bookingWindowStatus(for session: ClassSession, now: Date = Date()) -> BookingWindowStatus {
        guard case .exact(let start) = resolveLondonWallTime(dateIso: session.date, hhmm: session.startTime) else { return .invalidTime }
        return bookingWindowStatus(start: start, now: now)
    }

    /// `.started` once `start <= now`; `.open` from exactly 48h before start.
    public static func bookingWindowStatus(start: Date, now: Date = Date()) -> BookingWindowStatus {
        if start <= now { return .started }
        let opens = start.addingTimeInterval(-48 * 3600)
        if now >= opens { return .open }
        let label = "OPENS \(formatter("EEE HH:mm").string(from: opens).uppercased())"
        return opens.timeIntervalSince(now) <= 12 * 3600 ? .openingSoon(label) : .upcoming(label)
    }

    public static func nextMidnight(after now: Date) -> Date? {
        addDays(to: londonTodayIso(now: now), days: 1).flatMap { londonWallDate(dateIso: $0, hhmm: "00:00") }
    }

    /// `now` followed by every later instant where a row's badge or visibility changes: opening-soon (60h), 48h open,
    /// class start, each active booking's own start (`activeBookingStarts`), any `additionalDates` (such as reminder
    /// fire instants), and the next London midnight. Drives idle menu redraws with zero network requests.
    public static func upcomingBoundaryDates(for sessions: [ClassSession], now: Date = Date(), activeBookingStarts: [Int: Date] = [:], additionalDates: [Date] = []) -> [Date] {
        let marks = sessions.compactMap(startDate(of:)).flatMap { start in
            [-60.0, -48, 0].map { start.addingTimeInterval($0 * 3600) }
        }
        let bookedMarks = sessions.compactMap { activeBookingStarts[$0.id] }
        return [now] + Set(marks + bookedMarks + additionalDates + [nextMidnight(after: now)].compactMap { $0 }).filter { $0 > now }.sorted()
    }

    /// Rows that pass the date, period, and search filters. A row with an entry in `activeBookingStarts` (an active
    /// booking's own exact start) stays until that start, whatever its public wall time says.
    public static func filterSessions(
        _ sessions: [ClassSession],
        period: SchedulePeriod,
        search: String,
        selectedDate: String,
        now: Date = Date(),
        includePastGraceMinutes: Int = 0,
        activeBookingStarts: [Int: Date] = [:]
    ) -> [ClassSession] {
        filteredSessionStarts(sessions, period: period, search: search, selectedDate: selectedDate, now: now,
                              includePastGraceMinutes: includePastGraceMinutes, activeBookingStarts: activeBookingStarts).map(\.session)
    }

    /// `filterSessions` with each kept row's resolved public start (always set for today's rows and zero-grace lists),
    /// so callers never resolve wall times twice. Explicit earlier dates keep every stored row.
    public static func filteredSessionStarts(
        _ sessions: [ClassSession],
        period: SchedulePeriod,
        search: String,
        selectedDate: String,
        now: Date = Date(),
        includePastGraceMinutes: Int = 0,
        activeBookingStarts: [Int: Date] = [:]
    ) -> [(session: ClassSession, start: Date?)] {
        let todayIso = londonTodayIso(now: now)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sessions.compactMap { item in
            var start: Date?
            if let memberStart = activeBookingStarts[item.id] {
                guard memberStart > now else { return nil }
                start = startDate(of: item)
            } else if selectedDate == todayIso || includePastGraceMinutes == 0 {
                // Today's list and zero-grace lists need a real start: nonexistent spring-gap times are dropped and
                // today's started classes leave at start (`includePastGraceMinutes` default 0).
                guard let resolved = startDate(of: item) else { return nil }
                if selectedDate == todayIso, resolved <= now.addingTimeInterval(-TimeInterval(includePastGraceMinutes) * 60) { return nil }
                start = resolved
            }

            let hour = parseWallTime(item.startTime)?.hour ?? 0
            switch period {
            case .all: break
            case .morning: if hour >= 12 { return nil }
            case .afternoon: if hour < 12 || hour >= 17 { return nil }
            case .evening: if hour < 17 { return nil }
            }
            guard query.isEmpty || item.title.lowercased().contains(query) || item.trainer.lowercased().contains(query) else { return nil }
            return (item, start)
        }
    }
}

public enum WallTimeResolution: Equatable, Sendable {
    case exact(Date)
    case ambiguousRepeatedHour
    case invalid
}

public struct BookingDenied: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The one set of booking and cancellation rules used by the menu-bar app, CLI, and MCP. Every check runs on local
/// state with the caller's execution-time clock, so a rejected action makes zero private API calls.
public enum BookingAuthorization {
    public enum CancelDecision: Equatable, Sendable { case authorized(lateBooking: Bool), needsLateConfirmation }

    private static let outOfSync = BookingDenied("Booking state is out of sync. Refresh bookings before another action.")

    /// `lookup` is the shared cross-club search of the member's entitled clubs (`SharedStateStore.lookupEntitledClass`);
    /// `expectedClubId` (the menu's viewed club) is checked only after ambiguity, so a conflict is always reported.
    public static func authorizeBooking(classId: Int, lookup: SharedStateStore.EntitledClassLookup, bookings: BookingsSnapshot?, now: Date, expectedClubId: Int? = nil) throws {
        guard let bookings else { throw outOfSync }
        guard classId > 0 else { throw BookingDenied("Invalid class ID \(classId).") }
        guard let target = try publicSession(lookup, classId: classId), target.session.id == classId, expectedClubId.map({ $0 == target.clubId }) ?? true else {
            throw BookingDenied("Class \(classId) not found in a loaded timetable for your membership clubs. Fetch its club/date timetable first.")
        }
        guard !bookings.bookedIds.contains(classId) else { throw BookingDenied("Class \(classId) is already booked.") }
        let start = try exactStart(LondonCalendar.resolveLondonWallTime(dateIso: target.session.date, hhmm: target.session.startTime), classId)
        let status = LondonCalendar.bookingWindowStatus(start: start, now: now)
        if status == .started { throw BookingDenied("Class \(classId) has already started.") }
        guard status == .open else { throw BookingDenied("Class \(classId) is not open for booking yet (\(status.badgeLabel)).") }
    }

    /// The unique row and its club, `nil` when missing; an ambiguous ID, an unreadable club cache (whose recovery is named:
    /// a refresh never overwrites a corrupt snapshot file), or a store lock timeout (club `0`) throws before any private request.
    public static func publicSession(_ lookup: SharedStateStore.EntitledClassLookup, classId: Int) throws -> (session: ClassSession, clubId: Int)? {
        switch lookup {
        case .missing: return nil
        case .unique(let session, let clubId): return (session, clubId)
        case .ambiguous: throw BookingDenied("Class \(classId) appears with conflicting or multiple club definitions in cached timetables; refresh the timetable first.")
        case .untrusted(let clubId) where clubId == 0: throw BookingDenied("Another Tertia process is holding the store lock; try again in a moment.")
        case .untrusted(let clubId):
            throw BookingDenied("Cached timetable for club \(clubId) is unreadable or invalid; delete snapshot-\(clubId).json in the Tertia data folder and refresh.")
        }
    }

    /// A public timetable row and the club it was found in (`SharedStateStore.fallbackPublicTarget`).
    public typealias PublicTarget = (session: ClassSession, clubId: Int, clubName: String)

    /// `publicSession` with the row's club name: `clubNames[clubId]`, else the row's own `clubName`.
    public static func publicTarget(_ lookup: SharedStateStore.EntitledClassLookup, classId: Int, clubNames: [Int: String]) throws -> PublicTarget? {
        try publicSession(lookup, classId: classId).map { ($0.session, $0.clubId, clubNames[$0.clubId] ?? $0.session.clubName) }
    }

    /// Uses the active entries' own agreed start stamp; `publicFallback` (the public timetable row and its club) is called
    /// only when every active entry's stamp is empty, so a public ID collision never blocks a cancellation the member's
    /// own booking already dates. An undated booking that names a club is judged only by a row of that club. The late
    /// flag sent to the server is the true 3-hour window, whatever the caller confirmed.
    public static func authorizeCancellation(classId: Int, bookings: BookingsSnapshot?, confirmedLate: Bool, now: Date,
                                             publicFallback: () throws -> PublicTarget?) throws -> CancelDecision {
        guard let bookings else { throw outOfSync }
        guard classId > 0 else { throw BookingDenied("Invalid class ID \(classId).") }
        let resolution: WallTimeResolution
        switch bookings.activeStart(classId: classId) {
        case .missing: throw BookingDenied("Class \(classId) is not in your active bookings. Refresh bookings first.")
        case .conflicting: throw BookingDenied("Conflicting active booking records for class \(classId); refresh bookings first.")
        case .resolved(let stamp): resolution = stamp
        case .empty:
            guard let bookedClub = bookings.agreedActiveClub(classId: classId) else {
                throw BookingDenied("Conflicting active booking records for class \(classId); refresh bookings first.")
            }
            guard let target = try publicFallback(), target.session.id == classId else { throw BookingDenied("Cannot verify valid start time for class \(classId).") }
            guard bookedClub.isEmpty || bookedClub.caseInsensitiveCompare(target.clubName) == .orderedSame
                    || bookedClub.caseInsensitiveCompare(target.session.clubName) == .orderedSame else {
                throw BookingDenied("Cannot verify start time for class \(classId): cached timetable row belongs to \(target.clubName), not \(bookedClub).")
            }
            resolution = LondonCalendar.resolveLondonWallTime(dateIso: target.session.date, hhmm: target.session.startTime)
        }
        let start = try exactStart(resolution, classId)
        if start <= now { throw BookingDenied("Class \(classId) has already started.") }
        let requiresLate = start.timeIntervalSince(now) <= 3 * 3600
        return requiresLate && !confirmedLate ? .needsLateConfirmation : .authorized(lateBooking: requiresLate)
    }

    /// Whether an active booking may be cancelled at `now` (late cancellations count as allowed): the one rule behind
    /// the menu's `BOOKED · CANCEL` badge, with the same `publicFallback` the action runs, so display and execution
    /// never disagree (an ambiguous or untrusted fallback offers no Cancel).
    public static func canCancel(classId: Int, bookings: BookingsSnapshot?, now: Date, publicFallback: () throws -> PublicTarget?) -> Bool {
        (try? authorizeCancellation(classId: classId, bookings: bookings, confirmedLate: true, now: now, publicFallback: publicFallback)) != nil
    }

    /// The execution-time check `MobileBookingClient.mutateAndSync` runs on freshly read bookings: returns the
    /// `lateBooking` flag to send, or throws when the action is not allowed. `lookup` runs at most once, and for a
    /// cancellation only when the active booking has no start stamp of its own (`clubNames` names the row's club,
    /// `SharedStateStore.clubNamesById`).
    public static func authorize(classId: Int, isCancel: Bool, bookings: BookingsSnapshot?, confirmedLate: Bool, now: Date, expectedClubId: Int? = nil,
                                 clubNames: [Int: String] = [:], lookup: () -> SharedStateStore.EntitledClassLookup) throws -> Bool {
        guard isCancel else {
            try authorizeBooking(classId: classId, lookup: lookup(), bookings: bookings, now: now, expectedClubId: expectedClubId)
            return false
        }
        switch try authorizeCancellation(classId: classId, bookings: bookings, confirmedLate: confirmedLate, now: now,
                                          publicFallback: { try publicTarget(lookup(), classId: classId, clubNames: clubNames) }) {
        case .authorized(let lateBooking): return lateBooking
        case .needsLateConfirmation:
            throw BookingDenied("Class \(classId) starts in 3 hours or less. Confirm the late cancellation (CLI --late, MCP late_booking=true).")
        }
    }

    private static func exactStart(_ resolution: WallTimeResolution, _ classId: Int) throws -> Date {
        switch resolution {
        case .exact(let start): return start
        case .ambiguousRepeatedHour: throw BookingDenied("Class \(classId) falls in the ambiguous clock-change hour; cannot verify window locally.")
        case .invalid: throw BookingDenied("Cannot verify valid start time for class \(classId).")
        }
    }
}

public enum SampleData {
    /// Six Canary Wharf classes on London today and tomorrow (07:00 to 19:30) for placeholders and offline previews.
    public static func previewSnapshot(now: Date = Date()) -> TimetableSnapshot {
        let today = LondonCalendar.londonTodayIso(now: now)
        let tomorrow = LondonCalendar.addDays(to: today, days: 1) ?? today
        let rows: [(String, String, Int, String, String)] = [
            ("07:00", "07:45", 45, "Engine Intervals", "Claudia Ferreira"),
            ("09:30", "10:20", 50, "Dynamic Reformer", "Fallon Stocker"),
            ("12:15", "13:00", 45, "Vinyasa Yoga", "Sharon Saker"),
            ("17:30", "18:20", 50, "HYROX Power", "Jessie Woodburn"),
            ("18:30", "19:15", 45, "Mat Pilates", "Marie Leberl"),
            ("19:30", "20:20", 50, "Strong Bench Press", "Pandora Porter"),
        ]
        func day(_ iso: String, idBase: Int) -> [ClassSession] {
            rows.enumerated().map { i, r in
                ClassSession(id: idBase + i, date: iso, startTime: r.0, endTime: r.1, durationMinutes: r.2, title: r.3, trainer: r.4, clubName: "Canary Wharf")
            }
        }
        return TimetableSnapshot(
            clubs: Club.defaultClubs, clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY",
            days: [today: day(today, idBase: 1), tomorrow: day(tomorrow, idBase: 11)], syncedAt: now,
            daySyncedAt: [today: now, tomorrow: now]
        )
    }

    /// The README preview scene: the real `now` with `live` when `live` still has at least 5 classes today that have not
    /// started, else the sample timetable at 06:00 London time today (offline, or too few classes left; never `live`
    /// paired with 06:00). Every day is stamped at the shown clock, so the shown sync time is never later than the shown
    /// time, and the booked sample row is the first shown class that has not started (zero grace).
    public static func previewScene(live: TimetableSnapshot?, now: Date) -> (snapshot: TimetableSnapshot, date: String, now: Date, bookedRow: ClassSession?) {
        let today = LondonCalendar.londonTodayIso(now: now)
        func upcoming(_ snap: TimetableSnapshot, at instant: Date) -> [ClassSession] {
            LondonCalendar.filterSessions(snap.classes(for: today), period: .all, search: "", selectedDate: today, now: instant, includePastGraceMinutes: 0)
        }
        let (base, clock): (TimetableSnapshot, Date)
        if let live, upcoming(live, at: now).count >= 5 { (base, clock) = (live, now) } else {
            let sixAM = LondonCalendar.londonWallDate(dateIso: today, hhmm: "06:00") ?? now
            (base, clock) = (previewSnapshot(now: sixAM), sixAM)
        }
        let snapshot = TimetableSnapshot(clubs: base.clubs, clubId: base.clubId, clubName: base.clubName, clubShortCode: base.clubShortCode, days: base.days,
                                         syncedAt: clock, daySyncedAt: base.days.mapValues { _ in clock }, metaUpdatedAt: clock)
        return (snapshot, today, clock, upcoming(snapshot, at: clock).first)
    }
}
