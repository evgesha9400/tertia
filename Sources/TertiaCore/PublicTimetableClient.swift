import Foundation

public enum ClientError: Error, LocalizedError, Sendable {
    case invalidURL
    case httpStatus(Int)
    case unknownClub(Int)
    case responseTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid Third Space timetable URL."
        case .httpStatus(let code): "Public timetable returned HTTP \(code)."
        case .unknownClub(let id): "Unknown Third Space club ID \(id)."
        case .responseTooLarge(let limit): "Public timetable response exceeded \(limit) bytes."
        }
    }
}

public actor PublicTimetableClient {
    private static let baseURL = "https://www.thirdspace.london/timetable/"
    private static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let cacheTTL: TimeInterval = 30 * 60

    private let session: URLSession
    private let store: SharedStateStore
    /// Largest timetable page accepted; the download is cancelled as soon as more bytes arrive.
    private let maxResponseBytes: Int

    public init(store: SharedStateStore = SharedStateStore(), session: URLSession? = nil, maxResponseBytes: Int = 4 * 1024 * 1024) {
        self.store = store; self.maxResponseBytes = maxResponseBytes
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: config)
        }
    }

    /// Fetches `date` through `date + 3` and merges it into the on-disk snapshot under a per-club file lock (omitted
    /// days become `[]`; a request reserves its sequence number before sending, so an earlier request never replaces
    /// a later one's day). Other cached dates keep their stamps until they fall before yesterday; the returned snapshot
    /// also keeps fetched historical days.
    public func fetchSchedule(clubId: Int, date: String, forceRefresh: Bool = false) async throws -> TimetableSnapshot {
        guard clubId > 0 else { throw ClientError.unknownClub(clubId) }
        let trimmed = date.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetDate = trimmed.isEmpty ? LondonCalendar.londonTodayIso() : trimmed
        guard LondonCalendar.parseIsoDate(targetDate) != nil else { throw ClientError.invalidURL }

        if !forceRefresh, let cached = cachedSnapshotIfFresh(clubId: clubId, date: targetDate) {
            return cached
        }

        let rangeDates = (0...3).compactMap { LondonCalendar.addDays(to: targetDate, days: $0) }
        var comps = URLComponents(string: Self.baseURL)
        comps?.queryItems = [
            URLQueryItem(name: "location_id", value: String(clubId)),
            URLQueryItem(name: "fromDate", value: targetDate),
            URLQueryItem(name: "toDate", value: rangeDates.last ?? targetDate),
        ]
        guard let url = comps?.url else { throw ClientError.invalidURL }

        let requestSeq = try store.reserveSnapshotSequence()
        let requestedAt = Date()
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await boundedData(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.httpStatus(http.statusCode)
        }

        let parsed = try HTMLTimetableParser.parse(html: String(decoding: data, as: UTF8.self), clubId: clubId)
        guard let club = parsed.clubs.first(where: { $0.id == clubId }) ?? Club.defaultClubs.first(where: { $0.id == clubId }) else {
            throw ClientError.unknownClub(clubId)
        }
        return try store.mergeAndSaveSnapshot(
            clubId: clubId, clubs: parsed.clubs, clubName: club.name, clubShortCode: club.shortCode.isEmpty ? "PUBLIC" : club.shortCode,
            fetchedDays: parsed.days, fetchedRange: rangeDates, requestSeq: requestSeq, syncedAt: requestedAt
        )
    }

    /// Streams the body and cancels the task the moment it exceeds `maxResponseBytes` (`ClientError.responseTooLarge`).
    private func boundedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxResponseBytes else { bytes.task.cancel(); throw ClientError.responseTooLarge(maxResponseBytes) }
            data.append(byte)
        }
        return (data, response)
    }

    /// A fresh primary cache hit also repairs a missing widget mirror copy (best effort: the hit is still valid).
    private func cachedSnapshotIfFresh(clubId: Int, date: String) -> TimetableSnapshot? {
        guard let snap = store.loadSnapshot(clubId: clubId),
              let daySync = snap.syncedAt(for: date), (0...Self.cacheTTL).contains(Date().timeIntervalSince(daySync)),
              snap.hasCachedDay(date)
        else { return nil }
        try? store.repairSnapshotMirrorIfNeeded(clubId: clubId)
        return snap
    }
}
