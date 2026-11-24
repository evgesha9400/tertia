import Foundation

public enum ReminderError: Error, LocalizedError, Equatable, Sendable {
    case invalidLeadTime
    case invalidDurationFormat(String)
    case ambiguousOrInvalidStart(Int)
    case reminderTimePassed(String)
    case classNotFound(Int)
    case ambiguousClass(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidLeadTime:
            return "Reminder lead time must be between 5m and 48h."
        case .invalidDurationFormat(let raw):
            return "Invalid duration '\(raw)'. Use formats like 5m, 30m, 1h, 1h30m, or 48h."
        case .ambiguousOrInvalidStart(let id):
            return "Cannot schedule reminder for class \(id): start time is invalid or falls in a clock-change hour."
        case .reminderTimePassed(let label):
            return "Reminder time (\(label)) has already passed."
        case .classNotFound(let id):
            return "Class \(id) not found in loaded timetables. Fetch its club/date timetable first."
        case .ambiguousClass(let id):
            return "Class \(id) appears in multiple cached clubs; pass --club <id> (or club_id) to choose one."
        }
    }
}

public enum ReminderSyncStatus: Equatable, Sendable {
    case scheduled
    case permissionDenied
    case permissionPending
    case unavailable(String)
}

public protocol ReminderScheduler: Sendable {
    func sync(reminders: [ClassReminder], requestPermission: Bool, now: Date) async -> ReminderSyncStatus
}

public struct ClassReminder: Codable, Hashable, Sendable, Identifiable {
    public static let minLeadMinutes = 5
    public static let maxLeadMinutes = 48 * 60
    public static let presetLeadMinutes: [Int] = [5, 15, 30, 60, 180, 1440, 2880]
    public static let notificationPrefix = "tertia.reminder."

    public let id: String
    public let classId: Int
    public let clubId: Int
    public let clubName: String
    public let date: String
    public let startTime: String
    public let endTime: String
    public let title: String
    public let trainer: String
    public let leadMinutes: Int
    public let classStart: Date
    public let fireAt: Date

    public init(id: String, classId: Int, clubId: Int, clubName: String, date: String, startTime: String, endTime: String,
                title: String, trainer: String, leadMinutes: Int, classStart: Date, fireAt: Date) {
        self.id = id; self.classId = classId; self.clubId = clubId; self.clubName = clubName
        self.date = date; self.startTime = startTime; self.endTime = endTime; self.title = title
        self.trainer = trainer; self.leadMinutes = leadMinutes; self.classStart = classStart; self.fireAt = fireAt
    }

    public var classKey: String { Self.classKey(clubId: clubId, date: date, classId: classId) }

    public var notificationTitle: String {
        leadMinutes == Self.maxLeadMinutes ? "\(title): 48h booking window open" : "\(title) in \(Self.formatLeadTime(minutes: leadMinutes))"
    }

    public var notificationSubtitle: String { "\(clubName) · \(startTime) - \(endTime)" }

    public var notificationBody: String {
        trainer.isEmpty ? "\(date) at \(clubName)" : "With \(trainer) at \(clubName) (\(date))"
    }

    public static func classKey(clubId: Int, date: String, classId: Int) -> String { "\(clubId):\(date):\(classId)" }

    @discardableResult
    public static func validateLeadMinutes(_ minutes: Int) throws -> Int {
        guard (minLeadMinutes...maxLeadMinutes).contains(minutes) else { throw ReminderError.invalidLeadTime }
        return minutes
    }

    public static func leadMinutes(hours: Int?, minutes: Int?) throws -> Int {
        guard hours != nil || minutes != nil else { throw ReminderError.invalidLeadTime }
        if let h = hours, (h < 0 || h > 48) { throw ReminderError.invalidLeadTime }
        if let m = minutes {
            guard m >= 0 else { throw ReminderError.invalidLeadTime }
            if hours != nil, m >= 60 { throw ReminderError.invalidLeadTime }
        }
        let (hMins, hOverflow) = (hours ?? 0).multipliedReportingOverflow(by: 60)
        let (total, sumOverflow) = hMins.addingReportingOverflow(minutes ?? 0)
        guard !hOverflow, !sumOverflow else { throw ReminderError.invalidLeadTime }
        return try validateLeadMinutes(total)
    }

    public static func leadMinutes(hoursText: String, minutesText: String) throws -> Int {
        let hRaw = hoursText.trimmingCharacters(in: .whitespacesAndNewlines)
        let mRaw = minutesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hRaw.isEmpty || !mRaw.isEmpty else { throw ReminderError.invalidLeadTime }
        func parseInt(_ raw: String) throws -> Int? {
            guard !raw.isEmpty else { return nil }
            guard raw.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }), let val = Int(raw) else {
                throw ReminderError.invalidDurationFormat(raw)
            }
            return val
        }
        return try leadMinutes(hours: try parseInt(hRaw), minutes: try parseInt(mRaw))
    }

    /// Strict parser accepting ASCII formats such as `5m`, `30m`, `90m`, `1h`, `1h30m`, `1h 30m`, `48h`, `48h0m`.
    public static func parseLeadMinutes(_ raw: String) throws -> Int {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let compact = String(text.filter { $0 != " " && $0 != "\t" })
        guard !compact.isEmpty, compact.allSatisfy(\.isASCII) else { throw ReminderError.invalidDurationFormat(raw) }
        var hours: Int?, mins: Int?, digits = "", idx = compact.startIndex
        while idx < compact.endIndex {
            let ch = compact[idx]
            if ch.isNumber { digits.append(ch); idx = compact.index(after: idx); continue }
            guard !digits.isEmpty, let value = Int(digits) else { throw ReminderError.invalidDurationFormat(raw) }
            digits = ""
            if ch == "h", hours == nil, mins == nil { hours = value }
            else if ch == "m", mins == nil { mins = value }
            else { throw ReminderError.invalidDurationFormat(raw) }
            idx = compact.index(after: idx)
        }
        guard digits.isEmpty else { throw ReminderError.invalidDurationFormat(raw) }
        return try leadMinutes(hours: hours, minutes: mins)
    }

    public static func formatLeadTime(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    public static func make(session: ClassSession, clubId: Int, clubName: String, leadMinutes: Int, now: Date = Date()) throws -> ClassReminder {
        let validLead = try validateLeadMinutes(leadMinutes)
        guard case .exact(let start) = LondonCalendar.resolveLondonWallTime(dateIso: session.date, hhmm: session.startTime) else {
            throw ReminderError.ambiguousOrInvalidStart(session.id)
        }
        let fireAt = start.addingTimeInterval(-TimeInterval(validLead) * 60)
        guard start > now, fireAt > now else {
            throw ReminderError.reminderTimePassed("\(formatLeadTime(minutes: validLead)) before \(session.startTime)")
        }
        let resolvedClub = clubName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? session.clubName : clubName
        let id = "\(notificationPrefix)\(clubId).\(session.date).\(session.id).\(validLead)"
        return ClassReminder(id: id, classId: session.id, clubId: clubId, clubName: resolvedClub, date: session.date,
                             startTime: session.startTime, endTime: session.endTime, title: session.title,
                             trainer: session.trainer, leadMinutes: validLead, classStart: start, fireAt: fireAt)
    }
}
